import 'package:flutter/foundation.dart';

import '../models/model_spec.dart';
import 'app_settings.dart';
import 'chatterbox_tts_service.dart';
import 'kokoro_tts_service.dart';
import 'llm_service.dart';
import 'model_catalog.dart';
import 'model_storage.dart';
import 'tts_engine.dart';

/// Chooses the active speech-synthesis engine and speaks through it.
///
/// Callers ask for speech without knowing which backend is configured. The one
/// wrinkle this hides is memory: Chatterbox holds well over a gigabyte of ONNX
/// sessions, which will not co-reside with a multi-gigabyte language model on a
/// phone. For engines that declare [TtsEngineKind.requiresExclusiveMemory] the
/// language model is unloaded for the duration and reloaded afterwards.
class TtsRouter {
  static final TtsRouter _instance = TtsRouter._internal();
  factory TtsRouter() => _instance;
  TtsRouter._internal();

  final AppSettings _settings = AppSettings();
  final LlmService _llm = LlmService();
  final ModelStorage _storage = ModelStorage();

  TtsEngine engineFor(TtsEngineKind kind) => switch (kind) {
        TtsEngineKind.kokoro => KokoroTtsService(),
        TtsEngineKind.chatterbox => ChatterboxTtsService(),
      };

  /// The engine the user has selected.
  Future<TtsEngine> activeEngine() async => engineFor(await _activeKind());

  /// A TTS model and its engine are one choice, not two independent settings.
  /// Older builds allowed the engine radio group to drift away from the model
  /// selection, so an installed ONNX model could accidentally invoke GGUF.
  /// Prefer the selected catalog model and repair the stale engine setting.
  Future<TtsEngineKind> _activeKind() async {
    final configured = await _settings.ttsEngine;
    final selected = await _settings.selectedTtsModel;

    try {
      final catalog = await ModelCatalog().load();
      final ttsModels = catalog.byKind(ModelKind.tts);
      ModelSpec? chosen;

      if (selected != null) {
        final matches = ttsModels.where((m) => m.filename == selected);
        if (matches.isNotEmpty && await _isInstalled(matches.first)) {
          chosen = matches.first;
        }
      }

      if (chosen == null) {
        for (final model in ttsModels) {
          if (await _isInstalled(model)) {
            chosen = model;
            break;
          }
        }
      }
      if (chosen == null) return configured;

      final engineName = chosen.engine;
      final selectedKind = TtsEngineKind.fromName(engineName);
      if (engineName == null || selectedKind.name != engineName) {
        return configured;
      }

      if (selectedKind != configured) {
        debugPrint('TtsRouter: correcting stale engine ${configured.name} to '
            '${selectedKind.name} for installed model ${chosen.filename}');
        await _settings.setTtsEngine(selectedKind);
      }
      if (selected != chosen.filename) {
        await _settings.setSelectedTtsModel(chosen.filename);
      }
      return selectedKind;
    } catch (e) {
      debugPrint('TtsRouter: could not reconcile selected TTS model: $e');
      return configured;
    }
  }

  Future<bool> _isInstalled(ModelSpec model) {
    if (model.isBundle) {
      return _storage.bundleIsComplete(
        model.bundleDirectory ?? model.filename,
        model.requiredFilenames,
      );
    }
    return _storage.isDownloaded(model.filename);
  }

  /// Prepares the configured engine, if it can be prepared without disturbing
  /// the language model.
  ///
  /// Memory-exclusive engines are deliberately *not* warmed up: loading them at
  /// start-up would evict the language model before the user has said anything.
  Future<void> warmUp() async {
    final kind = await _activeKind();
    if (kind.requiresExclusiveMemory) {
      debugPrint('TtsRouter: deferring ${kind.name} until first use');
      return;
    }
    await engineFor(kind).initialize();
  }

  /// Speaks [text] through the configured engine.
  ///
  /// Returns false when synthesis was not possible, having already logged why.
  Future<bool> speak(String text) async {
    final kind = await _activeKind();
    final engine = engineFor(kind);

    if (!kind.requiresExclusiveMemory) {
      return _attempt(engine, text);
    }

    // Free the language model, speak, then bring it back. The reload is in a
    // finally so a synthesis failure cannot leave the chat unable to reply.
    final hadModel = _llm.isReady;
    if (hadModel) {
      debugPrint('TtsRouter: unloading language model for ${kind.name}');
      await _llm.unload();
    }
    try {
      return await _attempt(engine, text);
    } finally {
      await engine.stop();
      if (hadModel) {
        try {
          await _llm.initializeChat(force: true);
        } catch (e) {
          debugPrint('TtsRouter: could not reload the language model: $e');
        }
      }
    }
  }

  Future<bool> _attempt(TtsEngine engine, String text) async {
    try {
      await engine.speak(text);
      return true;
    } catch (e) {
      debugPrint('TtsRouter: ${engine.kind.name} failed: $e');
      return false;
    }
  }

  /// Stops whichever engine is speaking.
  Future<void> stopAll() async {
    for (final kind in TtsEngineKind.values) {
      await engineFor(kind).stop();
    }
  }

  /// Reloads the configured engine after a settings change, and releases the
  /// other so it is not holding memory it no longer needs.
  Future<void> applySettingsChange() async {
    final kind = await _activeKind();
    for (final other in TtsEngineKind.values) {
      if (other == kind) continue;
      await engineFor(other).dispose();
    }
    if (!kind.requiresExclusiveMemory) {
      await engineFor(kind).reload();
    }
  }
}
