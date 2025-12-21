import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'services/whisper_service.dart';
import 'services/kokoro_tts_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterGemma.initialize();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Chatbot',
      theme: ThemeData(
        primarySwatch: Colors.blue,
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
  final bool _isLoading = false;
  InferenceModel? _inferenceModel;
  InferenceChat? _chat;
  bool _isRecording = false;
  bool _isTranscribing = false;
  final WhisperService _whisperService = WhisperService.instance;
  final KokoroTtsService _kokoroService = KokoroTtsService();

  @override
  void initState() {
    super.initState();
    initializeChat();
    // Initialize services in background
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _whisperService.initialize();
      _kokoroService.initialize();
    });
  }

  Future<void> initializeChat() async {
    try {
      debugPrint('Starting model initialization...');

      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromBundled('Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task')
          .install();

      debugPrint('Model installation completed');

      _inferenceModel = await FlutterGemma.getActiveModel(maxTokens: 2048);
      debugPrint('Active model retrieved: ${_inferenceModel != null}');

      _chat = await _inferenceModel!.createChat();
      debugPrint('Chat session created: ${_chat != null}');
    } catch (e) {
      debugPrint('Error initializing chat: $e');
    }
  }

  Future<void> _sendMessage(String text) async {
    if (text.isEmpty) return;

    setState(() {
      _messages.add({'role': 'user', 'text': text});
    });
    _textController.clear();

    String response = await _getAIResponse(text);

    setState(() {
      _messages.add({'role': 'ai', 'text': response});
    });

    try {
      await _kokoroService.speak(response);
    } catch (e) {
      debugPrint('TTS Error: $e');
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final audioPath = await _whisperService.stopRecording();
      if (audioPath != null) {
        setState(() {
          _isRecording = false;
          _isTranscribing = true;
        });

        try {
          final transcription =
              await _whisperService.transcribeFromFile(audioPath);
          if (transcription.isNotEmpty) {
            await _sendMessage(transcription);
          } else {
            _showErrorSnackBar(
                '🎤 No speech detected. Please speak clearly and try again.');
          }
        } catch (e) {
          _showErrorSnackBar('⚠️ Transcription failed: $e');
        } finally {
          setState(() {
            _isTranscribing = false;
          });
        }
      }
    } else {
      try {
        await _whisperService.startRecording();
        setState(() {
          _isRecording = true;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('🎤 Recording... Speak now!')),
          );
        }
      } catch (e) {
        _showErrorSnackBar('⚠️ Failed to start recording: $e');
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<String> _getAIResponse(String input) async {
    if (_chat == null) {
      return 'Model not initialized. Please wait...';
    }

    try {
      final userMessage = Message(text: input, isUser: true);
      await _chat!.addQuery(userMessage);
      final response = await _chat!.generateChatResponse();
      if (response is TextResponse) {
        return response.token;
      } else {
        return 'Function call response';
      }
    } catch (e) {
      return 'Error: $e';
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _whisperService.dispose();
    _kokoroService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isTranscribing ? '🔍 Transcribing...' : '🤖 AI Chatbot'),
        backgroundColor: _isTranscribing ? Colors.orange[100] : null,
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                return ListTile(
                  title: Text(
                    message['role'] == 'user' ? 'You' : 'AI',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: message['role'] == 'user'
                          ? Colors.blue
                          : Colors.green,
                    ),
                  ),
                  subtitle: Text(message['text']!),
                );
              },
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: Colors.grey[100],
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withValues(alpha: 0.3),
                  spreadRadius: 1,
                  blurRadius: 3,
                  offset: const Offset(0, -1),
                ),
              ],
            ),
            child: Row(
              children: [
                IconButton(
                  icon: _isTranscribing
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          _isRecording ? Icons.stop : Icons.mic,
                          color: _isRecording ? Colors.red : Colors.blue,
                        ),
                  onPressed: _isTranscribing ? null : _toggleRecording,
                ),
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message or tap microphone...',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    ),
                    onSubmitted: _sendMessage,
                    enabled: !_isTranscribing,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _isTranscribing
                      ? null
                      : () => _sendMessage(_textController.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
