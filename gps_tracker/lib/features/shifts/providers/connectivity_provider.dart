import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/connectivity_service.dart';

/// Provider for the ConnectivityService.
final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  return ConnectivityService();
});

/// Stream provider for connectivity status changes.
final connectivityStatusProvider = StreamProvider<bool>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  return service.onConnectivityChanged;
});

/// Provider for current connectivity status.
final isConnectedProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(connectivityServiceProvider);
  return await service.isConnected();
});

/// Stream provider for network type changes.
final networkTypeStreamProvider = StreamProvider<NetworkType>((ref) {
  final service = ref.watch(connectivityServiceProvider);
  return service.onNetworkTypeChanged;
});

/// Provider for current network type.
final networkTypeProvider = FutureProvider<NetworkType>((ref) async {
  final service = ref.watch(connectivityServiceProvider);
  return await service.getNetworkType();
});

/// Provider for whether on WiFi.
final isOnWifiProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(connectivityServiceProvider);
  return await service.isOnWifi();
});

/// Provider for whether on cellular (metered).
final isOnCellularProvider = FutureProvider<bool>((ref) async {
  final service = ref.watch(connectivityServiceProvider);
  return await service.isOnCellular();
});
