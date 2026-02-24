import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Modal bottom sheet for sharing a generated mileage PDF report.
class ReportShareSheet extends StatelessWidget {
  final String filePath;

  const ReportShareSheet({required this.filePath, super.key});

  static Future<void> show(BuildContext context, String filePath) {
    return showModalBottomSheet<void>(
      context: context,
      builder: (context) => ReportShareSheet(filePath: filePath),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outline.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          const Icon(
            Icons.check_circle,
            size: 64,
            color: Colors.green,
          ),
          const SizedBox(height: 16),
          Text(
            'Rapport prêt',
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Votre rapport de kilométrage a été généré.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                Share.shareXFiles([XFile(filePath)]);
              },
              icon: const Icon(Icons.share),
              label: const Text('Partager'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Terminé'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
