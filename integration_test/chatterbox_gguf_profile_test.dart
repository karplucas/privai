import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privai/services/chatterbox_gguf_tts_service.dart';
import 'package:privai/services/model_storage.dart';

/// Times one GGUF synthesis, for comparison with the ONNX engine's profile.
///
/// Skipped unless the bundle is already on the device — see the ONNX profile
/// test for how to push it into the simulator's container.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profiles one utterance', (tester) async {
    final storage = ModelStorage();
    final present = await storage.bundleIsComplete(
      ChatterboxGgufTtsService.bundleName,
      const [
        ChatterboxGgufTtsService.backboneFile,
        ChatterboxGgufTtsService.codecFile,
      ],
    );
    if (!present) {
      // ignore: avoid_print
      print('SKIP: no Chatterbox GGUF bundle on this device');
      return;
    }

    final service = ChatterboxGgufTtsService();
    const text = 'The quick brown fox jumps over the lazy dog. '
        'This is roughly how long a spoken reply from the assistant runs.';

    final started = DateTime.now();
    final audio = await service.synthesise(text);
    final elapsed = DateTime.now().difference(started).inMilliseconds;

    final rtf = elapsed / 1000 / audio.seconds;
    final msPerToken = audio.frames == 0 ? 0.0 : elapsed / audio.frames;
    // ignore: avoid_print
    print('CHATTERBOX_GGUF_CSV total=$elapsed,tokens=${audio.frames},'
        'audio=${audio.seconds.toStringAsFixed(2)},'
        'rtf=${rtf.toStringAsFixed(2)},'
        'msPerToken=${msPerToken.toStringAsFixed(1)}');

    expect(audio.samples, isNotEmpty);
    await service.dispose();
  }, timeout: const Timeout(Duration(minutes: 20)));
}
