import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'theme.dart';

/// Full-screen presentation for an ongoing hands-free conversation.
class VoiceConversationPage extends StatefulWidget {
  const VoiceConversationPage({
    super.key,
    required this.status,
    required this.level,
    required this.active,
    required this.onStop,
  });

  final ValueListenable<String> status;
  final ValueListenable<double> level;
  final ValueListenable<bool> active;
  final Future<void> Function() onStop;

  @override
  State<VoiceConversationPage> createState() => _VoiceConversationPageState();
}

class _VoiceConversationPageState extends State<VoiceConversationPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    widget.active.addListener(_closeWhenStopped);
  }

  void _closeWhenStopped() {
    if (widget.active.value || !mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    widget.active.removeListener(_closeWhenStopped);
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await widget.onStop();
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gradients = AppGradients.of(context);

    return PopScope(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && widget.active.value) widget.onStop();
      },
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton.filledTonal(
                    key: const ValueKey('close_voice_conversation'),
                    tooltip: 'End voice conversation',
                    onPressed: _close,
                    icon: const Icon(Icons.close),
                  ),
                ),
                const Spacer(flex: 2),
                AnimatedBuilder(
                  animation: Listenable.merge([
                    _pulse,
                    widget.status,
                    widget.level,
                  ]),
                  builder: (context, _) {
                    final listening = widget.status.value == 'Listening…';
                    final monitoring =
                        listening || widget.status.value == 'Responding…';
                    final micLevel = monitoring ? widget.level.value : 0.0;
                    final idlePulse =
                        (math.sin(_pulse.value * math.pi) + 1) / 2;
                    final scale = 1 + micLevel * 0.22 + idlePulse * 0.025;
                    final glow = 0.22 + micLevel * 0.35 + idlePulse * 0.08;

                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        key: const ValueKey('voice_orb'),
                        width: 210,
                        height: 210,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: gradients.accent,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.accent.withValues(alpha: glow),
                              blurRadius: 56 + micLevel * 30,
                              spreadRadius: 8 + micLevel * 12,
                            ),
                          ],
                        ),
                        child: Icon(
                          listening ? Icons.graphic_eq : Icons.auto_awesome,
                          size: 72,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 64),
                ValueListenableBuilder<String>(
                  valueListenable: widget.status,
                  builder: (context, status, _) => AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    child: Text(
                      status,
                      key: ValueKey(status),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Speak naturally. I’ll respond when you pause.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(flex: 3),
                FilledButton.tonalIcon(
                  key: const ValueKey('stop_voice_conversation'),
                  onPressed: _close,
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('End conversation'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 14,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
