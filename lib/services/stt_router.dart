import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'app_settings.dart';
import 'model_catalog.dart';
import 'parakeet_stt_service.dart';
import 'stt_engine.dart';
import 'whisper_service.dart';

/// Owns the microphone and routes transcription to the engine the selected
/// speech-to-text model belongs to.
///
/// The chat screen used to talk to [WhisperService] directly, which meant the
/// recorder and the choice of backend were the same object; adding a second
/// backend would have given the app two microphones. Recording lives here now
/// and the engines only transcribe files.
class SpeechToTextService {
  static final SpeechToTextService _instance = SpeechToTextService._();
  factory SpeechToTextService() => _instance;
  SpeechToTextService._();

  final AudioRecorder _audioRecorder = AudioRecorder();
  final AppSettings _settings = AppSettings();
  final ModelCatalog _catalog = ModelCatalog();

  final Map<SttEngineKind, SttEngine> _engines = {
    SttEngineKind.whisper: WhisperService(),
    SttEngineKind.parakeet: ParakeetSttService(),
  };

  bool _recordingTransition = false;
  SttEngineKind _active = SttEngineKind.whisper;

  /// The engine the current model selection resolves to.
  SttEngineKind get activeEngine => _active;

  /// True once the selected model is loaded and can transcribe.
  bool get isReady => _engines[_active]!.isReady;

  /// Which engine owns [filename], defaulting to Whisper for the GGML entries
  /// that predate the `engine` field.
  Future<SttEngineKind> _engineFor(String filename) async {
    try {
      final catalog = await _catalog.load();
      return SttEngineKind.fromName(catalog.byFilename(filename)?.engine);
    } catch (e) {
      debugPrint('SpeechToTextService: could not resolve an engine for '
          '$filename ($e); assuming Whisper');
      return SttEngineKind.whisper;
    }
  }

  /// Loads the selected model, unloading the other engine first.
  ///
  /// Both backends hold hundreds of megabytes of weights, so only the one in
  /// use is ever resident.
  Future<void> initialize({bool force = false}) async {
    final filename = await _settings.selectedSttModel;
    if (filename == null || filename.isEmpty) {
      throw const SttNotReadyException(
        'No speech-to-text model is selected. Open Manage Models to pick one.',
      );
    }

    final kind = await _engineFor(filename);
    if (kind != _active) {
      await _engines[_active]!.unload();
      _active = kind;
    }
    await _engines[kind]!.initialize(force: force);
  }

  /// Transcribes the WAV file at [audioPath] with the selected engine.
  Future<String> transcribeFromFile(String audioPath,
      {String? language}) async {
    await initialize();
    return _engines[_active]!
        .transcribeFromFile(audioPath, language: language);
  }

  /// Starts recording 16 kHz mono WAV, the format whisper.cpp consumes
  /// directly.
  Future<String> startRecording() async {
    if (_recordingTransition || await _audioRecorder.isRecording()) {
      throw const SttNotReadyException(
        'The microphone is already recording.',
      );
    }
    _recordingTransition = true;
    try {
      return await _startRecording();
    } finally {
      _recordingTransition = false;
    }
  }

  Future<String> _startRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      throw const SttNotReadyException(
        'Microphone permission is required to record.',
      );
    }

    final tempDir = await getTemporaryDirectory();
    final path =
        '${tempDir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';

    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    return path;
  }

  /// Stops recording and returns the file path, or null if nothing usable was
  /// captured.
  Future<String?> stopRecording() async {
    if (_recordingTransition) {
      throw const SttNotReadyException(
        'The microphone is still changing state.',
      );
    }
    _recordingTransition = true;
    String? path;
    try {
      path = await _audioRecorder.stop();
    } finally {
      _recordingTransition = false;
    }
    if (path == null) return null;

    final file = File(path);

    // Wait briefly for the OS to finish flushing the WAV header.
    for (var attempt = 0; attempt < 10; attempt++) {
      if (await file.exists() && await file.length() > 1000) {
        debugPrint('WhisperService: recorded ${await file.length()} bytes');
        return path;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    debugPrint('WhisperService: recording was empty, discarding');
    if (await file.exists()) await file.delete();
    return null;
  }

  Future<bool> get isRecording => _audioRecorder.isRecording();

  /// Current microphone level in dBFS for hands-free end-of-turn detection.
  Future<double> get currentAmplitudeDb async =>
      (await _audioRecorder.getAmplitude()).current;

  /// Releases the recorder and every loaded engine. Only call when the app is
  /// shutting down — this is a singleton shared across screens.
  Future<void> dispose() async {
    for (final engine in _engines.values) {
      await engine.unload();
    }
    await _audioRecorder.dispose();
  }
}
