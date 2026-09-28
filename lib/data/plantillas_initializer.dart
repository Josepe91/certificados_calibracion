import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class PlantillasInitializer {
  // Guarda el Future activo para que llamadas simultáneas esperen al mismo
  // resultado en lugar de ejecutar copias paralelas de los archivos.
  static Future<void>? _initFuture;

  static List<String> plantillasCache = [];
  static final Map<String, Map<String, dynamic>> configCache = {};

  static Future<String> get rutaLocal async {
    final base = await getApplicationDocumentsDirectory();
    return p.join(base.path, 'BTMC_PLANTILLAS');
  }

  static Future<void> inicializar() => _initFuture ??= _doInit();

  static Future<void> _doInit() async {
    final ruta = await rutaLocal;
    final dir = Directory(ruta);
    await dir.create(recursive: true);

    final indexStr =
        await rootBundle.loadString('assets/plantillas/index.json');
    final List<dynamic> lista = jsonDecode(indexStr);

    final indexLocal = File(p.join(ruta, 'index.json'));
    await indexLocal.writeAsString(jsonEncode(lista));

    final futures = <Future<void>>[
      // Tabla de EMP compartida (ver lib/data/emp_referencia.dart) — igual
      // que los .json de cada plantilla, siempre se sobrescribe para que
      // una corrección de EMP llegue a todos los celulares en la próxima
      // actualización, no solo a los que instalan la app desde cero.
      _copiarAsset('assets/plantillas/emp_referencia.json',
          File(p.join(ruta, 'emp_referencia.json'))),
    ];

    for (final item in lista) {
      final String archivo = item.toString();

      // Siempre se copia (sobrescribe), igual que el .json de abajo — antes
      // el .xlsx solo se copiaba si no existía ya en el celular, así que
      // una plantilla corregida en una actualización de la app nunca
      // llegaba a un teléfono que ya la tenía cacheada de una instalación
      // anterior. El asset empacado en la app es siempre la versión
      // correcta; no tiene sentido preservar una copia local vieja.
      final fileXlsx = File(p.join(ruta, archivo));
      futures.add(_copiarAsset('assets/plantillas/$archivo', fileXlsx));

      final String nombreJson = archivo.replaceAll('.xlsx', '.json');
      final fileJson = File(p.join(ruta, nombreJson));
      futures.add(_copiarAsset('assets/plantillas/$nombreJson', fileJson));
    }

    await Future.wait(futures);
  }

  static Future<void> _copiarAsset(String assetPath, File destino) async {
    try {
      final bytes = await rootBundle.load(assetPath);
      await destino.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    } catch (_) {
      debugPrint('PlantillasInitializer: asset no encontrado "$assetPath"');
    }
  }

  static void resetear() {
    _initFuture = null;
    plantillasCache = [];
    configCache.clear();
  }
}
