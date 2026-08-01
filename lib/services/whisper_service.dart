import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'app_settings.dart';
import 'model_storage.dart';

/// Raised when transcription is attempted before a model is available.
class WhisperNotReadyException implements Exception {
  const WhisperNotReadyException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Records microphone audio and transcribes it with whisper.cpp.
class WhisperService {
  static final WhisperService _instance = WhisperService._();
  factory WhisperService() => _instance;
  WhisperService._();

  /// Kept for the existing `WhisperService.instance` call sites.
  static WhisperService get instance => _instance;

  final WhisperController _whisperController = WhisperController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();

  WhisperModel? _activeModel;
  Future<void>? _initialization;

  bool get isReady => _activeModel != null;

  /// Prepares the transcription model, reusing an in-flight initialisation.
  ///
  /// The previous implementation returned early while initialisation was still
  /// running, so a caller could proceed as though the model were loaded.
  Future<void> initialize({bool force = false}) {
    if (force) _initialization = null;
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final filename = await _settings.selectedSttModel;
      if (filename == null || filename.isEmpty) {
        throw const WhisperNotReadyException(
          'No speech-to-text model is selected. Open Manage Models to pick one.',
        );
      }

      final model = _modelFromFilename(filename);

      // whisper_ggml keeps its own copy in app-internal storage. If our
      // downloaded file is there but the plugin's is not, hand it over instead
      // of downloading the same weights a second time.
      final pluginFile = File(await _whisperController.getPath(model));
      if (!await pluginFile.exists()) {
        final downloaded = File(await _storage.pathFor(filename));
        if (await downloaded.exists()) {
          debugPrint('WhisperService: importing $filename into plugin storage');
          await pluginFile.parent.create(recursive: true);
          final sink = pluginFile.openWrite();
          try {
            await sink.addStream(downloaded.openRead());
          } finally {
            await sink.close();
          }
        } else {
          throw WhisperNotReadyException(
            'The speech-to-text model "$filename" has not been downloaded yet. '
            'Open Manage Models to download it.',
          );
        }
      }

      _activeModel = model;
      debugPrint('WhisperService: ready with ${model.name}');
    } catch (e) {
      // Allow a later attempt to retry rather than caching the failure.
      _activeModel = null;
      _initialization = null;
      debugPrint('WhisperService: initialisation failed: $e');
      rethrow;
    }
  }

  WhisperModel _modelFromFilename(String filename) {
    final name = filename.toLowerCase();
    if (name.contains('tiny')) return WhisperModel.tiny;
    if (name.contains('base')) return WhisperModel.base;
    if (name.contains('small')) return WhisperModel.small;
    if (name.contains('medium')) return WhisperModel.medium;
    return WhisperModel.large;
  }

  /// Transcribes the WAV file at [audioPath].
  ///
  /// When [language] is omitted the user's configured STT language is used —
  /// previously that setting was stored but never reached this call, so every
  /// transcription ran in auto-detect mode.
  Future<String> transcribeFromFile(String audioPath, {String? language}) async {
    await initialize();
    final model = _activeModel;
    if (model == null) {
      throw const WhisperNotReadyException(
        'The speech-to-text model is not ready.',
      );
    }

    final file = File(audioPath);
    if (!await file.exists() || await file.length() < 1000) {
      throw const WhisperNotReadyException(
        'The recording was too short to transcribe.',
      );
    }

    debugPrint('WhisperService: transcribing $audioPath');
    // Calling Whisper directly rather than going through
    // WhisperController.transcribe(), which catches every internal
    // exception and returns null — collapsing a real failure (bad model
    // file, native error, ffmpeg conversion failure, etc.) into the same
    // outcome as whisper genuinely hearing silence, with the actual reason
    // only ever reaching debugPrint.
    final modelPath = await _whisperController.getPath(model);
    final response = await Whisper(model: model).transcribe(
      transcribeRequest: TranscribeRequest(
        audio: audioPath,
        language: language ?? await _settings.sttLanguage,
        isNoTimestamps: true,
        isRealtime: true,
      ),
      modelPath: modelPath,
    );

    return response.text.trim();
  }

  /// Starts recording 16 kHz mono WAV, the format whisper.cpp consumes
  /// directly.
  Future<String> startRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      throw const WhisperNotReadyException(
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
    final path = await _audioRecorder.stop();
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

  /// Releases the recorder. Only call when the app is shutting down — this is a
  /// singleton shared across screens.
  Future<void> dispose() => _audioRecorder.dispose();
}
