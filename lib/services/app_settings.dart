import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'tts_engine.dart';

/// Typed accessor for everything the app persists as a user preference.
///
/// Settings used to be read directly from [FlutterSecureStorage] at each call
/// site with the default value inlined, which meant the same key had different
/// defaults in different files — most visibly `tts_enabled`, which the chat
/// screen declared as `true` but then resolved to `false` on first launch
/// because a missing key was compared against the string `'true'`. Defaults now
/// live here and here only.
class AppSettings {
  static final AppSettings _instance = AppSettings._internal();
  factory AppSettings() => _instance;
  AppSettings._internal();

  static const _storage = FlutterSecureStorage();

  // Keys
  static const _kSelectedLlm = 'selected_llm_model';
  static const _kSelectedTts = 'selected_tts_model';
  static const _kSelectedStt = 'selected_stt_model';
  static const _kSystemPrompt = 'selected_prompt';
  static const _kLlmTemperature = 'llm_temperature';
  static const _kLlmMaxTokens = 'llm_max_tokens';
  static const _kTtsEnabled = 'tts_enabled';
  static const _kSttEnabled = 'stt_enabled';
  static const _kSaveChatHistory = 'save_chat_history';
  static const _kTtsSpeed = 'tts_speed';
  static const _kTtsVoice = 'tts_voice';
  static const _kTtsLanguage = 'tts_language';
  static const _kSttLanguage = 'stt_language';
  static const _kHfToken = 'hf_token';
  static const _kTtsEngine = 'tts_engine';
  static const _kChatterboxExaggeration = 'chatterbox_exaggeration';
  static const _kChatterboxGgufGpu = 'chatterbox_gguf_use_gpu';

  // Defaults
  static const String defaultSystemPrompt =
      'You are a helpful, concise AI assistant. Keep responses to roughly '
      '50-100 words unless asked for more detail.';
  static const double defaultTemperature = 0.7;
  static const int defaultMaxTokens = 4096;
  static const double defaultTtsSpeed = 1.0;
  static const String defaultTtsVoice = 'af_heart';
  static const String defaultTtsLanguage = 'en-us';
  static const String defaultSttLanguage = 'auto';

  /// Chatterbox's emotion-intensity knob; 0.5 is the neutral default.
  static const double defaultChatterboxExaggeration = 0.5;

  // --- Model selection ---

  Future<String?> get selectedLlmModel => _storage.read(key: _kSelectedLlm);
  Future<void> setSelectedLlmModel(String value) =>
      _storage.write(key: _kSelectedLlm, value: value);

  Future<String?> get selectedTtsModel => _storage.read(key: _kSelectedTts);
  Future<void> setSelectedTtsModel(String value) =>
      _storage.write(key: _kSelectedTts, value: value);

  Future<String?> get selectedSttModel => _storage.read(key: _kSelectedStt);
  Future<void> setSelectedSttModel(String value) =>
      _storage.write(key: _kSelectedStt, value: value);

  /// Clears a model selection, used when the underlying file is deleted.
  Future<void> clearSelectionFor(String filename) async {
    for (final key in [_kSelectedLlm, _kSelectedTts, _kSelectedStt]) {
      if (await _storage.read(key: key) == filename) {
        await _storage.delete(key: key);
      }
    }
  }

  // --- LLM ---

  Future<String> get systemPrompt async =>
      await _storage.read(key: _kSystemPrompt) ?? defaultSystemPrompt;
  Future<void> setSystemPrompt(String value) =>
      _storage.write(key: _kSystemPrompt, value: value);

  Future<double> get temperature async => _readDouble(
        _kLlmTemperature,
        defaultTemperature,
        min: 0.0,
        max: 2.0,
      );
  Future<void> setTemperature(double value) =>
      _storage.write(key: _kLlmTemperature, value: value.toString());

  Future<int> get maxTokens async =>
      _readInt(_kLlmMaxTokens, defaultMaxTokens, min: 256, max: 32768);
  Future<void> setMaxTokens(int value) =>
      _storage.write(key: _kLlmMaxTokens, value: value.toString());

  // --- Voice toggles ---

  Future<bool> get ttsEnabled => _readBool(_kTtsEnabled, true);
  Future<void> setTtsEnabled(bool value) =>
      _storage.write(key: _kTtsEnabled, value: value.toString());

  Future<bool> get sttEnabled => _readBool(_kSttEnabled, true);
  Future<void> setSttEnabled(bool value) =>
      _storage.write(key: _kSttEnabled, value: value.toString());

  Future<bool> get saveChatHistory => _readBool(_kSaveChatHistory, true);
  Future<void> setSaveChatHistory(bool value) =>
      _storage.write(key: _kSaveChatHistory, value: value.toString());

  // --- TTS ---

  Future<double> get ttsSpeed =>
      _readDouble(_kTtsSpeed, defaultTtsSpeed, min: 0.5, max: 2.0);
  Future<void> setTtsSpeed(double value) =>
      _storage.write(key: _kTtsSpeed, value: value.toString());

  Future<String> get ttsVoice async =>
      await _storage.read(key: _kTtsVoice) ?? defaultTtsVoice;
  Future<void> setTtsVoice(String value) =>
      _storage.write(key: _kTtsVoice, value: value);

  Future<String> get ttsLanguage async =>
      await _storage.read(key: _kTtsLanguage) ?? defaultTtsLanguage;
  Future<void> setTtsLanguage(String value) =>
      _storage.write(key: _kTtsLanguage, value: value);

  // --- STT ---

  Future<String> get sttLanguage async =>
      await _storage.read(key: _kSttLanguage) ?? defaultSttLanguage;
  Future<void> setSttLanguage(String value) =>
      _storage.write(key: _kSttLanguage, value: value);

  // --- Speech synthesis engine ---

  /// Which TTS backend to use. Kokoro remains the default because it is two
  /// orders of magnitude smaller and near-realtime.
  Future<TtsEngineKind> get ttsEngine async =>
      TtsEngineKind.fromName(await _storage.read(key: _kTtsEngine));

  Future<void> setTtsEngine(TtsEngineKind value) =>
      _storage.write(key: _kTtsEngine, value: value.name);

  Future<double> get chatterboxExaggeration => _readDouble(
        _kChatterboxExaggeration,
        defaultChatterboxExaggeration,
        min: 0.0,
        max: 1.0,
      );

  Future<void> setChatterboxExaggeration(double value) => _storage.write(
        key: _kChatterboxExaggeration,
        value: value.toString(),
      );

  /// Whether the GGUF engine offloads its decode loop to the GPU.
  ///
  /// Off by default on measurement, not assumption: on a discrete GPU it ran
  /// *slower* than the CPU, because autoregressive decode dispatches one token
  /// at a time and never assembles a batch wide enough to repay the round
  /// trip. Left switchable because a phone's unified memory has no such
  /// transfer to repay, and that case is untested.
  Future<bool> get chatterboxGgufUseGpu async =>
      (await _storage.read(key: _kChatterboxGgufGpu)) == 'true';

  Future<void> setChatterboxGgufUseGpu(bool value) =>
      _storage.write(key: _kChatterboxGgufGpu, value: value.toString());

  // --- Hugging Face credentials ---

  Future<String?> get hfToken async {
    final token = await _storage.read(key: _kHfToken);
    return (token == null || token.isEmpty) ? null : token;
  }

  Future<void> setHfToken(String value) =>
      _storage.write(key: _kHfToken, value: value);

  Future<void> clearHfToken() => _storage.delete(key: _kHfToken);

  // --- Helpers ---

  Future<bool> _readBool(String key, bool fallback) async {
    final raw = await _storage.read(key: key);
    if (raw == null) return fallback;
    return raw.toLowerCase() == 'true';
  }

  Future<double> _readDouble(
    String key,
    double fallback, {
    required double min,
    required double max,
  }) async {
    final raw = await _storage.read(key: key);
    final parsed = raw == null ? null : double.tryParse(raw);
    if (parsed == null) return fallback;
    return parsed.clamp(min, max).toDouble();
  }

  Future<int> _readInt(
    String key,
    int fallback, {
    required int min,
    required int max,
  }) async {
    final raw = await _storage.read(key: key);
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed == null) return fallback;
    return parsed.clamp(min, max);
  }

  @visibleForTesting
  Future<void> clearAll() async {
    debugPrint('AppSettings: clearing all stored settings');
    await _storage.deleteAll();
  }
}
