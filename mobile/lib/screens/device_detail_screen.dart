import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/device.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';

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
  List<ScheduleSlot> _slots = [];
  bool _loading = true;
  bool _feeding = false;
  bool _savingSchedule = false;
  int _feedPortions = 1;

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
      final history = await _api.fetchHistory(widget.deviceId, limit: 50);
      if (!mounted) return;
      setState(() {
        _device = device;
        _slots = List.from(device.schedule.slots);
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
    final device = _device!;
    setState(() => _feeding = true);
    try {
      final result = await _api.feed(device.id, _feedPortions);
      if (!mounted) return;
      final msg = result['message']?.toString() ?? 'Besleme tamamlandı.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      await NotificationService.showNow('PetFeeder — ${device.name}', msg);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Besleme başarısız: $e')));
    } finally {
      if (mounted) setState(() => _feeding = false);
      _load();
    }
  }

  Future<void> _saveSchedule() async {
    final device = _device!;
    setState(() => _savingSchedule = true);
    try {
      await _api.updateSchedule(device.id, Schedule(slots: _slots));
      await NotificationService.scheduleFeedings(device.id, device.name, _slots);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Zamanlama kaydedildi.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kaydedilemedi: $e')));
    } finally {
      if (mounted) setState(() => _savingSchedule = false);
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: _device?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cihazı Yeniden Adlandır'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('İptal')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()), child: const Text('Kaydet')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty && mounted) {
      try {
        final updated = await _api.renameDevice(widget.deviceId, result);
        setState(() => _device = updated);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cihazı Sil'),
        content: Text('${_device?.name ?? 'Bu cihaz'} kalıcı olarak silinecek.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('İptal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      try {
        await _api.deleteDevice(widget.deviceId);
        await NotificationService.cancelDevice(widget.deviceId);
        if (mounted) Navigator.of(context).pop(true);
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Silme başarısız: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_device?.name ?? 'Cihaz'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _rename();
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: ListTile(
                leading: Icon(Icons.edit_outlined), title: Text('Yeniden Adlandır'), contentPadding: EdgeInsets.zero)),
              PopupMenuItem(value: 'delete', child: ListTile(
                leading: Icon(Icons.delete_outline, color: Colors.red),
                title: Text('Cihazı Sil', style: TextStyle(color: Colors.red)),
                contentPadding: EdgeInsets.zero)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _device == null
              ? const Center(child: Text('Cihaz bulunamadı.'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildStatusFeedCard(),
                      const SizedBox(height: 16),
                      _buildScheduleCard(),
                      const SizedBox(height: 16),
                      if (_history.isNotEmpty) _buildChartCard(),
                      if (_history.isNotEmpty) const SizedBox(height: 16),
                      _buildHistoryCard(),
                    ],
                  ),
                ),
    );
  }

  // ── Durum + Manuel Besleme ──────────────────────────────────────────────────
  Widget _buildStatusFeedCard() {
    final device = _device!;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(device.online ? Icons.wifi : Icons.wifi_off,
                size: 18, color: device.online ? Colors.green[700] : Colors.red[700]),
            const SizedBox(width: 6),
            Text(
              device.online ? 'Çevrimiçi' : 'Çevrimdışı',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: device.online ? Colors.green[700] : Colors.red[700],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
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
          ]),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (device.online && !_feeding) ? _feed : null,
              icon: const Icon(Icons.restaurant),
              label: Text(_feeding ? 'Besleniyor...' : 'Şimdi Besle'),
            ),
          ),
        ]),
      ),
    );
  }

  // ── Çoklu öğün zamanlaması ─────────────────────────────────────────────────
  Widget _buildScheduleCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Besleme Zamanlaması',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 4),
          const Text('Zamanlamayı kaydettiğinde telefon bildirimi de ayarlanır.',
              style: TextStyle(color: Colors.grey, fontSize: 11)),
          const SizedBox(height: 12),
          ...List.generate(_slots.length, _buildSlotRow),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: _savingSchedule ? null : _saveSchedule,
              child: Text(_savingSchedule ? 'Kaydediliyor...' : 'Zamanlamayı Kaydet'),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildSlotRow(int i) {
    final slot = _slots[i];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        SizedBox(
          width: 50,
          child: Text(slot.label,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: slot.enabled ? Theme.of(context).colorScheme.primary : Colors.grey,
              )),
        ),
        Switch(
          value: slot.enabled,
          onChanged: (v) => setState(() => _slots[i] = slot.copyWith(enabled: v)),
        ),
        Expanded(
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _numPad(slot.hour, 0, 23, (v) => setState(() => _slots[i] = slot.copyWith(hour: v)), pad: true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Text(':', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            _numPad(slot.minute, 0, 59, (v) => setState(() => _slots[i] = slot.copyWith(minute: v)), pad: true),
          ]),
        ),
        Row(children: [
          const Icon(Icons.restaurant, size: 13, color: Colors.grey),
          const SizedBox(width: 2),
          _numPad(slot.portions, 1, 10, (v) => setState(() => _slots[i] = slot.copyWith(portions: v))),
        ]),
      ]),
    );
  }

  Widget _numPad(int value, int min, int max, ValueChanged<int> onChange, {bool pad = false}) {
    final label = pad ? value.toString().padLeft(2, '0') : value.toString();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 22, height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 15,
          icon: const Icon(Icons.remove),
          onPressed: value > min ? () => onChange(value - 1) : null,
        ),
      ),
      SizedBox(
        width: 26,
        child: Text(label, textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
      ),
      SizedBox(
        width: 22, height: 30,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 15,
          icon: const Icon(Icons.add),
          onPressed: value < max ? () => onChange(value + 1) : null,
        ),
      ),
    ]);
  }

  // ── Besleme geçmişi grafiği ─────────────────────────────────────────────────
  Widget _buildChartCard() {
    final now = DateTime.now();
    final Map<int, int> counts = {for (int i = 0; i < 7; i++) i: 0};
    for (final h in _history) {
      final dt = DateTime.tryParse(h.ts)?.toLocal();
      if (dt == null) continue;
      final diff = now.difference(dt).inDays;
      if (diff >= 0 && diff < 7) counts[diff] = (counts[diff] ?? 0) + 1;
    }

    // FIX: clamp with double literals so return type is double, not num
    final maxY = (counts.values.reduce((a, b) => a > b ? a : b) + 1).toDouble().clamp(4.0, 20.0);

    final bars = List.generate(7, (i) {
      final day = 6 - i;
      return BarChartGroupData(x: i, barRods: [
        BarChartRodData(
          toY: (counts[day] ?? 0).toDouble(),
          color: Theme.of(context).colorScheme.primary,
          width: 18,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
        ),
      ]);
    });

    final labels = List.generate(7, (i) {
      final d = now.subtract(Duration(days: 6 - i));
      return '${d.day}/${d.month}';
    });

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Son 7 Gün',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 16),
          SizedBox(
            height: 130,
            child: BarChart(BarChartData(
              maxY: maxY,
              barGroups: bars,
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: 1,
                getDrawingHorizontalLine: (v) =>
                    FlLine(color: Colors.grey.withOpacity(0.15), strokeWidth: 1),
              ),
              borderData: FlBorderData(show: false),
              titlesData: FlTitlesData(
                leftTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 20,
                    interval: 1,
                    getTitlesWidget: (v, _) => v == v.floorToDouble()
                        ? Text(v.toInt().toString(),
                            style: const TextStyle(fontSize: 10, color: Colors.grey))
                        : const SizedBox.shrink(),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 20,
                    getTitlesWidget: (v, _) {
                      final idx = v.toInt();
                      if (idx < 0 || idx >= labels.length) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(labels[idx],
                            style: const TextStyle(fontSize: 9, color: Colors.grey)),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) => Theme.of(context).colorScheme.inverseSurface,
                  getTooltipItem: (_, __, rod, ___) => BarTooltipItem(
                    '${rod.toY.toInt()} besleme',
                    TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onInverseSurface,
                    ),
                  ),
                ),
              ),
            )),
          ),
        ]),
      ),
    );
  }

  // ── Besleme geçmişi listesi ─────────────────────────────────────────────────
  Widget _buildHistoryCard() {
    if (_history.isEmpty) {
      return const Text('Henüz kayıt yok.', style: TextStyle(color: Colors.grey));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Son Beslemeler',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          const SizedBox(height: 8),
          ..._history.take(15).map((h) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  Icon(Icons.circle, size: 6, color: Colors.grey[400]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_fmt(h.ts)} — ${h.message ?? h.status ?? ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ]),
              )),
        ]),
      ),
    );
  }
}

String _fmt(String iso) {
  final dt = DateTime.tryParse(iso)?.toLocal();
  if (dt == null) return iso;
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(dt.day)}.${z(dt.month)}.${dt.year} ${z(dt.hour)}:${z(dt.minute)}';
}
