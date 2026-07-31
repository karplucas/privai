import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/main.dart' as app;
import 'package:privai/main.dart';
import 'package:privai/services/asset_bundle_override.dart';

import 'test_harness.dart';

/// Widget tests for the chat screen.
///
/// These deliberately do not assert on model replies: no language model is
/// loaded in a test run, so anything that claims to send a message and receive
/// an answer would be asserting on a stub rather than on the app. What is
/// verified here is the shell the user sees before and without a model.
void main() {
  setUp(FakePlatform.install);

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    // Let the asynchronous start-up (settings, history, model probe) finish.
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  group('Entry point', () {
    // Nothing exercised main() before, which is how a crash on its very first
    // line reached a run. Note the limitation: flutter_test installs a binding
    // before any test executes, so these cannot reproduce the "no binding
    // exists yet" state that main() actually starts from — only launching the
    // app covers that. What they do pin down is that main() runs at all and
    // that ensureInitialized defers to a binding already in place.
    testWidgets('main() boots the app without throwing', (tester) async {
      app.main();
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.byType(MyApp), findsOneWidget);
      expect(find.text('PrivAI'), findsOneWidget);
    });

    testWidgets('ensureInitialized adopts an existing binding', (tester) async {
      final existing = WidgetsBinding.instance;

      expect(AssetOverrideBinding.ensureInitialized(), same(existing));
      // Idempotent, as ensureInitialized methods are expected to be.
      expect(AssetOverrideBinding.ensureInitialized(), same(existing));
    });
  });

  group('Chat screen', () {
    testWidgets('shows the app title', (tester) async {
      await pumpApp(tester);
      expect(find.text('PrivAI'), findsOneWidget);
    });

    testWidgets('shows the composer with send and mic buttons', (tester) async {
      await pumpApp(tester);

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });

    testWidgets('accepts typed input', (tester) async {
      await pumpApp(tester);

      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.pump();

      expect(find.text('Hello'), findsOneWidget);
    });

    testWidgets('shows the empty state before any messages', (tester) async {
      await pumpApp(tester);

      expect(
        find.textContaining('Everything here runs on this device'),
        findsOneWidget,
      );
    });

    testWidgets('does not send a blank message', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // The empty state is still showing, so nothing was added.
      expect(
        find.textContaining('Everything here runs on this device'),
        findsOneWidget,
      );
    });

    testWidgets('warns instead of sending when no model is loaded',
        (tester) async {
      await pumpApp(tester);

      await tester.enterText(find.byType(TextField), 'Are you there?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // A snack bar explains why nothing happened rather than the message
      // silently vanishing.
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('drawer offers a new chat and the settings page',
        (tester) async {
      await pumpApp(tester);

      tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
      // Fixed pumps rather than pumpAndSettle: the history list shows a
      // CircularProgressIndicator while it loads, and an indefinite animation
      // means "settled" never arrives.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Settings & models'), findsOneWidget);
    });
  });
}
