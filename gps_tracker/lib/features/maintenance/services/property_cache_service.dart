import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/apartment.dart';
import '../models/property_building.dart';
import 'maintenance_local_db.dart';

/// Service for managing the local cache of property buildings and apartments.
/// Follows the same pattern as StudioCacheService for cleaning.
class PropertyCacheService {
  final SupabaseClient _supabase;
  final MaintenanceLocalDb _localDb;

  PropertyCacheService(this._supabase, this._localDb);

  /// Download all active property buildings and apartments from Supabase
  /// and update the local cache.
  Future<void> syncProperties() async {
    try {
      // Fetch active buildings
      final buildingsResponse = await _supabase
          .from('property_buildings')
          .select('id, name, address, city, is_active')
          .eq('is_active', true);

      final buildings = (buildingsResponse as List)
          .map((row) => PropertyBuilding.fromJson(row as Map<String, dynamic>))
          .toList();

      await _localDb.upsertBuildings(buildings);

      // Fetch active apartments
      final apartmentsResponse = await _supabase
          .from('apartments')
          .select(
              'id, building_id, apartment_name, unit_number, apartment_category, is_active')
          .eq('is_active', true);

      final apartments = (apartmentsResponse as List)
          .map((row) => Apartment.fromJson(row as Map<String, dynamic>))
          .toList();

      await _localDb.upsertApartments(apartments);
    } catch (e) {
      // Silently fail - offline mode will use existing cache
      // ignore: avoid_print
      print('PropertyCacheService.syncProperties failed: $e');
    }
  }

  /// Get all cached property buildings.
  Future<List<PropertyBuilding>> getAllBuildings() async {
    return _localDb.getAllBuildings();
  }

  /// Get all cached apartments for a specific building.
  Future<List<Apartment>> getApartmentsForBuilding(String buildingId) async {
    return _localDb.getApartmentsForBuilding(buildingId);
  }
}
