import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/employee_history_provider.dart';
import '../providers/history_filter_provider.dart';
import '../providers/supervised_employees_provider.dart';
import '../services/export_service.dart';
import '../widgets/export_dialog.dart';
import '../widgets/history_filter_bar.dart';
import '../widgets/shift_history_card.dart';
import 'shift_detail_screen.dart';
import 'statistics_screen.dart';

/// Screen displaying the current user's own shift history
///
/// This is the entry point for employees to view their own enhanced
/// history with filtering, statistics, and export capabilities.
class MyHistoryScreen extends ConsumerStatefulWidget {
  const MyHistoryScreen({super.key});

  @override
  ConsumerState<MyHistoryScreen> createState() => _MyHistoryScreenState();
}

class _MyHistoryScreenState extends ConsumerState<MyHistoryScreen> {
  final _scrollController = ScrollController();
  final _exportService = ExportService();
  bool _isExporting = false;
  String? _userId;
  String _userName = 'Mon historique';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadUserProfile();
    });
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadUserProfile() async {
    final historyService = ref.read(historyServiceProvider);
    final profile = await historyService.getCurrentUserProfile();

    if (profile != null && mounted) {
      setState(() {
        _userId = profile.id;
        _userName = profile.displayName;
      });

      // Clear filters and load history
      ref.read(historyFilterProvider.notifier).clearAll();
      ref.read(employeeHistoryProvider.notifier).loadForEmployee(profile.id);
    }
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
            Text(_userName),
            Text(
              'Historique des quarts',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          // Statistics button
          if (_userId != null)
            IconButton(
              icon: const Icon(Icons.analytics_outlined),
              tooltip: 'Statistiques',
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
              tooltip: 'Exporter',
              onPressed: _isExporting ? null : _handleExport,
            ),
          if (hasFilters)
            IconButton(
              icon: const Icon(Icons.filter_alt_off),
              tooltip: 'Effacer les filtres',
              onPressed: () {
                ref.read(historyFilterProvider.notifier).clearAll();
                if (_userId != null) {
                  ref
                      .read(employeeHistoryProvider.notifier)
                      .loadForEmployee(_userId!);
                }
              },
            ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: state.isLoading ? null : _refresh,
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
    if (_userId == null) {
      return const Center(child: CircularProgressIndicator());
    }

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
                label: const Text('Réessayer'),
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
              'Aucun historique de quart trouvé',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (state.filter.hasFilters) ...[
              const SizedBox(height: 8),
              Text(
                'Essayez de modifier vos filtres',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () {
                  ref.read(historyFilterProvider.notifier).clearAll();
                  if (_userId != null) {
                    ref
                        .read(employeeHistoryProvider.notifier)
                        .loadForEmployee(_userId!);
                  }
                },
                icon: const Icon(Icons.filter_alt_off),
                label: const Text('Effacer les filtres'),
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
    if (_userId != null) {
      ref.read(employeeHistoryProvider.notifier).refresh();
    }
  }

  void _navigateToDetail(String shiftId) {
    if (_userId == null) return;

    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => ShiftDetailScreen(
          shiftId: shiftId,
          employeeId: _userId!,
          employeeName: _userName,
        ),
      ),
    );
  }

  void _navigateToStatistics() {
    if (_userId == null) return;

    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (context) => StatisticsScreen.employee(
          employeeId: _userId!,
          employeeName: _userName,
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
      employeeName: _userName,
    );

    if (format == null || !mounted) return;

    setState(() => _isExporting = true);

    try {
      String filePath;

      if (format == ExportFormat.csv) {
        filePath = await _exportService.exportToCsv(
          shifts: state.shifts,
          employeeName: _userName,
          employeeId: _userId,
        );
      } else {
        filePath = await _exportService.exportToPdf(
          shifts: state.shifts,
          employeeName: _userName,
          employeeId: _userId,
        );
      }

      if (!mounted) return;

      // Show success message with share option
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Export sauvegardé : ${filePath.split('/').last}',
          ),
          action: SnackBarAction(
            label: 'Partager',
            onPressed: () => _exportService.shareFile(filePath),
          ),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Échec de l'export : $e"),
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
