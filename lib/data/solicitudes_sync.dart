import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../utils/text_utils.dart';
import 'inventario_sync.dart';
import 'solicitudes_storage.dart';
import 'tecnico_profile.dart';

/// Sube/descarga solicitudes (certificado + mediciones + fotos) contra
/// Firestore + Cloud Storage, para que cualquier técnico vea y edite una
/// solicitud aunque no la haya creado él en su celular.
///
/// Mismo patrón que InventarioSync: la clave del documento se deriva del
/// CONTENIDO del equipo (InventarioSync.claveEquipo), nunca del id local
/// aleatorio del dispositivo — así dos técnicos que hablan del mismo
/// equipo físico siempre leen/escriben el mismo documento en
/// `clientes/{clienteId}/solicitudes/{claveEquipo}`, y las fotos del mismo
/// equipo siempre caen en la misma carpeta de Storage
/// `clientes/{clienteId}/solicitudes/{claveEquipo}/`.
class SolicitudesSync {
  SolicitudesSync._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static final FirebaseStorage _storage = FirebaseStorage.instance;

  static Future<void> _asegurarSesion() async {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  }

  static CollectionReference<Map<String, dynamic>> _solicitudesRef(
      String clienteId) {
    return _db
        .collection('clientes')
        .doc(clienteId)
        .collection('solicitudes');
  }

  static Reference _carpetaFotos(String clienteId, String equipoClave) {
    return _storage.ref('clientes/$clienteId/solicitudes/$equipoClave');
  }

  /// Sube una solicitud completa: primero reemplaza TODAS las fotos que
  /// hubiera antes en su carpeta de Storage por las actuales (para que la
  /// nube quede igual al ZIP local recién generado, nunca una mezcla de
  /// fotos viejas y nuevas), luego escribe el documento con la URL de cada
  /// una.
  ///
  /// No se relanza si falla — la solicitud YA quedó guardada localmente
  /// antes de llamar aquí (mismo criterio que
  /// `InventarioSync.upsertEquipo`), así que un fallo de red nunca le hace
  /// perder el trabajo al técnico; solo se queda sin subir hasta el
  /// próximo guardado con señal.
  static Future<void> subirSolicitud({
    required String clienteId,
    required Map<String, dynamic> equipo,
    required Map<String, dynamic> solicitud,
    required List<File> fotos,
  }) async {
    try {
      await _asegurarSesion();
      final clave = InventarioSync.claveEquipo(equipo);
      final carpeta = _carpetaFotos(clienteId, clave);

      final existentes = await carpeta.listAll();
      for (final item in existentes.items) {
        await item.delete();
      }

      final urls = <String>[];
      for (int i = 0; i < fotos.length; i++) {
        final ext = p.extension(fotos[i].path);
        final ref = carpeta.child('foto_$i$ext');
        await ref.putFile(fotos[i]);
        urls.add(await ref.getDownloadURL());
      }

      final tecnico = await TecnicoProfile.obtenerNombre();
      final datos = Map<String, dynamic>.from(solicitud)
        ..remove('fotos_zip') // solo tiene sentido en disco local
        ..['fotos_urls'] = urls
        ..['actualizado_en'] = FieldValue.serverTimestamp();
      if (tecnico.isNotEmpty) datos['actualizado_por'] = tecnico;

      await _solicitudesRef(clienteId).doc(clave).set(datos);
    } catch (e) {
      debugPrint('SolicitudesSync.subirSolicitud: $e');
    }
  }

  /// Lista (resumen) las solicitudes en la nube de un cliente, para
  /// mostrarlas en SolicitudesPage junto a las locales — incluye las que
  /// creó CUALQUIER técnico, no solo este dispositivo.
  static Future<List<Map<String, dynamic>>> listarResumenNube(
      String clienteId) async {
    try {
      await _asegurarSesion();
      final snap = await _solicitudesRef(clienteId).get();
      return snap.docs
          .map((d) => {'equipo_clave': d.id, ..._paraApp(d.data())})
          .toList();
    } catch (e) {
      debugPrint('SolicitudesSync.listarResumenNube: $e');
      return [];
    }
  }

  /// Descarga una solicitud completa de la nube (documento + fotos) y la
  /// escribe en disco en pendientes/ con el MISMO formato que una
  /// solicitud creada localmente (JSON + ZIP de fotos) — así
  /// NuevaSolicitudPage la abre exactamente igual que cualquier otra, sin
  /// ningún camino de código separado para "modo nube". Retorna null si la
  /// solicitud ya no existe en la nube o si algo falla.
  static Future<File?> descargarComoArchivoLocal({
    required String clienteId,
    required String equipoClave,
  }) async {
    try {
      await _asegurarSesion();
      final doc = await _solicitudesRef(clienteId).doc(equipoClave).get();
      if (!doc.exists || doc.data() == null) return null;
      final data = _paraApp(doc.data()!);

      final urls = (data['fotos_urls'] as List?)?.cast<dynamic>() ?? [];
      final dir = await SolicitudesStorage.pendientesDir();

      final certificado =
          TextUtils.normalizar(data['certificado']?.toString() ?? '');
      final equipoData = data['equipo'] as Map<String, dynamic>?;
      final nombreEquipo =
          TextUtils.normalizar(equipoData?['nombre']?.toString() ?? 'equipo');
      final baseNombre = '${certificado}_${nombreEquipo}_$equipoClave';

      String fotosZip = '';
      if (urls.isNotEmpty) {
        final tempDir = await getTemporaryDirectory();
        final carpetaTemp =
            Directory(p.join(tempDir.path, 'btmc_descarga_$equipoClave'));
        if (await carpetaTemp.exists()) {
          await carpetaTemp.delete(recursive: true);
        }
        await carpetaTemp.create(recursive: true);

        final archivosDescargados = <File>[];
        for (int i = 0; i < urls.length; i++) {
          try {
            final bytes = await _storage
                .refFromURL(urls[i].toString())
                // 15 MB de margen por foto — de sobra para una foto de
                // celular comprimida al 85% (image_picker), nunca se
                // acerca a ese tamaño en la práctica.
                .getData(15 * 1024 * 1024);
            if (bytes == null) continue;
            final destino = File(p.join(carpetaTemp.path, 'foto_$i.jpg'));
            await destino.writeAsBytes(bytes);
            archivosDescargados.add(destino);
          } catch (e) {
            debugPrint('SolicitudesSync: error descargando foto $i: $e');
          }
        }

        if (archivosDescargados.isNotEmpty) {
          final zipFile = File(p.join(dir.path, '${baseNombre}_fotos.zip'));
          final encoder = ZipFileEncoder();
          encoder.create(zipFile.path);
          for (final f in archivosDescargados) {
            encoder.addFile(f, p.basename(f.path));
          }
          encoder.close();
          fotosZip = p.basename(zipFile.path);
        }
      }

      final jsonFile = File(p.join(dir.path, '$baseNombre.json'));
      final paraGuardar = Map<String, dynamic>.from(data)
        ..remove('fotos_urls')
        ..remove('actualizado_por')
        ..remove('actualizado_en')
        ..['fotos_zip'] = fotosZip;
      await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(paraGuardar),
      );

      await SolicitudesStorage.refrescarContador();
      return jsonFile;
    } catch (e) {
      debugPrint('SolicitudesSync.descargarComoArchivoLocal: $e');
      return null;
    }
  }

  static Map<String, dynamic> _paraApp(Map<String, dynamic> data) {
    final copia = Map<String, dynamic>.from(data);
    for (final key in copia.keys.toList()) {
      final v = copia[key];
      if (v is Timestamp) copia[key] = v.toDate().toIso8601String();
    }
    return copia;
  }
}
