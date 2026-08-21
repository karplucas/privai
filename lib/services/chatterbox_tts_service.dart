import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_clip_player.dart';
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

  static final RegExp _wordPattern = RegExp(r'\S+');

  /// A conservative speech-token budget based on the amount of text to speak.
  ///
  /// Chatterbox normally emits EOS itself, but some prompts miss it and used to
  /// run all the way to the fixed 750-token/30-second ceiling. At roughly 2.3
  /// spoken words per second, plus a short allowance for pauses, this leaves
  /// enough room for natural delivery without generating a long irrelevant
  /// tail. Character units cover languages that do not separate every word
  /// with spaces.
  static int tokenBudgetForText(String text) {
    final estimatedSeconds = (1.5 + _speechUnits(text) / _unitsPerSecond).ceil();
    final seconds = min(max(estimatedSeconds, 3), maxSeconds);
    return seconds * tokenRateHz;
  }

  /// Spoken words per second, give or take, used to turn a length of text into
  /// a length of audio.
  static const double _unitsPerSecond = 2.3;

  /// Word-equivalents in [text]. Character units cover languages that do not
  /// separate every word with spaces.
  static int _speechUnits(String text) {
    final words = _wordPattern.allMatches(text.trim()).length;
    final characterUnits = (text.runes.length / (words <= 1 ? 2 : 6)).ceil();
    return max(words, characterUnits);
  }

  final ModelStorage _storage = ModelStorage();

  OrtSession? _embed;
  OrtSession? _language;
  OrtSession? _decoder;
  OrtSession? _speechEncoder;
  ChatterboxTokenizer? _tokenizer;
  final AudioClipPlayer _player = AudioClipPlayer('ChatterboxTtsService');

  /// Completed by [stop] so a clip that is cut short stops being awaited at
  /// once. `AudioPlayer.stop()` emits no completion event, so without this the
  /// queue sat waiting on audio that would never finish — which is why the
  /// chat's stop button stayed lit after it had been pressed.
  Completer<void> _stopSignal = Completer<void>();
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

      // Keep every graph on CPU. Core ML was tried for the speech encoder and
      // vocoder — both fixed-shape, single-pass graphs where the language
      // model's dynamic-KV-cache problem does not apply — and it was still
      // markedly slower in practice, most likely from falling back to
      // per-node CPU execution on these quantised ops or from ANE compile
      // stalls. CPU throughout remains the provider path known to produce
      // correct Chatterbox tensors quickly on both iOS and Android.
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

      await _player.warmUp();
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
    await _play(await _render(text, lang: lang), playbackEpoch);
  }


  /// Synthesises [text] and encodes it to the WAV file the player wants.
  ///
  /// Encoding and writing are part of preparation rather than playback so they
  /// happen while the previous utterance is still playing. Left in [_play] they
  /// sit squarely in the gap between clips, where a couple of hundred kilobytes
  /// of PCM conversion and file I/O are audible as a pause.
  Future<_Utterance?> _render(String text, {String? lang}) async {
    final samples = await synthesise(text, lang: lang);
    if (samples.isEmpty) return null;
    return _Utterance(
      file: await _writeWav(samples),
      seconds: samples.length / sampleRate,
    );
  }

  /// Plays a rendered utterance, returning once it has finished.
  ///
  /// Playback is awaited rather than left running: the caller may be holding
  /// the language model out of memory until this utterance completes.
  Future<void> _play(_Utterance? utterance, int playbackEpoch) async {
    if (utterance == null) return;
    if (playbackEpoch != _playbackEpoch) {
      unawaited(_delete(utterance.file));
      return;
    }

    debugPrint('ChatterboxTtsService: playing '
        '${utterance.seconds.toStringAsFixed(1)}s from ${utterance.file.path}');
    try {
      await _player.play(
        utterance.file,
        expected: Duration(milliseconds: (utterance.seconds * 1000).round()),
        interrupted: _stopSignal.future,
      );
    } finally {
      // Deleting is not on the critical path between two clips.
      unawaited(_delete(utterance.file));
    }
  }

  /// Runs the full pipeline and returns 24 kHz mono samples in -1..1.
  Future<Float32List> synthesise(
    String text, {
    String? referenceWavPath,
    String? lang,
  }) async {
    final total = Stopwatch()..start();
    final stage = Stopwatch()..start();

    await initialize();
    final loadMs = stage.elapsedMilliseconds;
    final tokenizer = _tokenizer!;

    stage.reset();
    final speaker = await _conditioning(referenceWavPath);
    final conditioningMs = stage.elapsedMilliseconds;

    stage.reset();
    final ids = tokenizer.encode(text);
    final tokenizeMs = stage.elapsedMilliseconds;

    stage.reset();
    final speechTokens = await _generateSpeechTokens(
      ids,
      speaker,
      maxTokens: tokenBudgetForText(text),
    );
    final decodeMs = stage.elapsedMilliseconds;

    if (speechTokens.isEmpty) {
      debugPrint('ChatterboxTtsService: model produced no speech tokens');
      return Float32List(0);
    }

    stage.reset();
    final audio = await _vocode(speechTokens, speaker);
    final vocodeMs = stage.elapsedMilliseconds;

    lastProfile = ChatterboxProfile(
      loadMs: loadMs,
      conditioningMs: conditioningMs,
      tokenizeMs: tokenizeMs,
      prefillMs: _lastPrefillMs,
      decodeMs: decodeMs,
      vocodeMs: vocodeMs,
      totalMs: total.elapsedMilliseconds,
      speechTokens: speechTokens.length,
      audioSeconds: audio.length / sampleRate,
    );
    debugPrint('ChatterboxTtsService: $lastProfile');
    return audio;
  }

  /// Timings of the most recent [synthesise], for profiling on a device.
  ChatterboxProfile? lastProfile;

  /// Prefill cost of the last decode, measured inside the token loop.
  int _lastPrefillMs = 0;

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

    // The last text token is decoded in its own single-position pass. Its
    // logits sample the first speech token; the prefill only populates the KV
    // cache. Reading the prefill's own `[1, prefillLength, 6563]` logits just
    // to reach the final row would drag several megabytes of activations
    // across the platform channel and materialise them in the Dart heap, on a
    // pipeline that is already close to its memory ceiling, so the cache-only
    // pass discards them native-side instead. The results are identical: the
    // LM is causal, so position `prefillLength` sees the same keys and values
    // whether it is the tail of the prefill or a pass of its own. It does cost
    // one full extra forward pass — one token's worth of decode against a
    // hundred or more in the loop below.
    final head = textIds.sublist(0, textIds.length - 1);
    final textEmbeds = await _embedFlat(embed, head);
    final prefillLength = speaker.condFrames + head.length;

    // The speech encoder's conditioning embedding is prepended to the text
    // embeddings; it carries the speaker and prosody the language model
    // generates against. Without it the model is running unconditioned, which
    // is what made it babble until the token ceiling instead of emitting
    // end-of-speech.
    final prefill =
        Float32List(speaker.condEmbeddings.length + textEmbeds.length)
          ..setAll(0, speaker.condEmbeddings)
          ..setAll(speaker.condEmbeddings.length, textEmbeds);

    var past = await _emptyCache();
    var totalLength = prefillLength;

    final prefillWatch = Stopwatch()..start();
    await _stepLanguageModel(
      language,
      embeds: await OrtValue.fromList(prefill, [1, prefillLength, hiddenSize]),
      sequenceLength: prefillLength,
      totalLength: totalLength,
      positionStart: 0,
      past: past,
      onPresent: (next) => past = next,
      readLogits: false,
    );

    _lastPrefillMs = prefillWatch.elapsedMilliseconds;

    totalLength += 1;
    final lastEmbeds = await _runEmbed(embed, [textIds.last]);
    var logits = await _stepLanguageModel(
      language,
      embeds: lastEmbeds,
      sequenceLength: 1,
      totalLength: totalLength,
      positionStart: totalLength - 1,
      past: past,
      onPresent: (next) => past = next,
    );

    final generated = <int>[];

    // Tokens the repetition penalty applies to. Seeded with the start-of-speech
    // id, which the reference counts as the first element of the generated
    // sequence even though it is never embedded.
    final seen = <int>{_startSpeechToken};

    debugPrint('ChatterboxTtsService: prefilled ${speaker.condFrames} '
        'conditioning + ${head.length} text positions in '
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
      final next = _sample(logits!, seen);
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

    await _disposeCache(past);
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
    final flat = _asFloat32(await value.asFlattenedList());
    await value.dispose();
    return flat;
  }

  /// A float tensor's contents, without a copy where one is avoidable.
  ///
  /// Both float32 and float16 tensors come across the platform channel as
  /// `FlutterStandardTypedData(float32:)`, which the codec decodes straight
  /// into a [Float32List] view. Only the fallback — a platform that hands back
  /// a boxed list — pays for a conversion, and the biggest reads here are whole
  /// waveforms.
  ///
  /// **The result is read-only.** Flutter wraps every incoming platform message
  /// in `ByteData.asUnmodifiableView`, so the returned list is a view onto that
  /// buffer and writing to it throws `Cannot modify an unmodifiable list`.
  /// Callers may read it, copy it, or slice it, but must not scale values in
  /// place — see [_sample], which folds its repetition penalty into the search
  /// for exactly this reason.
  static Float32List _asFloat32(List<dynamic> flat) =>
      flat is Float32List ? flat : Float32List.fromList(flat.cast<double>());

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
  ///
  /// Returns the last position's logits, or `null` when [readLogits] is false.
  /// A cache-only pass still pays the forward pass but skips pulling the whole
  /// `[1, sequence, vocab]` logits tensor across the channel, which is wasteful
  /// when only the final row would be read (as in the prefill).
  Future<Float32List?> _stepLanguageModel(
    OrtSession session, {
    required OrtValue embeds,
    required int sequenceLength,
    required int totalLength,
    required int positionStart,
    required Map<String, OrtValue> past,
    required void Function(Map<String, OrtValue>) onPresent,
    bool readLogits = true,
  }) async {
    final maskData = Int64List(totalLength)..fillRange(0, totalLength, 1);
    final positionsData = Int64List(sequenceLength);
    for (var i = 0; i < sequenceLength; i++) {
      positionsData[i] = positionStart + i;
    }
    // Both scratch tensors are created in one batch: the platform side handles
    // them one at a time regardless, but the messages queue up together
    // instead of each waiting for the previous reply to make it back to Dart.
    final scratch = await Future.wait([
      OrtValue.fromList(maskData, [1, totalLength]),
      OrtValue.fromList(positionsData, [1, sequenceLength]),
    ]);
    final mask = scratch[0];
    final positions = scratch[1];

    final outputs = await session.run({
      'inputs_embeds': embeds,
      'attention_mask': mask,
      'position_ids': positions,
      ...past,
    });

    final next = <String, OrtValue>{};
    for (var layer = 0; layer < layerCount; layer++) {
      for (final part in const ['key', 'value']) {
        final value = outputs['present.$layer.$part'];
        if (value != null) next['past_key_values.$layer.$part'] = value;
      }
    }
    onPresent(next);

    final logits = outputs['logits'];
    final flat = readLogits && logits != null
        ? _asFloat32(await logits.asFlattenedList())
        : null;

    // Everything this step allocated goes back in one batch: the two scratch
    // inputs, the embeddings, the logits, and the cache the pass just
    // superseded. Awaiting each release on its own cost 28 sequential round
    // trips per token. The previous cache is released only after the new one
    // has been captured above.
    await Future.wait([
      mask.dispose(),
      positions.dispose(),
      embeds.dispose(),
      _disposeCache(past),
      if (logits != null) logits.dispose(),
    ]);

    if (logits == null) {
      throw const ChatterboxUnavailableException(
        'The language model returned no logits.',
      );
    }
    if (flat == null) return null;

    // Only the final position matters when decoding, and every pass that asks
    // for logits supplies a single position, so the buffer already is that row.
    if (sequenceLength == 1) return flat;

    final vocab = flat.length ~/ sequenceLength;
    final start = (sequenceLength - 1) * vocab;
    return Float32List.fromList(
      Float32List.sublistView(flat, start, start + vocab),
    );
  }

  /// Builds the zero-length FP16 cache the first pass has to supply.
  ///
  /// Every `past_key_values.*` input is required even when there is no history:
  /// omitting them fails inside the attention kernel with
  /// `Missing Input: past_key_values.0.key`, which is what an empty map produced.
  Future<Map<String, OrtValue>> _emptyCache() async {
    final names = <String>[
      for (var layer = 0; layer < layerCount; layer++)
        for (final part in const ['key', 'value'])
          'past_key_values.$layer.$part',
    ];
    // All 24 entries are built at once. Sequentially this was 72 channel round
    // trips before the first token of every utterance.
    final values = await Future.wait(names.map((_) => _emptyKeyValue()));
    return Map.fromIterables(names, values);
  }

  Future<OrtValue> _emptyKeyValue() async {
    final fp32 = await OrtValue.fromList(
      Float32List(0),
      [1, kvHeads, 0, headDim],
    );
    final fp16 = await fp32.to(OrtDataType.float16);
    await fp32.dispose();
    return fp16;
  }

  Future<void> _disposeCache(Map<String, OrtValue> cache) =>
      Future.wait(cache.values.map((value) => value.dispose()));

  /// Picks the next speech token: greedy, after the repetition penalty from
  /// `generation_config.json`.
  ///
  /// The reference implementation decodes greedily. Sampling was tried here
  /// first and is a poor fit for this stage — a single off-distribution token
  /// derails the rest of the utterance, and it makes the end-of-speech token
  /// something the decoder can miss.
  ///
  /// [logits] is read but never written: it is the platform channel's own
  /// buffer, which Flutter hands over as an unmodifiable view, so penalising a
  /// token in place throws `Cannot modify an unmodifiable list`. Copying the
  /// whole vocabulary per token just to scale a handful of entries is not worth
  /// it either, so the penalty is folded into the search instead.
  ///
  /// The penalty only ever lowers a score — a positive logit is divided, a
  /// negative one is pushed further negative — so the winner is either the best
  /// token that has not been generated yet or the best penalised one, and the
  /// two passes below cover both. Membership is tested only when a new maximum
  /// turns up, which is a handful of lookups across the 6,563 entries rather
  /// than one per entry.
  int _sample(Float32List logits, Set<int> seen) {
    var best = 0;
    var bestValue = double.negativeInfinity;
    for (var i = 0; i < logits.length; i++) {
      final value = logits[i];
      if (value > bestValue && !seen.contains(i)) {
        bestValue = value;
        best = i;
      }
    }

    for (final token in seen) {
      if (token >= logits.length) continue;
      final value = logits[token];
      final penalised =
          value > 0 ? value / _repetitionPenalty : value * _repetitionPenalty;
      if (penalised > bestValue) {
        bestValue = penalised;
        best = token;
      }
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
    final condFlat = _asFloat32(await condEmb.asFlattenedList());
    final condFrames = condEmb.shape.length >= 2 ? condEmb.shape[1] : 0;
    final prompt = await promptTokens.asFlattenedList();
    await Future.wait([condEmb.dispose(), promptTokens.dispose()]);

    _speaker = _SpeakerConditioning(
      embeddings: embeddings,
      features: features,
      condEmbeddings: condFlat,
      condFrames: condFrames,
      promptTokens: List<int>.from(prompt),
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
    final started = DateTime.now();
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

    final flat = _asFloat32(await waveform.asFlattenedList());
    await waveform.dispose();

    debugPrint('ChatterboxTtsService: vocoded ${all.length} tokens into '
        '${(flat.length / sampleRate).toStringAsFixed(1)}s of audio in '
        '${DateTime.now().difference(started).inMilliseconds}ms');
    return flat;
  }

  Future<File> _writeWav(Float32List samples) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/chatterbox_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(encodeWav(
      samples,
      sampleRate: sampleRate,
      leadingSilence: AudioClipPlayer.leadingSilence,
    ));
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
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _stopSignal = Completer<void>();
    await _player.stop();
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
    await _player.dispose();
  }
}

/// One synthesised utterance, encoded and ready for the player.
class _Utterance {
  const _Utterance({required this.file, required this.seconds});

  final File file;
  final double seconds;
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

/// Where the time went in one Chatterbox utterance.
///
/// Added to answer "what part of it is so slow" with measurements rather than
/// assumptions. The decode figure is the one that matters: it is the
/// autoregressive loop, one language-model pass per speech token, and it grows
/// with the length of the reply while everything else is roughly fixed.
class ChatterboxProfile {
  const ChatterboxProfile({
    required this.loadMs,
    required this.conditioningMs,
    required this.tokenizeMs,
    required this.prefillMs,
    required this.decodeMs,
    required this.vocodeMs,
    required this.totalMs,
    required this.speechTokens,
    required this.audioSeconds,
  });

  /// Session creation, zero after the first utterance of a session.
  final int loadMs;

  /// The speech encoder over the reference voice, cached between utterances.
  final int conditioningMs;
  final int tokenizeMs;

  /// The single prefill pass over the whole prompt, part of [decodeMs].
  final int prefillMs;

  /// The autoregressive loop, including [prefillMs].
  final int decodeMs;

  /// The vocoder's single pass over every generated token.
  final int vocodeMs;
  final int totalMs;
  final int speechTokens;
  final double audioSeconds;

  /// Milliseconds per generated speech token, the loop's unit cost.
  double get msPerToken =>
      speechTokens == 0 ? 0 : (decodeMs - prefillMs) / speechTokens;

  /// Seconds of compute per second of audio. Below 1.0 is faster than real
  /// time; Chatterbox is well above it on a phone, which is what is heard as
  /// the pause before a reply is spoken.
  double get realTimeFactor =>
      audioSeconds == 0 ? 0 : totalMs / 1000 / audioSeconds;

  @override
  String toString() => 'profile: total ${totalMs}ms for '
      '${audioSeconds.toStringAsFixed(1)}s audio (rtf '
      '${realTimeFactor.toStringAsFixed(2)}) — load ${loadMs}ms, '
      'conditioning ${conditioningMs}ms, tokenize ${tokenizeMs}ms, '
      'prefill ${prefillMs}ms, decode ${decodeMs}ms '
      '($speechTokens tokens, ${msPerToken.toStringAsFixed(1)}ms each), '
      'vocode ${vocodeMs}ms';
}
