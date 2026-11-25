// The llama worker's use of llama.cpp. No inference code of its own: the
// model, the Metal kernels, the chat template, the samplers and the parser
// that takes an answer apart from its thinking are all llama.cpp's. Every setting that could change a result or the memory a
// request takes is written out below, and nothing falls back to another.

#include "cloak_llama.h"

#include "chat.h"
#include "common.h"
#include "sampling.h"
#include "ggml-backend.h"
#include "llama-cpp.h"
#include "log.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <map>
#include <string>
#include <vector>

extern char ** environ;

struct cloak_engine {
    llama_model_ptr           model;
    llama_adapter_lora *      lora  = nullptr;
    const llama_vocab *       vocab = nullptr;
    common_chat_templates_ptr templates;
    std::map<std::string, std::string> template_settings;
    bool                      enable_thinking = true;
    std::atomic<bool>         cancelled{false};
    // Cached static system-prompt prefix snapshot for rewrite acceleration
    // (contains strictly zero user tokens; restored into each rewrite's fresh
    // isolated context via llama_state_seq_set_data).
    std::string               cached_system;
    std::vector<llama_token>  cached_prefix;
    std::vector<uint8_t>      cached_prefix_state;

    ~cloak_engine() {
        if (lora) {
            llama_adapter_lora_free(lora);
            lora = nullptr;
        }
    }
};

namespace {

// The prompt goes to the model in chunks of this many tokens, with a check
// for a cancel between them; it is also the physical batch.
constexpr uint32_t prompt_chunk = 512;

// Set only while the model loads, before any request exists.
std::atomic<bool> loading{false};

// llama.cpp's own log stays out of the worker's: it can quote prompt text.
// While the model loads its errors go to standard error, to say why a load
// failed; nothing else is ever written.
void on_log(ggml_log_level level, const char * text, void *) {
    if (loading && level == GGML_LOG_LEVEL_ERROR) {
        fputs(text, stderr);
    }
}

// llama.cpp reads settings from GGML_* and LLAMA_* environment variables
// (fusion, graph reuse, Metal residency and more). The worker clears them, so
// only the settings written here apply.
void clear_environment_settings() {
    std::vector<std::string> names;
    for (char ** entry = environ; *entry; ++entry) {
        const std::string text = *entry;
        if (text.rfind("GGML_", 0) == 0 || text.rfind("LLAMA_", 0) == 0) {
            names.push_back(text.substr(0, text.find('=')));
        }
    }
    for (const auto & name : names) {
        unsetenv(name.c_str());
    }
}

ggml_backend_dev_t metal_device() {
    return ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);
}

llama_model_params model_params(ggml_backend_dev_t * devices) {
    llama_model_params params = llama_model_default_params();
    params.devices               = devices;                // Metal, and nothing else
    params.tensor_buft_overrides = nullptr;
    params.n_gpu_layers          = -1;                     // every layer on the GPU
    params.split_mode            = LLAMA_SPLIT_MODE_NONE;  // one GPU
    params.main_gpu              = 0;
    params.tensor_split          = nullptr;
    params.load_mode             = LLAMA_LOAD_MODE_NONE;   // weights read into memory, not mapped from the file
    params.lazy_mode             = LLAMA_LAZY_MODE_OFF;    // every tensor read at load
    params.progress_callback     = nullptr;
    params.kv_overrides          = nullptr;
    params.vocab_only            = false;
    params.check_tensors         = false;                  // the file's sha256 was checked against the pin
    params.use_extra_bufts       = false;                  // no CPU weight repacking
    params.no_host               = false;
    params.no_alloc              = false;
    params.load_mtp              = false;                  // no multi-token prediction layers: no speculative decoding
    return params;
}

bool abort_requested(void * data) {
    return static_cast<const std::atomic<bool> *>(data)->load(std::memory_order_relaxed);
}

llama_context_params context_params(uint32_t n_ctx, cloak_engine * engine) {
    llama_context_params params = llama_context_default_params();
    params.n_ctx                 = n_ctx;
    params.n_batch               = prompt_chunk;
    params.n_ubatch              = prompt_chunk;
    params.n_seq_max             = 1;
    params.n_rs_seq              = 0;                          // no recurrent-state snapshots
    params.n_outputs_max         = 1;                          // logits only for the last token of each step
    params.n_outputs_max_per_seq = 1;
    params.n_threads             = 4;
    params.n_threads_batch       = 4;
    params.ctx_type              = LLAMA_CONTEXT_TYPE_DEFAULT;
    params.rope_scaling_type     = LLAMA_ROPE_SCALING_TYPE_UNSPECIFIED; // the model's own
    params.pooling_type          = LLAMA_POOLING_TYPE_NONE;
    params.attention_type        = LLAMA_ATTENTION_TYPE_UNSPECIFIED;    // the model's own (causal)
    params.flash_attn_type       = LLAMA_FLASH_ATTN_TYPE_ENABLED;
    params.rope_freq_base        = 0.0f;                       // the model's own
    params.rope_freq_scale       = 0.0f;                       // the model's own
    params.yarn_ext_factor       = -1.0f;                      // the model's own
    params.cb_eval               = nullptr;
    params.cb_eval_user_data     = nullptr;
    params.type_k                = GGML_TYPE_F16;
    params.type_v                = GGML_TYPE_F16;
    params.moe_cache_size        = 0;
    params.abort_callback        = engine ? abort_requested : nullptr;
    params.abort_callback_data   = engine ? &engine->cancelled : nullptr;
    params.embeddings            = false;
    params.offload_kqv           = true;                       // the attention cache on the GPU
    params.no_perf               = true;
    params.op_offload            = true;
    params.swa_full              = false;                      // sliding-window layers keep only their window
    params.kv_unified            = false;
    params.samplers              = nullptr;
    params.n_samplers            = 0;
    params.ctx_other             = nullptr;
    return params;
}

common_chat_msg message(const char * role, const char * content) {
    common_chat_msg msg;
    msg.role    = role;
    msg.content = content;
    return msg;
}

// What the model's chat template is given: the messages, a turn for the
// model to answer, the pinned settings, and how a reply's thinking is told
// apart from its answer when it is parsed.
common_chat_templates_inputs template_inputs(const cloak_engine & engine, std::vector<common_chat_msg> messages,
                                             common_reasoning_format reasoning) {
    common_chat_templates_inputs inputs;
    inputs.messages              = std::move(messages);
    inputs.use_jinja             = true;
    inputs.add_generation_prompt = true;
    inputs.reasoning_format      = reasoning;
    inputs.chat_template_kwargs  = engine.template_settings;
    inputs.enable_thinking       = engine.enable_thinking;
    return inputs;
}

// A rendered prompt tokenized as llama-server tokenizes a chat prompt: the
// vocabulary's own start token added, and special tokens in the text read as
// special tokens.
std::vector<llama_token> tokenize(const cloak_engine & engine, const std::string & prompt) {
    return common_tokenize(engine.vocab, prompt, /* add_special */ true, /* parse_special */ true);
}

// The model's chat template over the messages, rendered by common/chat. A
// rewrite's reply is never parsed: the reply grammar decides its shape.
std::vector<llama_token> prompt_tokens(const cloak_engine & engine, std::vector<common_chat_msg> messages) {
    const common_chat_params params = common_chat_templates_apply(
        engine.templates.get(), template_inputs(engine, std::move(messages), COMMON_REASONING_FORMAT_NONE));
    return tokenize(engine, params.prompt.str());
}

// Greedy's own choice when the grammar allows it; otherwise greedy over the
// tokens the grammar allows, never over a token it masks. This is
// llama.cpp's own rejection sampling (common_sampler_sample): the same token
// as masking first, without masking the whole vocabulary at every step.
// LLAMA_TOKEN_NULL when the grammar allows no token at all.
llama_token allowed(llama_sampler * grammar, llama_sampler * greedy, llama_context * context, const llama_vocab * vocab,
                    llama_token token) {
    llama_token_data       one      = {token, 1.0f, 0.0f};
    llama_token_data_array just_one = {&one, 1, -1, false};
    llama_sampler_apply(grammar, &just_one);
    if (one.logit != -INFINITY) {
        return token;
    }
    const float *                 logits = llama_get_logits_ith(context, -1);
    std::vector<llama_token_data> candidates(llama_vocab_n_tokens(vocab));
    for (llama_token id = 0; id < static_cast<llama_token>(candidates.size()); ++id) {
        candidates[id] = {id, logits[id], 0.0f};
    }
    llama_token_data_array all = {candidates.data(), candidates.size(), -1, false};
    llama_sampler_apply(grammar, &all);
    llama_sampler_apply(greedy, &all);
    return all.data[all.selected].logit == -INFINITY ? LLAMA_TOKEN_NULL : all.data[all.selected].id;
}

// Feeds the model tokens at the positions after everything it has read, and
// asks for its prediction after the last of them.
class reader {
  public:
    explicit reader(llama_context * context, llama_pos start_pos = 0)
        : context_(context), batch_(llama_batch_ext_init(context)), position_(start_pos) {}

    // Zero, or llama.cpp's code.
    int32_t read(const llama_token * tokens, int32_t count) {
        llama_batch_ext_clear(batch_.get());
        for (int32_t i = 0; i < count; ++i, ++position_) {
            const int32_t at = llama_batch_ext_add_token(batch_.get(), 0, tokens[i]);
            if (at < 0) {
                return at;
            }
            llama_batch_ext_set_pos(batch_.get(), at, &position_);
        }
        llama_batch_ext_set_output_logits(batch_.get(), count - 1, true);
        return llama_process(context_, LLAMA_PROCESS_TYPE_DECODE, batch_.get());
    }

  private:
    llama_context *     context_;
    llama_batch_ext_ptr batch_;
    llama_pos           position_ = 0;
};

cloak_result failed(cloak_result result, const char * step, int32_t code) {
    result.finish      = CLOAK_FINISH_FAILED;
    result.failed_step = step;
    result.failed_code = code;
    return result;
}

// Reads `tokens[from..to)` in chunks, checking cancel before each chunk and
// treating an abort_callback interruption cleanly as CLOAK_FINISH_CANCELLED.
bool read_range(const cloak_engine & engine, reader & model, const std::vector<llama_token> & tokens,
                size_t from, size_t to, cloak_result & result) {
    for (size_t at = from; at < to; at += prompt_chunk) {
        if (engine.cancelled) {
            result.finish = CLOAK_FINISH_CANCELLED;
            return false;
        }
        const auto n = static_cast<int32_t>(std::min<size_t>(prompt_chunk, to - at));
        if (const int32_t code = model.read(tokens.data() + at, n)) {
            if (engine.cancelled) {
                result.finish = CLOAK_FINISH_CANCELLED;
                return false;
            }
            result = failed(result, "prompt", code);
            return false;
        }
    }
    return true;
}

// Reads the whole prompt in chunks, with a check for a cancel before each.
// False when a cancel or llama.cpp stopped it, with `result` saying which.
bool read_prompt(const cloak_engine & engine, reader & model, const std::vector<llama_token> & prompt,
                 cloak_result & result) {
    return read_range(engine, model, prompt, 0, prompt.size(), result);
}

// Computes the exact token prefix invariant across different user messages for
// `system` (strictly BOS + system message + template role header, zero user
// tokens) so it can be snapshotted and reused safely across rewrites.
std::vector<llama_token> system_prefix_tokens(const cloak_engine & engine, const char * system) {
    const auto a = prompt_tokens(engine, {message("system", system), message("user", "A")});
    const auto b = prompt_tokens(engine, {message("system", system), message("user", "B")});
    const size_t limit = std::min(a.size(), b.size());
    size_t common = 0;
    while (common < limit && a[common] == b[common]) {
        ++common;
    }
    return std::vector<llama_token>(a.begin(), a.begin() + static_cast<ptrdiff_t>(common));
}

void set_text(cloak_result & result, const std::string & text) {
    result.text        = static_cast<char *>(malloc(std::max<size_t>(text.size(), 1)));
    result.text_length = text.size();
    std::memcpy(result.text, text.data(), text.size());
}

void set_reasoning(cloak_result & result, const std::string & reasoning) {
    if (reasoning.empty()) {
        return;
    }
    result.reasoning        = static_cast<char *>(malloc(reasoning.size()));
    result.reasoning_length = reasoning.size();
    std::memcpy(result.reasoning, reasoning.data(), reasoning.size());
}

double seconds_since(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

void copy_error(char * error, size_t size, const std::string & text) {
    snprintf(error, size, "%s", text.c_str());
}

} // namespace

extern "C" cloak_engine * cloak_engine_load(const char * model_path, const char * chat_template, const char * lora_path,
                                            const char * const * setting_names, const char * const * setting_values,
                                            size_t setting_count, char * error, size_t error_size) {
    clear_environment_settings();
    // common/'s logger is never used; pausing it drops whatever is sent to it.
    common_log_pause(common_log_main());
    llama_log_set(on_log, nullptr);
    llama_backend_init();
    loading = true;

    ggml_backend_dev_t devices[] = {metal_device(), nullptr};
    if (!devices[0]) {
        loading = false;
        copy_error(error, error_size, "no Metal device");
        return nullptr;
    }
    auto engine = std::make_unique<cloak_engine>();
    engine->model.reset(llama_model_load_from_file(model_path, model_params(devices)));
    if (!engine->model) {
        loading = false;
        copy_error(error, error_size, "llama.cpp could not load the model file");
        return nullptr;
    }
    if (lora_path && lora_path[0] != '\0') {
        engine->lora = llama_adapter_lora_init(engine->model.get(), lora_path);
        if (!engine->lora) {
            loading = false;
            copy_error(error, error_size, "llama.cpp could not load the LoRA adapter");
            return nullptr;
        }
    }
    engine->vocab = llama_model_get_vocab(engine->model.get());
    // The pinned settings go in as llama-server takes chat_template_kwargs,
    // each value as JSON text; enable_thinking, true or false, also sets the
    // template machinery's own thinking switch, as llama-server does.
    for (size_t i = 0; i < setting_count; ++i) {
        const std::string value = setting_values[i];
        engine->template_settings[setting_names[i]] = value;
        if (std::strcmp(setting_names[i], "enable_thinking") == 0) {
            if (value != "true" && value != "false") {
                loading = false;
                copy_error(error, error_size, "enable_thinking is pinned as " + value + ", not true or false");
                return nullptr;
            }
            engine->enable_thinking = value == "true";
        }
    }
    try {
        engine->templates = common_chat_templates_init(engine->model.get(), chat_template);
        // A template llama.cpp cannot apply fails here, not at every request.
        prompt_tokens(*engine, {message("system", "system"), message("user", "user")});
    } catch (const std::exception & e) {
        loading = false;
        copy_error(error, error_size, std::string("the chat template does not apply: ") + e.what());
        return nullptr;
    }
    loading = false;
    return engine.release();
}

extern "C" void cloak_engine_free(cloak_engine * engine) {
    delete engine;
}

extern "C" void cloak_engine_arm(cloak_engine * engine) {
    engine->cancelled = false;
}

extern "C" void cloak_engine_cancel(cloak_engine * engine) {
    engine->cancelled = true;
}

extern "C" cloak_result cloak_engine_rewrite(cloak_engine * engine, const char * system, const char * user, int32_t max_tokens,
                                             const char * grammar) {
    cloak_result result = {};

    std::vector<llama_token> prompt;
    try {
        prompt = prompt_tokens(*engine, {message("system", system), message("user", user)});
    } catch (const std::exception &) {
        return failed(result, "template", 0);
    }
    result.prompt_tokens = static_cast<int32_t>(prompt.size());

    // Bound the rewrite output budget tightly to the prompt size (Decision R7)
    // instead of allocating a 16,384-token FP16 KV cache (~1.5 GB) for short
    // rewrites. A rewrite never needs more than max(1024, 2*prompt + 512)
    // output tokens while remaining capped by the caller's `max_tokens`.
    const int32_t effective_max = std::max<int32_t>(
        1, std::min<int32_t>(max_tokens, std::max<int32_t>(1024, static_cast<int32_t>(prompt.size()) * 2 + 512)));

    // A fresh isolated context of its own for every rewrite, sized tightly for
    // the prompt plus `effective_max` tokens, with abort_callback wired.
    llama_context_ptr context(llama_init_from_model(
        engine->model.get(),
        context_params(static_cast<uint32_t>(prompt.size()) + static_cast<uint32_t>(effective_max), engine)));
    if (!context) {
        return failed(result, "context", 0);
    }
    result.context_tokens = llama_n_ctx(context.get());
    llama_sampler_ptr greedy(llama_sampler_init_greedy());
    // llama.cpp's grammar sampler: it only masks tokens, and greedy still
    // picks among the rest.
    llama_sampler_ptr constraint(llama_sampler_init_grammar(engine->vocab, grammar, "root"));
    if (!constraint) {
        return failed(result, "grammar", 0);
    }

    // Reuse the exact static system-prompt KV + recurrent state across rewrites
    // (Decision R7) when `prompt` begins with the cached invariant prefix.
    const std::string system_str(system);
    if (engine->cached_system != system_str) {
        engine->cached_system = system_str;
        engine->cached_prefix.clear();
        engine->cached_prefix_state.clear();
        try {
            engine->cached_prefix = system_prefix_tokens(*engine, system);
        } catch (const std::exception &) {
            engine->cached_prefix.clear();
        }
    }

    const size_t prefix_len = engine->cached_prefix.size();
    const bool matches_prefix = prefix_len > 0 && prompt.size() > prefix_len
        && std::equal(engine->cached_prefix.begin(), engine->cached_prefix.end(), prompt.begin());

    auto started = std::chrono::steady_clock::now();
    size_t start_pos = 0;
    if (matches_prefix && !engine->cached_prefix_state.empty()) {
        if (llama_state_seq_set_data(context.get(), engine->cached_prefix_state.data(),
                                     engine->cached_prefix_state.size(), 0) > 0) {
            start_pos = prefix_len;
        }
    }

    reader model(context.get(), static_cast<llama_pos>(start_pos));
    if (matches_prefix && start_pos == 0) {
        // First rewrite for this system prompt: prefill the invariant prefix,
        // snapshot its KV/recurrent state (capped at 128 MiB), then prefill
        // the user suffix.
        if (!read_range(*engine, model, prompt, 0, prefix_len, result)) {
            return result;
        }
        const size_t state_size = llama_state_seq_get_size(context.get(), 0);
        constexpr size_t max_snapshot_bytes = 128ULL * 1024ULL * 1024ULL;
        if (state_size > 0 && state_size <= max_snapshot_bytes) {
            std::vector<uint8_t> snapshot(state_size);
            if (llama_state_seq_get_data(context.get(), snapshot.data(), snapshot.size(), 0) > 0) {
                engine->cached_prefix_state = std::move(snapshot);
            }
        }
        if (!read_range(*engine, model, prompt, prefix_len, prompt.size(), result)) {
            return result;
        }
    } else {
        if (!read_range(*engine, model, prompt, start_pos, prompt.size(), result)) {
            return result;
        }
    }
    result.prompt_seconds = seconds_since(started);

    started = std::chrono::steady_clock::now();
    std::vector<llama_token> output;
    while (true) {
        if (engine->cancelled) {
            result.finish = CLOAK_FINISH_CANCELLED;
            return result;
        }
        llama_token token = allowed(constraint.get(), greedy.get(), context.get(), engine->vocab,
                                    llama_sampler_sample(greedy.get(), context.get(), -1));
        if (token == LLAMA_TOKEN_NULL) {
            return failed(result, "grammar", 1);
        }
        llama_sampler_accept(constraint.get(), token);
        if (llama_vocab_is_eog(engine->vocab, token)) {
            result.finish = CLOAK_FINISH_STOP;
            break;
        }
        output.push_back(token);
        if (output.size() == static_cast<size_t>(effective_max)) {
            result.finish = CLOAK_FINISH_LENGTH;
            break;
        }
        if (const int32_t code = model.read(&token, 1)) {
            if (engine->cancelled) {
                result.finish = CLOAK_FINISH_CANCELLED;
                return result;
            }
            return failed(result, "generation", code);
        }
    }
    result.generate_seconds      = seconds_since(started);
    result.generated_tokens      = static_cast<int32_t>(output.size());
    result.metal_allocated_bytes = cloak_metal_allocated_bytes();

    // The tokens as text, special tokens written out, so the reply holds
    // exactly what the model generated.
    set_text(result, common_detokenize(engine->vocab, output, /* special */ true));
    return result;
}

extern "C" cloak_result cloak_engine_answer(cloak_engine * engine, const char * const * roles, const char * const * contents,
                                            const char * const * reasonings, size_t count, int32_t max_answer_tokens,
                                            int32_t max_thinking_tokens, uint32_t max_context,
                                            cloak_partial_callback on_partial, void * user_data) {
    cloak_result result = {};

    std::vector<common_chat_msg> messages;
    for (size_t i = 0; i < count; ++i) {
        common_chat_msg msg = message(roles[i], contents[i]);
        if (reasonings && reasonings[i] && reasonings[i][0] != '\0') {
            msg.reasoning_content = reasonings[i];
        }
        messages.push_back(std::move(msg));
    }
    common_chat_session      chat;
    std::vector<llama_token> prompt;
    try {
        chat   = common_chat_session(engine->templates.get(), engine->vocab,
                                     template_inputs(*engine, std::move(messages), COMMON_REASONING_FORMAT_DEEPSEEK));
        prompt = tokenize(*engine, chat.prompt().str());
    } catch (const std::exception &) {
        return failed(result, "template", 0);
    }
    result.prompt_tokens = static_cast<int32_t>(prompt.size());
    // The conversation is never trimmed: one that leaves no room for a whole
    // answer inside the cap is not started.
    if (prompt.size() + static_cast<size_t>(max_answer_tokens) > max_context) {
        result.finish = CLOAK_FINISH_TOO_LONG;
        return result;
    }

    // Reserve room for both thinking and answer budgets up to `max_context`
    // (Decision R7) so thinking models like Inkling 2 Mini don't run out of
    // room before writing their visible answer.
    const size_t available_gen = max_context - prompt.size();
    const size_t desired_gen   = static_cast<size_t>(max_answer_tokens) + static_cast<size_t>(std::max<int32_t>(0, max_thinking_tokens));
    const uint32_t total_gen_budget = static_cast<uint32_t>(std::min(available_gen, desired_gen));
    const int32_t effective_thinking_cap = static_cast<int32_t>(std::min<size_t>(
        static_cast<size_t>(std::max<int32_t>(0, max_thinking_tokens)),
        available_gen > static_cast<size_t>(max_answer_tokens) ? available_gen - static_cast<size_t>(max_answer_tokens) : 0));

    llama_context_ptr context(llama_init_from_model(
        engine->model.get(), context_params(static_cast<uint32_t>(prompt.size()) + total_gen_budget, engine)));
    if (!context) {
        return failed(result, "context", 0);
    }
    if (engine->lora) {
        float scale = 1.0f;
        if (llama_set_adapters_lora(context.get(), &engine->lora, 1, &scale) != 0) {
            return failed(result, "lora", 0);
        }
    }
    result.context_tokens = llama_n_ctx(context.get());
    common_params_sampling sampling;
    chat.apply_sampling(sampling);
    common_sampler_ptr     sampler;
    try {
        sampler.reset(common_sampler_init(engine->model.get(), sampling));
    } catch (const std::exception &) {
        return failed(result, "sampler", 0);
    }

    reader model(context.get());
    auto   started = std::chrono::steady_clock::now();
    if (!read_prompt(*engine, model, prompt, result)) {
        return result;
    }
    result.prompt_seconds = seconds_since(started);

    started = std::chrono::steady_clock::now();
    auto last_emit = started;
    common_chat_input pending;
    int32_t           generated       = 0;
    int32_t           thinking_tokens = 0;
    int32_t           answer_tokens   = 0;
    bool              saw_answer      = false;
    std::string       last_emitted;
    bool              thinking_exhausted = false;

    while (true) {
        if (engine->cancelled) {
            result.finish = CLOAK_FINISH_CANCELLED;
            return result;
        }
        const llama_token token = common_sampler_sample(sampler.get(), context.get(), -1);
        common_sampler_accept(sampler.get(), token, /* is_generated */ true);
        if (llama_vocab_is_eog(engine->vocab, token)) {
            result.finish = CLOAK_FINISH_STOP;
            break;
        }
        pending.append(common_token_to_piece(engine->vocab, token, sampling.preserved_tokens.count(token) > 0), token);
        ++generated;

        // Parse incrementally every 4 tokens (or every ~60 ms) to separate
        // thinking tokens from visible answer tokens and stream answer updates.
        const auto now = std::chrono::steady_clock::now();
        const bool should_parse = (generated % 4 == 0)
            || (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_emit).count() >= 60);
        if (should_parse && !pending.empty()) {
            try {
                const auto & parsed = chat.feed(pending);
                pending = {};
                if (!parsed.content.empty()) {
                    saw_answer = true;
                    if (on_partial && parsed.content != last_emitted) {
                        last_emitted = parsed.content;
                        on_partial(last_emitted.data(), last_emitted.size(), user_data);
                    }
                    last_emit = now;
                }
            } catch (const std::exception &) {
                return failed(result, "parse", 0);
            }
        }

        if (saw_answer) {
            ++answer_tokens;
            if (answer_tokens >= max_answer_tokens || generated >= static_cast<int32_t>(total_gen_budget)) {
                result.finish = CLOAK_FINISH_LENGTH;
                break;
            }
        } else {
            ++thinking_tokens;
            if (effective_thinking_cap > 0 && thinking_tokens >= effective_thinking_cap) {
                thinking_exhausted = true;
                break;
            }
            if (generated >= static_cast<int32_t>(total_gen_budget)) {
                thinking_exhausted = true;
                break;
            }
        }

        if (const int32_t code = model.read(&token, 1)) {
            if (engine->cancelled) {
                result.finish = CLOAK_FINISH_CANCELLED;
                return result;
            }
            return failed(result, "generation", code);
        }
    }
    result.generate_seconds      = seconds_since(started);
    result.generated_tokens      = generated;
    result.metal_allocated_bytes = cloak_metal_allocated_bytes();

    std::string answer;
    std::string reasoning;
    try {
        const auto finished = chat.finish(pending);
        answer    = finished.content;
        reasoning = finished.reasoning_content;
    } catch (const std::exception &) {
        return failed(result, "parse", 0);
    }
    if (answer.empty()) {
        if (thinking_exhausted || result.finish == CLOAK_FINISH_LENGTH) {
            result.finish = CLOAK_FINISH_THINKING_EXHAUSTED;
            return result;
        }
        return failed(result, "answer", 0);
    }
    if (on_partial && answer != last_emitted) {
        on_partial(answer.data(), answer.size(), user_data);
    }
    set_text(result, answer);
    set_reasoning(result, reasoning);
    return result;
}

extern "C" void cloak_result_free(cloak_result * result) {
    free(result->text);
    result->text = nullptr;
    free(result->reasoning);
    result->reasoning = nullptr;
}

extern "C" uint64_t cloak_engine_weights_bytes(const cloak_engine * engine) {
    return llama_model_size(engine->model.get());
}

extern "C" uint64_t cloak_metal_allocated_bytes(void) {
    // Metal's recommended working set less what is free; llama.cpp clips it
    // at the working set, which these models stay well under.
    size_t free = 0, total = 0;
    ggml_backend_dev_memory(metal_device(), &free, &total);
    return total - free;
}
