import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {
  static const _keyBaseUrl = 'backend_base_url';

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyBaseUrl) ?? '';
  }

  static Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    var normalized = url.trim();
    if (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    await prefs.setString(_keyBaseUrl, normalized);
  }
}
