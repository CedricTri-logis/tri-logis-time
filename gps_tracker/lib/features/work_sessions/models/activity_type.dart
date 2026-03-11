import 'package:flutter/material.dart';

enum ActivityType {
  cleaning,
  maintenance,
  admin;

  String toJson() {
    switch (this) {
      case ActivityType.cleaning:
        return 'cleaning';
      case ActivityType.maintenance:
        return 'maintenance';
      case ActivityType.admin:
        return 'admin';
    }
  }

  static ActivityType fromJson(String json) {
    switch (json) {
      case 'cleaning':
        return ActivityType.cleaning;
      case 'maintenance':
        return ActivityType.maintenance;
      case 'admin':
        return ActivityType.admin;
      default:
        return ActivityType.cleaning;
    }
  }

  String get displayName {
    switch (this) {
      case ActivityType.cleaning:
        return 'Ménage';
      case ActivityType.maintenance:
        return 'Entretien';
      case ActivityType.admin:
        return 'Administration';
    }
  }

  String get description {
    switch (this) {
      case ActivityType.cleaning:
        return 'Nettoyage — studios, aires communes, appartements';
      case ActivityType.maintenance:
        return 'Maintenance, réparations, rénovations';
      case ActivityType.admin:
        return 'Bureau, gestion, planification';
    }
  }

  Color get color {
    switch (this) {
      case ActivityType.cleaning:
        return const Color(0xFF4CAF50); // Green
      case ActivityType.maintenance:
        return const Color(0xFFFF9800); // Orange
      case ActivityType.admin:
        return const Color(0xFF2196F3); // Blue
    }
  }

  IconData get icon {
    switch (this) {
      case ActivityType.cleaning:
        return Icons.cleaning_services;
      case ActivityType.maintenance:
        return Icons.handyman;
      case ActivityType.admin:
        return Icons.business_center;
    }
  }

  /// Whether this activity type requires location selection
  bool get requiresLocation => this != ActivityType.admin;

  /// Whether this activity type supports QR scanning
  bool get supportsQrScan => this == ActivityType.cleaning;
}
