import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device.dart';

/// ESP8266'ya direkt HTTP konuşur.
/// Backend yok, API key yok.
class ApiService {
  static const _timeout     = Duration(seconds: 8);
  static const _feedTimeout = Duration(seconds: 25);

  String _url(String host, String path) => 'http://$host$path';

  Future<DeviceStatus> fetchStatus(String host) async {
    final resp = await http
        .get(Uri.parse(_url(host, '/status')))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Durum alınamadı: ${resp.statusCode}');
    return DeviceStatus.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> feed(String host, int portions) async {
    final resp = await http
        .post(Uri.parse(_url(host, '/feed')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'portions': portions}))
        .timeout(_feedTimeout);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['error'] ?? 'Besleme başarısız');
    return body;
  }

  Future<Schedule> fetchSchedule(String host) async {
    final resp = await http
        .get(Uri.parse(_url(host, '/schedule')))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Zamanlama alınamadı: ${resp.statusCode}');
    return Schedule.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> updateSchedule(String host, Schedule schedule) async {
    final resp = await http
        .post(Uri.parse(_url(host, '/schedule')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(schedule.toJson()))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Zamanlama kaydedilemedi: ${resp.statusCode}');
  }

  Future<List<HistoryEntry>> fetchHistory(String host) async {
    final resp = await http
        .get(Uri.parse(_url(host, '/history')))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Geçmiş alınamadı: ${resp.statusCode}');
    return (jsonDecode(resp.body) as List)
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> renameDevice(String host, String name) async {
    final resp = await http
        .post(Uri.parse(_url(host, '/name')),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'name': name}))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Yeniden adlandırma başarısız: ${resp.statusCode}');
  }

  Future<void> resetDevice(String host) async {
    await http
        .post(Uri.parse(_url(host, '/reset')),
            headers: {'Content-Type': 'application/json'})
        .timeout(_timeout);
  }

  /// Setup AP modu: 192.168.4.1/info
  Future<Map<String, dynamic>> fetchDeviceInfo() async {
    final resp = await http
        .get(Uri.parse('http://192.168.4.1/info'))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Cihaz bilgisi alınamadı');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  /// Setup AP modu: WiFi bilgilerini ESP'ye gönder
  Future<Map<String, dynamic>> configureDevice(
      String ssid, String password, String name) async {
    final resp = await http
        .post(Uri.parse('http://192.168.4.1/configure'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'ssid': ssid, 'password': password, 'name': name}))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Yapılandırma gönderilemedi: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
