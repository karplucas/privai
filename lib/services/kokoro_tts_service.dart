import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:kokoro_tts_flutter/kokoro_tts_flutter.dart';
import 'package:path_provider/path_provider.dart';

class KokoroTtsService {
  static final KokoroTtsService _instance = KokoroTtsService._internal();
  factory KokoroTtsService() => _instance;
  KokoroTtsService._internal();

  bool _isInitialized = false;
  Kokoro? _kokoro;
  AudioPlayer? _player;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Initialize Kokoro with proper configuration
      const modelPath = 'assets/kokoro.onnx';
      const voicesPath = 'assets/voices.json';

      debugPrint('Initializing Kokoro with:');
      debugPrint('  Model: $modelPath');
      debugPrint('  Voices: $voicesPath');

      const config = KokoroConfig(
        modelPath: modelPath,
        voicesPath: voicesPath,
        isInt8: false, // Using standard model
      );

      _kokoro = Kokoro(config);
      await _kokoro!.initialize();

      _player = AudioPlayer();
      _isInitialized = true;
      debugPrint('Kokoro TTS initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize Kokoro TTS: $e');
      rethrow;
    }
  }

  Future<void> speak(String text,
      {String voice = 'af', String lang = 'en-us'}) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      debugPrint('Generating speech for: "$text" with voice: $voice');

      if (_kokoro == null) {
        throw Exception('Kokoro TTS not initialized');
      }

      // Generate audio
      final ttsResult = await _kokoro!.createTTS(
        text: text,
        voice: voice,
        speed: 1.0,
        isPhonemes: false,
      );

      debugPrint(
          'TTS result generated: ${ttsResult.audio.length} audio samples');

      if (_player != null) {
        debugPrint('Starting audio playback...');

        final tempDir = await getTemporaryDirectory();
        final filename =
            'kokoro_output_${DateTime.now().millisecondsSinceEpoch}.wav';
        final audioFile = File('${tempDir.path}/$filename');

        final samples = ttsResult.audio.cast<double>();
        const sampleRate = 24000;
        const channels = 1;
        const bitsPerSample = 16;

        // 1. Convert Samples to 16-bit PCM bytes efficiently
        final Int16List int16Samples = Int16List(samples.length);
        for (int i = 0; i < samples.length; i++) {
          int16Samples[i] = (samples[i] * 32767).toInt().clamp(-32768, 32767);
        }
        final Uint8List pcmBytes = int16Samples.buffer.asUint8List();

        // 2. Build the Header using ByteData (handles Little Endian automatically)
        const byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
        const blockAlign = channels * (bitsPerSample ~/ 8);
        final dataSize = pcmBytes.length;
        final fileSize = 36 + dataSize;

        final header = ByteData(44);
        header.setUint32(0, 0x52494646, Endian.big); // "RIFF"
        header.setUint32(4, fileSize, Endian.little);
        header.setUint32(8, 0x57415645, Endian.big); // "WAVE"

        header.setUint32(12, 0x666d7420, Endian.big); // "fmt "
        header.setUint32(16, 16, Endian.little); // Subchunk1Size
        header.setUint16(20, 1, Endian.little); // AudioFormat (PCM)
        header.setUint16(22, channels, Endian.little);
        header.setUint32(24, sampleRate, Endian.little);
        header.setUint32(28, byteRate, Endian.little);
        header.setUint16(32, blockAlign, Endian.little);
        header.setUint16(34, bitsPerSample, Endian.little);

        header.setUint32(36, 0x64617461, Endian.big); // "data"
        header.setUint32(40, dataSize, Endian.little);

        // 3. Combine and Write
        final wavData = BytesBuilder()
          ..add(header.buffer.asUint8List())
          ..add(pcmBytes);

        await audioFile.writeAsBytes(wavData.toBytes());

        debugPrint('Audio file created: ${audioFile.path}');
        await _player!.play(DeviceFileSource(audioFile.path));

        // Set up a one-time listener to delete the file when finished
        _player!.onPlayerComplete.first.then((_) async {
          try {
            if (await audioFile.exists()) {
              await audioFile.delete();
              debugPrint('Temp audio file cleaned up.');
            }
          } catch (e) {
            debugPrint('Error deleting temp file: $e');
          }
        });
      }
    } catch (e) {
      debugPrint('Error in Kokoro TTS: $e');
      rethrow;
    }
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('Error stopping audio: $e');
    }
  }

  void dispose() {
    _kokoro?.dispose();
    _player?.dispose();
    _isInitialized = false;
  }

  bool get isInitialized => _isInitialized;

  Future<List<String>> getAvailableVoiceIds() async {
    // Return default voice IDs that should be available
    return [
      'af_heart',
      'af_sarah',
      'af_nicole',
      'af_adam',
      'af_sky',
      'am_michael',
      'am_fenrir',
      'bm_daniel',
      'bm_george',
      'bm_lewis',
      'ef_dora',
      'em_alex',
      'em_santa',
      'ff_azure',
      'fm_alice',
      'fm_ginny',
      'hf_alpha',
      'hm_roland',
      'hm_peter',
      'if_sara',
      'im_nicole',
      'jf_alpha',
      'jf_gongitsune',
      'jf_kumo',
      'jm_kumo',
      'pf_taylor',
      'pm_lee',
      'pf_santa',
      'zf_xiaoya',
      'zf_xiaotian',
      'zm_yunjian',
    ];
  }
}
