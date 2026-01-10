import 'dart:async';

import 'connectivity_service.dart';
import 'sync_logger.dart';

/// Configuration for network-aware sync behavior.
class NetworkSyncConfig {
  /// Whether to sync on cellular (metered) connections.
  final bool syncOnCellular;

  /// Maximum items to sync on cellular.
  final int cellularBatchLimit;

  /// Delay before syncing on cellular (to avoid frequent syncs).
  final Duration cellularSyncDelay;

  /// Delay before syncing on WiFi.
  final Duration wifiSyncDelay;

  /// Interval for bulk sync on WiFi (every 5 minutes per spec).
  final Duration wifiBulkSyncInterval;

  const NetworkSyncConfig({
    this.syncOnCellular = true,
    this.cellularBatchLimit = 50,
    this.cellularSyncDelay = const Duration(minutes: 2),
    this.wifiSyncDelay = const Duration(seconds: 30),
    this.wifiBulkSyncInterval = const Duration(minutes: 5),
  });
}

/// Service for network-aware sync scheduling.
class NetworkAwareSyncScheduler {
  final ConnectivityService _connectivityService;
  final SyncLogger _logger;
  final NetworkSyncConfig _config;

  StreamSubscription<NetworkType>? _networkSub;
  Timer? _syncTimer;
  Timer? _bulkSyncTimer;

  /// Callback when sync should be triggered.
  void Function(SyncTrigger trigger)? onSyncTrigger;

  /// Current network type.
  NetworkType _currentNetworkType = NetworkType.none;

  NetworkAwareSyncScheduler(
    this._connectivityService,
    this._logger, {
    NetworkSyncConfig? config,
  }) : _config = config ?? const NetworkSyncConfig();

  /// Start monitoring network and scheduling syncs.
  void start() {
    _networkSub?.cancel();
    _networkSub = _connectivityService.onNetworkTypeChanged.listen(
      _handleNetworkChange,
    );

    // Check initial state
    _connectivityService.getNetworkType().then(_handleNetworkChange);
  }

  /// Stop monitoring.
  void stop() {
    _networkSub?.cancel();
    _syncTimer?.cancel();
    _bulkSyncTimer?.cancel();
  }

  /// Handle network type changes.
  void _handleNetworkChange(NetworkType type) async {
    final previousType = _currentNetworkType;
    _currentNetworkType = type;

    await _logger.info(
      'Network type changed',
      metadata: {
        'from': previousType.name,
        'to': type.name,
      },
    );

    // Cancel pending timers
    _syncTimer?.cancel();
    _bulkSyncTimer?.cancel();

    if (!type.isConnected) {
      // No connection - stop sync
      return;
    }

    if (type.isHighBandwidth) {
      // WiFi/Ethernet - schedule immediate sync and bulk sync
      _scheduleSyncAfterDelay(_config.wifiSyncDelay, SyncTriggerReason.wifiConnected);
      _startBulkSyncTimer();
    } else if (type == NetworkType.cellular && _config.syncOnCellular) {
      // Cellular - schedule delayed sync
      _scheduleSyncAfterDelay(_config.cellularSyncDelay, SyncTriggerReason.cellularAvailable);
    }
  }

  /// Schedule sync after a delay.
  void _scheduleSyncAfterDelay(Duration delay, SyncTriggerReason reason) {
    _syncTimer?.cancel();
    _syncTimer = Timer(delay, () {
      _triggerSync(reason);
    });

    _logger.debug(
      'Sync scheduled',
      metadata: {
        'delay_seconds': delay.inSeconds,
        'reason': reason.name,
      },
    );
  }

  /// Start bulk sync timer for WiFi.
  void _startBulkSyncTimer() {
    _bulkSyncTimer?.cancel();
    _bulkSyncTimer = Timer.periodic(_config.wifiBulkSyncInterval, (_) {
      if (_currentNetworkType.isHighBandwidth) {
        _triggerSync(SyncTriggerReason.bulkSyncInterval);
      }
    });
  }

  /// Trigger a sync with context.
  void _triggerSync(SyncTriggerReason reason) {
    final trigger = SyncTrigger(
      reason: reason,
      networkType: _currentNetworkType,
      batchLimit: _getBatchLimit(),
    );

    onSyncTrigger?.call(trigger);

    _logger.debug(
      'Sync triggered',
      metadata: {
        'reason': reason.name,
        'network': _currentNetworkType.name,
        'batch_limit': trigger.batchLimit,
      },
    );
  }

  /// Get batch limit based on network type.
  int? _getBatchLimit() {
    if (_currentNetworkType == NetworkType.cellular) {
      return _config.cellularBatchLimit;
    }
    return null; // No limit on WiFi
  }

  /// Check if sync is allowed on current network.
  bool get canSync {
    if (!_currentNetworkType.isConnected) return false;
    if (_currentNetworkType == NetworkType.cellular && !_config.syncOnCellular) {
      return false;
    }
    return true;
  }

  /// Check if on high-bandwidth connection.
  bool get isOnHighBandwidth => _currentNetworkType.isHighBandwidth;

  /// Check if on metered connection.
  bool get isOnMetered => _currentNetworkType.isMetered;

  /// Dispose resources.
  void dispose() {
    stop();
  }
}

/// Reason for triggering a sync.
enum SyncTriggerReason {
  wifiConnected,
  cellularAvailable,
  bulkSyncInterval,
  manualRequest,
  appResume,
}

/// Sync trigger information.
class SyncTrigger {
  final SyncTriggerReason reason;
  final NetworkType networkType;
  final int? batchLimit;

  const SyncTrigger({
    required this.reason,
    required this.networkType,
    this.batchLimit,
  });

  bool get hasLimit => batchLimit != null;
  bool get isOnWifi => networkType == NetworkType.wifi;
  bool get isOnCellular => networkType == NetworkType.cellular;

  @override
  String toString() =>
      'SyncTrigger($reason, network: $networkType, limit: $batchLimit)';
}
