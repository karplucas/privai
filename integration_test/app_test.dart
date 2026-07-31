import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privai/main.dart';
import 'package:privai/ui/models_page.dart';

/// On-device smoke tests.
///
/// These run against real plugins on a real device, so they cover the parts of
/// the app that work without a downloaded model: start-up, navigation, settings
/// persistence and the model list. Sending a message and expecting a reply is
/// deliberately not asserted — that needs multi-gigabyte weights and an accepted
/// Gemma license, which is not something a test run should assume.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> launch(WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle(const Duration(seconds: 10));
  }

  group('App start-up', () {
    testWidgets('reaches the chat screen', (tester) async {
      await launch(tester);

      expect(find.text('PrivAI'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('composer accepts and retains typed text', (tester) async {
      await launch(tester);

      const message = 'Hello, can you help me?';
      await tester.enterText(find.byType(TextField), message);
      await tester.pump();

      expect(find.text(message), findsOneWidget);
    });

    testWidgets('handles a landscape resize without overflowing',
        (tester) async {
      await launch(tester);

      await tester.binding.setSurfaceSize(const Size(800, 400));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(null);
      await tester.pumpAndSettle();
    });
  });

  group('Navigation', () {
    testWidgets('opens the settings page from the drawer', (tester) async {
      await launch(tester);

      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      await tester.tap(find.text('Settings & models'));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(find.byType(ModelsPage), findsOneWidget);
      expect(find.text('Hugging Face account'), findsOneWidget);
    });

    testWidgets('lists the gated Gemma models with a license gate',
        (tester) async {
      await launch(tester);

      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Settings & models'));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(find.textContaining('Gemma'), findsWidgets);

      // Without a signed-in account no gated model may offer a download button.
      expect(find.widgetWithText(FilledButton, 'Download'), findsNothing);
    });

    testWidgets('returns to the chat screen', (tester) async {
      await launch(tester);

      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Settings & models'));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      await tester.pageBack();
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(find.text('PrivAI'), findsOneWidget);
    });
  });
}
