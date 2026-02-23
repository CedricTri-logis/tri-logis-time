import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Service for local push notifications (GPS alerts).
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// Notification IDs
  static const int _gpsLostId = 1001;
  static const int _gpsRestoredId = 1002;
  static const int _midnightWarningId = 1003;

  /// Android notification channel for GPS alerts.
  static const _gpsChannelId = 'gps_alerts';
  static const _gpsChannelName = 'Alertes GPS';
  static const _gpsChannelDescription =
      'Notifications quand le signal GPS est perdu ou restauré';

  /// Initialize the notification plugin.
  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _plugin.initialize(settings);

    // Create Android notification channel
    if (Platform.isAndroid) {
      final androidPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(
        const AndroidNotificationChannel(
          _gpsChannelId,
          _gpsChannelName,
          description: _gpsChannelDescription,
          importance: Importance.high,
          enableVibration: true,
          playSound: true,
        ),
      );
    }

    _initialized = true;
  }

  /// Request notification permission (call at clock-in time).
  Future<bool> requestPermission() async {
    if (Platform.isIOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final granted = await iosPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
      return granted ?? false;
    }
    if (Platform.isAndroid) {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestNotificationsPermission();
      return granted ?? false;
    }
    return true;
  }

  /// Show a persistent notification when GPS signal is lost.
  Future<void> showGpsLostNotification() async {
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      _gpsChannelId,
      _gpsChannelName,
      channelDescription: _gpsChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      ongoing: true, // Sticky — can't be swiped away
      autoCancel: false,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      _gpsLostId,
      'Signal GPS perdu',
      'Le suivi de votre quart continue mais sans points GPS. Vérifiez vos paramètres de localisation.',
      details,
    );
  }

  /// Cancel the GPS lost notification.
  Future<void> cancelGpsLostNotification() async {
    if (!_initialized) return;
    await _plugin.cancel(_gpsLostId);
  }

  /// Show a warning notification 5 minutes before midnight auto clock-out.
  Future<void> showMidnightWarningNotification() async {
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      _gpsChannelId,
      _gpsChannelName,
      channelDescription: _gpsChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      _midnightWarningId,
      'Fin de quart à minuit',
      'Votre quart se terminera automatiquement à minuit. '
          'Vous pourrez recommencer un nouveau quart après minuit si nécessaire.',
      details,
    );
  }

  /// Cancel the midnight warning notification.
  Future<void> cancelMidnightWarningNotification() async {
    if (!_initialized) return;
    await _plugin.cancel(_midnightWarningId);
  }

  /// Show a brief notification when GPS is restored.
  Future<void> showGpsRestoredNotification() async {
    if (!_initialized) return;

    const androidDetails = AndroidNotificationDetails(
      _gpsChannelId,
      _gpsChannelName,
      channelDescription: _gpsChannelDescription,
      importance: Importance.defaultImportance,
      priority: Priority.defaultPriority,
      autoCancel: true,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      _gpsRestoredId,
      'GPS restauré',
      'Le signal GPS est de retour. Le suivi reprend normalement.',
      details,
    );
  }
}
