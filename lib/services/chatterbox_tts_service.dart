import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'chatterbox_tokenizer.dart';
import 'model_storage.dart';
import 'tts_engine.dart';
import 'wav.dart';

/// Raised when Chatterbox cannot synthesise, with a message worth showing.
class ChatterboxUnavailableException implements Exception {
  const ChatterboxUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Chatterbox Multilingual speech synthesis over ONNX Runtime.
///
/// Four graphs, run in sequence:
///
/// 1. `embed_tokens`: `input_ids`,`position_ids`,`exaggeration` -> `inputs_embeds`
/// 2. `language_model`: `inputs_embeds`,`attention_mask` + 30 layers of KV cache
///    -> `logits[1,S,8194]` + `present.*`, decoded autoregressively into speech
///    tokens at 25 Hz
/// 3. `speech_encoder`: reference `audio_values` -> `speaker_embeddings[192]`,
///    `speaker_features`, cached per voice
/// 4. `conditional_decoder`: speech tokens + speaker tensors -> 24 kHz waveform,
///    in a single pass
///
/// Measured on a desktop CPU limited to four threads: ~8 ms per token for the
/// language model and ~1.5 s for the vocoder, so a five-second utterance costs a
/// few seconds there and noticeably more on a phone. The sessions also hold well
/// over a gigabyte, which is why [TtsEngineKind.requiresExclusiveMemory] is set
/// and the caller unloads the language model first.
class ChatterboxTtsService implements TtsEngine {
  static final ChatterboxTtsService _instance =
      ChatterboxTtsService._internal();
  factory ChatterboxTtsService() => _instance;
  ChatterboxTtsService._internal();

  /// Directory name used by the catalog entry.
  static const String bundleName = 'chatterbox-multilingual';

  static const String embedGraph = 'embed_tokens.onnx';

  /// The q4 export, not q4f16.
  ///
  /// Both hold the same weights, but q4f16's KV cache is float16 and
  /// `OrtValue.fromList` can only build float32/int32/int64/uint8/bool tensors.
  /// The first pass has to supply 60 empty cache tensors itself — the graph
  /// requires them even at zero length — so the float32-cache export is the one
  /// that can actually be driven from Dart. Costs about 49 MB more.
  static const String languageGraph = 'language_model_q4.onnx';
  static const String speechEncoderGraph = 'speech_encoder.onnx';
  static const String decoderGraph = 'conditional_decoder.onnx';
  static const String tokenizerFile = 'tokenizer.json';
  static const String defaultVoiceFile = 'default_voice.wav';

  /// Speech tokens per second produced by the language model. Confirmed by
  /// measurement: 75 tokens decoded to 72,000 samples at 24 kHz.
  static const int tokenRateHz = 25;
  static const int sampleRate = 24000;
  static const int hiddenSize = 1024;
  static const int layerCount = 30;

  /// Key/value heads and head dimension, from the graph's declared KV shape
  /// `[batch, 16, past_sequence_length, 64]`.
  static const int kvHeads = 16;
  static const int headDim = 64;

  /// End-of-speech ids from the repository's `generation_config.json`.
  static const Set<int> _eosTokens = {2, 6562};
  static const double _repetitionPenalty = 1.2;

  /// Hard ceiling on generated audio, so a degenerate sample cannot spin
  /// forever on a phone.
  static const int maxSeconds = 30;

  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();
  final Random _random = Random();

  OrtSession? _embed;
  OrtSession? _language;
  OrtSession? _decoder;
  OrtSession? _speechEncoder;
  ChatterboxTokenizer? _tokenizer;
  AudioPlayer? _player;

  _SpeakerConditioning? _speaker;
  String? _speakerSource;

  Future<void>? _initialization;

  @override
  TtsEngineKind get kind => TtsEngineKind.chatterbox;

  @override
  bool get isInitialized => _language != null;

  @override
  Future<void> initialize({bool force = false}) {
    if (force) _initialization = null;
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    try {
      final dir = await _storage.bundleDirectory(bundleName);

      for (final name in [
        embedGraph,
        languageGraph,
        decoderGraph,
        tokenizerFile,
      ]) {
        if (!await File('${dir.path}/$name').exists()) {
          throw ChatterboxUnavailableException(
            'Chatterbox is not fully downloaded ("$name" is missing). Open '
            'Settings & models to finish the download.',
          );
        }
      }

      _tokenizer =
          await ChatterboxTokenizer.fromFile('${dir.path}/$tokenizerFile');

      // ONNX Runtime finds each graph's `.onnx_data` sidecar by the name
      // recorded inside it, resolved next to the graph — which is why the
      // bundle keeps them in one directory under their original names.
      final ort = OnnxRuntime();
      _embed = await ort.createSession('${dir.path}/$embedGraph');
      _language = await ort.createSession('${dir.path}/$languageGraph');
      _decoder = await ort.createSession('${dir.path}/$decoderGraph');

      final encoderPath = '${dir.path}/$speechEncoderGraph';
      if (await File(encoderPath).exists()) {
        _speechEncoder = await ort.createSession(encoderPath);
      } else {
        debugPrint('ChatterboxTtsService: no speech encoder; cloning disabled');
      }

      _player ??= AudioPlayer();
      debugPrint(
        'ChatterboxTtsService: ready ($_tokenizer, '
        '${_language!.inputNames.length} LM inputs)',
      );
    } catch (e) {
      await _releaseSessions();
      _initialization = null;
      debugPrint('ChatterboxTtsService: initialisation failed: $e');
      rethrow;
    }
  }

  @override
  Future<void> reload() async {
    await stop();
    await _releaseSessions();
    await initialize(force: true);
  }

  @override
  Future<bool> get isStale async => false;

  /// Chatterbox clones whatever reference audio it is given rather than
  /// offering a fixed set, so the only named voice is the bundled default.
  @override
  Future<List<String>> availableVoices() async => const ['default'];

  @override
  Future<void> speak(
    String text, {
    String? voice,
    String? lang,
    double? speed,
  }) async {
    if (text.trim().isEmpty) return;
    await initialize();

    final samples = await synthesise(text);
    if (samples.isEmpty) return;

    final file = await _writeWav(samples);
    await stop();
    await _player!.play(DeviceFileSource(file.path));
    unawaited(_deleteWhenFinished(file));
  }

  /// Runs the full pipeline and returns 24 kHz mono samples in -1..1.
  Future<Float32List> synthesise(String text, {String? referenceWavPath}) async {
    await initialize();
    final tokenizer = _tokenizer!;

    final speaker = await _conditioning(referenceWavPath);
    final ids = tokenizer.encode(text);
    final speechTokens = await _generateSpeechTokens(ids);

    if (speechTokens.isEmpty) {
      debugPrint('ChatterboxTtsService: model produced no speech tokens');
      return Float32List(0);
    }
    return _vocode(speechTokens, speaker);
  }

  // --------------------------------------------------------------------------
  // Stage 1 + 2: text -> speech tokens
  // --------------------------------------------------------------------------

  Future<List<int>> _generateSpeechTokens(List<int> textIds) async {
    final embed = _embed!;
    final language = _language!;
    const maxTokens = maxSeconds * tokenRateHz;

    final promptEmbeds = await _runEmbed(embed, textIds, positionOffset: 0);

    var past = await _emptyCache();
    var totalLength = textIds.length;

    var logits = await _stepLanguageModel(
      language,
      embeds: promptEmbeds,
      sequenceLength: textIds.length,
      totalLength: totalLength,
      past: past,
      onPresent: (next) => past = next,
    );

    final generated = <int>[];
    final counts = <int, int>{};
    final started = DateTime.now();

    debugPrint('ChatterboxTtsService: prompt of ${textIds.length} tokens '
        'prefilled in ${DateTime.now().difference(started).inMilliseconds}ms, '
        'decoding up to $maxTokens speech tokens');

    for (var step = 0; step < maxTokens; step++) {
      // Progress is logged periodically so a slow run on a memory-starved
      // device is distinguishable from a hung one.
      if (step > 0 && step % 25 == 0) {
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        debugPrint('ChatterboxTtsService: $step tokens in ${elapsed}ms '
            '(${(elapsed / step).toStringAsFixed(0)}ms/token, '
            '~${(step / tokenRateHz).toStringAsFixed(1)}s of audio)');
      }
      final next = _sample(logits, counts);
      if (_eosTokens.contains(next)) break;

      generated.add(next);
      counts[next] = (counts[next] ?? 0) + 1;

      totalLength += 1;
      final stepEmbeds = await _runEmbed(
        embed,
        [next],
        positionOffset: totalLength - 1,
      );
      logits = await _stepLanguageModel(
        language,
        embeds: stepEmbeds,
        sequenceLength: 1,
        totalLength: totalLength,
        past: past,
        onPresent: (nextCache) => past = nextCache,
      );
    }

    _disposeCache(past);
    debugPrint('ChatterboxTtsService: ${generated.length} speech tokens '
        '(~${(generated.length / tokenRateHz).toStringAsFixed(1)}s)');
    return generated;
  }

  Future<OrtValue> _runEmbed(
    OrtSession session,
    List<int> ids, {
    required int positionOffset,
  }) async {
    final inputIds = await OrtValue.fromList(
      Int64List.fromList(ids),
      [1, ids.length],
    );
    final positions = await OrtValue.fromList(
      Int64List.fromList(
        List<int>.generate(ids.length, (i) => positionOffset + i),
      ),
      [1, ids.length],
    );
    final exaggeration = await OrtValue.fromList(
      Float32List.fromList([await _settings.chatterboxExaggeration]),
      [1],
    );

    final outputs = await session.run({
      'input_ids': inputIds,
      'position_ids': positions,
      'exaggeration': exaggeration,
    });

    await inputIds.dispose();
    await positions.dispose();
    await exaggeration.dispose();

    final embeds = outputs['inputs_embeds'];
    if (embeds == null) {
      throw const ChatterboxUnavailableException(
        'The embedding graph returned no inputs_embeds.',
      );
    }
    return embeds;
  }

  /// One language-model pass, replacing [past] with the returned cache.
  ///
  /// The KV tensors stay on the native side: `present.*` outputs are handed
  /// straight back as `past_key_values.*` inputs by reference, so 60 tensors per
  /// step never cross the platform channel.
  Future<Float32List> _stepLanguageModel(
    OrtSession session, {
    required OrtValue embeds,
    required int sequenceLength,
    required int totalLength,
    required Map<String, OrtValue> past,
    required void Function(Map<String, OrtValue>) onPresent,
  }) async {
    final mask = await OrtValue.fromList(
      Int64List.fromList(List<int>.filled(totalLength, 1)),
      [1, totalLength],
    );

    final outputs = await session.run({
      'inputs_embeds': embeds,
      'attention_mask': mask,
      ...past,
    });

    await mask.dispose();
    await embeds.dispose();

    final next = <String, OrtValue>{};
    for (var layer = 0; layer < layerCount; layer++) {
      for (final part in const ['key', 'value']) {
        final value = outputs['present.$layer.$part'];
        if (value != null) next['past_key_values.$layer.$part'] = value;
      }
    }
    // Free the previous step's cache only after the new one is captured.
    _disposeCache(past);
    onPresent(next);

    final logits = outputs['logits'];
    if (logits == null) {
      throw const ChatterboxUnavailableException(
        'The language model returned no logits.',
      );
    }

    // Only the final position matters when decoding.
    final flat = (await logits.asFlattenedList()).cast<num>();
    await logits.dispose();

    final vocab = flat.length ~/ sequenceLength;
    final start = (sequenceLength - 1) * vocab;
    return Float32List.fromList([
      for (var i = start; i < start + vocab; i++) flat[i].toDouble(),
    ]);
  }

  /// Builds the zero-length cache the first pass has to supply.
  ///
  /// Every `past_key_values.*` input is required even when there is no history:
  /// omitting them fails inside the attention kernel with
  /// `Missing Input: past_key_values.0.key`, which is what an empty map produced.
  Future<Map<String, OrtValue>> _emptyCache() async {
    final cache = <String, OrtValue>{};
    for (var layer = 0; layer < layerCount; layer++) {
      for (final part in const ['key', 'value']) {
        cache['past_key_values.$layer.$part'] = await OrtValue.fromList(
          Float32List(0),
          [1, kvHeads, 0, headDim],
        );
      }
    }
    return cache;
  }

  void _disposeCache(Map<String, OrtValue> cache) {
    for (final value in cache.values) {
      value.dispose();
    }
  }

  /// Temperature/top-p sampling with the repetition penalty from
  /// `generation_config.json`.
  int _sample(Float32List logits, Map<int, int> counts) {
    final scaled = Float32List.fromList(logits);

    for (final entry in counts.entries) {
      if (entry.key >= scaled.length) continue;
      final value = scaled[entry.key];
      scaled[entry.key] =
          value > 0 ? value / _repetitionPenalty : value * _repetitionPenalty;
    }

    const temperature = 0.8;
    var maxLogit = double.negativeInfinity;
    for (final value in scaled) {
      if (value > maxLogit) maxLogit = value;
    }

    final probs = Float64List(scaled.length);
    var sum = 0.0;
    for (var i = 0; i < scaled.length; i++) {
      final p = exp((scaled[i] - maxLogit) / temperature);
      probs[i] = p;
      sum += p;
    }
    if (sum <= 0 || !sum.isFinite) return _argmax(scaled);

    final order = List<int>.generate(scaled.length, (i) => i)
      ..sort((a, b) => probs[b].compareTo(probs[a]));

    const topP = 0.9;
    var cumulative = 0.0;
    final target = _random.nextDouble() * topP * sum;
    for (final index in order) {
      cumulative += probs[index];
      if (cumulative >= target) return index;
    }
    return order.first;
  }

  int _argmax(Float32List values) {
    var best = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] > values[best]) best = i;
    }
    return best;
  }

  // --------------------------------------------------------------------------
  // Stage 3: reference voice
  // --------------------------------------------------------------------------

  /// Speaker conditioning for [referenceWavPath], or the bundled default voice.
  ///
  /// Cached: the encoder is ~590 MB and the result only changes when the
  /// reference audio does.
  Future<_SpeakerConditioning> _conditioning(String? referenceWavPath) async {
    final dir = await _storage.bundleDirectory(bundleName);
    final source = referenceWavPath ?? '${dir.path}/$defaultVoiceFile';

    if (_speaker != null && _speakerSource == source) return _speaker!;

    final encoder = _speechEncoder;
    if (encoder == null) {
      throw const ChatterboxUnavailableException(
        'The Chatterbox speech encoder is not downloaded, so no reference voice '
        'can be encoded.',
      );
    }
    if (!await File(source).exists()) {
      throw ChatterboxUnavailableException(
        'Reference voice audio is missing at $source.',
      );
    }

    final audio = await readWavMono(source, targetSampleRate: sampleRate);
    final input = await OrtValue.fromList(audio, [1, audio.length]);
    final outputs = await encoder.run({'audio_values': input});
    await input.dispose();

    final embeddings = outputs['speaker_embeddings'];
    final features = outputs['speaker_features'];
    if (embeddings == null || features == null) {
      throw const ChatterboxUnavailableException(
        'The speech encoder returned no speaker conditioning.',
      );
    }

    // audio_tokens/audio_features are not needed downstream.
    for (final name in const ['audio_tokens', 'audio_features']) {
      await outputs[name]?.dispose();
    }

    _speaker = _SpeakerConditioning(
      embeddings: embeddings,
      features: features,
      frameCount: features.shape.length >= 2 ? features.shape[1] : 0,
    );
    _speakerSource = source;
    return _speaker!;
  }

  // --------------------------------------------------------------------------
  // Stage 4: speech tokens -> waveform
  // --------------------------------------------------------------------------

  Future<Float32List> _vocode(
    List<int> speechTokens,
    _SpeakerConditioning speaker,
  ) async {
    final tokens = await OrtValue.fromList(
      Int64List.fromList(speechTokens),
      [1, speechTokens.length],
    );

    final outputs = await _decoder!.run({
      'speech_tokens': tokens,
      'speaker_embeddings': speaker.embeddings,
      'speaker_features': speaker.features,
    });
    await tokens.dispose();

    final waveform = outputs['waveform'];
    if (waveform == null) {
      throw const ChatterboxUnavailableException(
        'The vocoder returned no waveform.',
      );
    }

    final flat = (await waveform.asFlattenedList()).cast<num>();
    await waveform.dispose();

    final samples = Float32List(flat.length);
    for (var i = 0; i < flat.length; i++) {
      samples[i] = flat[i].toDouble();
    }
    return samples;
  }

  Future<File> _writeWav(Float32List samples) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/chatterbox_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(encodeWav(samples, sampleRate: sampleRate));
    return file;
  }

  Future<void> _deleteWhenFinished(File file) async {
    try {
      await _player?.onPlayerComplete.first;
    } catch (_) {
      // Interrupted; the file still needs removing.
    }
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('ChatterboxTtsService: could not delete ${file.path}: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('ChatterboxTtsService: error stopping playback: $e');
    }
  }

  Future<void> _releaseSessions() async {
    await _speaker?.dispose();
    _speaker = null;
    _speakerSource = null;
    for (final session in [_embed, _language, _decoder, _speechEncoder]) {
      try {
        await session?.close();
      } catch (e) {
        debugPrint('ChatterboxTtsService: error closing session: $e');
      }
    }
    _embed = null;
    _language = null;
    _decoder = null;
    _speechEncoder = null;
    _tokenizer = null;
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _releaseSessions();
    _initialization = null;
    await _player?.dispose();
    _player = null;
  }
}

/// Cached speaker conditioning tensors, held native-side between utterances.
class _SpeakerConditioning {
  _SpeakerConditioning({
    required this.embeddings,
    required this.features,
    required this.frameCount,
  });

  final OrtValue embeddings;
  final OrtValue features;

  /// Reference mel frames, at twice the speech-token rate. The vocoder consumes
  /// `frameCount / 2` tokens' worth of prompt and trims it from the output.
  final int frameCount;

  Future<void> dispose() async {
    await embeddings.dispose();
    await features.dispose();
  }
}
