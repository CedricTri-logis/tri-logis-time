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
  static const int _midnightWarningId = 1003;

  /// Android notification channel for shift alerts.
  static const _gpsChannelId = 'gps_alerts';
  static const _gpsChannelName = 'Alertes de quart';
  static const _gpsChannelDescription =
      'Notifications liées aux quarts de travail';

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
}
