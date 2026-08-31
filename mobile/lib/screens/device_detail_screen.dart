import 'package:flutter/material.dart';
import '../models/device.dart';
import '../services/api_service.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String deviceId;
  const DeviceDetailScreen({super.key, required this.deviceId});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  final _api = ApiService();
  Device? _device;
  List<HistoryEntry> _history = [];
  bool _loading = true;
  bool _feeding = false;
  bool _savingSchedule = false;
  int _feedPortions = 1;

  ScheduleSlot _morning = ScheduleSlot(enabled: false, hour: 8, minute: 0, portions: 1);
  ScheduleSlot _evening = ScheduleSlot(enabled: false, hour: 18, minute: 0, portions: 1);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final devices = await _api.fetchDevices();
      final device = devices.firstWhere((d) => d.id == widget.deviceId);
      final history = await _api.fetchHistory(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _device = device;
        _morning = device.schedule.morning;
        _evening = device.schedule.evening;
        _history = history;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
    }
  }

  Future<void> _feed() async {
    setState(() => _feeding = true);
    try {
      final result = await _api.feed(widget.deviceId, _feedPortions);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result['message']?.toString() ?? 'Besleme tamamlandi.')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Besleme basarisiz: $e')));
      }
    } finally {
      if (mounted) setState(() => _feeding = false);
      _load();
    }
  }

  Future<void> _saveSchedule() async {
    setState(() => _savingSchedule = true);
    try {
      await _api.updateSchedule(widget.deviceId, Schedule(morning: _morning, evening: _evening));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Zamanlama kaydedildi.')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kaydedilemedi: $e')));
      }
    } finally {
      if (mounted) setState(() => _savingSchedule = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_device?.name ?? 'Cihaz')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _device == null
              ? const Center(child: Text('Cihaz bulunamadi.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildFeedCard(),
                      const SizedBox(height: 16),
                      _buildScheduleCard('🌅 Sabah beslemesi', _morning, (s) => setState(() => _morning = s)),
                      const SizedBox(height: 12),
                      _buildScheduleCard('🌙 Aksam beslemesi', _evening, (s) => setState(() => _evening = s)),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonal(
                          onPressed: _savingSchedule ? null : _saveSchedule,
                          child: Text(_savingSchedule ? 'Kaydediliyor...' : 'Zamanlamayi Kaydet'),
                        ),
                      ),
                      const SizedBox(height: 24),
                      const Text('Son beslemeler', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      if (_history.isEmpty)
                        const Text('Henuz kayit yok.', style: TextStyle(color: Colors.grey)),
                      ..._history.map((h) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Text('${_formatDate(h.ts)} — ${h.message ?? h.status ?? ''}'),
                          )),
                    ],
                  ),
                ),
    );
  }

  Widget _buildFeedCard() {
    final device = _device!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              device.online ? 'Cevrimici' : 'Cevrimdisi',
              style: TextStyle(
                color: device.online ? Colors.green[700] : Colors.red[700],
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Porsiyon: '),
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: _feedPortions > 1 ? () => setState(() => _feedPortions--) : null,
                ),
                Text('$_feedPortions', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  onPressed: _feedPortions < 10 ? () => setState(() => _feedPortions++) : null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (device.online && !_feeding) ? _feed : null,
                icon: const Icon(Icons.restaurant),
                label: Text(_feeding ? 'Besleniyor...' : 'Simdi Besle'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScheduleCard(String title, ScheduleSlot slot, ValueChanged<ScheduleSlot> onChange) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
                Switch(
                  value: slot.enabled,
                  onChanged: (v) => onChange(slot.copyWith(enabled: v)),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _numberField('Saat', slot.hour, 0, 23, (v) => onChange(slot.copyWith(hour: v))),
                _numberField('Dakika', slot.minute, 0, 59, (v) => onChange(slot.copyWith(minute: v))),
                _numberField('Porsiyon', slot.portions, 1, 10, (v) => onChange(slot.copyWith(portions: v))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _numberField(String label, int value, int min, int max, ValueChanged<int> onChange) {
    return Column(
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.remove, size: 18),
              onPressed: value > min ? () => onChange(value - 1) : null,
            ),
            SizedBox(width: 28, child: Text('$value', textAlign: TextAlign.center)),
            IconButton(
              icon: const Icon(Icons.add, size: 18),
              onPressed: value < max ? () => onChange(value + 1) : null,
            ),
          ],
        ),
      ],
    );
  }
}

String _formatDate(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(dt.day)}.${two(dt.month)}.${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
}
