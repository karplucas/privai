import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_settings.dart';
import '../services/conversation_service.dart';
import '../services/llm_service.dart';
import '../services/tts_router.dart';
import '../services/voice_activity_detector.dart';
import '../services/whisper_service.dart';
import 'models_page.dart';
import 'theme.dart';
import 'voice_conversation_page.dart';

/// The main chat screen.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.themeToggleCallback});

  final VoidCallback themeToggleCallback;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
  final FocusNode _composerFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  final AppSettings _settings = AppSettings();
  final LlmService _llmService = LlmService();
  final WhisperService _whisperService = WhisperService();
  final TtsRouter _tts = TtsRouter();
  final ConversationService _conversationService = ConversationService();

  bool _isRecording = false;
  bool _isTranscribing = false;
  bool _isProcessing = false;
  bool _isModelLoading = false;

  /// True while tokens are arriving from the model.
  bool _isStreaming = false;

  /// Set when the user asks to stop generating part-way through.
  bool _stopRequested = false;

  /// Whether the view should stay pinned to the newest text. Cleared when the
  /// user scrolls up, so a long reply cannot drag them back down while they are
  /// reading earlier messages.
  bool _followTail = true;

  /// Guards against queueing a scroll callback for every single token.
  bool _scrollScheduled = false;
  bool _ttsEnabled = true;
  bool _sttEnabled = true;
  bool _saveChatHistory = true;
  bool _voiceModeActive = false;
  String _voiceModeStatus = 'Listening…';
  int _voiceModeGeneration = 0;
  final ValueNotifier<String> _voiceStatus = ValueNotifier('Listening…');
  final ValueNotifier<double> _voiceLevel = ValueNotifier(0);
  final ValueNotifier<bool> _voiceActive = ValueNotifier(false);

  /// Non-null when the model could not be loaded; shown as a banner with a
  /// shortcut to the models page.
  String? _modelError;

  Conversation? _currentConversation;
  int _composerFocusRequest = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_trackScrollPosition);
    _startUp();
  }

  /// Follows the tail only while the user is already near the bottom.
  void _trackScrollPosition() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    _followTail = position.maxScrollExtent - position.pixels < 80;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _composerFocusRequest++;
    final wasInVoiceMode = _voiceModeActive;
    _voiceModeActive = false;
    _voiceModeGeneration++;
    if (wasInVoiceMode) {
      unawaited(_discardActiveVoiceRecording());
    }
    _textController.dispose();
    _composerFocusNode.dispose();
    _scrollController.dispose();
    _voiceStatus.dispose();
    _voiceLevel.dispose();
    _voiceActive.dispose();
    // The services are process-wide singletons shared with the settings screen,
    // so they are deliberately not disposed here — the previous version tore
    // them down whenever this widget went away, leaving the app with a dead
    // recorder and audio player.
    super.dispose();
  }

  Future<void> _discardActiveVoiceRecording() async {
    if (!await _whisperService.isRecording) return;
    final path = await _whisperService.stopRecording();
    if (path == null) return;
    try {
      await File(path).delete();
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _composerFocusNode.hasFocus) {
      _focusComposer();
    }
  }

  Future<void> _startUp() async {
    await _loadSettings();
    await _requestPermissions();
    await _loadConversation();
    await _initializeLlm();
    await _warmUpVoiceServices();
  }

  Future<void> _loadSettings() async {
    final tts = await _settings.ttsEnabled;
    final stt = await _settings.sttEnabled;
    final saveHistory = await _settings.saveChatHistory;
    if (!mounted) return;
    setState(() {
      _ttsEnabled = tts;
      _sttEnabled = stt;
      _saveChatHistory = saveHistory;
    });
  }

  /// Asks only for what the app actually uses.
  ///
  /// Models live in the app's own external files directory, which needs no
  /// storage permission, so the previous request for `MANAGE_EXTERNAL_STORAGE`
  /// — the all-files access that app stores treat as a policy violation — has
  /// been dropped.
  Future<void> _requestPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    if (!_sttEnabled) return;
    try {
      await Permission.microphone.request();
    } catch (e) {
      debugPrint('ChatScreen: permission request failed: $e');
    }
  }

  Future<void> _initializeLlm() async {
    setState(() {
      _isModelLoading = true;
      _modelError = null;
    });
    try {
      await _llmService.initializeChat();
    } catch (e) {
      if (mounted) setState(() => _modelError = '$e');
    } finally {
      // The loading flag is now set before the await rather than being read
      // from the service before initialisation had begun, which meant the
      // progress bar never appeared.
      if (mounted) setState(() => _isModelLoading = false);
    }
  }

  Future<void> _warmUpVoiceServices() async {
    if (_sttEnabled) {
      try {
        await _whisperService.initialize();
      } catch (e) {
        debugPrint('ChatScreen: speech-to-text unavailable: $e');
      }
    }
    if (_ttsEnabled) {
      try {
        await _tts.warmUp();
      } catch (e) {
        debugPrint('ChatScreen: text-to-speech unavailable: $e');
      }
    }
  }

  // --- Conversations ---

  Future<void> _loadConversation() async {
    if (!_saveChatHistory) {
      _currentConversation = await _conversationService.createNewConversation();
      if (mounted) setState(() => _messages.clear());
      return;
    }

    final existing = await _conversationService.getCurrentConversation();
    _currentConversation =
        existing ?? await _conversationService.createNewConversation();

    if (!mounted) return;
    setState(() {
      _messages
        ..clear()
        ..addAll(_currentConversation!.messages);
    });
    _scrollToBottom();
  }

  Future<void> _saveCurrentConversation() async {
    final conversation = _currentConversation;
    if (!_saveChatHistory || conversation == null || _messages.isEmpty) return;
    await _conversationService.updateConversationMessages(
      conversation.id,
      _messages,
    );
    // Titles are derived from the messages, so the drawer's copy is now stale.
    _historyFuture = null;
  }

  Future<void> _startNewConversation() async {
    await _saveCurrentConversation();
    _currentConversation = await _conversationService.createNewConversation();
    await _llmService.clearContext();
    if (!mounted) return;
    setState(() => _messages.clear());
    _refreshHistory();
  }

  Future<void> _openConversation(String conversationId) async {
    await _saveCurrentConversation();

    final conversations = await _conversationService.getConversations();
    final match =
        conversations.where((c) => c.id == conversationId).firstOrNull;
    if (match == null) return;

    await _conversationService.setCurrentConversation(conversationId);
    await _llmService.clearContext();

    if (!mounted) return;
    setState(() {
      _currentConversation = match;
      _messages
        ..clear()
        ..addAll(match.messages);
    });
    _scrollToBottom();
  }

  // --- Messaging ---

  Future<void> _sendMessage(
    String text, {
    Future<void> Function()? beforeSpeech,
  }) async {
    final userText = text.trim();
    if (userText.isEmpty || _isProcessing) return;

    if (!_llmService.isReady) {
      _showMessage(_modelError ?? 'The language model is still loading.');
      return;
    }

    // Deleting the active conversation intentionally leaves an unsaved blank
    // canvas. Start creating its backing record on the first real message, but
    // do not make the visible send wait for file/keychain I/O.
    final conversationFuture = _currentConversation == null
        ? _conversationService.createNewConversation()
        : null;

    _textController.clear();
    setState(() {
      _messages
        ..add({'role': 'user', 'text': userText})
        // The reply bubble goes in empty and fills as tokens arrive, so the
        // user sees progress instead of a stalled screen.
        ..add({'role': 'ai', 'text': ''});
      _isProcessing = true;
      _isStreaming = true;
      _stopRequested = false;
    });
    if (_voiceModeActive) {
      _composerFocusNode.unfocus();
    } else {
      _focusComposer();
    }
    _scrollToBottom();

    // Held by reference rather than by index: starting a new conversation
    // mid-stream clears the list, and an index into it would then throw.
    // Writing to a detached map is simply invisible.
    final replyMessage = _messages.last;
    final buffer = StringBuffer();
    var failed = false;
    final Future<TtsResponseQueue?>? speechQueueFuture =
        _ttsEnabled && !_llmService.isUsingDebugResponse
            ? _tts
                .responseQueue()
                .then<TtsResponseQueue?>((queue) => queue)
                .catchError(
                (Object e) {
                  debugPrint('ChatScreen: could not prepare speech queue: $e');
                  return null;
                },
              )
            : null;

    try {
      await for (final chunk in _withGenerationWatchdog(
        _llmService.generateResponseStream(userText),
      )) {
        if (!mounted) return;
        // Leaving the loop cancels the underlying subscription, which stops the
        // model rather than just hiding its output.
        if (_stopRequested) break;
        buffer.write(chunk);
        if (speechQueueFuture != null) {
          unawaited(speechQueueFuture.then((queue) => queue?.add(chunk)));
        }
        setState(() => replyMessage['text'] = buffer.toString());
        _scrollToBottomWhileStreaming();
      }
    } catch (e) {
      // Only a context overflow warrants clearing history; other failures are
      // reported as themselves instead of being mislabelled.
      debugPrint('ChatScreen: inference failed: $e');
      failed = true;
      final String message;
      if (_looksLikeContextOverflow(e)) {
        await _llmService.clearContext();
        message = 'The conversation grew past the context window, so I cleared '
            'it. Please ask again.';
      } else {
        message = 'Something went wrong generating a reply: $e';
      }
      if (!mounted) return;
      // Keep whatever streamed successfully and append the explanation.
      final partial = buffer.toString().trimRight();
      setState(() {
        replyMessage['text'] =
            partial.isEmpty ? message : '$partial\n\n$message';
      });
    }

    if (!mounted) return;
    final stopped = _stopRequested;
    setState(() {
      _isProcessing = false;
      _isStreaming = false;
      _stopRequested = false;
      if (stopped && (replyMessage['text'] ?? '').trim().isEmpty) {
        // Nothing was produced before stopping; drop the empty bubble.
        _messages.remove(replyMessage);
      }
    });

    if (conversationFuture != null) {
      try {
        _currentConversation = await conversationFuture;
      } catch (e) {
        debugPrint('ChatScreen: could not create conversation history: $e');
      }
      if (!mounted) return;
    }
    await _saveCurrentConversation();
    await beforeSpeech?.call();

    final reply = buffer.toString();
    final speechQueue = await speechQueueFuture;
    if (speechQueue != null && !failed && !stopped && reply.trim().isNotEmpty) {
      final spoken = await speechQueue.finish().timeout(
        const Duration(seconds: 45),
        onTimeout: () async {
          debugPrint('ChatScreen: speech timed out after 45 seconds');
          await _tts.stopAll();
          return false;
        },
      );
      if (!spoken) {
        _showMessage(
          'Could not generate audio with the selected speech engine. '
          'Check the model files and try again.',
        );
      }
    } else if ((failed || stopped) &&
        speechQueue?.speakWhileGenerating == true) {
      await _tts.stopAll();
    }
  }

  bool _looksLikeContextOverflow(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('context') ||
        message.contains('token') ||
        message.contains('max_tokens');
  }

  /// Closes its downstream side immediately when the backend stops emitting.
  /// Upstream cancellation is deliberately best-effort: a wedged native stream
  /// must not keep the UI waiting for cancellation acknowledgement.
  Stream<String> _withGenerationWatchdog(Stream<String> source) {
    late final StreamController<String> controller;
    StreamSubscription<String>? subscription;
    Timer? timer;
    var hasOutput = false;

    void armTimer() {
      timer?.cancel();
      final wait =
          hasOutput ? const Duration(seconds: 8) : const Duration(seconds: 15);
      timer = Timer(wait, () {
        debugPrint(
          'ChatScreen: generation idle for ${wait.inSeconds}s; '
          'closing the response stream',
        );
        unawaited(controller.close());
        final current = subscription;
        if (current != null) unawaited(current.cancel());
      });
    }

    controller = StreamController<String>(
      onListen: () {
        armTimer();
        subscription = source.listen(
          (chunk) {
            if (controller.isClosed) return;
            hasOutput = true;
            armTimer();
            controller.add(chunk);
          },
          onError: controller.addError,
          onDone: () {
            timer?.cancel();
            unawaited(controller.close());
          },
        );
      },
      onCancel: () {
        timer?.cancel();
        final current = subscription;
        if (current != null) unawaited(current.cancel());
      },
    );
    return controller.stream;
  }

  Future<void> _speak(String text) async {
    final queue = await _tts.responseQueue();
    queue.add(text);
    final spoken = await queue.finish();
    if (!spoken) {
      _showMessage(
        'Could not generate audio with the selected speech engine. '
        'Check the model files and try again.',
      );
    }
  }

  Future<void> _toggleVoiceMode() async {
    if (_voiceModeActive) {
      await _stopVoiceMode();
      return;
    }
    if (!_sttEnabled || !_ttsEnabled) {
      _showMessage('Enable both speech-to-text and text-to-speech first.');
      return;
    }
    if (!_llmService.isReady) {
      _showMessage(_modelError ?? 'The language model is not ready.');
      return;
    }
    final permission = await Permission.microphone.request();
    if (!permission.isGranted) {
      _showMessage('Microphone permission is required for voice mode.');
      return;
    }

    final generation = ++_voiceModeGeneration;
    setState(() {
      _voiceModeActive = true;
      _voiceModeStatus = 'Listening…';
    });
    _voiceStatus.value = 'Listening…';
    _voiceLevel.value = 0;
    _voiceActive.value = true;
    _composerFocusNode.unfocus();
    unawaited(_showVoiceConversation(generation));
    unawaited(_runVoiceMode(generation));
  }

  Future<void> _showVoiceConversation(int generation) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VoiceConversationPage(
          status: _voiceStatus,
          level: _voiceLevel,
          active: _voiceActive,
          onStop: _stopVoiceMode,
        ),
      ),
    );
    if (_voiceModeIsCurrent(generation)) await _stopVoiceMode();
  }

  Future<void> _stopVoiceMode() async {
    final wasActive = _voiceModeActive;
    _voiceModeActive = false;
    _voiceModeGeneration++;
    _voiceActive.value = false;
    _voiceLevel.value = 0;
    if (mounted && wasActive) setState(() {});
    if (wasActive && await _whisperService.isRecording) {
      final path = await _whisperService.stopRecording();
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _runVoiceMode(int generation) async {
    String? queuedSpeech;
    while (_voiceModeIsCurrent(generation)) {
      String? audioPath;
      try {
        var transcription = queuedSpeech;
        queuedSpeech = null;
        if (transcription == null) {
          _setVoiceModeStatus('Listening…');
          await _whisperService.startRecording();
          audioPath = await _waitForVoiceTurn(generation);
          if (audioPath == null) continue;

          _setVoiceModeStatus('Understanding…');
          transcription = await _transcribeWithMemoryHeadroom(audioPath);
        }
        if (!_voiceModeIsCurrent(generation)) return;
        if (transcription.trim().isEmpty) continue;

        _setVoiceModeStatus('Responding…');
        queuedSpeech = await _respondWithoutInterruption(
          transcription,
          generation,
        );
      } catch (e) {
        debugPrint('ChatScreen: voice mode failed: $e');
        if (_voiceModeIsCurrent(generation)) {
          _showMessage('Voice conversation stopped: $e');
          await _stopVoiceMode();
        }
        return;
      } finally {
        if (audioPath != null) {
          try {
            final file = File(audioPath);
            if (await file.exists()) await file.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<String?> _respondWithoutInterruption(
    String text,
    int generation,
  ) async {
    await _sendMessage(text, beforeSpeech: () async {
      if (!_voiceModeIsCurrent(generation)) return;
      _voiceLevel.value = 0;
      _setVoiceModeStatus('Speaking…');
    });
    return null;
  }

  Future<String?> _waitForVoiceTurn(int generation) async {
    final detector = VoiceActivityDetector(startedAt: DateTime.now());
    while (_voiceModeIsCurrent(generation)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (!_voiceModeIsCurrent(generation)) break;
      final amplitudeDb = await _whisperService.currentAmplitudeDb;
      if (_voiceModeIsCurrent(generation)) {
        // Map ordinary speech (-50 to -10 dBFS) onto the orb's visual range.
        _voiceLevel.value = ((amplitudeDb + 50) / 40).clamp(0.0, 1.0);
      }
      final state = detector.add(amplitudeDb, DateTime.now());
      if (state == VoiceTurnState.listening) continue;

      final path = await _whisperService.stopRecording();
      if (state == VoiceTurnState.noSpeech) {
        if (path != null) {
          try {
            await File(path).delete();
          } catch (_) {}
        }
        return null;
      }
      return path;
    }

    if (await _whisperService.isRecording) {
      final path = await _whisperService.stopRecording();
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
    }
    return null;
  }

  bool _voiceModeIsCurrent(int generation) =>
      mounted && _voiceModeActive && generation == _voiceModeGeneration;

  void _setVoiceModeStatus(String status) {
    if (!mounted || !_voiceModeActive) return;
    _voiceStatus.value = status;
    if (status != 'Listening…') _voiceLevel.value = 0;
    setState(() => _voiceModeStatus = status);
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      setState(() => _isRecording = false);
      final audioPath = await _whisperService.stopRecording();
      if (audioPath == null) {
        _showMessage('Nothing was recorded.');
        return;
      }

      setState(() => _isTranscribing = true);
      try {
        final transcription = await _transcribeWithMemoryHeadroom(audioPath);
        if (!mounted) return;
        setState(() => _isTranscribing = false);
        if (transcription.isEmpty) {
          // 16 kHz, 16-bit, mono PCM: 32000 bytes/sec, minus the 44-byte
          // WAV header. Surfaced so a genuinely empty recording (mic issue)
          // is distinguishable from whisper failing on real audio.
          final bytes = await File(audioPath).length();
          final seconds = (bytes - 44) / 32000;
          _showMessage(
            'Could not make out any speech. '
            '(recorded ${seconds.toStringAsFixed(1)}s, $bytes bytes)',
          );
        } else {
          await _sendMessage(transcription);
        }
      } catch (e) {
        if (!mounted) return;
        setState(() => _isTranscribing = false);
        _showMessage('Transcription failed: $e');
      } finally {
        // Recordings are transient input, not something to keep around.
        try {
          final file = File(audioPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      return;
    }

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      _showMessage('Microphone permission is required to record.');
      if (status.isPermanentlyDenied) await openAppSettings();
      return;
    }

    try {
      await _whisperService.startRecording();
      if (mounted) setState(() => _isRecording = true);
    } catch (e) {
      _showMessage('Could not start recording: $e');
    }
  }

  Future<String> _transcribeWithMemoryHeadroom(String audioPath) async {
    await _tts.releaseForTranscription();
    return _whisperService.transcribeFromFile(audioPath);
  }

  void _scrollToBottom() {
    _followTail = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// Keeps the newest text visible during streaming.
  ///
  /// Jumps rather than animates: an animation started per token would queue up
  /// faster than it could play and the list would lag behind the text.
  void _scrollToBottomWhileStreaming() {
    if (!_followTail || _scrollScheduled) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (!_scrollController.hasClients || !_followTail) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openSettings() async {
    await _stopVoiceMode();
    if (!mounted) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ModelsPage()),
    );
    if (!mounted || changed != true) return;

    await _loadSettings();
    await _initializeLlmAfterSettingsChange();
  }

  Future<void> _initializeLlmAfterSettingsChange() async {
    // Voice/language/speed and generation settings are read lazily. Preserve
    // every resident model unless the selected LLM itself changed.
    if (!await _llmService.isStale) {
      if (_sttEnabled) {
        try {
          await _whisperService.initialize();
        } catch (e) {
          debugPrint('ChatScreen: speech-to-text unavailable: $e');
        }
      }
      return;
    }
    setState(() {
      _isModelLoading = true;
      _modelError = null;
    });
    try {
      await _llmService.reload();
    } catch (e) {
      if (mounted) setState(() => _modelError = '$e');
    } finally {
      if (mounted) setState(() => _isModelLoading = false);
    }

    if (_sttEnabled) {
      try {
        await _whisperService.initialize();
      } catch (e) {
        debugPrint('ChatScreen: speech-to-text unavailable: $e');
      }
    }
  }

  // --- UI ---

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      drawer: _buildDrawer(),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (_isModelLoading) const LinearProgressIndicator(minHeight: 2),
            if (_modelError != null) _buildModelErrorBanner(),
            Expanded(child: _buildMessageList()),
            if (_isTranscribing) _buildStatusLine('Transcribing…'),
            if (_voiceModeActive) _buildVoiceModeStatus(),
            if (_isStreaming) _buildStopButton(),
            _buildComposer(),
          ],
        ),
      ),
    );
  }

  /// A conversation header rather than a plain title bar: the assistant's
  /// gradient badge, the app name, and whichever conversation is open beneath
  /// it.
  PreferredSizeWidget _buildAppBar() {
    final theme = Theme.of(context);
    final subtitle = _currentConversation?.title;

    return AppBar(
      leadingWidth: 60,
      leading: Builder(
        builder: (context) => Padding(
          padding: const EdgeInsets.only(left: 12),
          child: _CircleIconButton(
            icon: Icons.menu,
            tooltip: 'Menu',
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
      title: Row(
        children: [
          const SparkAvatar(size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('PrivAI'),
                if (subtitle != null && subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        _CircleIconButton(
          icon: theme.brightness == Brightness.dark
              ? Icons.light_mode
              : Icons.dark_mode,
          tooltip: 'Toggle theme',
          onPressed: widget.themeToggleCallback,
        ),
        const SizedBox(width: 8),
        _CircleIconButton(
          icon: Icons.tune,
          tooltip: 'Settings & models',
          onPressed: _openSettings,
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  Widget _buildModelErrorBanner() {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
              color: theme.colorScheme.error.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber,
                size: 20, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _modelError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: _openSettings,
              child: const Text('Fix'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageList() {
    if (_messages.isEmpty) {
      final theme = Theme.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SparkAvatar(size: 64),
              const SizedBox(height: 20),
              Text(
                'Everything here runs on this device.\nSay something to begin.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) => _buildMessage(
        _messages[index],
        isLast: index == _messages.length - 1,
      ),
    );
  }

  /// Renders one message.
  ///
  /// The user's own words sit in a gradient bubble on the right; the
  /// assistant's reply gets a flat card on the left, tagged with its badge and
  /// followed by the actions that apply to a finished answer.
  Widget _buildMessage(Map<String, String> message, {required bool isLast}) {
    final theme = Theme.of(context);
    final gradients = AppGradients.of(context);
    final role = message['role'];
    final text = message['text'] ?? '';
    final maxBubbleWidth = MediaQuery.of(context).size.width * 0.78;

    if (role == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ),
      );
    }

    if (role == 'user') {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2, left: 40),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            constraints: BoxConstraints(maxWidth: maxBubbleWidth),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              gradient: gradients.bubble,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(AppTheme.radius),
                topRight: Radius.circular(AppTheme.radius),
                bottomLeft: Radius.circular(AppTheme.radius),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(color: Colors.white, height: 1.4),
            ),
          ),
        ),
      );
    }

    // Assistant reply. The first token has not always arrived by the time the
    // bubble appears, so an empty one shows that something is happening rather
    // than looking stalled.
    final streamingThis = isLast && _isStreaming;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4, right: 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: SparkAvatar(size: 26),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              decoration: BoxDecoration(
                color: gradients.bubbleColor,
                border: Border.all(color: gradients.hairline),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6),
                  topRight: Radius.circular(AppTheme.radius),
                  bottomLeft: Radius.circular(AppTheme.radius),
                  bottomRight: Radius.circular(AppTheme.radius),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (text.isEmpty && streamingThis)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else
                    SelectableText(
                      text,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurface),
                    ),
                  if (text.isNotEmpty && !streamingThis) ...[
                    Divider(height: 20, color: gradients.hairline),
                    _buildReplyActions(text),
                  ] else
                    const SizedBox(height: 4),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What you can do with a finished answer. Deliberately limited to the two
  /// actions the app can actually back: put it on the clipboard, and read it
  /// aloud with the configured voice.
  Widget _buildReplyActions(String text) {
    Widget action(IconData icon, String tooltip, VoidCallback onPressed) =>
        IconButton(
          tooltip: tooltip,
          icon: Icon(icon, size: 18),
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 32, height: 28),
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

    return Row(
      children: [
        action(Icons.content_copy_outlined, 'Copy', () async {
          await Clipboard.setData(ClipboardData(text: text));
          _showMessage('Copied to clipboard.');
        }),
        const SizedBox(width: 4),
        if (_ttsEnabled)
          action(Icons.volume_up_outlined, 'Read aloud', () => _speak(text)),
      ],
    );
  }

  /// Lets the user cut a long reply short. On-device generation can run for a
  /// while, so waiting it out should not be the only option.
  Widget _buildStopButton() => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Center(
          child: OutlinedButton.icon(
            onPressed: _stopRequested
                ? null
                : () => setState(() => _stopRequested = true),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: Text(_stopRequested ? 'Stopping…' : 'Stop generating'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            ),
          ),
        ),
      );

  Widget _buildStatusLine(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Center(
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
      );

  Widget _buildVoiceModeStatus() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.graphic_eq, size: 20),
            const SizedBox(width: 8),
            Text(_voiceModeStatus),
            const SizedBox(width: 12),
            TextButton(onPressed: _stopVoiceMode, child: const Text('Stop')),
          ],
        ),
      );

  Widget _buildComposer() {
    final theme = Theme.of(context);
    final gradients = AppGradients.of(context);
    final busy = _isProcessing || _isTranscribing;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _focusComposer,
          child: Container(
            padding: const EdgeInsets.fromLTRB(18, 4, 4, 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: gradients.hairline),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('message_composer'),
                    controller: _textController,
                    focusNode: _composerFocusNode,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.send,
                    onSubmitted: busy ? null : _sendMessage,
                    onTap: () {
                      // InputUI can be restarted by iOS after memory pressure
                      // while Flutter's node still reports focus. Explicitly
                      // reopen the platform keyboard on every composer tap.
                      SystemChannels.textInput
                          .invokeMethod<void>('TextInput.show');
                    },
                    maxLines: 5,
                    minLines: 1,
                    scrollPadding: const EdgeInsets.only(bottom: 24),
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 14),
                      hintText: 'Send message…',
                      hintStyle: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
                if (_sttEnabled && _ttsEnabled)
                  IconButton(
                    key: const ValueKey('voice_mode_button'),
                    tooltip: _voiceModeActive
                        ? 'Stop voice conversation'
                        : 'Start voice conversation',
                    icon: Icon(
                      _voiceModeActive ? Icons.stop_circle : Icons.graphic_eq,
                      color: _voiceModeActive
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: _toggleVoiceMode,
                  ),
                if (_sttEnabled)
                  IconButton(
                    tooltip: _isRecording ? 'Stop recording' : 'Record',
                    icon: Icon(
                      _isRecording ? Icons.stop : Icons.mic,
                      size: 22,
                      color: _isRecording
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    onPressed: _isTranscribing || _voiceModeActive
                        ? null
                        : _toggleRecording,
                  ),
                Padding(
                  // The row is bottom-aligned for a growing multiline field.
                  // Its 48 pt single-line height is 6 pt taller than this
                  // button, so half that difference centers the blue circle.
                  padding: const EdgeInsets.only(bottom: 3),
                  child: GradientIconButton(
                    key: const ValueKey('send_message_button'),
                    icon: Icons.send,
                    tooltip: 'Send',
                    size: 42,
                    glow: true,
                    onPressed:
                        busy ? null : () => _sendMessage(_textController.text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Reconnects Flutter's focus node to the platform text-input client.
  ///
  /// iOS can close the keyboard connection while preserving `hasFocus` (for
  /// example after submitting, navigating back, or dismissing an overlay). A
  /// plain tap then appears to do nothing because Flutter thinks the field is
  /// already focused. Explicitly requesting focus and showing text input makes
  /// the whole composer reliably recoverable.
  void _focusComposer() {
    if (!mounted) return;
    final request = ++_composerFocusRequest;

    // `requestFocus` is a no-op when the node already claims focus, even if
    // iOS discarded the associated text-input client while the app slept or a
    // route/overlay was open. Cycling focus forces EditableText to create a new
    // platform connection. The controller preserves text and selection.
    if (_composerFocusNode.hasFocus) {
      _composerFocusNode.unfocus();
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || request != _composerFocusRequest) return;
      _composerFocusNode.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            request != _composerFocusRequest ||
            !_composerFocusNode.hasFocus) {
          return;
        }
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      });
    });
  }

  Widget _buildDrawer() {
    final theme = Theme.of(context);

    return Drawer(
      child: Column(
        children: [
          _buildDrawerHeader(),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.add_comment),
                  title: const Text('New chat'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _startNewConversation();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('Settings & models'),
                  onTap: () async {
                    Navigator.pop(context);
                    await _openSettings();
                  },
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Text(
                  'History',
                  style: theme.textTheme.titleMedium,
                ),
                const Spacer(),
                if (_saveChatHistory)
                  Flexible(
                    child: Text(
                      'On this device',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          if (_saveChatHistory)
            Expanded(child: _buildHistoryList())
          else
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Chat history is turned off.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The gradient wash at the top of the drawer, echoing the accent used for
  /// the user's own messages.
  Widget _buildDrawerHeader() {
    final theme = Theme.of(context);
    final gradients = AppGradients.of(context);

    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(
        24,
        MediaQuery.of(context).padding.top + 28,
        24,
        24,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            gradients.bubble.colors.first.withValues(alpha: 0.55),
            gradients.bubble.colors.last.withValues(alpha: 0.22),
            theme.colorScheme.surface.withValues(alpha: 0),
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SparkAvatar(size: 40),
          const SizedBox(height: 14),
          Text('Private by design', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Every model runs offline, on this phone.',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.75)),
          ),
        ],
      ),
    );
  }

  /// Cached so the drawer's [FutureBuilder] is not handed a brand new future on
  /// every rebuild — that rebuilt itself in a loop and re-read the history file
  /// each time.
  Future<List<Conversation>>? _historyFuture;

  void _refreshHistory() {
    // Started outside setState and assigned in a block body: an arrow closure
    // here returns the assignment's value — the future itself — and setState
    // rejects a callback that returns one.
    final history = _conversationService.getConversations();
    setState(() {
      _historyFuture = history;
    });
  }

  Widget _buildHistoryList() {
    _historyFuture ??= _conversationService.getConversations();

    return FutureBuilder<List<Conversation>>(
      future: _historyFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final theme = Theme.of(context);
        final conversations = snapshot.data!;
        if (conversations.isEmpty) {
          return Center(
            child: Text(
              'No saved conversations yet.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          itemCount: conversations.length,
          itemBuilder: (context, index) {
            final conversation = conversations[index];
            final isCurrent = _currentConversation?.id == conversation.id;

            return ListTile(
              contentPadding: const EdgeInsets.only(left: 12, right: 4),
              leading: SparkAvatar(
                size: 30,
                icon: isCurrent ? Icons.auto_awesome : Icons.history,
              ),
              title: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                  color: isCurrent
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              subtitle: Text(
                _conversationService.formatDate(conversation.updatedAt),
                style: theme.textTheme.bodySmall,
              ),
              selected: isCurrent,
              trailing: IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: () => _confirmDelete(conversation),
              ),
              onTap: () async {
                Navigator.pop(context);
                await _openConversation(conversation.id);
              },
            );
          },
        );
      },
    );
  }

  Future<void> _confirmDelete(Conversation conversation) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete conversation'),
        content: Text('Delete "${conversation.title}"? This cannot be undone.'),
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
    if (shouldDelete != true) return;

    await _conversationService.deleteConversation(conversation.id);
    if (_currentConversation?.id == conversation.id) {
      await _llmService.clearContext();
      if (!mounted) return;
      setState(() {
        _currentConversation = null;
        _messages.clear();
      });
    }
    if (mounted) _refreshHistory();
  }
}

/// A bare icon reads as an afterthought against a near-black bar; a soft filled
/// disc gives the app bar controls the same weight as the rest of the screen.
class _CircleIconButton extends StatelessWidget {
  const _CircleIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest,
        shape: CircleBorder(
            side: BorderSide(color: AppGradients.of(context).hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 38,
            height: 38,
            child: Icon(icon, size: 19, color: theme.colorScheme.onSurface),
          ),
        ),
      ),
    );
  }
}
