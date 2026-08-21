import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/model_spec.dart';
import 'app_settings.dart';
import 'chatterbox_gguf_tts_service.dart';
import 'chatterbox_tts_service.dart';
import 'kokoro_tts_service.dart';
import 'llm_service.dart';
import 'mms_tts_service.dart';
import 'model_catalog.dart';
import 'model_storage.dart';
import 'omnivoice_tts_service.dart';
import 'supertonic_tts_service.dart';
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

  /// A reply being spoken with the language model unloaded, from the unload
  /// through the reload that follows it.
  Future<void>? _exclusiveSpeech;

  /// Completes once no exclusive-memory engine is holding the language model's
  /// place in memory.
  ///
  /// The chat screen waits on this before treating the model as unavailable.
  /// While a reply is being spoken `LlmService.isReady` is legitimately false,
  /// and loading the model then would fight the speech engine for exactly the
  /// memory the unload freed for it.
  Future<void> get languageModelAvailable =>
      _exclusiveSpeech ?? Future<void>.value();

  /// Whether a reply is being spoken with the language model unloaded.
  bool get isSpeakingExclusively => _exclusiveSpeech != null;

  /// Whether any engine is speaking right now, so the UI can offer to stop it.
  final ValueNotifier<bool> isSpeaking = ValueNotifier<bool>(false);

  /// How many utterances are in flight. A reply is one utterance, but a
  /// "read aloud" tap can overlap a reply that is still being spoken.
  int _utterances = 0;

  /// Set by [stopSpeaking] and cleared when the next reply starts speaking.
  /// Chunks that have not begun are abandoned rather than spoken into a silence
  /// the user asked for.
  bool _stopRequested = false;

  TtsEngine engineFor(TtsEngineKind kind) => switch (kind) {
        TtsEngineKind.kokoro => KokoroTtsService(),
        TtsEngineKind.chatterbox => ChatterboxTtsService(),
        TtsEngineKind.omnivoice => OmniVoiceTtsService(),
        TtsEngineKind.chatterboxGguf => ChatterboxGgufTtsService(),
        TtsEngineKind.mms => MmsTtsService(),
        TtsEngineKind.supertonic => SupertonicTtsService(),
      };

  /// The engine the user has selected.
  Future<TtsEngine> activeEngine() async => engineFor(await _activeKind());

  /// Starts the speech queue for one streamed LLM response.
  ///
  /// A reply is spoken as a single utterance. It used to be split into
  /// sentences so that the fast engines could start speaking before generation
  /// finished, but every split is a seam: the engines pause between clips, and
  /// splitting is what made replies sound halting. One utterance has no seams
  /// to hide, at the cost of no audio until the reply is complete.
  Future<TtsResponseQueue> responseQueue() async {
    _stopRequested = false;
    return TtsResponseQueue._(this);
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
    _stopRequested = false;
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

  Future<bool> _speakExclusively(TtsEngine engine, String text) =>
      _withLanguageModelUnloaded(engine, () => _attempt(engine, text));

  /// Frees the language model, runs [speak], then brings the model back.
  ///
  /// The reload is in a finally so a synthesis failure cannot leave the chat
  /// unable to reply, and the whole span is published as [languageModelAvailable]
  /// so a message sent while the reply is still being spoken waits for the
  /// model instead of being told it is unavailable.
  Future<bool> _withLanguageModelUnloaded(
      TtsEngine engine, Future<bool> Function() speak) async {
    final done = Completer<void>();
    _exclusiveSpeech = done.future;

    final hadModel = _llm.isReady;
    if (hadModel) {
      debugPrint('TtsRouter: unloading language model for ${engine.kind.name}');
      await _llm.unload();
    }
    try {
      return await speak();
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
      _exclusiveSpeech = null;
      done.complete();
    }
  }

  Future<bool> _attempt(TtsEngine engine, String text) =>
      _utter(engine, () => engine.speak(text));

  /// Runs one piece of speech, tracking it in [isSpeaking] and honouring a stop.
  ///
  /// A cancelled utterance reports success: the caller uses the result to warn
  /// that the speech engine is broken, and silence the user asked for is not a
  /// failure to tell them about.
  Future<bool> _utter(TtsEngine engine, Future<void> Function() speak) async {
    if (_stopRequested) return true;
    _utterances++;
    isSpeaking.value = true;
    try {
      await speak();
      return true;
    } catch (e) {
      if (_stopRequested) return true;
      debugPrint('TtsRouter: ${engine.kind.name} failed: $e');
      return false;
    } finally {
      // A stop that lands while the reply was still being synthesised finds
      // nothing playing to stop, and the clip then starts afterwards. Stopping
      // again here is what actually makes the audio end.
      if (_stopRequested) {
        try {
          await engine.stop();
        } catch (e) {
          debugPrint('TtsRouter: ${engine.kind.name} would not stop: $e');
        }
      }
      if (--_utterances <= 0) {
        _utterances = 0;
        isSpeaking.value = false;
      }
    }
  }

  /// Stops the reply being spoken, and keeps it stopped.
  ///
  /// Unlike [stopAll] this is a user's decision, so [_stopRequested] also
  /// suppresses a synthesis that is still in flight — otherwise it would start
  /// playing the moment it finished, just after the user asked for silence.
  Future<void> stopSpeaking() async {
    _stopRequested = true;
    await stopAll();
  }

  /// Stops whichever engine is speaking.
  Future<void> stopAll() async {
    for (final kind in TtsEngineKind.values) {
      await engineFor(kind).stop();
    }
  }

  /// Releases speech-model sessions before Whisper allocates its decoder.
  ///
  /// The language model remains resident. TTS engines lazily initialize on
  /// their next [TtsEngine.speak] call, so this lowers the iPhone peak without
  /// reintroducing the disruptive LLM unload/reload cycle.
  Future<void> releaseForTranscription() async {
    for (final kind in TtsEngineKind.values) {
      final engine = engineFor(kind);
      try {
        await engine.stop();
        await engine.dispose();
      } catch (e) {
        debugPrint('TtsRouter: could not release ${kind.name} for Whisper: $e');
      }
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

/// Collects one streamed reply and speaks it when it is complete.
class TtsResponseQueue {
  TtsResponseQueue._(this._router);

  final TtsRouter _router;
  final StringBuffer _response = StringBuffer();

  /// Accumulates a generated fragment. Nothing is synthesised until [finish].
  void add(String fragment) => _response.write(fragment);

  /// Speaks everything collected, and reports whether the engine managed it.
  Future<bool> finish() async {
    final text = _response.toString().trim();
    if (text.isEmpty) return true;
    return _router.speak(text);
  }
}
