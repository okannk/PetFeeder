import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/device.dart';

/// Cihaz listesini SharedPreferences'ta saklar.
/// Backend yok — her şey yerel.
class DeviceStorage {
  static const _key = 'stored_devices';

  static Future<List<StoredDevice>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((e) => StoredDevice.fromJson(e as Map<String, dynamic>)).toList();
  }

  static Future<void> saveAll(List<StoredDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
  }

  static Future<void> add(StoredDevice d) async {
    final list = await loadAll();
    list.removeWhere((e) => e.id == d.id);
    list.add(d);
    await saveAll(list);
  }

  static Future<void> remove(String id) async {
    final list = await loadAll();
    list.removeWhere((e) => e.id == id);
    await saveAll(list);
  }

  static Future<void> update(StoredDevice d) async {
    final list = await loadAll();
    final idx = list.indexWhere((e) => e.id == d.id);
    if (idx >= 0) list[idx] = d;
    await saveAll(list);
  }
}
