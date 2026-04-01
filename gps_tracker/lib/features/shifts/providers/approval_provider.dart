import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/day_approval.dart';

/// Fetch day approval summaries for an employee + date range.
/// Accepts explicit employeeId so supervisors can view subordinates' data.
final dayApprovalSummariesProvider = FutureProvider.family<
    List<DayApprovalSummary>,
    ({String employeeId, DateTime from, DateTime to})>(
  (ref, params) async {
    final supabase = Supabase.instance.client;

    final fromStr =
        '${params.from.year}-${params.from.month.toString().padLeft(2, '0')}-${params.from.day.toString().padLeft(2, '0')}';
    final toStr =
        '${params.to.year}-${params.to.month.toString().padLeft(2, '0')}-${params.to.day.toString().padLeft(2, '0')}';

    final response = await supabase.schema('workforce')
        .from('day_approvals')
        .select(
            'employee_id, date, status, approved_minutes, rejected_minutes, total_shift_minutes')
        .eq('employee_id', params.employeeId)
        .gte('date', fromStr)
        .lte('date', toStr)
        .order('date', ascending: false);

    return (response as List<dynamic>)
        .map((row) =>
            DayApprovalSummary.fromJson(row as Map<String, dynamic>))
        .toList();
  },
);

/// Fetch full day approval detail for a specific employee + date.
/// Accepts explicit employeeId so supervisors can view subordinates' data.
final dayApprovalDetailProvider = FutureProvider.autoDispose.family<DayApprovalDetail?,
    ({String employeeId, DateTime date})>(
  (ref, params) async {
    final supabase = Supabase.instance.client;

    final dateStr =
        '${params.date.year}-${params.date.month.toString().padLeft(2, '0')}-${params.date.day.toString().padLeft(2, '0')}';

    try {
      final response = await supabase.schema('workforce').rpc('get_day_approval_detail', params: {
        'p_employee_id': params.employeeId,
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
