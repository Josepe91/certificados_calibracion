import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

class BTMCStorage {
  static Future<String> get rootPath async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, 'BTMC_SYNC');
  }

  static Future<void> borrarTodo() async {
    final path = await rootPath;
    final dir = Directory(path);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  static Future<void> borrarSolicitudes() async {
    final path = await rootPath;
    final dir = Directory(p.join(path, 'solicitudes'));
    if (await dir.exists()) await dir.delete(recursive: true);
  }

  static Future<void> crearBase() async {
    final path = await rootPath;
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
  }
}
