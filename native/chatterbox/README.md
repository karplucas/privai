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
and never assembles a batch wide enough to repay the dispatch. The build flag
and the in-app toggle exist so this can be re-tested on a phone, where unified
memory removes the transfer, but do not expect a win from it. See
[Vulkan on Android](#vulkan-on-android) — it is off by default for a reason
beyond performance.

## Layout

```
src/chatterbox_ffi.{h,cpp}   C boundary over codec_common::tts_runner_synthesize
CMakeLists.txt               builds codec.cpp + the isolated backbone + the shim
vendor/codec.cpp             submodule
patches/codec.cpp.patch      local codec.cpp changes
patches/llama.cpp-vulkan.patch  Vulkan fix for codec.cpp's nested llama.cpp
```

Android builds this via `android/app/build.gradle`'s `externalNativeBuild`,
for arm64-v8a and x86_64 — the models need more address space than a 32-bit
process has, and the x86_64 slice is what makes the engine usable on an
emulator.

## Applying the vendor patches

The repository pins `codec.cpp` as a submodule, so the Chatterbox integration
is stored as patches rather than committed inside `vendor/codec.cpp`. From the
repository root, initialize all submodules and apply both patches:

```bash
git submodule update --init --recursive
git -C native/chatterbox/vendor/codec.cpp \
    apply --check ../../patches/codec.cpp.patch
git -C native/chatterbox/vendor/codec.cpp \
    apply ../../patches/codec.cpp.patch
git -C native/chatterbox/vendor/codec.cpp/common/third-party/llama.cpp \
    apply --check ../../../../../patches/llama.cpp-vulkan.patch
git -C native/chatterbox/vendor/codec.cpp/common/third-party/llama.cpp \
    apply ../../../../../patches/llama.cpp-vulkan.patch
```

The `--check` commands make the process fail before modifying a submodule if a
patch no longer matches its pinned revision. A second application is expected
to fail because the changes are already present. To confirm that situation,
use `git apply --reverse --check` with the same path.

## Platform status

| | builds | runs | measured |
| --- | --- | --- | --- |
| Linux x86_64 | yes | yes | 60 ms/token, 8 threads |
| Android x86_64 (emulator) | yes | yes | 308 ms/token via CLI, 496 in-app at 3 threads |
| Android arm64 | yes | untested | — |
| Android + Vulkan | yes | yes | 153 ms/token (emulator, dGPU passthrough) |
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

## Vulkan on Android

Works, and built in by default. The in-app switch selects it at runtime.

Measured on the emulator (x86_64, GPU passed through to an RTX 5080), two
points per configuration:

| | per token | fixed |
| --- | --- | --- |
| Vulkan | **153 ms** | ~20.5 s |
| CPU, 4 threads | 270 ms | ~20.8 s |

Do not read 1.77x as what a phone will do. This pits a virtualised x86 CPU
against a desktop GPU; a phone has a far weaker GPU sharing a die with a far
stronger CPU. It does establish that the GPU path runs correctly on Android
and that dispatch overhead does not automatically sink it — the opposite of
the desktop result, where a 5080 lost to eight native CPU threads.

### The bug that made it look impossible

`ggml_vk_get_device` requested `VK_KHR_16bit_storage` unconditionally, gated
only on the *feature* `storageBuffer16BitAccess`. That extension was promoted
to core in Vulkan 1.1, so a 1.1+ driver may support the feature without
advertising the extension string — and asking for an unadvertised extension
fails `createDevice` with `ErrorExtensionNotPresent`. ggml already detects the
real extension into `fp16_storage`; the fix is to use it.
See `patches/llama.cpp-vulkan.patch`, which applies to the nested llama.cpp submodule
(not codec.cpp — a separate patch for a separate repository).

Until that was found, a Vulkan build died at *library load*, before anything
asked for a GPU, taking the CPU path down with it. That risk is not fully
gone: ggml still creates a Vulkan device eagerly, so a driver it cannot
satisfy for some other reason would crash the app even with the switch off.
Opt out with `-Pchatterbox.vulkan=false`. Making it survivable would need
`GGML_BACKEND_DL`, so the backend loads only when the GPU is requested.

### What it took to compile

- **Vulkan-Hpp is not in the NDK**, which ships only the C headers.
- **The version is not free.** Vulkan-Hpp static-asserts `VK_HEADER_VERSION`
  against the C headers it sits on (the NDK's are 275), and releases past
  ~1.3.275 dropped API this llama.cpp uses — it streams a `vk::Buffer` to an
  ostream. `CMakeLists.txt` fetches exactly 1.3.275; the distro's 341 fails
  both ways.
- **`spirv/unified1/spirv.hpp` is included directly**, and
  `find_package(SPIRV-Headers)` does not put it on that file's compile line.
- **`SPIRV-Headers` is invisible** to the nested build, because the NDK
  toolchain sets `CMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY`.
- **ggml-vulkan does not compile for 32-bit.** Non-dispatchable handles are
  `uint64_t` there, making Vulkan-Hpp's conversion explicit and breaking that
  same ostream call. 64-bit only, set through
  `externalNativeBuild.cmake.abiFilters` — the `ndk` block alone does not
  decide which ABIs CMake runs for.

`vulkan-shaders-gen` needs no special handling: llama.cpp detects a host
compiler and builds it with a generated host toolchain when cross-compiling.

## NPU

There is no path through this stack. llama.cpp has no NPU backend upstream —
Qualcomm's QNN work is not merged and NNAPI was removed. The nearest
alternative is **OpenCL**, which llama.cpp does support and which targets
Adreno directly; it would be the same shape of work as Vulkan.

Whether any of it is worth finishing is a separate question from whether it
builds. Autoregressive decode dispatches one token at a time and never
assembles a batch wide enough to repay a GPU round trip — an RTX 5080 lost to
eight CPU threads by 32%. Threads are the lever that measurably works: 4.8x on
desktop, and the in-app run at 3 threads was 496 ms/token against 308 ms/token
for the same model at 4.

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
