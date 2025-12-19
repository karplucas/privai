import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:privai/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('End-to-End Chatbot Tests', () {
    testWidgets('Complete chat session with multiple interactions',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      // Wait for app initialization
      await tester.pumpAndSettle(const Duration(seconds: 10));

      // Verify initial state
      expect(find.text('AI Chatbot'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsOneWidget);

      // Send first message
      await tester.enterText(find.byType(TextField), 'Hello, can you help me?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Verify user message appears
      expect(find.text('You'), findsWidgets);
      expect(find.text('Hello, can you help me?'), findsOneWidget);

      // Send second message
      await tester.enterText(
          find.byType(TextField), 'What languages do you support?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Verify second message
      expect(find.text('What languages do you support?'), findsOneWidget);

      // Test recording functionality
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byIcon(Icons.stop), findsOneWidget);

      // Stop recording
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byIcon(Icons.mic), findsOneWidget);

      // Send a farewell message
      await tester.enterText(find.byType(TextField), 'Thank you!');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle(const Duration(seconds: 3));

      expect(find.text('Thank you!'), findsOneWidget);
    });

    testWidgets('UI responsiveness and layout', (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Test in different screen sizes/orientations would go here
      // For now, just verify basic layout works

      final screenSize = tester.getSize(find.byType(Scaffold));

      // Verify the UI fits the screen
      expect(screenSize.width, greaterThan(0));
      expect(screenSize.height, greaterThan(0));

      // Verify all main UI elements are present
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.byType(ListView), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byType(IconButton), findsNWidgets(2)); // Send and Mic buttons
    });

    testWidgets('Message history persistence during session',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Send multiple messages
      const messages = ['First message', 'Second message', 'Third message'];

      for (final message in messages) {
        await tester.enterText(find.byType(TextField), message);
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }

      // Verify all messages are still visible
      for (final message in messages) {
        expect(find.text(message), findsOneWidget);
      }

      // Verify message count
      expect(find.text('You'), findsNWidgets(3));
    });

    testWidgets('Input validation and error handling',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Test sending empty message
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Should not add empty message
      expect(find.text('You'), findsNothing);

      // Test sending whitespace-only message
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Should not add whitespace-only message
      expect(find.text('You'), findsNothing);

      // Test sending valid message
      await tester.enterText(find.byType(TextField), 'Valid message');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Should add valid message
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Valid message'), findsOneWidget);
    });

    testWidgets('Audio recording UI feedback', (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Initially not recording
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);

      // Start recording
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      // Should show recording state
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);

      // The stop button should be red (recording indicator)
      final stopButton = tester.widget<IconButton>(find.byIcon(Icons.stop));
      expect(stopButton.color, Colors.red);

      // Stop recording
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();

      // Should return to normal state
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);
    });
  });
}
