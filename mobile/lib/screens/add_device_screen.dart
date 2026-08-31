import 'dart:async';
import 'package:flutter/material.dart';
import '../models/device.dart';
import '../services/api_service.dart';
import '../services/device_storage.dart';
import '../services/notification_service.dart';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});
  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  final _api = ApiService();
  int _step = 0;

  // Keşif
  bool _discovering = false;
  Map<String, dynamic>? _deviceInfo; // /info yanıtı
  Timer? _discoverTimer;
  int _discoverElapsed = 0;

  // Form
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'PetFeeder');
  bool _passVisible = false;
  bool _configuring = false;

  // Bağlanma bekleme
  bool _polling = false;
  int _pollElapsed = 0;
  Timer? _pollTimer;
  String? _mdnsHost; // "petfeeder-aabb.local"
  bool _success = false;

  @override
  void dispose() {
    _discoverTimer?.cancel();
    _pollTimer?.cancel();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  // ─── Adım 0: Güce tak ───────────────────────────────────────────────────────
  Widget _step0() => _stepBody(
        icon: Icons.power_settings_new,
        color: Colors.orange,
        title: 'Cihazı Güce Tak',
        body: 'PetFeeder'i prize tak. LED hızlı yanıp sönmeye başlayacak — '
            'bu kurulum modunda olduğunu gösterir.',
        next: () => setState(() => _step = 1),
        nextLabel: 'Bağlandım, Devam',
      );

  // ─── Adım 1: PetFeeder WiFi'ye bağlan ──────────────────────────────────────
  Widget _step1() => _stepBody(
        icon: Icons.wifi,
        color: Colors.blue,
        title: 'PetFeeder WiFi\'ye Bağlan',
        body: 'Telefon ayarlarından "PetFeeder-XXXX" adlı ağa bağlan.\n'
            'Şifre: petfeeder123\n\n'
            'Bağlandıktan sonra bu uygulamaya geri dön.',
        next: () {
          setState(() => _step = 2);
          _startDiscovery();
        },
        nextLabel: 'Bağlandım',
      );

  // ─── Adım 2: Cihazı keşfet ──────────────────────────────────────────────────
  void _startDiscovery() {
    setState(() { _discovering = true; _discoverElapsed = 0; });
    _discoverTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted) return;
      setState(() => _discoverElapsed += 2);
      if (_discoverElapsed > 30) {
        _discoverTimer?.cancel();
        setState(() => _discovering = false);
        return;
      }
      try {
        final info = await _api.fetchDeviceInfo();
        if (!mounted) return;
        _discoverTimer?.cancel();
        setState(() { _deviceInfo = info; _discovering = false; _step = 3; });
      } catch (_) {}
    });
  }

  Widget _step2() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          const Text('Cihaz aranıyor...', style: TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          Text('${_discoverElapsed}s / 30s',
              style: const TextStyle(color: Colors.grey)),
          if (!_discovering) ...[
            const SizedBox(height: 24),
            const Text('Cihaz bulunamadı.\nPetFeeder-XXXX WiFi\'sine bağlı olduğundan emin ol.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _startDiscovery,
              child: const Text('Tekrar Dene'),
            ),
          ],
        ]),
      );

  // ─── Adım 3: WiFi bilgilerini gir ───────────────────────────────────────────
  Widget _step3() {
    final mdns = _deviceInfo?['mdns'] as String? ?? '';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.check_circle, color: Colors.green),
          const SizedBox(width: 8),
          Expanded(child: Text('Cihaz bulundu: $mdns',
              style: const TextStyle(fontWeight: FontWeight.bold))),
        ]),
        const SizedBox(height: 24),
        const Text('Cihaz Adı', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        TextField(
          controller: _nameCtrl,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), hintText: 'Mutfak PetFeeder'),
        ),
        const SizedBox(height: 16),
        const Text('Ev WiFi Adı (SSID)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        TextField(
          controller: _ssidCtrl,
          decoration: const InputDecoration(
              border: OutlineInputBorder(), hintText: 'WiFi ağ adı'),
        ),
        const SizedBox(height: 16),
        const Text('WiFi Şifre', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        TextField(
          controller: _passCtrl,
          obscureText: !_passVisible,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: 'WiFi şifresi',
            suffixIcon: IconButton(
              icon: Icon(_passVisible ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _passVisible = !_passVisible),
            ),
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _configuring ? null : _sendConfig,
            child: Text(_configuring ? 'Gönderiliyor...' : 'WiFi Bilgilerini Gönder'),
          ),
        ),
      ]),
    );
  }

  Future<void> _sendConfig() async {
    if (_ssidCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('WiFi adı boş olamaz')));
      return;
    }
    setState(() => _configuring = true);
    try {
      final resp = await _api.configureDevice(
          _ssidCtrl.text.trim(), _passCtrl.text, _nameCtrl.text.trim());
      final mdns = resp['mdns'] as String? ?? '';
      _mdnsHost = '$mdns.local';
      if (mounted) setState(() { _configuring = false; _step = 4; });
    } catch (e) {
      if (mounted) {
        setState(() => _configuring = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Hata: $e')));
      }
    }
  }

  // ─── Adım 4: Ev WiFi'sine geri bağlan ──────────────────────────────────────
  Widget _step4() => _stepBody(
        icon: Icons.home,
        color: Colors.green,
        title: 'Ev WiFi\'sine Geri Bağlan',
        body: 'Cihaz WiFi bilgilerini kaydetti ve yeniden başlatıyor.\n\n'
            'Şimdi telefon ayarlarından ev WiFi\'ine geri bağlan, '
            'sonra buraya dön.',
        next: () {
          setState(() => _step = 5);
          _startPolling();
        },
        nextLabel: 'Geri Bağlandım',
      );

  // ─── Adım 5: Cihazın ağa katılmasını bekle ──────────────────────────────────
  void _startPolling() {
    setState(() { _polling = true; _pollElapsed = 0; });
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      setState(() => _pollElapsed += 3);
      if (_pollElapsed > 90) {
        _pollTimer?.cancel();
        setState(() => _polling = false);
        return;
      }
      try {
        final host = _mdnsHost!;
        await _api.fetchStatus(host);
        // Başarılı → cihaz kaydet
        _pollTimer?.cancel();
        final device = StoredDevice(
          id: host.replaceAll('.local', ''),
          name: _nameCtrl.text.trim(),
          host: host,
        );
        await DeviceStorage.add(device);
        if (!mounted) return;
        setState(() { _polling = false; _success = true; _step = 6; });
      } catch (_) {}
    });
  }

  Widget _step5() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text('$_mdnsHost bekleniyor...',
              style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          Text('${_pollElapsed}s / 90s',
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          const Text(
              'ESP8266 WiFi\'ye bağlanıp mDNS adını duyurması\n30-60 saniye sürebilir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          if (!_polling) ...[
            const SizedBox(height: 24),
            const Text(
                'Cihaza ulaşılamadı.\nEv WiFi\'ine bağlı olduğundan emin ol.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.red)),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _startPolling,
              child: const Text('Tekrar Dene'),
            ),
          ],
        ]),
      );

  // ─── Adım 6: Başarılı ───────────────────────────────────────────────────────
  Widget _step6() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle, size: 80, color: Colors.green),
          const SizedBox(height: 24),
          Text('${_nameCtrl.text.trim()} eklendi!',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(_mdnsHost ?? '',
              style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Tamamla'),
            ),
          ),
        ]),
      );

  // ─── Ortak adım şablonu ─────────────────────────────────────────────────────
  Widget _stepBody({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
    required VoidCallback next,
    required String nextLabel,
  }) =>
      Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 72, color: color),
            const SizedBox(height: 24),
            Text(title,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 15, height: 1.5)),
            const SizedBox(height: 40),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: next,
                child: Text(nextLabel),
              ),
            ),
          ],
        ),
      );

  // ─── Build ──────────────────────────────────────────────────────────────────
  static const _titles = [
    'Cihaz Ekle (1/6)',
    'Cihaz Ekle (2/6)',
    'Cihaz Aranıyor (3/6)',
    'WiFi Bilgileri (4/6)',
    'Yeniden Bağlan (5/6)',
    'Bağlanma Bekleniyor (6/6)',
    'Tamamlandı',
  ];

  Widget _body() {
    switch (_step) {
      case 0: return _step0();
      case 1: return _step1();
      case 2: return _step2();
      case 3: return _step3();
      case 4: return _step4();
      case 5: return _step5();
      case 6: return _step6();
      default: return const SizedBox();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_step.clamp(0, _titles.length - 1)]),
      ),
      body: _body(),
    );
  }
}
