import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/studio.dart';
import 'cleaning_local_db.dart';

/// Service for managing the local cache of studios data.
class StudioCacheService {
  final SupabaseClient _supabase;
  final CleaningLocalDb _localDb;

  StudioCacheService(this._supabase, this._localDb);

  /// Download all active studios from Supabase and update local cache.
  Future<void> syncStudios() async {
    try {
      final response = await _supabase
          .from('studios')
          .select('id, qr_code, studio_number, building_id, studio_type, is_active, buildings!inner(name)')
          .eq('is_active', true);

      final studios = (response as List).map((row) {
        final buildingName = row['buildings']?['name'] as String? ?? '';
        return Studio(
          id: row['id'] as String,
          qrCode: row['qr_code'] as String,
          studioNumber: row['studio_number'] as String,
          buildingId: row['building_id'] as String,
          buildingName: buildingName,
          studioType: StudioType.fromJson(row['studio_type'] as String? ?? 'unit'),
          isActive: row['is_active'] as bool? ?? true,
        );
      }).toList();

      await _localDb.upsertStudios(studios);
    } catch (e) {
      // Silently fail - offline mode will use existing cache
      // Log for debugging
      // ignore: avoid_print
      print('StudioCacheService.syncStudios failed: $e');
    }
  }

  /// Look up a studio by QR code from local cache.
  Future<Studio?> lookupByQrCode(String qrCode) async {
    return _localDb.getStudioByQrCode(qrCode);
  }

  /// Get all cached studios (for manual entry fallback).
  Future<List<Studio>> getAllStudios() async {
    return _localDb.getAllStudios();
  }
}
