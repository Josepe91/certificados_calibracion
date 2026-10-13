import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'auth_tecnico.dart';
import 'inventario_sync.dart';

/// "Certificado montado": marca, por equipo, que Sebastián ya armó el
/// certificado final en la oficina a partir de la calibración del técnico.
///
/// Vive en su PROPIA colección, `clientes/{clienteId}/montajes/{equipoId}`
/// (mismo `equipoId` que el equipo, ver InventarioSync.docId), y no como
/// campos del documento del equipo, a propósito:
/// - Las reglas pueden dejar que SOLO [AuthTecnico.admin] escriba aquí sin
///   tocar cómo los técnicos escriben sus equipos. Si fueran campos del
///   equipo, cada `upsertEquipo` de un técnico (que manda el mapa completo
///   que tiene en el celular) podría devolver un "montado" viejo y pisar la
///   marca, o las reglas tendrían que rechazarle la edición entera.
/// - Reimportar un Excel (`sincronizarEstructura`) nunca puede borrarla.
///
/// Cada marcar/desmarcar agrega una entrada a `historial` (quién, cuándo,
/// motivo) que se muestra al abrir el equipo.
class MontajesSync {
  MontajesSync._();

  static final FirebaseFirestore _db = FirebaseFirestore.instance;
  static StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _sub;
  static String? _clienteIdActivo;

  /// Montajes del cliente activo, por `equipoId` (InventarioSync.docId).
  static final ValueNotifier<Map<String, Map<String, dynamic>>> notifier =
      ValueNotifier(const {});

  static CollectionReference<Map<String, dynamic>> _ref(String clienteId) =>
      _db.collection('clientes').doc(clienteId).collection('montajes');

  static Map<String, dynamic>? de(Map<String, dynamic> equipo) =>
      notifier.value[InventarioSync.docId(equipo)];

  /// Montado = tiene la marca Y sigue teniendo número de certificado (si al
  /// equipo le borraron el certificado, la marca vieja ya no aplica).
  static bool estaMontado(Map<String, dynamic> equipo,
      [Map<String, Map<String, dynamic>>? montajes]) {
    if ((equipo['certificado']?.toString().trim() ?? '').isEmpty) return false;
    final m = (montajes ?? notifier.value)[InventarioSync.docId(equipo)];
    return m?['montado'] == true;
  }

  static Future<void> attach(String clienteId) async {
    if (_clienteIdActivo == clienteId && _sub != null) return;
    await detach();
    _clienteIdActivo = clienteId;
    _sub = _ref(clienteId).snapshots().listen((snap) {
      notifier.value = {
        for (final d in snap.docs) d.id: _paraApp(d.data()),
      };
    }, onError: (e) => debugPrint('MontajesSync: error en listener ($e)'));
  }

  static Future<void> detach() async {
    await _sub?.cancel();
    _sub = null;
    _clienteIdActivo = null;
    notifier.value = const {};
  }

  /// Lectura única (para exportar el Excel de un cliente que no es el
  /// activo). Si no hay señal usa lo que haya en el caché de Firestore.
  static Future<Map<String, Map<String, dynamic>>> cargar(
      String clienteId) async {
    try {
      await AuthTecnico.asegurarSesion();
      if (clienteId == _clienteIdActivo) return notifier.value;
      final snap = await _ref(clienteId)
          .get()
          .timeout(const Duration(seconds: 8),
              onTimeout: () => _ref(clienteId)
                  .get(const GetOptions(source: Source.cache)));
      return {for (final d in snap.docs) d.id: _paraApp(d.data())};
    } catch (e) {
      debugPrint('MontajesSync.cargar: $e');
      return const {};
    }
  }

  static Map<String, dynamic> _entrada(
          String accion, Map<String, dynamic> equipo, String motivo) =>
      {
        'accion': accion,
        'por': AuthTecnico.nombre,
        'correo': AuthTecnico.correo,
        // Hora del celular: serverTimestamp no se permite dentro de arrays.
        'en': DateTime.now().toIso8601String(),
        'certificado': equipo['certificado']?.toString().trim() ?? '',
        if (motivo.isNotEmpty) 'motivo': motivo,
      };

  /// Marca uno o varios equipos como montados (un solo batch). Firestore
  /// la encola si no hay señal, igual que las escrituras de equipos.
  static Future<void> marcar(
      String clienteId, List<Map<String, dynamic>> equipos) async {
    await AuthTecnico.asegurarSesion();
    if (!AuthTecnico.esAdmin) {
      throw StateError('Solo ${AuthTecnico.admin} puede marcar montados');
    }
    for (var i = 0; i < equipos.length; i += 400) {
      final batch = _db.batch();
      for (final e in equipos.skip(i).take(400)) {
        batch.set(
          _ref(clienteId).doc(InventarioSync.docId(e)),
          {
            'montado': true,
            'certificado': e['certificado']?.toString().trim() ?? '',
            'equipo': e['nombre']?.toString() ?? '',
            'montado_por': AuthTecnico.nombre,
            'montado_en': FieldValue.serverTimestamp(),
            'historial':
                FieldValue.arrayUnion([_entrada('montado', e, '')]),
          },
          SetOptions(merge: true),
        );
      }
      // Sin await del commit si no hay señal: la escritura ya quedó en la
      // cola local de Firestore y el listener la refleja de inmediato.
      unawaited(batch.commit().catchError(
          (e) => debugPrint('MontajesSync.marcar: $e')));
    }
  }

  static Future<void> desmarcar(
      String clienteId, Map<String, dynamic> equipo, String motivo) async {
    await AuthTecnico.asegurarSesion();
    if (!AuthTecnico.esAdmin) {
      throw StateError('Solo ${AuthTecnico.admin} puede desmarcar montados');
    }
    unawaited(_ref(clienteId).doc(InventarioSync.docId(equipo)).set(
      {
        'montado': false,
        'montado_por': FieldValue.delete(),
        'montado_en': FieldValue.delete(),
        'historial':
            FieldValue.arrayUnion([_entrada('desmontado', equipo, motivo)]),
      },
      SetOptions(merge: true),
    ).catchError((e) => debugPrint('MontajesSync.desmarcar: $e')));
  }

  static Map<String, dynamic> _paraApp(Map<String, dynamic> data) {
    final copia = Map<String, dynamic>.from(data);
    final en = copia['montado_en'];
    if (en is Timestamp) copia['montado_en'] = en.toDate().toIso8601String();
    return copia;
  }
}
