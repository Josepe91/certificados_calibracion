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
import 'inventario_sync.dart';
import 'montajes_sync.dart';
import 'plantillas_initializer.dart';

class DriveSync {
  // ===============================
  // COMPARTIR SOLO SOLICITUDES
  // Comparte el certificado Excel (.xlsx) de cada solicitud + su ZIP de
  // fotos — ya no el JSON, que era lo que había que convertir a mano en la
  // oficina. El .xlsx se regenera aquí siempre desde el JSON, así también
  // lo tienen las solicitudes bajadas de la nube (que llegan solo como
  // JSON+ZIP) o guardadas con una versión vieja de la app. Si una
  // solicitud no tiene plantilla, se manda su JSON para no perderla.
  // Con [enviadasDesde] también incluye las de enviadas/ guardadas desde esa
  // fecha (ya subidas a la nube), para poder mandarlas a Drive en bloque.
  // Retorna true si había archivos para compartir, false si no había nada.
  // ===============================
  static Future<bool> syncSolicitudes({
    DateTime? enviadasDesde,
    void Function(int hechos, int total)? onProgreso,
  }) async {
    bool esJson(File f) => f.path.toLowerCase().endsWith('.json');
    final jsons = <File>[
      ...(await SolicitudesStorage.pendientesDir())
          .listSync()
          .whereType<File>()
          .where(esJson),
      // La fecha del JSON es la del último guardado (moverAEnviadas solo
      // lo renombra, no la cambia).
      if (enviadasDesde != null)
        ...(await SolicitudesStorage.enviadasDir())
            .listSync()
            .whereType<File>()
            .where((f) =>
                esJson(f) && f.lastModifiedSync().isAfter(enviadasDesde)),
    ];

    if (jsons.isEmpty) return false;

    // Antes se regeneraba el .xlsx de TODAS las solicitudes, una tras otra,
    // antes de abrir la ventana de compartir: con muchas solicitudes eso
    // tardaba un buen rato sin mostrar nada. Ahora se reusa el .xlsx que ya
    // dejó el guardado (si es más nuevo que el JSON y que las plantillas
    // instaladas) y solo se generan los que faltan, varios a la vez.
    final marcadorPlantillas = await _fechaPlantillas();
    // Copias con el nombre de oficina ("JS11260-26 VENTILADOR MECÁNICO
    // VG70(U)XZZS33267.xlsx" + "..._fotos.zip"): el archivo interno lleva el
    // id del equipo ("..._eq_1792433199173796_70"), que en Drive no le
    // dice nada a la oficina. Se arma una carpeta temporal nueva cada vez.
    final carpetaCompartir = Directory(
        p.join((await getTemporaryDirectory()).path, 'btmc_compartir'));
    if (await carpetaCompartir.exists()) {
      await carpetaCompartir.delete(recursive: true);
    }
    await carpetaCompartir.create(recursive: true);
    final nombresUsados = <String>{};
    String nombreUnico(String base) {
      var nombre = base;
      var n = 2;
      while (!nombresUsados.add(nombre.toLowerCase())) {
        nombre = '$base ($n)';
        n++;
      }
      return nombre;
    }

    final porSolicitud = List<List<File>>.filled(jsons.length, const []);
    var hechos = 0;
    onProgreso?.call(0, jsons.length);

    Future<void> procesar(int i) async {
      final f = jsons[i];
      final archivos = <File>[];
      File? xlsx;
      try {
        xlsx = await _certificadoVigente(f, marcadorPlantillas) ??
            await CertificadoExcel.generarDesdeSolicitud(f);
      } catch (e) {
        debugPrint('DriveSync: error generando certificado ${f.path}: $e');
      }
      var nombreZip = '';
      Map<String, dynamic>? solicitud;
      try {
        solicitud = jsonDecode(await f.readAsString());
        nombreZip = (solicitud?['fotos_zip'] ?? '').toString();
      } catch (_) {}
      var nombreOficina = '';
      if (xlsx != null && solicitud != null) {
        nombreOficina = CertificadoExcel.nombreOficina(solicitud);
      }
      if (nombreOficina.isNotEmpty) nombreOficina = nombreUnico(nombreOficina);
      final original = xlsx;
      if (original != null && nombreOficina.isNotEmpty) {
        try {
          xlsx = await original
              .copy(p.join(carpetaCompartir.path, '$nombreOficina.xlsx'));
        } catch (e) {
          debugPrint('DriveSync: no se pudo renombrar ${original.path}: $e');
        }
      }
      archivos.add(xlsx ?? f);
      if (nombreZip.isEmpty) {
        nombreZip = p
            .basename(f.path)
            .replaceAll(RegExp(r'\.json$', caseSensitive: false), '_fotos.zip');
      }
      File zip = File(p.join(f.parent.path, nombreZip));
      if (await zip.exists()) {
        if (nombreOficina.isNotEmpty) {
          try {
            zip = await zip.copy(
                p.join(carpetaCompartir.path, '${nombreOficina}_fotos.zip'));
          } catch (e) {
            debugPrint('DriveSync: no se pudo renombrar ${zip.path}: $e');
          }
        }
        archivos.add(zip);
      }
      porSolicitud[i] = archivos;
      hechos++;
      onProgreso?.call(hechos, jsons.length);
    }

    // Hasta 3 certificados a la vez: más no acelera (cada uno ya corre en
    // su propio isolate) y sí sube mucho la memoria en celulares modestos.
    var siguiente = 0;
    Future<void> trabajador() async {
      while (siguiente < jsons.length) {
        await procesar(siguiente++);
      }
    }

    await Future.wait(List.generate(3, (_) => trabajador()));

    final filesToSend = porSolicitud.expand((l) => l).toList();
    if (filesToSend.isEmpty) return false;

    await Share.shareXFiles(
      filesToSend.map((f) => XFile(f.path)).toList(),
    );
    return true;
  }

  /// El .xlsx ya generado de una solicitud, si sigue siendo válido: existe,
  /// es más nuevo que el JSON (no hubo ediciones después) y más nuevo que
  /// la copia actual de las plantillas (un build nuevo pudo corregir una).
  /// Si no, null → hay que regenerarlo.
  static Future<File?> _certificadoVigente(
      File json, DateTime? fechaPlantillas) async {
    final xlsx = File(CertificadoExcel.rutaCertificado(json.path));
    if (!await xlsx.exists()) return null;
    final fx = await xlsx.lastModified();
    if (fx.isBefore(await json.lastModified())) return null;
    if (fechaPlantillas != null && fx.isBefore(fechaPlantillas)) return null;
    return xlsx;
  }

  /// Fecha en que se copiaron las plantillas del build instalado (marcador
  /// de [PlantillasInitializer]). null si no se puede saber.
  static Future<DateTime?> _fechaPlantillas() async {
    try {
      await PlantillasInitializer.inicializar();
      final marcador =
          File(p.join(await PlantillasInitializer.rutaLocal, '.build_copiado'));
      if (await marcador.exists()) return await marcador.lastModified();
    } catch (_) {}
    return null;
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
        final montajes = await MontajesSync.cargar(
            InventarioSync.slug(data['cliente']?['nombre']?.toString() ?? ''));
        await tempFile
            .writeAsBytes(InventarioExcel.generar(data, montajes: montajes));

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
