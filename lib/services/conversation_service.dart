import 'dart:convert';
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
    return Conversation(
      id: json['id'],
      title: json['title'],
      messages: List<Map<String, String>>.from(json['messages']),
      createdAt: DateTime.parse(json['createdAt']),
      updatedAt: DateTime.parse(json['updatedAt']),
    );
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
      if (conversationsJson == null) return [];

      final List<dynamic> jsonList = json.decode(conversationsJson);
      return jsonList.map((json) => Conversation.fromJson(json)).toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (e) {
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
    final conversations = await getConversations();

    final existingIndex =
        conversations.indexWhere((c) => c.id == conversation.id);
    if (existingIndex >= 0) {
      conversations[existingIndex] = conversation;
    } else {
      conversations.add(conversation);
    }

    await _storage.write(
      key: _conversationsKey,
      value: json.encode(conversations.map((c) => c.toJson()).toList()),
    );
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

    await saveConversation(conversation);
    await setCurrentConversation(id);
    return conversation;
  }

  Future<void> updateConversationMessages(
      String conversationId, List<Map<String, String>> messages) async {
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
