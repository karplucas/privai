import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/whisper_service.dart';
import 'services/kokoro_tts_service.dart';
import 'services/conversation_service.dart';
import 'models_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the plugin structure
  await FlutterGemma.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PrivAI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  InferenceModel? _inferenceModel;
  InferenceChat? _chat;

  bool _isRecording = false;
  bool _isTranscribing = false;
  bool _isProcessing = false;
  bool _isModelLoading = false;
  bool _ttsEnabled = true;
  bool _sttEnabled = true;
  Conversation? _currentConversation;

  final WhisperService _whisperService = WhisperService.instance;
  final KokoroTtsService _kokoroService = KokoroTtsService();
  final ConversationService _conversationService = ConversationService();

  @override
  void initState() {
    super.initState();
    // Load settings and start initialization
    _loadSettings();
    _startFullInitialization();
  }

  Future<void> _startFullInitialization() async {
    await initializeChat();
    await _loadConversation();

    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Initialize Whisper (if enabled)
    if (_sttEnabled) {
      try {
        debugPrint('Initializing Whisper...');
        await _whisperService.initialize();
        debugPrint('Whisper ready.');
      } catch (e) {
        debugPrint('Whisper init failed: $e');
      }
    }

    // 4. Initialize Kokoro (if enabled)
    if (_ttsEnabled) {
      try {
        debugPrint('Initializing Kokoro...');
        await _kokoroService.initialize();
        debugPrint('Kokoro ready.');
      } catch (e) {
        debugPrint('Kokoro init failed: $e');
      }
    }
  }

  Future<String?> _getSelectedLlmFilename() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: 'selected_llm_model');
  }

  Future<String> _getSelectedPrompt() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: 'selected_prompt') ??
        'Try to keep your responses shorter, under 100 words.';
  }

  Future<void> _loadSettings() async {
    const storage = FlutterSecureStorage();
    final tts = await storage.read(key: 'tts_enabled');
    final stt = await storage.read(key: 'stt_enabled');

    setState(() {
      _ttsEnabled = tts == 'true';
      _sttEnabled = stt == 'true';
    });
  }

  Future<void> _loadConversation() async {
    debugPrint('Loading current conversation...');
    _currentConversation = await _conversationService.getCurrentConversation();

    if (_currentConversation != null) {
      debugPrint(
          'Loaded conversation ${_currentConversation!.id} with ${_currentConversation!.messages.length} messages');
      setState(() {
        _messages.clear();
        _messages.addAll(_currentConversation!.messages);
      });
    } else {
      // Create a new conversation if none exists
      debugPrint('No current conversation, creating new one');
      _currentConversation = await _conversationService.createNewConversation();
    }
  }

  Future<void> _saveCurrentConversation() async {
    if (_currentConversation != null) {
      debugPrint(
          'Saving conversation ${_currentConversation!.id} with ${_messages.length} messages');
      await _conversationService.updateConversationMessages(
        _currentConversation!.id,
        _messages,
      );
      _currentConversation = _currentConversation!.copyWith(
        messages: List.from(_messages),
        updatedAt: DateTime.now(),
      );
    } else {
      debugPrint('No current conversation to save');
    }
  }

  Future<void> _startNewConversation() async {
    // Save current conversation if it has messages
    if (_currentConversation != null && _messages.isNotEmpty) {
      await _saveCurrentConversation();
    }

    // Create new conversation
    _currentConversation = await _conversationService.createNewConversation();

    // Clear messages and reset chat
    _chat = await _inferenceModel?.createChat();
    if (_chat != null) {
      final prompt = await _getSelectedPrompt();
      final systemMessage = Message(text: prompt, isUser: false);
      await _chat!.addQueryChunk(systemMessage);
    }

    setState(() {
      _messages.clear();
    });
  }

  Future<void> _loadConversationById(String conversationId) async {
    // Save current conversation if it has messages
    if (_currentConversation != null && _messages.isNotEmpty) {
      await _saveCurrentConversation();
    }

    // Load the selected conversation
    final conversations = await _conversationService.getConversations();
    _currentConversation =
        conversations.firstWhere((c) => c.id == conversationId);

    // Set as current
    await _conversationService.setCurrentConversation(conversationId);

    // Reset chat and load messages
    _chat = await _inferenceModel?.createChat();
    if (_chat != null) {
      final prompt = await _getSelectedPrompt();
      final systemMessage = Message(text: prompt, isUser: false);
      await _chat!.addQueryChunk(systemMessage);

      // Add existing messages to chat context
      for (final message in _currentConversation!.messages) {
        final isUser = message['role'] == 'user';
        final msg = Message(text: message['text']!, isUser: isUser);
        await _chat!.addQueryChunk(msg);
      }
    }

    setState(() {
      _messages.clear();
      _messages.addAll(_currentConversation!.messages);
    });
  }

  /// Sets up the Gemma model with a 4096 context window
  Future<void> initializeChat() async {
    if (_isModelLoading) return;
    setState(() => _isModelLoading = true);

    try {
      debugPrint('Starting model initialization...');
      final selectedFilename =
          await _getSelectedLlmFilename() ?? 'gemma-3n-E2B-it-int4.task';

      // Standard app-specific directory for model files
      final dir =
          Directory('/sdcard/Android/data/com.LucasKarpinski.privai/files');
      if (!await dir.exists()) await dir.create(recursive: true);

      final modelPath = '${dir.path}/$selectedFilename';
      final file = File(modelPath);

      if (await file.exists()) {
        // 1. Install model into the native Gemma engine
        await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
            .fromFile(modelPath)
            .install();

        // 2. Load model with 4096 tokens (increased from 512 to prevent frequent crashes)
        _inferenceModel = await FlutterGemma.getActiveModel(maxTokens: 4096);

        if (_inferenceModel != null) {
          // 3. Create a single persistent chat session
          _chat = await _inferenceModel!.createChat();

          // 4. Add initial system prompt
          final prompt = await _getSelectedPrompt();
          final systemMessage = Message(text: prompt, isUser: false);
          await _chat!.addQueryChunk(systemMessage);

          debugPrint('Gemma ready. Context: 4096 tokens.');
        }
      } else {
        _showErrorSnackBar('Model not found. Please download it in Settings.');
      }
    } catch (e) {
      debugPrint('Initialization Error: $e');
    } finally {
      if (mounted) setState(() => _isModelLoading = false);
    }
  }

  /// Handles sending the message and getting AI response
  Future<void> _sendMessage(String text) async {
    if (text.trim().isEmpty || _isProcessing || _chat == null) return;

    final userText = text.trim();
    _textController.clear();

    setState(() {
      _messages.add({'role': 'user', 'text': userText});
      _isProcessing = true;
    });
    _scrollToBottom();

    String response = await _getAIResponse(userText);

    if (mounted) {
      setState(() {
        _messages.add({'role': 'ai', 'text': response});
        _isProcessing = false;
      });
      _scrollToBottom();

      // Play TTS if enabled
      if (_ttsEnabled && response.isNotEmpty) {
        try {
          await _kokoroService.speak(response);
        } catch (e) {
          debugPrint('TTS failed: $e');
        }
      }

      // Save conversation after each exchange
      await _saveCurrentConversation();
    }
  }

  /// Core inference logic with crash-protection for context overflow
  Future<String> _getAIResponse(String input) async {
    try {
      final userMessage = Message(text: input, isUser: true);

      // Send to native engine
      await _chat!.addQueryChunk(userMessage);
      final response = await _chat!.generateChatResponse();

      if (response is TextResponse) {
        return response.token;
      }
      return 'I encountered an unexpected response format.';
    } catch (e) {
      debugPrint('Inference Error (Likely Context Full): $e');

      // CRITICAL: If the native engine throws an OUT_OF_RANGE error,
      // we must reset the chat session or the app will abort.
      _chat = await _inferenceModel?.createChat();

      return '⚠️ My memory limit was reached, so I had to clear our history. What were we talking about?';
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final audioPath = await _whisperService.stopRecording();
      if (audioPath != null) {
        setState(() {
          _isRecording = false;
          _isTranscribing = true;
          _messages.add({'role': 'system', 'text': '🔍 Transcribing...'});
        });
        _scrollToBottom();

        try {
          final transcription =
              await _whisperService.transcribeFromFile(audioPath);
          if (mounted) {
            setState(() =>
                _messages.removeLast()); // Remove transcription placeholder
            if (transcription.isNotEmpty) {
              await _sendMessage(transcription);
            }
          }
        } catch (e) {
          _showErrorSnackBar('Transcription failed: $e');
        } finally {
          if (mounted) setState(() => _isTranscribing = false);
        }
      }
    } else {
      try {
        await _whisperService.startRecording();
        setState(() => _isRecording = true);
      } catch (e) {
        _showErrorSnackBar('Check microphone permissions.');
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _saveCurrentConversation(); // Save before disposing
    _textController.dispose();
    _scrollController.dispose();
    _whisperService.dispose();
    _kokoroService.dispose();

    // Release native resources
    _chat = null;
    _inferenceModel = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🤖 PrivAI'),
        centerTitle: true,
        elevation: 2,
      ),
      drawer: Drawer(
        child: Column(
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text('PrivAI',
                  style: TextStyle(color: Colors.white, fontSize: 24)),
            ),
            ListTile(
              leading: const Icon(Icons.chat),
              title: const Text('New Chat'),
              onTap: () async {
                await _startNewConversation();
                Navigator.pop(context);
              },
            ),
            const Divider(),
            Expanded(
              child: FutureBuilder<List<Conversation>>(
                future: _conversationService.getConversations(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  final conversations = snapshot.data ?? [];

                  if (conversations.isEmpty) {
                    return const Center(
                      child: Text('No conversations yet'),
                    );
                  }

                  return ListView.builder(
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      final isCurrent =
                          _currentConversation?.id == conversation.id;

                      return ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(
                          conversation.title,
                          style: TextStyle(
                            fontWeight:
                                isCurrent ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          _conversationService
                              .formatDate(conversation.updatedAt),
                        ),
                        trailing: isCurrent
                            ? const Icon(Icons.check, color: Colors.blue)
                            : IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final shouldDelete = await showDialog<bool>(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: const Text('Delete Conversation'),
                                      content: const Text(
                                          'Are you sure you want to delete this conversation?'),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('Cancel'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('Delete'),
                                        ),
                                      ],
                                    ),
                                  );

                                  if (shouldDelete == true) {
                                    await _conversationService
                                        .deleteConversation(conversation.id);

                                    // If deleted conversation was current, start new one
                                    if (_currentConversation?.id ==
                                        conversation.id) {
                                      await _startNewConversation();
                                    }

                                    setState(() {}); // Refresh drawer
                                  }
                                },
                              ),
                        onTap: () async {
                          await _loadConversationById(conversation.id);
                          Navigator.pop(context);
                        },
                        selected: isCurrent,
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Manage Models'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => const ModelsPage()));
              },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_isModelLoading) const LinearProgressIndicator(),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.all(10),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isUser = message['role'] == 'user';
                final isSystem = message['role'] == 'system';

                return Align(
                  alignment: isUser
                      ? Alignment.centerRight
                      : (isSystem ? Alignment.center : Alignment.centerLeft),
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: isUser
                          ? Colors.blue[600]
                          : (isSystem ? Colors.amber[100] : Colors.grey[200]),
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(15),
                        topRight: const Radius.circular(15),
                        bottomLeft:
                            isUser ? const Radius.circular(15) : Radius.zero,
                        bottomRight:
                            isUser ? Radius.zero : const Radius.circular(15),
                      ),
                    ),
                    child: Text(
                      message['text']!,
                      style: TextStyle(
                          color: isUser ? Colors.white : Colors.black87),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_isProcessing)
            const Padding(
              padding: EdgeInsets.all(8.0),
              child: Text("PrivAI is thinking...",
                  style: TextStyle(
                      fontStyle: FontStyle.italic, color: Colors.grey)),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    enabled: !_isProcessing && !_isTranscribing,
                    // RESTORES ENTER KEY FUNCTIONALITY
                    textInputAction: TextInputAction.send,
                    onSubmitted: (val) => _sendMessage(val),
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      filled: true,
                      fillColor: Colors.grey[100],
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(25),
                          borderSide: BorderSide.none),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 20),
                      suffixIcon: _sttEnabled
                          ? IconButton(
                              icon: Icon(_isRecording ? Icons.stop : Icons.mic,
                                  color:
                                      _isRecording ? Colors.red : Colors.blue),
                              onPressed:
                                  _isTranscribing ? null : _toggleRecording,
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CircleAvatar(
                  backgroundColor: Colors.blue,
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white),
                    onPressed: (_isProcessing || _isTranscribing)
                        ? null
                        : () => _sendMessage(_textController.text),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
