import 'dart:async';
import 'package:flutter/material.dart';
import '../models/device.dart';
import '../services/api_service.dart';
import '../services/device_storage.dart';
import 'add_device_screen.dart';
import 'device_detail_screen.dart';

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  final _api = ApiService();
  List<Device> _devices = [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final stored = await DeviceStorage.loadAll();

    // Her cihaz için durum sorgula (paralel)
    final futures = stored.map((s) async {
      try {
        final status = await _api.fetchStatus(s.host);
        return Device(stored: s, online: true, schedule: status.schedule);
      } catch (_) {
        return Device(
            stored: s,
            online: false,
            schedule: Schedule(slots: []));
      }
    });

    final results = await Future.wait(futures);
    if (!mounted) return;
    setState(() {
      _devices = results;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('🐾 PetFeeder')),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: _buildBody(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final added = await Navigator.of(context).push<bool>(
            MaterialPageRoute(builder: (_) => const AddDeviceScreen()),
          );
          if (added == true) _load();
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
    if (_devices.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 100),
          Center(
            child: Column(children: [
              Icon(Icons.pets, size: 56, color: Colors.grey),
              SizedBox(height: 12),
              Text('Henüz cihaz yok.\nSağ alttan cihaz ekleyebilirsin.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey)),
            ]),
          ),
        ],
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _devices.length,
      itemBuilder: (context, i) {
        final d = _devices[i];
        return Card(
          child: ListTile(
            leading: Icon(Icons.router,
                color: d.online ? Colors.green[600] : Colors.grey),
            title: Text(d.name),
            subtitle: Text(d.host,
                style: const TextStyle(fontSize: 12, color: Colors.grey)),
            trailing: Chip(
              label: Text(d.online ? 'Çevrimiçi' : 'Çevrimdışı'),
              backgroundColor: d.online ? Colors.green[100] : Colors.red[100],
              labelStyle: TextStyle(
                color: d.online ? Colors.green[800] : Colors.red[800],
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => DeviceDetailScreen(device: d.stored)),
              );
              _load();
            },
          ),
        );
      },
    );
  }
}
