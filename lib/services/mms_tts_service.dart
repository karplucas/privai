import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_clip_player.dart';
import 'model_storage.dart';
import 'tts_engine.dart';
import 'wav.dart';

/// Raised when the MMS bundle is missing or cannot be run.
class MmsUnavailableException implements Exception {
  const MmsUnavailableException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Meta's Massively Multilingual Speech TTS, a VITS model run on ONNX Runtime.
///
/// The simplest engine here by a wide margin: one graph, one run, character ids
/// in and a waveform out. There is no autoregressive loop, no separate vocoder
/// and no speaker conditioning, so it needs none of the memory choreography
/// Chatterbox does — [TtsEngineKind.requiresExclusiveMemory] stays false and the
/// language model keeps its place.
///
/// The trade is fidelity and choice: 16 kHz output against Kokoro's 24 kHz, and
/// exactly one voice per language, since MMS ships a separate model per
/// language rather than a voice bank.
///
/// The graph is the **fp32** export deliberately. Its int8 sibling is a third
/// of the size but measured 6.8x slower (0.81 against 0.12 real-time factor on
/// a desktop CPU): dynamic quantisation leaves this convolution-heavy model
/// paying quantise/dequantise on every layer without a fast kernel to make up
/// for it. The fp16 export is unusable at any speed — it fails to load, its
/// `RandomNormalLike` node declaring a float16 output where ONNX Runtime
/// requires float32.
class MmsTtsService implements TtsEngine {
  static final MmsTtsService _instance = MmsTtsService._internal();
  factory MmsTtsService() => _instance;
  MmsTtsService._internal();

  /// Directory name used by the catalog entry.
  static const String bundleName = 'mms-tts-eng';

  static const String modelGraph = 'model.onnx';
  static const String vocabFile = 'vocab.json';

  /// Every MMS voice is trained at 16 kHz.
  static const int sampleRate = 16000;

  /// Inserted between every pair of characters, and at both ends.
  ///
  /// The tokenizer config sets `add_blank`, and its pad token is the character
  /// whose id is zero. Without the interleaving the model reads a sequence half
  /// the length it was trained on and returns unintelligible audio.
  static const int _blankId = 0;

  final ModelStorage _storage = ModelStorage();

  OrtSession? _session;
  Map<String, int> _vocab = const {};
  final AudioClipPlayer _player = AudioClipPlayer('MmsTtsService');
  Future<void>? _initialization;
  int _playbackEpoch = 0;

  /// Completed by [stop] so a clip that is cut short stops being awaited at
  /// once. `AudioPlayer.stop()` emits no completion event, so without this the
  /// queue would sit waiting on audio that will never finish.
  Completer<void> _stopSignal = Completer<void>();

  @override
  TtsEngineKind get kind => TtsEngineKind.mms;

  @override
  bool get isInitialized => _session != null;

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
      for (final name in [modelGraph, vocabFile]) {
        if (!await File('${dir.path}/$name').exists()) {
          throw MmsUnavailableException(
            'MMS-TTS is not fully downloaded ("$name" is missing). Open '
            'Settings & models to finish the download.',
          );
        }
      }

      _vocab = await _readVocabulary('${dir.path}/$vocabFile');
      if (_vocab.isEmpty) {
        throw const MmsUnavailableException(
          'The MMS-TTS vocabulary is empty.',
        );
      }

      final ort = OnnxRuntime();
      _session = await ort.createSession(
        '${dir.path}/$modelGraph',
        options: OrtSessionOptions(
          providers: const [OrtProvider.CPU],
          intraOpNumThreads: Platform.numberOfProcessors,
        ),
      );
      await _player.warmUp();
      debugPrint('MmsTtsService: ready (${_vocab.length} characters)');
    } catch (e) {
      await _release();
      _initialization = null;
      debugPrint('MmsTtsService: initialisation failed: $e');
      rethrow;
    }
  }

  static Future<Map<String, int>> _readVocabulary(String path) async {
    final raw = json.decode(await File(path).readAsString());
    if (raw is! Map) return const {};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is int)
          entry.key as String: entry.value as int,
    };
  }

  /// Turns [text] into the model's character ids.
  ///
  /// MMS normalises by lower-casing and dropping anything outside its alphabet
  /// — punctuation included, which the model has no tokens for and does not
  /// need, since VITS takes its pauses from the text's spaces.
  @visibleForTesting
  static List<int> encode(String text, Map<String, int> vocab) {
    final ids = <int>[_blankId];
    for (final character in text.toLowerCase().split('')) {
      final id = vocab[character];
      if (id == null) continue;
      ids
        ..add(id)
        ..add(_blankId);
    }
    return ids.length > 1 ? ids : const [];
  }

  /// Runs the model and returns 16 kHz mono samples in -1..1.
  Future<Float32List> synthesise(String text) async {
    await initialize();
    final session = _session!;
    final ids = encode(text, _vocab);
    if (ids.isEmpty) return Float32List(0);

    final inputIds = await OrtValue.fromList(
      Int64List.fromList(ids),
      [1, ids.length],
    );
    final mask = await OrtValue.fromList(
      Int64List(ids.length)..fillRange(0, ids.length, 1),
      [1, ids.length],
    );

    final outputs = await session.run({
      'input_ids': inputIds,
      'attention_mask': mask,
    });
    await Future.wait([inputIds.dispose(), mask.dispose()]);

    final waveform = outputs['waveform'];
    // The graph also returns the intermediate spectrogram, which nothing here
    // reads; leaving it undisposed would leak a tensor per utterance.
    final spectrogram = outputs['spectrogram'];
    if (waveform == null) {
      await spectrogram?.dispose();
      throw const MmsUnavailableException('MMS-TTS returned no audio.');
    }

    final flat = await waveform.asFlattenedList();
    await Future.wait([
      waveform.dispose(),
      if (spectrogram != null) spectrogram.dispose(),
    ]);
    return flat is Float32List
        ? flat
        : Float32List.fromList(flat.cast<double>());
  }

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
    await _play(await _render(text), epoch);
  }


  Future<_Clip?> _render(String text) async {
    final samples = await synthesise(text);
    if (samples.isEmpty) return null;
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/mms_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(encodeWav(
      samples,
      sampleRate: sampleRate,
      leadingSilence: AudioClipPlayer.leadingSilence,
    ));
    return _Clip(file, samples.length / sampleRate);
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
      debugPrint('MmsTtsService: could not delete ${file.path}: $e');
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

  @override
  Future<bool> get isStale async => false;

  /// MMS ships one model per language, each with a single speaker, so there is
  /// no voice to choose.
  @override
  Future<List<String>> availableVoices() async => const [];

  @override
  Future<void> dispose() async {
    await stop();
    await _release();
    await _player.dispose();
    _initialization = null;
  }

  Future<void> _release() async {
    try {
      await _session?.close();
    } catch (e) {
      debugPrint('MmsTtsService: error closing session: $e');
    }
    _session = null;
    _vocab = const {};
  }
}

/// A rendered clip and how long it plays for.
class _Clip {
  const _Clip(this.file, this.seconds);

  final File file;
  final double seconds;

  Duration get duration =>
      Duration(milliseconds: (seconds * 1000).round());
}
