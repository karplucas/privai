/// Which speech-recognition backend transcribes a recording.
enum SttEngineKind {
  /// whisper.cpp through `whisper_ggml`, using the GGML weights.
  whisper,

  /// NVIDIA Parakeet TDT, run as ONNX graphs by this app directly.
  parakeet;

  static SttEngineKind fromName(String? name) {
    for (final kind in SttEngineKind.values) {
      if (kind.name == name) return kind;
    }
    return SttEngineKind.whisper;
  }

  String get label => switch (this) {
        SttEngineKind.whisper => 'Whisper (whisper.cpp)',
        SttEngineKind.parakeet => 'Parakeet TDT (ONNX)',
      };
}

/// Common surface every speech-recognition backend exposes.
///
/// The chat screen talks to [SpeechToTextService] rather than to an engine, so
/// adding a backend does not change any call site. Implementations are
/// singletons that own native sessions and follow the same single-flight
/// `initialize` contract as the rest of the services.
abstract class SttEngine {
  SttEngineKind get kind;

  /// True once a model is loaded and transcription can be requested.
  bool get isReady;

  /// Prepares the engine, reusing an in-flight initialisation. Pass [force] to
  /// discard a cached failure or a stale model and load again.
  Future<void> initialize({bool force = false});

  /// Transcribes the 16 kHz mono WAV file at [audioPath].
  ///
  /// [language] falls back to the user's configured STT language. Engines that
  /// detect the language themselves may ignore it.
  Future<String> transcribeFromFile(String audioPath, {String? language});

  /// Releases the loaded model, keeping the engine usable after a later
  /// [initialize]. Called when the user switches to a different engine so two
  /// sets of weights are never resident at once.
  Future<void> unload();
}

/// Raised when transcription is attempted before a model is usable.
class SttNotReadyException implements Exception {
  const SttNotReadyException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}
