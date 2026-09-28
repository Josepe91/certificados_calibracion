import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Control de versión entre celulares de los técnicos.
///
/// Por qué existe: si dos celulares corren builds distintos, pueden
/// escribir en documentos distintos de Firestore sin que nadie lo note —
/// eso causó el bug "Gabriel editó y Sebastián no lo ve" del 2026-09-16
/// (ver CLAUDE.md > Releases). Acá cada build compara su número
/// (`version: x.y.z+BUILD` del pubspec) con `config/app.version_minima` en
/// Firestore y, si es más viejo, la app se bloquea hasta actualizar.
///
/// Quién sube `version_minima`: SOLO un build compilado con
/// `--dart-define=PUBLICAR_VERSION=true` (lo pone `tool/release.ps1`, el
/// que distribuye por App Distribution). Así, un APK de prueba compilado a
/// mano NO bloquea a los demás técnicos antes de que tengan cómo
/// actualizar. Las reglas de Firestore solo permiten subir el número,
/// nunca bajarlo.
class VersionApp {
  VersionApp._();

  static const bool _publicaVersion =
      bool.fromEnvironment('PUBLICAR_VERSION');

  static PackageInfo? _info;

  static Future<PackageInfo> _paquete() async =>
      _info ??= await PackageInfo.fromPlatform();

  /// "v1.1.0 (2)" — para mostrar en pantalla.
  static Future<String> etiqueta() async {
    final i = await _paquete();
    return 'v${i.version} (${i.buildNumber})';
  }

  static Future<int> build() async =>
      int.tryParse((await _paquete()).buildNumber) ?? 0;

  static DocumentReference<Map<String, dynamic>> get _doc =>
      FirebaseFirestore.instance.collection('config').doc('app');

  /// Retorna la versión mínima exigida si ESTE build es más viejo (la app
  /// debe bloquearse), o null si está al día o no se pudo consultar (sin
  /// señal: nunca se bloquea a un técnico en campo por no poder verificar).
  static Future<int?> verificar() async {
    try {
      final actual = await build();
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      final snap = await _doc.get().timeout(const Duration(seconds: 8));
      final minima = (snap.data()?['version_minima'] as num?)?.toInt() ?? 0;

      if (actual < minima) return minima;

      if (_publicaVersion && actual > minima) {
        await _doc.set({
          'version_minima': actual,
          'actualizado_en': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
      return null;
    } catch (e) {
      debugPrint('VersionApp.verificar: $e');
      return null;
    }
  }
}
