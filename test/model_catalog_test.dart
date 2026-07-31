import 'package:flutter_test/flutter_test.dart';
import 'package:privai/models/model_spec.dart';
import 'package:privai/services/tts_engine.dart';
import 'package:privai/services/chatterbox_tts_service.dart';
import 'package:privai/services/model_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ModelSpec', () {
    ModelSpec parse(Map<String, dynamic> json) =>
        ModelSpec.fromJson(ModelKind.llm, json);

    test('derives the download URL from the repo and file', () {
      final spec = parse({
        'repo': 'google/gemma-3n-E2B-it-litert-preview',
        'file': 'gemma-3n-E2B-it-int4.task',
        'filename': 'gemma-3n-E2B-it-int4.task',
      });

      expect(
        spec.downloadUrl.toString(),
        'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/'
        'resolve/main/gemma-3n-E2B-it-int4.task',
      );
    });

    test('points the license page at the same repository as the download', () {
      final spec = parse({
        'repo': 'google/gemma-3n-E2B-it-litert-preview',
        'filename': 'model.task',
      });

      expect(
        spec.licensePageUrl.toString(),
        'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview',
      );
      expect(
        spec.downloadUrl.toString().startsWith(spec.licensePageUrl.toString()),
        isTrue,
        reason: 'the terms the user accepts must govern the file downloaded',
      );
    });

    test('honours a pinned revision', () {
      final spec = parse({
        'repo': 'owner/repo',
        'filename': 'model.task',
        'revision': 'abc123',
      });

      expect(spec.downloadUrl.toString(), contains('/resolve/abc123/'));
    });

    test('defaults gated to false and requires repo and filename', () {
      expect(parse({'repo': 'a/b', 'filename': 'm.task'}).gated, isFalse);
      expect(() => parse({'filename': 'm.task'}), throwsFormatException);
      expect(() => parse({'repo': 'a/b'}), throwsFormatException);
    });
  });

  group('ModelCatalogData', () {
    test('separates models from the language tables', () {
      final data = ModelCatalogData.fromJson({
        'llm': [
          {'repo': 'a/b', 'filename': 'llm.task', 'gated': true},
        ],
        'stt': [
          {'repo': 'c/d', 'filename': 'stt.bin'},
        ],
        'tts_languages': [
          {'code': 'en-us', 'name': 'English (US)'},
        ],
        'stt_languages': [
          {'code': 'auto', 'name': 'Auto-detect'},
        ],
      });

      expect(data.models, hasLength(2));
      expect(data.byKind(ModelKind.llm).single.filename, 'llm.task');
      expect(data.byKind(ModelKind.tts), isEmpty);
      expect(data.ttsLanguages.single.code, 'en-us');
      expect(data.sttLanguages.single.name, 'Auto-detect');
    });

    test('skips malformed entries instead of failing the whole catalog', () {
      final data = ModelCatalogData.fromJson({
        'llm': [
          {'not': 'a model'},
          {'repo': 'a/b', 'filename': 'good.task'},
        ],
      });

      expect(data.models.single.filename, 'good.task');
    });

    test('looks a model up by its on-device filename', () {
      final data = ModelCatalogData.fromJson({
        'llm': [
          {'repo': 'a/b', 'filename': 'llm.task'},
        ],
      });

      expect(data.byFilename('llm.task'), isNotNull);
      expect(data.byFilename('missing.task'), isNull);
    });
  });

  group('shipped catalog', () {
    late ModelCatalogData catalog;

    setUpAll(() async {
      ModelCatalog().invalidate();
      catalog = await ModelCatalog().load();
    });

    test('loads', () {
      expect(catalog.models, isNotEmpty);
      expect(catalog.byKind(ModelKind.llm), isNotEmpty);
    });

    // Gemma 3 and 3n ship under the Gemma Terms of Use, which Hugging Face
    // enforces per account, so those entries have to carry the gate. Gemma 4 is
    // Apache-2.0 and its litert-community repositories are not gated, so
    // requiring the gate of every Gemma would force users through a licence
    // acceptance that does not exist. What every entry does owe the user is a
    // named licence, and every gated one an explanation of what it is agreeing
    // to.
    test('names a license for every Gemma model, and explains the gated ones',
        () {
      final gemmas = catalog.models.where(
        (m) => m.repo.toLowerCase().contains('gemma'),
      );

      expect(gemmas, isNotEmpty, reason: 'the catalog should offer Gemma');
      for (final model in gemmas) {
        expect(
          model.license,
          isNotNull,
          reason: '${model.repo} must name its license',
        );
        if (model.gated) {
          expect(
            model.licenseNote,
            isNotNull,
            reason: '${model.repo} gates downloads without saying why',
          );
        }
      }
    });

    test('the Gemma models still under the Terms of Use keep their gate', () {
      // Losing the gate on these would mean downloads that fail with a bare 403
      // instead of walking the user through accepting Google's terms.
      final gated = catalog.models.where(
        (m) => m.license == 'Gemma Terms of Use',
      );

      expect(gated, isNotEmpty);
      for (final model in gated) {
        expect(
          model.gated,
          isTrue,
          reason: '${model.repo} must go through the license gate',
        );
      }
    });

    test('every entry resolves to an https URL on a known host', () {
      for (final model in catalog.models) {
        expect(model.downloadUrl.scheme, 'https');
        expect(
          model.downloadUrl.host,
          anyOf('huggingface.co', 'github.com'),
          reason: '${model.filename} points somewhere unexpected',
        );
      }
    });

    test('gated models are always fetched from Hugging Face', () {
      // The license gate is implemented against the Hub's access rules, so a
      // gated entry hosted elsewhere would silently bypass it.
      for (final model in catalog.models.where((m) => m.gated)) {
        expect(model.downloadUrl.host, 'huggingface.co');
      }
    });

    test('the Kokoro model is the export kokoro_tts_flutter can read', () {
      // Regression: the onnx-community export of the same weights emits a 2-D
      // output, and the package casts each element straight to double, so
      // synthesis died with "type 'Float32List' is not a subtype of type
      // 'double'". Only this release asset produces a flat float array.
      final kokoro = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'kokoro');

      expect(kokoro.downloadUrl.toString(), contains('kokoro-v1.0.onnx'));
      expect(kokoro.downloadUrl.toString(), contains('model-files-v1.0'));
      expect(kokoro.downloadUrl.host, 'github.com');
    });

    test('every TTS entry names the engine that consumes it', () {
      // Several engines share the tts section, so an entry without an engine
      // tag could be handed to the wrong runtime. Checked against the enum
      // rather than a list here, so adding an engine cannot leave this stale.
      final names = TtsEngineKind.values.map((e) => e.name).toList();
      for (final model in catalog.byKind(ModelKind.tts)) {
        expect(names, contains(model.engine),
            reason: '${model.filename} has no usable engine tag');
      }
    });

    test('Chatterbox declares every file its pipeline needs', () {
      final chatterbox = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'chatterbox');

      expect(chatterbox.isBundle, isTrue);
      expect(chatterbox.bundleDirectory, isNotNull);

      final names = chatterbox.files.map((f) => f.name).toList();
      for (final required in const [
        'embed_tokens.onnx',
        'language_model_q4.onnx',
        'speech_encoder.onnx',
        'conditional_decoder.onnx',
        'tokenizer.json',
      ]) {
        expect(names, contains(required));
      }

      // Each graph must be accompanied by the sidecar it names internally,
      // under exactly that filename, or ONNX Runtime cannot find its weights.
      for (final stem in const [
        'embed_tokens',
        'language_model_q4',
        'speech_encoder',
        'conditional_decoder',
      ]) {
        expect(names, contains('$stem.onnx'));
        expect(
          names,
          contains('$stem.onnx_data'),
          reason: 'the sidecar must sit beside $stem.onnx',
        );
      }
    });

    test('the catalog ships the exact graphs ChatterboxTtsService loads', () {
      // Regression: the service and the catalog disagreed on which language
      // model export to use. It also has to be the float32-KV one, because
      // OrtValue.fromList cannot build the float16 cache tensors the q4f16
      // export requires on its first pass.
      final chatterbox = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'chatterbox');
      final names = chatterbox.files.map((f) => f.name).toSet();

      for (final graph in const [
        ChatterboxTtsService.embedGraph,
        ChatterboxTtsService.languageGraph,
        ChatterboxTtsService.speechEncoderGraph,
        ChatterboxTtsService.decoderGraph,
        ChatterboxTtsService.tokenizerFile,
        ChatterboxTtsService.defaultVoiceFile,
      ]) {
        expect(names, contains(graph),
            reason: 'the service loads $graph but the catalog omits it');
      }

      expect(ChatterboxTtsService.languageGraph, isNot(contains('f16')),
          reason: 'a float16 KV cache cannot be created from Dart');
      expect(chatterbox.bundleDirectory, ChatterboxTtsService.bundleName);
    });

    test('a bundle stands for a real file, not its directory name', () {
      // Regression: downloadUrl fell back to `filename`, which for a bundle is
      // the local directory rather than a repo path, so the access check that
      // runs before every download failed with "Entry not found".
      final chatterbox = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'chatterbox');

      final paths = chatterbox.files.map((f) => f.pathInRepo).toList();
      final probed = chatterbox.downloadUrl.path;

      expect(
        paths.any(probed.endsWith),
        isTrue,
        reason: 'downloadUrl must address a file that exists in the repo, '
            'got $probed',
      );
      expect(
        probed.endsWith('/${chatterbox.filename}'),
        isFalse,
        reason: 'the bundle directory name is not a path in the repository',
      );
    });

    test('bundle files keep their basenames so sidecars resolve', () {
      final chatterbox = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'chatterbox');

      for (final file in chatterbox.files) {
        expect(file.name, file.pathInRepo.split('/').last,
            reason: 'renaming would break the reference inside the graph');
        expect(
          chatterbox.urlFor(file).toString(),
          contains(file.pathInRepo),
        );
      }
    });

    test('filenames are unique across kinds', () {
      final filenames = catalog.models.map((m) => m.filename).toList();
      expect(filenames.toSet(), hasLength(filenames.length));
    });
  });
}
