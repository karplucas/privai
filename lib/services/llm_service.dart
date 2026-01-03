import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

enum LlmModel {
  gemma3_1b,
  gemma3nE2b,
}

class LlmService {
  static final LlmService _instance = LlmService._internal();
  factory LlmService() => _instance;
  LlmService._internal() {
    _initializeGemma();
  }

  static Future<void> _initializeGemma() async {
    // Initialize the plugin structure
    await FlutterGemma.initialize();
  }

  InferenceModel? _inferenceModel;
  dynamic _chat;

  bool _isModelLoading = false;
  bool get isModelLoading => _isModelLoading;

  /// Sets up Gemma model using dynamic path resolution
  Future<void> initializeChat() async {
    if (_isModelLoading) return;
    _isModelLoading = true;

    try {
      debugPrint('Starting LLM model initialization...');
      final selectedFilename =
          await _getSelectedLlmFilename() ?? 'gemma-3n-E2B-it-int4.task';

      // FIX: Instead of hardcoded /sdcard/, get the directory Android actually allows
      final directory = await getExternalStorageDirectory();

      if (directory == null) {
        throw Exception('Storage directory not found.');
      }

      final modelPath = '${directory.path}/$selectedFilename';
      final file = File(modelPath);

      debugPrint('Targeting model path: $modelPath');

      if (await file.exists()) {
        // 1. Install model into native Gemma engine
        await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
            .fromFile(modelPath)
            .install();

        // 2. Load model with 4096 tokens
        _inferenceModel = await FlutterGemma.getActiveModel(maxTokens: 4096);

        if (_inferenceModel != null) {
          _chat = await _inferenceModel!.createChat();
          final prompt = await _getSelectedPrompt();
          await (_chat as dynamic)
              .addQueryChunk(Message(text: prompt, isUser: false));
          debugPrint('Gemma ready.');
        }
      } else {
        throw Exception('Model file missing. Check: ${file.path}');
      }
    } catch (e) {
      debugPrint('Initialization Error: $e');
      throw Exception('Initialization Error: $e');
    } finally {
      _isModelLoading = false;
    }
  }

  /// Processes user input and returns AI response
  Future<String> generateResponse(String input) async {
    if (_chat == null) {
      throw Exception('Chat not initialized');
    }

    try {
      await _chat!.addQueryChunk(Message(text: input, isUser: true));
      final response = await _chat!.generateChatResponse();

      if (response is TextResponse) return response.token;
      return 'Unexpected response format.';
    } catch (e) {
      debugPrint('Inference Error: $e');
      _chat = await _inferenceModel?.createChat();
      return '⚠️ Context limit reached. History cleared. What next?';
    }
  }

  /// Gets the selected LLM model filename from storage
  Future<String?> _getSelectedLlmFilename() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: 'selected_llm_model');
  }

  /// Gets the selected system prompt from storage
  Future<String> _getSelectedPrompt() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: 'selected_prompt') ??
        'You are a helpful, concise AI assistant. Provide accurate and brief responses.';
  }

  /// Checks if the model is ready for inference
  bool get isReady => _chat != null;

  /// Gets current chat instance
  dynamic get currentChat => _chat;

  /// Gets current inference model
  InferenceModel? get currentModel => _inferenceModel;
}
