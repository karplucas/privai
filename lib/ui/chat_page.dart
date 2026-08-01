import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/app_settings.dart';
import '../services/conversation_service.dart';
import '../services/llm_service.dart';
import '../services/tts_router.dart';
import '../services/whisper_service.dart';
import 'models_page.dart';
import 'theme.dart';

/// The main chat screen.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.themeToggleCallback});

  final VoidCallback themeToggleCallback;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

class ChatScreenState extends State<ChatScreen> {
  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
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

  /// Non-null when the model could not be loaded; shown as a banner with a
  /// shortcut to the models page.
  String? _modelError;

  Conversation? _currentConversation;

  @override
  void initState() {
    super.initState();
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
    _textController.dispose();
    _scrollController.dispose();
    // The services are process-wide singletons shared with the settings screen,
    // so they are deliberately not disposed here — the previous version tore
    // them down whenever this widget went away, leaving the app with a dead
    // recorder and audio player.
    super.dispose();
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

  Future<void> _sendMessage(String text) async {
    final userText = text.trim();
    if (userText.isEmpty || _isProcessing) return;

    if (!_llmService.isReady) {
      _showMessage(_modelError ?? 'The language model is still loading.');
      return;
    }

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
    _scrollToBottom();

    // Held by reference rather than by index: starting a new conversation
    // mid-stream clears the list, and an index into it would then throw.
    // Writing to a detached map is simply invisible.
    final replyMessage = _messages.last;
    final buffer = StringBuffer();
    var failed = false;

    try {
      await for (final chunk in _llmService.generateResponseStream(userText)) {
        if (!mounted) return;
        // Leaving the loop cancels the underlying subscription, which stops the
        // model rather than just hiding its output.
        if (_stopRequested) break;
        buffer.write(chunk);
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
        replyMessage['text'] = partial.isEmpty ? message : '$partial\n\n$message';
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

    await _saveCurrentConversation();

    final reply = buffer.toString();
    if (_ttsEnabled && !failed && !stopped && reply.trim().isNotEmpty) {
      // Spoken once the full reply is known; synthesising per token would
      // produce disjointed audio. The router picks the configured engine and,
      // for Chatterbox, frees the language model while it runs.
      await _tts.speak(reply);
    }
  }

  bool _looksLikeContextOverflow(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('context') ||
        message.contains('token') ||
        message.contains('max_tokens');
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
        final transcription =
            await _whisperService.transcribeFromFile(audioPath);
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
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const ModelsPage()),
    );
    if (!mounted || changed != true) return;

    // Settings that alter how a model is loaded only take effect on a reload.
    await _loadSettings();
    await _initializeLlmAfterSettingsChange();
  }

  Future<void> _initializeLlmAfterSettingsChange() async {
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

    if (_ttsEnabled) {
      try {
        await _tts.applySettingsChange();
      } catch (e) {
        debugPrint('ChatScreen: text-to-speech unavailable: $e');
      }
    }
    if (_sttEnabled) {
      try {
        await _whisperService.initialize(force: true);
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
            if (_isStreaming) _buildStopButton(),
          ],
        ),
      ),
      // Kept out of `body` so the default SnackBar (which floats above
      // bottomNavigationBar) doesn't render on top of the input field.
      bottomNavigationBar: SafeArea(top: false, child: _buildComposer()),
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
          border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.35)),
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
          action(Icons.volume_up_outlined, 'Read aloud', () => _tts.speak(text)),
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

  Widget _buildComposer() {
    final theme = Theme.of(context);
    final gradients = AppGradients.of(context);
    final busy = _isProcessing || _isTranscribing;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
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
                controller: _textController,
                enabled: !busy,
                textInputAction: TextInputAction.send,
                onSubmitted: _sendMessage,
                maxLines: 5,
                minLines: 1,
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
                onPressed: _isTranscribing ? null : _toggleRecording,
              ),
            GradientIconButton(
              icon: Icons.send,
              tooltip: 'Send',
              size: 42,
              glow: true,
              onPressed: busy ? null : () => _sendMessage(_textController.text),
            ),
          ],
        ),
      ),
    );
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
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.75)),
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
              contentPadding:
                  const EdgeInsets.only(left: 12, right: 4),
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
      await _startNewConversation();
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
        shape: CircleBorder(side: BorderSide(color: AppGradients.of(context).hairline)),
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
