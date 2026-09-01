import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device.dart';
import 'backend_service.dart';

/// Uygulama içi API katmanı.
///
/// Normal cihaz işlemleri → BackendService (MQTT üzerinden ESP'ye).
/// Sadece cihaz kurulum sihirbazı 192.168.4.1'e direkt bağlanır.
class ApiService {
  static const _setupIp = '192.168.4.1';
  static const _setupTimeout = Duration(seconds: 8);

  // ─── Cihaz listesi ────────────────────────────────────────────────────────

  Future<List<Device>> fetchDevices() => BackendService.getDevices();

  // ─── Cihaz işlemleri (backend → MQTT → ESP) ───────────────────────────────

  Future<Map<String, dynamic>> feed(String deviceId, int portions) =>
      BackendService.feed(deviceId, portions);

  Future<Schedule> fetchSchedule(String deviceId) =>
      BackendService.getSchedule(deviceId);

  Future<void> updateSchedule(String deviceId, Schedule schedule) =>
      BackendService.updateSchedule(deviceId, schedule);

  Future<List<HistoryEntry>> fetchHistory(String deviceId, {int limit = 50}) =>
      BackendService.getHistory(deviceId, limit: limit);

  /// Cihazı yeniden adlandırır; güncel Device nesnesi döner.
  Future<Device> renameDevice(String deviceId, String name) =>
      BackendService.renameDevice(deviceId, name);

  Future<void> deleteDevice(String deviceId) =>
      BackendService.deleteDevice(deviceId);

  Future<void> resetDevice(String deviceId) =>
      BackendService.resetDevice(deviceId);

  // ─── Kurulum sihirbazı — direkt 192.168.4.1 ──────────────────────────────

  /// ESP'nin AP modunda cihaz bilgisini okur.
  Future<Map<String, dynamic>> fetchDeviceInfo() async {
    final resp = await http
        .get(Uri.parse('http://$_setupIp/info'))
        .timeout(_setupTimeout);
    if (resp.statusCode != 200) throw Exception('Cihaz bilgisi alınamadı');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// WiFi + MQTT kimlik bilgilerini ESP'ye gönderir (kurulum).
  ///
  /// [mqttHost] : MQTT broker'ın genel IP'si (backend sunucusu)
  /// [mqttUser] : Cihazın MQTT kullanıcı adı (= cihaz ID'si)
  /// [mqttPass] : Cihazın MQTT şifresi (backend tarafından üretilir)
  Future<Map<String, dynamic>> configureDevice({
    required String ssid,
    required String password,
    required String name,
    required String mqttHost,
    required String mqttUser,
    required String mqttPass,
  }) async {
    final resp = await http
        .post(
          Uri.parse('http://$_setupIp/configure'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'ssid': ssid,
            'password': password,
            'name': name,
            'mqtt_host': mqttHost,
            'mqtt_port': 1883,
            'mqtt_user': mqttUser,
            'mqtt_pass': mqttPass,
          }),
        )
        .timeout(const Duration(seconds: 12));
    if (resp.statusCode != 200) {
      throw Exception('Yapılandırma gönderilemedi: ${resp.statusCode}');
    }
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
