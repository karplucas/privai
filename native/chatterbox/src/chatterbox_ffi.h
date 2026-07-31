// C boundary over codec.cpp's TTS reference loop, for dart:ffi.
//
// `codec_common::tts_runner_synthesize` is C++ — its params and result carry
// std::string and std::vector — so it cannot be called from Dart directly.
// This header is the flat equivalent: plain types in, a malloc'd float buffer
// out, one free function.
//
// Synthesis blocks for seconds. Call it from a Dart isolate, never the UI one.

#ifndef CHATTERBOX_FFI_H
#define CHATTERBOX_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
#define CHATTERBOX_API __declspec(dllexport)
#else
#define CHATTERBOX_API __attribute__((visibility("default")))
#endif

/// Everything one utterance needs. Paths are UTF-8 and must outlive the call.
typedef struct {
    const char * codec_path;     // codec + LM adaptor GGUF (required)
    const char * backbone_path;  // T3 llama.cpp GGUF (required)
    const char * text;           // what to say (required)
    const char * ref_audio_path; // reference voice WAV, or NULL for the
                                 // model's built-in conditioning.
                                 // PCM 16-bit only — float WAVs are rejected
                                 // by the loader.

    int32_t n_threads;   // 0 lets the runtime choose, which on this stack
                         // means effectively single-threaded. Always pass a
                         // real value: it is worth ~4x.
    int32_t use_gpu;     // 1 offloads the decode loop. Measured slower than
                         // CPU on a discrete GPU; kept for on-device testing
                         // where unified memory may change the answer.
    int32_t max_frames;  // hard ceiling on generated audio frames; 0 = the
                         // model's own default.
    uint32_t seed;

    float exaggeration;  // emotion intensity; <0 keeps the model's default.
    float cfg_weight;    // 0 disables classifier-free guidance, halving the
                         // work per step (the model runs one sequence rather
                         // than two). <0 keeps the default.
    float temperature;   // <0 keeps the default.
} chatterbox_params;

/// Synthesised audio. Owned by the library — release with
/// [chatterbox_result_free].
typedef struct {
    float * pcm;          // mono, -1..1, NULL on failure
    int32_t n_samples;
    int32_t sample_rate;
    int32_t n_frames;     // speech tokens generated
    const char * error;   // NULL on success
} chatterbox_result;

/// Synthesises [params.text]. Returns 0 on success, non-zero on failure with
/// `out->error` set. `out` is valid to pass to [chatterbox_result_free] either
/// way.
CHATTERBOX_API int32_t chatterbox_synthesize(const chatterbox_params * params,
                                             chatterbox_result * out);

/// Releases the buffers in [result]. Safe on a zeroed or failed result.
CHATTERBOX_API void chatterbox_result_free(chatterbox_result * result);

/// Library version string, for checking the .so actually loaded.
CHATTERBOX_API const char * chatterbox_version(void);

#ifdef __cplusplus
}
#endif

#endif  // CHATTERBOX_FFI_H
