import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'model_storage.dart';
import 'stt_engine.dart';
import 'wav.dart';

/// Raised when the Parakeet bundle is missing or cannot be run.
class ParakeetUnavailableException extends SttNotReadyException {
  const ParakeetUnavailableException(super.reason);
}

/// NVIDIA Parakeet TDT 0.6B v3, run directly on ONNX Runtime.
///
/// The bundle is the three graphs the model was exported as plus its vocabulary:
///
/// * `nemo128.onnx` turns a waveform into the 128-bin log-mel features the
///   encoder expects, so none of that signal processing has to be reimplemented
///   in Dart;
/// * `encoder-model.int8.onnx` is the Conformer encoder, emitting one 1024-wide
///   frame per 80 ms of audio;
/// * `decoder_joint-model.int8.onnx` is the prediction network and joint
///   network fused into one graph, stepped once per decoding iteration.
///
/// Unlike Whisper this is a transducer, so there is no separate language
/// decoder to run over the whole utterance — [_decode] walks the encoder frames
/// and emits tokens as it goes.
class ParakeetSttService implements SttEngine {
  static final ParakeetSttService _instance = ParakeetSttService._();
  factory ParakeetSttService() => _instance;
  ParakeetSttService._();

  /// Directory the catalog downloads the bundle into.
  static const String bundleName = 'parakeet-tdt-0.6b-v3';

  static const String preprocessorGraph = 'nemo128.onnx';
  static const String encoderGraph = 'encoder-model.int8.onnx';
  static const String jointGraph = 'decoder_joint-model.int8.onnx';
  static const String vocabFile = 'vocab.txt';

  /// The sample rate the exported preprocessor assumes; anything else is
  /// resampled on the way in.
  static const int sampleRate = 16000;

  /// Width of one encoder frame.
  static const int encoderDim = 1024;

  /// Shape of the prediction network's LSTM state: two layers, 640 wide.
  static const int predictionLayers = 2;
  static const int predictionDim = 640;

  /// Cap on tokens emitted at a single encoder frame, matching NeMo's greedy
  /// decoder. Without it a degenerate model state can emit forever without ever
  /// advancing time.
  static const int maxTokensPerStep = 10;

  /// Longest span fed to the encoder in one pass, in seconds.
  ///
  /// The Conformer attends over the whole input, so cost grows quadratically
  /// with the length of the recording and a long dictation would otherwise ask
  /// for an allocation a phone cannot serve. Voice turns are far shorter than
  /// this; anything longer is split on a silence-agnostic boundary and the
  /// transcripts are joined.
  static const int maxSegmentSeconds = 20;

  final ModelStorage _storage = ModelStorage();

  OrtSession? _preprocessor;
  OrtSession? _encoder;
  OrtSession? _joint;
  List<String> _vocab = const [];
  int _blankIndex = 0;

  Future<void>? _initialization;
  bool _isTranscribing = false;

  @override
  SttEngineKind get kind => SttEngineKind.parakeet;

  @override
  bool get isReady => _encoder != null && _joint != null;

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

  Future<void> _initialize() async {
    try {
      final dir = await _storage.bundleDirectory(bundleName);
      for (final name in [
        preprocessorGraph,
        encoderGraph,
        jointGraph,
        vocabFile,
      ]) {
        if (!await File('${dir.path}/$name').exists()) {
          throw ParakeetUnavailableException(
            'Parakeet is not fully downloaded ("$name" is missing). Open '
            'Settings & models to finish the download.',
          );
        }
      }

      _vocab = await _readVocabulary('${dir.path}/$vocabFile');
      final blank = _vocab.indexOf('<blk>');
      if (blank < 0) {
        throw const ParakeetUnavailableException(
          'The Parakeet vocabulary has no blank token.',
        );
      }
      _blankIndex = blank;

      final ort = OnnxRuntime();
      // CPU throughout, for the same reason the Chatterbox graphs are pinned
      // there: these are int8 weight-quantised exports, and the accelerating
      // providers have no kernels for those ops, so they partition the graph
      // and pay to copy tensors across the boundary rather than speeding
      // anything up.
      final options = OrtSessionOptions(
        providers: const [OrtProvider.CPU],
        intraOpNumThreads: Platform.numberOfProcessors,
      );
      _preprocessor =
          await _createSession(ort, '${dir.path}/$preprocessorGraph', options);
      _encoder = await _createSession(ort, '${dir.path}/$encoderGraph', options);
      _joint = await _createSession(ort, '${dir.path}/$jointGraph', options);

      debugPrint('ParakeetSttService: ready (${_vocab.length} tokens, '
          'blank $_blankIndex)');
    } catch (e) {
      await _releaseSessions();
      _initialization = null;
      debugPrint('ParakeetSttService: initialisation failed: $e');
      rethrow;
    }
  }

  Future<OrtSession> _createSession(
      OnnxRuntime ort, String path, OrtSessionOptions options) async {
    try {
      return await ort.createSession(path, options: options);
    } catch (e) {
      debugPrint('ParakeetSttService: ${path.split('/').last} would not load '
          'with the requested providers ($e); using the defaults');
      return ort.createSession(path);
    }
  }

  /// Reads the `token id` vocabulary file.
  ///
  /// Tokens are SentencePiece pieces, so the word-boundary marker `▁` is
  /// translated to a plain space here and the transcript is just the pieces
  /// concatenated. Splitting on the *last* space matters: the piece for a
  /// literal space is itself written with one.
  static Future<List<String>> _readVocabulary(String path) async {
    final lines = await File(path).readAsLines();
    final entries = <int, String>{};
    for (final line in lines) {
      if (line.isEmpty) continue;
      final split = line.lastIndexOf(' ');
      if (split <= 0) continue;
      final id = int.tryParse(line.substring(split + 1));
      if (id == null) continue;
      entries[id] = line.substring(0, split).replaceAll('▁', ' ');
    }
    if (entries.isEmpty) return const [];
    final size = entries.keys.reduce((a, b) => a > b ? a : b) + 1;
    return List<String>.generate(size, (i) => entries[i] ?? '');
  }

  @override
  Future<String> transcribeFromFile(String audioPath, {String? language}) async {
    if (_isTranscribing) {
      throw const ParakeetUnavailableException(
        'A transcription is already in progress.',
      );
    }
    _isTranscribing = true;
    try {
      await initialize();
      final file = File(audioPath);
      if (!await file.exists() || await file.length() < 1000) {
        throw const ParakeetUnavailableException(
          'The recording was too short to transcribe.',
        );
      }

      final audio = await readWavMono(audioPath, targetSampleRate: sampleRate);
      final segment = maxSegmentSeconds * sampleRate;
      final parts = <String>[];
      for (var offset = 0; offset < audio.length; offset += segment) {
        final end =
            offset + segment < audio.length ? offset + segment : audio.length;
        final text = await _transcribeSegment(
          Float32List.sublistView(audio, offset, end),
        );
        if (text.isNotEmpty) parts.add(text);
      }
      // Parakeet v3 detects the spoken language itself and has no prompt to
      // steer, so the configured STT language has nothing to act on here.
      return parts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    } finally {
      _isTranscribing = false;
    }
  }

  Future<String> _transcribeSegment(Float32List audio) async {
    final preprocessor = _preprocessor;
    final encoder = _encoder;
    if (preprocessor == null || encoder == null) {
      throw const ParakeetUnavailableException(
        'The speech-to-text model is not ready.',
      );
    }

    // Waveform to log-mel features.
    final waveform = await OrtValue.fromList(audio, [1, audio.length]);
    final lengths =
        await OrtValue.fromList(Int64List.fromList([audio.length]), [1]);
    final features = await preprocessor.run({
      'waveforms': waveform,
      'waveforms_lens': lengths,
    });
    await Future.wait([waveform.dispose(), lengths.dispose()]);

    final featureValue = features['features'];
    final featureLens = features['features_lens'];
    if (featureValue == null || featureLens == null) {
      throw const ParakeetUnavailableException(
        'The audio preprocessor returned no features.',
      );
    }

    // Encoder. Its outputs come back as [1, 1024, frames] — one column per
    // frame rather than one row, which is why the decoder below strides.
    final encoded = await encoder.run({
      'audio_signal': featureValue,
      'length': featureLens,
    });
    await Future.wait([featureValue.dispose(), featureLens.dispose()]);

    final encoderOut = encoded['outputs'];
    final encoderLens = encoded['encoded_lengths'];
    if (encoderOut == null || encoderLens == null) {
      throw const ParakeetUnavailableException(
        'The speech encoder returned no frames.',
      );
    }

    final frameCount = encoderOut.shape.last;
    final flat = _asFloat32(await encoderOut.asFlattenedList());
    final reportedFrames = (await encoderLens.asFlattenedList()).first;
    final validFrames = reportedFrames is int ? reportedFrames : frameCount;
    await Future.wait([encoderOut.dispose(), encoderLens.dispose()]);

    return _decode(
      frames: flat,
      frameCount: frameCount,
      validFrames: validFrames < frameCount ? validFrames : frameCount,
    );
  }

  /// Greedy token-and-duration decoding over the encoder frames.
  ///
  /// A TDT transducer predicts, alongside the next token, how many encoder
  /// frames to skip before predicting again — that trailing slice of the joint
  /// output is the duration distribution. Skipping is what makes this much
  /// cheaper than a plain RNN-T, which has to visit every frame.
  Future<String> _decode({
    required Float32List frames,
    required int frameCount,
    required int validFrames,
  }) async {
    final joint = _joint;
    if (joint == null) {
      throw const ParakeetUnavailableException(
        'The joint network is not ready.',
      );
    }

    final zeros = Float32List(predictionLayers * predictionDim);
    var state1 = await OrtValue.fromList(zeros, [predictionLayers, 1, predictionDim]);
    var state2 = await OrtValue.fromList(zeros, [predictionLayers, 1, predictionDim]);
    final targetLength = await OrtValue.fromList(Int32List.fromList([1]), [1]);

    final tokens = <int>[];
    var previous = _blankIndex;
    var frame = 0;
    var emitted = 0;

    try {
      while (frame < validFrames) {
        final column = Float32List(encoderDim);
        for (var d = 0; d < encoderDim; d++) {
          column[d] = frames[d * frameCount + frame];
        }

        final encoderStep =
            await OrtValue.fromList(column, [1, encoderDim, 1]);
        final targets =
            await OrtValue.fromList(Int32List.fromList([previous]), [1, 1]);
        final outputs = await joint.run({
          'encoder_outputs': encoderStep,
          'targets': targets,
          'target_length': targetLength,
          'input_states_1': state1,
          'input_states_2': state2,
        });
        await Future.wait([encoderStep.dispose(), targets.dispose()]);

        final logits = outputs['outputs'];
        final nextState1 = outputs['output_states_1'];
        final nextState2 = outputs['output_states_2'];
        if (logits == null || nextState1 == null || nextState2 == null) {
          throw const ParakeetUnavailableException(
            'The joint network returned an incomplete step.',
          );
        }

        final scores = _asFloat32(await logits.asFlattenedList());
        await Future.wait([
          logits.dispose(),
          outputs['prednet_lengths']?.dispose() ?? Future<void>.value(),
        ]);

        final token = _argmax(scores, 0, _vocab.length);
        final duration = _argmax(scores, _vocab.length, scores.length);

        if (token != _blankIndex) {
          // Only a real emission advances the prediction network; a blank
          // leaves it exactly where it was.
          await Future.wait([state1.dispose(), state2.dispose()]);
          state1 = nextState1;
          state2 = nextState2;
          tokens.add(token);
          previous = token;
          emitted++;
        } else {
          await Future.wait([nextState1.dispose(), nextState2.dispose()]);
        }

        if (duration > 0) {
          frame += duration;
          emitted = 0;
        } else if (token == _blankIndex || emitted == maxTokensPerStep) {
          frame++;
          emitted = 0;
        }
      }
    } finally {
      await Future.wait([
        state1.dispose(),
        state2.dispose(),
        targetLength.dispose(),
      ]);
    }

    final buffer = StringBuffer();
    for (final token in tokens) {
      if (token >= 0 && token < _vocab.length) buffer.write(_vocab[token]);
    }
    return buffer.toString().trim();
  }

  /// Index of the largest value in `values[start, end)`, relative to [start].
  static int _argmax(Float32List values, int start, int end) {
    var best = start;
    for (var i = start + 1; i < end; i++) {
      if (values[i] > values[best]) best = i;
    }
    return best - start;
  }

  static Float32List _asFloat32(List<dynamic> flat) => flat is Float32List
      ? flat
      : Float32List.fromList(flat.cast<double>());

  @override
  Future<void> unload() async {
    await _releaseSessions();
    _initialization = null;
  }

  Future<void> _releaseSessions() async {
    for (final session in [_preprocessor, _encoder, _joint]) {
      try {
        await session?.close();
      } catch (e) {
        debugPrint('ParakeetSttService: error closing session: $e');
      }
    }
    _preprocessor = null;
    _encoder = null;
    _joint = null;
  }
}
