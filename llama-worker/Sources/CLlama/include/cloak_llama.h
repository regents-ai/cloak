// The llama worker's one way into llama.cpp: load a pinned GGUF model with
// every setting pinned, turn messages into the model's prompt tokens with
// llama.cpp's own chat template machinery (common/chat), and run one request
// at a time: a greedy rewrite under the reply grammar, or an answer to a
// Local Llama chat with llama.cpp's default sampling and its own reply parser.
// cloak_llama.cpp says what each setting is and why.

#ifndef CLOAK_LLAMA_H
#define CLOAK_LLAMA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A loaded model, its vocabulary and its chat template.
typedef struct cloak_engine cloak_engine;

/// How a rewrite or an answer ended.
typedef enum {
    CLOAK_FINISH_STOP,      ///< the model ended its turn
    CLOAK_FINISH_LENGTH,    ///< max_tokens tokens were generated
    CLOAK_FINISH_CANCELLED, ///< cloak_engine_cancel stopped it
    CLOAK_FINISH_FAILED,    ///< a step failed; `failed_step` names it
    CLOAK_FINISH_TOO_LONG,  ///< an answer's prompt plus max_tokens exceeds max_context; nothing was computed
} cloak_finish;

typedef struct {
    cloak_finish finish;
    const char * failed_step;    ///< "template", "context", "grammar", "sampler", "prompt", "generation", "parse" or "answer"; NULL unless failed
    int32_t      failed_code;    ///< llama_process's return code for "prompt" and "generation"; for "grammar", 0 when it does not parse, 1 when it allows no token
    char *       text;           ///< a rewrite's generated text, or an answer's text alone (UTF-8, not terminated); free with cloak_result_free
    size_t       text_length;
    int32_t      prompt_tokens;
    int32_t      generated_tokens;
    uint32_t     context_tokens; ///< the size of the request's own context
    double       prompt_seconds;
    double       generate_seconds;
    uint64_t     metal_allocated_bytes; ///< Metal's allocations at the end of the request, its context still alive
} cloak_result;

/// Loads the GGUF model at `model_path` with `chat_template` (the template's
/// source) in place of the one the model file carries, and the template
/// settings `setting_names[i] = setting_values[i]`, each value JSON text (a
/// boolean, a number or a string); `enable_thinking`, when set, is true or
/// false. Returns NULL on failure, with the reason in `error`.
cloak_engine * cloak_engine_load(const char * model_path, const char * chat_template,
                                 const char * const * setting_names, const char * const * setting_values,
                                 size_t setting_count, char * error, size_t error_size);

/// Frees the model and its Metal buffers. ggml's Metal device checks at
/// process exit that every buffer is gone, so a loaded engine is freed
/// before the process exits.
void cloak_engine_free(cloak_engine * engine);

/// Clears the cancel; called before each request starts.
void cloak_engine_arm(cloak_engine * engine);

/// Stops the request in progress before its next prompt chunk or token. Safe
/// from any thread.
void cloak_engine_cancel(cloak_engine * engine);

/// One rewrite: the prompt read in chunks into a context of its own, sized
/// for the prompt plus `max_tokens`, then greedy decoding under `grammar`
/// (GBNF, its start rule `root`) until the model ends its turn or
/// `max_tokens` tokens are out: greedy picks only among the tokens llama.cpp's
/// grammar sampler allows.
cloak_result cloak_engine_rewrite(cloak_engine * engine, const char * system, const char * user, int32_t max_tokens,
                                  const char * grammar);

/// One answer to a Local Llama chat: `count` messages, `roles[i]` "user" or
/// "assistant" and `contents[i]` its text, with no system message, through
/// the model's chat template; then llama.cpp's own sampling with its default
/// parameters (common_sampler from a default common_params_sampling, as
/// llama-cli and llama-server use with no flags) until the model ends its
/// turn or `max_tokens` tokens are out. The context is sized for the prompt
/// plus `max_tokens`; when that exceeds `max_context` the answer finishes
/// CLOAK_FINISH_TOO_LONG before any context is made. llama.cpp's own parser
/// for the template's format (common_chat_session, as llama-server parses a
/// chat reply) takes the answer apart from any thinking; the text is the
/// answer alone, and thinking is dropped. A reply the parser refuses fails at
/// "parse", and one with no answer in it at "answer".
cloak_result cloak_engine_answer(cloak_engine * engine, const char * const * roles, const char * const * contents, size_t count,
                                 int32_t max_tokens, uint32_t max_context);

void cloak_result_free(cloak_result * result);

/// The size of the model's weights, as llama.cpp counts it.
uint64_t cloak_engine_weights_bytes(const cloak_engine * engine);

/// What Metal has allocated in this process (MTLDevice.currentAllocatedSize,
/// through ggml_backend_dev_memory).
uint64_t cloak_metal_allocated_bytes(void);

#ifdef __cplusplus
}
#endif

#endif
