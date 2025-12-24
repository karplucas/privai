import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'services/whisper_service.dart';
import 'services/kokoro_tts_service.dart';
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

  final WhisperService _whisperService = WhisperService.instance;
  final KokoroTtsService _kokoroService = KokoroTtsService();

  @override
  void initState() {
    super.initState();
    // Start the chain reaction of initialization
    _startFullInitialization();
  }

  Future<void> _startFullInitialization() async {
    await initializeChat();

    await Future.delayed(const Duration(milliseconds: 500));

    // 3. Initialize Whisper
    try {
      debugPrint('Initializing Whisper...');
      await _whisperService.initialize();
      debugPrint('Whisper ready.');
    } catch (e) {
      debugPrint('Whisper init failed: $e');
    }

    // 4. Initialize Kokoro
    try {
      debugPrint('Initializing Kokoro...');
      await _kokoroService.initialize();
      debugPrint('Kokoro ready.');
    } catch (e) {
      debugPrint('Kokoro init failed: $e');
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
        child: ListView(
          padding: EdgeInsets.zero,
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
                _chat = await _inferenceModel?.createChat();
                if (_chat != null) {
                  final prompt = await _getSelectedPrompt();
                  final systemMessage = Message(text: prompt, isUser: false);
                  await _chat!.addQueryChunk(systemMessage);
                }
                setState(() => _messages.clear());
                Navigator.pop(context);
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
                      suffixIcon: IconButton(
                        icon: Icon(_isRecording ? Icons.stop : Icons.mic,
                            color: _isRecording ? Colors.red : Colors.blue),
                        onPressed: _isTranscribing ? null : _toggleRecording,
                      ),
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
