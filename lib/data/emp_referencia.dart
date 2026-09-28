import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Tabla compartida de Error Máximo Permitido (EMP) por variable de
/// medición (el `titulo` de una sección, ej. "TEMPERATURA AMBIENTE") y
/// punto nominal — para que el EMP de una variable se defina UNA sola vez
/// y aplique a todas las plantillas que comparten esa misma variable, en
/// vez de repetirlo plantilla por plantilla (hay ~176 plantillas y muchas
/// comparten la misma variable con el mismo EMP).
///
/// Formato de `assets/plantillas/emp_referencia.json` — la clave es
/// "título|unidad" (la unidad separa variables con el mismo título pero
/// unidades distintas, ej. "PRESIÓN" en mmHg vs PSI vs cmH2O):
/// ```json
/// {
///   "TEMPERATURA AMBIENTE|°C": [{"nominal": 2, "emp": 0.5}, {"nominal": 8, "emp": 1.0}],
///   "CALIBRACIÓN DE VELOCIDAD|RPM": [{"nominal": 50, "emp": 2}]
/// }
/// ```
/// Un punto de una plantilla puede además traer su propio campo `"emp"`
/// para sobrescribir esta tabla cuando ese equipo puntual necesita una
/// tolerancia distinta a la del resto de su variable — ver
/// `NuevaSolicitudPage._revisarTolerancia`.
class EmpReferencia {
  EmpReferencia._();

  static Map<String, dynamic>? _cache;

  static Future<Map<String, dynamic>> _cargar() async {
    if (_cache != null) return _cache!;

    try {
      final base = await getApplicationDocumentsDirectory();
      final local = File(
          p.join(base.path, 'BTMC_PLANTILLAS', 'emp_referencia.json'));
      if (await local.exists()) {
        _cache = jsonDecode(await local.readAsString()) as Map<String, dynamic>;
        return _cache!;
      }
    } catch (_) {}

    try {
      final raw =
          await rootBundle.loadString('assets/plantillas/emp_referencia.json');
      _cache = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _cache = {};
    }
    return _cache!;
  }

  /// EMP para una variable (título de sección + unidad) en un punto nominal
  /// dado, o null si todavía no hay un valor definido para esa combinación.
  ///
  /// La clave incluye la unidad además del título porque algunos títulos
  /// ("PRESIÓN", "PRESIÓN NEGATIVA") existen en varias plantillas con
  /// unidades distintas (mmHg, PSI, cmH2O, kPa) que además comparten
  /// valores nominales iguales — sin la unidad en la clave, el EMP de una
  /// unidad se aplicaría por error a otra.
  static Future<double?> buscar(
      String tituloSeccion, String unidad, num nominal) async {
    final tabla = await _cargar();
    final entradas = tabla['$tituloSeccion|$unidad'] as List?;
    if (entradas == null) return null;
    for (final e in entradas) {
      final entrada = e as Map<String, dynamic>;
      final n = (entrada['nominal'] as num).toDouble();
      if (n == nominal.toDouble()) {
        return (entrada['emp'] as num).toDouble();
      }
    }
    return null;
  }

  static void resetear() => _cache = null;
}
