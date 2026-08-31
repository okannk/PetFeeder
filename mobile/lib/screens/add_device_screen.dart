import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../services/settings_service.dart';

// Cihaz kurulumunda ESP8266'nın açtığı AP'nin IP adresi
const _setupIp = '192.168.4.1';
const _setupTimeout = Duration(seconds: 30);
const _backendPollTimeout = Duration(seconds: 60);

class AddDeviceScreen extends StatefulWidget {
  const AddDeviceScreen({super.key});

  @override
  State<AddDeviceScreen> createState() => _AddDeviceScreenState();
}

class _AddDeviceScreenState extends State<AddDeviceScreen> {
  int _step = 0;

  // Adım 2: Cihaz keşfi
  String? _deviceMac;
  String? _deviceAp;
  bool _discovering = false;
  String? _discoverError;

  // Adım 3: Bilgi formu
  final _nameController     = TextEditingController(text: 'PetFeeder');
  final _ssidController     = TextEditingController();
  final _passController     = TextEditingController();
  final _backendController  = TextEditingController();
  bool _passVisible         = false;
  bool _sending             = false;
  String? _sendError;

  // Adım 5: Backend'de bekleme
  bool _polling         = false;
  String? _pollError;
  int   _pollSecondsLeft = 60;

  @override
  void initState() {
    super.initState();
    _loadBackend();
  }

  Future<void> _loadBackend() async {
    final url = await SettingsService.getBaseUrl();
    // URL'den sadece host:port kısmını al (http:// prefix olmadan)
    final clean = url.replaceFirst(RegExp(r'^https?://'), '');
    setState(() => _backendController.text = clean.isNotEmpty ? clean : '192.168.1.x:3001');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _ssidController.dispose();
    _passController.dispose();
    _backendController.dispose();
    super.dispose();
  }

  // ─── ADIM 0: Cihazı prize tak ────────────────────────────────────────────
  Widget _buildStep0() => _StepShell(
    icon: Icons.power,
    iconColor: Colors.orange,
    title: 'Cihazı Prize Tak',
    body: const Text(
      'Mama kabını prize takın.\n\n'
      'LED ışığı çok hızlı yanıp sönmeye başladığında kurulum moduna girmiş demektir.',
      style: TextStyle(fontSize: 16, height: 1.6),
    ),
    buttonLabel: 'LED hızlı yanıp sönüyor →',
    onButton: () => setState(() => _step = 1),
  );

  // ─── ADIM 1: WiFi'ye bağlan ───────────────────────────────────────────────
  Widget _buildStep1() => _StepShell(
    icon: Icons.wifi,
    iconColor: Colors.blue,
    title: 'PetFeeder Ağına Bağlan',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'iPhone\'unuzda şu adımları takip edin:',
          style: TextStyle(fontSize: 16),
        ),
        const SizedBox(height: 16),
        _step1Row('1', 'Ayarlar uygulamasını aç'),
        _step1Row('2', 'WiFi\'ya dokun'),
        _step1Row('3', '"PetFeeder-XXXX" ağını seç'),
        _step1Row('4', 'Bu uygulamaya geri dön'),
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
                  'Şifre: petfeeder123\n(config.h dosyasından değiştirebilirsin)',
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
      setState(() => _step = 2);
      _startDiscovery();
    },
  );

  Widget _step1Row(String num, String text) => Padding(
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
          child: Text(num, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 15))),
      ],
    ),
  );

  // ─── ADIM 2: Cihaz keşfi ──────────────────────────────────────────────────
  void _startDiscovery() {
    setState(() { _discovering = true; _discoverError = null; });

    final deadline = DateTime.now().add(_setupTimeout);

    Future.doWhile(() async {
      if (!mounted) return false;
      if (DateTime.now().isAfter(deadline)) {
        if (mounted) setState(() {
          _discovering = false;
          _discoverError = 'Cihaz bulunamadı.\nPetFeeder WiFi ağına bağlı olduğundan emin ol.';
        });
        return false;
      }
      try {
        final resp = await http.get(
          Uri.parse('http://$_setupIp/info'),
        ).timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          if (mounted) setState(() {
            _discovering  = false;
            _deviceMac    = data['mac']?.toString() ?? '';
            _deviceAp     = data['ap']?.toString()  ?? '';
            _step = 3;
          });
          return false;
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 2));
      return true;
    });
  }

  Widget _buildStep2() => Scaffold(
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
            Text(_discoverError!, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Tekrar Dene'),
              onPressed: () {
                setState(() => _step = 1);
              },
            ),
          ],
        ],
      ),
    ),
  );

  // ─── ADIM 3: Bilgi formu ──────────────────────────────────────────────────
  Widget _buildStep3() => Scaffold(
    appBar: AppBar(title: const Text('Cihaz Bilgileri')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cihaz bulundu bandı
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
                Expanded(
                  child: Text(
                    'Cihaz bulundu ✓\n${_deviceAp ?? ''}\n${_deviceMac ?? ''}',
                    style: TextStyle(color: Colors.green[800], fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _label('Cihaz Adı'),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Örn: Misket\'in Kabı',
            ),
          ),
          const SizedBox(height: 16),
          _label('Ev WiFi Adı (SSID)'),
          TextField(
            controller: _ssidController,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'Ev ağının adı',
            ),
          ),
          const SizedBox(height: 16),
          _label('Ev WiFi Şifresi'),
          TextField(
            controller: _passController,
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
          const SizedBox(height: 16),
          _label('Backend Adresi'),
          const Text(
            'Cihazın bağlanacağı yerel sunucu adresi (IP:port)',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _backendController,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '192.168.1.10:3001',
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
              onPressed: _sending ? null : _sendConfig,
              child: Text(_sending ? 'Gönderiliyor...' : 'Cihazı Kur →'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
  );

  Future<void> _sendConfig() async {
    final ssid  = _ssidController.text.trim();
    final name  = _nameController.text.trim();
    final back  = _backendController.text.trim();

    if (ssid.isEmpty) {
      setState(() => _sendError = 'WiFi adı gerekli');
      return;
    }
    if (back.isEmpty) {
      setState(() => _sendError = 'Backend adresi gerekli');
      return;
    }

    // host:port ayrıştır
    final parts  = back.split(':');
    final host   = parts[0];
    final port   = parts.length > 1 ? int.tryParse(parts[1]) ?? 3001 : 3001;

    setState(() { _sending = true; _sendError = null; });

    try {
      final resp = await http.post(
        Uri.parse('http://$_setupIp/configure'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'ssid':     ssid,
          'password': _passController.text,
          'host':     host,
          'port':     port,
          'name':     name.isNotEmpty ? name : 'PetFeeder',
        }),
      ).timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        if (!mounted) return;
        setState(() { _sending = false; _step = 4; });
      } else {
        setState(() {
          _sending   = false;
          _sendError = 'Hata: ${resp.statusCode} — ${resp.body}';
        });
      }
    } catch (e) {
      setState(() {
        _sending   = false;
        _sendError = 'Bağlantı hatası: $e';
      });
    }
  }

  // ─── ADIM 4: Ev WiFi'na geri dön ─────────────────────────────────────────
  Widget _buildStep4() => _StepShell(
    icon: Icons.swap_horiz,
    iconColor: Colors.purple,
    title: 'Ev WiFi\'na Geri Bağlan',
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Cihaz yapılandırıldı ve yeniden başlatılıyor.\n\n'
          'Şimdi iPhone\'unuzu ev WiFi ağınıza geri bağlayın:',
          style: TextStyle(fontSize: 16, height: 1.6),
        ),
        const SizedBox(height: 16),
        _step1Row('1', 'Ayarlar → WiFi'),
        _step1Row('2', 'Ev ağını seç'),
        _step1Row('3', 'Bu uygulamaya geri dön'),
      ],
    ),
    buttonLabel: 'Ev ağına bağlandım →',
    onButton: () {
      setState(() { _step = 5; _pollSecondsLeft = 60; });
      _startPolling();
    },
  );

  // ─── ADIM 5: Backend'de cihaz bekleniyor ─────────────────────────────────
  void _startPolling() async {
    setState(() { _polling = true; _pollError = null; });

    // Geri sayım timer
    Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _pollSecondsLeft--);
      if (_pollSecondsLeft <= 0) t.cancel();
    });

    final baseUrl = await SettingsService.getBaseUrl();
    final apiKey  = await SettingsService.getApiKey();
    final deadline = DateTime.now().add(_backendPollTimeout);

    await Future.doWhile(() async {
      if (!mounted) return false;
      if (DateTime.now().isAfter(deadline)) {
        if (mounted) setState(() {
          _polling   = false;
          _pollError = 'Cihaz ${_backendPollTimeout.inSeconds} saniye içinde görünmedi.\n'
                       'Backend çalışıyor mu? Cihaz ev ağına bağlandı mı?';
        });
        return false;
      }
      try {
        final resp = await http.get(
          Uri.parse('$baseUrl/api/devices'),
          headers: { if (apiKey.isNotEmpty) 'X-Api-Key': apiKey },
        ).timeout(const Duration(seconds: 4));
        if (resp.statusCode == 200) {
          final list = jsonDecode(resp.body) as List;
          // Yeni eklenen cihaz: son 60 saniye içinde lastSeenAt olanı bul
          final cutoff = DateTime.now().subtract(const Duration(seconds: 90));
          final found = list.any((d) {
            final seen = DateTime.tryParse(d['lastSeenAt'] ?? '');
            return seen != null && seen.isAfter(cutoff);
          });
          if (found) {
            if (mounted) setState(() { _polling = false; _step = 6; });
            return false;
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 3));
      return true;
    });
  }

  Widget _buildStep5() => Scaffold(
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
              'Cihazın backend\'e bağlanması bekleniyor...\n$_pollSecondsLeft sn',
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
                setState(() { _pollSecondsLeft = 60; _pollError = null; });
                _startPolling();
              },
            ),
          ],
        ],
      ),
    ),
  );

  // ─── ADIM 6: Başarı ───────────────────────────────────────────────────────
  Widget _buildStep6() => Scaffold(
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
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            const Text(
              'Cihaz artık cihaz listesinde görünüyor.\nBesleme programını ayarlamayı unutma.',
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
            Center(
              child: Icon(icon, size: 72, color: iconColor),
            ),
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
