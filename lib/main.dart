import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'data/plantillas_initializer.dart';
import 'theme/app_theme.dart';
import 'pages/main_navigation_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Sync de inventario entre técnicos (ver lib/data/inventario_sync.dart).
  // Si el dispositivo no tiene internet en este momento, esto falla rápido
  // y la app sigue funcionando en modo local: Firestore reintenta la
  // conexión solo cuando vuelva la señal.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase no se pudo inicializar (¿sin internet?): $e');
  }

  // Inicializar plantillas en background sin bloquear la UI
  PlantillasInitializer.inicializar();
  runApp(const BTMCApp());
}

class BTMCApp extends StatelessWidget {
  const BTMCApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BTMC Certificados',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('es', 'CO'),
        Locale('en', 'US'),
      ],
      locale: const Locale('es', 'CO'),
      home: const MainNavigationPage(),
    );
  }
}
