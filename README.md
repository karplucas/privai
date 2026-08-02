# PrivAI

A Flutter chat app that runs entirely on-device: a Gemma language model through
MediaPipe, Whisper for speech-to-text, and Kokoro for speech synthesis. Nothing
you type or say leaves the phone — the only network traffic is downloading the
models themselves from Hugging Face.

## Downloading the Gemma model

The Gemma models are published in **gated** Hugging Face repositories. Google
requires every user to read and accept the [Gemma Terms of
Use](https://ai.google.dev/gemma/terms) before the weights can be downloaded, and
Hugging Face enforces that per account. The app does not and cannot bypass this:
it detects the gate, sends you to Hugging Face's own consent page, and unlocks
the download only after Hugging Face confirms your account has access.

The flow in the app, under **Settings & models**:

1. **Sign in to Hugging Face.** Either OAuth (see below) or a personal access
   token with `read` scope from
   [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens).
2. **Review the license.** Gated models show a "Review license" button. It
   explains the requirement and opens the model page on huggingface.co.
3. **Accept on Hugging Face.** Acknowledge Google's terms there, signed in with
   the same account.
4. **Return and re-check.** The app re-queries Hugging Face. Once access is
   granted the tile switches to a Download button.

Access is verified again immediately before any bytes are transferred, so a
stale screen cannot start a download the account is not entitled to. Downloads
are streamed to disk, resume after an interruption, and can be cancelled.

Some gated repositories use *manual* approval, where a human reviews the request.
In that case the re-check keeps reporting the model as restricted until the
request is approved; try again later.

### Optional: Hugging Face OAuth

Signing in with a pasted access token works out of the box. To offer the nicer
"Sign in with Hugging Face" button instead, register a Connected App at
[huggingface.co/settings/connected-applications](https://huggingface.co/settings/connected-applications):

- Redirect URI: `privai://oauth-callback`
- Scopes: `openid profile read-repos`

Then build with the client id:

```bash
flutter run --dart-define=HF_CLIENT_ID=your_client_id
```

The flow uses PKCE and no client secret — a secret embedded in a distributed app
binary is not a secret. If `HF_CLIENT_ID` is not set, only the access-token
option is shown.

If you change the callback scheme, update it in all three places:
`HuggingFaceService.callbackScheme`, the `android:scheme` in
`android/app/src/main/AndroidManifest.xml`, and `CFBundleURLSchemes` in
`ios/Runner/Info.plist`.

## Text-to-speech setup

Kokoro needs four files. Which of them can be downloaded is decided by
[`kokoro_tts_flutter`](https://pub.dev/packages/kokoro_tts_flutter), not by this
app: it reads most of them through `rootBundle`, and the asset bundle is baked
into the APK, so a file fetched at runtime is invisible to it. Only the ONNX
weights are read from a plain filesystem path.

| File | Size | How it is loaded | Where it comes from |
| --- | --- | --- | --- |
| `kokoro.onnx` | 310 MB | filesystem path *or* asset | **Downloaded** through the models page |
| voice style vectors | ~510 KB each | `rootBundle` only | **Downloaded** per voice, then served as an asset |
| `tokenizer_vocab.json` | 1.4 KB | `rootBundle`, hardcoded path | Committed to this repo |
| `lexicon.json` | 907 B | `rootBundle`, optional | Committed to this repo |

Nothing has to be placed by hand. Both large files are downloaded on demand, so
a fresh clone builds and runs.

The weights come from the `kokoro-onnx` release asset
[`kokoro-v1.0.onnx`](https://github.com/thewh1teagle/kokoro-onnx/releases/tag/model-files-v1.0)
(326 MB) — the one file on GitHub rather than the Hub. **Do not substitute the
`onnx-community/Kokoro-82M-v1.0-ONNX` export.** It contains the same weights, but
its output is 2-D, and `kokoro_tts_flutter` casts each output element directly to
`double`, so synthesis fails with:

```
Failed to run inference: type 'Float32List' is not a subtype of type 'double' in type cast
```

The engine reports itself ready and only fails per utterance, so this is easy to
misdiagnose as an audio problem. A test pins the URL.

If you would rather bundle the weights, drop them at `assets/kokoro.onnx` and
that is preferred over the downloaded copy.

### How voices are downloaded despite being asset-only

`kokoro_tts_flutter` reads its voice table from `assets/voices.json` via
`rootBundle`, and `rootBundle` only sees files compiled into the app. Bundling
the whole table costs 52 MB. Two things get around that:

- **`AssetOverrideBinding`** (`lib/services/asset_bundle_override.dart`) makes a
  file on disk answer for an asset key. `rootBundle` is `final` and cannot be
  replaced, but `PlatformAssetBundle.load` fetches bytes over the
  `flutter/assets` platform channel, and `ServicesBinding.createBinaryMessenger`
  is `@protected` — so a binding subclass can intercept exactly that one
  channel. Any other channel, and any asset key without a registered override,
  passes straight through; a missing override file falls back to the real
  bundle.
- **`VoicePackService`** downloads `voices/<id>.bin` (~510 KB each) from the Hub
  and assembles the selected voices into the JSON shape the package expects.

The `.bin` files are little-endian float32 `rows x 256`; the package wants
`[rows][1][256]`. The decoder was checked against a real bundled `voices.json`:
for the `af` voice the values are bit-identical across all 511 shared rows, only
the container differs. `Voice.getStyleVectorForTokens` clamps its index to the
table length, so the 510-row and 512-row layouts the Hub publishes are both
fine.

Two default voices (~1 MB) are fetched on first use. A bundled
`assets/voices.json` still wins if one is present, so existing installs are
untouched.

The pronunciation dictionaries (`us_gold.json`, `us_silver.json` and their `gb_`
counterparts) are a trap. `malsami` declares them in its own pubspec, so they are
built in under `packages/malsami/assets/…` — but `Lexicon` reads them back from
the *application's* root asset namespace, without the package prefix. If nothing
answers for `assets/us_gold.json`, speech fails at synthesis time with
`Unable to load asset`, long after the engine reports itself ready.

`KokoroTtsService` registers an alias from each root key onto the package copy,
so the app does not have to ship a second ~6 MB of identical files. A real
`assets/us_gold.json` still takes precedence if you want a custom lexicon.

Lifting `voices.json` into the download flow needs an upstream change to
`kokoro_tts_flutter` — `Kokoro.initialize()` calls `_loadVoices()`
unconditionally, and that method only reads `rootBundle`.

## Speech engines

Three backends sit behind `TtsEngine`, selectable under **Settings & models**.

Model files download through native background transfers: `URLSession` on iOS
and the platform download worker on Android. Transfers continue when the app is
backgrounded or the phone locks, retry transient failures three times, and use
the operating system's resumable temporary storage. A user force-quitting the
app on iOS still cancels its scheduled transfers, as required by iOS.

| | Kokoro 82M | Chatterbox Nano | OmniVoice Hybrid |
| --- | --- | --- | --- |
| Download | 326 MB, one file | 570 MB, 10 files | 2.16 GB, 9 files |
| Languages | US/UK English, Japanese, Mandarin, Spanish, Hindi, Italian, Brazilian Portuguese | English | 646 |
| Voice cloning | no | yes, from reference audio | not in the compact bundle |
| Speed | near-realtime | streamlined autoregressive + one-step decoder | 12 guided refinement passes + decoder |
| Memory | modest | >1 GB of ONNX sessions | language model is unloaded around use |

Kokoro stays the default. Chatterbox is opt-in because of the second and last
rows: it is an order of magnitude slower and its sessions will not co-reside with
a multi-gigabyte language model on a phone. `TtsRouter` therefore unloads the
language model around a Chatterbox utterance and reloads it in a `finally`, so a
synthesis failure cannot leave the chat unable to reply. It is also not warmed up
at start-up, which would evict the language model before you had said anything.

Chatterbox support is ONNX-only. The former GGUF/`codec.cpp` backend, its native
patches, and its separate iOS/Android build steps have been removed.

OmniVoice uses the corrected FP32 bidirectional language backbone from
[dellusional/OmniVoice-ONNX-bidirectional](https://huggingface.co/dellusional/OmniVoice-ONNX-bidirectional),
plus the verified full-precision audio embedding/head graphs and FP16 Higgs
decoder from [onnx-community/OmniVoice-Onnx](https://huggingface.co/onnx-community/OmniVoice-Onnx).
The former INT4 language graph was causal: future masked positions could not
influence earlier positions, so diffusion collapsed into repeated codec tokens
and the decoder produced screaming or horn-like noise. The corrected backbone
accepts OmniVoice's real four-dimensional bidirectional attention matrix.
Only its built-in automatic voice is downloaded. Reference-voice cloning would
require the additional acoustic, semantic, and quantizer encoders; those are
deliberately excluded until the app has a reference-audio voice workflow.
No small export is currently offered because the available compact graph is the
incorrect causal export. The working FP32 model is non-commercial
(CC-BY-NC-4.0); the Higgs decoder also carries separate Boson/Meta community
terms.
The refinement-step selector offers 5–32 passes and defaults to 12. Runtime is
roughly proportional to this setting; 32 remains available when quality matters
more than latency.
On iOS and macOS, the expensive bidirectional backbone requests ONNX Runtime's
Core ML execution provider with CPU fallback. Core ML may place compatible
partitions on the GPU or Neural Engine, but its default API chooses the compute
unit and unsupported operators remain on CPU. Android currently uses CPU.

The optional **Keep Chatterbox loaded** setting avoids unloading and reloading
Gemma around every utterance. It is off by default: enable it only with a small
language model on a high-memory device. When it is off, the router fully closes
the Chatterbox ONNX sessions before restoring Gemma.

Kokoro receives LLM output at sentence boundaries, starts speaking during
generation, and serializes ONNX inference while pipelining the next sentence's
synthesis with playback through one reusable audio player. It also runs one
unplayed inference prewarm after loading. Run-on text is split at a word
boundary after 220 characters. Chatterbox and OmniVoice synthesize one continuous
waveform per reply. Their current ONNX decoders expose no causal streaming state;
progressively replaying separate WAV prefixes produced audible gaps at arbitrary
token boundaries, so that experiment was removed in favor of uninterrupted
prosody.

### Hands-free voice conversation

The waveform button beside the message field opens a dedicated voice screen
with a large center orb that reacts to microphone level and shows whether the
app is listening, understanding, or responding. The app records 16 kHz mono
audio until speech is followed by
about 1.2 seconds of silence, transcribes it with Whisper, sends the transcript to
the LLM, speaks the response, and then begins listening again without another tap.
It waits up to 12 seconds for speech and caps an individual turn at 30 seconds.
The conversation status and an explicit Stop control remain visible above the
composer while the mode is active.
During a response the microphone remains active. Sustained speech stops both
token generation and audio playback, transcribes the interruption, and
immediately uses it as the next conversational turn. A sustained-speech gate
reduces false interruptions from brief sounds.

Interruption monitoring closes before synthesized audio begins. The current
file-recorder backend has no acoustic echo cancellation on iOS; leaving it open
during playback made the assistant transcribe its own voice and enter a feedback
loop. Barge-in therefore interrupts token generation today, while spoken-audio
barge-in remains disabled until capture moves to an echo-cancelled stream.

Opening and closing Settings preserves resident LLM, STT, and TTS sessions. A
dormant TTS engine is not loaded just to populate its voice list; engine changes
take effect lazily on first use, and the LLM is reloaded only when the selected
model file changes.

### Whisper native patch

`whisper_ggml` is resolved from `third_party/whisper_ggml` rather than the Pub
cache. The vendored 2.4.0 source bypasses FFmpeg when input is already WAV and
captures the WAV channel count before `drwav_uninit`; this avoids an extra
native-memory peak and a post-teardown metadata read at transcription startup.
It also keeps the existing iOS FFI response-allocation and invalid-UTF-8 fixes
reproducible on clean machines.

To remove the vendored patch after upstream incorporates all of those fixes,
delete the `whisper_ggml` path entry under `dependency_overrides`, remove
`third_party/whisper_ggml`, run `flutter pub get`, and regenerate CocoaPods with
`pod install` from `ios/`. Keep the Podfile's `_request` linker retention until
upstream stops resolving that symbol through `DynamicLibrary.process()`.

### Chatterbox Nano pipeline

Four community ONNX graphs from
[owensong/chatterbox-nano-ONNX](https://huggingface.co/owensong/chatterbox-nano-ONNX),
derived from [ResembleAI/chatterbox-nano](https://huggingface.co/ResembleAI/chatterbox-nano):

1. `embed_tokens_fp16` — GPT-2 text/speech ids → `inputs_embeds[1,S,768]`
2. `language_model_q4f16` — embeds, attention/position ids, and 12 FP16
   KV-cache layers
   → `logits[1,S,6563]`, decoded autoregressively at **25 Hz**
3. `speech_encoder_q4f16` — reference audio → conditioning prefix, reference
   speech tokens, speaker embedding, and speaker features
4. `conditional_decoder_q4` — reference and generated speech tokens plus three
   trailing silence tokens → a 24 kHz waveform in one distilled pass

The language model is conditioned by prepending the speech encoder's features
to the text embeddings. Its 24 cache tensors remain in native ONNX Runtime
memory between steps. Decoding is greedy after the official 1.2 repetition
penalty and stops only on speech token 6562.

Nano uses GPT-2 byte-level BPE, appends two `<|endoftext|>` tokens, and is
English-only. Native performance tags include `[laugh]`, `[chuckle]`, `[cough]`,
`[sigh]`, `[gasp]`, and `[whispering]`. Each Q4 graph requires its matching
`.onnx_data` sidecar in the same directory.

After Nano has loaded successfully once, the obsolete Turbo and Multilingual
bundles are deleted to reclaim disk space. They can be recovered only by
downloading those retired bundles again from their Hugging Face repositories.

## Architecture

```
lib/
  main.dart                        App shell and theming
  models/
    model_spec.dart                Typed catalog entry; derives download and
                                   license URLs from one repo id
  services/
    app_settings.dart              Every persisted preference, with one place
                                   for each default
    model_storage.dart             The single source of truth for where models
                                   live on disk
    model_catalog.dart             Parses assets/models_list.json
    huggingface_service.dart       Auth, gated-access checks, resumable
                                   downloads
    llm_service.dart               Gemma inference session
    whisper_service.dart           Recording and transcription
    kokoro_tts_service.dart        Speech synthesis
    conversation_service.dart      File-backed chat history
  ui/
    chat_page.dart                 Chat screen
    models_page.dart               Settings and model downloads
    widgets/                       Model tile, sign-in sheet
```

Services are singletons that own a resource and expose a single-flight
`initialize`/`reload`, so concurrent callers share one load rather than racing.
They are owned by the app, not by any screen, and are therefore not disposed when
a widget is torn down.

`assets/models_list.json` is the catalog. Each entry names a Hugging Face `repo`
and a `file` within it; the download URL and the license page are both derived
from those, so the terms a user accepts always govern the file that gets
downloaded. Gated entries carry `"gated": true` plus a `license` and
`licenseNote`.

## Storage

- **Models** — the app's own external files directory
  (`getExternalStorageDirectory()`), which needs no storage permission and is
  removed on uninstall.
- **Chat history** — a JSON file in the app support directory, written through a
  temp file and an atomic rename.
- **Settings and the Hugging Face token** — `flutter_secure_storage`.

## Running

```bash
flutter pub get
flutter run

flutter analyze
flutter test
flutter test integration_test/    # needs a connected device
```

Android `minSdkVersion` is 26. The app requests only `INTERNET`,
`ACCESS_NETWORK_STATE`, `RECORD_AUDIO` and `MODIFY_AUDIO_SETTINGS`.

## Tests

`flutter test` covers the catalog and its gating metadata, settings defaults and
clamping, model storage paths, conversation persistence and migration, and the
chat screen shell. Tests do not assert on model output: no weights are present in
a test run, so anything claiming to send a message and receive a reply would be
asserting on a stub. `integration_test/` covers start-up, navigation and the
model list on a real device, and checks that no gated model offers a download
button while signed out.
