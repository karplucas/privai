import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/main.dart';
import 'package:privai/services/llm_service.dart';

import 'test_harness.dart';

/// Covers the chat screen's token streaming.
///
/// The model is replaced with a scripted stream through
/// [LlmService.debugResponseStream], so these exercise the real widget code —
/// accumulation, stopping, error handling — without model weights.
///
/// Two things to know when editing these:
///  * A stream event needs two `pump`s to reach the widget tree: one to deliver
///    it to the listener, one to rebuild after `setState`.
///  * `pumpAndSettle` never returns while the reply bubble's
///    `CircularProgressIndicator` is on screen, and pushing events into a
///    controller whose subscription has been cancelled wedges the test harness.
///    Prefer fixed pumps and closing the controller.
void main() {
  setUp(FakePlatform.install);
  tearDown(() => LlmService().debugResponseStream = null);

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle(const Duration(seconds: 2));
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
    await tester.pump();
  }

  /// Delivers a queued stream event and rebuilds.
  Future<void> settleEvent(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('tokens accumulate instead of replacing one another',
      (tester) async {
    final controller = StreamController<String>();
    LlmService().debugResponseStream = (_) => controller.stream;

    await pumpApp(tester);
    await send(tester, 'hi');

    controller.add('Hello');
    await settleEvent(tester);
    expect(find.text('Hello'), findsOneWidget);

    controller.add(' there');
    await settleEvent(tester);
    // Each event is a fragment, so the bubble must show the running total.
    expect(find.text('Hello there'), findsOneWidget);
    expect(find.text(' there'), findsNothing);

    controller.add(', friend');
    await settleEvent(tester);
    expect(find.text('Hello there, friend'), findsOneWidget);

    await controller.close();
    await settleEvent(tester);
    expect(find.text('Hello there, friend'), findsOneWidget);
  });

  testWidgets('shows a progress indicator until the first token lands',
      (tester) async {
    final controller = StreamController<String>();
    LlmService().debugResponseStream = (_) => controller.stream;

    await pumpApp(tester);
    await send(tester, 'hi');

    // The reply bubble is in the list but still empty.
    expect(find.byType(CircularProgressIndicator), findsWidgets);

    controller.add('Answer');
    await settleEvent(tester);
    expect(find.text('Answer'), findsOneWidget);

    await controller.close();
    await settleEvent(tester);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an idle model stream closes after producing partial text',
      (tester) async {
    final controller = StreamController<String>();
    LlmService().debugResponseStream = (_) => controller.stream;

    await pumpApp(tester);
    await send(tester, 'Are you working?');
    controller.add('Yes I work');
    await settleEvent(tester);
    expect(find.text('Yes I work'), findsOneWidget);

    await tester.pump(const Duration(seconds: 9));
    await tester.pump();

    expect(find.text('Yes I work'), findsOneWidget);
    expect(find.text('Stop generating'), findsNothing);
    unawaited(controller.close());
  });

  testWidgets('composer remains focusable while a response is streaming',
      (tester) async {
    final controller = StreamController<String>();
    LlmService().debugResponseStream = (_) => controller.stream;

    await pumpApp(tester);
    await send(tester, 'hi');

    final field = find.byKey(const ValueKey('message_composer'));
    expect(tester.widget<TextField>(field).enabled, isNot(false));
    await tester.tap(field);
    await tester.pump();
    expect(tester.widget<TextField>(field).focusNode?.hasFocus, isTrue);

    await controller.close();
    await settleEvent(tester);
  });

  testWidgets('the user message appears before any token arrives',
      (tester) async {
    final controller = StreamController<String>();
    LlmService().debugResponseStream = (_) => controller.stream;

    await pumpApp(tester);
    await send(tester, 'What is 2 + 2?');

    expect(find.text('What is 2 + 2?'), findsOneWidget);

    await controller.close();
    await settleEvent(tester);
  });

  testWidgets('offers a stop control only while streaming', (tester) async {
    final controller = StreamController<String>();
    LlmService().debugResponseStream = (_) => controller.stream;

    await pumpApp(tester);
    expect(find.text('Stop generating'), findsNothing);

    await send(tester, 'hi');
    expect(find.text('Stop generating'), findsOneWidget);

    await controller.close();
    await settleEvent(tester);
    expect(find.text('Stop generating'), findsNothing);
  });

  testWidgets('stopping cancels the model and keeps the text so far',
      (tester) async {
    var generatorClosed = false;

    LlmService().debugResponseStream = (_) async* {
      try {
        yield 'Partial answer';
        // Would run indefinitely if nothing cancelled it.
        for (var i = 0; i < 1000; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          yield ' more';
        }
      } finally {
        // Reached when the listener cancels, which is what proves the stop
        // actually halted generation rather than just hiding the output.
        generatorClosed = true;
      }
    };

    await pumpApp(tester);
    await send(tester, 'hi');
    await tester.pump(const Duration(milliseconds: 10));
    await settleEvent(tester);
    expect(find.textContaining('Partial answer'), findsOneWidget);

    await tester.tap(find.text('Stop generating'));
    await tester.pump();

    // Let the next token arrive so the loop sees the stop request and breaks.
    await tester.pump(const Duration(milliseconds: 20));
    await settleEvent(tester);

    expect(generatorClosed, isTrue,
        reason: 'the model stream must be cancelled');
    expect(find.textContaining('Partial answer'), findsOneWidget);
    expect(find.text('Stop generating'), findsNothing);
  });

  testWidgets('keeps partial output when generation fails midway',
      (tester) async {
    LlmService().debugResponseStream = (_) async* {
      yield 'Half an answer';
      throw StateError('backend exploded');
    };

    await pumpApp(tester);
    await send(tester, 'hi');
    await settleEvent(tester);

    // The partial text must survive, with the failure explained beneath it,
    // rather than the whole reply being discarded.
    expect(find.textContaining('Half an answer'), findsOneWidget);
    expect(find.textContaining('Something went wrong'), findsOneWidget);
  });

  testWidgets('a context-overflow failure is reported as such', (tester) async {
    LlmService().debugResponseStream = (_) async* {
      throw Exception('input exceeds max context tokens');
      // ignore: dead_code
      yield '';
    };

    await pumpApp(tester);
    await send(tester, 'hi');
    await settleEvent(tester);

    expect(find.textContaining('context window'), findsOneWidget);
  });

  testWidgets('starting a new conversation mid-stream does not crash',
      (tester) async {
    LlmService().debugResponseStream = (_) async* {
      yield 'Partial';
      for (var i = 0; i < 100; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        yield ' more';
      }
    };

    await pumpApp(tester);
    await send(tester, 'hi');
    await tester.pump(const Duration(milliseconds: 10));
    await settleEvent(tester);

    tester.state<ScaffoldState>(find.byType(Scaffold).first).openDrawer();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('New chat'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // The reply bubble is no longer in the list; further tokens write to a
    // detached map, which must not throw a RangeError.
    await tester.pump(const Duration(milliseconds: 20));
    await settleEvent(tester);
    expect(tester.takeException(), isNull);
  });
}
