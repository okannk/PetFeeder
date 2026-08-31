import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device.dart';
import 'settings_service.dart';

class ApiService {
  static const _timeout = Duration(seconds: 8);
  static const _feedTimeout = Duration(seconds: 20);

  Future<Map<String, String>> _headers() async {
    final key = await SettingsService.getApiKey();
    return {
      'Content-Type': 'application/json',
      if (key.isNotEmpty) 'X-Api-Key': key,
    };
  }

  Future<String> _base() => SettingsService.getBaseUrl();

  Future<List<Device>> fetchDevices() async {
    final resp = await http
        .get(Uri.parse('${await _base()}/api/devices'), headers: await _headers())
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Sunucu hatası: ${resp.statusCode}');
    return (jsonDecode(resp.body) as List)
        .map((e) => Device.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> createDevice(String name) async {
    final resp = await http
        .post(Uri.parse('${await _base()}/api/devices'),
            headers: await _headers(), body: jsonEncode({'name': name}))
        .timeout(_timeout);
    if (resp.statusCode != 201) throw Exception('Cihaz oluşturulamadı: ${resp.statusCode}');
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Device> renameDevice(String id, String name) async {
    final resp = await http
        .patch(Uri.parse('${await _base()}/api/devices/$id'),
            headers: await _headers(), body: jsonEncode({'name': name}))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Yeniden adlandırma başarısız: ${resp.statusCode}');
    return Device.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> deleteDevice(String id) async {
    final resp = await http
        .delete(Uri.parse('${await _base()}/api/devices/$id'), headers: await _headers())
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Silme başarısız: ${resp.statusCode}');
  }

  Future<List<HistoryEntry>> fetchHistory(String deviceId, {int limit = 50}) async {
    final resp = await http
        .get(Uri.parse('${await _base()}/api/devices/$deviceId/history?limit=$limit'),
            headers: await _headers())
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Geçmiş alınamadı: ${resp.statusCode}');
    return (jsonDecode(resp.body) as List)
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> feed(String deviceId, int portions) async {
    final resp = await http
        .post(Uri.parse('${await _base()}/api/devices/$deviceId/feed'),
            headers: await _headers(), body: jsonEncode({'portions': portions}))
        .timeout(_feedTimeout);
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode != 200) throw Exception(body['error'] ?? 'Besleme başarısız');
    return body;
  }

  Future<void> updateSchedule(String deviceId, Schedule schedule) async {
    final resp = await http
        .post(Uri.parse('${await _base()}/api/devices/$deviceId/schedule'),
            headers: await _headers(), body: jsonEncode(schedule.toJson()))
        .timeout(_timeout);
    if (resp.statusCode != 200) throw Exception('Zamanlama kaydedilemedi: ${resp.statusCode}');
  }
}
