import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

/// A single stored chat.
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final List<Map<String, String>> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'messages': messages,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  /// Parses a stored conversation, or returns null when the record is too
  /// damaged to be useful.
  ///
  /// The previous version substituted an empty "Recovered Chat" with a fresh id
  /// on any parse error, which meant a single bad record quietly multiplied into
  /// new empty conversations on every load.
  static Conversation? tryFromJson(Map<String, dynamic> json) {
    final id = json['id']?.toString();
    if (id == null || id.isEmpty) {
      debugPrint('Conversation: dropping record with no id');
      return null;
    }

    final createdAt = _parseDate(json['createdAt']);
    final updatedAt = _parseDate(json['updatedAt']) ?? createdAt;

    return Conversation(
      id: id,
      title: json['title']?.toString() ?? 'New Chat',
      messages: _parseMessages(json['messages']),
      createdAt: createdAt ?? DateTime.now(),
      updatedAt: updatedAt ?? DateTime.now(),
    );
  }

  static DateTime? _parseDate(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;

  static List<Map<String, String>> _parseMessages(Object? raw) {
    if (raw is! List) return [];
    return raw.map<Map<String, String>>((message) {
      if (message is Map) {
        return {
          'role': message['role']?.toString() ?? 'user',
          'text': message['text']?.toString() ?? '',
        };
      }
      return {'role': 'user', 'text': message.toString()};
    }).toList();
  }

  Conversation copyWith({
    String? title,
    List<Map<String, String>>? messages,
    DateTime? updatedAt,
  }) =>
      Conversation(
        id: id,
        title: title ?? this.title,
        messages: messages ?? this.messages,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}

/// Persists chat history.
///
/// History used to live in [FlutterSecureStorage], which on Android is backed by
/// encrypted shared preferences — a key/value store meant for small secrets, not
/// for an ever-growing JSON blob of every message ever sent. Conversations are
/// now written to a file in the app's private directory; only the pointer to the
/// current conversation stays in preferences.
class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  static const String _fileName = 'conversations.json';
  static const String _currentConversationKey = 'current_conversation';
  static const String _legacyConversationsKey = 'conversations';

  final FlutterSecureStorage _prefs = const FlutterSecureStorage();

  /// Serialises writes so two concurrent saves cannot interleave and corrupt
  /// the file.
  Future<void> _writeQueue = Future.value();

  List<Conversation>? _cache;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) await dir.create(recursive: true);
    return File('${dir.path}/$_fileName');
  }

  Future<List<Conversation>> getConversations() async {
    final cached = _cache;
    if (cached != null) return List.unmodifiable(cached);

    final conversations = await _readFromDisk();
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _cache = conversations;
    return List.unmodifiable(conversations);
  }

  Future<List<Conversation>> _readFromDisk() async {
    try {
      final file = await _file();
      if (!await file.exists()) return _migrateFromSecureStorage();

      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return [];
      return _decode(raw);
    } catch (e) {
      debugPrint('ConversationService: could not read history: $e');
      return [];
    }
  }

  List<Conversation> _decode(String raw) {
    final decoded = json.decode(raw);
    if (decoded is! List) return [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(Conversation.tryFromJson)
        .whereType<Conversation>()
        .toList();
  }

  /// One-time move of history written by earlier versions of the app.
  Future<List<Conversation>> _migrateFromSecureStorage() async {
    final legacy = await _prefs.read(key: _legacyConversationsKey);
    if (legacy == null || legacy.trim().isEmpty) return [];

    try {
      final conversations = _decode(legacy);
      debugPrint(
        'ConversationService: migrating ${conversations.length} conversations '
        'out of secure storage',
      );
      await _persist(conversations);
      await _prefs.delete(key: _legacyConversationsKey);
      return conversations;
    } catch (e) {
      debugPrint('ConversationService: migration failed: $e');
      return [];
    }
  }

  Future<void> _persist(List<Conversation> conversations) {
    // Chain onto the queue so writes stay ordered.
    return _writeQueue = _writeQueue.then((_) async {
      final file = await _file();
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        json.encode(conversations.map((c) => c.toJson()).toList()),
        flush: true,
      );
      // Rename is atomic, so a crash mid-write cannot truncate the history.
      await temp.rename(file.path);
    }).catchError((Object e) {
      debugPrint('ConversationService: write failed: $e');
    });
  }

  Future<Conversation?> getCurrentConversation() async {
    final currentId = await _prefs.read(key: _currentConversationKey);
    if (currentId == null) return null;

    final conversations = await getConversations();
    for (final conversation in conversations) {
      if (conversation.id == currentId) return conversation;
    }
    return null;
  }

  Future<void> setCurrentConversation(String conversationId) =>
      _prefs.write(key: _currentConversationKey, value: conversationId);

  Future<Conversation> createNewConversation({String title = 'New Chat'}) async {
    final now = DateTime.now();
    final conversation = Conversation(
      id: '${now.millisecondsSinceEpoch}',
      title: title,
      messages: const [],
      createdAt: now,
      updatedAt: now,
    );

    final conversations = [conversation, ...await getConversations()];
    _cache = conversations;
    await _persist(conversations);
    await setCurrentConversation(conversation.id);
    return conversation;
  }

  /// Replaces the messages of [conversationId], retitling it from the first
  /// user message.
  Future<void> updateConversationMessages(
    String conversationId,
    List<Map<String, String>> messages,
  ) async {
    final conversations = [...await getConversations()];
    final index = conversations.indexWhere((c) => c.id == conversationId);
    final now = DateTime.now();

    if (index >= 0) {
      conversations[index] = conversations[index].copyWith(
        messages: List.of(messages),
        title: _generateTitle(messages),
        updatedAt: now,
      );
    } else {
      conversations.add(Conversation(
        id: conversationId,
        title: _generateTitle(messages),
        messages: List.of(messages),
        createdAt: now,
        updatedAt: now,
      ));
    }

    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _cache = conversations;
    await _persist(conversations);
  }

  Future<void> deleteConversation(String conversationId) async {
    final conversations = [...await getConversations()]
      ..removeWhere((c) => c.id == conversationId);
    _cache = conversations;
    await _persist(conversations);

    if (await _prefs.read(key: _currentConversationKey) == conversationId) {
      await _prefs.delete(key: _currentConversationKey);
    }
  }

  /// Removes every stored conversation, used when history saving is turned off.
  Future<void> deleteAll() async {
    _cache = [];
    await _persist(const []);
    await _prefs.delete(key: _currentConversationKey);
  }

  /// Waits for queued writes to land. Useful before the app exits.
  Future<void> flush() => _writeQueue;

  String _generateTitle(List<Map<String, String>> messages) {
    for (final message in messages) {
      if (message['role'] != 'user') continue;
      final text = (message['text'] ?? '').trim();
      if (text.isEmpty) continue;
      return text.length <= 40 ? text : '${text.substring(0, 40)}...';
    }
    return 'New Chat';
  }

  String formatDate(DateTime date) {
    final difference = DateTime.now().difference(date);
    if (difference.inDays == 0) return DateFormat('HH:mm').format(date);
    if (difference.inDays == 1) return 'Yesterday';
    if (difference.inDays < 7) return DateFormat('EEEE').format(date);
    return DateFormat('MMM d').format(date);
  }

  @visibleForTesting
  void invalidateCache() => _cache = null;
}
