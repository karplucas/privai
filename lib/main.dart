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
      title: 'PrivAI',
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
  final ScrollController _scrollController = ScrollController();
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _whisperService.initialize();
        debugPrint('Whisper initialized successfully');
      } catch (e) {
        debugPrint('Whisper initialization failed: $e');
      }
      try {
        await _kokoroService.initialize();
        debugPrint('Kokoro initialized successfully');
      } catch (e) {
        debugPrint('Kokoro initialization failed: $e');
      }
    });
  }

  Future<void> initializeChat() async {
    try {
      debugPrint('Starting model initialization...');

      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromBundled('Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task')
          // .fromBundled('gemma-3n-E2B-it-int4.task')
          .install();

      debugPrint('Model installation completed');

      _inferenceModel = await FlutterGemma.getActiveModel(maxTokens: 256);
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });

    String response = await _getAIResponse(text);

    if (mounted) {
      setState(() {
        _messages.add({'role': 'ai', 'text': response});
      });

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

    try {
      debugPrint('Speaking response: "$response"');
      await _kokoroService.speak(response);
      debugPrint('TTS completed');
    } catch (e) {
      debugPrint('TTS Error: $e');
    }
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final audioPath = await _whisperService.stopRecording();
      debugPrint('Audio path: $audioPath');
      if (audioPath != null) {
        setState(() {
          _isRecording = false;
          _messages.removeWhere((msg) =>
              msg['role'] == 'system' &&
              msg['text'] == '🎤 Recording... Speak now!');
          _isTranscribing = true;
          _messages.add({'role': 'system', 'text': '🔍 Transcribing...'});
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });

        try {
          debugPrint('Starting transcription for $audioPath');
          final transcription =
              await _whisperService.transcribeFromFile(audioPath);
          debugPrint('Transcription result: "$transcription"');
          if (transcription.isNotEmpty) {
            if (mounted) {
              await _sendMessage(transcription);
            }
          } else {
            _showErrorSnackBar(
                '🎤 No speech detected. Please speak clearly and try again.');
          }
        } catch (e) {
          _showErrorSnackBar('⚠️ Transcription failed: $e');
        } finally {
          if (mounted) {
            setState(() {
              _isTranscribing = false;
              _messages.removeWhere((msg) =>
                  msg['role'] == 'system' &&
                  msg['text'] == '🔍 Transcribing...');
            });
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
        }
      }
    } else {
      try {
        await _whisperService.startRecording();
        setState(() {
          _isRecording = true;
          _messages
              .add({'role': 'system', 'text': '🎤 Recording... Speak now!'});
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
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
    _scrollController.dispose();
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
        title: const Text('🤖 PrivAI'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isUser = message['role'] == 'user';
                final isAi = message['role'] == 'ai';
                final isSystem = message['role'] == 'system';
                final isRecordingOrTranscribing = isSystem &&
                    (message['text'] == '🎤 Recording... Speak now!' ||
                        message['text'] == '🔍 Transcribing...');
                return Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Align(
                    alignment: isUser || (isSystem && isRecordingOrTranscribing)
                        ? Alignment.centerRight
                        : isAi
                            ? Alignment.centerLeft
                            : Alignment.center,
                    child: Container(
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.7),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isUser
                            ? Colors.blue
                            : isAi
                                ? Colors.grey[300]
                                : Colors.orange[100],
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: isRecordingOrTranscribing
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 12,
                                  height: 12,
                                  child: const CircularProgressIndicator(
                                      strokeWidth: 1.5),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    message['text']!,
                                    style: TextStyle(
                                      color:
                                          isUser ? Colors.white : Colors.black,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Text(
                              message['text']!,
                              style: TextStyle(
                                color: isUser ? Colors.white : Colors.black,
                              ),
                            ),
                    ),
                  ),
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
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: InputDecoration(
                      hintText: 'Ask PrivAI',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      suffixIcon: IconButton(
                        icon: _isTranscribing
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _isRecording ? Icons.stop : Icons.mic,
                                color: _isRecording ? Colors.red : Colors.blue,
                              ),
                        onPressed: _isTranscribing ? null : _toggleRecording,
                      ),
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
