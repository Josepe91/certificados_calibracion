import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'certificado_excel.dart';
import 'inventario_excel.dart';
import 'solicitudes_storage.dart';
import '../utils/text_utils.dart';

class DriveSync {
  // ===============================
  // COMPARTIR SOLO SOLICITUDES
  // Comparte el certificado Excel (.xlsx) de cada solicitud + su ZIP de
  // fotos — ya no el JSON, que era lo que había que convertir a mano en la
  // oficina. El .xlsx se regenera aquí siempre desde el JSON, así también
  // lo tienen las solicitudes bajadas de la nube (que llegan solo como
  // JSON+ZIP) o guardadas con una versión vieja de la app. Si una
  // solicitud no tiene plantilla, se manda su JSON para no perderla.
  // Retorna true si había archivos para compartir, false si no había nada.
  // ===============================
  static Future<bool> syncSolicitudes() async {
    final List<File> filesToSend = [];

    final pendientesDir = await SolicitudesStorage.pendientesDir();

    if (await pendientesDir.exists()) {
      for (final f in pendientesDir.listSync()) {
        if (f is! File) continue;
        final ruta = f.path.toLowerCase();
        if (ruta.endsWith('.zip')) {
          filesToSend.add(f);
        } else if (ruta.endsWith('.json')) {
          File? xlsx;
          try {
            xlsx = await CertificadoExcel.generarDesdeSolicitud(f);
          } catch (e) {
            debugPrint('DriveSync: error generando certificado ${f.path}: $e');
          }
          filesToSend.add(xlsx ?? f);
        }
      }
    }

    if (filesToSend.isEmpty) return false;

    await Share.shareXFiles(
      filesToSend.map((f) => XFile(f.path)).toList(),
    );
    return true;
  }

  // ===============================
  // EXPORTAR INVENTARIOS
  // ===============================
  static Future<List<String>> enviarInventario() async {
    final base = await getApplicationDocumentsDirectory();
    final inventariosDir =
        Directory(p.join(base.path, 'BTMC_SYNC', 'inventarios'));

    if (!await inventariosDir.exists()) return [];

    final archivos = inventariosDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();

    if (archivos.isEmpty) return [];

    final tempDir = await getTemporaryDirectory();
    final carpetaTemp = Directory(p.join(tempDir.path, 'btmc_inv'));
    if (await carpetaTemp.exists()) await carpetaTemp.delete(recursive: true);
    await carpetaTemp.create();

    final List<String> nombresGuardados = [];
    final List<XFile> xfiles = [];

    for (final f in archivos) {
      try {
        final contenido = await f.readAsString();
        final data = jsonDecode(contenido);

        final nombreCliente = TextUtils.normalizar(
          data['cliente']?['nombre']?.toString() ?? 'inventario',
        );

        final nombreArchivo = 'INVENTARIO_$nombreCliente.xlsx';
        final tempFile = File(p.join(carpetaTemp.path, nombreArchivo));
        await tempFile.writeAsBytes(InventarioExcel.generar(data));

        nombresGuardados.add(nombreArchivo);
        xfiles.add(XFile(tempFile.path));
      } catch (e) {
        debugPrint('DriveSync: error procesando inventario ${f.path}: $e');
      }
    }

    if (xfiles.isEmpty) return [];

    // 🔥 Sin subject ni text para que Drive use el nombre real
    await Share.shareXFiles(xfiles);

    return nombresGuardados;
  }
}
