import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:whisper_ggml/whisper_ggml.dart';
import 'dart:convert';
import 'dart:io';

class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  String? _token;
  bool _isDownloading = false;
  Map<String, List<Map<String, dynamic>>> _modelCategories = {};
  String? _selectedLlmFilename;
  String? _selectedTtsFilename;
  late TextEditingController _promptController;

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _loadToken();
    _loadSelectedLlm();
    _loadSelectedTts();
    _loadSelectedPrompt();
    _loadModels();
  }

  Future<void> _loadToken() async {
    // _token = await _storage.read(key: 'hf_token');
    _token = null;
    setState(() {});
  }

  Future<void> _loadSelectedLlm() async {
    _selectedLlmFilename = await _storage.read(key: 'selected_llm_model');
    setState(() {});
  }

  Future<void> _loadSelectedTts() async {
    _selectedTtsFilename = await _storage.read(key: 'selected_tts_model');
    setState(() {});
  }

  Future<void> _loadSelectedPrompt() async {
    final prompt = await _storage.read(key: 'selected_prompt') ??
        'Try to keep your responses shorter, about 50 - 100 words.';
    _promptController.text = prompt;
    setState(() {});
  }

  Future<void> _loadModels() async {
    try {
      final jsonString = await rootBundle.loadString('assets/models_list.json');
      final Map<String, dynamic> jsonMap = json.decode(jsonString);
      setState(() {
        _modelCategories = jsonMap.map((key, value) =>
            MapEntry(key, (value as List).cast<Map<String, dynamic>>()));
      });
    } catch (e) {
      // Handle error, perhaps show snackbar
    }
  }

  Future<void> _loginWithHF() async {
    // TODO: Replace with actual client_id from HF app registration
    const clientId = 'your_client_id_here';
    const redirectUri = 'app://callback';
    final url = Uri.parse(
        'https://huggingface.co/oauth/authorize?client_id=$clientId&redirect_uri=$redirectUri&response_type=code&scope=read');

    try {
      final result = await FlutterWebAuth2.authenticate(
          url: url.toString(), callbackUrlScheme: 'app');
      final uri = Uri.parse(result);
      final code = uri.queryParameters['code'];
      if (code != null) {
        final token = await _exchangeCodeForToken(code);
        if (token != null) {
          // await _storage.write(key: 'hf_token', value: token);
          setState(() {
            _token = token;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Logged in successfully')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to get token')),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Login failed: $e')),
      );
    }
  }

  Future<String?> _exchangeCodeForToken(String code) async {
    // TODO: Replace with actual client_id and client_secret from HF app
    const clientId = 'your_client_id_here';
    const clientSecret = 'your_client_secret_here';
    const redirectUri = 'app://callback';

    final response = await http.post(
      Uri.parse('https://huggingface.co/oauth/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'client_secret': clientSecret,
        'code': code,
        'redirect_uri': redirectUri,
      },
    );

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return data['access_token'];
    }
    return null;
  }

  Future<void> _downloadModel(String modelUrl, String fileName) async {
    if (_token == null) return;

    setState(() {
      _isDownloading = true;
    });

    try {
      final response = await http.get(
        Uri.parse(modelUrl),
        headers: {'Authorization': 'Bearer $_token'},
      );

      if (response.statusCode == 200) {
        final dir =
            Directory('/sdcard/Android/data/com.LucasKarpinski.privai/files');
        final filePath = '${dir.path}/$fileName';
        final file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$fileName downloaded successfully')),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Download failed')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download error: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Models'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _promptController,
              decoration: const InputDecoration(
                labelText: 'Initial Prompt',
                hintText: 'Enter the initial system prompt for the LLM',
              ),
              maxLines: 3,
              onChanged: (value) {
                _storage.write(key: 'selected_prompt', value: value);
              },
            ),
          ),
          Expanded(
            child: _token == null
                ? Center(
                    child: ElevatedButton(
                      onPressed: _loginWithHF,
                      child: const Text('Login with Hugging Face'),
                    ),
                  )
                : _modelCategories.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        children: [],
                      ),
          ),
        ],
      ),
    );
  }
}
