// The llama worker's use of llama.cpp. No inference code of its own: the
// model, the Metal kernels, the chat template and the sampler are all
// llama.cpp's. Every setting that could change a result or the memory a
// rewrite takes is written out below, and nothing falls back to another.

#include "cloak_llama.h"

#include "chat.h"
#include "common.h"
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
    const llama_vocab *       vocab = nullptr;
    common_chat_templates_ptr templates;
    std::map<std::string, std::string> template_settings;
    bool                      enable_thinking = true;
    std::atomic<bool>         cancelled{false};
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

llama_context_params context_params(uint32_t n_ctx) {
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
    params.abort_callback        = nullptr;
    params.abort_callback_data   = nullptr;
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

// The model's chat template over the two messages, rendered by common/chat and
// tokenized as llama-server tokenizes a chat prompt: the vocabulary's own
// start token added, and special tokens in the text read as special tokens.
std::vector<llama_token> prompt_tokens(const cloak_engine & engine, const char * system, const char * user) {
    common_chat_templates_inputs inputs;
    inputs.messages              = {message("system", system), message("user", user)};
    inputs.use_jinja             = true;
    inputs.add_generation_prompt = true;
    inputs.reasoning_format      = COMMON_REASONING_FORMAT_NONE;
    inputs.chat_template_kwargs  = engine.template_settings;
    inputs.enable_thinking       = engine.enable_thinking;
    const common_chat_params params = common_chat_templates_apply(engine.templates.get(), inputs);
    return common_tokenize(engine.vocab, params.prompt.str(), /* add_special */ true, /* parse_special */ true);
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

double seconds_since(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

void copy_error(char * error, size_t size, const std::string & text) {
    snprintf(error, size, "%s", text.c_str());
}

} // namespace

extern "C" cloak_engine * cloak_engine_load(const char * model_path, const char * chat_template,
                                            const char * const * setting_names, const bool * setting_values,
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
    engine->vocab = llama_model_get_vocab(engine->model.get());
    // The pinned settings go in as llama-server takes chat_template_kwargs,
    // each value as JSON; enable_thinking also sets the template machinery's
    // own thinking switch, as llama-server does.
    for (size_t i = 0; i < setting_count; ++i) {
        engine->template_settings[setting_names[i]] = setting_values[i] ? "true" : "false";
        if (std::strcmp(setting_names[i], "enable_thinking") == 0) {
            engine->enable_thinking = setting_values[i];
        }
    }
    try {
        engine->templates = common_chat_templates_init(engine->model.get(), chat_template);
        // A template llama.cpp cannot apply fails here, not at every request.
        prompt_tokens(*engine, "system", "user");
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

extern "C" int32_t * cloak_engine_prompt(cloak_engine * engine, const char * system, const char * user, size_t * count) {
    std::vector<llama_token> tokens;
    try {
        tokens = prompt_tokens(*engine, system, user);
    } catch (const std::exception &) {
        return nullptr;
    }
    auto * out = static_cast<int32_t *>(malloc(std::max<size_t>(tokens.size(), 1) * sizeof(int32_t)));
    std::copy(tokens.begin(), tokens.end(), out);
    *count = tokens.size();
    return out;
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
    const auto fail = [&](const char * step, int32_t code) {
        result.finish      = CLOAK_FINISH_FAILED;
        result.failed_step = step;
        result.failed_code = code;
        return result;
    };

    std::vector<llama_token> prompt;
    try {
        prompt = prompt_tokens(*engine, system, user);
    } catch (const std::exception &) {
        return fail("template", 0);
    }
    result.prompt_tokens = static_cast<int32_t>(prompt.size());

    // A context of its own for every rewrite, sized for the prompt and every
    // token the request allows (llama.cpp rounds it up to a multiple of 256):
    // any request under the daemon's limits fits, nothing carries over from
    // the rewrite before, and the attention cache is no bigger than this
    // rewrite can need.
    llama_context_ptr context(llama_init_from_model(
        engine->model.get(), context_params(static_cast<uint32_t>(prompt.size()) + static_cast<uint32_t>(max_tokens))));
    if (!context) {
        return fail("context", 0);
    }
    result.context_tokens = llama_n_ctx(context.get());
    llama_sampler_ptr greedy(llama_sampler_init_greedy());
    // llama.cpp's grammar sampler, when the pin has a grammar: it only masks
    // tokens, and greedy still picks among the rest.
    llama_sampler_ptr constraint(grammar ? llama_sampler_init_grammar(engine->vocab, grammar, "root") : nullptr);
    if (grammar && !constraint) {
        return fail("grammar", 0);
    }

    auto started = std::chrono::steady_clock::now();
    for (size_t at = 0; at < prompt.size(); at += prompt_chunk) {
        if (engine->cancelled) {
            result.finish = CLOAK_FINISH_CANCELLED;
            return result;
        }
        const auto n = static_cast<int32_t>(std::min<size_t>(prompt_chunk, prompt.size() - at));
        if (const int32_t code = llama_decode(context.get(), llama_batch_get_one(prompt.data() + at, n))) {
            return fail("prompt", code);
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
        llama_token token = llama_sampler_sample(greedy.get(), context.get(), -1);
        if (constraint) {
            token = allowed(constraint.get(), greedy.get(), context.get(), engine->vocab, token);
            if (token == LLAMA_TOKEN_NULL) {
                return fail("grammar", 1);
            }
            llama_sampler_accept(constraint.get(), token);
        }
        if (llama_vocab_is_eog(engine->vocab, token)) {
            result.finish = CLOAK_FINISH_STOP;
            break;
        }
        output.push_back(token);
        if (output.size() == static_cast<size_t>(max_tokens)) {
            result.finish = CLOAK_FINISH_LENGTH;
            break;
        }
        if (const int32_t code = llama_decode(context.get(), llama_batch_get_one(&token, 1))) {
            return fail("generation", code);
        }
    }
    result.generate_seconds      = seconds_since(started);
    result.generated_tokens      = static_cast<int32_t>(output.size());
    result.metal_allocated_bytes = cloak_metal_allocated_bytes();

    // The tokens as text, special tokens written out, as the MLX worker
    // decodes them.
    const std::string text = common_detokenize(engine->vocab, output, /* special */ true);
    result.text        = static_cast<char *>(malloc(std::max<size_t>(text.size(), 1)));
    result.text_length = text.size();
    std::memcpy(result.text, text.data(), text.size());
    return result;
}

extern "C" void cloak_result_free(cloak_result * result) {
    free(result->text);
    result->text = nullptr;
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
