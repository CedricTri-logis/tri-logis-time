/// Represents an apartment/unit within a property building.
/// Used for maintenance session tracking (separate from cleaning studios).
class Apartment {
  final String id;
  final String buildingId;
  final String apartmentName;
  final String? unitNumber;
  final String apartmentCategory;
  final bool isActive;

  const Apartment({
    required this.id,
    required this.buildingId,
    required this.apartmentName,
    this.unitNumber,
    this.apartmentCategory = 'Residential',
    this.isActive = true,
  });

  /// Display label: apartment name.
  String get displayLabel => apartmentName;

  factory Apartment.fromJson(Map<String, dynamic> json) {
    return Apartment(
      id: json['id'] as String,
      buildingId: json['building_id'] as String,
      apartmentName: json['apartment_name'] as String,
      unitNumber: json['unit_number'] as String?,
      apartmentCategory:
          json['apartment_category'] as String? ?? 'Residential',
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  factory Apartment.fromLocalDb(Map<String, dynamic> map) {
    return Apartment(
      id: map['id'] as String,
      buildingId: map['building_id'] as String,
      apartmentName: map['apartment_name'] as String,
      unitNumber: map['unit_number'] as String?,
      apartmentCategory:
          map['apartment_category'] as String? ?? 'Residential',
      isActive: (map['is_active'] as int?) == 1,
    );
  }

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'building_id': buildingId,
        'apartment_name': apartmentName,
        'unit_number': unitNumber,
        'apartment_category': apartmentCategory,
        'is_active': isActive ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}
