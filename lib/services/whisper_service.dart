import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import 'package:record/record.dart';

class WhisperService {
  static WhisperService? _instance;
  final WhisperController _whisperController = WhisperController();
  final AudioRecorder _audioRecorder = AudioRecorder();

  late WhisperModel _activeModel;
  bool _isInitialized = false;
  bool _isInitializing = false;

  WhisperService._();

  static WhisperService get instance {
    _instance ??= WhisperService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_isInitialized || _isInitializing) return;
    _isInitializing = true;

    try {
      // 1. Get the filename you specified
      final selectedFilename =
          await _getSelectedModelFilename() ?? 'ggml-base-q5_1.bin';
      _activeModel = _getModelFromFilename(selectedFilename);

      // 2. Identify the Internal "Fast Path" for this model
      final pluginPath = await _whisperController.getPath(_activeModel);
      final pluginFile = File(pluginPath);

      // 3. Move the file from SD card to Internal if missing
      if (!await pluginFile.exists()) {
        final sdCardPath =
            '/sdcard/Android/data/com.LucasKarpinski.privai/files/$selectedFilename';
        final sdCardFile = File(sdCardPath);

        if (await sdCardFile.exists()) {
          debugPrint('⚡ Optimizing model storage for $selectedFilename...');
          await Directory(pluginFile.parent.path).create(recursive: true);

          // Using byte streams to safely transfer the large model
          final sink = pluginFile.openWrite();
          await sink.addStream(sdCardFile.openRead());
          await sink.close();

          debugPrint('✅ Model optimized in internal storage.');
        } else {
          debugPrint(
              '🌐 Model not found on SD card, calling plugin downloader.');
          await _whisperController.downloadModel(_activeModel);
        }
      }

      _isInitialized = true;
      debugPrint('🚀 Whisper Ready with $_activeModel');
    } catch (e) {
      debugPrint('❌ Whisper Initialization Error: $e');
    } finally {
      _isInitializing = false;
    }
  }

  Future<String?> _getSelectedModelFilename() async {
    const storage = FlutterSecureStorage();
    return await storage.read(key: 'selected_stt_model');
  }

  WhisperModel _getModelFromFilename(String filename) {
    final name = filename.toLowerCase();
    if (name.contains('tiny')) return WhisperModel.tiny;
    if (name.contains('base')) return WhisperModel.base;
    if (name.contains('small')) return WhisperModel.small;
    if (name.contains('medium')) return WhisperModel.medium;
    return WhisperModel.large;
  }

  Future<String> transcribeFromFile(String audioPath,
      {String? language}) async {
    if (!_isInitialized) await initialize();

    try {
      final file = File(audioPath);
      if (!await file.exists() || await file.length() < 100) {
        throw Exception("Audio file is missing or empty.");
      }

      debugPrint('🎙️ Transcribing: $audioPath');
      final result = await _whisperController.transcribe(
        model: _activeModel,
        audioPath: audioPath,
        lang: language ?? 'auto',
      );

      return result?.transcription.text.trim() ?? '';
    } catch (e) {
      debugPrint('❌ Transcription Error: $e');
      return "Transcription failed.";
    }
  }

  Future<String> startRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      throw Exception('Microphone permission not granted');
    }

    final Directory tempDir = await getTemporaryDirectory();
    final String path =
        '${tempDir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.wav';

    debugPrint('🎤 Recording 16kHz Mono...');
    // We use EXACT parameters required by Whisper to avoid conversion lag
    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 128000,
      ),
      path: path,
    );
    return path;
  }

  Future<String?> stopRecording() async {
    final path = await _audioRecorder.stop();
    if (path != null) {
      final file = File(path);

      // Give the OS time to finish writing the WAV header
      int waitCycles = 0;
      while (waitCycles < 10 &&
          (!await file.exists() || await file.length() < 1000)) {
        await Future.delayed(const Duration(milliseconds: 50));
        waitCycles++;
      }

      if (await file.exists() && await file.length() > 1000) {
        debugPrint('⏹️ Recording saved: ${await file.length()} bytes');
        return path;
      }
    }
    return null;
  }

  void dispose() {
    _audioRecorder.dispose();
  }
}
