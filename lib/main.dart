import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart'; // Correctly handles app-specific paths
import 'services/whisper_service.dart';
import 'services/kokoro_tts_service.dart';
import 'services/conversation_service.dart';
import 'models_page.dart';

enum LlmModel {
  gemma3_1b,
  gemma3n_e2b,
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the plugin structure
  await FlutterGemma.initialize();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
      ),
      themeMode: _themeMode,
      home: ChatScreen(themeToggleCallback: _toggleTheme),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final VoidCallback themeToggleCallback;

  const ChatScreen({super.key, required this.themeToggleCallback});

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

  // FIX: Improved permission handling for Android 11+
  Future<void> _requestStoragePermissions() async {
    try {
      if (Platform.isAndroid) {
        // Standard permissions for older Android versions
        await [
          Permission.storage,
          Permission.microphone,
          Permission.mediaLibrary,
        ].request();

        // For Android 11+ (API 30), we check Manage External Storage
        // though usually getExternalStorageDirectory() doesn't require this.
        if (await Permission.manageExternalStorage.isDenied) {
          debugPrint('Requesting Manage External Storage...');
          await Permission.manageExternalStorage.request();
        }
      }
    } catch (e) {
      debugPrint('Permission request failed: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _startFullInitialization();
  }

  Future<void> _startFullInitialization() async {
    await _requestStoragePermissions();
    await initializeChat();
    await _loadConversation();

    await Future.delayed(const Duration(milliseconds: 500));

    if (_sttEnabled) {
      try {
        debugPrint('Initializing Whisper...');
        await _whisperService.initialize();
      } catch (e) {
        debugPrint('Whisper init failed: $e');
      }
    }

    if (_ttsEnabled) {
      try {
        debugPrint('Initializing Kokoro...');
        await _kokoroService.initialize();
      } catch (e) {
        debugPrint('Kokoro init failed: $e');
      }
    }
  }

  // --- MODEL & SETTINGS HELPERS ---

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

  // --- CONVERSATION LOGIC ---

  Future<void> _loadConversation() async {
    _currentConversation = await _conversationService.getCurrentConversation();
    if (_currentConversation != null) {
      setState(() {
        _messages.clear();
        _messages.addAll(_currentConversation!.messages);
      });
    } else {
      _currentConversation = await _conversationService.createNewConversation();
    }
  }

  Future<void> _saveCurrentConversation() async {
    if (_currentConversation != null && _messages.isNotEmpty) {
      await _conversationService.updateConversationMessages(
        _currentConversation!.id,
        _messages,
      );
    }
  }

  Future<void> _startNewConversation() async {
    if (_currentConversation != null && _messages.isNotEmpty) {
      await _saveCurrentConversation();
    }
    _currentConversation = await _conversationService.createNewConversation();
    _chat = await _inferenceModel?.createChat();
    if (_chat != null) {
      final prompt = await _getSelectedPrompt();
      await _chat!.addQueryChunk(Message(text: prompt, isUser: false));
    }
    setState(() => _messages.clear());
  }

  Future<void> _loadConversationById(String conversationId) async {
    if (_currentConversation != null && _messages.isNotEmpty) {
      await _saveCurrentConversation();
    }
    final conversations = await _conversationService.getConversations();
    _currentConversation =
        conversations.firstWhere((c) => c.id == conversationId);
    await _conversationService.setCurrentConversation(conversationId);

    _chat = await _inferenceModel?.createChat();
    if (_chat != null) {
      final prompt = await _getSelectedPrompt();
      await _chat!.addQueryChunk(Message(text: prompt, isUser: false));
      for (final message in _currentConversation!.messages) {
        await _chat!.addQueryChunk(
            Message(text: message['text']!, isUser: message['role'] == 'user'));
      }
    }
    setState(() {
      _messages.clear();
      _messages.addAll(_currentConversation!.messages);
    });
  }

  // --- CORE FIX: INITIALIZATION ---

  /// Sets up the Gemma model using dynamic path resolution
  Future<void> initializeChat() async {
    if (_isModelLoading) return;
    setState(() => _isModelLoading = true);

    try {
      debugPrint('Starting LLM model initialization...');
      final selectedFilename =
          await _getSelectedLlmFilename() ?? 'gemma-3n-E2B-it-int4.task';

      // FIX: Instead of hardcoded /sdcard/, get the directory Android actually allows
      final directory = await getExternalStorageDirectory();

      if (directory == null) {
        _showErrorSnackBar('Storage directory not found.');
        return;
      }

      final modelPath = '${directory.path}/$selectedFilename';
      final file = File(modelPath);

      debugPrint('Targeting model path: $modelPath');

      if (await file.exists()) {
        // 1. Install model into the native Gemma engine
        await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
            .fromFile(modelPath)
            .install();

        // 2. Load model with 4096 tokens
        _inferenceModel = await FlutterGemma.getActiveModel(maxTokens: 4096);

        if (_inferenceModel != null) {
          _chat = await _inferenceModel!.createChat();
          final prompt = await _getSelectedPrompt();
          await _chat!.addQueryChunk(Message(text: prompt, isUser: false));
          debugPrint('Gemma ready.');
        }
      } else {
        _showErrorSnackBar('Model file missing. Check: ${file.path}');
      }
    } catch (e) {
      debugPrint('Initialization Error: $e');
      _showErrorSnackBar('Initialization Error: $e');
    } finally {
      if (mounted) setState(() => _isModelLoading = false);
    }
  }

  // --- MESSAGE HANDLING & INFERENCE ---

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

      if (_ttsEnabled && response.isNotEmpty) {
        try {
          await _kokoroService.speak(response);
        } catch (e) {
          debugPrint('TTS error: $e');
        }
      }
      await _saveCurrentConversation();
    }
  }

  Future<String> _getAIResponse(String input) async {
    try {
      await _chat!.addQueryChunk(Message(text: input, isUser: true));
      final response = await _chat!.generateChatResponse();

      if (response is TextResponse) return response.token;
      return 'Unexpected response format.';
    } catch (e) {
      debugPrint('Inference Error: $e');
      _chat = await _inferenceModel?.createChat();
      return '⚠️ Context limit reached. History cleared. What next?';
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
            setState(() => _messages.removeLast());
            if (transcription.isNotEmpty) await _sendMessage(transcription);
          }
        } catch (e) {
          _showErrorSnackBar('Transcription failed: $e');
        } finally {
          if (mounted) setState(() => _isTranscribing = false);
        }
      }
    } else {
      try {
        final status = await Permission.microphone.request();
        if (status.isGranted) {
          await _whisperService.startRecording();
          setState(() => _isRecording = true);
        } else {
          _showErrorSnackBar('Microphone permission required.');
          if (status.isPermanentlyDenied) await openAppSettings();
        }
      } catch (e) {
        _showErrorSnackBar('Recording failed: $e');
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _saveCurrentConversation();
    _textController.dispose();
    _scrollController.dispose();
    _whisperService.dispose();
    _kokoroService.dispose();
    _chat = null;
    _inferenceModel = null;
    super.dispose();
  }

  // --- UI BUILD ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(Theme.of(context).brightness == Brightness.dark
                ? Icons.light_mode
                : Icons.dark_mode),
            onPressed: widget.themeToggleCallback,
          ),
        ],
      ),
      drawer: Drawer(
        child: Column(
          children: [
            const SizedBox(height: 56),
            ListTile(
              leading: const Icon(Icons.chat),
              title: const Text('New Chat'),
              onTap: () async {
                await _startNewConversation();
                if (mounted) {
                  Navigator.pop(this.context);
                }
              },
            ),
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
            const Divider(),
            Expanded(
              child: FutureBuilder<List<Conversation>>(
                future: _conversationService.getConversations(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final conversations = snapshot.data!;
                  return ListView.builder(
                    itemCount: conversations.length,
                    itemBuilder: (context, index) {
                      final conversation = conversations[index];
                      final isCurrent =
                          _currentConversation?.id == conversation.id;
                      return ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(conversation.title,
                            style: TextStyle(
                                fontWeight: isCurrent
                                    ? FontWeight.bold
                                    : FontWeight.normal)),
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
                          if (mounted) {
                            Navigator.pop(this.context);
                          }
                        },
                        selected: isCurrent,
                      );
                    },
                  );
                },
              ),
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
                          ? Theme.of(context).brightness == Brightness.dark
                              ? Colors.grey[700]
                              : Colors.grey[300]
                          : (isSystem
                              ? Colors.grey[900]
                              : Theme.of(context).scaffoldBackgroundColor),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Text(message['text']!,
                        style: TextStyle(
                          color: isUser
                              ? Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white
                                  : Colors.black87
                              : Theme.of(context).brightness == Brightness.dark
                                  ? Colors.white70
                                  : Colors.black87,
                        )),
                  ),
                );
              },
            ),
          ),
          if (_isProcessing)
            const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text("Thinking...",
                    style: TextStyle(
                        fontStyle: FontStyle.italic, color: Colors.grey))),
          if (_isTranscribing)
            const Padding(
                padding: EdgeInsets.all(8.0),
                child: Text("Transcribing...",
                    style: TextStyle(
                        fontStyle: FontStyle.italic, color: Colors.grey))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: TextField(
              controller: _textController,
              enabled: !_isProcessing && !_isTranscribing,
              onSubmitted: (val) => _sendMessage(val),
              decoration: InputDecoration(
                hintText: 'Type a message...',
                filled: true,
                fillColor: Theme.of(context).brightness == Brightness.dark
                    ? Colors.grey[700]
                    : Colors.grey[300],
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(25),
                    borderSide: BorderSide.none),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_sttEnabled)
                      IconButton(
                        icon: Icon(_isRecording ? Icons.stop : Icons.mic,
                            color: _isRecording
                                ? Colors.red
                                : (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black)),
                        onPressed: _isTranscribing ? null : _toggleRecording,
                      ),
                    IconButton(
                      icon: Icon(Icons.send,
                          color: Theme.of(context).brightness == Brightness.dark
                              ? Colors.white
                              : Colors.black),
                      onPressed: (_isProcessing || _isTranscribing)
                          ? null
                          : () => _sendMessage(_textController.text),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
