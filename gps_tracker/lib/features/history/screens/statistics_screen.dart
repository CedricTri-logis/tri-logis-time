import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../shared/utils/timezone_formatter.dart';
import '../models/history_statistics.dart';
import '../providers/history_filter_provider.dart';
import '../providers/history_statistics_provider.dart';
import '../widgets/history_filter_bar.dart';
import '../widgets/statistics_card.dart';
import 'employee_history_screen.dart';

/// Screen displaying statistics for an individual employee or team
class StatisticsScreen extends ConsumerStatefulWidget {
  final String? employeeId;
  final String? employeeName;
  final bool showTeamStats;

  const StatisticsScreen({
    super.key,
    this.employeeId,
    this.employeeName,
    this.showTeamStats = false,
  });

  /// Create an employee statistics screen
  factory StatisticsScreen.employee({
    Key? key,
    required String employeeId,
    required String employeeName,
  }) {
    return StatisticsScreen(
      key: key,
      employeeId: employeeId,
      employeeName: employeeName,
      showTeamStats: false,
    );
  }

  /// Create a team statistics screen
  factory StatisticsScreen.team({Key? key}) {
    return StatisticsScreen(
      key: key,
      showTeamStats: true,
    );
  }

  @override
  ConsumerState<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends ConsumerState<StatisticsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(historyFilterProvider.notifier).clearAll();
      _loadStatistics();
    });
  }

  void _loadStatistics() {
    final filterState = ref.read(historyFilterProvider);

    if (widget.showTeamStats) {
      ref.read(teamStatisticsProvider.notifier).load(
            startDate: filterState.startDate,
            endDate: filterState.endDate,
          );
    } else if (widget.employeeId != null) {
      ref.read(employeeStatisticsProvider.notifier).loadForEmployee(
            widget.employeeId!,
            startDate: filterState.startDate,
            endDate: filterState.endDate,
          );
    }
  }

  void _navigateToShifts() {
    if (widget.employeeId == null || widget.employeeName == null) return;

    // Navigate to employee history - the filter provider state
    // will be used when the history screen loads
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => EmployeeHistoryScreen(
          employeeId: widget.employeeId!,
          employeeName: widget.employeeName!,
        ),
      ),
    );
  }

  void _onFilterChanged() {
    final filterState = ref.read(historyFilterProvider);

    if (widget.showTeamStats) {
      ref.read(teamStatisticsProvider.notifier).applyDateFilter(
            startDate: filterState.startDate,
            endDate: filterState.endDate,
          );
    } else {
      ref.read(employeeStatisticsProvider.notifier).applyDateFilter(
            startDate: filterState.startDate,
            endDate: filterState.endDate,
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFilters = ref.watch(hasActiveFiltersProvider);
    final filterState = ref.watch(historyFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.showTeamStats ? 'Team Statistics' : widget.employeeName ?? 'Statistics'),
            if (!widget.showTeamStats)
              Text(
                'Statistics',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        actions: [
          if (hasFilters)
            IconButton(
              icon: const Icon(Icons.filter_alt_off),
              tooltip: 'Clear Filters',
              onPressed: () {
                ref.read(historyFilterProvider.notifier).clearAll();
                _loadStatistics();
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadStatistics,
          ),
        ],
      ),
      floatingActionButton: !widget.showTeamStats && widget.employeeId != null
          ? FloatingActionButton.extended(
              onPressed: _navigateToShifts,
              icon: const Icon(Icons.list),
              label: const Text('View Shifts'),
            )
          : null,
      body: Column(
        children: [
          // Filter bar
          HistoryFilterBar(
            showSearch: false,
            showDateRange: true,
            onFilterChanged: _onFilterChanged,
          ),
          // Content
          Expanded(
            child: widget.showTeamStats
                ? _buildTeamContent(theme, filterState)
                : _buildEmployeeContent(theme, filterState),
          ),
        ],
      ),
    );
  }

  Widget _buildEmployeeContent(ThemeData theme, HistoryFilterState filterState) {
    final state = ref.watch(employeeStatisticsProvider);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadStatistics,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final statistics = state.statistics;
    if (statistics == null || !statistics.hasData) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.analytics_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No statistics available',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (filterState.hasFilters) ...[
              const SizedBox(height: 8),
              Text(
                'Try adjusting your date range',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Period info
          if (filterState.hasFilters)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildPeriodInfo(theme, filterState),
            ),
          // Main statistics card
          StatisticsCard(
            statistics: statistics,
            title: 'Summary',
          ),
          const SizedBox(height: 16),
          // Detailed breakdown
          _buildDetailedStats(theme, statistics),
        ],
      ),
    );
  }

  Widget _buildTeamContent(ThemeData theme, HistoryFilterState filterState) {
    final state = ref.watch(teamStatisticsProvider);

    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline,
                size: 48,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                state.error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _loadStatistics,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    final statistics = state.statistics;
    if (statistics == null || !statistics.hasData) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.analytics_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No team statistics available',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (filterState.hasFilters) ...[
              const SizedBox(height: 8),
              Text(
                'Try adjusting your date range',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Period info
          if (filterState.hasFilters)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildPeriodInfo(theme, filterState),
            ),
          // Main statistics card
          TeamStatisticsCard(
            statistics: statistics,
            title: 'Team Summary',
          ),
          const SizedBox(height: 16),
          // Detailed breakdown
          _buildTeamDetailedStats(theme, statistics),
        ],
      ),
    );
  }

  Widget _buildPeriodInfo(ThemeData theme, HistoryFilterState filterState) {
    final dateFormat = DateFormat.MMMd();
    String periodText;

    if (filterState.startDate != null && filterState.endDate != null) {
      periodText =
          '${dateFormat.format(filterState.startDate!)} - ${dateFormat.format(filterState.endDate!)}';
    } else if (filterState.startDate != null) {
      periodText = 'From ${dateFormat.format(filterState.startDate!)}';
    } else if (filterState.endDate != null) {
      periodText = 'Until ${dateFormat.format(filterState.endDate!)}';
    } else {
      periodText = 'All time';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.date_range,
            size: 16,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 8),
          Text(
            periodText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailedStats(ThemeData theme, HistoryStatistics statistics) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Details',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    TimezoneFormatter.compactTzIndicator,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _buildDetailRow(
              theme,
              icon: Icons.schedule,
              label: 'Total Shifts',
              value: statistics.totalShifts.toString(),
            ),
            const Divider(height: 24),
            _buildDetailRow(
              theme,
              icon: Icons.access_time,
              label: 'Total Hours Worked',
              value: statistics.formattedTotalHours,
            ),
            const Divider(height: 24),
            _buildDetailRow(
              theme,
              icon: Icons.timelapse,
              label: 'Average Shift Duration',
              value: statistics.formattedAverageDuration,
            ),
            if (statistics.totalGpsPoints != null && statistics.totalGpsPoints > 0) ...[
              const Divider(height: 24),
              _buildDetailRow(
                theme,
                icon: Icons.location_on,
                label: 'GPS Points Recorded',
                value: statistics.totalGpsPoints.toString(),
              ),
            ],
            if (statistics.earliestShift != null) ...[
              const Divider(height: 24),
              _buildDetailRow(
                theme,
                icon: Icons.first_page,
                label: 'First Shift',
                value: DateFormat.yMMMd().format(statistics.earliestShift!),
              ),
            ],
            if (statistics.latestShift != null) ...[
              const Divider(height: 24),
              _buildDetailRow(
                theme,
                icon: Icons.last_page,
                label: 'Latest Shift',
                value: DateFormat.yMMMd().format(statistics.latestShift!),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildTeamDetailedStats(ThemeData theme, TeamStatistics statistics) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Details',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _buildDetailRow(
              theme,
              icon: Icons.people,
              label: 'Total Employees',
              value: statistics.totalEmployees.toString(),
            ),
            const Divider(height: 24),
            _buildDetailRow(
              theme,
              icon: Icons.schedule,
              label: 'Total Shifts',
              value: statistics.totalShifts.toString(),
            ),
            const Divider(height: 24),
            _buildDetailRow(
              theme,
              icon: Icons.access_time,
              label: 'Total Hours Worked',
              value: statistics.formattedTotalHours,
            ),
            const Divider(height: 24),
            _buildDetailRow(
              theme,
              icon: Icons.person,
              label: 'Avg Shifts per Employee',
              value: statistics.averageShiftsPerEmployee.toStringAsFixed(1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
