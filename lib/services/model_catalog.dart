import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/model_spec.dart';

/// Loads and caches the downloadable-model catalog from
/// `assets/models_list.json`.
///
/// The page that displays models used to decode the JSON itself and treat every
/// top-level key as a list of models, which silently swept the `tts_languages`
/// and `stt_languages` arrays into the model list. Parsing lives here now and is
/// explicit about which keys are models and which are language tables.
class ModelCatalog {
  static final ModelCatalog _instance = ModelCatalog._internal();
  factory ModelCatalog() => _instance;
  ModelCatalog._internal();

  static const String assetPath = 'assets/models_list.json';

  Future<ModelCatalogData>? _pending;

  /// Loads the catalog, reusing the in-flight or previously completed load.
  Future<ModelCatalogData> load() => _pending ??= _load();

  Future<ModelCatalogData> _load() async {
    try {
      final raw = await rootBundle.loadString(assetPath);
      return ModelCatalogData.fromJson(
        json.decode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      // A broken catalog should not take the whole settings page down; surface
      // an empty catalog and let the UI say so.
      debugPrint('ModelCatalog: failed to load $assetPath: $e');
      _pending = null;
      rethrow;
    }
  }

  @visibleForTesting
  void invalidate() => _pending = null;
}

/// Parsed contents of the model catalog.
class ModelCatalogData {
  const ModelCatalogData({
    required this.models,
    required this.ttsLanguages,
    required this.sttLanguages,
  });

  final List<ModelSpec> models;
  final List<LanguageOption> ttsLanguages;
  final List<LanguageOption> sttLanguages;

  List<ModelSpec> byKind(ModelKind kind) =>
      models.where((m) => m.kind == kind).toList();

  /// Looks up a model by its on-device filename.
  ModelSpec? byFilename(String filename) {
    for (final model in models) {
      if (model.filename == filename) return model;
    }
    return null;
  }

  factory ModelCatalogData.fromJson(Map<String, dynamic> json) {
    final models = <ModelSpec>[];

    for (final kind in ModelKind.values) {
      final entries = json[kind.name];
      if (entries is! List) continue;
      for (final entry in entries) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          models.add(ModelSpec.fromJson(kind, entry));
        } catch (e) {
          debugPrint('ModelCatalog: skipping malformed ${kind.name} entry: $e');
        }
      }
    }

    return ModelCatalogData(
      models: models,
      ttsLanguages: _languages(json['tts_languages']),
      sttLanguages: _languages(json['stt_languages']),
    );
  }

  static List<LanguageOption> _languages(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map<String, dynamic>>()
        .where((entry) => entry['code'] is String)
        .map(LanguageOption.fromJson)
        .toList();
  }
}
