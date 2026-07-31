import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kokoro_tts_flutter/kokoro_tts_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'asset_bundle_override.dart';
import 'model_catalog.dart';
import 'model_storage.dart';
import 'tts_engine.dart';
import 'voice_pack_service.dart';

/// Raised when speech synthesis cannot start, with a message worth showing.
class TtsUnavailableException implements Exception {
  const TtsUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Wraps the Kokoro ONNX voice model.
///
/// The weights are loaded from the bundled `assets/kokoro.onnx` when it is
/// present, which is how this app has always shipped Kokoro. A model downloaded
/// through the models page is used as a fallback, so the app still has a voice
/// on a checkout that does not carry the (untracked, large) asset.
///
/// The one behaviour that changed: the user's configured voice, speed and
/// language were previously persisted but never passed to the engine, which
/// synthesised everything with a hardcoded `voice: 'af'` at speed 1.0. Every
/// call now reads the current settings.
class KokoroTtsService implements TtsEngine {
  static final KokoroTtsService _instance = KokoroTtsService._internal();
  factory KokoroTtsService() => _instance;
  KokoroTtsService._internal();

  /// Bundled ONNX weights, the primary source for the voice model.
  static const String modelAsset = 'assets/kokoro.onnx';

  /// Voice style vectors. The package reads this through the asset bundle only,
  /// so it must be shipped with the app even when the model is downloaded.
  static const String voicesAsset = 'assets/voices.json';

  /// Phoneme-to-token map. The package hardcodes this path and cannot start
  /// without it.
  static const String tokenizerAsset = 'assets/tokenizer_vocab.json';

  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();

  Kokoro? _kokoro;
  AudioPlayer? _player;
  String? _loadedModelPath;
  Future<void>? _initialization;

  @override
  bool get isInitialized => _kokoro != null;

  /// Loads the voice model, reusing an in-flight initialisation.
  @override
  Future<void> initialize({bool force = false}) {
    if (force) _initialization = null;
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      await _aliasLexiconAssets();

      // Downloads the voice table if it is not bundled, and registers it so the
      // TTS package can read it through the asset bundle.
      await VoicePackService().ensureReady();

      if (!await _assetExists(tokenizerAsset)) {
        throw const TtsUnavailableException(
          'The voice data file "$tokenizerAsset" is missing from this build. '
          'The kokoro_tts_flutter package reads it through the asset bundle at '
          'a hardcoded path — see the README.',
        );
      }

      final modelPath = await _resolveModelPath();

      final kokoro = Kokoro(KokoroConfig(
        modelPath: modelPath,
        voicesPath: voicesAsset,
      ));
      await kokoro.initialize();

      _kokoro = kokoro;
      _loadedModelPath = modelPath;
      _player ??= AudioPlayer();
      debugPrint('KokoroTtsService: ready with $modelPath');
    } catch (e) {
      _kokoro = null;
      _loadedModelPath = null;
      _initialization = null;
      debugPrint('KokoroTtsService: initialisation failed: $e');
      rethrow;
    }
  }

  /// Locates the ONNX weights.
  ///
  /// A bundled `assets/kokoro.onnx` wins, because that is how the app shipped
  /// Kokoro historically and it needs no download. Otherwise the model selected
  /// on the models page is used — the package accepts a plain filesystem path
  /// for the weights, so this one file does not have to live in the bundle.
  Future<String> _resolveModelPath() async {
    if (await _assetExists(modelAsset)) {
      debugPrint('KokoroTtsService: using bundled $modelAsset');
      return modelAsset;
    }

    final filename = await _selectedKokoroModel();
    if (filename == null) {
      throw const TtsUnavailableException(
        'No Kokoro voice model is selected. Open Settings & models to '
        'download one, or switch the speech engine.',
      );
    }

    final path = await _storage.pathFor(filename);
    if (!await File(path).exists()) {
      throw TtsUnavailableException(
        'The voice model "$filename" has not been downloaded yet. Open '
        'Settings & models to download it.',
      );
    }
    return path;
  }

  /// Pronunciation dictionaries the grapheme-to-phoneme engine needs.
  ///
  /// `malsami` declares these in its own pubspec — so they are built into the
  /// app under `packages/malsami/assets/…` — but `Lexicon` then reads them from
  /// the *application's* root asset namespace without the package prefix. The
  /// app therefore has to answer for `assets/us_gold.json`, and text-to-speech
  /// fails with `Unable to load asset` if nothing does.
  ///
  /// Aliasing avoids shipping a second ~6 MB copy of files already in the
  /// build. An app-provided file wins, so a custom lexicon can still override
  /// this.
  static const Map<String, String> _lexiconAliases = {
    'assets/us_gold.json': 'packages/malsami/assets/us_gold.json',
    'assets/us_silver.json': 'packages/malsami/assets/us_silver.json',
    'assets/gb_gold.json': 'packages/malsami/assets/gb_gold.json',
    'assets/gb_silver.json': 'packages/malsami/assets/gb_silver.json',
  };

  Future<void> _aliasLexiconAssets() async {
    for (final entry in _lexiconAliases.entries) {
      if (AssetOverrideBinding.hasAlias(entry.key)) continue;
      if (await _assetExists(entry.key)) continue;
      if (!await _assetExists(entry.value)) {
        debugPrint('KokoroTtsService: ${entry.value} is not in this build');
        continue;
      }
      AssetOverrideBinding.registerAlias(entry.key, entry.value);
    }
  }

  Future<bool> _assetExists(String key) async {
    try {
      await rootBundle.load(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reloads the engine, picking up a change of TTS model.
  @override
  Future<void> reload() async {
    await stop();
    _kokoro = null;
    _loadedModelPath = null;
    await initialize(force: true);
  }

  /// Whether the loaded model still matches the current selection.
  ///
  /// Always false while the bundled asset is in use, since no setting can
  /// change which file that is.
  @override
  Future<bool> get isStale async {
    final loaded = _loadedModelPath;
    if (loaded == null || loaded == modelAsset) return false;
    final selected = await _selectedKokoroModel();
    if (selected == null) return true;
    return loaded != await _storage.pathFor(selected);
  }

  /// The selected text-to-speech model, or null when it is not one this engine
  /// can load.
  ///
  /// The models page stores one selection for all TTS models regardless of
  /// which engine consumes them, so picking Chatterbox leaves its bundle
  /// directory in the same setting Kokoro reads. Loading that as ONNX weights
  /// failed with a misleading "the voice model has not been downloaded yet",
  /// naming a model that was in fact downloaded and in use.
  Future<String?> _selectedKokoroModel() async {
    final filename = await _settings.selectedTtsModel;
    if (filename == null || filename.isEmpty) return null;

    try {
      final spec = (await ModelCatalog().load()).byFilename(filename);
      final engine = spec?.engine;
      if (engine != null && engine != TtsEngineKind.kokoro.name) {
        debugPrint(
          'KokoroTtsService: ignoring "$filename", which belongs to $engine',
        );
        return null;
      }
    } catch (e) {
      // An unreadable catalog says nothing about the selection; try it.
      debugPrint('KokoroTtsService: could not check the catalog: $e');
    }
    return filename;
  }

  /// Speaks [text], using the configured voice, speed and language unless they
  /// are overridden.
  @override
  Future<void> speak(
    String text, {
    String? voice,
    String? lang,
    double? speed,
  }) async {
    if (text.trim().isEmpty) return;

    await initialize();
    final kokoro = _kokoro;
    if (kokoro == null) {
      throw const TtsUnavailableException('Text-to-speech is not ready.');
    }

    final resolvedVoice = voice ?? await _resolveVoice();
    final resolvedLang = lang ?? await _settings.ttsLanguage;
    final resolvedSpeed =
        (speed ?? await _settings.ttsSpeed).clamp(0.5, 2.0).toDouble();

    final result = await kokoro.createTTS(
      text: text,
      voice: resolvedVoice,
      speed: resolvedSpeed,
      lang: resolvedLang,
      isPhonemes: false,
    );

    final wavFile = await _writeWav(result.audio.cast<double>());

    // Stop anything still playing so overlapping replies do not talk over each
    // other and so the previous temp file's completion handler fires.
    await stop();
    await _player!.play(DeviceFileSource(wavFile.path));

    unawaited(_deleteWhenFinished(wavFile));
  }

  /// Picks a voice that the loaded model actually provides, so a stale saved
  /// preference cannot make every utterance throw.
  Future<String> _resolveVoice() async {
    final saved = await _settings.ttsVoice;
    final available = availableVoiceIds();
    if (available.isEmpty || available.contains(saved)) return saved;

    debugPrint('KokoroTtsService: voice "$saved" unavailable, using first');
    return available.first;
  }

  /// Voice ids the loaded model exposes. Empty until [initialize] succeeds.
  List<String> availableVoiceIds() {
    final kokoro = _kokoro;
    if (kokoro == null) return const [];
    final ids = kokoro.availableVoices.keys.toList()..sort();
    return ids;
  }

  @override
  TtsEngineKind get kind => TtsEngineKind.kokoro;

  @override
  Future<List<String>> availableVoices() => getAvailableVoiceIds();

  /// Voice ids for the settings UI, initialising the engine first when it can
  /// be.
  ///
  /// Returns an empty list when the engine cannot start, so the UI can say the
  /// voice list is unavailable rather than offering a voice that does not exist.
  Future<List<String>> getAvailableVoiceIds() async {
    try {
      await initialize();
    } catch (e) {
      debugPrint('KokoroTtsService: cannot list voices yet: $e');
      return const [];
    }
    return availableVoiceIds();
  }

  Future<File> _writeWav(List<double> samples) async {
    const sampleRate = 24000;
    const channels = 1;
    const bitsPerSample = 16;
    const byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    const blockAlign = channels * (bitsPerSample ~/ 8);

    final pcm = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      pcm[i] = (samples[i] * 32767).round().clamp(-32768, 32767);
    }
    final pcmBytes = pcm.buffer.asUint8List();

    final header = ByteData(44);
    header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
    header.setUint32(4, 36 + pcmBytes.length, Endian.little);
    header.setUint32(8, 0x57415645, Endian.big); // "WAVE"
    header.setUint32(12, 0x666d7420, Endian.big); // "fmt "
    header.setUint32(16, 16, Endian.little); // subchunk size
    header.setUint16(20, 1, Endian.little); // PCM
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    header.setUint32(36, 0x64617461, Endian.big); // "data"
    header.setUint32(40, pcmBytes.length, Endian.little);

    final builder = BytesBuilder()
      ..add(header.buffer.asUint8List())
      ..add(pcmBytes);

    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(builder.takeBytes());
    return file;
  }

  Future<void> _deleteWhenFinished(File file) async {
    try {
      await _player?.onPlayerComplete.first;
    } catch (_) {
      // Playback was interrupted; the file still needs removing.
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('KokoroTtsService: could not delete ${file.path}: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('KokoroTtsService: error stopping playback: $e');
    }
  }

  /// Releases the engine. Only call when the app is shutting down — this is a
  /// singleton shared across screens.
  @override
  Future<void> dispose() async {
    await stop();
    _kokoro?.dispose();
    _kokoro = null;
    _loadedModelPath = null;
    _initialization = null;
    await _player?.dispose();
    _player = null;
  }
}
