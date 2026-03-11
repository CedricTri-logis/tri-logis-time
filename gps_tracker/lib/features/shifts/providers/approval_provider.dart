import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/day_approval.dart';

/// Fetch day approval summaries for a date range (employee's own data).
/// Uses direct table query — RLS policy allows employee SELECT own.
final dayApprovalSummariesProvider = FutureProvider.family<
    List<DayApprovalSummary>, ({DateTime from, DateTime to})>(
  (ref, range) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return [];

    final fromStr =
        '${range.from.year}-${range.from.month.toString().padLeft(2, '0')}-${range.from.day.toString().padLeft(2, '0')}';
    final toStr =
        '${range.to.year}-${range.to.month.toString().padLeft(2, '0')}-${range.to.day.toString().padLeft(2, '0')}';

    final response = await supabase
        .from('day_approvals')
        .select(
            'employee_id, date, status, approved_minutes, rejected_minutes, total_shift_minutes')
        .eq('employee_id', userId)
        .gte('date', fromStr)
        .lte('date', toStr)
        .order('date', ascending: false);

    return (response as List<dynamic>)
        .map((row) =>
            DayApprovalSummary.fromJson(row as Map<String, dynamic>))
        .toList();
  },
);

/// Fetch full day approval detail for a specific date.
/// Uses get_day_approval_detail RPC with p_employee_id = userId.
final dayApprovalDetailProvider =
    FutureProvider.family<DayApprovalDetail?, DateTime>(
  (ref, date) async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return null;

    final dateStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    try {
      final response = await supabase.rpc('get_day_approval_detail', params: {
        'p_employee_id': userId,
        'p_date': dateStr,
      });

      if (response == null) return null;
      return DayApprovalDetail.fromJson(response as Map<String, dynamic>);
    } catch (_) {
      // Graceful degradation — approval data is supplementary
      return null;
    }
  },
);
