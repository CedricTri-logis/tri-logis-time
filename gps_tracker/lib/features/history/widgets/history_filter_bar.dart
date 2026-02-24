import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers/history_filter_provider.dart';

/// A filter bar widget for history screens
///
/// Provides date range selection and search functionality.
class HistoryFilterBar extends ConsumerStatefulWidget {
  /// Whether to show the search field
  final bool showSearch;

  /// Whether to show the date range picker
  final bool showDateRange;

  /// Callback when filters change
  final VoidCallback? onFilterChanged;

  /// Hint text for search field
  final String searchHint;

  const HistoryFilterBar({
    super.key,
    this.showSearch = true,
    this.showDateRange = true,
    this.onFilterChanged,
    this.searchHint = 'Rechercher...',
  });

  @override
  ConsumerState<HistoryFilterBar> createState() => _HistoryFilterBarState();
}

class _HistoryFilterBarState extends ConsumerState<HistoryFilterBar> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Initialize search with current filter state
    final filterState = ref.read(historyFilterProvider);
    _searchController.text = filterState.searchQuery;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filterState = ref.watch(historyFilterProvider);
    final theme = Theme.of(context);

    return Column(
      children: [
        if (widget.showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: widget.searchHint,
                prefixIcon: const Icon(Icons.search),
                suffixIcon: filterState.searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          ref.read(historyFilterProvider.notifier).clearSearch();
                          widget.onFilterChanged?.call();
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                filled: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
              onChanged: (value) {
                ref.read(historyFilterProvider.notifier).setSearchQuery(value);
                widget.onFilterChanged?.call();
              },
            ),
          ),
        if (widget.showDateRange)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _buildQuickFilterChip(
                  context,
                  label: '7 jours',
                  isSelected: _isLast7DaysSelected(filterState),
                  onTap: () {
                    ref.read(historyFilterProvider.notifier).setLast7Days();
                    widget.onFilterChanged?.call();
                  },
                ),
                const SizedBox(width: 8),
                _buildQuickFilterChip(
                  context,
                  label: '30 jours',
                  isSelected: _isLast30DaysSelected(filterState),
                  onTap: () {
                    ref.read(historyFilterProvider.notifier).setLast30Days();
                    widget.onFilterChanged?.call();
                  },
                ),
                const SizedBox(width: 8),
                _buildQuickFilterChip(
                  context,
                  label: 'Ce mois',
                  isSelected: _isCurrentMonthSelected(filterState),
                  onTap: () {
                    ref.read(historyFilterProvider.notifier).setCurrentMonth();
                    widget.onFilterChanged?.call();
                  },
                ),
                const SizedBox(width: 8),
                _buildDateRangeChip(context, filterState, theme),
                if (filterState.startDate != null ||
                    filterState.endDate != null) ...[
                  const SizedBox(width: 8),
                  ActionChip(
                    avatar: const Icon(Icons.clear, size: 18),
                    label: const Text('Effacer'),
                    onPressed: () {
                      ref
                          .read(historyFilterProvider.notifier)
                          .clearDateRange();
                      widget.onFilterChanged?.call();
                    },
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildQuickFilterChip(
    BuildContext context, {
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onTap(),
    );
  }

  Widget _buildDateRangeChip(
    BuildContext context,
    HistoryFilterState filterState,
    ThemeData theme,
  ) {
    final hasCustomRange = filterState.startDate != null ||
        filterState.endDate != null;
    final isCustom = hasCustomRange &&
        !_isLast7DaysSelected(filterState) &&
        !_isLast30DaysSelected(filterState) &&
        !_isCurrentMonthSelected(filterState);

    return ActionChip(
      avatar: Icon(
        Icons.date_range,
        size: 18,
        color: isCustom ? theme.colorScheme.onPrimary : null,
      ),
      label: Text(
        isCustom ? _formatDateRange(filterState) : 'Période personnalisée',
      ),
      backgroundColor: isCustom ? theme.colorScheme.primary : null,
      labelStyle: isCustom
          ? TextStyle(color: theme.colorScheme.onPrimary)
          : null,
      onPressed: () => _showDateRangePicker(context),
    );
  }

  Future<void> _showDateRangePicker(BuildContext context) async {
    final filterState = ref.read(historyFilterProvider);
    final now = DateTime.now();

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: now,
      initialDateRange: filterState.startDate != null && filterState.endDate != null
          ? DateTimeRange(
              start: filterState.startDate!,
              end: filterState.endDate!,
            )
          : DateTimeRange(
              start: now.subtract(const Duration(days: 30)),
              end: now,
            ),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme,
          ),
          child: child!,
        );
      },
    );

    if (picked != null) {
      ref.read(historyFilterProvider.notifier).setDateRange(
            picked.start,
            DateTime(
              picked.end.year,
              picked.end.month,
              picked.end.day,
              23,
              59,
              59,
            ),
          );
      widget.onFilterChanged?.call();
    }
  }

  bool _isLast7DaysSelected(HistoryFilterState state) {
    if (state.startDate == null || state.endDate == null) return false;
    final now = DateTime.now();
    final expected = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 7));
    return _isSameDay(state.startDate!, expected) &&
        _isSameDay(state.endDate!, DateTime(now.year, now.month, now.day));
  }

  bool _isLast30DaysSelected(HistoryFilterState state) {
    if (state.startDate == null || state.endDate == null) return false;
    final now = DateTime.now();
    final expected = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 30));
    return _isSameDay(state.startDate!, expected) &&
        _isSameDay(state.endDate!, DateTime(now.year, now.month, now.day));
  }

  bool _isCurrentMonthSelected(HistoryFilterState state) {
    if (state.startDate == null || state.endDate == null) return false;
    final now = DateTime.now();
    final firstOfMonth = DateTime(now.year, now.month, 1);
    final lastOfMonth = DateTime(now.year, now.month + 1, 0);
    return _isSameDay(state.startDate!, firstOfMonth) &&
        _isSameDay(state.endDate!, lastOfMonth);
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  String _formatDateRange(HistoryFilterState state) {
    final dateFormat = DateFormat.MMMd();
    if (state.startDate != null && state.endDate != null) {
      return '${dateFormat.format(state.startDate!)} - ${dateFormat.format(state.endDate!)}';
    }
    if (state.startDate != null) {
      return 'Depuis le ${dateFormat.format(state.startDate!)}';
    }
    if (state.endDate != null) {
      return 'Jusqu\'au ${dateFormat.format(state.endDate!)}';
    }
    return 'Période personnalisée';
  }
}
