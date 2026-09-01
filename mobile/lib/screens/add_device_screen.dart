import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/backend_service.dart';

const _setupIp = '192.168.4.1';
const _setupTimeout = Duration(seconds: 45);

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  int _step = 0;

  // Adım 1: Cihaz adı ve backend kaydı
  final _nameCtrl = TextEditingController(text: 'PetFeeder');
  bool _registering = false;
  String? _registerError;

  // Backend'den gelen
  String? _deviceId;
  String? _mqttUser;
  String? _mqttPass;

  // Adım 3: ESP keşfi
  bool _discovering = false;
  String? _discoverError;

  // Adım 4: WiFi bilgileri
  final _ssidCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _passVisible = false;

  // Adım 5: ESP yapılandırma
  bool _configuring = false;
  String? _configError;

  // Adım 7: Backend polling
  bool _polling = false;
  String? _pollError;
  int _pollSecondsLeft = 60;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _ssidCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  // ─── ADIM 0: Cihazı prize tak ─────────────────────────────────────────────
  Widget _buildStep0() => _Shell(
        icon: Icons.power,
        iconColor: Colors.orange,
        title: 'Cihazı Prize Tak',
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'PetFeeder\'ı prize takın ve birkaç saniye bekleyin.\n'
            'Mavi LED yanıp sönmeye başladığında hazır demektir.',
            style: TextStyle(fontSize: 15, height: 1.6),
          ),
          const SizedBox(height: 16),
          _row('1', 'Cihazı prize takın'),
          _row('2', 'Mavi LED\'i bekleyin (5-10 sn)'),
        ]),
        buttonLabel: 'Hazır, devam et →',
        onButton: () => setState(() => _step = 1),
      );

  // ─── ADIM 1: Cihaz adı + backend kaydı ───────────────────────────────────
  Widget _buildStep1() => Scaffold(
        appBar: AppBar(title: const Text('Cihaz Ekle')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text(
              'Cihazınıza bir isim verin.',
              style: TextStyle(fontSize: 16, height: 1.5),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Cihaz Adı',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.pets),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _registerDevice(),
            ),
            if (_registerError != null) ...[
              const SizedBox(height: 12),
              Text(_registerError!,
                  style: const TextStyle(color: Colors.red, fontSize: 13)),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _registering ? null : _registerDevice,
              child: _registering
                  ? const SizedBox(
                      height: 18, width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Devam Et →'),
            ),
          ]),
        ),
      );

  Future<void> _registerDevice() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _registerError = 'Cihaz adı boş olamaz');
      return;
    }
    setState(() { _registering = true; _registerError = null; });
    try {
      final result = await BackendService.registerDevice(null, name);
      _deviceId = result['id'] as String?;
      _mqttUser = result['mqttUser'] as String?;
      _mqttPass = result['mqttPass'] as String?;
      if (!mounted) return;
      setState(() { _registering = false; _step = 2; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _registering = false;
        _registerError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  // ─── ADIM 2: PetFeeder AP'ye bağlan ──────────────────────────────────────
  Widget _buildStep2() => _Shell(
        icon: Icons.wifi,
        iconColor: Colors.blue,
        title: 'PetFeeder Ağına Bağlan',
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'iPhone\'unuzu PetFeeder\'ın WiFi ağına bağlayın:',
            style: TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 16),
          _row('1', 'Ayarlar → WiFi aç'),
          _row('2', '"PetFeeder-XXXX" ağını seç'),
          _row('3', 'Bu uygulamaya geri dön'),
        ]),
        buttonLabel: 'Bağlandım →',
        onButton: () {
          setState(() { _step = 3; _discovering = true; _discoverError = null; });
          _startDiscovery();
        },
      );

  // ─── ADIM 3: Cihaz keşfi ─────────────────────────────────────────────────
  void _startDiscovery() {
    final deadline = DateTime.now().add(_setupTimeout);
    Future.doWhile(() async {
      if (!mounted) return false;
      if (DateTime.now().isAfter(deadline)) {
        if (mounted) setState(() {
          _discovering = false;
          _discoverError =
              'Cihaz bulunamadı.\nPetFeeder WiFi ağına bağlı olduğundan emin ol.';
        });
        return false;
      }
      try {
        final resp = await http
            .get(Uri.parse('http://$_setupIp/info'))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          if (mounted) setState(() { _discovering = false; _step = 4; });
          return false;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
      return true;
    });
  }

  Widget _buildStep3() => Scaffold(
        appBar: AppBar(title: const Text('Cihaz Aranıyor...')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_discovering) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              const Text('192.168.4.1 adresinde cihaz aranıyor...',
                  textAlign: TextAlign.center),
            ] else if (_discoverError != null) ...[
              const Icon(Icons.wifi_off, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_discoverError!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16)),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar Dene'),
                onPressed: () => setState(() => _step = 2),
              ),
            ],
          ]),
        ),
      );

  // ─── ADIM 4: WiFi bilgileri ───────────────────────────────────────────────
  Widget _buildStep4() => Scaffold(
        appBar: AppBar(title: const Text('Ev WiFi Bilgileri')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text(
              'Cihazın bağlanacağı ev WiFi bilgilerini girin:',
              style: TextStyle(fontSize: 15),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _ssidCtrl,
              decoration: const InputDecoration(
                labelText: 'WiFi Adı (SSID)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.wifi),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passCtrl,
              obscureText: !_passVisible,
              decoration: InputDecoration(
                labelText: 'WiFi Şifresi',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.lock_outline),
                suffixIcon: IconButton(
                  icon: Icon(_passVisible ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _passVisible = !_passVisible),
                ),
              ),
            ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () {
                if (_ssidCtrl.text.trim().isEmpty) return;
                setState(() { _step = 5; _configuring = true; _configError = null; });
                _configureEsp();
              },
              child: const Text('Cihazı Kur →'),
            ),
          ]),
        ),
      );

  // ─── ADIM 5: ESP yapılandırma (otomatik) ─────────────────────────────────
  Future<void> _configureEsp() async {
    try {
      final resp = await http
          .post(
            Uri.parse('http://$_setupIp/configure'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'ssid':      _ssidCtrl.text.trim(),
              'password':  _passCtrl.text,
              'name':      _nameCtrl.text.trim(),
              'mqtt_host': '92.5.176.9',
              'mqtt_port': 1883,
              'mqtt_user': _mqttUser ?? '',
              'mqtt_pass': _mqttPass ?? '',
              'device_id': _deviceId ?? '',
            }),
          )
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      if (resp.statusCode == 200) {
        setState(() { _configuring = false; _step = 6; });
      } else {
        setState(() {
          _configuring = false;
          _configError = 'Hata: ${resp.statusCode} — ${resp.body}';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _configuring = false;
        _configError = 'Bağlantı hatası: $e';
      });
    }
  }

  Widget _buildStep5() => Scaffold(
        appBar: AppBar(title: const Text('Yapılandırılıyor...')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_configuring) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              const Text('Cihaz yapılandırılıyor...', textAlign: TextAlign.center),
            ] else if (_configError != null) ...[
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_configError!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar Dene'),
                onPressed: () {
                  setState(() { _configuring = true; _configError = null; });
                  _configureEsp();
                },
              ),
            ],
          ]),
        ),
      );

  // ─── ADIM 6: Ev WiFi'na geri dön ─────────────────────────────────────────
  Widget _buildStep6() => _Shell(
        icon: Icons.swap_horiz,
        iconColor: Colors.purple,
        title: 'Ev WiFi\'na Geri Bağlan',
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
            'Cihaz yapılandırıldı!\n\n'
            'Şimdi iPhone\'unuzu ev WiFi ağına geri bağlayın:',
            style: TextStyle(fontSize: 15, height: 1.6),
          ),
          const SizedBox(height: 16),
          _row('1', 'Ayarlar → WiFi'),
          _row('2', 'Ev ağını seç'),
          _row('3', 'Bu uygulamaya geri dön'),
        ]),
        buttonLabel: 'Ev ağına bağlandım →',
        onButton: () {
          setState(() {
            _step = 7;
            _polling = true;
            _pollError = null;
            _pollSecondsLeft = 60;
          });
          _startPolling();
        },
      );

  // ─── ADIM 7: Backend polling ──────────────────────────────────────────────
  void _startPolling() {
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _pollSecondsLeft--);
      if (_pollSecondsLeft <= 0) t.cancel();
    });

    final deadline = DateTime.now().add(const Duration(seconds: 60));
    Future.doWhile(() async {
      if (!mounted) return false;
      if (DateTime.now().isAfter(deadline)) {
        if (mounted) setState(() {
          _polling = false;
          _pollError =
              'Cihaz 60 saniye içinde görünmedi.\nCihaz ev ağına bağlandı mı?';
        });
        return false;
      }
      try {
        final devices = await BackendService.getDevices();
        final found = devices.any((d) => d.id == _deviceId);
        if (found) {
          if (mounted) setState(() { _polling = false; _step = 8; });
          return false;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 3));
      return true;
    });
  }

  Widget _buildStep7() => Scaffold(
        appBar: AppBar(title: const Text('Cihaz Bekleniyor...')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            if (_polling) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Cihaz bekleniyor... $_pollSecondsLeft sn',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 8),
              const Text(
                'Cihaz ev ağına bağlanıyor...',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ] else if (_pollError != null) ...[
              const Icon(Icons.wifi_off, size: 64, color: Colors.orange),
              const SizedBox(height: 16),
              Text(_pollError!, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Tekrar Dene'),
                onPressed: () {
                  setState(() {
                    _polling = true;
                    _pollError = null;
                    _pollSecondsLeft = 60;
                  });
                  _startPolling();
                },
              ),
            ],
          ]),
        ),
      );

  // ─── ADIM 8: Başarı ───────────────────────────────────────────────────────
  Widget _buildStep8() => Scaffold(
        appBar: AppBar(title: const Text('Kurulum Tamamlandı')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.check_circle, size: 80, color: Colors.green),
            const SizedBox(height: 24),
            Text(
              '${_nameCtrl.text.trim()} başarıyla eklendi!',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text('Cihaz artık çevrimiçi ve kullanıma hazır.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 32),
            FilledButton.icon(
              icon: const Icon(Icons.home),
              label: const Text('Ana Sayfaya Dön'),
              onPressed: () => Navigator.of(context).pop(true),
            ),
          ]),
        ),
      );

  // ─── Yardımcılar ──────────────────────────────────────────────────────────

  Widget _row(String num, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Container(
            width: 24, height: 24,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(num,
                style:
                    const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return switch (_step) {
      0 => _buildStep0(),
      1 => _buildStep1(),
      2 => _buildStep2(),
      3 => _buildStep3(),
      4 => _buildStep4(),
      5 => _buildStep5(),
      6 => _buildStep6(),
      7 => _buildStep7(),
      8 => _buildStep8(),
      _ => _buildStep0(),
    };
  }
}

// ─── Shell widget ────────────────────────────────────────────────────────────

class _Shell extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget body;
  final String buttonLabel;
  final VoidCallback onButton;

  const _Shell({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.buttonLabel,
    required this.onButton,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Icon(icon, size: 72, color: iconColor),
                ),
                const SizedBox(height: 24),
                body,
              ],
            ),
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onButton,
              child: Text(buttonLabel),
            ),
          ),
          const SizedBox(height: 8),
        ]),
      ),
    );
  }
}
