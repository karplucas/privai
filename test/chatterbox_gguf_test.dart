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
}
