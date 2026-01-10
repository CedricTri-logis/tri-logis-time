import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/employee_history_provider.dart';
import '../providers/history_filter_provider.dart';
import '../services/export_service.dart';
import '../widgets/export_dialog.dart';
import '../widgets/history_filter_bar.dart';
import '../widgets/shift_history_card.dart';
import 'shift_detail_screen.dart';
import 'statistics_screen.dart';

/// Screen displaying shift history for a specific employee
class EmployeeHistoryScreen extends ConsumerStatefulWidget {
  final String employeeId;
  final String employeeName;

  const EmployeeHistoryScreen({
    super.key,
    required this.employeeId,
    required this.employeeName,
  });

  @override
  ConsumerState<EmployeeHistoryScreen> createState() =>
      _EmployeeHistoryScreenState();
}

class _EmployeeHistoryScreenState extends ConsumerState<EmployeeHistoryScreen> {
  final _scrollController = ScrollController();
  final _exportService = ExportService();
  bool _isExporting = false;

  @override
  void initState() {
    super.initState();
    // Clear filters and load history when screen opens
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(historyFilterProvider.notifier).clearAll();
      ref
          .read(employeeHistoryProvider.notifier)
          .loadForEmployee(widget.employeeId);
    });

    // Setup pagination scroll listener
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      ref.read(employeeHistoryProvider.notifier).loadMore();
    }
  }

  void _onFilterChanged() {
    final filterState = ref.read(historyFilterProvider);
    ref.read(employeeHistoryProvider.notifier).applyDateFilter(
          startDate: filterState.startDate,
          endDate: filterState.endDate,
        );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(employeeHistoryProvider);
    final hasFilters = ref.watch(hasActiveFiltersProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.employeeName),
            Text(
              'Shift History',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          // Statistics button
          IconButton(
            icon: const Icon(Icons.analytics_outlined),
            tooltip: 'Statistics',
            onPressed: _navigateToStatistics,
          ),
          // Export button
          if (state.shifts.isNotEmpty)
            IconButton(
              icon: _isExporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              tooltip: 'Export',
              onPressed: _isExporting ? null : _handleExport,
            ),
          if (hasFilters)
            IconButton(
              icon: const Icon(Icons.filter_alt_off),
              tooltip: 'Clear Filters',
              onPressed: () {
                ref.read(historyFilterProvider.notifier).clearAll();
                ref
                    .read(employeeHistoryProvider.notifier)
                    .loadForEmployee(widget.employeeId);
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isLoading ? null : () => _refresh(),
          ),
        ],
      ),
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
            child: _buildContent(state, theme),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(EmployeeHistoryState state, ThemeData theme) {
    if (state.isLoading && state.shifts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (state.error != null && state.shifts.isEmpty) {
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
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (state.shifts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.history,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(
              'No shift history found',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (state.filter.hasFilters) ...[
              const SizedBox(height: 8),
              Text(
                'Try adjusting your filters',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  ref.read(historyFilterProvider.notifier).clearAll();
                  ref
                      .read(employeeHistoryProvider.notifier)
                      .loadForEmployee(widget.employeeId);
                },
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Clear Filters'),
              ),
            ],
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () async => _refresh(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 8, bottom: 16),
        itemCount: state.shifts.length + (state.isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= state.shifts.length) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          final shift = state.shifts[index];
          return ShiftHistoryCard(
            shift: shift,
            onTap: () => _navigateToDetail(shift.id),
          );
        },
      ),
    );
  }

  void _refresh() {
    ref.read(employeeHistoryProvider.notifier).refresh();
  }

  void _navigateToDetail(String shiftId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => ShiftDetailScreen(
          shiftId: shiftId,
          employeeId: widget.employeeId,
          employeeName: widget.employeeName,
        ),
      ),
    );
  }

  void _navigateToStatistics() {
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => StatisticsScreen.employee(
          employeeId: widget.employeeId,
          employeeName: widget.employeeName,
        ),
      ),
    );
  }

  Future<void> _handleExport() async {
    final state = ref.read(employeeHistoryProvider);
    if (state.shifts.isEmpty) return;

    // Show export dialog to select format
    final format = await ExportDialog.show(
      context,
      shiftCount: state.shifts.length,
      employeeName: widget.employeeName,
    );

    if (format == null || !mounted) return;

    setState(() => _isExporting = true);

    try {
      String filePath;

      if (format == ExportFormat.csv) {
        filePath = await _exportService.exportToCsv(
          shifts: state.shifts,
          employeeName: widget.employeeName,
          employeeId: widget.employeeId,
        );
      } else {
        filePath = await _exportService.exportToPdf(
          shifts: state.shifts,
          employeeName: widget.employeeName,
          employeeId: widget.employeeId,
        );
      }

      if (!mounted) return;

      // Show success message with share option
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Export saved: ${filePath.split('/').last}',
          ),
          action: SnackBarAction(
            label: 'Share',
            onPressed: () => _exportService.shareFile(filePath),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isExporting = false);
      }
    }
  }
}
