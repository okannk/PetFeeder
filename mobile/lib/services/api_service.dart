import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/device.dart';
import 'settings_service.dart';

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => message;
}

class ApiService {
  Future<String> _base() async {
    final base = await SettingsService.getBaseUrl();
    if (base.isEmpty) {
      throw ApiException("Once Ayarlar'dan backend adresini gir.");
    }
    return base;
  }

  Map<String, dynamic> _decodeObject(http.Response res) {
    Map<String, dynamic> body = {};
    if (res.body.isNotEmpty) {
      try {
        final decoded = jsonDecode(res.body);
        if (decoded is Map<String, dynamic>) body = decoded;
      } catch (_) {
        // gecersiz govde, bos obje ile devam
      }
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw ApiException(
          body['error']?.toString() ?? 'Istek basarisiz (${res.statusCode})');
    }
    return body;
  }

  Future<List<Device>> fetchDevices() async {
    final base = await _base();
    final res = await http
        .get(Uri.parse('$base/api/devices'))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw ApiException('Cihazlar alinamadi (${res.statusCode})');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => Device.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<HistoryEntry>> fetchHistory(String deviceId,
      {int limit = 10}) async {
    final base = await _base();
    final res = await http
        .get(Uri.parse('$base/api/devices/$deviceId/history?limit=$limit'))
        .timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return [];
    final list = jsonDecode(res.body) as List<dynamic>;
    return list
        .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> createDevice(String name) async {
    final base = await _base();
    final res = await http
        .post(
          Uri.parse('$base/api/devices'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'name': name}),
        )
        .timeout(const Duration(seconds: 8));
    return _decodeObject(res);
  }

  Future<Map<String, dynamic>> feed(String deviceId, int portions) async {
    final base = await _base();
    final res = await http
        .post(
          Uri.parse('$base/api/devices/$deviceId/feed'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'portions': portions}),
        )
        .timeout(const Duration(seconds: 20));
    return _decodeObject(res);
  }

  Future<Map<String, dynamic>> updateSchedule(
      String deviceId, Schedule schedule) async {
    final base = await _base();
    final res = await http
        .post(
          Uri.parse('$base/api/devices/$deviceId/schedule'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(schedule.toJson()),
        )
        .timeout(const Duration(seconds: 8));
    return _decodeObject(res);
  }
}
