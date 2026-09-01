import 'dart:async';
import 'package:flutter/material.dart';
import '../models/device.dart';
import '../services/api_service.dart';
import '../services/backend_service.dart';
import 'add_device_screen.dart';
import 'auth_screen.dart';
import 'device_detail_screen.dart';

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
    _load();
    // Her 10 saniyede bir yenile (backend polling)
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() { _loading = true; _error = null; });
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
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _error = msg;
        _loading = false;
      });
      // Oturum süresi dolmuş → giriş ekranına git
      if (msg.contains('Oturum süresi')) _logout();
    }
  }

  Future<void> _logout() async {
    await BackendService.logout();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const AuthScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🐾 PetFeeder'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'logout') _logout();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'logout',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Çıkış Yap'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
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
          const Center(child: Icon(Icons.wifi_off, size: 48, color: Colors.grey)),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.tonal(
              onPressed: _load,
              child: const Text('Tekrar Dene'),
            ),
          ),
        ],
      );
    }
    if (_devices.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          Center(
            child: Text(
              'Henüz cihaz yok.\nSağ alttan ekleyebilirsin.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ),
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
            leading: Icon(
              device.online ? Icons.wifi : Icons.wifi_off,
              color: device.online ? Colors.green[600] : Colors.grey,
            ),
            title: Text(device.name),
            subtitle: Text(
              device.lastSeenAt != null
                  ? 'Son görülme: ${_formatDate(device.lastSeenAt!)}'
                  : 'Hiç görülmedi',
            ),
            trailing: Chip(
              label: Text(device.online ? 'Çevrimiçi' : 'Çevrimdışı'),
              backgroundColor:
                  device.online ? Colors.green[100] : Colors.red[100],
              labelStyle: TextStyle(
                color: device.online ? Colors.green[800] : Colors.red[800],
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      DeviceDetailScreen(deviceId: device.id),
                ),
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
  return '${two(dt.day)}.${two(dt.month)}.${dt.year} '
      '${two(dt.hour)}:${two(dt.minute)}';
}
