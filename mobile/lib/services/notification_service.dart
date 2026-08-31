import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest_all.dart' as tz;
import '../models/device.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static const _channelId = 'petfeeder';
  static const _channelName = 'PetFeeder Bildirimler';

  static Future<void> init() async {
    if (_initialized) return;
    tz.initializeTimeZones();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
    _initialized = true;
  }

  static NotificationDetails get _details => const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId, _channelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        ),
      );

  /// Besleme zamanları için günlük tekrarlayan bildirim planla
  static Future<void> scheduleFeedings(
      String deviceId, String deviceName, List<ScheduleSlot> slots) async {
    final baseId = deviceId.hashCode.abs() % 100000 * 10;

    // Bu cihazın eski bildirimlerini iptal et
    for (int i = 0; i < 4; i++) {
      await _plugin.cancel(baseId + i);
    }

    for (int i = 0; i < slots.length && i < 4; i++) {
      final slot = slots[i];
      if (!slot.enabled) continue;

      final now = tz.TZDateTime.now(tz.local);
      var scheduled = tz.TZDateTime(
          tz.local, now.year, now.month, now.day, slot.hour, slot.minute);
      if (scheduled.isBefore(now)) {
        scheduled = scheduled.add(const Duration(days: 1));
      }

      await _plugin.zonedSchedule(
        baseId + i,
        'PetFeeder — $deviceName',
        '${slot.label}: ${slot.portions} porsiyon mama zamanı 🐾',
        scheduled,
        _details,
        matchDateTimeComponents: DateTimeComponents.time,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.wallClockTime,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
    }
  }

  /// Anlık bildirim (besleme tamamlandı)
  static Future<void> showNow(String title, String body) async {
    await _plugin.show(9999, title, body, _details);
  }

  /// Cihaz silinince bildirimlerini iptal et
  static Future<void> cancelDevice(String deviceId) async {
    final baseId = deviceId.hashCode.abs() % 100000 * 10;
    for (int i = 0; i < 4; i++) {
      await _plugin.cancel(baseId + i);
    }
  }
}
