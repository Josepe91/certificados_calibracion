import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class SolicitudesStorage {
  static const String _pendientes = 'pendientes';
  static const String _enviadas = 'enviadas';

  static Future<String> get _rootPath async {
    final base = await getApplicationDocumentsDirectory();
    return p.join(base.path, 'BTMC_SYNC', 'solicitudes');
  }

  static Future<Directory> pendientesDir() async {
    final root = await _rootPath;
    final dir = Directory(p.join(root, _pendientes));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<Directory> enviadasDir() async {
    final root = await _rootPath;
    final dir = Directory(p.join(root, _enviadas));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<File> crearPendiente(String nombreArchivo) async {
    final dir = await pendientesDir();
    return File(p.join(dir.path, nombreArchivo));
  }

  static final ValueNotifier<int> contadorNotifier = ValueNotifier(0);

  static Future<void> refrescarContador() async {
    final archivos = await listarPendientes();
    contadorNotifier.value = archivos.length;
  }

  static Future<List<File>> listarPendientes() async {
    final dir = await pendientesDir();
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.json'))
        .toList();
  }

  static Future<void> moverAEnviadas(File f) async {
    final dir = await enviadasDir();
    final destino = File(p.join(dir.path, f.uri.pathSegments.last));
    if (await f.exists()) {
      await f.rename(destino.path);
    }
  }

  // Mueve todos los archivos de pendientes/ a enviadas/ y retorna
  // la cantidad de solicitudes (JSON) movidas.
  static Future<int> moverTodasAEnviadas() async {
    final pDir = await pendientesDir();
    final eDir = await enviadasDir();
    int solicitudesMovidas = 0;

    for (final entity in pDir.listSync()) {
      if (entity is File) {
        if (entity.path.toLowerCase().endsWith('.json')) solicitudesMovidas++;
        final destino = File(p.join(eDir.path, entity.uri.pathSegments.last));
        await entity.rename(destino.path);
      }
    }
    await refrescarContador();
    return solicitudesMovidas;
  }
}
