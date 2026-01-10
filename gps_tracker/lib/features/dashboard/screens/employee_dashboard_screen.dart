import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/providers/profile_provider.dart';
import '../../history/screens/shift_detail_screen.dart';
import '../../shifts/models/shift.dart';
import '../../shifts/providers/sync_provider.dart';
import '../providers/dashboard_provider.dart';
import '../widgets/daily_summary_card.dart';
import '../widgets/monthly_summary_card.dart';
import '../widgets/recent_shifts_list.dart';
import '../widgets/shift_status_tile.dart';
import '../widgets/sync_status_badge.dart';

/// Main dashboard screen for employees.
///
/// Displays:
/// - Current shift status with live timer
/// - Today's and monthly statistics
/// - Sync status indicator
/// - Recent shift history
class EmployeeDashboardScreen extends ConsumerWidget {
  const EmployeeDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(dashboardProvider);
    final theme = Theme.of(context);

    // Show loading spinner only on initial load
    if (state.isLoading && state.lastUpdated == null) {
      return const Center(child: CircularProgressIndicator());
    }

    // Show error state only if no data
    if (state.error != null && state.lastUpdated == null) {
      return _ErrorState(
        error: state.error!,
        onRetry: () => ref.read(dashboardProvider.notifier).refresh(),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.read(dashboardProvider.notifier).refresh(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Shift status with live timer
          ShiftStatusTile(
            status: state.currentShiftStatus,
            lastUpdated: state.isFromCache ? state.lastUpdated : null,
            onClockIn: () => _handleClockIn(context, ref),
          ),
          const SizedBox(height: 16),

          // Statistics row
          Row(
            children: [
              Expanded(
                child: DailySummaryCard(stats: state.todayStats),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: MonthlySummaryCard(stats: state.monthlyStats),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Sync status
          SyncStatusBadge(
            syncState: state.syncStatus,
            onRetry: () => ref.read(syncProvider.notifier).retrySync(),
          ),
          const SizedBox(height: 24),

          // Recent shifts section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Recent Shifts',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (state.isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),

          RecentShiftsList(
            shifts: state.recentShifts,
            onShiftTap: (shift) => _navigateToShiftDetail(context, ref, shift),
            onViewAll: () => _navigateToHistory(context),
          ),

          // Bottom padding for FAB
          const SizedBox(height: 80),
        ],
      ),
    );
  }

  void _handleClockIn(BuildContext context, WidgetRef ref) {
    // Navigate to clock-in flow (handled by existing shift screen)
    // The home screen already handles this via the FAB
  }

  void _navigateToShiftDetail(BuildContext context, WidgetRef ref, Shift shift) {
    final profile = ref.read(profileProvider).profile;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ShiftDetailScreen(
          shiftId: shift.id,
          employeeId: shift.employeeId,
          employeeName: profile?.fullName ?? 'Employee',
        ),
      ),
    );
  }

  void _navigateToHistory(BuildContext context) {
    // Navigate to full history screen
    Navigator.of(context).pushNamed('/history');
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
              'Failed to load dashboard',
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

/// Empty state widget for new employees with no shift history.
class EmptyDashboardState extends StatelessWidget {
  final VoidCallback? onClockIn;

  const EmptyDashboardState({
    super.key,
    this.onClockIn,
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
              Icons.schedule_outlined,
              size: 80,
              color: theme.colorScheme.primary.withOpacity(0.5),
            ),
            const SizedBox(height: 24),
            Text(
              'Welcome!',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Start your first shift to see your work statistics here.',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            if (onClockIn != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onClockIn,
                icon: const Icon(Icons.play_arrow),
                label: const Text('Start Your First Shift'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
