import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Network connection type for optimization decisions.
enum NetworkType {
  none,
  wifi,
  cellular,
  ethernet,
  unknown;

  bool get isConnected => this != none;
  bool get isHighBandwidth => this == wifi || this == ethernet;
  bool get isMetered => this == cellular;
}

/// Service for monitoring network connectivity with type detection.
class ConnectivityService {
  final Connectivity _connectivity;
  StreamController<NetworkType>? _networkTypeController;

  ConnectivityService() : _connectivity = Connectivity();

  /// Check current connectivity status.
  Future<bool> isConnected() async {
    final results = await _connectivity.checkConnectivity();
    return _hasConnection(results);
  }

  /// Get current network type.
  Future<NetworkType> getNetworkType() async {
    final results = await _connectivity.checkConnectivity();
    return _getNetworkType(results);
  }

  /// Check if on WiFi (unmetered, high bandwidth).
  Future<bool> isOnWifi() async {
    final type = await getNetworkType();
    return type == NetworkType.wifi;
  }

  /// Check if on cellular (metered).
  Future<bool> isOnCellular() async {
    final type = await getNetworkType();
    return type == NetworkType.cellular;
  }

  /// Stream of connectivity changes (simple boolean).
  Stream<bool> get onConnectivityChanged {
    return _connectivity.onConnectivityChanged
        .map((results) => _hasConnection(results));
  }

  /// Stream of network type changes.
  Stream<NetworkType> get onNetworkTypeChanged {
    _networkTypeController ??= StreamController<NetworkType>.broadcast();

    _connectivity.onConnectivityChanged.listen((results) {
      _networkTypeController?.add(_getNetworkType(results));
    });

    return _networkTypeController!.stream;
  }

  /// Check if any connection type indicates connectivity.
  bool _hasConnection(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;

    return results.any((result) =>
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.ethernet);
  }

  /// Convert connectivity results to NetworkType.
  NetworkType _getNetworkType(List<ConnectivityResult> results) {
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
      return NetworkType.none;
    }

    // Prefer WiFi/Ethernet over cellular
    if (results.contains(ConnectivityResult.wifi)) {
      return NetworkType.wifi;
    }
    if (results.contains(ConnectivityResult.ethernet)) {
      return NetworkType.ethernet;
    }
    if (results.contains(ConnectivityResult.mobile)) {
      return NetworkType.cellular;
    }

    return NetworkType.unknown;
  }

  /// Get detailed connectivity status.
  Future<List<ConnectivityResult>> getConnectivityStatus() async {
    return await _connectivity.checkConnectivity();
  }

  /// Dispose resources.
  void dispose() {
    _networkTypeController?.close();
  }
}
