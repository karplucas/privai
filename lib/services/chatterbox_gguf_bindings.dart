import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// `dart:ffi` bindings for `native/chatterbox/src/chatterbox_ffi.h`.
///
/// Hand-written rather than generated: the surface is three functions, and the
/// header is the contract both sides are checked against.
final class ChatterboxParams extends Struct {
  external Pointer<Utf8> codecPath;
  external Pointer<Utf8> backbonePath;
  external Pointer<Utf8> text;
  external Pointer<Utf8> refAudioPath;

  @Int32()
  external int nThreads;
  @Int32()
  external int useGpu;
  @Int32()
  external int maxFrames;
  @Uint32()
  external int seed;

  @Float()
  external double exaggeration;
  @Float()
  external double cfgWeight;
  @Float()
  external double temperature;
}

final class ChatterboxResult extends Struct {
  external Pointer<Float> pcm;

  @Int32()
  external int nSamples;
  @Int32()
  external int sampleRate;
  @Int32()
  external int nFrames;

  external Pointer<Utf8> error;
}

typedef _SynthesizeNative = Int32 Function(
    Pointer<ChatterboxParams>, Pointer<ChatterboxResult>);
typedef _SynthesizeDart = int Function(
    Pointer<ChatterboxParams>, Pointer<ChatterboxResult>);

typedef _FreeNative = Void Function(Pointer<ChatterboxResult>);
typedef _FreeDart = void Function(Pointer<ChatterboxResult>);

typedef _VersionNative = Pointer<Utf8> Function();

/// Raised when the native library is missing or a synthesis call fails.
class ChatterboxNativeException implements Exception {
  const ChatterboxNativeException(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// One synthesised utterance.
class ChatterboxAudio {
  const ChatterboxAudio({
    required this.samples,
    required this.sampleRate,
    required this.frames,
  });

  final Float32List samples;
  final int sampleRate;

  /// Speech tokens generated, at 25 per second of audio. Useful for telling a
  /// model that ran to its ceiling apart from one that stopped on its own.
  final int frames;

  double get seconds => sampleRate == 0 ? 0 : samples.length / sampleRate;
}

/// The loaded native library.
class ChatterboxNative {
  ChatterboxNative._(DynamicLibrary lib)
      : _synthesize = lib.lookupFunction<_SynthesizeNative, _SynthesizeDart>(
          'chatterbox_synthesize',
        ),
        _free = lib.lookupFunction<_FreeNative, _FreeDart>(
          'chatterbox_result_free',
        ),
        _version = lib.lookupFunction<_VersionNative, _VersionNative>(
          'chatterbox_version',
        );

  final _SynthesizeDart _synthesize;
  final _FreeDart _free;
  final _VersionNative _version;

  static ChatterboxNative? _instance;

  /// Opens the library, or throws with something worth showing a user.
  ///
  /// Android loads it out of the APK's jniLibs by soname; iOS statically links
  /// it into the process, which is what `DynamicLibrary.process()` reads.
  static ChatterboxNative open() {
    final existing = _instance;
    if (existing != null) return existing;

    try {
      final lib = Platform.isIOS || Platform.isMacOS
          ? DynamicLibrary.process()
          : DynamicLibrary.open('libchatterbox_ffi.so');
      return _instance = ChatterboxNative._(lib);
    } catch (e) {
      throw ChatterboxNativeException(
        'The Chatterbox native library could not be loaded ($e). This build '
        'may not include it for your device architecture.',
      );
    }
  }

  String get version => _version().toDartString();

  /// Synthesises [text]. Blocks for seconds — call it inside `Isolate.run`.
  ChatterboxAudio synthesize({
    required String codecPath,
    required String backbonePath,
    required String text,
    String? refAudioPath,
    int threads = 0,
    bool useGpu = false,
    int maxFrames = 0,
    int seed = 0xC0DEC1AB,
    double? exaggeration,
    double? cfgWeight,
    double? temperature,
  }) {
    final params = calloc<ChatterboxParams>();
    final result = calloc<ChatterboxResult>();
    final codec = codecPath.toNativeUtf8();
    final backbone = backbonePath.toNativeUtf8();
    final body = text.toNativeUtf8();
    final ref = refAudioPath?.toNativeUtf8();

    try {
      params.ref
        ..codecPath = codec
        ..backbonePath = backbone
        ..text = body
        ..refAudioPath = ref ?? nullptr
        ..nThreads = threads
        ..useGpu = useGpu ? 1 : 0
        ..maxFrames = maxFrames
        ..seed = seed
        // Negative means "leave the model's trained default alone"; the
        // native side gates each knob on that rather than on zero, which is
        // a meaningful value for all three.
        ..exaggeration = exaggeration ?? -1.0
        ..cfgWeight = cfgWeight ?? -1.0
        ..temperature = temperature ?? -1.0;

      final rc = _synthesize(params, result);
      if (rc != 0) {
        final err = result.ref.error;
        throw ChatterboxNativeException(
          err == nullptr ? 'Synthesis failed.' : err.toDartString(),
        );
      }

      // Copy before freeing: the native buffer is released below.
      final n = result.ref.nSamples;
      final samples = Float32List(n);
      if (n > 0) {
        samples.setAll(0, result.ref.pcm.asTypedList(n));
      }
      return ChatterboxAudio(
        samples: samples,
        sampleRate: result.ref.sampleRate,
        frames: result.ref.nFrames,
      );
    } finally {
      _free(result);
      calloc.free(params);
      calloc.free(result);
      malloc.free(codec);
      malloc.free(backbone);
      malloc.free(body);
      if (ref != null) malloc.free(ref);
    }
  }
}
