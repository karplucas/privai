/// Which speech-synthesis backend to use.
enum TtsEngineKind {
  /// Kokoro 82M: ~326 MB, near-realtime, the default.
  kokoro,

  /// Chatterbox Multilingual: ~1.5 GB across several ONNX graphs, 23 languages
  /// and voice cloning, but roughly an order of magnitude slower and heavy
  /// enough that the language model has to be unloaded while it runs.
  chatterbox,

  /// The same Chatterbox model through llama.cpp + codec.cpp instead of ONNX
  /// Runtime.
  ///
  /// Measured on a desktop CPU against the ONNX pipeline: 60 ms per speech
  /// token at eight threads, where ONNX Runtime's CPU provider manages nothing
  /// close. The win is threading and a 4-bit GGUF, not an accelerator —
  /// offloading the decode loop to a GPU measured *slower*, because
  /// autoregressive decode dispatches one token at a time and never builds a
  /// batch wide enough to pay for the round trip.
  chatterboxGguf;

  static TtsEngineKind fromName(String? name) {
    for (final kind in TtsEngineKind.values) {
      if (kind.name == name) return kind;
    }
    return TtsEngineKind.kokoro;
  }

  String get label => switch (this) {
        TtsEngineKind.kokoro => 'Kokoro 82M',
        TtsEngineKind.chatterbox => 'Chatterbox Multilingual (ONNX)',
        TtsEngineKind.chatterboxGguf => 'Chatterbox Multilingual (GGUF)',
      };

  String get description => switch (this) {
        TtsEngineKind.kokoro =>
          '326 MB • near-realtime • English and a few other locales',
        TtsEngineKind.chatterbox =>
          '1.5 GB • slower • 23 languages, voice cloning',
        TtsEngineKind.chatterboxGguf =>
          '480 MB • ~12x faster than the ONNX build • 23 languages, '
              'voice cloning',
      };

  /// Whether this engine needs the language model unloaded to fit in memory.
  bool get requiresExclusiveMemory =>
      this == TtsEngineKind.chatterbox || this == TtsEngineKind.chatterboxGguf;
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
