import 'package:flutter/material.dart';

void main() {
  runApp(const FlashyApp());
}

/// Root widget for the Flashy app.
///
/// Phase 1: Placeholder UI — the transfer engine is tested via
/// integration tests, not through the UI yet. The real UI comes
/// in Phase 2+.
class FlashyApp extends StatelessWidget {
  const FlashyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flashy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6C5CE7),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const Scaffold(
        body: Center(
          child: Text(
            'Flashy — P2P File Transfer\nPhase 1: Engine Built ✓',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 20),
          ),
        ),
      ),
    );
  }
}
