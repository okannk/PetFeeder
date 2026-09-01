import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/backend_service.dart';

// ESP8266'nın kurulum AP'sinin IP adresi
const _setupIp = '192.168.4.1';
const _setupTimeout = Duration(seconds: 30);
const _backendPollTimeout = Duration(seconds: 90);

// Backend sunucu IP'si
const _backendIp = '92.5.176.9';

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  int _step = 0;

  // Adım 1: Cihaz adı + backend kayıt
  final _nameController = TextEditingController(text: 'PetFeeder');
  bool _registering = false;
  String? _registerError;

  // Backend'den gelen bilgiler
  String? _deviceId;
  String? _mqttUser;
  String? _mqttPass;

  // Adım 3: AP keşfi
  bool _discovering = false;
  String? _discoverError;

  // Adım 4: WiFi bilgileri formu
  final _ssidController = TextEditingController();
  final _passController = TextEditingController();
  bool _passVisible = false;
  bool _sending = false;
  String? _sendError;

  // Adım 6: Backend'de cihaz bekleme
  bool _polling = false;
  String? _pollError;
  int _pollSecondsLeft = 90;

  @override
  void dispose() {
    _nameController.dispose();
    _ssidController.dispose();
    _passController.dispose();
    super.dispose();
  }

  // ─── ADIM 0: Cihazı prize tak ────────────────────────────────────────────
  Widget _buildStep0() => _StepShell(
        icon: Icons.power,
        iconColor: Colors.orange,
        title: 'Cihazı Prize Tak',
        body: const Text(
          'Mama kabını prize takın.\n\n'
          'LED ışığı çok hızlı yanıp sönmeye başladığında '
          'kurulum moduna girmiş demektir.',
          style: TextStyle(fontSize: 16, height: 1.6),
        ),
        buttonLabel: 'LED hızlı yanıp sönüyor →',
        onButton: () => setState(() => _step = 1),
      );

  // ─── ADIM 1: Cihazı buluta kaydet (ev WiFi'ında) ──────────────────────────
  // Bu adım telefon hâlâ ev WiFi'ındayken çalışır — internet gerektirir.
  Widget _buildStep1() => Scaffold(
        appBar: AppBar(title: const Text('Cihaz Adı')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.blue[700]),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Telefon ev WiFi\'ına bağlı olmalı.\n'
                        'Cihaz buluta kaydedilecek.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text('Cihaz Adı',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Örn: Misket\'in Kabı',
                ),
              ),
              if (_registerError != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red[50],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red[200]!),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red[700], size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_registerError!,
                            style: TextStyle(color: Colors.red[800], fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _registering ? null : _registerDevice,
                  child: _registering
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Devam →'),
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> _registerDevice() async {
    setState(() { _registering = true; _registerError = null; });
    try {
      final creds = await BackendService.registerDevice(
        null, // id yok → backend UUID üretir
        _nameController.text.trim().isNotEmpty
            ? _nameController.text.trim()
            : 'PetFeeder',
      );
      _deviceId  = creds['id']       as String;
      _mqttUser  = creds['mqttUser'] as String;
      _mqttPass  = creds['mqttPass'] as String;
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

  // ─── ADIM 2: PetFeeder WiFi'na bağlan ────────────────────────────────────
  Widget _buildStep2() => _StepShell(
        icon: Icons.wifi,
        iconColor: Colors.blue,
        title: 'PetFeeder Ağına Bağlan',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Telefon ayarlarında:', style: TextStyle(fontSize: 16)),
            const SizedBox(height: 16),
            _stepRow('1', 'Ayarlar → WiFi'),
            _stepRow('2', '"PetFeeder-XXXX" ağını seç'),
            _stepRow('3', 'Bu uygulamaya geri dön'),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber[50],
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber[300]!),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock, size: 18, color: Colors.amber[800]),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'WiFi şifresi: petfeeder123',
                      style: TextStyle(color: Colors.amber[900], fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        buttonLabel: 'PetFeeder ağına bağlandım →',
        onButton: () {
          setState(() => _step = 3);
          _startDiscovery();
        },
      );

  Widget _stepRow(String num, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(num,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
          ],
        ),
      );

  // ─── ADIM 3: Cihaz keşfi (192.168.4.1/info) ───────────────────────────────
  void _startDiscovery() {
    setState(() { _discovering = true; _discoverError = null; });
    final deadline = DateTime.now().add(_setupTimeout);
    Future.doWhile(() async {
      if (!mounted) return false;
      if (DateTime.now().isAfter(deadline)) {
        if (mounted) {
          setState(() {
            _discovering = false;
            _discoverError =
                'Cihaz bulunamadı.\nPetFeeder WiFi ağına bağlı olduğundan emin ol.';
          });
        }
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
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
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
            ],
          ),
        ),
      );

  // ─── ADIM 4: WiFi bilgileri formu ─────────────────────────────────────────
  Widget _buildStep4() => Scaffold(
        appBar: AppBar(title: const Text('Ev WiFi Bilgileri')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green[50],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.green[300]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green[700]),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Cihaz bulundu ✓\nEv WiFi bilgilerini gir.',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text('Ev WiFi Adı (SSID)',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              TextField(
                controller: _ssidController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'Ev ağının adı',
                ),
              ),
              const SizedBox(height: 16),
              const Text('Ev WiFi Şifresi',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              TextField(
                controller: _passController,
                obscureText: !_passVisible,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: 'WiFi şifresi',
                  suffixIcon: IconButton(
                    icon: Icon(_passVisible
                        ? Icons.visibility_off
                        : Icons.visibility),
                    onPressed: () =>
                        setState(() => _passVisible = !_passVisible),
                  ),
                ),
              ),
              if (_sendError != null) ...[
                const SizedBox(height: 12),
                Text(_sendError!, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _sending ? null : _configureEsp,
                  child: Text(_sending ? 'Gönderiliyor...' : 'Cihazı Kur →'),
                ),
              ),
            ],
          ),
        ),
      );

  // ─── ADIM 5: ESP'yi yapılandır (sadece 192.168.4.1 — internet yok) ────────
  Future<void> _configureEsp() async {
    final ssid = _ssidController.text.trim();
    if (ssid.isEmpty) {
      setState(() => _sendError = 'Ev WiFi adı gerekli');
      return;
    }
    setState(() { _sending = true; _sendError = null; _step = 5; });
    try {
      final resp = await http
          .post(
            Uri.parse('http://$_setupIp/configure'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'ssid': ssid,
              'password': _passController.text,
              'name': _nameController.text.trim().isNotEmpty
                  ? _nameController.text.trim()
                  : 'PetFeeder',
              'mqtt_host': _backendIp,
              'mqtt_port': 1883,
              'mqtt_user': _mqttUser,
              'mqtt_pass': _mqttPass,
              'device_id': _deviceId,
            }),
          )
          .timeout(const Duration(seconds: 12));

      if (resp.statusCode != 200) {
        throw Exception('ESP yapılandırma hatası: ${resp.statusCode}');
      }
      if (!mounted) return;
      setState(() { _sending = false; _step = 6; });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = e.toString().replaceFirst('Exception: ', '');
        _step = 4;
      });
    }
  }

  Widget _buildStep5() => Scaffold(
        appBar: AppBar(title: const Text('Yapılandırılıyor...')),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 24),
              Text(
                'WiFi ve bulut bilgileri cihaza gönderiliyor...',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16),
              ),
            ],
          ),
        ),
      );

  // ─── ADIM 6: Ev WiFi'na geri dön ─────────────────────────────────────────
  Widget _buildStep6() => _StepShell(
        icon: Icons.swap_horiz,
        iconColor: Colors.purple,
        title: 'Ev WiFi\'na Geri Bağlan',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Cihaz yapılandırıldı ve yeniden başlatılıyor.\n\n'
              'Şimdi telefonunu ev WiFi ağına geri bağla:',
              style: TextStyle(fontSize: 16, height: 1.6),
            ),
            const SizedBox(height: 16),
            _stepRow('1', 'Ayarlar → WiFi'),
            _stepRow('2', 'Ev ağını seç'),
            _stepRow('3', 'Bu uygulamaya geri dön'),
          ],
        ),
        buttonLabel: 'Ev ağına bağlandım →',
        onButton: () {
          setState(() { _step = 7; _pollSecondsLeft = 90; });
          _startPolling();
        },
      );

  // ─── ADIM 7: Backend'de cihaz bekleniyor ─────────────────────────────────
  void _startPolling() async {
    setState(() { _polling = true; _pollError = null; });
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _pollSecondsLeft--);
      if (_pollSecondsLeft <= 0) t.cancel();
    });
    final deadline = DateTime.now().add(_backendPollTimeout);
    await Future.doWhile(() async {
      if (!mounted) return false;
      if (DateTime.now().isAfter(deadline)) {
        if (mounted) {
          setState(() {
            _polling = false;
            _pollError = 'Cihaz ${_backendPollTimeout.inSeconds} saniye içinde '
                'görünmedi.\nLED yavaş yanıp sönüyor mu? '
                'Ev WiFi adı/şifresini kontrol et.';
          });
        }
        return false;
      }
      try {
        final devices = await BackendService.getDevices();
        final cutoff = DateTime.now().subtract(const Duration(seconds: 120));
        final found = devices.any((d) {
          if (d.id != _deviceId) return false;
          if (d.online) return true;
          final seen = DateTime.tryParse(d.lastSeenAt ?? '');
          return seen != null && seen.isAfter(cutoff);
        });
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
        appBar: AppBar(title: const Text('Cihaz Bağlanıyor...')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_polling) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  'Cihazın buluta bağlanması bekleniyor...\n$_pollSecondsLeft sn',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Cihaz LED\'i yavaş yanıp sönmeye başlarsa bağlandı demektir.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ] else if (_pollError != null) ...[
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(_pollError!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('Tekrar Dene'),
                  onPressed: () {
                    setState(() { _pollSecondsLeft = 90; _pollError = null; });
                    _startPolling();
                  },
                ),
              ],
            ],
          ),
        ),
      );

  // ─── ADIM 8: Başarı ───────────────────────────────────────────────────────
  Widget _buildStep8() => Scaffold(
        appBar: AppBar(title: const Text('Cihaz Eklendi')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.check_circle, size: 80, color: Colors.green),
                const SizedBox(height: 24),
                Text(
                  '${_nameController.text} eklendi! 🎉',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                const Text(
                  'Cihaz artık cihaz listesinde görünüyor.\n'
                  'Besleme programını ayarlamayı unutma.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey, fontSize: 15),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('Cihaz Listesine Dön'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  // ─── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case 0:  return _buildStep0();
      case 1:  return _buildStep1();
      case 2:  return _buildStep2();
      case 3:  return _buildStep3();
      case 4:  return _buildStep4();
      case 5:  return _buildStep5();
      case 6:  return _buildStep6();
      case 7:  return _buildStep7();
      case 8:  return _buildStep8();
      default: return _buildStep0();
    }
  }
}

// ─── Yardımcı: Ortak adım kabuğu ─────────────────────────────────────────────
class _StepShell extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Widget body;
  final String buttonLabel;
  final VoidCallback onButton;

  const _StepShell({
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(child: Icon(icon, size: 72, color: iconColor)),
            const SizedBox(height: 24),
            Expanded(child: body),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: onButton,
                child: Text(buttonLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
