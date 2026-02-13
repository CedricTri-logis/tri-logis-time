import 'package:flutter/material.dart';

import '../models/cleaning_session.dart';
import '../models/scan_result.dart';
import '../models/studio.dart';

/// Dialog displayed after a QR scan showing the result.
class ScanResultDialog extends StatelessWidget {
  final ScanResult result;

  const ScanResultDialog({super.key, required this.result});

  /// Show the dialog and wait for dismissal.
  static Future<void> show(BuildContext context, ScanResult result) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ScanResultDialog(result: result),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (result.success) {
      return _SuccessDialog(result: result);
    } else {
      return _ErrorDialog(result: result);
    }
  }
}

class _SuccessDialog extends StatelessWidget {
  final ScanResult result;

  const _SuccessDialog({required this.result});

  String _formatDuration(double? minutes) {
    if (minutes == null) return '--';
    final totalMinutes = minutes.round();
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h > 0) return '${h}h ${m}min';
    return '${m} min';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = result.session!;
    final isCompleted = session.status != CleaningSessionStatus.inProgress;

    return AlertDialog(
      icon: Icon(
        Icons.check_circle,
        color: Colors.green,
        size: 48,
      ),
      title: Text(
        isCompleted ? 'Session terminée' : 'Session démarrée',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Studio info
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                Text(
                  session.studioNumber ?? '',
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  session.buildingName ?? '',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (session.studioType != null) ...[
                  const SizedBox(height: 4),
                  _StudioTypeBadge(type: session.studioType!),
                ],
              ],
            ),
          ),

          // Duration (for completed sessions)
          if (isCompleted && session.durationMinutes != null) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.timer_outlined, size: 20),
                const SizedBox(width: 8),
                Text(
                  _formatDuration(session.durationMinutes),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],

          // Warning (for flagged sessions)
          if (result.warning != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.flag, color: Colors.orange, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      result.warning!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.orange.shade800,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _ErrorDialog extends StatelessWidget {
  final ScanResult result;

  const _ErrorDialog({required this.result});

  IconData get _errorIcon {
    switch (result.errorType) {
      case ScanErrorType.invalidQr:
        return Icons.qr_code_scanner;
      case ScanErrorType.studioInactive:
        return Icons.block;
      case ScanErrorType.noActiveShift:
        return Icons.work_off;
      case ScanErrorType.sessionExists:
        return Icons.warning_amber;
      case ScanErrorType.noActiveSession:
        return Icons.search_off;
      case null:
        return Icons.error_outline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      icon: Icon(
        _errorIcon,
        color: theme.colorScheme.error,
        size: 48,
      ),
      title: const Text('Erreur'),
      content: Text(
        result.errorMessage ?? 'Une erreur est survenue',
        textAlign: TextAlign.center,
        style: theme.textTheme.bodyLarge,
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

class _StudioTypeBadge extends StatelessWidget {
  final StudioType type;

  const _StudioTypeBadge({required this.type});

  Color get _color {
    switch (type) {
      case StudioType.unit:
        return Colors.blue;
      case StudioType.commonArea:
        return Colors.teal;
      case StudioType.conciergerie:
        return Colors.purple;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _color.withValues(alpha: 0.3)),
      ),
      child: Text(
        type.displayName,
        style: TextStyle(
          fontSize: 12,
          color: _color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
