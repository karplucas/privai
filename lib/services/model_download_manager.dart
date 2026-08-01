import 'dart:async';

import '../models/model_spec.dart';
import '../ui/widgets/model_tile.dart' show ModelTileState;
import 'app_settings.dart';
import 'huggingface_service.dart';
import 'tts_engine.dart';

enum ModelDownloadStatus { progress, completed, cancelled, failed }

/// One state change for a download, broadcast to whichever page is open.
class ModelDownloadEvent {
  const ModelDownloadEvent(this.model, this.status, this.state);

  final ModelSpec model;
  final ModelDownloadStatus status;
  final ModelTileState state;
}

/// Runs model downloads independently of any page's lifecycle.
///
/// Downloads used to be owned by the Models page's State and torn down in its
/// `dispose()`, so leaving Settings & Models — even just tapping back to the
/// chat screen — cancelled the transfer mid-stream and surfaced whatever raw
/// exception the aborted HTTP stream produced. `_downloadTo` in
/// [HuggingFaceService] already writes to a resumable `.partial` file, so the
/// fix is to stop tearing the transfer down on navigation: this singleton
/// owns it for as long as the app process is alive, and the page just
/// displays whatever state is current, attaching and detaching without
/// affecting the transfer itself.
class ModelDownloadManager {
  static final ModelDownloadManager _instance =
      ModelDownloadManager._internal();
  factory ModelDownloadManager() => _instance;
  ModelDownloadManager._internal();

  final HuggingFaceService _hf = HuggingFaceService();
  final AppSettings _settings = AppSettings();

  final Map<String, ModelTileState> _states = {};
  final StreamController<ModelDownloadEvent> _events =
      StreamController.broadcast();

  Stream<ModelDownloadEvent> get events => _events.stream;

  /// Download/error state for [filename], or an empty state if nothing is
  /// tracked for it (not downloading, no leftover error).
  ModelTileState stateFor(String filename) =>
      _states[filename] ?? const ModelTileState();

  /// Starts downloading [model]. A no-op if it is already in flight — the
  /// tile only ever offers Cancel while downloading, so this guards against
  /// two overlapping streams writing the same `.partial` file rather than
  /// something expected in normal use.
  Future<void> download(ModelSpec model) async {
    if (stateFor(model.filename).isDownloading) return;

    final token = CancellationToken();
    _update(
      model,
      ModelDownloadStatus.progress,
      (s) => s.copyWith(
        cancellationToken: token,
        progress: const DownloadProgress(received: 0, total: null),
        clearError: true,
      ),
    );

    try {
      await _hf.downloadModel(
        model,
        cancellationToken: token,
        onProgress: (progress) => _update(
          model,
          ModelDownloadStatus.progress,
          (s) => s.copyWith(progress: progress),
        ),
      );

      _update(
        model,
        ModelDownloadStatus.completed,
        (_) => const ModelTileState(downloaded: true),
      );

      // A freshly downloaded model is almost always the one you want to use.
      await _autoSelect(model);
    } on DownloadCancelled {
      _update(
        model,
        ModelDownloadStatus.cancelled,
        (s) => s.copyWith(clearProgress: true, clearToken: true),
      );
    } on HfDownloadException catch (e) {
      _update(
        model,
        ModelDownloadStatus.failed,
        (s) => s.copyWith(
          clearProgress: true,
          clearToken: true,
          error: e.message,
          access: e.access,
        ),
      );
    } catch (e) {
      _update(
        model,
        ModelDownloadStatus.failed,
        (s) => s.copyWith(clearProgress: true, clearToken: true, error: '$e'),
      );
    }
  }

  /// Cancels [filename]'s download, if one is running. The partial file is
  /// kept so a later [download] call resumes it.
  void cancel(String filename) {
    stateFor(filename).cancellationToken?.cancel();
  }

  /// Drops any tracked state for [filename] — used when the file itself is
  /// deleted, so a stale error or progress bar cannot linger for it.
  void forget(String filename) {
    cancel(filename);
    _states.remove(filename);
  }

  void _update(
    ModelSpec model,
    ModelDownloadStatus status,
    ModelTileState Function(ModelTileState) update,
  ) {
    final next = update(stateFor(model.filename));
    _states[model.filename] = next;
    _events.add(ModelDownloadEvent(model, status, next));
  }

  Future<void> _autoSelect(ModelSpec model) async {
    switch (model.kind) {
      case ModelKind.llm:
        await _settings.setSelectedLlmModel(model.filename);
      case ModelKind.tts:
        await _settings.setSelectedTtsModel(model.filename);
        final engineName = model.engine;
        if (engineName != null) {
          final kind = TtsEngineKind.fromName(engineName);
          if (kind.name == engineName) await _settings.setTtsEngine(kind);
        }
      case ModelKind.stt:
        await _settings.setSelectedSttModel(model.filename);
    }
  }
}
