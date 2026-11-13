import 'dart:convert';
import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import 'certificado_excel.dart';
import 'inventario_sync.dart';
import 'tecnico_profile.dart';
import 'auth_tecnico.dart';

/// Sube los Excel (certificados e inventarios) a Firebase Storage, para
/// que la oficina los descargue sin que el técnico tenga que compartirlos
/// a mano por Drive.
///
/// Rutas en Storage:
/// - `certificados/{clienteId}/{docId}/<CERT> <EQUIPO> <SERIE>.xlsx` (nombre de oficina)
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

  static Future<void> _asegurarSesion() => AuthTecnico.asegurarSesion();

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

      // Mismo nombre que usa la oficina: "<CERT> <EQUIPO> <SERIE>"
      // (sin serie → inventario). Ver CertificadoExcel.nombreOficina.
      final nombre = '${_limpiarNombre(CertificadoExcel.nombreOficina(solicitud))}.xlsx';

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

  /// Quita del nombre los caracteres que Storage no maneja bien (# [ ]);
  /// los que Windows no acepta ya los quita CertificadoExcel.nombreOficina.
  static String _limpiarNombre(String nombre) => nombre
      .replaceAll(RegExp(r'[#\[\]]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
