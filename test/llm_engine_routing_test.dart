import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/models/model_spec.dart';
import 'package:privai/services/llm_service.dart';
import 'package:privai/services/model_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('engine routing', () {
    test('sends each extension to the engine that can load it', () {
      expect(
        LlmService.fileTypeFor('gemma-4-E2B-it.litertlm'),
        ModelFileType.litertlm,
      );
      expect(
        LlmService.fileTypeFor('gemma-3n-E2B-it-int4.task'),
        ModelFileType.task,
      );
      expect(LlmService.fileTypeFor('model.bin'), ModelFileType.binary);
      expect(LlmService.fileTypeFor('model.tflite'), ModelFileType.binary);
    });

    test('is case insensitive and tolerates dotted names', () {
      expect(
        LlmService.fileTypeFor('Gemma3-1B-IT_q4_ekv4096.LiteRTLM'),
        ModelFileType.litertlm,
      );
      expect(
        LlmService.fileTypeFor('model.v1.2.litertlm'),
        ModelFileType.litertlm,
      );
    });

    // Left at flutter_gemma's default the install declares every model a .task,
    // which routes .litertlm files to MediaPipe — whose native EngineFactory
    // refuses them ("should be handled by Dart FFI (LiteRtLmFfiClient)"). So
    // the catalog's own filenames are what this has to hold for.
    test('routes every LLM in the shipped catalog to a real engine', () async {
      ModelCatalog().invalidate();
      final catalog = await ModelCatalog().load();
      final llms = catalog.byKind(ModelKind.llm);

      expect(llms, isNotEmpty);
      for (final model in llms) {
        final fileType = LlmService.fileTypeFor(model.filename);
        final expected = model.filename.endsWith('.litertlm')
            ? ModelFileType.litertlm
            : ModelFileType.task;
        expect(
          fileType,
          expected,
          reason: '${model.filename} must install as ${expected.name}',
        );
      }
    });
  });
}
