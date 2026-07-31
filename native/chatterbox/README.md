# Chatterbox GGUF engine

Chatterbox Multilingual through llama.cpp + [codec.cpp](https://github.com/mybigday/codec.cpp)
instead of ONNX Runtime, behind a `dart:ffi` boundary.

Measured against the ONNX engine on the same desktop CPU: **60 ms per speech
token at eight threads.** Two things produce that, and neither is an
accelerator:

- **Threads.** The single largest factor. Left at the runtime's default the
  same build measures 289 ms/token — a 4.8x difference from the flag alone.
- **A 4-bit GGUF driven entirely in native code.** The ONNX engine runs its
  decode loop from Dart, paying a platform-channel round trip for each of the
  25 speech tokens per second of audio.

**GPU offload measured *slower*** — 24.2 s against 18.3 s for the same
utterance on an RTX 5080. Autoregressive decode dispatches one token at a time
and never assembles a batch wide enough to repay the dispatch. `CHATTERBOX_VULKAN`
and the in-app toggle exist so this can be re-tested on a phone, where unified
memory removes the transfer, but do not expect a win from it.

## Layout

```
src/chatterbox_ffi.{h,cpp}   C boundary over codec_common::tts_runner_synthesize
CMakeLists.txt               builds codec.cpp + the isolated backbone + the shim
vendor/codec.cpp             submodule
codec.cpp.patch              local changes to the submodule (see below)
```

Android builds this via `android/app/build.gradle`'s `externalNativeBuild`.
Debug builds produce arm64-v8a, armeabi-v7a and x86_64; only arm64 is worth
shipping, since the models need more address space than a 32-bit process has,
but the x86_64 slice is what makes the engine usable on an emulator.

## Platform status

| | builds | runs | measured |
| --- | --- | --- | --- |
| Linux x86_64 | yes | yes | 60 ms/token, 8 threads |
| Android x86_64 (emulator) | yes | yes | 308 ms/token, 4 threads |
| Android arm64 | yes | untested | — |
| iOS | **unverified** | — | — |

**The iOS support has never been compiled.** It was written on a Linux machine
with no Xcode, adapted from the working Android build. The CMake parses and the
build script is syntactically valid; nothing beyond that is known. Treat
`ios/build_xcframework.sh` as a starting point, not a working build.

What had to change for Apple, and why each is a real difference rather than a
guess:

- **No version scripts.** `--version-script` is GNU-only; ld64 wants
  `-exported_symbols_list`, which takes *mangled* names with the leading
  underscore — hence `_llama_*` and a `*common_sampler*` glob instead of an
  `extern "C++"` block.
- **`--whole-archive` does not exist**; `-all_load` is the equivalent, and
  applies to every archive on the line rather than a bracketed group.
- **`-shared` → `-dynamiclib`**, plus an `-install_name` of
  `@rpath/libttsbackbone.dylib` so it resolves from inside the app bundle.
- **Accelerate and Metal are frameworks**, named with `-framework`, not `-l`.
- **Metal shaders must be embedded** (`GGML_METAL_EMBED_LIBRARY=ON`); a
  `.metal` file located at runtime is no use inside a sandboxed app.

One thing that should be *easier* on Apple: the two-ggml collision that
segfaults under Vulkan is an ELF problem. Mach-O uses a two-level namespace, so
each dylib records which library every imported symbol comes from, and two
copies of ggml cannot interpose on each other the way they do with ELF's flat
global namespace. The symbol hiding is kept anyway, but it is belt-and-braces
there rather than load-bearing.

Metal is still off by default. It is the one case where GPU offload might pay —
unified memory means no per-dispatch transfer to repay, which is exactly what
made Vulkan a loss on a discrete GPU — but that is a hypothesis, not a
measurement.

## The submodule patches

`codec.cpp.patch` holds four changes. Reapply after bumping the submodule:

```bash
cd native/chatterbox/vendor/codec.cpp && git apply ../../codec.cpp.patch
```

1. **`lm.cpp` / `parallel_heads_delay.cpp`** — accept `lm.c0_head.weight` as an
   alias for `lm.heads_0.weight`. Only needed for GGUFs from older converters;
   harmless otherwise.
2. **`tts_runner.cpp`** — `n_gpu_layers` was pinned to 0 on the assumption the
   backbone is a small semantic LM not worth offloading. For Chatterbox T3 it
   is the entire decode loop, so it now follows the caller's `use_gpu`.
3. **`SetupTtsBackbone.cmake`** — Vulkan for the backbone is now a separate
   `CODEC_BACKBONE_VULKAN` option rather than hardcoded `OFF`, and when it is
   on, `libggml-vulkan.a` joins the wrapper's archive list and `-lvulkan` its
   link line. Without both the wrapper fails on `ggml_backend_vk_reg` and then
   on `vkGetInstanceProcAddr`.

Note that **enabling Vulkan on _both_ ggml instances segfaults** during tensor
load. codec.cpp's symbol hiding stops the two from linking against each other,
but not from each initialising its own Vulkan backend. Only the backbone may
have it — which is the configuration that would matter anyway.

## Models

Two files in the app's `chatterbox-gguf` bundle directory:

| file | size | what |
| --- | --- | --- |
| `chatterbox-mtl-t3-q4_k_m.gguf` | 302 MB | T3 token generator, stock `llama` arch |
| `chatterbox-mtl-codec-q4_k_m.gguf` | 180 MB | S3Gen + LM adaptor + tokenizer + voice encoder |

The backbone can be taken as published from
[hans00/Chatterbox-Multilingual-TTS-GGUF](https://huggingface.co/hans00/Chatterbox-Multilingual-TTS-GGUF).

**The codec file cannot.** The published one is missing three things and fails
at load or at prompt build:

- no BPE tokenizer baked in → `chatterbox: no tokenizer baked into GGUF`
- no voice encoder and no built-in conditioning → `no speaker_emb and no builtin conds`
- `lm.c0_head.weight` where current codec.cpp expects `lm.heads_0.weight`

Convert it from the official checkpoint instead. Download `t3_mtl23ls_v3.safetensors`,
`s3gen.safetensors`, `ve.safetensors` and `conds.pt` from
[ResembleAI/chatterbox](https://huggingface.co/ResembleAI/chatterbox) into one
directory, and put a `tokenizer.json` beside them — use the one from
[onnx-community/chatterbox-multilingual-ONNX](https://huggingface.co/onnx-community/chatterbox-multilingual-ONNX),
**not** the repo's own `mtl_tokenizer.json`. Both agree on every shared id, but
the ONNX copy has 2454 tokens against 2352, matching the model's text-embedding
width; the extra 102 are accented characters that would otherwise tokenize as
`[UNK]`. Then:

```bash
pip install -r vendor/codec.cpp/requirements.txt librosa
python vendor/codec.cpp/scripts/convert-to-gguf.py \
    --checkpoint-path <checkpoint-dir> \
    --model-type chatterbox_s3g \
    --lm-source <checkpoint-dir> \
    --quantization Q4_K_M \
    --output chatterbox-mtl-codec-q4_k_m.gguf
```

Expect it to report `tokenizer: 2454 tokens`, `builtin conds: speaker_emb=(256,)`
and `Speaker section: voice_encoder`. If any is absent the file will not work.

## Reference audio

Voice cloning takes **PCM 16-bit WAV only**; the loader rejects float WAVs,
including the `default_voice.wav` published alongside the ONNX model. Without a
reference the model uses the conditioning baked into the codec GGUF.
