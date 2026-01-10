import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../history/screens/employee_history_screen.dart';
import '../models/employee_work_status.dart';
import '../providers/team_dashboard_provider.dart';
import '../widgets/team_employee_tile.dart';
import '../widgets/team_search_bar.dart';
import 'team_statistics_screen.dart';

/// Team dashboard screen for managers.
///
/// Displays:
/// - Summary of active/total employees
/// - Search/filter bar
/// - Scrollable list of supervised employees
/// - Navigation to employee details and team statistics
class TeamDashboardScreen extends ConsumerWidget {
  const TeamDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(teamDashboardProvider);
    final theme = Theme.of(context);

    // Show loading spinner only on initial load
    if (state.isLoading && state.lastUpdated == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Show error state only if no data
    if (state.error != null && state.lastUpdated == null) {
      return _ErrorState(
        error: state.error!,
        onRetry: () => ref.read(teamDashboardProvider.notifier).refresh(),
      );
    }

    // Show empty state if no employees
    if (!state.hasEmployees && !state.isLoading) {
      return const _EmptyState();
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(teamDashboardProvider.notifier).refresh(),
      child: CustomScrollView(
        slivers: [
          // Summary header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Active count summary
                  _TeamSummaryCard(
                    activeCount: state.activeCount,
                    totalCount: state.totalCount,
                    onViewStats: () => _navigateToStatistics(context),
                  ),
                  const SizedBox(height: 16),

                  // Search bar
                  TeamSearchBar(
                    onSearch: (query) => ref
                        .read(teamDashboardProvider.notifier)
                        .updateSearchQuery(query),
                    initialQuery: state.searchQuery,
                    isLoading: state.isLoading,
                  ),
                  const SizedBox(height: 8),

                  // Filter status
                  if (state.searchQuery.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Text(
                            '${state.filteredEmployees.length} of ${state.totalCount} employees',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => ref
                                .read(teamDashboardProvider.notifier)
                                .clearSearch(),
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Employee list
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final employee = state.filteredEmployees[index];
                  return TeamEmployeeTile(
                    employee: employee,
                    onTap: () => _navigateToEmployeeHistory(context, employee),
                  );
                },
                childCount: state.filteredEmployees.length,
              ),
            ),
          ),

          // Bottom padding
          const SliverToBoxAdapter(
            child: SizedBox(height: 80),
          ),
        ],
      ),
    );
  }

  void _navigateToEmployeeHistory(
      BuildContext context, TeamEmployeeStatus employee) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => EmployeeHistoryScreen(
          employeeId: employee.employeeId,
          employeeName: employee.displayName,
        ),
      ),
    );
  }

  void _navigateToStatistics(BuildContext context) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => const TeamStatisticsScreen()),
    );
  }
}

class _TeamSummaryCard extends StatelessWidget {
  final int activeCount;
  final int totalCount;
  final VoidCallback? onViewStats;

  const _TeamSummaryCard({
    required this.activeCount,
    required this.totalCount,
    this.onViewStats,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Team Overview',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _StatPill(
                        icon: Icons.circle,
                        iconColor: Colors.green,
                        label: '$activeCount Active',
                      ),
                      const SizedBox(width: 12),
                      _StatPill(
                        icon: Icons.people,
                        iconColor: colorScheme.primary,
                        label: '$totalCount Total',
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (onViewStats != null)
              IconButton(
                onPressed: onViewStats,
                icon: Icon(
                  Icons.bar_chart,
                  color: colorScheme.primary,
                ),
                tooltip: 'View Statistics',
              ),
          ],
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;

  const _StatPill({
    required this.icon,
    required this.iconColor,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: iconColor),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.error,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline,
              size: 64,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              'Failed to load team',
              style: theme.textTheme.titleLarge?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.groups_outlined,
              size: 80,
              color: theme.colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'No Team Members',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'You don\'t have any supervised employees yet. Contact your administrator to assign employees to your team.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
