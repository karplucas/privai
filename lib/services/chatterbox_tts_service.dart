import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

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

/// Chatterbox Nano speech synthesis over ONNX Runtime.
///
/// Four graphs, run in sequence:
///
/// 1. `embed_tokens`: `input_ids` -> `inputs_embeds`
/// 2. `language_model`: embeds, attention/position ids + 12 layers of KV cache
///    -> `logits[1,S,6563]` + `present.*`, decoded autoregressively into speech
///    tokens at 25 Hz
/// 3. `speech_encoder`: reference `audio_values` -> `audio_features` (the
///    conditioning prefix the language model generates against),
///    `audio_tokens` (the reference's own speech tokens),
///    `speaker_embeddings[192]` and `speaker_features`, cached per voice
/// 4. `conditional_decoder`: reference + generated speech tokens + speaker
///    tensors -> 24 kHz waveform, in a single pass
///
/// Step 3 runs first: its conditioning embedding is prepended to the text
/// embeddings before the language model's prefill, and its tokens are prepended
/// to the generated ones before the vocoder.
///
/// Measured on a desktop CPU limited to four threads: ~8 ms per token for the
/// language model and ~1.5 s for the vocoder, so a five-second utterance costs a
/// few seconds there and noticeably more on a phone. The sessions also hold well
/// around a gigabyte once weights, caches, and intermediate tensors are live,
/// which is why [TtsEngineKind.requiresExclusiveMemory] is set and the caller
/// unloads the language model first.
class ChatterboxTtsService implements TtsEngine {
  static final ChatterboxTtsService _instance =
      ChatterboxTtsService._internal();
  factory ChatterboxTtsService() => _instance;
  ChatterboxTtsService._internal();

  /// Directory name used by the catalog entry.
  static const String bundleName = 'chatterbox-nano-q4f16';
  static const String _legacyBundleName = 'chatterbox-multilingual-q4';
  static const String _legacyTurboBundleName = 'chatterbox-turbo-q4';

  static const String embedGraph = 'embed_tokens_fp16.onnx';

  /// Weight-only Q4 language model with a float32 KV interface that Dart can
  /// construct for the first decode step.
  static const String languageGraph = 'language_model_q4f16.onnx';
  static const String speechEncoderGraph = 'speech_encoder_q4f16.onnx';
  static const String decoderGraph = 'conditional_decoder_q4.onnx';
  static const String tokenizerFile = 'tokenizer.json';
  static const String defaultVoiceFile = 'default_voice.wav';

  /// Speech tokens per second produced by the language model. Confirmed by
  /// measurement: 75 tokens decoded to 72,000 samples at 24 kHz.
  static const int tokenRateHz = 25;
  static const int sampleRate = 24000;
  static const int hiddenSize = 768;
  static const int layerCount = 12;

  /// Key/value heads and head dimension, from the graph's declared KV shape
  /// `[batch, 16, past_sequence_length, 64]`.
  static const int kvHeads = 12;
  static const int headDim = 64;

  /// Start-of-speech id. Never embedded — the first speech token is sampled
  /// from the prefill — but the repetition penalty counts it as generated.
  static const int _startSpeechToken = 6561;

  /// End-of-speech id used by Nano's 6,563-way speech-token head.
  static const int _stopSpeechToken = 6562;
  static const int _silenceToken = 4299;
  static const double _repetitionPenalty = 1.2;

  /// Absolute ceiling on generated audio, so a degenerate sample cannot spin
  /// forever on a phone. Normal utterances use the much smaller, text-derived
  /// budget from [tokenBudgetForText].
  static const int maxSeconds = 30;

  /// A conservative speech-token budget based on the amount of text to speak.
  ///
  /// Chatterbox normally emits EOS itself, but some prompts miss it and used to
  /// run all the way to the fixed 750-token/30-second ceiling. At roughly 2.3
  /// spoken words per second, plus a short allowance for pauses, this leaves
  /// enough room for natural delivery without generating a long irrelevant
  /// tail. Character units cover languages that do not separate every word
  /// with spaces.
  static int tokenBudgetForText(String text) {
    final words = RegExp(r'\S+').allMatches(text.trim()).length;
    final characterUnits = (text.runes.length / (words <= 1 ? 2 : 6)).ceil();
    final speechUnits = max(words, characterUnits);
    final estimatedSeconds = (1.5 + speechUnits / 2.3).ceil();
    final seconds = min(max(estimatedSeconds, 3), maxSeconds);
    return seconds * tokenRateHz;
  }

  final ModelStorage _storage = ModelStorage();

  OrtSession? _embed;
  OrtSession? _language;
  OrtSession? _decoder;
  OrtSession? _speechEncoder;
  ChatterboxTokenizer? _tokenizer;
  AudioPlayer? _player;
  int _playbackEpoch = 0;

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

      final ort = OnnxRuntime();
      await _availableProviders(ort);
      final cpuOptions = _cpuSessionOptions();

      // Keep every graph on CPU. Core ML can accept these dynamic graphs at
      // session creation and then fail or stall during execution, which leaves
      // the app with no waveform. This is slower, but it is the provider path
      // known to produce correct Chatterbox tensors on both iOS and Android.
      _language = await _createSession(
        ort,
        '${dir.path}/$languageGraph',
        cpuOptions,
        requestedProvider: 'CPU',
      );
      _embed = await ort.createSession('${dir.path}/$embedGraph');
      _decoder = await _createSession(
        ort,
        '${dir.path}/$decoderGraph',
        cpuOptions,
        requestedProvider: 'CPU',
      );

      final encoderPath = '${dir.path}/$speechEncoderGraph';
      if (await File(encoderPath).exists()) {
        _speechEncoder = await _createSession(
          ort,
          encoderPath,
          cpuOptions,
          requestedProvider: 'CPU',
        );
      } else {
        debugPrint('ChatterboxTtsService: no speech encoder; cloning disabled');
      }

      _player ??= AudioPlayer();
      // The old model is no longer represented in the catalog, so it cannot
      // be removed from the models page. Reclaim it only after every Nano
      // session has loaded successfully; all of its files are downloadable.
      try {
        await _storage.deleteBundle(_legacyBundleName);
        await _storage.deleteBundle(_legacyTurboBundleName);
      } catch (e) {
        debugPrint('ChatterboxTtsService: could not remove legacy bundle: $e');
      }
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

  /// Providers compiled into this ONNX Runtime build.
  Future<Set<OrtProvider>> _availableProviders(OnnxRuntime ort) async {
    try {
      final available = (await ort.getAvailableProviders()).toSet();
      debugPrint('ChatterboxTtsService: providers available: '
          '${available.map((p) => p.name).join(', ')}');
      return available;
    } catch (e) {
      debugPrint('ChatterboxTtsService: could not list providers: $e');
      return const {};
    }
  }

  /// CPU settings for the autoregressive language model.
  ///
  /// The CPU provider, parallelised across the cores. The two alternatives this
  /// runtime reports were both tried and are worse here:
  ///
  /// * **XNNPACK** takes its thread count from an `intra_op_num_threads` entry
  ///   in the provider options map, and `flutter_onnxruntime` hardcodes that
  ///   map empty — so it runs single-threaded and cannot be told otherwise
  ///   from Dart. Measured 1100 ms per token against 700 ms for plain CPU. It
  ///   also miscomputed the speech encoder, failing to reshape a {1} tensor to
  ///   the S3 tokenizer's {1,150} prompt.
  /// * **NNAPI** partitions a dynamically shaped, heavily quantised graph like
  ///   this one badly, and the round trip through the driver costs more than
  ///   it saves.
  OrtSessionOptions _cpuSessionOptions() => OrtSessionOptions(
        providers: const [OrtProvider.CPU],
        intraOpNumThreads: Platform.numberOfProcessors,
      );

  /// Creates a session with [options], falling back to the runtime's defaults
  /// if the requested providers are not usable for this graph.
  Future<OrtSession> _createSession(
      OnnxRuntime ort, String path, OrtSessionOptions options,
      {required String requestedProvider}) async {
    try {
      final session = await ort.createSession(path, options: options);
      debugPrint('ChatterboxTtsService: ${path.split('/').last} created with '
          '$requestedProvider requested');
      return session;
    } catch (e) {
      debugPrint('ChatterboxTtsService: ${path.split('/').last} would not load '
          'with the requested providers ($e); using the defaults');
      return ort.createSession(path);
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
    await stop();
    final playbackEpoch = _playbackEpoch;
    final samples = await synthesise(text, lang: lang);
    if (samples.isEmpty || playbackEpoch != _playbackEpoch) return;

    final file = await _writeWav(samples);
    if (playbackEpoch != _playbackEpoch) {
      await _delete(file);
      return;
    }
    await _player!.play(DeviceFileSource(file.path));
    debugPrint('ChatterboxTtsService: playing '
        '${(samples.length / sampleRate).toStringAsFixed(1)}s from ${file.path}');

    // Playback is awaited rather than left running: the caller may be holding
    // the language model out of memory until this utterance completes.
    await _awaitPlayback(samples.length / sampleRate);
    await _delete(file);
  }

  /// Waits for the current utterance to finish, giving up [seconds] plus a
  /// margin so a player that never reports completion cannot hang the caller.
  Future<void> _awaitPlayback(double seconds) async {
    try {
      await _player!.onPlayerComplete.first.timeout(
        Duration(milliseconds: (seconds * 1000).round() + 5000),
      );
    } on TimeoutException {
      debugPrint('ChatterboxTtsService: playback did not report completion');
    } catch (e) {
      debugPrint('ChatterboxTtsService: playback error: $e');
    }
  }

  /// Runs the full pipeline and returns 24 kHz mono samples in -1..1.
  Future<Float32List> synthesise(
    String text, {
    String? referenceWavPath,
    String? lang,
  }) async {
    await initialize();
    final tokenizer = _tokenizer!;

    final speaker = await _conditioning(referenceWavPath);
    final ids = tokenizer.encode(text);
    final speechTokens = await _generateSpeechTokens(
      ids,
      speaker,
      maxTokens: tokenBudgetForText(text),
    );

    if (speechTokens.isEmpty) {
      debugPrint('ChatterboxTtsService: model produced no speech tokens');
      return Float32List(0);
    }
    return _vocode(speechTokens, speaker);
  }

  // --------------------------------------------------------------------------
  // Stage 1 + 2: text -> speech tokens
  // --------------------------------------------------------------------------

  Future<List<int>> _generateSpeechTokens(
    List<int> textIds,
    _SpeakerConditioning speaker, {
    required int maxTokens,
  }) async {
    final embed = _embed!;
    final language = _language!;
    final started = DateTime.now();

    final textEmbeds = await _embedFlat(embed, textIds);

    // The speech encoder's conditioning embedding is prepended to the text
    // embeddings; it carries the speaker and prosody the language model
    // generates against. Without it the model is running unconditioned, which
    // is what made it babble until the token ceiling instead of emitting
    // end-of-speech.
    final prefill =
        Float32List(speaker.condEmbeddings.length + textEmbeds.length)
          ..setAll(0, speaker.condEmbeddings)
          ..setAll(speaker.condEmbeddings.length, textEmbeds);
    final prefillLength = speaker.condFrames + textIds.length;

    var past = await _emptyCache();
    var totalLength = prefillLength;

    var logits = await _stepLanguageModel(
      language,
      embeds: await OrtValue.fromList(prefill, [1, prefillLength, hiddenSize]),
      sequenceLength: prefillLength,
      totalLength: totalLength,
      positionStart: 0,
      past: past,
      onPresent: (next) => past = next,
    );

    final generated = <int>[];

    // Tokens the repetition penalty applies to. Seeded with the start-of-speech
    // id, which the reference counts as the first element of the generated
    // sequence even though it is never embedded.
    final seen = <int>{_startSpeechToken};

    debugPrint('ChatterboxTtsService: prefilled ${speaker.condFrames} '
        'conditioning + ${textIds.length} text positions in '
        '${DateTime.now().difference(started).inMilliseconds}ms, decoding at '
        'most $maxTokens speech tokens');

    for (var step = 0; step < maxTokens; step++) {
      // Progress is logged periodically so a slow run on a memory-starved
      // device is distinguishable from a hung one.
      if (step > 0 && step % 25 == 0) {
        final elapsed = DateTime.now().difference(started).inMilliseconds;
        debugPrint('ChatterboxTtsService: $step tokens in ${elapsed}ms '
            '(${(elapsed / step).toStringAsFixed(0)}ms/token, '
            '~${(step / tokenRateHz).toStringAsFixed(1)}s of audio)');
      }
      final next = _sample(logits, seen);
      if (next == _stopSpeechToken) break;

      generated.add(next);
      seen.add(next);

      totalLength += 1;
      final stepEmbeds = await _runEmbed(embed, [next]);
      logits = await _stepLanguageModel(
        language,
        embeds: stepEmbeds,
        sequenceLength: 1,
        totalLength: totalLength,
        positionStart: totalLength - 1,
        past: past,
        onPresent: (nextCache) => past = nextCache,
      );
    }

    _disposeCache(past);
    debugPrint('ChatterboxTtsService: ${generated.length} speech tokens '
        '(~${(generated.length / tokenRateHz).toStringAsFixed(1)}s)');
    return generated;
  }

  /// Embeddings for [ids], read back as a flat float32 buffer so the caller can
  /// concatenate them with the conditioning prefix.
  Future<Float32List> _embedFlat(
    OrtSession session,
    List<int> ids,
  ) async {
    final value = await _runEmbed(session, ids);
    final flat = (await value.asFlattenedList()).cast<num>();
    await value.dispose();
    return Float32List.fromList([for (final v in flat) v.toDouble()]);
  }

  Future<OrtValue> _runEmbed(
    OrtSession session,
    List<int> ids,
  ) async {
    final inputIds = await OrtValue.fromList(
      Int64List.fromList(ids),
      [1, ids.length],
    );
    final outputs = await session.run({'input_ids': inputIds});

    await inputIds.dispose();

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
  /// straight back as `past_key_values.*` inputs by reference, so 48 tensors per
  /// step never cross the platform channel.
  Future<Float32List> _stepLanguageModel(
    OrtSession session, {
    required OrtValue embeds,
    required int sequenceLength,
    required int totalLength,
    required int positionStart,
    required Map<String, OrtValue> past,
    required void Function(Map<String, OrtValue>) onPresent,
  }) async {
    final mask = await OrtValue.fromList(
      Int64List.fromList(List<int>.filled(totalLength, 1)),
      [1, totalLength],
    );
    final positions = await OrtValue.fromList(
      Int64List.fromList(
        List<int>.generate(sequenceLength, (i) => positionStart + i),
      ),
      [1, sequenceLength],
    );

    final outputs = await session.run({
      'inputs_embeds': embeds,
      'attention_mask': mask,
      'position_ids': positions,
      ...past,
    });

    await mask.dispose();
    await positions.dispose();
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

  /// Builds the zero-length FP16 cache the first pass has to supply.
  ///
  /// Every `past_key_values.*` input is required even when there is no history:
  /// omitting them fails inside the attention kernel with
  /// `Missing Input: past_key_values.0.key`, which is what an empty map produced.
  Future<Map<String, OrtValue>> _emptyCache() async {
    final cache = <String, OrtValue>{};
    for (var layer = 0; layer < layerCount; layer++) {
      for (final part in const ['key', 'value']) {
        final fp32 = await OrtValue.fromList(
          Float32List(0),
          [1, kvHeads, 0, headDim],
        );
        cache['past_key_values.$layer.$part'] =
            await fp32.to(OrtDataType.float16);
        await fp32.dispose();
      }
    }
    return cache;
  }

  void _disposeCache(Map<String, OrtValue> cache) {
    for (final value in cache.values) {
      value.dispose();
    }
  }

  /// Picks the next speech token: greedy, after the repetition penalty from
  /// `generation_config.json`.
  ///
  /// The reference implementation decodes greedily. Sampling was tried here
  /// first and is a poor fit for this stage — a single off-distribution token
  /// derails the rest of the utterance, and it makes the end-of-speech token
  /// something the decoder can miss.
  int _sample(Float32List logits, Set<int> seen) {
    final scaled = Float32List.fromList(logits);

    for (final token in seen) {
      if (token >= scaled.length) continue;
      final value = scaled[token];
      scaled[token] =
          value > 0 ? value / _repetitionPenalty : value * _repetitionPenalty;
    }

    return _argmax(scaled);
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

    // The encoder's four outputs are, in the reference implementation's terms,
    // (cond_emb, prompt_token, ref_x_vector, prompt_feat). The first two were
    // being discarded here, which cost the language model its conditioning and
    // the vocoder its reference prefix.
    final condEmb = outputs['audio_features'];
    final promptTokens = outputs['audio_tokens'];
    final embeddings = outputs['speaker_embeddings'];
    final features = outputs['speaker_features'];
    if (condEmb == null ||
        promptTokens == null ||
        embeddings == null ||
        features == null) {
      throw const ChatterboxUnavailableException(
        'The speech encoder returned no speaker conditioning.',
      );
    }

    // These two are consumed once per utterance rather than passed back into a
    // graph, so they come across the channel now and the tensors are released.
    final condFlat = (await condEmb.asFlattenedList()).cast<num>();
    final condFrames = condEmb.shape.length >= 2 ? condEmb.shape[1] : 0;
    final prompt = (await promptTokens.asFlattenedList()).cast<num>();
    await condEmb.dispose();
    await promptTokens.dispose();

    _speaker = _SpeakerConditioning(
      embeddings: embeddings,
      features: features,
      condEmbeddings: Float32List.fromList([
        for (final v in condFlat) v.toDouble(),
      ]),
      condFrames: condFrames,
      promptTokens: [for (final v in prompt) v.toInt()],
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
    final all = [
      ...speaker.promptTokens,
      ...speechTokens,
      _silenceToken,
      _silenceToken,
      _silenceToken,
    ];
    final tokens = await OrtValue.fromList(
      Int64List.fromList(all),
      [1, all.length],
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

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('ChatterboxTtsService: could not delete ${file.path}: $e');
    }
  }

  @override
  Future<void> stop() async {
    _playbackEpoch++;
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
    required this.condEmbeddings,
    required this.condFrames,
    required this.promptTokens,
  });

  final OrtValue embeddings;
  final OrtValue features;

  /// `cond_emb`, flattened `[condFrames][hiddenSize]`. Prepended to the text
  /// embeddings before the language model's first pass.
  final Float32List condEmbeddings;

  final int condFrames;

  /// Speech tokens for the reference audio, prepended to the generated ones so
  /// the vocoder has the voice it is continuing. It trims them from the output.
  final List<int> promptTokens;

  Future<void> dispose() async {
    await embeddings.dispose();
    await features.dispose();
  }
}
