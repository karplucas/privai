import 'package:flutter/foundation.dart';

import '../models/model_spec.dart';
import 'app_settings.dart';
import 'chatterbox_tts_service.dart';
import 'kokoro_tts_service.dart';
import 'llm_service.dart';
import 'model_catalog.dart';
import 'model_storage.dart';
import 'omnivoice_tts_service.dart';
import 'speech_chunker.dart';
import 'tts_engine.dart';

/// Chooses the active speech-synthesis engine and speaks through it.
///
/// Callers ask for speech without knowing which backend is configured. The one
/// wrinkle this hides is memory: Chatterbox's Q4 weights, caches, and
/// intermediate tensors will not reliably co-reside with a multi-gigabyte
/// language model on a phone. For engines that declare
/// [TtsEngineKind.requiresExclusiveMemory] the language model is unloaded for
/// the duration and reloaded afterwards.
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
        TtsEngineKind.omnivoice => OmniVoiceTtsService(),
      };

  /// The engine the user has selected.
  Future<TtsEngine> activeEngine() async => engineFor(await _activeKind());

  /// Starts a sentence queue for one streamed LLM response.
  Future<TtsResponseQueue> responseQueue() async {
    final kind = await _activeKind();
    return TtsResponseQueue._(
      this,
      kind,
      speakWhileGenerating: kind == TtsEngineKind.kokoro,
      pipelineSynthesis: kind == TtsEngineKind.kokoro,
      sentenceChunking: kind == TtsEngineKind.kokoro,
    );
  }

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
    final keepLoaded = kind == TtsEngineKind.chatterbox &&
        await _settings.keepChatterboxLoaded;
    if (kind.requiresExclusiveMemory && !keepLoaded) {
      debugPrint('TtsRouter: deferring ${kind.name} until first use');
      return;
    }
    final engine = engineFor(kind);
    await engine.initialize();
    if (kind == TtsEngineKind.kokoro) {
      await KokoroTtsService().prewarm();
    }
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

    if (kind == TtsEngineKind.chatterbox &&
        await _settings.keepChatterboxLoaded) {
      final spoken = await _attempt(engine, text);
      if (spoken) return true;

      // A provider/session allocation failure can be recoverable after freeing
      // Gemma. Native out-of-memory termination itself cannot be caught, which
      // is why this remains an explicit opt-in setting.
      debugPrint('TtsRouter: simultaneous mode failed; retrying exclusively');
      await engine.dispose();
    }

    return _speakExclusively(engine, text);
  }

  Future<bool> _speakExclusively(TtsEngine engine, String text) async {
    final kind = engine.kind;

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
      // Releasing the sessions here matters: stopping playback alone leaves
      // all Chatterbox weights resident, defeating exclusive mode when Gemma
      // is loaded again below.
      await engine.dispose();
      if (hadModel) {
        try {
          await _llm.initializeChat(force: true);
        } catch (e) {
          debugPrint('TtsRouter: could not reload the language model: $e');
        }
      }
    }
  }

  Future<bool> _speakBatch(TtsEngineKind kind, List<String> chunks) async {
    if (chunks.isEmpty) return true;
    final engine = engineFor(kind);
    if (!kind.requiresExclusiveMemory) {
      var okay = true;
      for (final chunk in chunks) {
        okay = await _attempt(engine, chunk) && okay;
      }
      return okay;
    }

    if (kind == TtsEngineKind.chatterbox &&
        await _settings.keepChatterboxLoaded) {
      var okay = true;
      for (final chunk in chunks) {
        okay = await _attempt(engine, chunk) && okay;
      }
      if (okay) return true;

      // Match the single-utterance path: if co-resident allocation/inference
      // fails, release Chatterbox before retrying with the LLM out of memory.
      debugPrint('TtsRouter: simultaneous Chatterbox batch failed; '
          'retrying exclusively');
      await engine.dispose();
    }

    final hadModel = _llm.isReady;
    if (hadModel) await _llm.unload();
    try {
      var okay = true;
      for (final chunk in chunks) {
        okay = await _attempt(engine, chunk) && okay;
      }
      return okay;
    } finally {
      await engine.dispose();
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
    final keepLoaded = kind == TtsEngineKind.chatterbox &&
        await _settings.keepChatterboxLoaded;
    for (final other in TtsEngineKind.values) {
      if (other == kind) continue;
      await engineFor(other).dispose();
    }
    if (kind.requiresExclusiveMemory && !keepLoaded) {
      await engineFor(kind).dispose();
    } else {
      await engineFor(kind).reload();
    }
  }
}

/// Queues natural sentence chunks without delaying token rendering.
class TtsResponseQueue {
  TtsResponseQueue._(
    this._router,
    this._kind, {
    required this.speakWhileGenerating,
    required this.pipelineSynthesis,
    required this.sentenceChunking,
  });

  final TtsRouter _router;
  final TtsEngineKind _kind;
  final bool speakWhileGenerating;
  final bool pipelineSynthesis;
  final bool sentenceChunking;
  final SpeechChunker _chunker = SpeechChunker();
  final StringBuffer _wholeResponse = StringBuffer();
  final List<String> _buffered = [];
  final List<Future<bool>> _pipelined = [];
  Future<bool> _serial = Future<bool>.value(true);

  void add(String fragment) {
    if (!sentenceChunking) {
      _wholeResponse.write(fragment);
      return;
    }
    for (final chunk in _chunker.add(fragment)) {
      _enqueue(chunk);
    }
  }

  Future<bool> finish() async {
    if (sentenceChunking) {
      for (final chunk in _chunker.finish()) {
        _enqueue(chunk);
      }
    } else {
      final response = _wholeResponse.toString().trim();
      if (response.isNotEmpty) _enqueue(response);
    }
    if (!speakWhileGenerating) {
      return _router._speakBatch(_kind, _buffered);
    }
    if (pipelineSynthesis) {
      final results = await Future.wait(_pipelined);
      return results.every((result) => result);
    }
    return _serial;
  }

  void _enqueue(String chunk) {
    if (!speakWhileGenerating) {
      _buffered.add(chunk);
    } else if (pipelineSynthesis) {
      // Kokoro serializes ONNX inference internally but may synthesize the next
      // chunk while its reusable player is playing the previous one.
      _pipelined.add(_router._attempt(_router.engineFor(_kind), chunk));
    } else {
      _serial = _serial.then((okay) async =>
          await _router._attempt(_router.engineFor(_kind), chunk) && okay);
    }
  }
}
