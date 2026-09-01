import 'package:flutter/material.dart';
import 'services/backend_service.dart';
import 'services/notification_service.dart';
import 'screens/auth_screen.dart';
import 'screens/device_list_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.init();

  // JWT var mı kontrol et
  final loggedIn = await BackendService.isLoggedIn();

  runApp(PetFeederApp(loggedIn: loggedIn));
}

class PetFeederApp extends StatelessWidget {
  final bool loggedIn;
  const PetFeederApp({super.key, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PetFeeder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F7D5F),
      ),
      home: loggedIn ? const DeviceListScreen() : const AuthScreen(),
    );
  }
}
