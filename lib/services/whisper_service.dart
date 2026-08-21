import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:whisper_ggml/whisper_ggml.dart';

import 'app_settings.dart';
import 'model_storage.dart';
import 'stt_engine.dart';

/// Raised when transcription is attempted before a Whisper model is available.
class WhisperNotReadyException extends SttNotReadyException {
  const WhisperNotReadyException(super.reason);
}

/// Transcribes recorded audio with whisper.cpp.
///
/// Recording itself lives in [SpeechToTextService], which owns the microphone
/// for every engine.
class WhisperService implements SttEngine {
  static final WhisperService _instance = WhisperService._();
  factory WhisperService() => _instance;
  WhisperService._();

  /// Kept for the existing `WhisperService.instance` call sites.
  static WhisperService get instance => _instance;

  final WhisperController _whisperController = WhisperController();
  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();

  WhisperModel? _activeModel;
  String? _activeFilename;
  Future<void>? _initialization;
  bool _isTranscribing = false;

  @override
  SttEngineKind get kind => SttEngineKind.whisper;

  @override
  bool get isReady => _activeModel != null;

  /// Prepares the transcription model, reusing an in-flight initialisation.
  ///
  /// The previous implementation returned early while initialisation was still
  /// running, so a caller could proceed as though the model were loaded.
  @override
  Future<void> initialize({bool force = false}) async {
    final selected = await _settings.selectedSttModel;
    final selectionChanged = selected != _activeFilename;
    if (force || selectionChanged) {
      // Never start a second import while the first one is still copying the
      // model. Competing writes can leave whisper.cpp with a truncated GGML
      // file, which is a native-process crash rather than a Dart exception.
      final inFlight = _initialization;
      if (inFlight != null) {
        try {
          await inFlight;
        } catch (_) {
          // The fresh attempt below reports its own useful error.
        }
      }
      _initialization = null;
      _activeModel = null;
      _activeFilename = null;
    }
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
      final downloaded = File(await _storage.pathFor(filename));
      final hasDownloaded = await downloaded.exists();
      final pluginIsComplete = await pluginFile.exists() &&
          (!hasDownloaded ||
              await pluginFile.length() == await downloaded.length());
      if (!pluginIsComplete) {
        if (hasDownloaded) {
          debugPrint('WhisperService: importing $filename into plugin storage');
          await pluginFile.parent.create(recursive: true);
          final importing = File('${pluginFile.path}.importing');
          if (await importing.exists()) await importing.delete();
          final sink = importing.openWrite();
          try {
            await sink.addStream(downloaded.openRead());
          } finally {
            await sink.close();
          }
          if (await importing.length() != await downloaded.length()) {
            await importing.delete();
            throw const WhisperNotReadyException(
              'The speech-to-text model could not be copied completely.',
            );
          }
          if (await pluginFile.exists()) await pluginFile.delete();
          await importing.rename(pluginFile.path);
        } else {
          throw WhisperNotReadyException(
            'The speech-to-text model "$filename" has not been downloaded yet. '
            'Open Manage Models to download it.',
          );
        }
      }

      _activeModel = model;
      _activeFilename = filename;
      debugPrint('WhisperService: ready with ${model.name}');
    } catch (e) {
      // Allow a later attempt to retry rather than caching the failure.
      _activeModel = null;
      _activeFilename = null;
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
  @override
  Future<String> transcribeFromFile(String audioPath,
      {String? language}) async {
    if (_isTranscribing) {
      throw const WhisperNotReadyException(
        'A transcription is already in progress.',
      );
    }
    _isTranscribing = true;
    try {
      final text = await _transcribeFromFile(audioPath, language: language);
      debugPrint('WhisperService: native transcription completed');
      return sanitizeTranscription(text);
    } finally {
      _isTranscribing = false;
    }
  }

  /// Whisper uses bracketed or parenthesized annotations for non-speech audio,
  /// such as `[BLANK_AUDIO]`, `[music]`, and `(silence)`. They are not user
  /// messages.
  @visibleForTesting
  static String sanitizeTranscription(String text) {
    final trimmed = text.trim();
    final isAnnotation = (trimmed.startsWith('[') && trimmed.endsWith(']')) ||
        (trimmed.startsWith('(') && trimmed.endsWith(')'));
    if (isAnnotation) {
      debugPrint('WhisperService: discarded audio annotation');
      return '';
    }
    return trimmed;
  }

  Future<String> _transcribeFromFile(String audioPath,
      {String? language}) async {
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
        // Each worker owns inference scratch space. One is slower than the
        // desktop-oriented default but avoids a large peak beside the resident
        // language and speech models on memory-constrained iPhones.
        threads: 1,
        isNoTimestamps: true,
        noContext: true,
        suppressNonSpeechTokens: true,
        // This is a finalized file; realtime mode is reserved for the
        // plugin's streaming API and must not be mixed with file requests.
        isRealtime: false,
      ),
      modelPath: modelPath,
    );

    return response.text.trim();
  }

  @override
  Future<void> unload() async {
    _activeModel = null;
    _activeFilename = null;
    _initialization = null;
  }
}
