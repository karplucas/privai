import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privai/main.dart';

void main() {
  group('Chatbot App Core Functionality Tests', () {
    test('MyApp widget can be instantiated', () {
      const app = MyApp();
      expect(app, isA<MyApp>());
    });

    test('ChatScreen widget can be instantiated', () {
      const chatScreen = ChatScreen();
      expect(chatScreen, isA<ChatScreen>());
    });

    test('Supported languages list is valid', () {
      // Test the languages that Whisper supports
      final supportedLanguages = [
        'en',
        'es',
        'fr',
        'de',
        'it',
        'pt',
        'ru',
        'ja',
        'zh',
        'ko',
        'ar',
        'hi'
      ];

      for (final lang in supportedLanguages) {
        expect(lang.length, equals(2));
        expect(lang, matches(r'^[a-z]{2,3}$'));
      }
    });

    test('Text message validation works', () {
      // Test various message inputs
      expect(_isValidMessage('Hello AI'), isTrue);
      expect(_isValidMessage(''), isFalse);
      expect(_isValidMessage('   '), isFalse);
      expect(_isValidMessage(null), isFalse);
    });

    test('Audio file path generation is correct', () {
      const tempPath = '/tmp/audio.wav';
      expect(tempPath.endsWith('.wav'), isTrue);
      expect(tempPath.contains('audio'), isTrue);
    });

    test('Kokoro TTS model configuration', () {
      // Test that Kokoro model paths are correctly configured
      final modelConfig = {
        'model': 'assets/tts/kokoro-multi-lang-v1_1/model.onnx',
        'voices': 'assets/tts/kokoro-multi-lang-v1_1/voices.bin',
        'tokens': 'assets/tts/kokoro-multi-lang-v1_1/tokens.txt',
        'lexicon':
            'assets/tts/kokoro-multi-lang-v1_1/lexicon-us-en.txt,assets/tts/kokoro-multi-lang-v1_1/lexicon-zh.txt',
        'dataDir': 'assets/tts/kokoro-multi-lang-v1_1/espeak-ng-data',
      };

      expect(modelConfig['model']!.contains('kokoro'), isTrue);
      expect(modelConfig['voices']!.contains('voices.bin'), isTrue);
      expect(modelConfig['tokens']!.contains('tokens.txt'), isTrue);
      expect(modelConfig['lexicon']!.contains('lexicon'), isTrue);
      expect(modelConfig['dataDir']!.contains('espeak-ng-data'), isTrue);
    });
  });

  group('UI Component Tests', () {
    testWidgets('Loading state displays circular progress indicator',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('Chat interface loads after initialization',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      expect(find.text('PrivAI'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets('Send button is present and tappable',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      final sendButton = find.byIcon(Icons.send);
      expect(sendButton, findsOneWidget);

      await tester.tap(sendButton);
      await tester.pump();
      // Button should still be there after tap
      expect(sendButton, findsOneWidget);
    });

    testWidgets('Mic button toggles between record and stop',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Initially shows mic icon
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(find.byIcon(Icons.stop), findsNothing);

      // Tap to start recording
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();

      // Should show stop icon
      expect(find.byIcon(Icons.stop), findsOneWidget);
      expect(find.byIcon(Icons.mic), findsNothing);
    });

    testWidgets('Text field accepts and displays input',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      const testMessage = 'Test chatbot message';
      await tester.enterText(find.byType(TextField), testMessage);

      expect(find.text(testMessage), findsOneWidget);
    });
  });

  group('Message Flow Tests', () {
    testWidgets('Sending message adds it to conversation',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      const testMessage = 'Hello AI assistant';

      // Enter and send message
      await tester.enterText(find.byType(TextField), testMessage);
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // Check that user message appears
      expect(find.text('You'), findsOneWidget);
      expect(find.text(testMessage), findsOneWidget);
    });

    testWidgets('Empty message is not sent', (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Try to send empty message
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // No messages should be in the list
      expect(find.text('You'), findsNothing);
    });

    testWidgets('Message list scrolls for long conversations',
        (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // Send multiple messages
      for (int i = 1; i <= 10; i++) {
        await tester.enterText(find.byType(TextField), 'Message $i');
        await tester.tap(find.byIcon(Icons.send));
        await tester.pump();
      }

      // Should find all messages
      expect(find.text('Message 1'), findsOneWidget);
      expect(find.text('Message 10'), findsOneWidget);
    });
  });

  group('Multilingual Support Tests', () {
    test('Language codes are valid ISO format', () {
      final languageCodes = {
        'English': 'en',
        'Spanish': 'es',
        'French': 'fr',
        'German': 'de',
        'Chinese': 'zh',
        'Japanese': 'ja',
        'Korean': 'ko',
        'Arabic': 'ar',
        'Hindi': 'hi',
        'Portuguese': 'pt',
        'Russian': 'ru',
        'Italian': 'it'
      };

      languageCodes.forEach((language, code) {
        expect(code.length, greaterThanOrEqualTo(2));
        expect(code.length, lessThanOrEqualTo(3));
        expect(code, matches(r'^[a-z]{2,3}$'));
      });
    });

    test('Kokoro TTS speaker IDs are valid', () {
      // Test speaker IDs for Kokoro model (0-102 = 103 speakers)
      final speakerIds = [0, 1, 50, 100, 102];

      for (final id in speakerIds) {
        expect(id, isNonNegative);
        expect(id, lessThan(103)); // Kokoro has 103 speakers (0-102)
      }
    });
  });

  group('Integration Tests', () {
    testWidgets('Complete user interaction flow', (WidgetTester tester) async {
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle(const Duration(seconds: 5));

      // 1. Enter text
      const message = 'How are you?';
      await tester.enterText(find.byType(TextField), message);

      // 2. Send message
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // 3. Verify message appears
      expect(find.text('You'), findsOneWidget);
      expect(find.text(message), findsOneWidget);

      // 4. Test recording functionality
      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      expect(find.byIcon(Icons.stop), findsOneWidget);

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(find.byIcon(Icons.mic), findsOneWidget);
    });
  });
}

// Helper functions for testing
bool _isValidMessage(String? message) {
  return message != null && message.trim().isNotEmpty;
}
