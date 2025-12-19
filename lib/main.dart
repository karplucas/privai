import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';

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
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
  bool _isLoading = false;
  InferenceModel? _inferenceModel;
  InferenceChat? _chat;

  @override
  void initState() {
    super.initState();
    initializeChat();
  }

  Future<void> initializeChat() async {
    try {
      debugPrint('Starting model initialization...');

      // Use small file to test
      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromBundled('Gemma3-1B-IT_multi-prefill-seq_q4_ekv2048.task')
          .install();

      debugPrint('Model installation completed');

      // Get the active model
      _inferenceModel = await FlutterGemma.getActiveModel(maxTokens: 2048);
      debugPrint('Active model retrieved: ${_inferenceModel != null}');

      // Create a chat session from the loaded model
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
  }

  Future<String> _getAIResponse(String input) async {
    if (_chat == null) {
      return 'Model not initialized. Please wait...';
    }

    try {
      // Package the text into a Message object
      final userMessage = Message(text: input, isUser: true);

      // Send the user's message to the chat
      await _chat!.addQuery(userMessage);

      // Get the Gemma's response
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
        title: const Text('AI Chatbot'),
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
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: 'Type a message...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: _sendMessage,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () => _sendMessage(_textController.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
