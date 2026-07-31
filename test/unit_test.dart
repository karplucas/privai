import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:privai/services/app_settings.dart';
import 'package:privai/services/conversation_service.dart';
import 'package:privai/services/model_storage.dart';

import 'test_harness.dart';

void main() {
  group('AppSettings defaults', () {
    late FakePlatform platform;

    setUp(() {
      platform = FakePlatform.install();
    });

    test('voice features default to on when nothing is stored', () async {
      // Regression: these keys used to be compared against the string 'true' at
      // each call site, so an absent key resolved to false and a fresh install
      // came up with speech silently disabled.
      final settings = AppSettings();
      expect(await settings.ttsEnabled, isTrue);
      expect(await settings.sttEnabled, isTrue);
      expect(await settings.saveChatHistory, isTrue);
    });

    test('stored booleans round-trip', () async {
      final settings = AppSettings();
      await settings.setTtsEnabled(false);
      expect(await settings.ttsEnabled, isFalse);
      await settings.setTtsEnabled(true);
      expect(await settings.ttsEnabled, isTrue);
    });

    test('numeric settings are clamped to a usable range', () async {
      final settings = AppSettings();

      await settings.setTemperature(99);
      expect(await settings.temperature, 2.0);

      await settings.setMaxTokens(1);
      expect(await settings.maxTokens, 256);
    });

    test('corrupt numeric values fall back to the default', () async {
      platform.secureStorage['llm_temperature'] = 'not a number';
      expect(await AppSettings().temperature, AppSettings.defaultTemperature);
    });

    test('an empty token reads back as no token', () async {
      final settings = AppSettings();
      await settings.setHfToken('');
      expect(await settings.hfToken, isNull);

      await settings.setHfToken('hf_example');
      expect(await settings.hfToken, 'hf_example');

      await settings.clearHfToken();
      expect(await settings.hfToken, isNull);
    });

    test('deleting a model clears only that selection', () async {
      final settings = AppSettings();
      await settings.setSelectedLlmModel('llm.task');
      await settings.setSelectedSttModel('stt.bin');

      await settings.clearSelectionFor('llm.task');

      expect(await settings.selectedLlmModel, isNull);
      expect(await settings.selectedSttModel, 'stt.bin');
    });
  });

  group('ModelStorage', () {
    setUp(() {
      FakePlatform.install();
      ModelStorage().resetCacheForTest();
    });

    test('resolves one directory for every caller', () async {
      final storage = ModelStorage();
      final a = await storage.pathFor('model.task');
      final b = await ModelStorage().pathFor('model.task');
      expect(a, b);
    });

    test('keeps partial downloads under a separate name', () async {
      final storage = ModelStorage();
      expect(
        await storage.partialPathFor('model.task'),
        '${await storage.pathFor('model.task')}${ModelStorage.partialSuffix}',
      );
    });

    test('reports a missing model as not downloaded', () async {
      expect(await ModelStorage().isDownloaded('absent.task'), isFalse);
      expect(await ModelStorage().sizeOf('absent.task'), 0);
    });

    test('listing ignores partial downloads', () async {
      final storage = ModelStorage();
      final dir = await storage.directory();
      await File('${dir.path}/done.task').writeAsString('x');
      await File('${dir.path}/busy.task${ModelStorage.partialSuffix}')
          .writeAsString('x');

      expect(await storage.listDownloaded(), ['done.task']);
    });

    test('delete removes both the model and its partial file', () async {
      final storage = ModelStorage();
      final dir = await storage.directory();
      await File('${dir.path}/gone.task').writeAsString('x');
      await File('${dir.path}/gone.task${ModelStorage.partialSuffix}')
          .writeAsString('x');

      await storage.delete('gone.task');

      expect(await storage.listDownloaded(), isEmpty);
      expect(await storage.partialSizeOf('gone.task'), 0);
    });
  });

  group('Conversation parsing', () {
    test('reads a well-formed record', () {
      final conversation = Conversation.tryFromJson({
        'id': '1',
        'title': 'Hello',
        'messages': [
          {'role': 'user', 'text': 'hi'},
        ],
        'createdAt': '2026-01-01T10:00:00.000',
        'updatedAt': '2026-01-02T10:00:00.000',
      });

      expect(conversation, isNotNull);
      expect(conversation!.title, 'Hello');
      expect(conversation.messages.single['text'], 'hi');
      expect(conversation.updatedAt.day, 2);
    });

    test('drops a record with no id rather than inventing one', () {
      // Regression: a parse failure used to produce a brand new empty
      // conversation with a fresh id, which multiplied on every load.
      expect(Conversation.tryFromJson({'title': 'orphan'}), isNull);
    });

    test('survives unparseable dates and message shapes', () {
      final conversation = Conversation.tryFromJson({
        'id': '2',
        'createdAt': 'not a date',
        'messages': ['bare string'],
      });

      expect(conversation, isNotNull);
      expect(conversation!.messages.single['role'], 'user');
      expect(conversation.messages.single['text'], 'bare string');
    });
  });

  group('ConversationService', () {
    setUp(FakePlatform.install);

    test('stores, retitles and deletes conversations', () async {
      final service = ConversationService()..invalidateCache();

      final conversation = await service.createNewConversation();
      await service.updateConversationMessages(conversation.id, [
        {'role': 'user', 'text': 'What is the capital of France?'},
        {'role': 'ai', 'text': 'Paris.'},
      ]);

      service.invalidateCache();
      final stored = await service.getConversations();
      expect(stored, hasLength(1));
      expect(stored.single.title, 'What is the capital of France?');
      expect(stored.single.messages, hasLength(2));

      await service.deleteConversation(conversation.id);
      service.invalidateCache();
      expect(await service.getConversations(), isEmpty);
    });

    test('titles a conversation from the first non-empty user message',
        () async {
      final service = ConversationService()..invalidateCache();
      final conversation = await service.createNewConversation();

      await service.updateConversationMessages(conversation.id, [
        {'role': 'ai', 'text': 'How can I help?'},
        {'role': 'user', 'text': '   '},
        {'role': 'user', 'text': 'Explain gradients'},
      ]);

      service.invalidateCache();
      expect((await service.getConversations()).single.title,
          'Explain gradients');
    });

    test('migrates history written to secure storage by older versions',
        () async {
      final platform = FakePlatform.install();
      platform.secureStorage['conversations'] =
          '[{"id":"legacy","title":"Old chat","messages":[],'
          '"createdAt":"2026-01-01T00:00:00.000",'
          '"updatedAt":"2026-01-01T00:00:00.000"}]';

      final service = ConversationService()..invalidateCache();
      final conversations = await service.getConversations();

      expect(conversations.single.id, 'legacy');
      await service.flush();
      // The key is cleared so the blob does not stay in encrypted preferences.
      expect(platform.secureStorage.containsKey('conversations'), isFalse);
    });
  });
}
