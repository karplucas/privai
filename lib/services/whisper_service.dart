import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_ggml/whisper_ggml.dart';
import 'package:record/record.dart';

class WhisperService {
  static WhisperService? _instance;
  final WhisperController _whisperController = WhisperController();
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isInitialized = false;
  final WhisperModel _model = WhisperModel.tiny;

  WhisperService._();

  static WhisperService get instance {
    _instance ??= WhisperService._();
    return _instance!;
  }

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      await _setupModel();
      _isInitialized = true;
    } catch (e) {
      throw Exception('Failed to initialize Whisper: $e');
    }
  }

  Future<void> _setupModel() async {
    try {
      final ByteData bytesBase =
          await rootBundle.load('assets/models/ggml-tiny.bin');
      final modelPathBase = await _whisperController.getPath(_model);
      final fileBase = File(modelPathBase);

      if (!await fileBase.exists()) {
        await fileBase.writeAsBytes(
          bytesBase.buffer
              .asUint8List(bytesBase.offsetInBytes, bytesBase.lengthInBytes),
        );
      }
    } catch (e) {
      await _whisperController.downloadModel(_model);
    }
  }

  Future<String> transcribeFromFile(String audioPath,
      {String? language}) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final result = await _whisperController.transcribe(
        model: _model,
        audioPath: audioPath,
        lang: language ?? 'auto',
      );

      return result?.transcription.text ?? '';
    } catch (e) {
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
        '${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _audioRecorder.start(const RecordConfig(), path: path);
    return path;
  }

  Future<String?> stopRecording() async {
    return await _audioRecorder.stop();
  }

  Future<bool> isRecording() async {
    return await _audioRecorder.isRecording();
  }

  void dispose() {
    _audioRecorder.dispose();
  }
}
