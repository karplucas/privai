import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'asset_bundle_override.dart';
import 'model_storage.dart';

/// Downloads Kokoro voices individually instead of bundling the whole table.
///
/// `kokoro_tts_flutter` wants a single `assets/voices.json` holding every voice —
/// about 52 MB, which it can only read through the asset bundle. Hugging Face
/// publishes the same data as one `voices/<id>.bin` per voice (510 x 256
/// float32, ~510 KB), so this fetches just the voices that are wanted, assembles
/// them into the JSON shape the package expects, and registers the result as an
/// asset override via [AssetOverrideBinding].
///
/// A bundled `assets/voices.json` still wins if one is present, so an existing
/// install keeps working untouched.
class VoicePackService {
  static final VoicePackService _instance = VoicePackService._internal();
  factory VoicePackService() => _instance;
  VoicePackService._internal();

  /// Asset key the TTS package reads its voice table from.
  static const String voicesAsset = 'assets/voices.json';

  /// Repository publishing the per-voice style vectors.
  static const String repo = 'onnx-community/Kokoro-82M-v1.0-ONNX';

  /// Style vectors are `[rows][1][256]` float32. The package clamps its lookup
  /// to the table length, so the exact row count does not have to match what a
  /// bundled file happened to have.
  static const int vectorWidth = 256;

  /// Downloaded by default on first use — one American and one British voice,
  /// about 1 MB in total.
  static const List<String> defaultVoices = ['af_heart', 'bf_emma'];

  /// Voices available in [repo]. Kept here so the settings screen can offer a
  /// choice before anything has been downloaded.
  static const List<String> knownVoices = [
    'af_alloy', 'af_aoede', 'af_bella', 'af_heart', 'af_jessica',
    'af_kore', 'af_nicole', 'af_nova', 'af_river', 'af_sarah', 'af_sky',
    'am_adam', 'am_echo', 'am_eric', 'am_fenrir', 'am_liam', 'am_michael',
    'am_onyx', 'am_puck', 'am_santa',
    'bf_alice', 'bf_emma', 'bf_isabella', 'bf_lily',
    'bm_daniel', 'bm_fable', 'bm_george', 'bm_lewis',
  ];

  final ModelStorage _storage = ModelStorage();
  final http.Client _client = http.Client();

  Future<void>? _preparation;

  Future<Directory> _voicesDir() async {
    final dir = Directory('${(await _storage.directory()).path}/voices');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _binFile(String voiceId) async =>
      File('${(await _voicesDir()).path}/$voiceId.bin');

  Future<File> _assembledFile() async =>
      File('${(await _voicesDir()).path}/voices.json');

  /// True when the app already ships a voice table, in which case nothing needs
  /// downloading.
  Future<bool> hasBundledVoices() async {
    try {
      await rootBundle.load(voicesAsset);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Voice ids already downloaded to this device.
  Future<List<String>> downloadedVoices() async {
    final dir = await _voicesDir();
    final files = await dir.list().toList();
    return files
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.bin'))
        .map((name) => name.substring(0, name.length - 4))
        .toList()
      ..sort();
  }

  /// Ensures a usable voice table exists and is registered with the bundle.
  ///
  /// Downloads [defaultVoices] when nothing is present yet. Safe to call
  /// repeatedly; concurrent callers share one run.
  Future<void> ensureReady({void Function(String message)? onStatus}) =>
      _preparation ??= _ensureReady(onStatus).whenComplete(() {
        _preparation = null;
      });

  Future<void> _ensureReady(void Function(String)? onStatus) async {
    if (await hasBundledVoices()) {
      debugPrint('VoicePackService: using bundled $voicesAsset');
      return;
    }

    var voices = await downloadedVoices();
    if (voices.isEmpty) {
      onStatus?.call('Downloading voices…');
      for (final voice in defaultVoices) {
        await downloadVoice(voice);
      }
      voices = await downloadedVoices();
    }

    if (voices.isEmpty) {
      throw const VoicePackException(
        'No Kokoro voices are available and none could be downloaded.',
      );
    }

    await _assembleAndRegister(voices);
  }

  /// Fetches one voice's style vectors.
  Future<void> downloadVoice(
    String voiceId, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final url = Uri.parse(
      'https://huggingface.co/$repo/resolve/main/voices/$voiceId.bin',
    );

    final request = http.Request('GET', url);
    final response = await _client.send(request);

    if (response.statusCode != 200) {
      throw VoicePackException(
        'Could not download the voice "$voiceId" '
        '(HTTP ${response.statusCode}).',
      );
    }

    final target = await _binFile(voiceId);
    final temp = File('${target.path}.part');
    final sink = temp.openWrite();
    var received = 0;

    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, response.contentLength);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (received < vectorWidth * 4) {
      await temp.delete();
      throw VoicePackException('The voice "$voiceId" downloaded incomplete.');
    }

    if (await target.exists()) await target.delete();
    await temp.rename(target.path);
    debugPrint('VoicePackService: downloaded $voiceId ($received bytes)');
  }

  /// Removes a downloaded voice and rebuilds the table.
  Future<void> deleteVoice(String voiceId) async {
    final file = await _binFile(voiceId);
    if (await file.exists()) await file.delete();

    final remaining = await downloadedVoices();
    if (remaining.isEmpty) {
      AssetOverrideBinding.removeOverride(voicesAsset);
      final assembled = await _assembledFile();
      if (await assembled.exists()) await assembled.delete();
    } else {
      await _assembleAndRegister(remaining);
    }
  }

  /// Adds [voiceId] and refreshes the registered table.
  Future<void> addVoice(
    String voiceId, {
    void Function(int received, int? total)? onProgress,
  }) async {
    await downloadVoice(voiceId, onProgress: onProgress);
    await _assembleAndRegister(await downloadedVoices());
  }

  /// Decodes one voice's `.bin` into the nested shape the TTS package expects.
  ///
  /// The file is little-endian float32 laid out as `rows x [vectorWidth]`. The
  /// package wants `[rows][1][vectorWidth]`, with each 256-wide vector wrapped
  /// in a single-element list. Verified byte-for-byte against a bundled
  /// `voices.json`: the values are identical, only the container differs.
  static List<List<List<double>>> decodeStyleVectors(Uint8List bytes) {
    // Copy rather than view: readAsBytes may hand back a buffer whose offset is
    // not 4-byte aligned, which Float32List.view rejects.
    final aligned = Uint8List.fromList(bytes);
    final floats = aligned.buffer.asFloat32List(0, aligned.lengthInBytes ~/ 4);

    final rows = floats.length ~/ vectorWidth;
    if (rows == 0) return const [];

    return List.generate(
      rows,
      (row) => [
        List<double>.generate(
          vectorWidth,
          (col) => floats[row * vectorWidth + col],
        ),
      ],
      growable: false,
    );
  }

  /// Converts the downloaded `.bin` files into the JSON table the TTS package
  /// reads, then points the asset key at it.
  Future<void> _assembleAndRegister(List<String> voiceIds) async {
    final table = <String, List<List<List<double>>>>{};

    for (final voiceId in voiceIds) {
      final file = await _binFile(voiceId);
      if (!await file.exists()) continue;

      final vectors = decodeStyleVectors(await file.readAsBytes());
      if (vectors.isEmpty) {
        debugPrint('VoicePackService: $voiceId is too small, skipping');
        continue;
      }
      table[voiceId] = vectors;
    }

    if (table.isEmpty) {
      throw const VoicePackException('No usable voice data on this device.');
    }

    final assembled = await _assembledFile();
    final temp = File('${assembled.path}.tmp');
    await temp.writeAsString(json.encode(table), flush: true);
    if (await assembled.exists()) await assembled.delete();
    await temp.rename(assembled.path);

    AssetOverrideBinding.registerOverride(voicesAsset, assembled.path);
    debugPrint(
      'VoicePackService: assembled ${table.length} voices into '
      '${assembled.path}',
    );
  }

  void dispose() => _client.close();
}

/// Raised when voice data cannot be obtained.
class VoicePackException implements Exception {
  const VoicePackException(this.message);

  final String message;

  @override
  String toString() => message;
}
