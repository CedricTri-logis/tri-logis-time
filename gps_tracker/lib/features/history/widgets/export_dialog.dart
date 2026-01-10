import 'package:flutter/material.dart';

/// Export format options
enum ExportFormat {
  csv,
  pdf,
}

/// Dialog for selecting export format and options
class ExportDialog extends StatefulWidget {
  /// Number of shifts to export
  final int shiftCount;

  /// Employee name for the export
  final String employeeName;

  /// Called when export is confirmed
  final void Function(ExportFormat format)? onExport;

  const ExportDialog({
    super.key,
    required this.shiftCount,
    required this.employeeName,
    this.onExport,
  });

  /// Show the export dialog
  static Future<ExportFormat?> show(
    BuildContext context, {
    required int shiftCount,
    required String employeeName,
  }) async {
    return showDialog<ExportFormat>(
      context: context,
      builder: (context) => ExportDialog(
        shiftCount: shiftCount,
        employeeName: employeeName,
        onExport: (format) => Navigator.of(context).pop(format),
      ),
    );
  }

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  ExportFormat _selectedFormat = ExportFormat.csv;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Export Shifts'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Export ${widget.shiftCount} shifts for ${widget.employeeName}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            'Select format:',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 12),
          _buildFormatOption(
            format: ExportFormat.csv,
            title: 'CSV',
            subtitle: 'Spreadsheet format for Excel, Google Sheets',
            icon: Icons.table_chart,
          ),
          const SizedBox(height: 8),
          _buildFormatOption(
            format: ExportFormat.pdf,
            title: 'PDF',
            subtitle: 'Formatted report for printing and sharing',
            icon: Icons.picture_as_pdf,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => widget.onExport?.call(_selectedFormat),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Export'),
        ),
      ],
    );
  }

  Widget _buildFormatOption({
    required ExportFormat format,
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    final isSelected = _selectedFormat == format;

    return InkWell(
      onTap: () => setState(() => _selectedFormat = format),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
          color: isSelected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
              : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 32,
              color: isSelected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Radio<ExportFormat>(
              value: format,
              groupValue: _selectedFormat,
              onChanged: (value) {
                if (value != null) setState(() => _selectedFormat = value);
              },
            ),
          ],
        ),
      ),
    );
  }
}
