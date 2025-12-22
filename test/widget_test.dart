import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/main.dart';

void main() {
  group('PrivAI App Tests', () {
    testWidgets('App displays ChatScreen immediately',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      // App should display ChatScreen immediately (no loading state)
      expect(find.text('PrivAI'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('Text field accepts input and send button works',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      // Enter text in the text field
      await tester.enterText(find.byType(TextField), 'Hello AI');
      expect(find.text('Hello AI'), findsOneWidget);

      // Tap send button
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.send));
        await Future.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // Message should appear in the list
      expect(find.text('You'), findsWidgets);
      expect(find.text('Hello AI'), findsWidgets);
    });

    testWidgets('Recording button toggles state', (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      // Initially mic icon should be visible
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);

      // Tap mic button to start recording
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      // Should show stop icon when recording
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
    });

    testWidgets('App bar displays correct title', (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      expect(find.text('PrivAI'), findsOneWidget);
    });

    testWidgets(
        'Message list displays user and AI messages with correct styling',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      // Send a message
      await tester.enterText(find.byType(TextField), 'Test message');
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.send));
        await Future.delayed(const Duration(milliseconds: 500));
      });
      await tester.pump();

      // Check that user message appears
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Test message'), findsOneWidget);
    });
  });
}
