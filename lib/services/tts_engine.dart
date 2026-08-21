/// Which speech-synthesis backend to use.
enum TtsEngineKind {
  /// Kokoro 82M: ~326 MB, near-realtime, the default.
  kokoro,

  /// Chatterbox Nano: roughly 570 MB across four ONNX graphs, English,
  /// performance tags, and voice cloning. Its runtime tensors are still heavy
  /// enough that the language model has to be unloaded while it runs.
  chatterbox,

  /// OmniVoice hybrid: a multilingual masked-codebook model. Its verified FP32
  /// backbone preserves the bidirectional attention required by diffusion.
  /// This integration uses its built-in automatic voice, not cloning encoders.
  omnivoice,

  /// The same Chatterbox model through llama.cpp + codec.cpp instead of ONNX
  /// Runtime.
  ///
  /// Measured on a desktop CPU against the ONNX pipeline: 60 ms per speech
  /// token at eight threads. The win is threading and a 4-bit GGUF, not an
  /// accelerator — offloading the decode loop to a GPU measured *slower*,
  /// because autoregressive decode dispatches one token at a time and never
  /// builds a batch wide enough to pay for the round trip.
  chatterboxGguf,

  /// Meta's MMS: one small VITS model per language, 114 MB and faster than
  /// real time, at 16 kHz and with a single voice.
  mms,

  /// Supertonic 3: a 99M flow-matching model, 44.1 kHz, ten voices and 31
  /// languages. Several times faster than Chatterbox — a fixed eight passes
  /// per clip rather than one per 40 ms of audio — but it has no Chinese.
  supertonic;

  static TtsEngineKind fromName(String? name) {
    for (final kind in TtsEngineKind.values) {
      if (kind.name == name) return kind;
    }
    return TtsEngineKind.kokoro;
  }

  String get label => switch (this) {
        TtsEngineKind.kokoro => 'Kokoro 82M',
        TtsEngineKind.chatterbox => 'Chatterbox Nano (ONNX)',
        TtsEngineKind.omnivoice => 'OmniVoice Multilingual (ONNX)',
        TtsEngineKind.chatterboxGguf => 'Chatterbox Multilingual (GGUF)',
        TtsEngineKind.mms => 'Meta MMS-TTS (ONNX)',
        TtsEngineKind.supertonic => 'Supertonic 3 (ONNX)',
      };

  String get description => switch (this) {
        TtsEngineKind.kokoro =>
          '326 MB • near-realtime • English (US/UK), Japanese, Mandarin Chinese, Spanish, Hindi, Italian, Brazilian Portuguese',
        TtsEngineKind.chatterbox =>
          '570 MB • Q4F16 • English, voice cloning and performance tags',
        TtsEngineKind.omnivoice =>
          '638 MB–2.16 GB • very slow • automatic voice • 646 languages',
        TtsEngineKind.chatterboxGguf =>
          '491 MB • 23 languages • voice cloning • native decode loop',
        TtsEngineKind.mms =>
          '114 MB • fp32 • faster than real time • 16 kHz • one voice per language • non-commercial use only',
        TtsEngineKind.supertonic =>
          '401 MB • ~5x faster than real time • 44.1 kHz • 10 voices • 31 languages, not including Chinese',
      };

  /// Whether this engine needs the language model unloaded to fit in memory.
  bool get requiresExclusiveMemory =>
      this == TtsEngineKind.chatterbox ||
      this == TtsEngineKind.chatterboxGguf ||
      this == TtsEngineKind.omnivoice;
}

/// Common surface every speech-synthesis backend exposes.
///
/// Extracted so a second engine could be added without the chat screen or the
/// settings page knowing which one is active. Implementations are singletons
/// that own native resources, so they follow the same single-flight
/// `initialize`/`reload` contract as the rest of the services.
abstract class TtsEngine {
  TtsEngineKind get kind;

  /// True once synthesis can be requested.
  bool get isInitialized;

  /// Prepares the engine. Concurrent callers share one initialisation; pass
  /// [force] to discard a cached failure and retry.
  Future<void> initialize({bool force = false});

  /// Reloads after a model or settings change.
  Future<void> reload();

  /// Whether the loaded model no longer matches the current selection.
  Future<bool> get isStale;

  /// Speaks [text], falling back to the user's configured voice, language and
  /// speed for any argument left null.
  Future<void> speak(String text, {String? voice, String? lang, double? speed});

  /// Stops playback immediately.
  Future<void> stop();

  /// Voice identifiers this engine can currently use. Empty when it is not
  /// ready or has no fixed set.
  Future<List<String>> availableVoices();

  /// Releases native resources. Only at app shutdown — these are singletons.
  Future<void> dispose();
}
