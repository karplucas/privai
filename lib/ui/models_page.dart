import 'dart:async';

import 'package:flutter/material.dart';

import '../models/model_spec.dart';
import '../services/app_settings.dart';
import '../services/huggingface_service.dart';
import '../services/model_catalog.dart';
import '../services/model_download_manager.dart';
import '../services/model_storage.dart';
import '../services/tts_engine.dart';
import '../services/tts_router.dart';
import 'theme.dart';
import 'widgets/hf_sign_in_sheet.dart';
import 'widgets/model_tile.dart';

/// Settings screen: inference parameters, voice options and model downloads.
class ModelsPage extends StatefulWidget {
  const ModelsPage({super.key});

  @override
  State<ModelsPage> createState() => _ModelsPageState();
}

class _ModelsPageState extends State<ModelsPage> {
  final AppSettings _settings = AppSettings();
  final HuggingFaceService _hf = HuggingFaceService();
  final ModelStorage _storage = ModelStorage();

  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _temperatureController = TextEditingController();
  final TextEditingController _maxTokensController = TextEditingController();
  final TextEditingController _ttsSpeedController = TextEditingController();

  ModelCatalogData? _catalog;
  Object? _catalogError;
  bool _loading = true;

  String? _hfAccount;
  bool _signedIn = false;

  final Map<String, ModelTileState> _modelStates = {};
  final Set<String> _downloadedFilenames = {};

  String? _selectedLlm;
  String? _selectedTts;
  String? _selectedStt;

  bool _ttsEnabled = true;
  bool _sttEnabled = true;
  bool _saveChatHistory = true;
  bool _keepChatterboxLoaded = false;
  int _omnivoiceRefinementSteps = AppSettings.defaultOmnivoiceRefinementSteps;

  TtsEngineKind _ttsEngineKind = TtsEngineKind.kokoro;
  String _ttsVoice = AppSettings.defaultTtsVoice;
  String _ttsLanguage = AppSettings.defaultTtsLanguage;
  String _sttLanguage = AppSettings.defaultSttLanguage;
  List<String> _availableVoices = const [];

  /// Set when a change requires the chat screen to reload a service.
  bool _needsReload = false;

  StreamSubscription<ModelDownloadEvent>? _downloadSub;

  @override
  void initState() {
    super.initState();
    _downloadSub = ModelDownloadManager().events.listen(_handleDownloadEvent);
    _load();
  }

  @override
  void dispose() {
    // Downloads are owned by ModelDownloadManager, not this page, so leaving
    // (even via a swipe-back) no longer cancels a transfer in progress —
    // only unsubscribes this page from its progress events.
    _downloadSub?.cancel();
    _promptController.dispose();
    _temperatureController.dispose();
    _maxTokensController.dispose();
    _ttsSpeedController.dispose();
    super.dispose();
  }

  /// Reacts to a download's state change, whichever tile it belongs to.
  ///
  /// The manager already persisted anything durable (the `.partial` file, the
  /// auto-select on completion); everything here is this page's own view of
  /// that state, so it is skipped once the page is gone.
  void _handleDownloadEvent(ModelDownloadEvent event) {
    if (!mounted) return;

    final filename = event.model.filename;
    setState(() {
      final current = _modelStates[filename] ?? const ModelTileState();
      _modelStates[filename] = current.copyWith(
        downloaded: event.status == ModelDownloadStatus.completed
            ? true
            : current.downloaded,
        progress: event.state.progress,
        cancellationToken: event.state.cancellationToken,
        error: event.state.error,
        clearProgress: event.state.progress == null,
        clearToken: event.state.cancellationToken == null,
        clearError: event.state.error == null,
      );
      if (event.status == ModelDownloadStatus.completed) {
        _downloadedFilenames.add(filename);
      }
    });

    switch (event.status) {
      case ModelDownloadStatus.progress:
        break;
      case ModelDownloadStatus.completed:
        // The manager already persisted the selection (and, for TTS, the
        // engine switch); mirror both into this page's own fields so the
        // tile's "selected" state and the engine radio group update too.
        setState(() {
          _needsReload = true;
          switch (event.model.kind) {
            case ModelKind.llm:
              _selectedLlm = filename;
            case ModelKind.tts:
              _selectedTts = filename;
              final engineName = event.model.engine;
              if (engineName != null) {
                final kind = TtsEngineKind.fromName(engineName);
                if (kind.name == engineName) _ttsEngineKind = kind;
              }
            case ModelKind.stt:
              _selectedStt = filename;
          }
        });
        if (event.model.kind == ModelKind.tts) _refreshVoices();
        _showMessage('${event.model.name} downloaded and selected.');
      case ModelDownloadStatus.cancelled:
        _showMessage('Download cancelled. Progress is kept for resuming.');
      case ModelDownloadStatus.failed:
        final access = event.state.access;
        if (access?.status == HfAccessStatus.licenseRequired) {
          _openLicenseGate(event.model);
        } else if (access?.status == HfAccessStatus.authenticationRequired) {
          _signIn();
        } else {
          _showMessage(event.state.error ?? 'Download failed.');
        }
    }
  }

  /// Loads settings and the catalog in a defined order.
  ///
  /// The previous version fired nine independent loads from `initState`, so the
  /// saved TTS voice was validated against a voice list that had not been
  /// fetched yet and was therefore always discarded.
  Future<void> _load() async {
    try {
      final catalog = await ModelCatalog().load();
      final downloaded = await _storage.listDownloaded();

      final prompt = await _settings.systemPrompt;
      final temperature = await _settings.temperature;
      final maxTokens = await _settings.maxTokens;
      final ttsSpeed = await _settings.ttsSpeed;

      final selectedLlm = await _settings.selectedLlmModel;
      final selectedTts = await _settings.selectedTtsModel;
      final selectedStt = await _settings.selectedSttModel;

      final ttsEnabled = await _settings.ttsEnabled;
      final sttEnabled = await _settings.sttEnabled;
      final saveChatHistory = await _settings.saveChatHistory;
      final keepChatterboxLoaded = await _settings.keepChatterboxLoaded;
      final omnivoiceRefinementSteps = await _settings.omnivoiceRefinementSteps;

      final ttsEngineKind = await _settings.ttsEngine;
      final ttsVoice = await _settings.ttsVoice;
      final ttsLanguage = await _settings.ttsLanguage;
      final sttLanguage = await _settings.sttLanguage;

      final signedIn = await _hf.isSignedIn;
      final account = signedIn ? await _hf.currentAccountName() : null;

      if (!mounted) return;

      _promptController.text = prompt;
      _temperatureController.text = temperature.toString();
      _maxTokensController.text = maxTokens.toString();
      _ttsSpeedController.text = ttsSpeed.toString();

      setState(() {
        _catalog = catalog;
        _downloadedFilenames
          ..clear()
          ..addAll(downloaded);
        _selectedLlm = selectedLlm;
        _selectedTts = selectedTts;
        _selectedStt = selectedStt;
        _ttsEnabled = ttsEnabled;
        _sttEnabled = sttEnabled;
        _saveChatHistory = saveChatHistory;
        _keepChatterboxLoaded = keepChatterboxLoaded;
        _omnivoiceRefinementSteps = omnivoiceRefinementSteps;
        _ttsEngineKind = ttsEngineKind;
        _ttsVoice = ttsVoice;
        _ttsLanguage = ttsLanguage;
        _sttLanguage = sttLanguage;
        _signedIn = signedIn;
        _hfAccount = account;
        _loading = false;

        for (final model in catalog.models) {
          // Picks up a download already in flight (or a leftover error) from
          // the manager, so reopening this page mid-transfer shows it rather
          // than resetting to a blank tile.
          _modelStates[model.filename] = ModelDownloadManager()
              .stateFor(model.filename)
              .copyWith(downloaded: downloaded.contains(model.filename));
        }
      });

      await _refreshBundleStates(catalog);
      await _refreshVoices();
      await _refreshGatedAccess();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _catalogError = e;
        _loading = false;
      });
    }
  }

  /// Multi-file models are complete only when every one of their files is on
  /// disk, which a flat filename listing cannot tell us.
  Future<void> _refreshBundleStates(ModelCatalogData catalog) async {
    for (final model in catalog.models.where((m) => m.isBundle)) {
      final complete = await _storage.bundleIsComplete(
        model.bundleDirectory ?? model.filename,
        model.requiredFilenames,
      );
      if (!mounted) return;
      setState(() {
        if (complete) _downloadedFilenames.add(model.filename);
        _modelStates[model.filename] = ModelDownloadManager()
            .stateFor(model.filename)
            .copyWith(downloaded: complete);
      });
    }
  }

  /// Loads the voice list, then reconciles the saved voice against it.
  Future<void> _refreshVoices() async {
    final catalog = _catalog;
    if (catalog == null) return;

    // Voice ids come from the engine itself rather than a hardcoded list, which
    // previously offered voices the model does not actually contain.
    List<String> voices;
    try {
      final engine = await TtsRouter().activeEngine();
      // Merely opening Settings must not load a dormant multi-gigabyte TTS
      // engine beside the current LLM. Voice choices appear once that engine
      // has been initialized by normal use or warm-up.
      if (!engine.isInitialized) return;
      voices = await engine.availableVoices();
    } catch (e) {
      debugPrint('ModelsPage: could not list voices: $e');
      return;
    }

    if (!mounted || voices.isEmpty) return;

    setState(() {
      _availableVoices = voices;
      if (!voices.contains(_ttsVoice)) _ttsVoice = voices.first;
    });
    await _settings.setTtsVoice(_ttsVoice);
  }

  /// Checks license status for every gated model that is not on disk yet.
  Future<void> _refreshGatedAccess() async {
    final catalog = _catalog;
    if (catalog == null) return;

    for (final model in catalog.models) {
      if (!model.gated) continue;
      if (_downloadedFilenames.contains(model.filename)) continue;
      await _checkAccess(model);
    }
  }

  Future<void> _checkAccess(ModelSpec model) async {
    _updateState(model.filename, (s) => s.copyWith(checkingAccess: true));
    final result = await _hf.checkAccess(model);
    if (!mounted) return;
    _updateState(
      model.filename,
      (s) => s.copyWith(checkingAccess: false, access: result),
    );
  }

  void _updateState(
    String filename,
    ModelTileState Function(ModelTileState) update,
  ) {
    if (!mounted) return;
    setState(() {
      final current = _modelStates[filename] ?? const ModelTileState();
      _modelStates[filename] = update(current);
    });
  }

  // --------------------------------------------------------------------------
  // Hugging Face account
  // --------------------------------------------------------------------------

  Future<void> _signIn() async {
    final signedIn = await showHfSignInSheet(context, _hf);
    if (!signedIn || !mounted) return;

    final account = await _hf.currentAccountName();
    if (!mounted) return;
    setState(() {
      _signedIn = true;
      _hfAccount = account;
    });
    _showMessage(
        'Signed in to Hugging Face${account == null ? '' : ' as $account'}.');
    await _refreshGatedAccess();
  }

  Future<void> _signOut() async {
    await _hf.signOut();
    if (!mounted) return;
    setState(() {
      _signedIn = false;
      _hfAccount = null;
      for (final entry in _modelStates.entries) {
        _modelStates[entry.key] = entry.value.copyWith(clearAccess: true);
      }
    });
    await _refreshGatedAccess();
  }

  // --------------------------------------------------------------------------
  // License gate
  // --------------------------------------------------------------------------

  /// Walks the user through accepting the repository's license on Hugging Face.
  ///
  /// The app cannot record the acceptance itself: Hugging Face presents the
  /// terms — Google's Gemma Terms of Use for the Gemma repositories — and stores
  /// the acknowledgement against the signed-in account. All this does is explain
  /// the requirement, open that page, and re-check afterwards.
  Future<void> _openLicenseGate(ModelSpec model) async {
    if (!_signedIn) {
      await _signIn();
      if (!mounted || !_signedIn) return;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(model.license ?? 'License required'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                model.licenseNote ??
                    '${model.name} is distributed under a license you must '
                        'accept before downloading.',
              ),
              const SizedBox(height: 16),
              const Text(
                'You will be taken to the model page on Hugging Face. Read the '
                'terms there and choose to acknowledge them with the same '
                'account you signed in with. Come back here afterwards and the '
                'download will unlock.',
              ),
              const SizedBox(height: 16),
              SelectableText(
                model.licensePageUrl.toString(),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Open model page'),
          ),
        ],
      ),
    );

    if (proceed != true || !mounted) return;

    final opened = await _hf.openLicensePage(model);
    if (!mounted) return;
    if (!opened) {
      _showMessage('Could not open a browser. Visit ${model.licensePageUrl}');
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Finished on Hugging Face?'),
        content: Text(
          'Once you have accepted the terms for ${model.name}, tap Re-check and '
          'the download will become available.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Re-check'),
          ),
        ],
      ),
    );

    if (!mounted) return;
    await _checkAccess(model);
    if (!mounted) return;

    final access = _modelStates[model.filename]?.access;
    if (access != null && !access.isGranted) {
      _showMessage(
        access.status == HfAccessStatus.licenseRequired
            ? 'Hugging Face still reports this model as restricted. Approval '
                'can take a moment — try again shortly.'
            : access.message ?? 'Still unable to access this model.',
      );
    }
  }

  // --------------------------------------------------------------------------
  // Downloads
  // --------------------------------------------------------------------------

  /// Kicks off the download and returns immediately — [ModelDownloadManager]
  /// runs it independently of this page, and [_handleDownloadEvent] reflects
  /// its progress here for as long as the page stays open.
  void _download(ModelSpec model) {
    ModelDownloadManager().download(model);
  }

  Future<void> _delete(ModelSpec model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${model.name}?'),
        content: Text(
          'This removes the ${model.size} file from this device. You can '
          'download it again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    ModelDownloadManager().forget(model.filename);
    if (model.isBundle) {
      await _storage.deleteBundle(model.bundleDirectory ?? model.filename);
    } else {
      await _storage.delete(model.filename);
    }
    await _settings.clearSelectionFor(model.filename);
    if (!mounted) return;

    setState(() {
      _downloadedFilenames.remove(model.filename);
      _modelStates[model.filename] = const ModelTileState();
      if (_selectedLlm == model.filename) _selectedLlm = null;
      if (_selectedTts == model.filename) _selectedTts = null;
      if (_selectedStt == model.filename) _selectedStt = null;
      _needsReload = true;
    });

    if (model.gated) await _checkAccess(model);
  }

  Future<void> _select(ModelSpec model, {bool announce = true}) async {
    switch (model.kind) {
      case ModelKind.llm:
        await _settings.setSelectedLlmModel(model.filename);
        if (mounted) setState(() => _selectedLlm = model.filename);
      case ModelKind.tts:
        await _settings.setSelectedTtsModel(model.filename);
        if (mounted) setState(() => _selectedTts = model.filename);
        // A TTS model is only usable by the engine it was built for, so picking
        // one switches engines rather than leaving a selection the active
        // engine cannot load.
        await _adoptEngineFor(model);
      case ModelKind.stt:
        await _settings.setSelectedSttModel(model.filename);
        if (mounted) setState(() => _selectedStt = model.filename);
    }
    if (mounted) setState(() => _needsReload = true);
    if (announce && mounted) _showMessage('${model.name} selected.');
  }

  /// Switches the active speech engine to the one [model] belongs to.
  Future<void> _adoptEngineFor(ModelSpec model) async {
    final engine = model.engine;
    if (engine == null) return;
    final kind = TtsEngineKind.fromName(engine);
    if (kind.name != engine || kind == _ttsEngineKind) return;

    await _settings.setTtsEngine(kind);
    if (!mounted) return;
    setState(() {
      _ttsEngineKind = kind;
      _needsReload = true;
    });
    await _refreshVoices();
  }

  String? _selectionFor(ModelKind kind) => switch (kind) {
        ModelKind.llm => _selectedLlm,
        ModelKind.tts => _selectedTts,
        ModelKind.stt => _selectedStt,
      };

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --------------------------------------------------------------------------
  // Build
  // --------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // A swipe-back or hardware/gesture back pops through this callback too,
      // not just the AppBar's back button below. With `canPop: true` that
      // system-driven pop used to complete `Navigator.push<bool>` with `null`
      // instead of `_needsReload`, so `_openSettings` silently skipped the
      // model reload — a model picked with "Use this" then swiped away from
      // stayed unloaded until the app was restarted.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        Navigator.pop(context, _needsReload);
      },
      child: Scaffold(
        appBar: AppBar(
          leadingWidth: 60,
          leading: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: _CircleBackButton(
              onPressed: () => Navigator.pop(context, _needsReload),
            ),
          ),
          title: const Text('Settings & Models'),
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_catalogError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Could not load the model catalog:\n$_catalogError'),
        ),
      );
    }

    final catalog = _catalog!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        _huggingFaceSection(),
        for (final kind in ModelKind.values)
          _modelSection(kind, catalog.byKind(kind)),
        _llmSection(),
        _voiceTogglesSection(),
        _ttsSection(catalog),
        _sttSection(catalog),
      ],
    );
  }

  /// One settings group: a heading on the canvas with its controls in a card
  /// beneath it, which reads more clearly on a near-black background than the
  /// hairline dividers this replaced.
  Widget _section(
    String title, {
    String? subtitle,
    required List<Widget> children,
    EdgeInsets padding = const EdgeInsets.all(4),
  }) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: padding,
            decoration: BoxDecoration(
              color: AppGradients.of(context).bubbleColor,
              borderRadius: BorderRadius.circular(AppTheme.radius),
              border: Border.all(color: AppGradients.of(context).hairline),
            ),
            // The card's fill is painted by this Container, so list tiles
            // inside it need a Material of their own to ink onto — otherwise
            // their splashes and selected-tile colour land on the page's
            // Material, underneath the fill, and Flutter asserts.
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: children,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _huggingFaceSection() {
    final theme = Theme.of(context);

    return _section(
      'Hugging Face account',
      subtitle: 'Required to download models from gated repositories, such '
          'as the Gemma models published by Google.',
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        ListTile(
          leading: Icon(
            _signedIn ? Icons.verified_user : Icons.person_outline,
            color: _signedIn ? theme.colorScheme.primary : null,
          ),
          title: Text(
            _signedIn
                ? 'Signed in${_hfAccount == null ? '' : ' as $_hfAccount'}'
                : 'Not signed in',
            style: theme.textTheme.titleSmall,
          ),
          subtitle: Text(
            _signedIn
                ? 'Gated models you have accepted the terms for are downloadable.'
                : 'Sign in to download gated models.',
            style: theme.textTheme.bodySmall,
          ),
          isThreeLine: true,
          trailing: _signedIn
              ? TextButton(onPressed: _signOut, child: const Text('Sign out'))
              : FilledButton(onPressed: _signIn, child: const Text('Sign in')),
        ),
      ],
    );
  }

  Widget _modelSection(ModelKind kind, List<ModelSpec> models) {
    if (models.isEmpty) return const SizedBox.shrink();

    return _section(
      kind.label,
      padding: const EdgeInsets.all(8),
      children: [
        for (final model in models)
          ModelTile(
            model: model,
            state: _modelStates[model.filename] ?? const ModelTileState(),
            isSelected: _selectionFor(kind) == model.filename,
            signedIn: _signedIn,
            onDownload: () => _download(model),
            onCancel: () => ModelDownloadManager().cancel(model.filename),
            onDelete: () => _delete(model),
            onSelect: () => _select(model),
            onReviewLicense: () => _openLicenseGate(model),
            onSignIn: _signIn,
            onRetryCheck: () => _checkAccess(model),
          ),
      ],
    );
  }

  Widget _llmSection() {
    return _section(
      'Language model parameters',
      subtitle: 'Changes take effect the next time the model loads.',
      padding: const EdgeInsets.all(16),
      children: [
        Column(
          children: [
            TextField(
              controller: _promptController,
              decoration: const InputDecoration(labelText: 'System prompt'),
              maxLines: 3,
              onChanged: (value) {
                _settings.setSystemPrompt(value);
                _needsReload = true;
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _temperatureController,
              decoration: const InputDecoration(
                labelText: 'Temperature',
                helperText: '0.0 (focused) to 2.0 (creative)',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (value) {
                final parsed = double.tryParse(value);
                if (parsed == null) return;
                _settings.setTemperature(parsed.clamp(0.0, 2.0).toDouble());
                _needsReload = true;
              },
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _maxTokensController,
              decoration: const InputDecoration(
                labelText: 'Max context tokens',
                helperText: '256 to 32768',
              ),
              keyboardType: TextInputType.number,
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed == null) return;
                _settings.setMaxTokens(parsed.clamp(256, 32768));
                _needsReload = true;
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _voiceTogglesSection() {
    return _section(
      'Chat behaviour',
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        SwitchListTile(
          title: const Text('Text-to-speech'),
          subtitle: const Text('Speak the assistant\'s replies aloud'),
          value: _ttsEnabled,
          onChanged: (value) async {
            await _settings.setTtsEnabled(value);
            if (!mounted) return;
            setState(() {
              _ttsEnabled = value;
              _needsReload = true;
            });
          },
        ),
        SwitchListTile(
          title: const Text('Speech-to-text'),
          subtitle: const Text('Show the microphone button for voice input'),
          value: _sttEnabled,
          onChanged: (value) async {
            await _settings.setSttEnabled(value);
            if (!mounted) return;
            setState(() {
              _sttEnabled = value;
              _needsReload = true;
            });
          },
        ),
        SwitchListTile(
          title: const Text('Save chat history'),
          subtitle: const Text('Keep conversations on this device'),
          value: _saveChatHistory,
          onChanged: (value) async {
            await _settings.setSaveChatHistory(value);
            if (!mounted) return;
            setState(() {
              _saveChatHistory = value;
              _needsReload = true;
            });
          },
        ),
      ],
    );
  }

  Widget _ttsSection(ModelCatalogData catalog) {
    return _section(
      'Text-to-speech options',
      padding: const EdgeInsets.symmetric(vertical: 4),
      children: [
        RadioGroup<TtsEngineKind>(
          groupValue: _ttsEngineKind,
          onChanged: (value) async {
            if (value == null) return;
            final matches = catalog
                .byKind(ModelKind.tts)
                .where((model) => model.engine == value.name);
            if (matches.isEmpty) return;
            final model = matches.first;
            if (!_downloadedFilenames.contains(model.filename)) {
              _showMessage('Download ${model.name} before selecting it.');
              return;
            }
            await _select(model);
          },
          child: Column(
            children: [
              for (final engine in TtsEngineKind.values)
                RadioListTile<TtsEngineKind>(
                  value: engine,
                  title: Text(
                    engine.label,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  subtitle: Text(
                    engine.requiresExclusiveMemory
                        ? '${engine.description}\nFrees the language model '
                            'while speaking, then reloads it.'
                        : engine.description,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        if (_ttsEngineKind == TtsEngineKind.chatterbox)
          SwitchListTile(
            title: const Text('Keep Chatterbox loaded'),
            subtitle: const Text(
              'Keep it in memory with the language model for faster speech. '
              'Use only with a small LLM on a high-memory device.',
            ),
            value: _keepChatterboxLoaded,
            onChanged: (value) async {
              await _settings.setKeepChatterboxLoaded(value);
              if (!mounted) return;
              setState(() {
                _keepChatterboxLoaded = value;
                _needsReload = true;
              });
            },
          ),
        if (_ttsEngineKind == TtsEngineKind.omnivoice)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: DropdownButtonFormField<int>(
              initialValue: _omnivoiceRefinementSteps,
              decoration: const InputDecoration(
                labelText: 'Refinement steps',
                helperText: 'More steps improve quality but take longer',
              ),
              items: const [5, 8, 12, 16, 24, 32]
                  .map((steps) => DropdownMenuItem(
                        value: steps,
                        child: Text('$steps steps'),
                      ))
                  .toList(),
              onChanged: (value) async {
                if (value == null) return;
                await _settings.setOmnivoiceRefinementSteps(value);
                if (!mounted) return;
                setState(() => _omnivoiceRefinementSteps = value);
              },
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                menuMaxHeight: 360,
                initialValue:
                    catalog.ttsLanguages.any((l) => l.code == _ttsLanguage)
                        ? _ttsLanguage
                        : null,
                decoration: const InputDecoration(labelText: 'Language'),
                items: [
                  for (final language in catalog.ttsLanguages)
                    DropdownMenuItem(
                      value: language.code,
                      child: Text(language.name),
                    ),
                ],
                onChanged: (value) async {
                  if (value == null) return;
                  await _settings.setTtsLanguage(value);
                  if (!mounted) return;
                  setState(() => _ttsLanguage = value);
                },
              ),
              const SizedBox(height: 16),
              if (_availableVoices.isEmpty)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.info_outline),
                  title: Text(
                    'Voice list unavailable',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  subtitle: Text(
                    'Download and select a text-to-speech model to choose a '
                    'voice.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                DropdownButtonFormField<String>(
                  initialValue:
                      _availableVoices.contains(_ttsVoice) ? _ttsVoice : null,
                  decoration: const InputDecoration(labelText: 'Voice'),
                  items: [
                    for (final voice in _availableVoices)
                      DropdownMenuItem(value: voice, child: Text(voice)),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    await _settings.setTtsVoice(value);
                    if (!mounted) return;
                    setState(() => _ttsVoice = value);
                  },
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _ttsSpeedController,
                decoration: const InputDecoration(
                  labelText: 'Speaking speed',
                  helperText: '0.5 to 2.0',
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  final parsed = double.tryParse(value);
                  if (parsed == null) return;
                  _settings.setTtsSpeed(parsed.clamp(0.5, 2.0).toDouble());
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sttSection(ModelCatalogData catalog) {
    return _section(
      'Speech-to-text options',
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          width: double.infinity,
          child: DropdownButtonFormField<String>(
            initialValue:
                catalog.sttLanguages.any((l) => l.code == _sttLanguage)
                    ? _sttLanguage
                    : null,
            decoration: const InputDecoration(labelText: 'Language'),
            items: [
              for (final language in catalog.sttLanguages)
                DropdownMenuItem(
                  value: language.code,
                  child: Text(language.name),
                ),
            ],
            onChanged: (value) async {
              if (value == null) return;
              await _settings.setSttLanguage(value);
              if (!mounted) return;
              setState(() => _sttLanguage = value);
            },
          ),
        ),
      ],
    );
  }
}

/// Matches the circular controls on the chat screen's app bar.
class _CircleBackButton extends StatelessWidget {
  const _CircleBackButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: MaterialLocalizations.of(context).backButtonTooltip,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: CircleBorder(
          side: BorderSide(color: AppGradients.of(context).hairline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(
              Icons.arrow_back,
              size: 19,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
