import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Single source of truth for where downloaded models live on disk.
///
/// Before this existed the model directory was spelled three different ways
/// across the app (`getExternalStorageDirectory()`, a hardcoded
/// `/storage/emulated/0/Android/data/...` path, and `/sdcard/Android/data/...`),
/// so a model downloaded by the models page was not always the file the LLM or
/// Whisper service went looking for. Everything now goes through here.
class ModelStorage {
  static final ModelStorage _instance = ModelStorage._internal();
  factory ModelStorage() => _instance;
  ModelStorage._internal();

  /// Suffix used for partially downloaded files so an interrupted download is
  /// never mistaken for a usable model.
  static const String partialSuffix = '.part';

  Directory? _cachedDirectory;

  /// Directory that holds downloaded models.
  ///
  /// On Android this is the app-private external files dir, which needs no
  /// storage permission and is removed when the app is uninstalled. On other
  /// platforms it falls back to the app support directory.
  Future<Directory> directory() async {
    final cached = _cachedDirectory;
    if (cached != null) return cached;

    Directory? dir;
    if (Platform.isAndroid) {
      dir = await getExternalStorageDirectory();
    }
    dir ??= await getApplicationSupportDirectory();

    final modelsDir = Directory('${dir.path}/models');
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }

    _cachedDirectory = modelsDir;
    return modelsDir;
  }

  /// Absolute path a model with [filename] would occupy once fully downloaded.
  Future<String> pathFor(String filename) async {
    final dir = await directory();
    return '${dir.path}/$filename';
  }

  /// Absolute path used while a download of [filename] is still in flight.
  Future<String> partialPathFor(String filename) async =>
      '${await pathFor(filename)}$partialSuffix';

  /// Whether a complete copy of [filename] is present.
  Future<bool> isDownloaded(String filename) async =>
      File(await pathFor(filename)).exists();

  /// Size on disk of [filename], or 0 if it is not present.
  Future<int> sizeOf(String filename) async {
    final file = File(await pathFor(filename));
    if (!await file.exists()) return 0;
    return file.length();
  }

  /// Bytes already fetched for an interrupted download of [filename].
  Future<int> partialSizeOf(String filename) async {
    final file = File(await partialPathFor(filename));
    if (!await file.exists()) return 0;
    return file.length();
  }

  /// Deletes the model and any partial download for [filename].
  Future<void> delete(String filename) async {
    for (final path in [
      await pathFor(filename),
      await partialPathFor(filename),
    ]) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
        debugPrint('ModelStorage: deleted $path');
      }
    }
  }

  /// Directory holding a multi-file model's files.
  ///
  /// Sidecar weight files must sit beside the graph that names them, so each
  /// bundle gets its own subdirectory rather than sharing the flat model folder.
  Future<Directory> bundleDirectory(String bundle) async {
    final dir = Directory('${(await directory()).path}/$bundle');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Path of [filename] inside the [bundle] directory.
  Future<String> pathInBundle(String bundle, String filename) async =>
      '${(await bundleDirectory(bundle)).path}/$filename';

  /// Whether every name in [filenames] is present in [bundle].
  Future<bool> bundleIsComplete(String bundle, List<String> filenames) async {
    for (final name in filenames) {
      if (!await File(await pathInBundle(bundle, name)).exists()) return false;
    }
    return filenames.isNotEmpty;
  }

  /// Total bytes occupied by [bundle].
  Future<int> bundleSize(String bundle) async {
    final dir = Directory('${(await directory()).path}/$bundle');
    if (!await dir.exists()) return 0;
    var total = 0;
    await for (final entry in dir.list(recursive: true)) {
      if (entry is File) total += await entry.length();
    }
    return total;
  }

  /// Removes a whole bundle directory.
  Future<void> deleteBundle(String bundle) async {
    final dir = Directory('${(await directory()).path}/$bundle');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
      debugPrint('ModelStorage: deleted bundle ${dir.path}');
    }
  }

  /// Filenames of every complete model currently on disk.
  Future<List<String>> listDownloaded() async {
    final dir = await directory();
    final entries = await dir.list().toList();
    return entries
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => !name.endsWith(partialSuffix))
        .toList()
      ..sort();
  }

  @visibleForTesting
  void resetCacheForTest() => _cachedDirectory = null;
}
