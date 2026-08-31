import 'dart:async';
import 'package:flutter/material.dart';
import '../models/device.dart';
import '../services/api_service.dart';
import '../services/settings_service.dart';
import 'add_device_screen.dart';
import 'device_detail_screen.dart';
import 'settings_screen.dart';

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _api = ApiService();
  List<Device> _devices = [];
  String? _error;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _checkSettingsThenLoad();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkSettingsThenLoad() async {
    final url = await SettingsService.getBaseUrl();
    if (url.isEmpty) {
      await _openSettings();
    }
    _load();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final devices = await _api.fetchDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🐾 PetFeeder'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () async {
              await _openSettings();
              _load();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: _buildBody(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final created = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
          );
          if (created == true) _load();
        },
        icon: const Icon(Icons.add),
        label: const Text('Cihaz Ekle'),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading && _devices.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _devices.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 80),
          Icon(Icons.wifi_off, size: 48, color: Colors.grey[400]),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(_error!, textAlign: TextAlign.center),
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(onPressed: _openSettings, child: const Text('Ayarlari kontrol et')),
          ),
        ],
      );
    }
    if (_devices.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          Center(child: Text('Henuz cihaz yok. Sag alttan ekleyebilirsin.')),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _devices.length,
      itemBuilder: (context, index) {
        final device = _devices[index];
        return Card(
          child: ListTile(
            title: Text(device.name),
            subtitle: Text(device.lastSeenAt != null
                ? 'Son gorulme: ${_formatDate(device.lastSeenAt!)}'
                : 'Hic gorulmedi'),
            trailing: Chip(
              label: Text(device.online ? 'Cevrimici' : 'Cevrimdisi'),
              backgroundColor: device.online ? Colors.green[100] : Colors.red[100],
              labelStyle: TextStyle(
                color: device.online ? Colors.green[800] : Colors.red[800],
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => DeviceDetailScreen(deviceId: device.id)),
              );
              _load();
            },
          ),
        );
      },
    );
  }
}

String _formatDate(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
}
