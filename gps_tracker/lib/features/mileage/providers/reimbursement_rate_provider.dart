import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/reimbursement_rate.dart';

/// Provider for the current active reimbursement rate.
final reimbursementRateProvider = FutureProvider<ReimbursementRate?>((ref) async {
  final supabase = Supabase.instance.client;
  final now = DateTime.now().toIso8601String().split('T').first;

  try {
    final response = await supabase
        .from('reimbursement_rates')
        .select()
        .lte('effective_from', now)
        .or('effective_to.is.null,effective_to.gte.$now')
        .order('effective_from', ascending: false)
        .limit(1)
        .maybeSingle();

    if (response == null) return null;
    return ReimbursementRate.fromJson(response);
  } catch (e) {
    return null;
  }
});
