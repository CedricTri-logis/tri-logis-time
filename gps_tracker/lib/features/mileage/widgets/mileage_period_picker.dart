import 'package:flutter/material.dart';

class MileagePeriodPicker extends StatelessWidget {
  final DateTime periodStart;
  final DateTime periodEnd;
  final ValueChanged<DateTimeRange> onPeriodChanged;

  const MileagePeriodPicker({
    super.key,
    required this.periodStart,
    required this.periodEnd,
    required this.onPeriodChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _PresetChip(
                  label: 'Cette semaine',
                  isSelected: _isThisWeek,
                  onTap: () => _selectThisWeek(context),
                ),
                const SizedBox(width: 8),
                _PresetChip(
                  label: 'Semaine dernière',
                  isSelected: _isLastWeek,
                  onTap: () => _selectLastWeek(context),
                ),
                const SizedBox(width: 8),
                _PresetChip(
                  label: 'Ce mois',
                  isSelected: _isThisMonth,
                  onTap: () => _selectThisMonth(context),
                ),
                const SizedBox(width: 8),
                _PresetChip(
                  label: 'Personnalisé',
                  isSelected: !_isThisWeek && !_isLastWeek && !_isThisMonth,
                  onTap: () => _selectCustom(context),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _formatPeriod(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey.shade600,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  bool get _isThisWeek {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final weekStart = DateTime(monday.year, monday.month, monday.day);
    final weekEnd = weekStart.add(const Duration(days: 7));
    return periodStart == weekStart && periodEnd == weekEnd;
  }

  bool get _isLastWeek {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final lastMonday = monday.subtract(const Duration(days: 7));
    final weekStart = DateTime(lastMonday.year, lastMonday.month, lastMonday.day);
    final weekEnd = weekStart.add(const Duration(days: 7));
    return periodStart == weekStart && periodEnd == weekEnd;
  }

  bool get _isThisMonth {
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month, 1);
    final monthEnd = DateTime(now.year, now.month + 1, 1);
    return periodStart == monthStart && periodEnd == monthEnd;
  }

  void _selectThisWeek(BuildContext context) {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final weekStart = DateTime(monday.year, monday.month, monday.day);
    onPeriodChanged(DateTimeRange(
      start: weekStart,
      end: weekStart.add(const Duration(days: 7)),
    ));
  }

  void _selectLastWeek(BuildContext context) {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final lastMonday = monday.subtract(const Duration(days: 7));
    final weekStart = DateTime(lastMonday.year, lastMonday.month, lastMonday.day);
    onPeriodChanged(DateTimeRange(
      start: weekStart,
      end: weekStart.add(const Duration(days: 7)),
    ));
  }

  void _selectThisMonth(BuildContext context) {
    final now = DateTime.now();
    onPeriodChanged(DateTimeRange(
      start: DateTime(now.year, now.month, 1),
      end: DateTime(now.year, now.month + 1, 1),
    ));
  }

  Future<void> _selectCustom(BuildContext context) async {
    final result = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      initialDateRange: DateTimeRange(start: periodStart, end: periodEnd),
    );
    if (result != null) {
      onPeriodChanged(DateTimeRange(
        start: result.start,
        end: result.end.add(const Duration(days: 1)),
      ));
    }
  }

  String _formatPeriod() {
    final start = '${periodStart.day}/${periodStart.month}/${periodStart.year}';
    final end = periodEnd.subtract(const Duration(days: 1));
    final endStr = '${end.day}/${end.month}/${end.year}';
    return '$start — $endStr';
  }
}

class _PresetChip extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: isSelected ? Colors.white : theme.colorScheme.onSurface,
        ),
      ),
      selected: isSelected,
      onSelected: (_) => onTap(),
      selectedColor: theme.colorScheme.primary,
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.compact,
    );
  }
}
