import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/huggingface_service.dart';

/// Presents the Hugging Face sign-in options and returns true when a token was
/// stored.
Future<bool> showHfSignInSheet(
  BuildContext context,
  HuggingFaceService service,
) async {
  final result = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: _HfSignInSheet(service: service),
    ),
  );
  return result ?? false;
}

class _HfSignInSheet extends StatefulWidget {
  const _HfSignInSheet({required this.service});

  final HuggingFaceService service;

  @override
  State<_HfSignInSheet> createState() => _HfSignInSheetState();
}

class _HfSignInSheetState extends State<_HfSignInSheet> {
  final TextEditingController _tokenController = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is HfDownloadException ? e.message : '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Connect to Hugging Face', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Gated models — including Google\'s Gemma releases — are only '
              'downloadable by an account that has accepted their terms.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            if (widget.service.isOAuthConfigured) ...[
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(widget.service.signInWithOAuth),
                icon: const Icon(Icons.login),
                label: const Text('Sign in with Hugging Face'),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text('or', style: theme.textTheme.bodySmall),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 16),
            ],
            Text('Use an access token', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                style: theme.textTheme.bodySmall,
                children: [
                  const TextSpan(
                    text: 'Create a token with read access at ',
                  ),
                  TextSpan(
                    text: 'huggingface.co/settings/tokens',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      decoration: TextDecoration.underline,
                    ),
                    recognizer: TapGestureRecognizer()
                      ..onTap = () => launchUrl(
                            Uri.parse('https://huggingface.co/settings/tokens'),
                            mode: LaunchMode.externalApplication,
                          ),
                  ),
                  const TextSpan(text: ' and paste it below.'),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Access token',
                hintText: 'hf_…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submitToken(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed:
                      _busy ? null : () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _submitToken,
                  child: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save token'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _submitToken() {
    _run(() => widget.service.signInWithAccessToken(_tokenController.text));
  }
}
