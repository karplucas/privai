import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:privai/models/model_spec.dart';
import 'package:privai/services/chatterbox_gguf_tts_service.dart';
import 'package:privai/services/model_catalog.dart';
import 'package:privai/services/tts_engine.dart';
import 'package:privai/services/tts_router.dart';

/// Wiring checks for the GGUF engine. Synthesis itself needs the native
/// library and ~480 MB of weights, so it is not exercised here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the router resolves every engine kind to a distinct backend', () {
    final router = TtsRouter();
    final engines = {
      for (final kind in TtsEngineKind.values) kind: router.engineFor(kind),
    };

    for (final entry in engines.entries) {
      expect(entry.value.kind, entry.key,
          reason: '${entry.key.name} resolved to the wrong backend');
    }
    expect(
      engines.values.map((e) => e.runtimeType).toSet(),
      hasLength(TtsEngineKind.values.length),
      reason: 'two engine kinds share one implementation',
    );
  });

  test('both Chatterbox engines free the language model while speaking', () {
    // Either one holds well over a gigabyte alongside its own weights.
    expect(TtsEngineKind.chatterbox.requiresExclusiveMemory, isTrue);
    expect(TtsEngineKind.chatterboxGguf.requiresExclusiveMemory, isTrue);
    expect(TtsEngineKind.kokoro.requiresExclusiveMemory, isFalse);
  });

  test('the engine kind survives a round trip through storage', () {
    for (final kind in TtsEngineKind.values) {
      expect(TtsEngineKind.fromName(kind.name), kind);
    }
    // An unknown name must fall back rather than throw, so a downgrade cannot
    // leave the app unable to read its own settings.
    expect(TtsEngineKind.fromName('nonesuch'), TtsEngineKind.kokoro);
    expect(TtsEngineKind.fromName(null), TtsEngineKind.kokoro);
  });

  group('catalog entry', () {
    late ModelCatalogData catalog;

    setUpAll(() async {
      ModelCatalog().invalidate();
      catalog = await ModelCatalog().load();
    });

    test('lands in the directory the service reads', () {
      final entry = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == TtsEngineKind.chatterboxGguf.name);

      // A single-file entry still has to be treated as a bundle: the codec
      // GGUF is supplied separately and must sit beside the backbone.
      expect(entry.isBundle, isTrue);
      expect(entry.bundleDirectory, ChatterboxGgufTtsService.bundleName);
      expect(
        entry.files.map((f) => f.name),
        contains(ChatterboxGgufTtsService.backboneFile),
        reason: 'the service loads the backbone under this exact name',
      );
    });

    test('counts the hand-supplied codec file towards completeness', () {
      // Without this the models page reported the model ready as soon as the
      // backbone landed, while the engine refused to load for want of the
      // codec file — "definitely downloaded in settings", and still missing.
      final entry = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == TtsEngineKind.chatterboxGguf.name);

      expect(entry.suppliedFiles, contains(ChatterboxGgufTtsService.codecFile));
      expect(
        entry.requiredFilenames,
        containsAll([
          ChatterboxGgufTtsService.backboneFile,
          ChatterboxGgufTtsService.codecFile,
        ]),
      );
    });

    test('does not offer the codec file the published repo gets wrong', () {
      // The Hub copy carries no tokenizer and no voice encoder, so downloading
      // it would produce an engine that fails at first use. It has to be
      // converted — see native/chatterbox/README.md.
      final entry = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == TtsEngineKind.chatterboxGguf.name);

      expect(
        entry.files.map((f) => f.name),
        isNot(contains(ChatterboxGgufTtsService.codecFile)),
      );
    });
  });

  group('vocoder tone removal', () {
    /// codec.cpp's S3Gen adds a constant four-sample pattern to every render —
    /// a fixed tone at a quarter of the sample rate, 6 kHz at 24 kHz, audible
    /// as a whine. Measured from a real render's silent passages:
    const offsets = [0.00842, 0.00299, -0.00204, 0.00043];

    Float32List synth({required bool withSpeech}) {
      const n = 24000;
      final out = Float32List(n);
      final rand = Random(7);
      for (var i = 0; i < n; i++) {
        // Loud for the first half, silent for the second, as an utterance is.
        final speech = withSpeech && i < n ~/ 2
            ? 0.3 * sin(2 * pi * 220 * i / 24000) + 0.02 * rand.nextDouble()
            : 0.0;
        out[i] = speech + offsets[i % 4];
      }
      return out;
    }

    /// Magnitude at [hz] over the signal's quiet tail.
    double toneLevel(Float32List x, double hz) {
      final tail = x.sublist(x.length ~/ 2);
      var re = 0.0, im = 0.0;
      for (var i = 0; i < tail.length; i++) {
        final w = 2 * pi * hz * i / 24000;
        re += tail[i] * cos(w);
        im += tail[i] * sin(w);
      }
      return sqrt(re * re + im * im) / tail.length;
    }

    test('removes the constant per-phase offset', () {
      final dirty = synth(withSpeech: true);
      final clean = ChatterboxGgufTtsService.debugRemoveVocoderTone(dirty);

      final before = toneLevel(dirty, 6000);
      final after = toneLevel(clean, 6000);
      expect(after, lessThan(before / 10),
          reason: '6 kHz tone should drop by at least 10x '
              '(before $before, after $after)');
    });

    test('leaves speech level alone', () {
      final dirty = synth(withSpeech: true);
      final clean = ChatterboxGgufTtsService.debugRemoveVocoderTone(dirty);

      double rms(Float32List x) {
        var s = 0.0;
        for (final v in x) {
          s += v * v;
        }
        return sqrt(s / x.length);
      }

      expect(rms(clean), closeTo(rms(dirty), rms(dirty) * 0.02));
    });

    test('is a no-op on audio that has no such offset', () {
      const n = 24000;
      final rand = Random(3);
      final clean = Float32List(n);
      for (var i = 0; i < n; i++) {
        clean[i] = 0.2 * sin(2 * pi * 300 * i / 24000) + 0.01 * rand.nextDouble();
      }
      final out = ChatterboxGgufTtsService.debugRemoveVocoderTone(clean);
      for (var i = 0; i < n; i++) {
        expect(out[i], closeTo(clean[i], 0.02));
      }
    });

    test('too-short buffers pass through untouched', () {
      final tiny = Float32List.fromList([0.1, 0.2, 0.3, 0.4]);
      expect(ChatterboxGgufTtsService.debugRemoveVocoderTone(tiny), same(tiny));
    });
  });
}
