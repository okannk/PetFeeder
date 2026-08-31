import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../models/device.dart';
import '../services/api_service.dart';
import '../services/device_storage.dart';
import '../services/notification_service.dart';

class DeviceDetailScreen extends StatefulWidget {
  final StoredDevice device;
  const DeviceDetailScreen({super.key, required this.device});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  final _api = ApiService();
  bool _online = false;
  List<ScheduleSlot> _slots = [];
  List<HistoryEntry> _history = [];
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
      final status  = await _api.fetchStatus(widget.device.host);
      final history = await _api.fetchHistory(widget.device.host);
      if (!mounted) return;
      setState(() {
        _online  = status.online;
        _slots   = List.from(status.schedule.slots);
        _history = history;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() { _online = false; _loading = false; });
    }
  }

  Future<void> _feed() async {
    setState(() => _feeding = true);
    try {
      final result = await _api.feed(widget.device.host, _feedPortions);
      if (!mounted) return;
      final msg = result['message']?.toString() ?? 'Besleme tamamlandı.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
      await NotificationService.showNow('PetFeeder — ${widget.device.name}', msg);
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Besleme başarısız: $e')));
    } finally {
      if (mounted) setState(() => _feeding = false);
      _load();
    }
  }

  Future<void> _saveSchedule() async {
    setState(() => _savingSchedule = true);
    try {
      await _api.updateSchedule(widget.device.host, Schedule(slots: _slots));
      await NotificationService.scheduleFeedings(
          widget.device.id, widget.device.name, _slots);
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Zamanlama kaydedildi.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Kaydedilemedi: $e')));
    } finally {
      if (mounted) setState(() => _savingSchedule = false);
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: widget.device.name);
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
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('Kaydet')),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      try {
        await _api.renameDevice(widget.device.host, result);
        final updated = widget.device.copyWith(name: result);
        await DeviceStorage.update(updated);
        if (mounted) Navigator.of(context).pop(true);
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cihazı Kaldır'),
        content: Text('${widget.device.name} listeden kaldırılacak.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false), child: const Text('İptal')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await DeviceStorage.remove(widget.device.id);
      await NotificationService.cancelDevice(widget.device.id);
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'rename') _rename();
              if (v == 'delete') _delete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('Yeniden Adlandır'),
                      contentPadding: EdgeInsets.zero)),
              PopupMenuItem(
                  value: 'delete',
                  child: ListTile(
                      leading: Icon(Icons.delete_outline, color: Colors.red),
                      title: Text('Listeden Kaldır',
                          style: TextStyle(color: Colors.red)),
                      contentPadding: EdgeInsets.zero)),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _buildStatusFeedCard(),
                  const SizedBox(height: 16),
                  if (_slots.isNotEmpty) _buildScheduleCard(),
                  if (_slots.isNotEmpty) const SizedBox(height: 16),
                  if (_history.isNotEmpty) _buildChartCard(),
                  if (_history.isNotEmpty) const SizedBox(height: 16),
                  _buildHistoryCard(),
                ],
              ),
            ),
    );
  }

  Widget _buildStatusFeedCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(_online ? Icons.wifi : Icons.wifi_off,
                  size: 18,
                  color: _online ? Colors.green[700] : Colors.red[700]),
              const SizedBox(width: 6),
              Text(
                _online ? 'Çevrimiçi' : 'Çevrimdışı',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _online ? Colors.green[700] : Colors.red[700],
                ),
              ),
              const Spacer(),
              Text(widget.device.host,
                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const Text('Porsiyon: '),
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: _feedPortions > 1
                    ? () => setState(() => _feedPortions--)
                    : null,
              ),
              Text('$_feedPortions',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: _feedPortions < 10
                    ? () => setState(() => _feedPortions++)
                    : null,
              ),
            ]),
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: (_online && !_feeding) ? _feed : null,
                icon: const Icon(Icons.restaurant),
                label: Text(_feeding ? 'Besleniyor...' : 'Şimdi Besle'),
              ),
            ),
          ]),
        ),
      );

  Widget _buildScheduleCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Besleme Zamanlaması',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
            const SizedBox(height: 4),
            const Text('Zamanlamayı kaydettiğinde bildirim de ayarlanır.',
                style: TextStyle(color: Colors.grey, fontSize: 11)),
            const SizedBox(height: 12),
            ...List.generate(_slots.length, _buildSlotRow),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonal(
                onPressed: _savingSchedule ? null : _saveSchedule,
                child: Text(_savingSchedule
                    ? 'Kaydediliyor...'
                    : 'Zamanlamayı Kaydet'),
              ),
            ),
          ]),
        ),
      );

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
                color: slot.enabled
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              )),
        ),
        Switch(
          value: slot.enabled,
          onChanged: (v) =>
              setState(() => _slots[i] = slot.copyWith(enabled: v)),
        ),
        Expanded(
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _numPad(slot.hour, 0, 23,
                (v) => setState(() => _slots[i] = slot.copyWith(hour: v)),
                pad: true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Text(':',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
            _numPad(slot.minute, 0, 59,
                (v) => setState(() => _slots[i] = slot.copyWith(minute: v)),
                pad: true),
          ]),
        ),
        Row(children: [
          const Icon(Icons.restaurant, size: 13, color: Colors.grey),
          const SizedBox(width: 2),
          _numPad(slot.portions, 1, 10,
              (v) => setState(() => _slots[i] = slot.copyWith(portions: v))),
        ]),
      ]),
    );
  }

  Widget _numPad(int value, int min, int max, ValueChanged<int> onChange,
      {bool pad = false}) {
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
        child: Text(label,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w500)),
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

  Widget _buildChartCard() {
    final now = DateTime.now();
    final Map<int, int> counts = {for (int i = 0; i < 7; i++) i: 0};
    for (final h in _history) {
      final dt = DateTime.tryParse(h.ts)?.toLocal();
      if (dt == null) continue;
      final diff = now.difference(dt).inDays;
      if (diff >= 0 && diff < 7) counts[diff] = (counts[diff] ?? 0) + 1;
    }

    final maxY = (counts.values.reduce((a, b) => a > b ? a : b) + 1)
        .toDouble()
        .clamp(4.0, 20.0);

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
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey))
                        : const SizedBox.shrink(),
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 20,
                    getTitlesWidget: (v, _) {
                      final idx = v.toInt();
                      if (idx < 0 || idx >= labels.length)
                        return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(labels[idx],
                            style: const TextStyle(
                                fontSize: 9, color: Colors.grey)),
                      );
                    },
                  ),
                ),
                topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
                rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false)),
              ),
              barTouchData: BarTouchData(
                touchTooltipData: BarTouchTooltipData(
                  getTooltipColor: (_) =>
                      Theme.of(context).colorScheme.inverseSurface,
                  getTooltipItem: (_, __, rod, ___) => BarTooltipItem(
                    '${rod.toY.toInt()} besleme',
                    TextStyle(
                      fontSize: 11,
                      color:
                          Theme.of(context).colorScheme.onInverseSurface,
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

  Widget _buildHistoryCard() {
    if (_history.isEmpty) {
      return const Text('Henüz kayıt yok.',
          style: TextStyle(color: Colors.grey));
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
                      '${_fmtTs(h.ts)} — ${h.msg ?? '${h.portions} porsiyon'}',
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

String _fmtTs(String s) {
  // ISO format → yerel saat
  final dt = DateTime.tryParse(s)?.toLocal();
  if (dt == null) return s; // "boot+XXs" gibi
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(dt.day)}.${z(dt.month)}.${dt.year} ${z(dt.hour)}:${z(dt.minute)}';
}
