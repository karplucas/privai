#include "chatterbox_ffi.h"

#include "tts_runner.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <string>

namespace {

/// Copies [s] onto the heap so the caller can read it after the C++ result
/// object is gone. Freed by chatterbox_result_free.
char * dup_c(const std::string & s) {
    char * out = (char *) std::malloc(s.size() + 1);
    if (out == nullptr) return nullptr;
    std::memcpy(out, s.c_str(), s.size() + 1);
    return out;
}

const char * or_empty(const char * s) { return s == nullptr ? "" : s; }

}  // namespace

extern "C" {

int32_t chatterbox_synthesize(const chatterbox_params * params,
                              chatterbox_result * out) {
    if (out == nullptr) return -1;
    *out = chatterbox_result{};
    if (params == nullptr) {
        out->error = dup_c("chatterbox_synthesize: params is NULL");
        return -1;
    }

    codec_common::tts_runner_params p;
    p.codec_path     = or_empty(params->codec_path);
    p.backbone_path  = or_empty(params->backbone_path);
    p.text           = or_empty(params->text);
    p.ref_audio_path = or_empty(params->ref_audio_path);
    p.n_threads      = params->n_threads;
    p.use_gpu        = params->use_gpu != 0;
    p.seed           = params->seed;
    p.max_frames     = params->max_frames;

    // The runner gates every optional knob behind a has_* flag so that unset
    // ones fall back to the values the model was trained with, rather than to
    // whatever this struct happened to be zero-initialised with.
    if (params->cfg_weight >= 0.0f) {
        p.has_cfg_weight = true;
        p.cfg_weight     = params->cfg_weight;
    }
    if (params->temperature >= 0.0f) {
        p.has_temp = true;
        p.temp     = params->temperature;
    }

    codec_common::tts_runner_result r;
    bool ok = false;
    try {
        ok = codec_common::tts_runner_synthesize(p, &r);
    } catch (const std::exception & e) {
        // The runner reports failure by return value, but it sits on top of
        // two ggml runtimes and llama.cpp; an exception crossing the FFI
        // boundary would take the whole app down instead of failing one
        // utterance.
        out->error = dup_c(std::string("chatterbox: ") + e.what());
        return -1;
    } catch (...) {
        out->error = dup_c("chatterbox: unknown native exception");
        return -1;
    }

    if (!ok || !r.error.empty()) {
        out->error = dup_c(r.error.empty() ? "chatterbox: synthesis failed"
                                           : r.error);
        return -1;
    }

    const size_t n = r.pcm.size();
    if (n > 0) {
        out->pcm = (float *) std::malloc(n * sizeof(float));
        if (out->pcm == nullptr) {
            out->error = dup_c("chatterbox: out of memory for PCM");
            return -1;
        }
        std::memcpy(out->pcm, r.pcm.data(), n * sizeof(float));
    }
    out->n_samples   = (int32_t) n;
    out->sample_rate = r.sample_rate;
    out->n_frames    = r.n_frames;
    return 0;
}

void chatterbox_result_free(chatterbox_result * result) {
    if (result == nullptr) return;
    std::free(result->pcm);
    // Cast away const: the string was malloc'd by dup_c above.
    std::free(const_cast<char *>(result->error));
    *result = chatterbox_result{};
}

const char * chatterbox_version(void) { return "chatterbox-ffi 0.1.0"; }

}  // extern "C"
