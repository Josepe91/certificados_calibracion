import 'dart:async';
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
import 'certificado_excel.dart';
import 'excel_nube.dart';
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
    return _db.collection('clientes').doc(clienteId).collection('solicitudes');
  }

  static Reference _carpetaFotos(String clienteId, String equipoClave) {
    return _storage.ref('clientes/$clienteId/solicitudes/$equipoClave');
  }

  /// Nombres (basename del JSON) de las solicitudes guardadas en este
  /// celular que todavía NO quedaron en la nube. SolicitudesPage lo usa
  /// para marcarlas; sin esto una subida fallida (sin señal) pasaba en
  /// silencio y el técnico creía que los demás ya la veían.
  static final ValueNotifier<Set<String>> pendientesNube = ValueNotifier({});

  // Todas las subidas van en fila: un reintento y un guardado nuevo de la
  // MISMA solicitud no pueden borrar/subir fotos de la misma carpeta a la
  // vez (quedaría una mezcla de fotos de las dos versiones).
  static Future<void> _cola = Future.value();

  static Future<T> _enCola<T>(Future<T> Function() tarea) {
    final resultado = _cola.then((_) => tarea());
    _cola = resultado.then((_) {}, onError: (_) {});
    return resultado;
  }

  /// Un archivo por solicitud sin subir, con el mismo nombre del JSON
  /// (contenido: token del guardado, ver [subirSolicitud]). Vive en su propia carpeta (no junto al JSON) porque el JSON
  /// puede moverse de pendientes/ a enviadas/ antes de que haya señal.
  static Future<Directory> _dirMarcadores() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(
        p.join(base.path, 'BTMC_SYNC', 'solicitudes', 'sin_subir_nube'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<void> refrescarPendientesNube() async {
    final dir = await _dirMarcadores();
    pendientesNube.value =
        dir.listSync().whereType<File>().map((f) => p.basename(f.path)).toSet();
  }

  /// Sube la solicitud guardada en [archivoJson]. Antes de intentar deja
  /// un marcador "sin subir" que solo se borra si la subida termina bien;
  /// si falla, [reintentarPendientes] la vuelve a subir sola (al abrir la
  /// app, al volver a ella o tras la próxima subida exitosa).
  ///
  /// [fotos] son las que el técnico tiene en pantalla; si no se pasan se
  /// sacan del ZIP de la solicitud (caso reintento). Nunca lanza: la
  /// solicitud YA quedó guardada localmente antes de llamar aquí.
  static Future<bool> subirSolicitud({
    required File archivoJson,
    List<File>? fotos,
  }) async {
    final marcador = File(
        p.join((await _dirMarcadores()).path, p.basename(archivoJson.path)));
    // El contenido es un token por guardado: una subida anterior de esta
    // misma solicitud que termine después solo borra el marcador si sigue
    // siendo el suyo, no el de este guardado más nuevo.
    await marcador.writeAsString('${DateTime.now().microsecondsSinceEpoch}');
    await refrescarPendientesNube();

    final ok = await _enCola(() => _subir(archivoJson, marcador, fotos));
    await refrescarPendientesNube();
    if (ok) unawaited(reintentarPendientes()); // hay señal: aprovecharla
    return ok;
  }

  static Future<bool> _subir(
      File archivoJson, File marcador, List<File>? fotos) async {
    // Otro intento ya la subió mientras esperaba en la fila.
    if (!await marcador.exists()) return true;
    final token = await marcador.readAsString();
    try {
      final Map<String, dynamic> solicitud =
          jsonDecode(await archivoJson.readAsString());
      final equipo =
          Map<String, dynamic>.from((solicitud['equipo'] as Map?) ?? {});
      final cliente = (solicitud['cliente'] as Map?)?['nombre']?.toString();
      if (cliente == null || cliente.trim().isEmpty) {
        await marcador.delete(); // sin cliente no hay adónde subirla
        return false;
      }
      final clienteId = InventarioSync.slug(cliente);
      fotos ??= await _fotosDelZip(archivoJson, solicitud);

      await _asegurarSesion();
      final clave = InventarioSync.claveEquipo(equipo);
      final carpeta = _carpetaFotos(clienteId, clave);

      // Reemplaza TODAS las fotos de la carpeta por las actuales, para que
      // la nube quede igual al ZIP local, nunca una mezcla de viejas y
      // nuevas.
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

      // Si Firestore no confirma a tiempo, la escritura igual queda en su
      // cola persistente y se envía sola al volver la señal: cuenta como
      // subida (las fotos, que no tienen esa cola, ya subieron arriba).
      await _solicitudesRef(clienteId)
          .doc(clave)
          .set(datos)
          .timeout(const Duration(seconds: 20), onTimeout: () {});

      // Certificado en Excel para la oficina, en el mismo intento: así el
      // reintento automático también lo cubre y no depende del botón
      // "Subir certificados" de Inicio.
      final rutaXlsx = File(CertificadoExcel.rutaCertificado(archivoJson.path));
      final xlsx = await rutaXlsx.exists()
          ? rutaXlsx
          : await CertificadoExcel.generarDesdeSolicitud(archivoJson);
      // Si el Excel no se puede generar (plantilla faltante/dañada) es un
      // fallo local que reintentar no arregla: no se deja la solicitud
      // atascada por eso, ni frena a las demás en la fila.
      if (xlsx != null &&
          !await ExcelNube.subirCertificado(archivoJson, xlsx)) {
        return false;
      }

      if (await marcador.exists() && await marcador.readAsString() == token) {
        await marcador.delete();
      }
      return true;
    } catch (e) {
      debugPrint('SolicitudesSync.subirSolicitud ${archivoJson.path}: $e');
      return false;
    }
  }

  static Future<List<File>> _fotosDelZip(
      File archivoJson, Map<String, dynamic> solicitud) async {
    final nombreZip = solicitud['fotos_zip']?.toString() ?? '';
    if (nombreZip.isEmpty) return [];
    final zip = File(p.join(archivoJson.parent.path, nombreZip));
    if (!await zip.exists()) return [];

    final tempDir = await getTemporaryDirectory();
    final carpeta = Directory(p.join(
        tempDir.path, 'btmc_reintento', p.basenameWithoutExtension(nombreZip)));
    if (await carpeta.exists()) await carpeta.delete(recursive: true);
    await carpeta.create(recursive: true);

    final fotos = <File>[];
    for (final entry
        in ZipDecoder().decodeBytes(await zip.readAsBytes()).files) {
      if (!entry.isFile) continue;
      final destino = File(p.join(carpeta.path, p.basename(entry.name)));
      await destino.writeAsBytes(entry.content as List<int>);
      fotos.add(destino);
    }
    return fotos;
  }

  static bool _reintentando = false;

  /// Vuelve a subir toda solicitud que quedó marcada "sin subir". Se
  /// detiene en el primer fallo (sin señal, el resto también fallaría).
  static Future<void> reintentarPendientes() async {
    if (_reintentando) return;
    _reintentando = true;
    try {
      final dirMarcadores = await _dirMarcadores();
      final pendientes = await SolicitudesStorage.pendientesDir();
      final enviadas = await SolicitudesStorage.enviadasDir();

      for (final marcador in dirMarcadores.listSync().whereType<File>()) {
        final nombre = p.basename(marcador.path);
        final json = [pendientes, enviadas]
            .map((d) => File(p.join(d.path, nombre)))
            .where((f) => f.existsSync())
            .firstOrNull;
        if (json == null) {
          // Se borró o se renombró (cambió el certificado): el guardado
          // que la renombró ya dejó su propio marcador con el nombre nuevo.
          await marcador.delete();
          continue;
        }
        if (!await _enCola(() => _subir(json, marcador, null))) break;
      }
    } catch (e) {
      debugPrint('SolicitudesSync.reintentarPendientes: $e');
    } finally {
      _reintentando = false;
      await refrescarPendientesNube();
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
