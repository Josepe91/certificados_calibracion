import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'tecnico_profile.dart';
import '../utils/text_utils.dart';

/// Sincroniza el inventario de un cliente contra Firestore para que varios
/// técnicos que trabajan el mismo cliente (con o sin señal) terminen el día
/// viendo un solo inventario consolidado con la acción de todos.
///
/// Cómo funciona:
/// - Cada equipo vive en `clientes/{clienteId}/equipos/{equipoId}`, donde
///   `equipoId` se deriva del CONTENIDO del equipo (ver [claveEquipo]), no
///   de un id aleatorio por dispositivo — así, cuando dos técnicos importan
///   el MISMO Excel cada uno en su celular, ambos calculan la misma clave
///   para la misma fila y terminan escribiendo el mismo documento en vez de
///   crear dos copias distintas de un mismo equipo físico.
/// - Cada escritura (`upsertEquipo`, `eliminarEquipo`) se manda a Firestore.
///   El SDK de Firestore la encola en disco si no hay internet y la sube
///   sola en cuanto el dispositivo recupera señal — no hay que programar
///   ninguna cola manual.
/// - `attachCliente` abre un listener en tiempo real: si el dispositivo
///   tiene señal, los cambios de OTRO técnico llegan al instante. Si no,
///   Firestore sirve la última copia cacheada y se pone al día solo al
///   reconectar.
class InventarioSync {
  InventarioSync._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  static String? _clienteIdActivo;
  // Si el listener del cliente activo ya entregó al menos una lista.
  static bool _yaAplicado = false;

  /// Callback que InventarioData registra para recibir los cambios remotos
  /// (agregar/actualizar/eliminar) y aplicarlos sobre `equiposNotifier`.
  static void Function(List<Map<String, dynamic>> equiposRemotos)?
      onEquiposRemotos;

  // 'sincronizado' | 'sincronizando' | 'sin_conexion' | 'error' | 'apagado'
  static final ValueNotifier<String> estadoNotifier = ValueNotifier('apagado');

  static bool get activo => _clienteIdActivo != null;

  /// Convierte el nombre de un cliente en un id de documento estable para
  /// Firestore.
  ///
  /// Dos técnicos casi nunca escriben el nombre del cliente exactamente
  /// igual en cada Excel (mayúsculas, tildes, espacios extra: "Clínica X"
  /// vs "CLINICA X"). Si el id de nube dependiera de esa ortografía, cada
  /// uno terminaría escribiendo a una carpeta distinta sin darse cuenta —
  /// cada uno viendo solo lo suyo, en silencio. Por eso se normaliza todo
  /// a mayúsculas sin tildes antes de generar el id: el NIT/nombre visible
  /// para el usuario no cambia, solo la clave interna en la nube.
  static String slug(String nombreCliente) {
    return TextUtils.quitarTildes(nombreCliente)
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9\s]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
  }

  /// Clave de nube de un equipo, derivada de su contenido (no de un id
  /// aleatorio).
  ///
  /// El "id" local de un equipo (`InventarioData._generarId`) se genera con
  /// la hora del dispositivo — así que si dos técnicos importan el mismo
  /// Excel cada uno en su celular, el MISMO equipo físico recibe un id
  /// distinto en cada teléfono. Si esa clave aleatoria se usara para
  /// direccionar el documento en Firestore, cada dispositivo terminaría
  /// creando su propia copia del inventario completo en la nube en vez de
  /// fusionarse en una sola: el primero que reimporta "gana" y el resto ve
  /// solo su porción, o peor, una reimportación puede pisar por completo lo
  /// que ya había (justo el bug que se observó con "NEFROUROS PEREIRA").
  ///
  /// Por eso la clave de nube se calcula a partir de los campos que vienen
  /// del Excel (nombre, marca, modelo, serie, inventario, ubicación) más la
  /// posición de la fila (`orden`) como desambiguador — dos dispositivos
  /// que importan el mismo archivo calculan exactamente la misma clave para
  /// la misma fila, así que terminan escribiendo el mismo documento.
  static String claveEquipo(Map<String, dynamic> equipo) {
    String limpiar(dynamic v) {
      final s =
          TextUtils.quitarTildes((v?.toString() ?? '').trim().toUpperCase());
      return s.replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
    }

    final orden = equipo['orden'] is int ? equipo['orden'] as int : 0;
    final partes = [
      limpiar(equipo['nombre']),
      limpiar(equipo['marca']),
      limpiar(equipo['modelo']),
      limpiar(equipo['serie']),
      limpiar(equipo['inventario']),
      limpiar(equipo['ubicacion']),
    ].where((s) => s.isNotEmpty).join('_');

    final clave = 'eq_${orden}_$partes';
    // Límite generoso muy por debajo del máximo de Firestore (1500 bytes),
    // solo para evitar claves absurdamente largas con textos libres largos.
    return clave.length > 400 ? clave.substring(0, 400) : clave;
  }

  /// Id del documento de un equipo en la nube. Es `clave_nube`, que se
  /// fija UNA vez (al importar o crear el equipo, o es el id del documento
  /// que bajó de la nube) y nunca se recalcula. Antes se usaba
  /// [claveEquipo] en cada escritura: corregir la serie/ubicación o
  /// reimportar un Excel con una fila insertada cambiaba la clave, se
  /// escribía un documento NUEVO y el viejo quedaba — equipo duplicado
  /// para todos los técnicos. [claveEquipo] queda solo como respaldo para
  /// datos guardados antes de este campo (su clave es la que ya tienen).
  static String docId(Map<String, dynamic> equipo) {
    final clave = equipo['clave_nube']?.toString() ?? '';
    return clave.isNotEmpty ? clave : claveEquipo(equipo);
  }

  static Future<void> _asegurarSesion() async {
    if (FirebaseAuth.instance.currentUser == null) {
      await FirebaseAuth.instance.signInAnonymously();
    }
  }

  static CollectionReference<Map<String, dynamic>> _equiposRef(
      String clienteId) {
    return _db.collection('clientes').doc(clienteId).collection('equipos');
  }

  static Future<void> _attachListener(String clienteId) async {
    if (_clienteIdActivo == clienteId && _sub != null) return;
    await detach();
    _clienteIdActivo = clienteId;
    _yaAplicado = false;

    estadoNotifier.value = 'sincronizando';
    // El orden se resuelve en InventarioData con el campo 'orden' de cada
    // equipo (Firestore no garantiza el orden de inserción en una
    // colección), así que aquí no hace falta un orderBy.
    //
    // includeMetadataChanges: true es necesario para que el ícono de
    // sincronización se actualice correctamente. Sin esto, cuando el
    // primer snapshot llega desde el caché local (isFromCache: true) y
    // el servidor confirma los mismos datos sin cambios, Firestore NO
    // dispara un nuevo evento (por defecto solo notifica cambios de
    // datos, no de metadata) — el ícono se queda pegado en "sin conexión"
    // para siempre aunque los datos ya estén sincronizados.
    _sub = _equiposRef(clienteId)
        .snapshots(includeMetadataChanges: true)
        .listen((snap) {
      estadoNotifier.value =
          snap.metadata.isFromCache ? 'sin_conexion' : 'sincronizado';
      // Un snapshot VACÍO que viene del caché no significa "la nube no
      // tiene equipos", sino "este celular no tiene nada cacheado" (caché
      // limpiado o recolectado por Firestore). Aplicarlo reemplazaría el
      // inventario local por una lista vacía y la guardaría en el JSON.
      if (snap.metadata.isFromCache && snap.docs.isEmpty) return;
      // Cambios solo de metadata (una escritura propia confirmada, pasar
      // de caché a servidor) no traen datos nuevos: no hace falta
      // reemplazar la lista ni reescribir el JSON local.
      if (snap.docChanges.isEmpty && _yaAplicado) return;
      _yaAplicado = true;
      final remoto = snap.docs.map(_equipoDeDoc).toList();
      onEquiposRemotos?.call(remoto);
    }, onError: (e) {
      debugPrint('InventarioSync: error en listener ($e)');
      estadoNotifier.value = 'error';
    });
  }

  /// Conecta el listener en tiempo real para un cliente que YA se conoce
  /// localmente (se está reabriendo, no reimportando). Si la nube todavía
  /// no tiene nada de este cliente (primerísima vez que alguien lo carga
  /// desde cualquier dispositivo), sube lo local como semilla; si ya tiene
  /// algo, no lo toca — la nube manda y el listener trae esa versión.
  static Future<void> attachCliente({
    required String clienteId,
    required Map<String, dynamic> clienteMeta,
    required List<Map<String, dynamic>> equiposLocales,
  }) async {
    try {
      await _asegurarSesion();
    } catch (e) {
      debugPrint('InventarioSync: sin conexión para autenticar ($e). '
          'Se sigue trabajando localmente.');
      estadoNotifier.value = 'sin_conexion';
      return;
    }

    if (_clienteIdActivo == clienteId && _sub != null) return;

    final clienteDoc = _db.collection('clientes').doc(clienteId);
    try {
      final existentes = await _equiposRef(clienteId).limit(1).get(
            const GetOptions(source: Source.server),
          );
      if (existentes.docs.isEmpty && equiposLocales.isNotEmpty) {
        await _subirEstructura(
            clienteId, clienteDoc, clienteMeta, equiposLocales);
      } else {
        await clienteDoc.set({
          ...clienteMeta,
          'ultima_modificacion': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    } catch (e) {
      debugPrint('InventarioSync: no se pudo sembrar/actualizar cliente '
          '($e). El listener sigue intentando igual.');
    }

    await _attachListener(clienteId);
  }

  /// Sincroniza la ESTRUCTURA completa del inventario contra la nube: se
  /// usa cuando el técnico importa o reimporta un Excel, es decir, cuando
  /// la lista que trae en la mano es la verdad actual de qué equipos existen
  /// para ese cliente.
  ///
  /// A diferencia de [attachCliente], esto SIEMPRE fusiona (nunca se salta
  /// la subida solo porque la nube ya tenga algo) — si se saltara, la
  /// reimportación de un Excel completo podía terminar mostrando solo lo
  /// poco que ya hubiera en la nube, descartando en pantalla el resto de lo
  /// recién importado (exactamente lo que pasó con "NEFROUROS PEREIRA").
  ///
  /// Los campos de calibración (certificado/fecha/observaciones/fuera de
  /// servicio/fuera de servicio por) NO se pisan con un valor vacío: si
  /// este dispositivo no trae un valor real para esos campos, se omiten
  /// del envío para que Firestore conserve lo que ya haya subido otro
  /// técnico.
  static Future<void> sincronizarEstructura({
    required String clienteId,
    required Map<String, dynamic> clienteMeta,
    required List<Map<String, dynamic>> equipos,
  }) async {
    try {
      await _asegurarSesion();
    } catch (e) {
      debugPrint('InventarioSync: sin conexión para sincronizar estructura '
          '($e). Se sigue trabajando localmente.');
      estadoNotifier.value = 'sin_conexion';
      return;
    }

    final clienteDoc = _db.collection('clientes').doc(clienteId);
    try {
      await _subirEstructura(clienteId, clienteDoc, clienteMeta, equipos);
    } catch (e) {
      debugPrint('InventarioSync.sincronizarEstructura: $e');
    }

    await _attachListener(clienteId);
  }

  static Future<void> _subirEstructura(
    String clienteId,
    DocumentReference<Map<String, dynamic>> clienteDoc,
    Map<String, dynamic> clienteMeta,
    List<Map<String, dynamic>> equipos,
  ) async {
    // Firestore permite máximo 500 escrituras por batch.
    const tamanoLote = 400;
    for (int inicio = 0; inicio < equipos.length; inicio += tamanoLote) {
      final lote = equipos.skip(inicio).take(tamanoLote);
      final batch = _db.batch();
      if (inicio == 0) {
        batch.set(
            clienteDoc,
            {
              ...clienteMeta,
              'ultima_modificacion': FieldValue.serverTimestamp(),
            },
            SetOptions(merge: true));
      }
      for (final e in lote) {
        batch.set(_equiposRef(clienteId).doc(docId(e)), _soloEstructura(e),
            SetOptions(merge: true));
      }
      await batch.commit();
    }
  }

  /// Lista TODOS los clientes que existen hoy en la nube (los haya
  /// cargado este dispositivo o cualquier otro técnico), para que un
  /// técnico que nunca importó el Excel de un cliente pueda igual
  /// encontrarlo y descargarlo a su celular sin pedírselo a nadie.
  ///
  /// Trae la colección completa de una sola vez y el filtro por nombre se
  /// hace en la app (ver BuscarClienteNubePage) en vez de con una consulta
  /// de Firestore — para el volumen de clientes de esta empresa (decenas,
  /// no miles) es más simple y barato en lecturas que armar un índice de
  /// búsqueda por prefijo, y permite buscar por cualquier parte del
  /// nombre, no solo por cómo empieza.
  static Future<List<Map<String, dynamic>>> listarClientesNube() async {
    try {
      await _asegurarSesion();
      final snap = await _db.collection('clientes').get();
      return snap.docs.map((d) => {'id': d.id, ..._paraApp(d.data())}).toList();
    } catch (e) {
      debugPrint('InventarioSync.listarClientesNube: $e');
      return [];
    }
  }

  /// Descarga todos los equipos de un cliente desde la nube (lectura única,
  /// no abre listener) — se usa para traer por primera vez a este
  /// dispositivo un inventario que otro técnico ya cargó.
  static Future<List<Map<String, dynamic>>> descargarEquipos(
      String clienteId) async {
    try {
      await _asegurarSesion();
      final snap = await _equiposRef(clienteId).get();
      return snap.docs.map(_equipoDeDoc).toList();
    } catch (e) {
      debugPrint('InventarioSync.descargarEquipos: $e');
      return [];
    }
  }

  static Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _clienteIdActivo = null;
    estadoNotifier.value = 'apagado';
  }

  /// Sube (crea o actualiza) un equipo. Si no hay internet, Firestore la
  /// guarda en disco y la reintenta solo cuando vuelva la señal.
  static Future<void> upsertEquipo(
    String clienteId,
    Map<String, dynamic> equipo,
  ) async {
    try {
      await _asegurarSesion();
      final tecnico = await TecnicoProfile.obtenerNombre();
      await _equiposRef(clienteId).doc(docId(equipo)).set({
        ..._limpiar(equipo),
        if (tecnico.isNotEmpty) 'actualizado_por': tecnico,
        'actualizado_en': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      // No se relanza: la escritura local (JSON) ya se hizo antes de
      // llamar aquí, así que el técnico nunca pierde su trabajo aunque la
      // nube no responda en este momento.
      debugPrint('InventarioSync.upsertEquipo: $e');
    }
  }

  static Future<void> eliminarEquipo(
    String clienteId,
    Map<String, dynamic> equipo,
  ) async {
    try {
      await _asegurarSesion();
      await _equiposRef(clienteId).doc(docId(equipo)).delete();
    } catch (e) {
      debugPrint('InventarioSync.eliminarEquipo: $e');
    }
  }

  static Future<void> actualizarMetaCliente(
    String clienteId,
    Map<String, dynamic> meta,
  ) async {
    try {
      await _asegurarSesion();
      await _db.collection('clientes').doc(clienteId).set({
        ...meta,
        'ultima_modificacion': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('InventarioSync.actualizarMetaCliente: $e');
    }
  }

  /// El id del documento ES la clave del equipo: se copia a `clave_nube`
  /// para que toda escritura posterior vuelva a este mismo documento
  /// aunque se editen sus campos.
  static Map<String, dynamic> _equipoDeDoc(
          QueryDocumentSnapshot<Map<String, dynamic>> d) =>
      {..._paraApp(d.data()), 'clave_nube': d.id};

  /// Convierte los tipos propios de Firestore (como `Timestamp`) que llegan
  /// en un documento a algo que el resto de la app pueda guardar tal cual
  /// en un JSON local (`JsonEncoder` no sabe codificar un `Timestamp` — sin
  /// esto, guardar el inventario o una solicitud después de recibir un
  /// cambio remoto revienta con "Converting object to an encodable object
  /// failed: Instance of 'Timestamp'").
  static Map<String, dynamic> _paraApp(Map<String, dynamic> data) {
    final copia = Map<String, dynamic>.from(data);
    for (final key in copia.keys.toList()) {
      final v = copia[key];
      if (v is Timestamp) {
        copia[key] = v.toDate().toIso8601String();
      }
    }
    return copia;
  }

  /// Quita valores nulos, que Firestore no admite bien en `set` con merge
  /// (y que de todas formas no aportan nada frente a simplemente omitir
  /// el campo).
  static Map<String, dynamic> _limpiar(Map<String, dynamic> equipo) {
    final copia = Map<String, dynamic>.from(equipo);
    copia.removeWhere((key, value) => value == null);
    return copia;
  }

  /// Como [_limpiar], pero además omite los campos de calibración cuando
  /// este dispositivo no trae un valor real para ellos — para que subir la
  /// ESTRUCTURA de un Excel reimportado nunca borre en la nube un
  /// certificado/fecha/observación que otro técnico ya haya registrado.
  static Map<String, dynamic> _soloEstructura(Map<String, dynamic> equipo) {
    final copia = _limpiar(equipo);
    for (final campo in [
      'certificado',
      'fecha',
      'observaciones',
      'fuera_de_servicio_por',
      'no_pasa_calibracion_detalle',
      'no_pasa_calibracion_por',
    ]) {
      if ((copia[campo]?.toString().trim() ?? '').isEmpty) {
        copia.remove(campo);
      }
    }
    if (copia['fuera_de_servicio'] != true) {
      copia.remove('fuera_de_servicio');
    }
    if (copia['no_pasa_calibracion'] != true) {
      copia.remove('no_pasa_calibracion');
    }
    return copia;
  }
}
