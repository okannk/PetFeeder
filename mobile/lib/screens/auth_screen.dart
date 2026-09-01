import 'package:flutter/material.dart';
import '../services/backend_service.dart';
import 'device_list_screen.dart';

/// Giriş / Kayıt ekranı.
/// Başarılı auth sonrası DeviceListScreen'e geçer.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  // Login form
  final _loginEmailCtrl = TextEditingController();
  final _loginPassCtrl = TextEditingController();
  bool _loginPassVisible = false;
  bool _loginLoading = false;
  String? _loginError;

  // Register form
  final _regEmailCtrl = TextEditingController();
  final _regPassCtrl = TextEditingController();
  final _regPass2Ctrl = TextEditingController();
  bool _regPassVisible = false;
  bool _regLoading = false;
  String? _regError;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _loginEmailCtrl.dispose();
    _loginPassCtrl.dispose();
    _regEmailCtrl.dispose();
    _regPassCtrl.dispose();
    _regPass2Ctrl.dispose();
    super.dispose();
  }

  // ─── Login ────────────────────────────────────────────────────────────────

  Future<void> _login() async {
    final email = _loginEmailCtrl.text.trim();
    final pass  = _loginPassCtrl.text;
    if (email.isEmpty || pass.isEmpty) {
      setState(() => _loginError = 'E-posta ve şifre gerekli');
      return;
    }
    setState(() { _loginLoading = true; _loginError = null; });
    try {
      await BackendService.login(email, pass);
      if (!mounted) return;
      _goHome();
    } catch (e) {
      setState(() { _loginLoading = false; _loginError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  // ─── Register ─────────────────────────────────────────────────────────────

  Future<void> _register() async {
    final email = _regEmailCtrl.text.trim();
    final pass  = _regPassCtrl.text;
    final pass2 = _regPass2Ctrl.text;

    if (email.isEmpty || pass.isEmpty) {
      setState(() => _regError = 'E-posta ve şifre gerekli');
      return;
    }
    if (pass.length < 6) {
      setState(() => _regError = 'Şifre en az 6 karakter olmalı');
      return;
    }
    if (pass != pass2) {
      setState(() => _regError = 'Şifreler eşleşmiyor');
      return;
    }

    setState(() { _regLoading = true; _regError = null; });
    try {
      await BackendService.register(email, pass);
      if (!mounted) return;
      _goHome();
    } catch (e) {
      setState(() { _regLoading = false; _regError = e.toString().replaceFirst('Exception: ', ''); });
    }
  }

  void _goHome() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const DeviceListScreen()),
    );
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
              child: Column(
                children: [
                  Icon(Icons.pets, size: 56, color: scheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    'PetFeeder',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: scheme.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Akıllı mama kabı kontrolü',
                    style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
                  ),
                ],
              ),
            ),

            // Tabs
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: 'Giriş Yap'),
                Tab(text: 'Kayıt Ol'),
              ],
            ),

            // Tab views
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildLoginTab(),
                  _buildRegisterTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          TextField(
            controller: _loginEmailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'E-posta',
              prefixIcon: Icon(Icons.email_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _loginPassCtrl,
            obscureText: !_loginPassVisible,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'Şifre',
              prefixIcon: const Icon(Icons.lock_outlined),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_loginPassVisible
                    ? Icons.visibility_off
                    : Icons.visibility),
                onPressed: () =>
                    setState(() => _loginPassVisible = !_loginPassVisible),
              ),
            ),
          ),
          if (_loginError != null) ...[
            const SizedBox(height: 12),
            _errorBox(_loginError!),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _loginLoading ? null : _login,
            child: _loginLoading
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Giriş Yap'),
          ),
        ],
      ),
    );
  }

  Widget _buildRegisterTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          TextField(
            controller: _regEmailCtrl,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newUsername],
            decoration: const InputDecoration(
              labelText: 'E-posta',
              prefixIcon: Icon(Icons.email_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _regPassCtrl,
            obscureText: !_regPassVisible,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: 'Şifre (en az 6 karakter)',
              prefixIcon: const Icon(Icons.lock_outlined),
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(
                    _regPassVisible ? Icons.visibility_off : Icons.visibility),
                onPressed: () =>
                    setState(() => _regPassVisible = !_regPassVisible),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _regPass2Ctrl,
            obscureText: !_regPassVisible,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _register(),
            decoration: const InputDecoration(
              labelText: 'Şifre tekrar',
              prefixIcon: Icon(Icons.lock_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          if (_regError != null) ...[
            const SizedBox(height: 12),
            _errorBox(_regError!),
          ],
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _regLoading ? null : _register,
            child: _regLoading
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('Kayıt Ol'),
          ),
        ],
      ),
    );
  }

  Widget _errorBox(String message) {
    return Container(
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
            child: Text(
              message,
              style: TextStyle(color: Colors.red[800], fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
