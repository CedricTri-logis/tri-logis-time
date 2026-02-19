import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/apartment.dart';
import '../models/property_building.dart';
import '../providers/maintenance_provider.dart';

/// Bottom sheet for selecting a property building and optionally an apartment
/// to start a maintenance session.
class BuildingPickerSheet extends ConsumerStatefulWidget {
  const BuildingPickerSheet({super.key});

  /// Show the building picker and return the selected building/apartment info.
  static Future<BuildingPickerResult?> show(BuildContext context) {
    return showModalBottomSheet<BuildingPickerResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const BuildingPickerSheet(),
    );
  }

  @override
  ConsumerState<BuildingPickerSheet> createState() =>
      _BuildingPickerSheetState();
}

class _BuildingPickerSheetState extends ConsumerState<BuildingPickerSheet> {
  /// null = show buildings list, non-null = show apartments for that building
  PropertyBuilding? _selectedBuilding;
  bool _isLoading = true;
  List<PropertyBuilding> _buildings = [];
  List<Apartment> _apartments = [];

  @override
  void initState() {
    super.initState();
    _loadBuildings();
  }

  Future<void> _loadBuildings() async {
    try {
      final propertyCache = ref.read(propertyCacheServiceProvider);
      final buildings = await propertyCache.getAllBuildings();

      if (mounted) {
        setState(() {
          _buildings = buildings;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _selectBuilding(PropertyBuilding building) async {
    setState(() {
      _selectedBuilding = building;
      _isLoading = true;
    });

    try {
      final propertyCache = ref.read(propertyCacheServiceProvider);
      final apartments =
          await propertyCache.getApartmentsForBuilding(building.id);

      if (mounted) {
        setState(() {
          _apartments = apartments;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _apartments = [];
          _isLoading = false;
        });
      }
    }
  }

  void _goBack() {
    setState(() {
      _selectedBuilding = null;
      _apartments = [];
    });
  }

  void _confirmBuildingOnly() {
    final building = _selectedBuilding;
    if (building == null) return;

    Navigator.of(context).pop(BuildingPickerResult(
      buildingId: building.id,
      buildingName: building.displayName,
    ));
  }

  void _confirmWithApartment(Apartment apartment) {
    final building = _selectedBuilding;
    if (building == null) return;

    Navigator.of(context).pop(BuildingPickerResult(
      buildingId: building.id,
      buildingName: building.displayName,
      apartmentId: apartment.id,
      unitNumber: apartment.displayLabel,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  if (_selectedBuilding != null)
                    IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed: _goBack,
                    ),
                  Expanded(
                    child: Text(
                      _selectedBuilding != null
                          ? _selectedBuilding!.displayName
                          : 'Sélectionner un bâtiment',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // Content
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _selectedBuilding == null
                      ? _buildBuildingsList(theme, scrollController)
                      : _buildApartmentsList(theme, scrollController),
            ),
          ],
        );
      },
    );
  }

  Widget _buildBuildingsList(
      ThemeData theme, ScrollController scrollController) {
    if (_buildings.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.apartment, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              'Aucun bâtiment disponible',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      itemCount: _buildings.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final building = _buildings[index];
        return Card(
          elevation: 1,
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.apartment,
                color: theme.colorScheme.onPrimaryContainer,
                size: 20,
              ),
            ),
            title: Text(
              building.displayName,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(building.city),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _selectBuilding(building),
          ),
        );
      },
    );
  }

  Widget _buildApartmentsList(
      ThemeData theme, ScrollController scrollController) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(16),
      children: [
        // "Bâtiment au complet" option
        Card(
          elevation: 2,
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.apartment,
                color: theme.colorScheme.primary,
                size: 20,
              ),
            ),
            title: Text(
              'Bâtiment au complet',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            subtitle: const Text('Entretien du bâtiment entier'),
            trailing: Icon(Icons.play_circle,
                color: theme.colorScheme.primary),
            onTap: _confirmBuildingOnly,
          ),
        ),

        if (_apartments.isNotEmpty) ...[
          const SizedBox(height: 16),

          Text(
            'Ou sélectionner un appartement',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: 8),

          // Apartments list
          ..._apartments.map((apartment) {
            return Card(
              elevation: 1,
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.meeting_room,
                    color: theme.colorScheme.onSurfaceVariant,
                    size: 20,
                  ),
                ),
                title: Text(
                  apartment.displayLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(apartment.apartmentCategory),
                trailing: Icon(Icons.play_circle_outline,
                    color: theme.colorScheme.primary),
                onTap: () => _confirmWithApartment(apartment),
              ),
            );
          }),
        ],
      ],
    );
  }
}

/// Result from the building picker.
class BuildingPickerResult {
  final String buildingId;
  final String buildingName;
  final String? apartmentId;
  final String? unitNumber;

  const BuildingPickerResult({
    required this.buildingId,
    required this.buildingName,
    this.apartmentId,
    this.unitNumber,
  });
}
