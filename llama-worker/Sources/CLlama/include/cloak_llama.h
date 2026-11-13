// The llama worker's one way into llama.cpp: load a pinned GGUF model with
// every setting pinned, turn a system and a user message into the model's
// prompt tokens with llama.cpp's own chat template machinery (common/chat),
// and run one greedy rewrite at a time. cloak_llama.cpp says what each
// setting is and why.

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

/// How a rewrite ended.
typedef enum {
    CLOAK_FINISH_STOP,      ///< the model ended its turn
    CLOAK_FINISH_LENGTH,    ///< max_tokens tokens were generated
    CLOAK_FINISH_CANCELLED, ///< cloak_engine_cancel stopped it
    CLOAK_FINISH_FAILED,    ///< a step failed; `failed_step` names it
} cloak_finish;

typedef struct {
    cloak_finish finish;
    const char * failed_step;    ///< "template", "context", "prompt" or "generation"; NULL unless failed
    int32_t      failed_code;    ///< llama_decode's return code for "prompt" and "generation"
    char *       text;           ///< the generated text (UTF-8, not terminated); free with cloak_result_free
    size_t       text_length;
    int32_t      prompt_tokens;
    int32_t      generated_tokens;
    uint32_t     context_tokens; ///< the size of the rewrite's own context
    double       prompt_seconds;
    double       generate_seconds;
    uint64_t     metal_allocated_bytes; ///< Metal's allocations at the end of the rewrite, its context still alive
} cloak_result;

/// Loads the GGUF model at `model_path` with `chat_template` (the template's
/// source) in place of the one the model file carries, and the template
/// settings `setting_names[i] = setting_values[i]`. Returns NULL on failure,
/// with the reason in `error`.
cloak_engine * cloak_engine_load(const char * model_path, const char * chat_template,
                                 const char * const * setting_names, const bool * setting_values,
                                 size_t setting_count, char * error, size_t error_size);

/// Frees the model and its Metal buffers. ggml's Metal device checks at
/// process exit that every buffer is gone, so a loaded engine is freed
/// before the process exits.
void cloak_engine_free(cloak_engine * engine);

/// The prompt tokens for one system and one user message, as
/// cloak_engine_rewrite gives them to the model. Returns a buffer of
/// `*count` tokens to free with free(), or NULL when the template fails.
int32_t * cloak_engine_prompt(cloak_engine * engine, const char * system, const char * user, size_t * count);

/// Clears the cancel; called before each rewrite starts.
void cloak_engine_arm(cloak_engine * engine);

/// Stops the rewrite in progress before its next prompt chunk or token. Safe
/// from any thread.
void cloak_engine_cancel(cloak_engine * engine);

/// One rewrite: the prompt read in chunks into a context of its own, sized
/// for the prompt plus `max_tokens`, then greedy decoding until the model
/// ends its turn or `max_tokens` tokens are out.
cloak_result cloak_engine_rewrite(cloak_engine * engine, const char * system, const char * user, int32_t max_tokens);

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
