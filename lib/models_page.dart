import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'dart:convert';

import 'package:privai/services/kokoro_tts_service.dart';

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
  String? _selectedSttFilename;
  late TextEditingController _promptController;
  late TextEditingController _llmTemperatureController;
  late TextEditingController _llmMaxTokensController;
  late TextEditingController _ttsSpeedController;
  late TextEditingController _ttsLanguageController;
  late TextEditingController _sttLanguageController;
  String? _selectedTtsVoice;
  String? _selectedTtsLanguage;
  String? _selectedSttLanguage;
  bool _ttsEnabled = true;
  bool _sttEnabled = true;
  List<Map<String, dynamic>> _ttsLanguages = [];
  List<Map<String, dynamic>> _sttLanguages = [];
  List<String> _availableVoices = [];

  @override
  void initState() {
    super.initState();
    _promptController = TextEditingController();
    _llmTemperatureController = TextEditingController();
    _llmMaxTokensController = TextEditingController();
    _ttsSpeedController = TextEditingController();
    _ttsLanguageController = TextEditingController();
    _sttLanguageController = TextEditingController();
    _loadToken();
    _loadSelectedLlm();
    _loadSelectedTts();
    _loadSelectedStt();
    _loadSelectedPrompt();
    _loadModels();
    _loadLlmParameters();
    _loadTtsParameters();
    _loadSttParameters();
    _loadTtsEnabled();
    _loadSttEnabled();
  }

  Future<void> _loadToken() async {
    // _token = await _storage.read(key: 'hf_token');
    _token = null;
    setState(() {});
  }

  Future<void> _loadSelectedLlm() async {
    _selectedLlmFilename = await _storage.read(key: 'selected_llm_model');
    // Set default if none selected
    if (_selectedLlmFilename == null || _selectedLlmFilename!.isEmpty) {
      _selectedLlmFilename = 'gemma-3n-E2B-it-int4.task';
      await _storage.write(
          key: 'selected_llm_model', value: _selectedLlmFilename);
    }
    setState(() {});
  }

  Future<void> _loadSelectedTts() async {
    _selectedTtsFilename = await _storage.read(key: 'selected_tts_model');
    setState(() {});
  }

  Future<void> _loadSelectedStt() async {
    _selectedSttFilename = await _storage.read(key: 'selected_stt_model');
    setState(() {});
  }

  Future<void> _loadSelectedPrompt() async {
    final prompt = await _storage.read(key: 'selected_prompt') ??
        'Try to keep your responses shorter, about 50 - 100 words.';
    _promptController.text = prompt;
    setState(() {});
  }

  Future<void> _loadTtsEnabled() async {
    final enabled = await _storage.read(key: 'tts_enabled');
    _ttsEnabled = enabled == 'true';
    setState(() {});
  }

  Future<void> _loadSttEnabled() async {
    final enabled = await _storage.read(key: 'stt_enabled');
    _sttEnabled = enabled == 'true';
    setState(() {});
  }

  Future<void> _saveTtsEnabled(bool enabled) async {
    await _storage.write(key: 'tts_enabled', value: enabled.toString());
    _ttsEnabled = enabled;
    setState(() {});
  }

  Future<void> _saveSttEnabled(bool enabled) async {
    await _storage.write(key: 'stt_enabled', value: enabled.toString());
    _sttEnabled = enabled;
    setState(() {});
  }

  Future<void> _loadLlmParameters() async {
    final temperature = await _storage.read(key: 'llm_temperature') ?? '0.7';
    final maxTokens = await _storage.read(key: 'llm_max_tokens') ?? '8192';
    _llmTemperatureController.text = temperature;
    _llmMaxTokensController.text = maxTokens;
  }

  Future<void> _loadTtsParameters() async {
    final speed = await _storage.read(key: 'tts_speed') ?? '1.0';
    String? voice = await _storage.read(key: 'tts_voice');
    final language = await _storage.read(key: 'tts_language') ?? 'en';
    _ttsSpeedController.text = speed;

    if (voice == null || !_availableVoices.contains(voice)) {
      voice = _availableVoices.isNotEmpty ? _availableVoices.first : null;
      if (voice != null) {
        await _storage.write(key: 'tts_voice', value: voice);
      }
    }
    _selectedTtsVoice = voice;
    _selectedTtsLanguage = language;
    _ttsLanguageController.text = language;
  }

  Future<void> _loadSttParameters() async {
    final language = await _storage.read(key: 'stt_language') ?? 'auto';
    _selectedSttLanguage = language;
    _sttLanguageController.text = language;
  }

  Future<void> _saveLlmParameters() async {
    await _storage.write(
        key: 'llm_temperature', value: _llmTemperatureController.text);
    await _storage.write(
        key: 'llm_max_tokens', value: _llmMaxTokensController.text);
  }

  Future<void> _saveTtsParameters() async {
    await _storage.write(key: 'tts_speed', value: _ttsSpeedController.text);
    if (_selectedTtsVoice != null) {
      await _storage.write(key: 'tts_voice', value: _selectedTtsVoice!);
    }
    if (_selectedTtsLanguage != null) {
      await _storage.write(key: 'tts_language', value: _selectedTtsLanguage!);
    }
  }

  Future<void> _saveSttParameters() async {
    await _storage.write(key: 'stt_language', value: _selectedSttLanguage!);
  }

  Future<void> _loadModels() async {
    try {
      final jsonString = await rootBundle.loadString('assets/models_list.json');
      final Map<String, dynamic> jsonMap = json.decode(jsonString);
      _availableVoices = await KokoroTtsService().getAvailableVoiceIds();
      setState(() {
        _modelCategories = jsonMap.map((key, value) =>
            MapEntry(key, (value as List).cast<Map<String, dynamic>>()));
        _ttsLanguages =
            (jsonMap['tts_languages'] as List).cast<Map<String, dynamic>>();
        _sttLanguages =
            (jsonMap['stt_languages'] as List).cast<Map<String, dynamic>>();
      });
    } catch (e) {
      // Handle error, perhaps show snackbar
    }
  }

  Future<void> _loginWithHF() async {
    // TODO: Replace with actual client_id from HF app registration - create app at https://huggingface.co/oauth/apps
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
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Logged in successfully')),
            );
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Failed to get token')),
              );
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Login failed: $e')),
        );
      }
    }
  }

  Future<String?> _exchangeCodeForToken(String code) async {
    // TODO: Replace with actual client_id and client_secret from HF app - create app at https://huggingface.co/oauth/apps
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
        final dir = Directory(
            '/storage/emulated/0/Android/data/com.LucasKarpinski.privai/files');
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

  Future<void> _selectLlmModel(String filename) async {
    await _storage.write(key: 'selected_llm_model', value: filename);
    setState(() {
      _selectedLlmFilename = filename;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('LLM model selected: $filename')),
      );
    }
  }

  Future<void> _selectTtsModel(String filename) async {
    await _storage.write(key: 'selected_tts_model', value: filename);
    setState(() {
      _selectedTtsFilename = filename;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('TTS model selected: $filename')),
      );
    }
  }

  Future<void> _selectSttModel(String filename) async {
    await _storage.write(key: 'selected_stt_model', value: filename);
    setState(() {
      _selectedSttFilename = filename;
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('STT model selected: $filename')),
      );
    }
  }

  Widget _buildModelSection(
      String sectionTitle, List<Map<String, dynamic>> models) {
    if (models.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            sectionTitle,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        ...models.map((model) {
          final filename = model['filename'] as String;
          final isSelected = (sectionTitle == 'LLM Models' &&
                  _selectedLlmFilename == filename) ||
              (sectionTitle == 'TTS Models' &&
                  _selectedTtsFilename == filename) ||
              (sectionTitle == 'STT Models' &&
                  _selectedSttFilename == filename);

          return ListTile(
            leading: Icon(
              sectionTitle == 'LLM Models'
                  ? Icons.psychology
                  : sectionTitle == 'TTS Models'
                      ? Icons.record_voice_over
                      : Icons.mic,
              color: isSelected ? Theme.of(context).primaryColor : null,
            ),
            title: Text(model['name'] as String),
            subtitle: Text(
              '${model['size'] as String} • ${model['description'] as String}',
              style: const TextStyle(fontSize: 12),
            ),
            trailing: isSelected
                ? Icon(Icons.check_circle,
                    color: Theme.of(context).primaryColor)
                : _isDownloading
                    ? const CircularProgressIndicator()
                    : ElevatedButton(
                        onPressed: () =>
                            _downloadModel(model['url'] as String, filename),
                        child: const Text('Download'),
                      ),
            onTap: () {
              if (sectionTitle == 'LLM Models') {
                _selectLlmModel(filename);
              } else if (sectionTitle == 'TTS Models') {
                _selectTtsModel(filename);
              } else if (sectionTitle == 'STT Models') {
                _selectSttModel(filename);
              }
            },
            selected: isSelected,
          );
        }),
        const Divider(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // LLM Parameters Section
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('LLM Parameters',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _promptController,
                    decoration: const InputDecoration(
                      labelText: 'Initial Prompt',
                      hintText: 'Enter the initial system prompt for the LLM',
                      border: OutlineInputBorder(),
                    ),
                    maxLines: 3,
                    onChanged: (value) {
                      _storage.write(key: 'selected_prompt', value: value);
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _llmTemperatureController,
                    decoration: const InputDecoration(
                      labelText: 'Temperature (0.0-1.0)',
                      hintText: 'Controls randomness (lower = more focused)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) => _saveLlmParameters(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _llmMaxTokensController,
                    decoration: const InputDecoration(
                      labelText: 'Max Context Tokens',
                      hintText: 'Maximum context window size',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) => _saveLlmParameters(),
                  ),
                ],
              ),
            ),
            // Voice Settings
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Voice Settings',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text('Text-to-Speech (TTS)'),
                    subtitle: const Text('Enable AI voice responses'),
                    value: _ttsEnabled,
                    onChanged: (value) => _saveTtsEnabled(value),
                    contentPadding: EdgeInsets.zero,
                  ),
                  SwitchListTile(
                    title: const Text('Speech-to-Text (STT)'),
                    subtitle: const Text('Enable voice input recording'),
                    value: _sttEnabled,
                    onChanged: (value) => _saveSttEnabled(value),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
            // TTS Parameters Section
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('TTS Parameters',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedTtsLanguage,
                    decoration: const InputDecoration(
                      labelText: 'TTS Language',
                      border: OutlineInputBorder(),
                    ),
                    items: _ttsLanguages
                        .map((lang) => DropdownMenuItem<String>(
                              value: lang['code'] as String,
                              child: Text((lang['name'] as String?) ??
                                  (lang['code'] as String).toUpperCase()),
                            ))
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedTtsLanguage = value;
                        // Reset voice selection when language changes
                        if (_availableVoices.isNotEmpty) {
                          _selectedTtsVoice = _availableVoices.first;
                        } else {
                          _selectedTtsVoice = null;
                        }
                      });
                      _saveTtsParameters();
                    },
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedTtsVoice,
                    decoration: const InputDecoration(
                      labelText: 'Voice ID',
                      border: OutlineInputBorder(),
                    ),
                    items: _availableVoices
                        .map((voiceId) => DropdownMenuItem<String>(
                              value: voiceId,
                              child: Text(voiceId),
                            ))
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedTtsVoice = value;
                      });
                      _saveTtsParameters();
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _ttsSpeedController,
                    decoration: const InputDecoration(
                      labelText: 'Speech Speed (0.5-2.0)',
                      hintText: 'Controls speaking rate (1.0 = normal)',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) => _saveTtsParameters(),
                  ),
                ],
              ),
            ),
            // STT Parameters Section
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('STT Parameters',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedSttLanguage,
                    decoration: const InputDecoration(
                      labelText: 'STT Language',
                      border: OutlineInputBorder(),
                    ),
                    items: _sttLanguages
                        .map((lang) => DropdownMenuItem<String>(
                              value: lang['code'] as String,
                              child: Text((lang['name'] as String?) ??
                                  (lang['code'] as String).toUpperCase()),
                            ))
                        .toList(),
                    onChanged: (value) {
                      setState(() {
                        _selectedSttLanguage = value;
                      });
                      _saveSttParameters();
                    },
                  ),
                ],
              ),
            ),
            // Model Selection Section
            if (_token != null) ...[
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('Model Downloads',
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              _buildModelSection('LLM Models', _modelCategories['llm'] ?? []),
              _buildModelSection('TTS Models', _modelCategories['tts'] ?? []),
              _buildModelSection('STT Models', _modelCategories['stt'] ?? []),
            ] else
              Padding(
                padding: const EdgeInsets.all(32.0),
                child: Center(
                  child: ElevatedButton(
                    onPressed: _loginWithHF,
                    child: const Text('Login with Hugging Face'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
