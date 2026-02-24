/// Represents a property building from the Tri-logis property management system.
/// Used for maintenance session tracking (separate from cleaning buildings).
class PropertyBuilding {
  final String id;
  final String name;
  final String address;
  final String city;
  final bool isActive;

  const PropertyBuilding({
    required this.id,
    required this.name,
    required this.address,
    required this.city,
    this.isActive = true,
  });

  /// Human-readable display name (address-based).
  String get displayName => address;

  factory PropertyBuilding.fromJson(Map<String, dynamic> json) {
    return PropertyBuilding(
      id: json['id'] as String,
      name: json['name'] as String,
      address: json['address'] as String,
      city: json['city'] as String,
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  factory PropertyBuilding.fromLocalDb(Map<String, dynamic> map) {
    return PropertyBuilding(
      id: map['id'] as String,
      name: map['name'] as String,
      address: map['address'] as String,
      city: map['city'] as String,
      isActive: (map['is_active'] as int?) == 1,
    );
  }

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'name': name,
        'address': address,
        'city': city,
        'is_active': isActive ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };
}
