import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:vibration/vibration.dart';

/// Service สำหรับจัดการ Push Notification และ Vibration
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// Initialize notification service
  static Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(initSettings);
    _initialized = true;
  }

  /// คำนวณเวลาถึงโดยประมาณ (ETA) จากระยะทางและความเร็ว
  /// ความเร็วเฉลี่ย 35 km/h = 9.72 m/s
  static int calculateEtaSeconds(
    double distanceMeters, {
    double speedKmh = 35,
  }) {
    final speedMs = speedKmh * 1000 / 3600; // แปลงเป็น m/s
    return (distanceMeters / speedMs).round();
  }

  /// แปลงเวลาเป็นข้อความที่อ่านง่าย (รูปแบบนับถอยหลัง)
  static String formatEta(int etaSeconds) {
    if (etaSeconds <= 0) return 'ถึงแล้ว';
    if (etaSeconds < 60) {
      return '$etaSeconds วินาที';
    } else {
      final minutes = etaSeconds ~/ 60;
      final seconds = etaSeconds % 60;
      if (seconds == 0) return '$minutes นาที';
      return '$minutes นาที $seconds วินาที';
    }
  }

  /// แสดง Push Notification เมื่อรถบัสใกล้
  static Future<void> showBusNearbyNotification({
    required String busName,
    required double distanceMeters,
    int? etaSeconds,
  }) async {
    if (!_initialized) await initialize();

    const androidDetails = AndroidNotificationDetails(
      'bus_proximity_channel',
      'Bus Proximity Alerts',
      channelDescription: 'แจ้งเตือนเมื่อรถบัสเข้าใกล้',
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // สร้างข้อความ body พร้อม ETA
    String body = '$busName อยู่ห่าง ${distanceMeters.toStringAsFixed(0)} เมตร';
    if (etaSeconds != null) {
      body += ' (${formatEta(etaSeconds)})';
    }

    await _notifications.show(1, '🚌 รถบัสใกล้ถึงแล้ว!', body, details);
  }

  /// สั่นเตือน
  static Future<void> vibrate() async {
    final hasVibrator = await Vibration.hasVibrator();
    if (hasVibrator == true) {
      await Vibration.vibrate(duration: 500, amplitude: 128);
    }
  }

  /// แจ้งเตือนพร้อมสั่น
  static Future<void> alertBusNearby({
    required String busName,
    required double distanceMeters,
    int? etaSeconds,
  }) async {
    await Future.wait([
      showBusNearbyNotification(
        busName: busName,
        distanceMeters: distanceMeters,
        etaSeconds: etaSeconds,
      ),
      vibrate(),
    ]);
  }
}
