import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'audio_clip_player.dart';
import 'model_storage.dart';
import 'tts_engine.dart';
import 'wav.dart';

/// Raised when the Supertonic bundle is missing or cannot be run.
class SupertonicUnavailableException implements Exception {
  const SupertonicUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Supertone's Supertonic 3, a 99M-parameter flow-matching model.
///
/// The pipeline is derived from Supertone's own MIT-licensed Flutter sample,
/// which happens to target the same `flutter_onnxruntime` package this app
/// already uses. Four graphs:
///
///  1. `duration_predictor` — text and style to a length in seconds
///  2. `text_encoder`       — text and style to the embedding the flow attends to
///  3. `vector_estimator`   — one denoising step over a latent, run [defaultSteps] times
///  4. `vocoder`            — latent to a 44.1 kHz waveform
///
/// Unlike Chatterbox there is no autoregressive decode: the cost is a fixed,
/// small number of passes rather than one pass per 40 ms of audio, which is why
/// it is several times faster. Measured on a desktop CPU at the default eight
/// steps: 2.0 s to synthesise 10 s of audio, a real-time factor of 0.2. Sixteen
/// steps buys a little quality at 0.38. Its sessions are light enough to sit
/// beside the language model, so [TtsEngineKind.requiresExclusiveMemory] is
/// false and nothing has to be unloaded to speak.
class SupertonicTtsService implements TtsEngine {
  static final SupertonicTtsService _instance =
      SupertonicTtsService._internal();
  factory SupertonicTtsService() => _instance;
  SupertonicTtsService._internal();

  /// Directory used by the fp32 catalog entry.
  static const String bundleName = 'supertonic-3';

  /// Directory used by the int8 catalog entry.
  ///
  /// Only the two graphs that dominate the download are quantised — the vector
  /// estimator (257 MB to 78) and the vocoder (101 MB to 26); the duration
  /// predictor and text encoder are the same files. Measured at the default
  /// eight steps it is exactly as fast as fp32 (0.197 against 0.202 real-time
  /// factor), so the smaller build costs nothing in speed. That is the opposite
  /// of what int8 did to MMS, which is why both were measured rather than
  /// assumed.
  static const String int8BundleName = 'supertonic-3-int8';

  /// Bundles this engine can run, most preferred first.
  static const List<String> bundleNames = [bundleName, int8BundleName];

  static const String durationGraph = 'duration_predictor.onnx';
  static const String textEncoderGraph = 'text_encoder.onnx';
  static const String vectorEstimatorGraph = 'vector_estimator.onnx';
  static const String vocoderGraph = 'vocoder.onnx';
  static const String indexerFile = 'unicode_indexer.json';
  static const String configFile = 'tts.json';

  /// Voice styles shipped with the bundle, five female and five male.
  static const List<String> voiceStyles = [
    'F1', 'F2', 'F3', 'F4', 'F5', //
    'M1', 'M2', 'M3', 'M4', 'M5',
  ];
  static const String defaultVoice = 'M1';

  /// Denoising steps per utterance. Supertone's own sample defaults to eight,
  /// and measurement agrees: four is barely faster (the fixed graphs dominate)
  /// and sixteen costs nearly twice as much for a difference that does not
  /// carry through a phone speaker.
  static const int defaultSteps = 8;

  /// The sample's default, a touch above natural pace; the user's speed
  /// setting multiplies it.
  static const double baseSpeed = 1.05;

  /// Longest text handed to the model at once. Supertone uses a shorter limit
  /// for the languages that do not delimit words with spaces.
  static const int maxCharacters = 300;
  static const int maxCharactersDense = 120;

  /// App language codes to the two-letter codes Supertonic knows.
  ///
  /// This is a subset of the 31 languages the model reads — it only has to
  /// cover what the language dropdown offers. Mandarin is deliberately absent:
  /// Chinese is not one of the 31, so asking for it fails loudly here instead
  /// of being spoken in the wrong language.
  static const Map<String, String> _languages = {
    'en-us': 'en',
    'en-gb': 'en',
    'ja': 'ja',
    'es-419': 'es',
    'es': 'es',
    'hi': 'hi',
    'it': 'it',
    'pt-br': 'pt',
    'pt': 'pt',
    'pl': 'pl',
  };

  final ModelStorage _storage = ModelStorage();
  final AppSettings _settings = AppSettings();
  final math.Random _random = math.Random();

  OrtSession? _duration;
  OrtSession? _textEncoder;
  OrtSession? _vectorEstimator;
  OrtSession? _vocoder;

  /// Code-point indexed lookup table; -1 marks a character the model has no id
  /// for, which is folded to 0 like the reference implementation does.
  List<int> _indexer = const [];

  int _sampleRate = 44100;
  int _baseChunkSize = 512;
  int _chunkCompressFactor = 6;
  int _latentDim = 24;

  final Map<String, _VoiceStyle> _styles = {};

  final AudioClipPlayer _player = AudioClipPlayer('SupertonicTtsService');
  Future<void>? _initialization;
  int _playbackEpoch = 0;

  /// Completed by [stop] so a clip that is cut short stops being awaited at
  /// once. `AudioPlayer.stop()` emits no completion event, so without this the
  /// queue would sit waiting on audio that will never finish.
  Completer<void> _stopSignal = Completer<void>();

  /// Which bundle the loaded sessions came from, so a switch between the fp32
  /// and int8 downloads is noticed by [isStale].
  String? _loadedBundle;

  @override
  TtsEngineKind get kind => TtsEngineKind.supertonic;

  @override
  bool get isInitialized => _vocoder != null;

  @override
  Future<void> initialize({bool force = false}) {
    if (force) {
      _initialization = null;
    } else {
      final pending = _initialization;
      if (pending != null) return pending;
    }
    return _initialization ??= _initialize();
  }

  /// Files a bundle must hold before it can be loaded, whatever its precision.
  static const List<String> requiredFiles = [
    durationGraph,
    textEncoderGraph,
    vectorEstimatorGraph,
    vocoderGraph,
    indexerFile,
    configFile,
  ];

  /// Picks the downloaded bundle to run, preferring the one the user selected.
  ///
  /// The two precisions are separate catalog entries sharing this engine, and a
  /// bundle's directory is its catalog filename, so the selection names the
  /// directory directly.
  Future<String> _resolveBundle() async {
    final selected = await _settings.selectedTtsModel;
    final candidates = [
      if (selected != null && bundleNames.contains(selected)) selected,
      ...bundleNames,
    ];
    for (final name in candidates) {
      if (await _storage.bundleIsComplete(name, requiredFiles)) return name;
    }
    throw const SupertonicUnavailableException(
      'Supertonic is not fully downloaded. Open Settings & models to finish '
      'the download.',
    );
  }

  Future<void> _initialize() async {
    try {
      final bundle = await _resolveBundle();
      final dir = await _storage.bundleDirectory(bundle);

      await _readConfig('${dir.path}/$configFile');
      await _readIndexer('${dir.path}/$indexerFile');

      final ort = OnnxRuntime();
      final options = OrtSessionOptions(
        providers: const [OrtProvider.CPU],
        intraOpNumThreads: Platform.numberOfProcessors,
      );
      _duration = await _createSession(ort, '${dir.path}/$durationGraph', options);
      _textEncoder =
          await _createSession(ort, '${dir.path}/$textEncoderGraph', options);
      _vectorEstimator = await _createSession(
          ort, '${dir.path}/$vectorEstimatorGraph', options);
      _vocoder = await _createSession(ort, '${dir.path}/$vocoderGraph', options);

      await _player.warmUp();
      _loadedBundle = bundle;
      debugPrint('SupertonicTtsService: ready at $_sampleRate Hz from $bundle');
    } catch (e) {
      await _release();
      _initialization = null;
      debugPrint('SupertonicTtsService: initialisation failed: $e');
      rethrow;
    }
  }

  Future<OrtSession> _createSession(
      OnnxRuntime ort, String path, OrtSessionOptions options) async {
    try {
      return await ort.createSession(path, options: options);
    } catch (e) {
      debugPrint('SupertonicTtsService: ${path.split('/').last} would not load '
          'with the requested providers ($e); using the defaults');
      return ort.createSession(path);
    }
  }

  Future<void> _readConfig(String path) async {
    final config = json.decode(await File(path).readAsString());
    if (config is! Map) return;
    final ae = config['ae'];
    final ttl = config['ttl'];
    if (ae is Map) {
      _sampleRate = (ae['sample_rate'] as num?)?.toInt() ?? _sampleRate;
      _baseChunkSize =
          (ae['base_chunk_size'] as num?)?.toInt() ?? _baseChunkSize;
    }
    if (ttl is Map) {
      _chunkCompressFactor =
          (ttl['chunk_compress_factor'] as num?)?.toInt() ?? _chunkCompressFactor;
      _latentDim = (ttl['latent_dim'] as num?)?.toInt() ?? _latentDim;
    }
  }

  Future<void> _readIndexer(String path) async {
    final raw = json.decode(await File(path).readAsString());
    if (raw is! List) {
      throw const SupertonicUnavailableException(
        'The Supertonic character table is malformed.',
      );
    }
    _indexer = [for (final value in raw) (value as num?)?.toInt() ?? -1];
  }

  /// Loads a voice style, keeping the tensors alive for reuse.
  ///
  /// A style is two small tensors read from JSON, and the same pair is used by
  /// every utterance, so they are built once rather than per clip.
  Future<_VoiceStyle> _style(String name) async {
    final cached = _styles[name];
    if (cached != null) return cached;

    final dir = await _storage.bundleDirectory(_loadedBundle ?? bundleName);
    final file = File('${dir.path}/$name.json');
    if (!await file.exists()) {
      throw SupertonicUnavailableException(
        'The Supertonic voice "$name" is not in the downloaded bundle.',
      );
    }
    final raw = json.decode(await file.readAsString()) as Map<String, dynamic>;
    final style = _VoiceStyle(
      ttl: await _tensorFrom(raw['style_ttl'] as Map<String, dynamic>),
      dp: await _tensorFrom(raw['style_dp'] as Map<String, dynamic>),
    );
    return _styles[name] = style;
  }

  Future<OrtValue> _tensorFrom(Map<String, dynamic> field) async {
    final dims = [for (final d in field['dims'] as List) (d as num).toInt()];
    return OrtValue.fromList(_flatten(field['data']), dims);
  }

  static Float32List _flatten(Object? data) {
    final out = <double>[];
    void walk(Object? value) {
      if (value is List) {
        for (final child in value) {
          walk(child);
        }
      } else if (value is num) {
        out.add(value.toDouble());
      }
    }

    walk(data);
    return Float32List.fromList(out);
  }

  /// The two-letter code Supertonic expects for the configured language.
  @visibleForTesting
  static String languageFor(String? code) {
    final language = _languages[code ?? 'en-us'];
    if (language != null) return language;
    throw SupertonicUnavailableException(
      'Supertonic does not speak "$code". It covers 31 languages, but not '
      'Chinese — pick Kokoro for that, or choose another language.',
    );
  }

  /// Turns [text] into the model's character ids, wrapped in the language tag
  /// the model was trained to read.
  @visibleForTesting
  static List<int> encode(String text, String language, List<int> indexer) {
    final tagged = '<$language>$text</$language>';
    return [
      for (final rune in tagged.runes)
        if (rune < indexer.length && indexer[rune] >= 0) indexer[rune] else 0,
    ];
  }

  /// Runs the whole pipeline and returns mono samples in -1..1.
  Future<Float32List> synthesise(
    String text, {
    String? voice,
    String? lang,
    double? speed,
  }) async {
    await initialize();
    final language = languageFor(lang ?? await _settings.ttsLanguage);
    final style = await _style(_voiceName(voice ?? await _settings.ttsVoice));
    final rate = baseSpeed * (speed ?? await _settings.ttsSpeed);

    final ids = encode(text, language, _indexer);
    if (ids.isEmpty) return Float32List(0);

    final textIds = await OrtValue.fromList(
      Int64List.fromList(ids),
      [1, ids.length],
    );
    final textMask = await OrtValue.fromList(
      Float32List(ids.length)..fillRange(0, ids.length, 1),
      [1, 1, ids.length],
    );

    try {
      // 1. How long the clip will be, which fixes the size of the latent.
      final durationOut = await _duration!.run({
        'text_ids': textIds,
        'style_dp': style.dp,
        'text_mask': textMask,
      });
      final durationValue = _require(durationOut, 'duration');
      final seconds =
          _asFloat32(await durationValue.asFlattenedList()).first / rate;
      await durationValue.dispose();

      // 2. The embedding every denoising step attends to. Computed once.
      final encoded = await _textEncoder!.run({
        'text_ids': textIds,
        'style_ttl': style.ttl,
        'text_mask': textMask,
      });
      final textEmbedding = _require(encoded, 'text_emb');

      // 3. Denoise a Gaussian latent towards speech.
      final chunk = _baseChunkSize * _chunkCompressFactor;
      final frames = ((seconds * _sampleRate) + chunk - 1) ~/ chunk;
      if (frames <= 0) {
        await textEmbedding.dispose();
        return Float32List(0);
      }
      final channels = _latentDim * _chunkCompressFactor;

      final latentMask = await OrtValue.fromList(
        Float32List(frames)..fillRange(0, frames, 1),
        [1, 1, frames],
      );
      final totalSteps = await OrtValue.fromList(
        Float32List.fromList([defaultSteps.toDouble()]),
        [1],
      );

      var latent = await OrtValue.fromList(
        _gaussianNoise(channels * frames),
        [1, channels, frames],
      );
      for (var step = 0; step < defaultSteps; step++) {
        final current = await OrtValue.fromList(
          Float32List.fromList([step.toDouble()]),
          [1],
        );
        final estimated = await _vectorEstimator!.run({
          'noisy_latent': latent,
          'text_emb': textEmbedding,
          'style_ttl': style.ttl,
          'text_mask': textMask,
          'latent_mask': latentMask,
          'total_step': totalSteps,
          'current_step': current,
        });
        // The step's output becomes the next step's input directly, so the
        // latent never crosses back into Dart until the vocoder is done with
        // it — 8 round trips of a few hundred kilobytes saved per clip.
        await Future.wait([latent.dispose(), current.dispose()]);
        latent = _require(estimated, 'denoised_latent');
      }

      // 4. Latent to waveform.
      final vocoded = await _vocoder!.run({'latent': latent});
      final waveform = _require(vocoded, 'wav_tts');
      final samples = _asFloat32(await waveform.asFlattenedList());

      await Future.wait([
        latent.dispose(),
        waveform.dispose(),
        textEmbedding.dispose(),
        latentMask.dispose(),
        totalSteps.dispose(),
      ]);
      return samples;
    } finally {
      await Future.wait([textIds.dispose(), textMask.dispose()]);
    }
  }

  static OrtValue _require(Map<String, OrtValue> outputs, String name) {
    final value = outputs[name];
    if (value == null) {
      throw SupertonicUnavailableException(
        'Supertonic returned no "$name" tensor.',
      );
    }
    return value;
  }

  /// Box-Muller normal samples; the flow starts from noise.
  Float32List _gaussianNoise(int count) {
    final noise = Float32List(count);
    for (var i = 0; i < count; i++) {
      final u1 = math.max(1e-10, _random.nextDouble());
      final u2 = _random.nextDouble();
      noise[i] = math.sqrt(-2.0 * math.log(u1)) * math.cos(2 * math.pi * u2);
    }
    return noise;
  }

  static Float32List _asFloat32(List<dynamic> flat) => flat is Float32List
      ? flat
      : Float32List.fromList(flat.cast<double>());

  String _voiceName(String? configured) =>
      voiceStyles.contains(configured) ? configured! : defaultVoice;

  @override
  Future<void> speak(
    String text, {
    String? voice,
    String? lang,
    double? speed,
  }) async {
    if (text.trim().isEmpty) return;
    await initialize();
    await stop();
    final epoch = _playbackEpoch;
    await _play(
      await _render(text, voice: voice, lang: lang, speed: speed),
      epoch,
    );
  }


  Future<_Clip?> _render(
    String text, {
    String? voice,
    String? lang,
    double? speed,
  }) async {
    final samples =
        await synthesise(text, voice: voice, lang: lang, speed: speed);
    if (samples.isEmpty) return null;
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/supertonic_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(encodeWav(
      samples,
      sampleRate: _sampleRate,
      leadingSilence: AudioClipPlayer.leadingSilence,
    ));
    return _Clip(file, samples.length / _sampleRate);
  }

  Future<void> _play(_Clip? clip, int epoch) async {
    if (clip == null) return;
    if (epoch != _playbackEpoch) {
      unawaited(_delete(clip.file));
      return;
    }
    try {
      await _player.play(
        clip.file,
        expected: clip.duration,
        interrupted: _stopSignal.future,
      );
    } finally {
      unawaited(_delete(clip.file));
    }
  }

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('SupertonicTtsService: could not delete ${file.path}: $e');
    }
  }

  @override
  Future<void> stop() async {
    _playbackEpoch++;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _stopSignal = Completer<void>();
    await _player.stop();
  }

  @override
  Future<void> reload() async {
    await stop();
    await _release();
    await initialize(force: true);
  }

  /// True when the user has switched to the other precision's download.
  @override
  Future<bool> get isStale async {
    final loaded = _loadedBundle;
    if (loaded == null) return false;
    final selected = await _settings.selectedTtsModel;
    return selected != null &&
        bundleNames.contains(selected) &&
        selected != loaded;
  }

  @override
  Future<List<String>> availableVoices() async => voiceStyles;

  @override
  Future<void> dispose() async {
    await stop();
    await _release();
    await _player.dispose();
    _initialization = null;
  }

  Future<void> _release() async {
    for (final style in _styles.values) {
      await style.dispose();
    }
    _styles.clear();
    for (final session in [
      _duration,
      _textEncoder,
      _vectorEstimator,
      _vocoder,
    ]) {
      try {
        await session?.close();
      } catch (e) {
        debugPrint('SupertonicTtsService: error closing session: $e');
      }
    }
    _duration = null;
    _textEncoder = null;
    _vectorEstimator = null;
    _vocoder = null;
    _indexer = const [];
    _loadedBundle = null;
  }
}

/// A rendered clip and how long it plays for.
class _Clip {
  const _Clip(this.file, this.seconds);

  final File file;
  final double seconds;

  Duration get duration => Duration(milliseconds: (seconds * 1000).round());
}

/// One voice, as the two tensors the graphs take.
class _VoiceStyle {
  const _VoiceStyle({required this.ttl, required this.dp});

  final OrtValue ttl;
  final OrtValue dp;

  Future<void> dispose() => Future.wait([ttl.dispose(), dp.dispose()]);
}
