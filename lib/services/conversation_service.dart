import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';

class Conversation {
  final String id;
  final String title;
  final List<Map<String, String>> messages;
  final DateTime createdAt;
  final DateTime updatedAt;

  Conversation({
    required this.id,
    required this.title,
    required this.messages,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'messages': messages,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  factory Conversation.fromJson(Map<String, dynamic> json) {
    try {
      final id = json['id']?.toString() ?? '';
      final title = json['title']?.toString() ?? 'New Chat';
      final createdAtStr =
          json['createdAt']?.toString() ?? DateTime.now().toIso8601String();
      final updatedAtStr =
          json['updatedAt']?.toString() ?? DateTime.now().toIso8601String();

      List<Map<String, String>> messages = [];
      if (json['messages'] is List) {
        messages = (json['messages'] as List)
            .map((msg) {
              if (msg is Map<String, dynamic>) {
                return {
                  'role': msg['role']?.toString() ?? 'user',
                  'text': msg['text']?.toString() ?? '',
                };
              }
              return {'role': 'user', 'text': msg.toString()};
            })
            .cast<Map<String, String>>()
            .toList();
      }

      return Conversation(
        id: id,
        title: title,
        messages: messages,
        createdAt: DateTime.parse(createdAtStr),
        updatedAt: DateTime.parse(updatedAtStr),
      );
    } catch (e) {
      debugPrint('Error parsing conversation from JSON: $e, data: $json');
      // Return a default conversation if parsing fails
      return Conversation(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: 'Recovered Chat',
        messages: [],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
    }
  }

  Conversation copyWith({
    String? id,
    String? title,
    List<Map<String, String>>? messages,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Conversation(
      id: id ?? this.id,
      title: title ?? this.title,
      messages: messages ?? this.messages,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class ConversationService {
  static final ConversationService _instance = ConversationService._internal();
  factory ConversationService() => _instance;
  ConversationService._internal();

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _conversationsKey = 'conversations';
  static const String _currentConversationKey = 'current_conversation';

  Future<List<Conversation>> getConversations() async {
    try {
      final conversationsJson = await _storage.read(key: _conversationsKey);
      if (conversationsJson == null) {
        debugPrint('No conversations found in storage');
        return [];
      }

      final List<dynamic> jsonList = json.decode(conversationsJson);
      final conversations = <Conversation>[];

      for (final jsonItem in jsonList) {
        try {
          if (jsonItem is Map<String, dynamic>) {
            conversations.add(Conversation.fromJson(jsonItem));
          } else {
            debugPrint('Invalid conversation format: $jsonItem');
          }
        } catch (e) {
          debugPrint('Error parsing conversation: $e, data: $jsonItem');
        }
      }

      conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      debugPrint('Loaded ${conversations.length} conversations from storage');
      return conversations;
    } catch (e) {
      debugPrint('Error loading conversations: $e');
      return [];
    }
  }

  Future<Conversation?> getCurrentConversation() async {
    try {
      final currentId = await _storage.read(key: _currentConversationKey);
      if (currentId == null) return null;

      final conversations = await getConversations();
      return conversations.where((c) => c.id == currentId).firstOrNull;
    } catch (e) {
      return null;
    }
  }

  Future<void> saveConversation(Conversation conversation) async {
    debugPrint(
        'Saving conversation ${conversation.id} with ${conversation.messages.length} messages');
    final conversations = await getConversations();

    final existingIndex =
        conversations.indexWhere((c) => c.id == conversation.id);
    if (existingIndex >= 0) {
      conversations[existingIndex] = conversation;
      debugPrint('Updated existing conversation ${conversation.id}');
    } else {
      conversations.add(conversation);
      debugPrint('Added new conversation ${conversation.id}');
    }

    final jsonData = conversations.map((c) => c.toJson()).toList();
    final jsonString = json.encode(jsonData);

    // Validate the JSON before saving
    try {
      final decoded = json.decode(jsonString) as List;
      debugPrint('JSON validation passed: ${decoded.length} conversations');
    } catch (e) {
      debugPrint('JSON validation failed: $e');
    }

    await _storage.write(
      key: _conversationsKey,
      value: jsonString,
    );
    debugPrint('Saved ${conversations.length} conversations to storage');
  }

  Future<void> setCurrentConversation(String conversationId) async {
    await _storage.write(key: _currentConversationKey, value: conversationId);
  }

  Future<Conversation> createNewConversation(
      {String title = 'New Chat'}) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now();

    final conversation = Conversation(
      id: id,
      title: title,
      messages: [],
      createdAt: now,
      updatedAt: now,
    );

    debugPrint('Creating new conversation $id');
    await saveConversation(conversation);
    await setCurrentConversation(id);
    debugPrint('Created and saved new conversation $id');
    return conversation;
  }

  Future<void> updateConversationMessages(
      String conversationId, List<Map<String, String>> messages) async {
    debugPrint(
        'Updating conversation $conversationId with ${messages.length} messages');
    final conversations = await getConversations();
    final index = conversations.indexWhere((c) => c.id == conversationId);

    if (index >= 0) {
      final conversation = conversations[index];
      final updatedConversation = conversation.copyWith(
        messages: messages,
        updatedAt: DateTime.now(),
        title: _generateTitle(messages),
      );

      conversations[index] = updatedConversation;
      await _storage.write(
        key: _conversationsKey,
        value: json.encode(conversations.map((c) => c.toJson()).toList()),
      );
      debugPrint('Successfully updated conversation $conversationId');
    } else {
      debugPrint(
          'Conversation $conversationId not found in storage, creating it');
      // If conversation doesn't exist, create it
      final now = DateTime.now();
      final newConversation = Conversation(
        id: conversationId,
        title: _generateTitle(messages),
        messages: messages,
        createdAt: now,
        updatedAt: now,
      );
      await saveConversation(newConversation);
    }
  }

  Future<void> deleteConversation(String conversationId) async {
    final conversations = await getConversations();
    conversations.removeWhere((c) => c.id == conversationId);

    await _storage.write(
      key: _conversationsKey,
      value: json.encode(conversations.map((c) => c.toJson()).toList()),
    );

    final currentId = await _storage.read(key: _currentConversationKey);
    if (currentId == conversationId) {
      await _storage.delete(key: _currentConversationKey);
    }
  }

  String _generateTitle(List<Map<String, String>> messages) {
    final userMessages = messages.where((m) => m['role'] == 'user');
    if (userMessages.isEmpty) return 'New Chat';

    final firstMessage = userMessages.first['text'] ?? '';
    if (firstMessage.length <= 30) return firstMessage;

    return '${firstMessage.substring(0, 30)}...';
  }

  String formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return DateFormat('HH:mm').format(date);
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return DateFormat('EEEE').format(date);
    } else {
      return DateFormat('MMM d').format(date);
    }
  }
}
