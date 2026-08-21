import 'package:flutter_test/flutter_test.dart';
import 'package:privai/models/model_spec.dart';
import 'package:privai/services/tts_engine.dart';
import 'package:privai/services/chatterbox_tts_service.dart';
import 'package:privai/services/omnivoice_tts_service.dart';
import 'package:privai/services/mms_tts_service.dart';
import 'package:privai/services/supertonic_tts_service.dart';
import 'package:privai/services/model_catalog.dart';
import 'package:privai/services/parakeet_stt_service.dart';
import 'package:privai/services/stt_engine.dart';

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

    // Every listed Gemma model owes the user a named licence, and every gated
    // one an explanation of what the user is agreeing to.
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

    test('does not ship Gemma 3 or Gemma 3n models', () {
      final names = catalog.byKind(ModelKind.llm).map((m) => m.name).toList();
      expect(names, everyElement(startsWith('Gemma 4')));
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
      final kokoro =
          catalog.byKind(ModelKind.tts).firstWhere((m) => m.engine == 'kokoro');

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

      expect(
        chatterbox.repo,
        'owensong/chatterbox-nano-ONNX',
      );
      expect(chatterbox.revision, hasLength(40));
      expect(chatterbox.size, '570MB');
      expect(chatterbox.isBundle, isTrue);
      expect(chatterbox.bundleDirectory, isNotNull);

      final names = chatterbox.files.map((f) => f.name).toList();
      for (final required in const [
        'embed_tokens_fp16.onnx',
        'embed_tokens_fp16.onnx_data',
        'language_model_q4f16.onnx',
        'language_model_q4f16.onnx_data',
        'speech_encoder_q4f16.onnx',
        'speech_encoder_q4f16.onnx_data',
        'conditional_decoder_q4.onnx',
        'conditional_decoder_q4.onnx_data',
        'tokenizer.json',
        'default_voice.wav',
      ]) {
        expect(names, contains(required));
      }

      expect(names.where((name) => name.endsWith('.onnx')), hasLength(4));
      expect(names.where((name) => name.endsWith('.onnx_data')), hasLength(4),
          reason: 'each Nano graph has an external weight sidecar');
    });

    test('the catalog ships the exact graphs ChatterboxTtsService loads', () {
      // Regression: the service and the catalog disagreed on which language
      // model export to use.
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

      expect(chatterbox.bundleDirectory, ChatterboxTtsService.bundleName);
    });

    test('the fused OmniVoice build carries one graph in place of three', () {
      // Its export folds the embeddings encoder, the backbone and the audio
      // heads into a single quantized graph, so it needs neither of the two
      // graphs the split bundle loads — but it still needs the Higgs decoder
      // and the tokenizer, which that repo does not publish.
      final fused = catalog.byKind(ModelKind.tts).firstWhere(
          (m) => m.bundleDirectory == OmniVoiceTtsService.int8BundleName);
      final names = fused.files.map((f) => f.name).toSet();

      expect(fused.engine, 'omnivoice');
      expect(fused.revision, hasLength(40));
      expect(names, containsAll(OmniVoiceTtsService.fusedFiles));
      expect(names, contains('omnivoice.qint8.onnx_data'),
          reason: 'the graph references its weights by this exact name');
      expect(names, isNot(contains(OmniVoiceTtsService.llmGraph)));
      expect(names, isNot(contains(OmniVoiceTtsService.audioEmbeddingsGraph)));

      for (final borrowed in const ['higgs_decoder.onnx', 'higgs_decoder.onnx.data']) {
        expect(
          fused.files.firstWhere((f) => f.name == borrowed).repo,
          'onnx-community/OmniVoice-Onnx',
        );
      }
    });

    test('OmniVoice ships the hybrid automatic-voice pipeline', () {
      final omnivoice = catalog.byKind(ModelKind.tts).firstWhere(
          (m) => m.bundleDirectory == OmniVoiceTtsService.bundleName);
      final names = omnivoice.files.map((f) => f.name).toSet();

      expect(omnivoice.repo, 'dellusional/OmniVoice-ONNX-bidirectional');
      expect(omnivoice.revision, hasLength(40));
      expect(omnivoice.size, '2.16GB');
      expect(omnivoice.bundleDirectory, OmniVoiceTtsService.bundleName);
      for (final required in const [
        OmniVoiceTtsService.audioEmbeddingsGraph,
        OmniVoiceTtsService.audioHeadsGraph,
        OmniVoiceTtsService.llmGraph,
        OmniVoiceTtsService.decoderGraph,
        OmniVoiceTtsService.tokenizerFile,
        'audio_embeddings_encoder.onnx.data',
        'llm_backbone_fp32.onnx.data',
        'higgs_decoder.onnx.data',
        'model_config.json',
      ]) {
        expect(names, contains(required));
      }
      expect(
        omnivoice.files
            .firstWhere(
                (file) => file.name == OmniVoiceTtsService.audioEmbeddingsGraph)
            .pathInRepo,
        OmniVoiceTtsService.audioEmbeddingsGraph,
        reason: 'the INT4 audio embedding graph produces tonal codec output',
      );
      final backbone = omnivoice.files
          .firstWhere((file) => file.name == OmniVoiceTtsService.llmGraph);
      expect(backbone.repo, isNull,
          reason: 'the backbone comes from the corrected primary repository');
      expect(omnivoice.urlFor(backbone).host, 'huggingface.co');
      expect(omnivoice.urlFor(backbone).path,
          contains('dellusional/OmniVoice-ONNX-bidirectional'));
      final embeddings = omnivoice.files.firstWhere(
          (file) => file.name == OmniVoiceTtsService.audioEmbeddingsGraph);
      expect(embeddings.repo, 'onnx-community/OmniVoice-Onnx');
      expect(omnivoice.urlFor(embeddings).path,
          contains('onnx-community/OmniVoice-Onnx'));
      expect(
        omnivoice.files
            .firstWhere(
                (file) => file.name == OmniVoiceTtsService.audioHeadsGraph)
            .pathInRepo,
        OmniVoiceTtsService.audioHeadsGraph,
        reason: 'the INT4 audio heads produce tonal codec output',
      );
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

    test('bundle files keep their repository basenames', () {
      final chatterbox = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'chatterbox');

      for (final file in chatterbox.files) {
        expect(file.name, file.pathInRepo.split('/').last);
        expect(
          chatterbox.urlFor(file).toString(),
          contains(file.pathInRepo),
        );
      }
    });

    test('the MMS bundle carries the graph and vocabulary the service loads',
        () {
      final mms = catalog
          .byKind(ModelKind.tts)
          .firstWhere((m) => m.engine == 'mms');

      expect(mms.bundleDirectory, MmsTtsService.bundleName);
      expect(
        mms.requiredFilenames,
        containsAll([MmsTtsService.modelGraph, MmsTtsService.vocabFile]),
      );
      expect(mms.licenseNote, isNotNull,
          reason: 'MMS is non-commercial and the user has to be told');
    });

    test('both Supertonic precisions carry every graph and voice it loads',
        () {
      final builds = catalog
          .byKind(ModelKind.tts)
          .where((m) => m.engine == 'supertonic')
          .toList();

      expect(builds, hasLength(2), reason: 'fp32 and int8 are both offered');
      expect(
        builds.map((m) => m.bundleDirectory).toSet(),
        SupertonicTtsService.bundleNames.toSet(),
        reason: 'the engine loads whichever of these directories is present',
      );

      for (final build in builds) {
        expect(
          build.requiredFilenames,
          containsAll(SupertonicTtsService.requiredFiles),
          reason: '${build.name} is missing a graph the service loads',
        );
        // Every voice the engine offers has to be on disk, or picking it fails.
        expect(
          build.requiredFilenames,
          containsAll([
            for (final voice in SupertonicTtsService.voiceStyles) '$voice.json',
          ]),
          reason: '${build.name} is missing a voice',
        );
        expect(build.licenseNote, isNotNull,
            reason: '${build.name} is OpenRAIL-M and has use restrictions');
      }
    });

    test('the int8 Supertonic build lands its graphs under the fp32 names', () {
      // Its graphs are named `*.int8.onnx` upstream; the service looks for the
      // plain names, so the bundle has to rename them on the way in.
      final int8 = catalog.byKind(ModelKind.tts).firstWhere(
          (m) => m.bundleDirectory == SupertonicTtsService.int8BundleName);

      final graphs = int8.files.where((f) => f.name.endsWith('.onnx'));
      expect(graphs, isNotEmpty);
      for (final graph in graphs) {
        expect(graph.pathInRepo, contains('.int8.'));
        expect(graph.name, isNot(contains('.int8.')));
        expect(int8.urlFor(graph).toString(), contains(graph.pathInRepo));
      }
    });

    test('every speech-to-text model names an engine that exists', () {
      for (final model in catalog.byKind(ModelKind.stt)) {
        expect(model.engine, isNotNull, reason: '${model.name} has no engine');
        expect(
          SttEngineKind.fromName(model.engine).name,
          model.engine,
          reason: '${model.name} names an unknown engine "${model.engine}"',
        );
      }
    });

    test('the Parakeet bundle carries every graph the service loads', () {
      final parakeet = catalog
          .byKind(ModelKind.stt)
          .firstWhere((m) => m.engine == 'parakeet');

      expect(parakeet.bundleDirectory, ParakeetSttService.bundleName);
      expect(
        parakeet.requiredFilenames,
        containsAll([
          ParakeetSttService.preprocessorGraph,
          ParakeetSttService.encoderGraph,
          ParakeetSttService.jointGraph,
          ParakeetSttService.vocabFile,
        ]),
      );
    });

    test('filenames are unique across kinds', () {
      final filenames = catalog.models.map((m) => m.filename).toList();
      expect(filenames.toSet(), hasLength(filenames.length));
    });
  });
}
