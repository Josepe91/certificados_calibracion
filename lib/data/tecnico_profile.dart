import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Identidad local del técnico que usa este dispositivo.
///
/// No es un login: es un nombre que el técnico escribe una sola vez para
/// que sus acciones (certificados, equipos agregados/editados) queden
/// firmadas en el campo `actualizado_por` cuando el inventario se
/// sincroniza en la nube. Así, al final del día, se puede ver qué hizo
/// cada ingeniero sobre el mismo inventario.
class TecnicoProfile {
  static String? _nombreCache;

  static Future<File> _archivo() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'BTMC_SYNC'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return File(p.join(dir.path, 'tecnico.txt'));
  }

  /// Nombre guardado del técnico, o cadena vacía si nunca se configuró.
  static Future<String> obtenerNombre() async {
    if (_nombreCache != null) return _nombreCache!;
    final file = await _archivo();
    if (await file.exists()) {
      _nombreCache = (await file.readAsString()).trim();
    } else {
      _nombreCache = '';
    }
    return _nombreCache!;
  }

  static Future<void> guardarNombre(String nombre) async {
    final limpio = nombre.trim();
    _nombreCache = limpio;
    final file = await _archivo();
    await file.writeAsString(limpio);
  }
}
