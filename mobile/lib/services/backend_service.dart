import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device.dart';

/// Cloud backend ile tüm iletişimi yönetir.
/// Tüm cihaz komutları backend üzerinden MQTT ile ESP'ye iletilir.
class BackendService {
  static const _baseUrl = 'http://92.5.176.9';
  static const _tokenKey = 'jwt_token';
  static const _timeout = Duration(seconds: 10);
  static const _feedTimeout = Duration(seconds: 35);

  // ─── Auth ─────────────────────────────────────────────────────────────────

  static Future<String?> getToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  static Future<bool> isLoggedIn() async => (await getToken()) != null;

  static Future<void> _saveToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
  }

  static Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
  }

  static Future<Map<String, String>> _authHeaders() async {
    final token = await getToken();
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// Kayıt ol. Başarıda JWT saklanır.
  static Future<void> register(String email, String password) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/auth/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(_timeout);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 201) {
      throw Exception(body['error'] ?? 'Kayıt başarısız (${resp.statusCode})');
    }
    await _saveToken(body['token'] as String);
  }

  /// Giriş yap. Başarıda JWT saklanır.
  static Future<void> login(String email, String password) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/auth/login'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'email': email, 'password': password}),
        )
        .timeout(_timeout);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) {
      throw Exception(body['error'] ?? 'Giriş başarısız (${resp.statusCode})');
    }
    await _saveToken(body['token'] as String);
  }

  // ─── Cihazlar ─────────────────────────────────────────────────────────────

  /// Kullanıcının cihaz listesini getirir.
  static Future<List<Device>> getDevices() async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/devices'),
          headers: await _authHeaders(),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Cihazlar alınamadı: ${resp.statusCode}');
    final list = jsonDecode(resp.body) as List;
    return list.map((e) => Device.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Yeni cihazı hesaba bağlar. id null ise backend UUID üretir.
  /// Döner: {id, mqttUser, mqttPass}
  static Future<Map<String, dynamic>> registerDevice(String? id, String name) async {
    final Map<String, dynamic> payload = {'name': name};
    if (id != null && id.isNotEmpty) payload['id'] = id;
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/devices'),
          headers: await _authHeaders(),
          body: jsonEncode(payload),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 201) throw Exception(body['error'] ?? 'Cihaz kaydedilemedi');
    return body;
  }

  /// Cihazı hesaptan çıkarır.
  static Future<void> deleteDevice(String deviceId) async {
    final resp = await http
        .delete(
          Uri.parse('$_baseUrl/devices/$deviceId'),
          headers: await _authHeaders(),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Silme başarısız: ${resp.statusCode}');
  }

  /// Manuel besleme komutu gönderir (backend → MQTT → ESP).
  static Future<Map<String, dynamic>> feed(String deviceId, int portions) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/devices/$deviceId/feed'),
          headers: await _authHeaders(),
          body: jsonEncode({'portions': portions}),
        )
        .timeout(_feedTimeout);
    _checkAuth(resp);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['error'] ?? 'Besleme başarısız');
    return body;
  }

  /// Cihaz zamanlamasını getirir.
  static Future<Schedule> getSchedule(String deviceId) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/devices/$deviceId/schedule'),
          headers: await _authHeaders(),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Zamanlama alınamadı: ${resp.statusCode}');
    return Schedule.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Cihaz zamanlamasını günceller (backend → MQTT → ESP).
  static Future<void> updateSchedule(String deviceId, Schedule schedule) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/devices/$deviceId/schedule'),
          headers: await _authHeaders(),
          body: jsonEncode(schedule.toJson()),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Zamanlama kaydedilemedi: ${resp.statusCode}');
  }

  /// Besleme geçmişini getirir.
  static Future<List<HistoryEntry>> getHistory(String deviceId,
      {int limit = 50}) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/devices/$deviceId/history'),
          headers: await _authHeaders(),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Geçmiş alınamadı: ${resp.statusCode}');
    return (jsonDecode(resp.body) as List)
        .take(limit)
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Cihazı yeniden adlandırır.
  static Future<Device> renameDevice(String deviceId, String name) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/devices/$deviceId/name'),
          headers: await _authHeaders(),
          body: jsonEncode({'name': name}),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Yeniden adlandırma başarısız: ${resp.statusCode}');
    // Güncel cihaz listesinden cihazı bul
    final devices = await getDevices();
    return devices.firstWhere(
      (d) => d.id == deviceId,
      orElse: () => Device(
        id: deviceId,
        name: name,
        online: false,
        schedule: Schedule(slots: []),
      ),
    );
  }

  /// Cihazı fabrika ayarlarına sıfırlar.
  static Future<void> resetDevice(String deviceId) async {
    final resp = await http
        .post(
          Uri.parse('$_baseUrl/devices/$deviceId/reset'),
          headers: await _authHeaders(),
        )
        .timeout(_timeout);
    _checkAuth(resp);
  }

  /// Cihaz için yeni MQTT kimlik bilgileri üretir.
  /// Döner: {mqttUrl, mqttUser, mqttPass, backendUrl}
  static Future<Map<String, dynamic>> provision(String deviceId) async {
    final resp = await http
        .get(
          Uri.parse('$_baseUrl/devices/$deviceId/provision'),
          headers: await _authHeaders(),
        )
        .timeout(_timeout);
    _checkAuth(resp);
    if (resp.statusCode != 200) throw Exception('Provision başarısız: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  // ─── Yardımcı ─────────────────────────────────────────────────────────────

  /// 401 → oturum süresi dolmuş, token temizle
  static void _checkAuth(http.Response resp) {
    if (resp.statusCode == 401) {
      // Token async temizle (fire-and-forget)
      logout();
      throw Exception('Oturum süresi doldu. Lütfen tekrar giriş yapın.');
    }
  }
}
