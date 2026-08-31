import 'package:flutter/material.dart';
import 'screens/device_list_screen.dart';

void main() {
  runApp(const PetFeederApp());
}

class PetFeederApp extends StatelessWidget {
  const PetFeederApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PetFeeder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF2F7D5F),
      ),
      home: const DeviceListScreen(),
    );
  }
}
