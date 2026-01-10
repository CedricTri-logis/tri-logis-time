import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/team_dashboard_state.dart';

/// Widget for selecting date range preset or custom range.
///
/// Shows:
/// - Preset buttons (Today, This Week, This Month)
/// - Custom date picker option
/// - Current date range display
class DateRangePicker extends StatelessWidget {
  final DateRangePreset selectedPreset;
  final DateTimeRange dateRange;
  final ValueChanged<DateRangePreset> onPresetSelected;
  final ValueChanged<DateTimeRange> onCustomRangeSelected;

  const DateRangePicker({
    super.key,
    required this.selectedPreset,
    required this.dateRange,
    required this.onPresetSelected,
    required this.onCustomRangeSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Preset buttons
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: DateRangePreset.values
              .where((p) => p != DateRangePreset.custom)
              .map((preset) => _PresetChip(
                    preset: preset,
                    isSelected: selectedPreset == preset,
                    onTap: () => onPresetSelected(preset),
                  ))
              .toList(),
        ),
        const SizedBox(height: 12),

        // Current range display / custom picker
        InkWell(
          onTap: () => _showDateRangePicker(context),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: selectedPreset == DateRangePreset.custom
                  ? colorScheme.primaryContainer
                  : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selectedPreset == DateRangePreset.custom
                    ? colorScheme.primary
                    : Colors.transparent,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.calendar_today,
                  size: 16,
                  color: selectedPreset == DateRangePreset.custom
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDateRange(dateRange),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: selectedPreset == DateRangePreset.custom
                        ? colorScheme.onPrimaryContainer
                        : colorScheme.onSurfaceVariant,
                    fontWeight: selectedPreset == DateRangePreset.custom
                        ? FontWeight.w600
                        : null,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.edit,
                  size: 14,
                  color: selectedPreset == DateRangePreset.custom
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatDateRange(DateTimeRange range) {
    final formatter = DateFormat('MMM d');
    final start = formatter.format(range.start);
    final end = formatter.format(range.end);

    if (_isSameDay(range.start, range.end)) {
      return start;
    }
    return '$start - $end';
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  Future<void> _showDateRangePicker(BuildContext context) async {
    final colorScheme = Theme.of(context).colorScheme;

    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
      initialDateRange: dateRange,
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: colorScheme,
          ),
          child: child!,
        );
      },
    );

    if (result != null) {
      onCustomRangeSelected(result);
    }
  }
}

class _PresetChip extends StatelessWidget {
  final DateRangePreset preset;
  final bool isSelected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.preset,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return ChoiceChip(
      label: Text(preset.label),
      selected: isSelected,
      onSelected: (_) => onTap(),
      selectedColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(
        color: isSelected
            ? colorScheme.onPrimaryContainer
            : colorScheme.onSurfaceVariant,
        fontWeight: isSelected ? FontWeight.w600 : null,
      ),
    );
  }
}

/// Compact date range display for tight spaces.
class DateRangeDisplay extends StatelessWidget {
  final DateTimeRange dateRange;
  final VoidCallback? onTap;

  const DateRangeDisplay({
    super.key,
    required this.dateRange,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formatter = DateFormat('MMM d');

    return InkWell(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.date_range,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            '${formatter.format(dateRange.start)} - ${formatter.format(dateRange.end)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
