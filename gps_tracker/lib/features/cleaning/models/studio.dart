/// Type of studio in a building.
enum StudioType {
  unit,
  commonArea,
  conciergerie;

  String toJson() {
    switch (this) {
      case StudioType.unit:
        return 'unit';
      case StudioType.commonArea:
        return 'common_area';
      case StudioType.conciergerie:
        return 'conciergerie';
    }
  }

  static StudioType fromJson(String json) {
    switch (json) {
      case 'common_area':
        return StudioType.commonArea;
      case 'conciergerie':
        return StudioType.conciergerie;
      default:
        return StudioType.unit;
    }
  }

  String get displayName {
    switch (this) {
      case StudioType.unit:
        return 'Unité';
      case StudioType.commonArea:
        return 'Aires communes';
      case StudioType.conciergerie:
        return 'Conciergerie';
    }
  }
}

/// Represents a studio/room within a building.
class Studio {
  final String id;
  final String qrCode;
  final String studioNumber;
  final String buildingId;
  final String buildingName;
  final StudioType studioType;
  final bool isActive;

  const Studio({
    required this.id,
    required this.qrCode,
    required this.studioNumber,
    required this.buildingId,
    required this.buildingName,
    required this.studioType,
    this.isActive = true,
  });

  factory Studio.fromJson(Map<String, dynamic> json) {
    return Studio(
      id: json['id'] as String,
      qrCode: json['qr_code'] as String,
      studioNumber: json['studio_number'] as String,
      buildingId: json['building_id'] as String,
      buildingName: json['building_name'] as String? ?? '',
      studioType: StudioType.fromJson(json['studio_type'] as String? ?? 'unit'),
      isActive: json['is_active'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'qr_code': qrCode,
        'studio_number': studioNumber,
        'building_id': buildingId,
        'building_name': buildingName,
        'studio_type': studioType.toJson(),
        'is_active': isActive,
      };

  factory Studio.fromLocalDb(Map<String, dynamic> map) {
    return Studio(
      id: map['id'] as String,
      qrCode: map['qr_code'] as String,
      studioNumber: map['studio_number'] as String,
      buildingId: map['building_id'] as String,
      buildingName: map['building_name'] as String? ?? '',
      studioType: StudioType.fromJson(map['studio_type'] as String? ?? 'unit'),
      isActive: (map['is_active'] as int?) == 1,
    );
  }

  Map<String, dynamic> toLocalDb() => {
        'id': id,
        'qr_code': qrCode,
        'studio_number': studioNumber,
        'building_id': buildingId,
        'building_name': buildingName,
        'studio_type': studioType.toJson(),
        'is_active': isActive ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

  /// Display label combining studio number and building.
  String get displayLabel => '$studioNumber — $buildingName';
}
