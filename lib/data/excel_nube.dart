import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'certificado_excel.dart';
import 'inventario_excel.dart';
import 'inventario_sync.dart';
import 'solicitudes_storage.dart';
import 'tecnico_profile.dart';

/// Sube los Excel (certificados e inventarios) a Firebase Storage, para
/// que la oficina los descargue sin que el técnico tenga que compartirlos
/// a mano por Drive.
///
/// Rutas en Storage:
/// - `certificados/{clienteId}/{docId}/<CERT> - <EQUIPO> - <SERIE>.xlsx`
/// - `inventarios/{clienteId}/INVENTARIO <CLIENTE>.xlsx`
///
/// La carpeta de cada certificado usa `InventarioSync.docId` (mismo
/// criterio que las fotos en SolicitudesSync): dos técnicos que certifican
/// el mismo equipo escriben en la MISMA carpeta. Antes de subir se borra
/// lo que hubiera en ella, así si se corrige el número de certificado no
/// queda el Excel viejo al lado del nuevo.
class ExcelNube {
  ExcelNube._();

  static const _tipoXlsx =
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

  static FirebaseStorage get _storage => FirebaseStorage.instance;

  static Future<void> _asegurarSesion() async {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  }

  /// Sube el certificado de una solicitud ya guardada. Retorna true si
  /// quedó en la nube. Nunca lanza: sin señal simplemente retorna false y
  /// la solicitud sigue pendiente para subirla después desde Inicio.
  static Future<bool> subirCertificado(File archivoJson, File xlsx) async {
    try {
      final Map<String, dynamic> solicitud =
          jsonDecode(await archivoJson.readAsString());
      final equipo =
          Map<String, dynamic>.from((solicitud['equipo'] as Map?) ?? {});
      final cliente = (solicitud['cliente'] as Map?)?['nombre']?.toString();
      if (cliente == null || cliente.trim().isEmpty) return false;

      await _asegurarSesion();
      final carpeta = _storage.ref('certificados/'
          '${InventarioSync.slug(cliente)}/'
          '${InventarioSync.docId(equipo)}');

      final nombre = '${_limpiarNombre([
            solicitud['certificado'],
            equipo['nombre'],
            equipo['serie'],
          ])}.xlsx';

      final existentes = await carpeta.listAll();
      for (final item in existentes.items) {
        if (item.name != nombre) await item.delete();
      }

      final tecnico = await TecnicoProfile.obtenerNombre();
      await carpeta.child(nombre).putFile(
            xlsx,
            SettableMetadata(contentType: _tipoXlsx, customMetadata: {
              'cliente': cliente,
              'certificado': solicitud['certificado']?.toString() ?? '',
              'equipo': equipo['nombre']?.toString() ?? '',
              if (tecnico.isNotEmpty) 'tecnico': tecnico,
            }),
          );
      return true;
    } catch (e) {
      debugPrint('ExcelNube.subirCertificado ${archivoJson.path}: $e');
      return false;
    }
  }

  /// Genera y sube el certificado de TODAS las solicitudes pendientes; las
  /// que suben bien pasan a `enviadas/` (JSON + ZIP de fotos + .xlsx).
  /// Retorna (subidas, fallidas).
  static Future<(int, int)> subirPendientes() async {
    final dir = await SolicitudesStorage.pendientesDir();
    final jsons = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.json'))
        .toList();

    var ok = 0, fallidas = 0;
    for (final json in jsons) {
      File? xlsx;
      try {
        // Siempre se regenera: la solicitud pudo editarse, o venir de la
        // nube sin .xlsx (ver SolicitudesSync.descargarComoArchivoLocal).
        xlsx = await CertificadoExcel.generarDesdeSolicitud(json);
      } catch (e) {
        debugPrint('ExcelNube: error generando ${json.path}: $e');
      }
      if (xlsx == null || !await subirCertificado(json, xlsx)) {
        fallidas++;
        continue;
      }
      ok++;
      final zip = File(json.path
          .replaceAll(RegExp(r'\.json$', caseSensitive: false), '_fotos.zip'));
      for (final f in [json, zip, xlsx]) {
        if (await f.exists()) await SolicitudesStorage.moverAEnviadas(f);
      }
    }
    await SolicitudesStorage.refrescarContador();
    return (ok, fallidas);
  }

  /// Genera y sube el Excel de inventario de cada cliente guardado en el
  /// celular. Retorna (subidos, fallidos).
  static Future<(int, int)> subirInventarios() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'BTMC_SYNC', 'inventarios'));
    if (!await dir.exists()) return (0, 0);

    var ok = 0, fallidos = 0;
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.json')) continue;
      try {
        final Map<String, dynamic> data = jsonDecode(await f.readAsString());
        final cliente = (data['cliente'] as Map?)?['nombre']?.toString() ?? '';
        if (cliente.trim().isEmpty) continue;

        await _asegurarSesion();
        final ref = _storage.ref('inventarios/'
            '${InventarioSync.slug(cliente)}/'
            'INVENTARIO ${_limpiarNombre([cliente])}.xlsx');
        await ref.putData(
          InventarioExcel.generar(data),
          SettableMetadata(contentType: _tipoXlsx),
        );
        ok++;
      } catch (e) {
        debugPrint('ExcelNube.subirInventarios ${f.path}: $e');
        fallidos++;
      }
    }
    return (ok, fallidos);
  }

  /// Nombre de archivo legible ("JS0001-26 - BAÑO MARIA - 12345") sin
  /// caracteres que Windows o Storage no aceptan.
  static String _limpiarNombre(List<Object?> partes) => partes
      .map((v) => (v?.toString() ?? '')
          .replaceAll(RegExp(r'[\\/:*?"<>|#\[\]\r\n\t]'), '-')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim())
      .where((s) => s.isNotEmpty)
      .join(' - ');
}
