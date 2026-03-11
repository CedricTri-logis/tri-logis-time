import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/day_approval.dart';
import '../models/shift.dart';
import '../providers/approval_provider.dart';
import '../providers/shift_history_provider.dart';
import '../widgets/shift_card.dart';
import 'shift_detail_screen.dart';

/// Screen displaying the shift history with pagination.
class ShiftHistoryScreen extends ConsumerStatefulWidget {
  const ShiftHistoryScreen({super.key});

  @override
  ConsumerState<ShiftHistoryScreen> createState() => _ShiftHistoryScreenState();
}

class _ShiftHistoryScreenState extends ConsumerState<ShiftHistoryScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_isNearBottom) {
      ref.read(shiftHistoryProvider.notifier).loadMore();
    }
  }

  bool get _isNearBottom {
    if (!_scrollController.hasClients) return false;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.offset;
    return currentScroll >= (maxScroll * 0.9);
  }

  void _navigateToDetail(String shiftId) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ShiftDetailScreen(shiftId: shiftId),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final historyState = ref.watch(shiftHistoryProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shift History'),
        centerTitle: true,
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.read(shiftHistoryProvider.notifier).refresh(),
        child: historyState.shifts.isEmpty && !historyState.isLoading
            ? _buildEmptyState(theme)
            : _buildShiftList(historyState, theme),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.history,
                size: 80,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 24),
              Text(
                'No Shift History',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Your completed shifts will appear here',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  ({DateTime from, DateTime to})? _getDateRange(List<Shift> shifts) {
    if (shifts.isEmpty) return null;
    final dates = shifts.map((s) => s.clockedInAt.toLocal()).toList();
    final earliest = dates.reduce((a, b) => a.isBefore(b) ? a : b);
    final latest = dates.reduce((a, b) => a.isAfter(b) ? a : b);
    return (
      from: DateTime(earliest.year, earliest.month, earliest.day),
      to: DateTime(latest.year, latest.month, latest.day),
    );
  }

  Map<String, DayApprovalSummary> _buildApprovalMap(
      List<DayApprovalSummary> approvals) {
    return {
      for (final a in approvals)
        '${a.date.year}-${a.date.month.toString().padLeft(2, '0')}-${a.date.day.toString().padLeft(2, '0')}':
            a,
    };
  }

  String _dateKey(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  Widget _buildShiftList(ShiftHistoryState historyState, ThemeData theme) {
    final approvalRange = _getDateRange(historyState.shifts);
    final userId = Supabase.instance.client.auth.currentUser?.id;
    final approvalsAsync = approvalRange != null && userId != null
        ? ref.watch(dayApprovalSummariesProvider(
            (employeeId: userId, from: approvalRange.from, to: approvalRange.to)))
        : const AsyncValue<List<DayApprovalSummary>>.data([]);
    final approvalMap = _buildApprovalMap(approvalsAsync.valueOrNull ?? []);

    return ListView.builder(
      controller: _scrollController,
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: historyState.shifts.length + (historyState.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= historyState.shifts.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: historyState.isLoading
                  ? const CircularProgressIndicator()
                  : TextButton(
                      onPressed: () =>
                          ref.read(shiftHistoryProvider.notifier).loadMore(),
                      child: const Text('Load More'),
                    ),
            ),
          );
        }

        final shift = historyState.shifts[index];

        // Group by date header
        Widget? dateHeader;
        if (index == 0 ||
            !_isSameDay(
              historyState.shifts[index - 1].clockedInAt,
              shift.clockedInAt,
            )) {
          dateHeader = _buildDateHeader(shift.clockedInAt, theme);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (dateHeader != null) dateHeader,
            ShiftCard(
              shift: shift,
              approval: approvalMap[_dateKey(shift.clockedInAt)],
              onTap: () => _navigateToDetail(shift.id),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDateHeader(DateTime date, ThemeData theme) {
    final localDate = date.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final shiftDate = DateTime(localDate.year, localDate.month, localDate.day);

    String label;
    if (shiftDate == today) {
      label = 'Today';
    } else if (shiftDate == yesterday) {
      label = 'Yesterday';
    } else {
      final months = [
        'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'
      ];
      label = '${months[localDate.month - 1]} ${localDate.day}, ${localDate.year}';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    final localA = a.toLocal();
    final localB = b.toLocal();
    return localA.year == localB.year &&
        localA.month == localB.month &&
        localA.day == localB.day;
  }
}
