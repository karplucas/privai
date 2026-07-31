import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

import 'app_settings.dart';
import 'model_storage.dart';

/// Raised when the selected model has not been downloaded yet.
///
/// Distinct from a generic failure so the UI can send the user to the models
/// page instead of showing an opaque error.
class ModelNotDownloadedException implements Exception {
  const ModelNotDownloadedException(this.filename);

  final String filename;

  @override
  String toString() =>
      'The model "$filename" has not been downloaded yet. Open Manage Models '
      'to download it.';
}

/// Raised when no model has been chosen at all.
class NoModelSelectedException implements Exception {
  const NoModelSelectedException();

  @override
  String toString() =>
      'No language model is selected. Open Manage Models to pick one.';
}

/// Owns the on-device Gemma inference session.
class LlmService {
  static final LlmService _instance = LlmService._internal();
  factory LlmService() => _instance;
  LlmService._internal();

  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();

  InferenceModel? _inferenceModel;
  InferenceChat? _chat;
  String? _loadedFilename;

  Future<void>? _pluginInit;
  Future<void>? _chatInit;

  bool _isModelLoading = false;
  bool get isModelLoading => _isModelLoading;

  /// Test seam: when set, replaces the model with a scripted stream so the
  /// chat UI's streaming behaviour can be exercised without loading weights.
  @visibleForTesting
  Stream<String> Function(String prompt)? debugResponseStream;

  /// True once a chat session exists and can answer prompts.
  bool get isReady => _chat != null || debugResponseStream != null;

  /// Filename of the model currently loaded, if any.
  String? get loadedFilename => _loadedFilename;

  /// Initialises the native plugin exactly once.
  ///
  /// This used to be kicked off from the constructor without being awaited, so
  /// the first [initializeChat] could race the plugin's own setup. Callers now
  /// await it through [initializeChat].
  Future<void> _ensurePluginInitialized() =>
      _pluginInit ??= FlutterGemma.initialize();

  /// Loads the selected model and opens a chat session.
  ///
  /// Concurrent callers share a single initialisation rather than the earlier
  /// behaviour of returning immediately while loading was still in flight,
  /// which left the caller believing the model was ready.
  Future<void> initializeChat({bool force = false}) {
    if (force) {
      _chatInit = null;
    } else {
      final pending = _chatInit;
      if (pending != null) return pending;
    }
    return _chatInit = _initializeChat();
  }

  Future<void> _initializeChat() async {
    _isModelLoading = true;
    try {
      await _ensurePluginInitialized();

      final filename = await _settings.selectedLlmModel;
      if (filename == null || filename.isEmpty) {
        throw const NoModelSelectedException();
      }

      final modelPath = await _storage.pathFor(filename);
      if (!await File(modelPath).exists()) {
        throw ModelNotDownloadedException(filename);
      }

      debugPrint('LlmService: loading $modelPath');

      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromFile(modelPath)
          .install();

      final maxTokens = await _settings.maxTokens;
      final model = await FlutterGemma.getActiveModel(maxTokens: maxTokens);

      final chat = await model.createChat(
        temperature: await _settings.temperature,
      );

      // Seed the session with the system prompt.
      await chat.addQueryChunk(
        Message.text(text: await _settings.systemPrompt, isUser: false),
      );

      _inferenceModel = model;
      _chat = chat;
      _loadedFilename = filename;
      debugPrint('LlmService: ready with $filename ($maxTokens tokens)');
    } catch (e) {
      // Leave the service in a clean unloaded state and let the next call retry.
      _chat = null;
      _loadedFilename = null;
      _chatInit = null;
      debugPrint('LlmService: initialisation failed: $e');
      rethrow;
    } finally {
      _isModelLoading = false;
    }
  }

  /// Releases the native session while keeping the model selection.
  ///
  /// Used to free memory for a speech engine that cannot co-reside with the
  /// language model; call [initializeChat] with `force: true` to bring it back.
  Future<void> unload() async {
    debugPrint('LlmService: unloading to free memory');
    await _closeSession();
  }

  /// Reloads the session, picking up any change to the selected model or the
  /// LLM parameters.
  Future<void> reload() async {
    await _closeSession();
    await initializeChat(force: true);
  }

  /// Whether the loaded model still matches what the settings select.
  Future<bool> get isStale async {
    final selected = await _settings.selectedLlmModel;
    return _loadedFilename != null && selected != _loadedFilename;
  }

  /// Runs [input] through the model and returns its reply in one piece.
  ///
  /// Prefer [generateResponseStream] for anything user-facing: on-device
  /// generation takes long enough that waiting for the whole answer looks like
  /// the app has hung.
  Future<String> generateResponse(String input) async {
    final buffer = StringBuffer();
    await for (final chunk in generateResponseStream(input)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  /// Streams the model's reply token by token as it is produced.
  ///
  /// Each event is a fragment to append to what has already been shown, not the
  /// running total.
  Stream<String> generateResponseStream(String input) async* {
    final scripted = debugResponseStream;
    if (scripted != null) {
      yield* scripted(input);
      return;
    }

    final chat = _chat;
    if (chat == null) {
      throw StateError('The language model is not ready yet.');
    }

    await chat.addQueryChunk(Message.text(text: input, isUser: true));

    await for (final response in chat.generateChatResponseAsync()) {
      switch (response) {
        case TextResponse(:final token):
          yield token;
        case ThinkingResponse():
          // The model's internal reasoning is not shown in the transcript.
          break;
        default:
          debugPrint(
            'LlmService: ignoring response type ${response.runtimeType}',
          );
      }
    }
  }

  /// Drops the conversation context while keeping the model loaded.
  ///
  /// Used when the context window fills up — the previous code did this inside
  /// a catch-all that reported every inference failure as a context overflow.
  Future<void> clearContext() async {
    final model = _inferenceModel;
    if (model == null) return;
    _chat = await model.createChat(temperature: await _settings.temperature);
    await _chat!.addQueryChunk(
      Message.text(text: await _settings.systemPrompt, isUser: false),
    );
  }

  Future<void> _closeSession() async {
    try {
      await _inferenceModel?.close();
    } catch (e) {
      debugPrint('LlmService: error closing model: $e');
    }
    _inferenceModel = null;
    _chat = null;
    _loadedFilename = null;
    _chatInit = null;
  }

  /// Releases native resources. Only call this when the app is shutting down —
  /// this is a singleton shared by every screen.
  Future<void> dispose() => _closeSession();
}
