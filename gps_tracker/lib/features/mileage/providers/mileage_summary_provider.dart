import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/mileage_summary.dart';
import 'trip_provider.dart';

/// Provider for mileage summary via Supabase RPC.
final mileageSummaryProvider =
    FutureProvider.family<MileageSummary, TripPeriodParams>((ref, params) async {
  final supabase = Supabase.instance.client;

  try {
    final response = await supabase.rpc(
      'get_mileage_summary',
      params: {
        'p_employee_id': params.employeeId,
        'p_period_start': params.start.toIso8601String().split('T').first,
        'p_period_end': params.end.toIso8601String().split('T').first,
      },
    );

    if (response == null) return MileageSummary.empty();

    // RPC returns a single row or array with one element
    final Map<String, dynamic> data;
    if (response is List && response.isNotEmpty) {
      data = response.first as Map<String, dynamic>;
    } else if (response is Map<String, dynamic>) {
      data = response;
    } else {
      return MileageSummary.empty();
    }

    return MileageSummary.fromJson(data);
  } catch (e) {
    return MileageSummary.empty();
  }
});
