import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'audio_clip_player.dart';
import 'model_storage.dart';
import 'omnivoice_tokenizer.dart';
import 'tts_engine.dart';
import 'wav.dart';

class OmniVoiceUnavailableException implements Exception {
  const OmniVoiceUnavailableException(this.reason);
  final String reason;

  @override
  String toString() => reason;
}

/// OmniVoice's hybrid automatic-voice ONNX pipeline.
///
/// The text and masked audio tokens are embedded, refined over 32 confidence-
/// based decoding passes, then converted from eight codebooks to 24 kHz audio
/// by the Higgs decoder. Voice cloning is intentionally omitted: its three
/// extra encoder graphs add substantial download and memory cost, while the app
/// currently has no reference-audio voice picker. The FP32 language backbone
/// preserves OmniVoice's bidirectional diffusion attention. The former causal
/// KV-cache export collapsed codec-token diversity and decoded as noise.
class OmniVoiceTtsService implements TtsEngine {
  static final OmniVoiceTtsService _instance = OmniVoiceTtsService._();
  factory OmniVoiceTtsService() => _instance;
  OmniVoiceTtsService._();

  static const bundleName = 'omnivoice-int4';

  /// The fused int8 export. Where the FP32 bundle splits the forward pass over
  /// three graphs, this one is a single graph that takes token ids straight to
  /// logits — a third of the download, and one session instead of three.
  static const int8BundleName = 'omnivoice-int8';
  static const List<String> bundleNames = [bundleName, int8BundleName];

  static const audioEmbeddingsGraph = 'audio_embeddings_encoder.onnx';
  static const audioHeadsGraph = 'audio_heads_decoder.onnx';
  static const llmGraph = 'llm_backbone_fp32.onnx';
  static const fusedGraph = 'omnivoice.qint8.onnx';
  static const decoderGraph = 'higgs_decoder.onnx';
  static const tokenizerFile = 'tokenizer.json';

  /// Files each bundle must have before it can be loaded.
  static const List<String> splitFiles = [
    audioEmbeddingsGraph,
    audioHeadsGraph,
    llmGraph,
    decoderGraph,
    tokenizerFile,
  ];
  static const List<String> fusedFiles = [
    fusedGraph,
    decoderGraph,
    tokenizerFile,
  ];

  static const _codebooks = 8;
  static const _audioMaskId = 1024;
  static const _audioVocab = 1025;
  static const _sampleRate = 24000;
  static const _frameRate = 25;
  static const _timeShift = 0.1;
  static const _layerPenalty = 5.0;
  static const _guidanceScale = 2.0;
  static const _positionTemperature = 5.0;

  final _settings = AppSettings();
  final _storage = ModelStorage();
  OrtSession? _embeddings;
  OrtSession? _heads;
  OrtSession? _llm;

  /// Set when the loaded bundle is the fused int8 export, in which case
  /// [_embeddings] and [_heads] stay null and [_llm] is the whole forward pass.
  bool _fused = false;
  OrtSession? _decoder;
  OmniVoiceTokenizer? _tokenizer;
  final AudioClipPlayer _player = AudioClipPlayer('OmniVoiceTtsService');

  /// Completed by [stop] so a clip that is cut short stops being awaited at
  /// once; `AudioPlayer.stop()` emits no completion event.
  Completer<void> _stopSignal = Completer<void>();
  int _playbackEpoch = 0;
  Future<void>? _initialization;

  @override
  TtsEngineKind get kind => TtsEngineKind.omnivoice;

  @override
  bool get isInitialized => _llm != null;

  @override
  Future<void> initialize({bool force = false}) {
    if (force) _initialization = null;
    return _initialization ??= _initialize();
  }

  /// Picks the installed bundle, preferring the one the user selected.
  ///
  /// The two exports are interchangeable from the decoding loop's point of
  /// view but not on disk, so which one is present decides how the forward
  /// pass runs.
  Future<(String, bool)> _resolveBundle() async {
    final selected = await _settings.selectedTtsModel;
    final candidates = [
      if (selected != null && bundleNames.contains(selected)) selected,
      ...bundleNames,
    ];
    for (final name in candidates) {
      final fused = name == int8BundleName;
      final required = fused ? fusedFiles : splitFiles;
      if (await _storage.bundleIsComplete(name, required)) return (name, fused);
    }
    throw const OmniVoiceUnavailableException(
      'OmniVoice is not fully downloaded. Open Settings & models to finish '
      'the download.',
    );
  }

  Future<void> _initialize() async {
    try {
      final (bundle, fused) = await _resolveBundle();
      _fused = fused;
      final dir = await _storage.bundleDirectory(bundle);
      _tokenizer =
          await OmniVoiceTokenizer.fromFile('${dir.path}/$tokenizerFile');
      final ort = OnnxRuntime();
      final cpuOptions = OrtSessionOptions(
        providers: const [OrtProvider.CPU],
        intraOpNumThreads: Platform.numberOfProcessors,
      );
      if (!fused) {
        _embeddings = await ort.createSession(
          '${dir.path}/$audioEmbeddingsGraph',
          options: cpuOptions,
        );
        _heads = await ort.createSession(
          '${dir.path}/$audioHeadsGraph',
          options: cpuOptions,
        );
      }
      _llm = await _createBackboneSession(
        ort,
        '${dir.path}/${fused ? fusedGraph : llmGraph}',
      );
      _decoder = await ort.createSession('${dir.path}/$decoderGraph',
          options: cpuOptions);
      await _player.warmUp();
      debugPrint('OmniVoiceTtsService: ready '
          '(${fused ? 'fused int8' : 'split fp32'} backbone)');
    } catch (e) {
      await _releaseSessions();
      _initialization = null;
      debugPrint('OmniVoiceTtsService: initialisation failed: $e');
      rethrow;
    }
  }

  /// Uses Core ML for the expensive diffusion backbone on Apple devices.
  ///
  /// ONNX Runtime lets Core ML partition the graph and automatically executes
  /// unsupported nodes on CPU. Core ML itself chooses GPU, Neural Engine, or
  /// CPU for each supported partition; this API cannot force one compute unit.
  Future<OrtSession> _createBackboneSession(
    OnnxRuntime ort,
    String path,
  ) async {
    if (Platform.isIOS || Platform.isMacOS) {
      try {
        final providers = await ort.getAvailableProviders();
        debugPrint('OmniVoiceTtsService: providers available: '
            '${providers.map((provider) => provider.name).join(', ')}');
        if (providers.contains(OrtProvider.CORE_ML)) {
          final accelerated = OrtSessionOptions(
            providers: const [OrtProvider.CORE_ML, OrtProvider.CPU],
            intraOpNumThreads: Platform.numberOfProcessors,
          );
          final session = await ort.createSession(path, options: accelerated);
          debugPrint(
              'OmniVoiceTtsService: backbone created with Core ML requested');
          return session;
        }
      } catch (e) {
        debugPrint('OmniVoiceTtsService: Core ML backbone unavailable ($e); '
            'falling back to CPU');
      }
    }

    final cpu = OrtSessionOptions(
      providers: const [OrtProvider.CPU],
      intraOpNumThreads: Platform.numberOfProcessors,
    );
    final session = await ort.createSession(path, options: cpu);
    debugPrint('OmniVoiceTtsService: backbone created with CPU requested');
    return session;
  }

  @override
  Future<void> speak(String text,
      {String? voice, String? lang, double? speed}) async {
    if (text.trim().isEmpty) return;
    await initialize();
    await stop();
    final playbackEpoch = _playbackEpoch;
    final effectiveSpeed = speed ?? await _settings.ttsSpeed;
    final effectiveLanguage = lang ?? await _settings.ttsLanguage;
    final samples =
        await _synthesise(text.trim(), effectiveSpeed, effectiveLanguage);
    if (playbackEpoch != _playbackEpoch) return;
    final directory = await getTemporaryDirectory();
    final file = File(
      '${directory.path}/omnivoice_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(encodeWav(
      samples,
      sampleRate: _sampleRate,
      leadingSilence: AudioClipPlayer.leadingSilence,
    ));
    try {
      final seconds = samples.length / _sampleRate;
      debugPrint(
          'OmniVoiceTtsService: playing ${seconds.toStringAsFixed(1)}s');
      await _player.play(
        file,
        expected: Duration(milliseconds: (seconds * 1000).round()),
        interrupted: _stopSignal.future,
      );
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('OmniVoiceTtsService: could not delete ${file.path}: $e');
      }
    }
  }

  Future<Float32List> _synthesise(
      String text, double speed, String language) async {
    // These boundaries are part of OmniVoice's trained input format. The
    // community ONNX example omitted them, but feeding bare text leaves the
    // model unable to distinguish style, text, and audio regions.
    final baseLanguage = language.split(RegExp('[-_]')).first;
    final languageId = baseLanguage == 'cmn' ? 'zh' : baseLanguage;
    final prompt = '<|lang_start|>$languageId<|lang_end|>'
        '<|instruct_start|>None<|instruct_end|>'
        '<|text_start|>$text<|text_end|>';
    final textIds = _tokenizer!.encode(prompt);
    final words = RegExp(r'\S+').allMatches(text).length;
    final units = max(words, (text.runes.length / (words <= 1 ? 2 : 6)).ceil());
    final seconds =
        ((1.5 + units / 2.3) / speed.clamp(0.5, 2.0)).ceil().clamp(3, 30);
    final frames = seconds * _frameRate;
    final steps = await _settings.omnivoiceRefinementSteps;
    final sequence = textIds.length + frames;
    final codes = List.generate(
      _codebooks,
      (_) => List<int>.filled(frames, _audioMaskId),
    );
    // A position is one codebook/frame cell, not an entire frame. Lower
    // codebooks carry the coarse acoustic structure and are deliberately
    // filled first by the layer penalty used in the official implementation.
    final remaining = <int>{
      for (var i = 0; i < _codebooks * frames; i++) i,
    };
    final random = Random();

    final started = Stopwatch()..start();
    for (var step = 0; step < steps && remaining.isNotEmpty; step++) {
      final conditional = await _runBackbone(codes, textIds);
      final unconditional = await _runBackbone(codes, const []);

      final candidates = <_Candidate>[];
      for (final cell in remaining) {
        final codebook = cell ~/ frames;
        final frame = cell % frames;
        final conditionalBase =
            (codebook * sequence + textIds.length + frame) * _audioVocab;
        final unconditionalBase = (codebook * frames + frame) * _audioVocab;

        var conditionalMax = double.negativeInfinity;
        var unconditionalMax = double.negativeInfinity;
        for (var token = 0; token < _audioVocab; token++) {
          conditionalMax = max(
              conditionalMax, conditional[conditionalBase + token].toDouble());
          unconditionalMax = max(unconditionalMax,
              unconditional[unconditionalBase + token].toDouble());
        }
        var conditionalSum = 0.0;
        var unconditionalSum = 0.0;
        for (var token = 0; token < _audioVocab; token++) {
          conditionalSum += exp(
              conditional[conditionalBase + token].toDouble() - conditionalMax);
          unconditionalSum += exp(
              unconditional[unconditionalBase + token].toDouble() -
                  unconditionalMax);
        }
        final conditionalLogZ = conditionalMax + log(conditionalSum);
        final unconditionalLogZ = unconditionalMax + log(unconditionalSum);

        var best = 0;
        var bestScore = double.negativeInfinity;
        final guidedScores = Float32List(_audioMaskId);
        for (var token = 0; token < _audioMaskId; token++) {
          final conditionalLogProbability =
              conditional[conditionalBase + token].toDouble() - conditionalLogZ;
          final unconditionalLogProbability =
              unconditional[unconditionalBase + token].toDouble() -
                  unconditionalLogZ;
          final score = conditionalLogProbability +
              _guidanceScale *
                  (conditionalLogProbability - unconditionalLogProbability);
          guidedScores[token] = score;
          if (score > bestScore) {
            best = token;
            bestScore = score;
          }
        }
        var guidedSum = 0.0;
        for (var token = 0; token < _audioMaskId; token++) {
          guidedSum += exp(guidedScores[token] - bestScore);
        }
        final logConfidence = -log(guidedSum) - codebook * _layerPenalty;
        // Token choice is greedy, but the official generator adds Gumbel noise
        // when choosing which positions to commit at each diffusion step.
        final uniform = random.nextDouble().clamp(1e-10, 1 - 1e-10);
        final gumbel = -log(-log(uniform));
        final positionScore = logConfidence / _positionTemperature + gumbel;
        candidates.add(_Candidate(cell, positionScore, best));
      }
      candidates.sort((a, b) => b.confidence.compareTo(a.confidence));
      final x0 = step / steps;
      final x1 = (step + 1) / steps;
      final t0 = _timeShift * x0 / (1 + (_timeShift - 1) * x0);
      final t1 = _timeShift * x1 / (1 + (_timeShift - 1) * x1);
      final count = step == steps - 1
          ? remaining.length
          : min(remaining.length,
              max(1, (_codebooks * frames * (t1 - t0)).ceil()));
      for (final candidate in candidates.take(count)) {
        final codebook = candidate.cell ~/ frames;
        final frame = candidate.cell % frames;
        codes[codebook][frame] = candidate.token;
        remaining.remove(candidate.cell);
      }
      debugPrint('OmniVoiceTtsService: refinement ${step + 1}/$steps, '
          '${_codebooks * frames - remaining.length}/'
          '${_codebooks * frames} codec tokens');
    }

    final codeData = Int64List(_codebooks * frames);
    for (var codebook = 0; codebook < _codebooks; codebook++) {
      codeData.setRange(
          codebook * frames, (codebook + 1) * frames, codes[codebook]);
    }
    final codeValue =
        await OrtValue.fromList(codeData, [_codebooks, 1, frames]);
    final decoded = await _decoder!.run({'codes': codeValue});
    await codeValue.dispose();
    final waveform = decoded['waveform_24k'];
    if (waveform == null) {
      await _disposeOutputs(decoded);
      throw const OmniVoiceUnavailableException(
        'The Higgs decoder returned no waveform_24k.',
      );
    }
    final samples = (await waveform.asFlattenedList()).cast<num>();
    await _disposeOutputs(decoded);
    debugPrint('OmniVoiceTtsService: generated ${seconds}s in '
        '${started.elapsedMilliseconds}ms');
    return Float32List.fromList(
        [for (final sample in samples) sample.toDouble()]);
  }

  /// Runs one conditioned or unconditional backbone pass and returns logits.
  Future<List<num>> _runBackbone(
      List<List<int>> codes, List<int> prefixIds) async {
    final frames = codes.first.length;
    final sequence = prefixIds.length + frames;
    final ids = Int64List(_codebooks * sequence);
    for (var codebook = 0; codebook < _codebooks; codebook++) {
      final offset = codebook * sequence;
      if (prefixIds.isNotEmpty) {
        ids.setRange(offset, offset + prefixIds.length, prefixIds);
      }
      ids.setRange(
          offset + prefixIds.length, offset + sequence, codes[codebook]);
    }
    final inputIds = await OrtValue.fromList(ids, [1, _codebooks, sequence]);
    final audioMask = await OrtValue.fromList(
      <bool>[
        ...List<bool>.filled(prefixIds.length, false),
        ...List<bool>.filled(frames, true),
      ],
      [1, sequence],
    );
    if (_fused) {
      return _runFused(inputIds, audioMask, sequence);
    }
    final embeddingOutputs = await _embeddings!.run({
      'input_ids': inputIds,
      'audio_mask': audioMask,
    });
    await inputIds.dispose();
    await audioMask.dispose();
    final embeddings = embeddingOutputs['inputs_embeds'];
    if (embeddings == null) {
      await _disposeOutputs(embeddingOutputs);
      throw const OmniVoiceUnavailableException(
        'The OmniVoice embedding graph returned no inputs_embeds.',
      );
    }
    final llmEmbeddings = embeddings.dataType == OrtDataType.float32
        ? embeddings
        : await embeddings.to(OrtDataType.float32);
    // OmniVoice is masked diffusion, not autoregressive generation: every
    // position must see future positions on every refinement pass.
    final attention = await OrtValue.fromList(
      List<bool>.filled(sequence * sequence, true),
      [1, 1, sequence, sequence],
    );
    final llmOutputs = await _llm!.run({
      'inputs_embeds': llmEmbeddings,
      'attention_mask': attention,
    });
    await attention.dispose();
    if (!identical(llmEmbeddings, embeddings)) {
      await llmEmbeddings.dispose();
    }
    await embeddings.dispose();
    final hidden = llmOutputs['hidden_states'];
    if (hidden == null) {
      await _disposeOutputs(llmOutputs);
      throw const OmniVoiceUnavailableException(
        'The OmniVoice language graph returned no hidden_states.',
      );
    }
    await _disposeOutputs(llmOutputs, except: hidden);
    final headHidden = hidden.dataType == OrtDataType.float16
        ? hidden
        : await hidden.to(OrtDataType.float16);
    final headOutputs = await _heads!.run({'hidden_states': headHidden});
    if (!identical(headHidden, hidden)) {
      await headHidden.dispose();
    }
    await hidden.dispose();
    final logitsValue = headOutputs['logits'];
    if (logitsValue == null) {
      await _disposeOutputs(headOutputs);
      throw const OmniVoiceUnavailableException(
        'The OmniVoice audio heads returned no logits.',
      );
    }
    final flat = (await logitsValue.asFlattenedList()).cast<num>();
    await _disposeOutputs(headOutputs);
    return flat;
  }

  /// Runs the fused int8 graph, which is the three split graphs in one.
  ///
  /// It differs from the split path in two of its inputs. The attention mask is
  /// the ordinary 2-D padding mask rather than the 4-D all-true one — this
  /// export applies bidirectional attention internally, which matters because
  /// masked diffusion needs every position to see every other, and a causal
  /// export decodes as noise. Position ids are explicit rather than inferred.
  Future<List<num>> _runFused(
    OrtValue inputIds,
    OrtValue audioMask,
    int sequence,
  ) async {
    final attention = await OrtValue.fromList(
      Int64List.fromList(List<int>.filled(sequence, 1)),
      [1, sequence],
    );
    final positions = await OrtValue.fromList(
      Int64List.fromList(List<int>.generate(sequence, (i) => i)),
      [1, sequence],
    );
    final outputs = await _llm!.run({
      'input_ids': inputIds,
      'audio_mask': audioMask,
      'attention_mask': attention,
      'position_ids': positions,
    });
    await inputIds.dispose();
    await audioMask.dispose();
    await attention.dispose();
    await positions.dispose();
    final logits = outputs['logits'];
    if (logits == null) {
      await _disposeOutputs(outputs);
      throw const OmniVoiceUnavailableException(
        'The fused OmniVoice graph returned no logits.',
      );
    }
    final flat = (await logits.asFlattenedList()).cast<num>();
    await _disposeOutputs(outputs);
    return flat;
  }

  Future<void> _disposeOutputs(Map<String, OrtValue> outputs,
      {OrtValue? except}) async {
    for (final value in outputs.values) {
      if (!identical(value, except)) await value.dispose();
    }
  }

  @override
  Future<List<String>> availableVoices() async => const ['automatic'];

  @override
  Future<bool> get isStale async => false;

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
    await _releaseSessions();
    await initialize(force: true);
  }

  Future<void> _releaseSessions() async {
    for (final session in [_embeddings, _heads, _llm, _decoder]) {
      try {
        await session?.close();
      } catch (e) {
        debugPrint('OmniVoiceTtsService: error closing session: $e');
      }
    }
    _embeddings = null;
    _heads = null;
    _llm = null;
    _decoder = null;
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

class _Candidate {
  const _Candidate(this.cell, this.confidence, this.token);
  final int cell;
  final double confidence;
  final int token;
}
