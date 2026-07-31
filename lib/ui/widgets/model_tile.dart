import 'package:flutter/material.dart';

import '../../models/model_spec.dart';
import '../../services/huggingface_service.dart';
import '../theme.dart';

/// Per-model UI state tracked by the models page.
@immutable
class ModelTileState {
  const ModelTileState({
    this.downloaded = false,
    this.access,
    this.checkingAccess = false,
    this.progress,
    this.cancellationToken,
    this.error,
  });

  final bool downloaded;

  /// Last known license/authentication status. Null when it has not been
  /// checked, or when the model is not gated.
  final HfAccessResult? access;

  final bool checkingAccess;

  /// Non-null while a download is running.
  final DownloadProgress? progress;

  final CancellationToken? cancellationToken;

  final String? error;

  bool get isDownloading => cancellationToken != null;

  ModelTileState copyWith({
    bool? downloaded,
    HfAccessResult? access,
    bool? checkingAccess,
    DownloadProgress? progress,
    CancellationToken? cancellationToken,
    String? error,
    bool clearAccess = false,
    bool clearProgress = false,
    bool clearToken = false,
    bool clearError = false,
  }) =>
      ModelTileState(
        downloaded: downloaded ?? this.downloaded,
        access: clearAccess ? null : (access ?? this.access),
        checkingAccess: checkingAccess ?? this.checkingAccess,
        progress: clearProgress ? null : (progress ?? this.progress),
        cancellationToken:
            clearToken ? null : (cancellationToken ?? this.cancellationToken),
        error: clearError ? null : (error ?? this.error),
      );
}

/// One row in the model list, rendering whichever action is currently possible:
/// select, download, sign in, review the license, cancel, or delete.
class ModelTile extends StatelessWidget {
  const ModelTile({
    super.key,
    required this.model,
    required this.state,
    required this.isSelected,
    required this.signedIn,
    required this.onDownload,
    required this.onCancel,
    required this.onDelete,
    required this.onSelect,
    required this.onReviewLicense,
    required this.onSignIn,
    required this.onRetryCheck,
  });

  final ModelSpec model;
  final ModelTileState state;
  final bool isSelected;
  final bool signedIn;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onDelete;
  final VoidCallback onSelect;
  final VoidCallback onReviewLicense;
  final VoidCallback onSignIn;
  final VoidCallback onRetryCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Sits inside the settings page's section card, so this is a nested panel
    // rather than a card of its own: a slightly raised fill, and the accent
    // border reserved for whichever model is actually in use.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary.withValues(alpha: 0.55)
                : AppGradients.of(context).hairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isSelected)
                  SparkAvatar(size: 30, icon: _icon)
                else
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: theme.colorScheme.surface,
                      border: Border.all(color: AppGradients.of(context).hairline),
                    ),
                    child: Icon(
                      _icon,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(model.name, style: theme.textTheme.titleSmall),
                      const SizedBox(height: 2),
                      Text(
                        '${model.size} • ${model.description}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Icon(
                      Icons.check_circle,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _statusLine(context),
            const SizedBox(height: 6),
            _actions(context),
          ],
        ),
      ),
    );
  }

  IconData get _icon => switch (model.kind) {
        ModelKind.llm => Icons.psychology,
        ModelKind.tts => Icons.record_voice_over,
        ModelKind.stt => Icons.mic,
      };

  Widget _statusLine(BuildContext context) {
    final theme = Theme.of(context);
    final progress = state.progress;

    if (state.isDownloading) {
      final fraction = progress?.fraction;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(value: fraction, minHeight: 5),
          ),
          const SizedBox(height: 4),
          Text(
            fraction == null
                ? 'Downloading… ${_formatBytes(progress?.received ?? 0)}'
                : 'Downloading… ${(fraction * 100).toStringAsFixed(0)}% '
                    '(${_formatBytes(progress!.received)} of '
                    '${_formatBytes(progress.total!)})',
            style: theme.textTheme.bodySmall,
          ),
        ],
      );
    }

    if (state.downloaded) {
      return _badge(
        context,
        Icons.download_done,
        'Downloaded',
        theme.colorScheme.primary,
      );
    }

    if (state.checkingAccess) {
      return Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
          Text('Checking license…', style: theme.textTheme.bodySmall),
        ],
      );
    }

    if (state.error != null) {
      return _badge(
        context,
        Icons.error_outline,
        state.error!,
        theme.colorScheme.error,
      );
    }

    if (!model.gated) {
      return _badge(
        context,
        Icons.lock_open,
        model.license == null
            ? 'Open download'
            : 'Open download • ${model.license}',
        theme.colorScheme.onSurfaceVariant,
      );
    }

    return switch (state.access?.status) {
      HfAccessStatus.granted => _badge(
          context,
          Icons.verified,
          '${model.license ?? 'License'} accepted — ready to download',
          theme.colorScheme.primary,
        ),
      HfAccessStatus.licenseRequired => _badge(
          context,
          Icons.gavel,
          'You must accept the ${model.license ?? 'license'} on Hugging Face '
              'before downloading',
          theme.colorScheme.error,
        ),
      HfAccessStatus.authenticationRequired => _badge(
          context,
          Icons.lock,
          'Sign in to Hugging Face to check access',
          theme.colorScheme.error,
        ),
      HfAccessStatus.notFound => _badge(
          context,
          Icons.help_outline,
          state.access?.message ?? 'Not available on Hugging Face',
          theme.colorScheme.error,
        ),
      HfAccessStatus.networkError => _badge(
          context,
          Icons.wifi_off,
          'Could not reach Hugging Face',
          theme.colorScheme.onSurfaceVariant,
        ),
      null => _badge(
          context,
          Icons.gavel,
          'Gated — requires accepting the ${model.license ?? 'license'}',
          theme.colorScheme.onSurfaceVariant,
        ),
    };
  }

  Widget _badge(
    BuildContext context,
    IconData icon,
    String label,
    Color color,
  ) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      );

  Widget _actions(BuildContext context) {
    if (state.isDownloading) {
      return Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: onCancel,
          icon: const Icon(Icons.close),
          label: const Text('Cancel'),
        ),
      );
    }

    if (state.downloaded) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Delete'),
          ),
          const SizedBox(width: 8),
          if (!isSelected)
            FilledButton(onPressed: onSelect, child: const Text('Use this'))
          else
            const TextButton(onPressed: null, child: Text('In use')),
        ],
      );
    }

    if (state.checkingAccess) {
      return const SizedBox.shrink();
    }

    // Ungated models can be fetched straight away.
    if (!model.gated) {
      return Align(
        alignment: Alignment.centerRight,
        child: FilledButton.icon(
          onPressed: onDownload,
          icon: const Icon(Icons.download),
          label: const Text('Download'),
        ),
      );
    }

    // Gated models: the download button only appears once Hugging Face confirms
    // the account has accepted the repository's terms.
    return switch (state.access?.status) {
      HfAccessStatus.granted => Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onDownload,
            icon: const Icon(Icons.download),
            label: const Text('Download'),
          ),
        ),
      HfAccessStatus.authenticationRequired => Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onSignIn,
            icon: const Icon(Icons.login),
            label: const Text('Sign in'),
          ),
        ),
      HfAccessStatus.networkError => Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton.icon(
            onPressed: onRetryCheck,
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
          ),
        ),
      _ => Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: onRetryCheck,
              child: const Text('Re-check'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: signedIn ? onReviewLicense : onSignIn,
              icon: const Icon(Icons.gavel),
              label: Text(signedIn ? 'Review license' : 'Sign in'),
            ),
          ],
        ),
    };
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    const units = ['KB', 'MB', 'GB'];
    var value = bytes / 1024;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
  }
}
