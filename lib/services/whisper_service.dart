import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import 'package:record/record.dart';

class WhisperService {
  static WhisperService? _instance;
  final WhisperController _whisperController = WhisperController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isInitialized = false;
  bool _isInitializing = false;
  final WhisperModel _model = WhisperModel.tiny;
  String? _cachedModelPath;

  WhisperService._();

  static WhisperService get instance {
    _instance ??= WhisperService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_isInitialized || _isInitializing) return;

    _isInitializing = true;
    try {
      await _setupModel();
      _isInitialized = true;
    } catch (e) {
      _isInitializing = false;
      throw Exception('Failed to initialize Whisper: $e');
    } finally {
      _isInitializing = false;
    }
  }

  Future<void> _setupModel() async {
    try {
      final modelPathBase = await _whisperController.getPath(_model);
      final fileBase = File(modelPathBase);

      if (!await fileBase.exists()) {
        final ByteData bytesBase =
            await rootBundle.load('assets/models/ggml-tiny.bin');
        await fileBase.writeAsBytes(
          bytesBase.buffer
              .asUint8List(bytesBase.offsetInBytes, bytesBase.lengthInBytes),
        );
      }

      _cachedModelPath = modelPathBase;
      debugPrint('Whisper model setup complete at: $_cachedModelPath');
    } catch (e) {
      debugPrint('Model setup failed: $e');
      await _whisperController.downloadModel(_model);
      _cachedModelPath = await _whisperController.getPath(_model);
    }
  }

  Future<String> transcribeFromFile(String audioPath,
      {String? language}) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      // Validate audio file
      final audioFile = File(audioPath);
      if (!await audioFile.exists()) {
        throw Exception('Audio file not found: $audioPath');
      }

      final fileSize = await audioFile.length();
      if (fileSize < 1024) {
        throw Exception('Audio file too small ($fileSize bytes), may be empty');
      }

      debugPrint('=== TRANSCRIPTION START ===');
      debugPrint('Audio file: $audioPath');
      debugPrint('File size: $fileSize bytes');
      debugPrint('Language: ${language ?? "auto"}');

      final result = await _whisperController.transcribe(
        model: _model,
        audioPath: audioPath,
        lang: language ?? 'auto',
      );

      final transcription = result?.transcription.text ?? '';
      debugPrint('Raw transcription result: "$transcription"');

      if (transcription.trim().isEmpty) {
        debugPrint('❌ EMPTY TRANSCRIPTION');
        return '';
      }

      debugPrint('✅ SUCCESS: "$transcription"');
      return transcription.trim();
    } catch (e) {
      debugPrint('❌ TRANSCRIPTION ERROR: $e');
      throw Exception('Transcription failed: $e');
    }
  }

  Future<String> transcribeFromBytes(Uint8List audioBytes,
      {String? language}) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final Directory tempDir = Directory.systemTemp;
      final String tempPath = '${tempDir.path}/temp_audio.wav';
      final File tempFile = File(tempPath);
      await tempFile.writeAsBytes(audioBytes);

      final result = await transcribeFromFile(tempPath, language: language);

      await tempFile.delete();
      return result;
    } catch (e) {
      throw Exception('Transcription from bytes failed: $e');
    }
  }

  Future<bool> hasRecordingPermission() async {
    return await _audioRecorder.hasPermission();
  }

  Future<String> startRecording() async {
    if (!await _audioRecorder.hasPermission()) {
      throw Exception('Microphone permission not granted');
    }

    final Directory tempDir = await getTemporaryDirectory();
    final String path =
        '${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';

    debugPrint('🎤 Starting recording to: $path');

    await _audioRecorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        bitRate: 128000,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
    return path;
  }

  Future<String?> stopRecording() async {
    final path = await _audioRecorder.stop();

    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        final fileSize = await file.length();
        debugPrint('⏹️ Recording stopped: $path ($fileSize bytes)');

        if (fileSize < 1024) {
          throw Exception('Recording too short ($fileSize bytes)');
        }
      } else {
        throw Exception('Recording file not created');
      }
    }

    return path;
  }

  Future<bool> isRecording() async {
    return await _audioRecorder.isRecording();
  }

  void dispose() {
    _audioRecorder.dispose();
  }
}
