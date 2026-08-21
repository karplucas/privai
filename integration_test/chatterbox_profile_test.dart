import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privai/services/chatterbox_tts_service.dart';
import 'package:privai/services/model_storage.dart';

/// Measures where Chatterbox spends its time, stage by stage.
///
/// Skipped unless the bundle is already on the device: it is 570 MB and a test
/// run must not download it. Push it into the simulator's container first —
/// `xcrun simctl get_app_container <udid> com.LucasKarpinski.privai data` gives
/// the path, and the files belong in
/// `Library/Application Support/<bundle-id>/models/chatterbox-nano-q4f16/`.
///
/// Synthesis only; nothing is played, so the numbers are compute alone.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('profiles one utterance', (tester) async {
    final storage = ModelStorage();
    final present = await storage.bundleIsComplete(
      ChatterboxTtsService.bundleName,
      const [
        ChatterboxTtsService.embedGraph,
        ChatterboxTtsService.languageGraph,
        ChatterboxTtsService.decoderGraph,
        ChatterboxTtsService.tokenizerFile,
      ],
    );
    if (!present) {
      final dir = await storage.bundleDirectory(ChatterboxTtsService.bundleName);
      // ignore: avoid_print
      print('SKIP: no Chatterbox bundle at ${dir.path}');
      return;
    }

    final service = ChatterboxTtsService();

    // Two sentences of ordinary reply length. The decode loop is the part that
    // scales with the text, so a realistic length is what makes the split
    // between stages meaningful.
    const text = 'The quick brown fox jumps over the lazy dog. '
        'This is roughly how long a spoken reply from the assistant runs.';

    final samples = await service.synthesise(text);
    final profile = service.lastProfile!;

    // ignore: avoid_print
    print('CHATTERBOX_PROFILE ${profile.toString()}');
    // ignore: avoid_print
    print('CHATTERBOX_CSV load=${profile.loadMs},cond=${profile.conditioningMs},'
        'tokenize=${profile.tokenizeMs},prefill=${profile.prefillMs},'
        'decode=${profile.decodeMs},vocode=${profile.vocodeMs},'
        'total=${profile.totalMs},tokens=${profile.speechTokens},'
        'audio=${profile.audioSeconds.toStringAsFixed(2)},'
        'rtf=${profile.realTimeFactor.toStringAsFixed(2)},'
        'msPerToken=${profile.msPerToken.toStringAsFixed(1)}');

    expect(samples, isNotEmpty);
    await service.dispose();
  }, timeout: const Timeout(Duration(minutes: 15)));
}
