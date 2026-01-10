import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../history/models/history_statistics.dart';
import '../models/team_dashboard_state.dart';
import '../providers/team_statistics_provider.dart';
import '../widgets/date_range_picker.dart';
import '../widgets/team_hours_chart.dart';

/// Screen displaying aggregate team statistics with bar chart.
///
/// Shows:
/// - Date range filter (presets and custom)
/// - Aggregate metrics (total employees, total hours, etc.)
/// - Bar chart of hours per employee
class TeamStatisticsScreen extends ConsumerWidget {
  const TeamStatisticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(teamStatisticsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Statistics'),
        actions: [
          if (state.isLoading)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () =>
                  ref.read(teamStatisticsProvider.notifier).refresh(),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(teamStatisticsProvider.notifier).refresh(),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Date range picker
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Date Range',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DateRangePicker(
                      selectedPreset: state.dateRangePreset,
                      dateRange: state.dateRange,
                      onPresetSelected: (preset) => ref
                          .read(teamStatisticsProvider.notifier)
                          .selectPreset(preset),
                      onCustomRangeSelected: (range) => ref
                          .read(teamStatisticsProvider.notifier)
                          .selectCustomRange(range),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Error state
            if (state.error != null)
              _ErrorBanner(
                error: state.error!,
                onRetry: () =>
                    ref.read(teamStatisticsProvider.notifier).refresh(),
              ),

            // Aggregate statistics
            _StatsGrid(statistics: state.statistics),
            const SizedBox(height: 24),

            // Bar chart
            Text(
              'Hours by Employee',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: state.isLoading && state.employeeHours.isEmpty
                    ? const SizedBox(
                        height: 200,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : TeamHoursChart(data: state.employeeHours),
              ),
            ),
            const SizedBox(height: 24),

            // Hours breakdown list
            if (state.employeeHours.isNotEmpty) ...[
              Text(
                'Breakdown',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              ...state.employeeHours.map((e) => _HoursBreakdownItem(data: e)),
            ],

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final TeamStatistics statistics;

  const _StatsGrid({required this.statistics});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.5,
      children: [
        _StatCard(
          icon: Icons.groups,
          label: 'Team Members',
          value: statistics.totalEmployees.toString(),
        ),
        _StatCard(
          icon: Icons.event,
          label: 'Total Shifts',
          value: statistics.totalShifts.toString(),
        ),
        _StatCard(
          icon: Icons.schedule,
          label: 'Total Hours',
          value: statistics.formattedTotalHours,
        ),
        _StatCard(
          icon: Icons.trending_up,
          label: 'Avg Shifts/Person',
          value: statistics.averageShiftsPerEmployee.toStringAsFixed(1),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              color: colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurface,
              ),
            ),
            Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HoursBreakdownItem extends StatelessWidget {
  final EmployeeHoursData data;

  const _HoursBreakdownItem({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: colorScheme.primaryContainer,
              child: Text(
                _initials(data.displayName),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                data.displayName,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              data.formattedHours,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name.split(' ');
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    return parts[0].isNotEmpty ? parts[0][0].toUpperCase() : '?';
  }
}

class _ErrorBanner extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorBanner({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.errorContainer,
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(
              Icons.error_outline,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
            TextButton(
              onPressed: onRetry,
              child: Text(
                'Retry',
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
