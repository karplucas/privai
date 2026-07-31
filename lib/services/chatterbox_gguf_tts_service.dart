import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'chatterbox_gguf_bindings.dart';
import 'model_storage.dart';
import 'tts_engine.dart';
import 'wav.dart';

/// Chatterbox Multilingual through llama.cpp + codec.cpp rather than ONNX
/// Runtime.
///
/// Two GGUF files in one bundle directory:
///
/// * `chatterbox-mtl-t3-q4_k_m.gguf` — the T3 speech-token generator, a stock
///   `llama` arch model that llama.cpp runs unmodified
/// * `chatterbox-mtl-codec-q4_k_m.gguf` — S3Gen (flow-matching decoder plus
///   HiFi-GAN) bundled with the LM adaptor, the BPE tokenizer and the voice
///   encoder, driven by codec.cpp
///
/// Everything downstream of the text lives in native code: tokenization,
/// conditioning, the autoregressive loop and the vocoder. That is the whole
/// point — the ONNX engine drives that loop from Dart and pays a platform
/// channel round trip for every one of the 25 speech tokens per second of
/// audio.
///
/// The codec GGUF must be one converted with the tokenizer and voice encoder
/// baked in. The GGUFs published on the Hub at the time of writing carry
/// neither, and fail at load with "no tokenizer baked into GGUF" or at prompt
/// build with "no speaker_emb and no builtin conds". See
/// `native/chatterbox/README.md` for the conversion.
class ChatterboxGgufTtsService implements TtsEngine {
  static final ChatterboxGgufTtsService _instance =
      ChatterboxGgufTtsService._internal();
  factory ChatterboxGgufTtsService() => _instance;
  ChatterboxGgufTtsService._internal();

  /// Directory name used by the catalog entry.
  static const String bundleName = 'chatterbox-gguf';

  static const String backboneFile = 'chatterbox-mtl-t3-q4_k_m.gguf';
  static const String codecFile = 'chatterbox-mtl-codec-q4_k_m.gguf';

  /// Speech tokens per second, the same 25 Hz the ONNX engine measured.
  static const int tokenRateHz = 25;

  /// Ceiling on generated audio, so a degenerate sample cannot spin forever.
  static const int maxSeconds = 30;

  final AppSettings _settings = AppSettings();
  final ModelStorage _storage = ModelStorage();

  AudioPlayer? _player;
  bool _ready = false;
  Future<void>? _initialization;

  @override
  TtsEngineKind get kind => TtsEngineKind.chatterboxGguf;

  @override
  bool get isInitialized => _ready;

  @override
  Future<void> initialize({bool force = false}) {
    if (force) _initialization = null;
    return _initialization ??= _initialize();
  }

  /// Checks the model files are present and the native library loads.
  ///
  /// Deliberately does not load the models: llama.cpp holds them for the
  /// lifetime of one synthesis call and frees them after, so there is no
  /// session to warm up, and holding one would keep ~480 MB resident for a
  /// user who never asks for speech.
  Future<void> _initialize() async {
    try {
      await _requireModelFiles();

      final native = ChatterboxNative.open();
      _player ??= AudioPlayer();
      _ready = true;
      debugPrint('ChatterboxGgufTtsService: ready (${native.version})');
    } catch (e) {
      _ready = false;
      _initialization = null;
      debugPrint('ChatterboxGgufTtsService: initialisation failed: $e');
      rethrow;
    }
  }

  /// Throws unless both GGUFs are on disk, naming the one that is not.
  ///
  /// Re-checked before every utterance rather than only at initialisation:
  /// deleting the model from the settings page removes the files underneath a
  /// service that has already reported itself ready, and the failure then
  /// surfaces from native code as "flow_lm: model load failed" — which says
  /// nothing about what is actually wrong.
  Future<Directory> _requireModelFiles() async {
    final dir = await _storage.bundleDirectory(bundleName);
    for (final name in [backboneFile, codecFile]) {
      if (!await File('${dir.path}/$name').exists()) {
        _ready = false;
        _initialization = null;
        throw ChatterboxNativeException(
          name == codecFile
              // This one is never downloaded, so "finish the download" would
              // send the user somewhere that cannot help them.
              ? 'The Chatterbox codec model ("$name") is missing. It has to be '
                  'converted and copied into the chatterbox-gguf folder by '
                  'hand — deleting the model from this page removes it too.'
              : 'The Chatterbox GGUF model is not fully downloaded ("$name" is '
                  'missing). Open Settings & models to finish the download.',
        );
      }
    }
    return dir;
  }

  @override
  Future<void> reload() async {
    await stop();
    _ready = false;
    await initialize(force: true);
  }

  /// Nothing is held between utterances, so nothing can go stale.
  @override
  Future<bool> get isStale async => false;

  /// The model clones whatever reference audio it is given rather than
  /// offering a fixed set; without one it uses the conditioning baked into the
  /// GGUF.
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

    final audio = await synthesise(text);
    if (audio.samples.isEmpty) {
      debugPrint('ChatterboxGgufTtsService: no audio produced');
      return;
    }

    final file = await _writeWav(audio);
    await stop();
    await _player!.play(DeviceFileSource(file.path));
    debugPrint('ChatterboxGgufTtsService: playing '
        '${audio.seconds.toStringAsFixed(1)}s (${audio.frames} tokens)');

    // Awaited rather than left running: the caller unloads the language model
    // to make room for this engine and stops it in a `finally`, so returning
    // early would cut the audio off as it started.
    await _awaitPlayback(audio.seconds);
    await _delete(file);
  }

  /// Runs the native pipeline off the UI isolate.
  ///
  /// `Isolate.run` matters here: synthesis blocks for seconds inside native
  /// code, which would otherwise freeze every frame for its duration.
  Future<ChatterboxAudio> synthesise(String text,
      {String? referenceWavPath}) async {
    await initialize();

    // Deliberately re-checked here, not just at initialisation: two stat calls
    // are nothing against a synthesis that runs for tens of seconds.
    final dir = await _requireModelFiles();
    final threads = _threadCount();
    final useGpu = await _settings.chatterboxGgufUseGpu;
    final exaggeration = await _settings.chatterboxExaggeration;

    final request = _SynthesisRequest(
      codecPath: '${dir.path}/$codecFile',
      backbonePath: '${dir.path}/$backboneFile',
      text: text,
      refAudioPath: referenceWavPath,
      threads: threads,
      useGpu: useGpu,
      maxFrames: maxSeconds * tokenRateHz,
      exaggeration: exaggeration,
    );

    final started = DateTime.now();
    final audio = await Isolate.run(() => _synthesizeBlocking(request));
    final elapsed = DateTime.now().difference(started).inMilliseconds;
    debugPrint('ChatterboxGgufTtsService: ${audio.frames} tokens in ${elapsed}ms '
        '(${audio.frames == 0 ? 0 : elapsed ~/ audio.frames}ms/token, '
        '${audio.seconds.toStringAsFixed(1)}s of audio, '
        '$threads threads, gpu=$useGpu)');
    return audio;
  }

  /// Samples per cycle of the vocoder's constant-offset artifact.
  ///
  /// 24 kHz / 4 = 6 kHz, which is where the tone sits.
  static const int _artifactPeriod = 4;

  /// Removes the vocoder's fixed per-phase DC offset — an audible 6 kHz whine.
  ///
  /// codec.cpp's S3Gen emits a constant repeating four-sample pattern, clearly
  /// visible in silence, where the waveform settles to exactly
  /// `[8.42, 2.99, -2.04, 0.43] × 10⁻³` cycle after cycle. A constant offset
  /// per phase position is a fixed tone at a quarter of the sample rate, and
  /// it is present in every render this pipeline produces, on every platform,
  /// GPU or CPU — so it is a bug in the vocoder rather than anything about how
  /// it is driven here.
  ///
  /// The offsets are measured over the quietest frames rather than the whole
  /// signal: speech dominates a plain average and subtracting that makes the
  /// tone *worse* (measured: 6 kHz energy in silence went up 2.8x). Estimated
  /// from the quiet frames instead it drops by ~38x, and broadband level is
  /// unchanged to three decimal places.
  static Float32List _removeVocoderTone(Float32List samples) {
    const frame = 512; // a multiple of _artifactPeriod, so phases stay aligned
    if (samples.length < frame * 4) return samples;

    final frames = samples.length ~/ frame;
    final energy = List<({double rms, int index})>.generate(frames, (i) {
      var sum = 0.0;
      for (var j = i * frame; j < (i + 1) * frame; j++) {
        sum += samples[j] * samples[j];
      }
      return (rms: sum / frame, index: i);
    })
      ..sort((a, b) => a.rms.compareTo(b.rms));

    final quiet = energy.take((frames * 15 ~/ 100).clamp(1, frames)).toList();
    final sums = List<double>.filled(_artifactPeriod, 0);
    final counts = List<int>.filled(_artifactPeriod, 0);
    for (final f in quiet) {
      for (var j = f.index * frame; j < (f.index + 1) * frame; j++) {
        sums[j % _artifactPeriod] += samples[j];
        counts[j % _artifactPeriod]++;
      }
    }

    final out = Float32List.fromList(samples);
    for (var p = 0; p < _artifactPeriod; p++) {
      if (counts[p] == 0) continue;
      final offset = sums[p] / counts[p];
      for (var j = p; j < out.length; j += _artifactPeriod) {
        out[j] -= offset;
      }
    }
    return out;
  }

  @visibleForTesting
  static Float32List debugRemoveVocoderTone(Float32List samples) =>
      _removeVocoderTone(samples);

  /// Threads to give the decode loop.
  ///
  /// Not a detail: leaving this at the runtime's default measured four times
  /// slower than using the cores. One core is left for the UI and the audio
  /// pipeline.
  int _threadCount() {
    final cores = Platform.numberOfProcessors;
    return cores > 2 ? cores - 1 : 1;
  }

  Future<void> _awaitPlayback(double seconds) async {
    try {
      await _player!.onPlayerComplete.first.timeout(
        Duration(milliseconds: (seconds * 1000).round() + 5000),
      );
    } on TimeoutException {
      debugPrint('ChatterboxGgufTtsService: playback did not report completion');
    } catch (e) {
      debugPrint('ChatterboxGgufTtsService: playback error: $e');
    }
  }

  Future<File> _writeWav(ChatterboxAudio audio) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/chatterbox_gguf_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(
      encodeWav(_removeVocoderTone(audio.samples),
          sampleRate: audio.sampleRate),
    );
    return file;
  }

  Future<void> _delete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('ChatterboxGgufTtsService: could not delete ${file.path}: $e');
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('ChatterboxGgufTtsService: error stopping playback: $e');
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    await _player?.dispose();
    _player = null;
    _ready = false;
    _initialization = null;
  }
}

/// Parameters for one synthesis, sized to cross an isolate boundary.
class _SynthesisRequest {
  const _SynthesisRequest({
    required this.codecPath,
    required this.backbonePath,
    required this.text,
    required this.refAudioPath,
    required this.threads,
    required this.useGpu,
    required this.maxFrames,
    required this.exaggeration,
  });

  final String codecPath;
  final String backbonePath;
  final String text;
  final String? refAudioPath;
  final int threads;
  final bool useGpu;
  final int maxFrames;
  final double exaggeration;
}

/// Runs on the spawned isolate. Top-level so it can be sent as a closure.
ChatterboxAudio _synthesizeBlocking(_SynthesisRequest r) {
  return ChatterboxNative.open().synthesize(
    codecPath: r.codecPath,
    backbonePath: r.backbonePath,
    text: r.text,
    refAudioPath: r.refAudioPath,
    threads: r.threads,
    useGpu: r.useGpu,
    maxFrames: r.maxFrames,
    exaggeration: r.exaggeration,
  );
}
