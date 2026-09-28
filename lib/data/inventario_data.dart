import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'inventario_sync.dart';
import '../utils/text_utils.dart';

class InventarioData {
  // =====================
  // NOTIFIERS
  // =====================
  static final ValueNotifier<List<Map<String, dynamic>>> equiposNotifier =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  // Se incrementa al limpiar el inventario para que InventarioPage
  // refresque su lista de clientes.
  static final ValueNotifier<int> versionNotifier = ValueNotifier(0);

  static List<Map<String, dynamic>> get equipos => equiposNotifier.value;

  // =====================
  // INVENTARIO ACTIVO
  // =====================
  static String? clienteActivo;
  static String? archivoOrigen;

  // =====================
  // DATOS DEL CLIENTE
  // =====================
  static String cliente = '';
  static String nit = '';
  static String telefono = '';
  static String direccion = '';
  static String ciudad = '';

  // =====================
  // DIRECTORIO DE INVENTARIOS
  // =====================
  static Future<Directory> _inventariosDir() async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'BTMC_SYNC', 'inventarios'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _archivoCliente(String nombreCliente) async {
    final dir = await _inventariosDir();
    final nombre = nombreCliente
        .replaceAll(RegExp(r'[^a-zA-Z0-9áéíóúÁÉÍÓÚñÑ\s]'), '')
        .replaceAll(RegExp(r'\s+'), '_');
    return File(p.join(dir.path, '$nombre.json'));
  }

  // =====================
  // LISTAR INVENTARIOS
  // =====================
  static Future<List<Map<String, dynamic>>> listarInventarios() async {
    final dir = await _inventariosDir();
    final archivos = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList();

    final List<Map<String, dynamic>> resultado = [];
    for (final f in archivos) {
      try {
        final data = jsonDecode(await f.readAsString());
        final clienteData = data['cliente'] ?? {};
        final equiposList = (data['equipos'] as List?) ?? [];
        final calibrados = equiposList
            .where(
                (e) => (e['certificado']?.toString().trim() ?? '').isNotEmpty)
            .length;
        resultado.add({
          'archivo': f.path,
          'nombre': clienteData['nombre'] ?? f.uri.pathSegments.last,
          'nit': clienteData['nit'] ?? '',
          'ciudad': clienteData['ciudad'] ?? '',
          'total_equipos': equiposList.length,
          'calibrados': calibrados,
          'archivo_origen': data['archivo_origen'] ?? '',
        });
      } catch (e) {
        debugPrint('InventarioData: error leyendo ${f.path}: $e');
      }
    }
    resultado.sort((a, b) => a['nombre'].compareTo(b['nombre']));
    return resultado;
  }

  // =====================
  // ID ÚNICO POR EQUIPO
  //
  // El "serie"/"inventario" que trae el Excel del cliente NO es confiable
  // como identificador: es común que varios equipos compartan el mismo
  // texto de relleno ("NO REGISTRA", "N/A", vacío, etc). Si esos campos se
  // usan para buscar/actualizar un equipo específico, `indexWhere` siempre
  // encuentra el PRIMER equipo con ese valor — no necesariamente el que el
  // técnico seleccionó — y la actualización cae sobre el equipo equivocado.
  //
  // Por eso cada equipo recibe un "id" interno único (invisible para el
  // usuario) apenas se crea o se importa. Todo el matching interno de la
  // app debe preferir este id sobre serie/inventario/nombre.
  // =====================
  static int _idSeed = 0;

  static String _generarId() {
    _idSeed++;
    return 'eq_${DateTime.now().microsecondsSinceEpoch}_$_idSeed';
  }

  /// Asegura que todo equipo de la lista tenga un id único, asignando uno
  /// a los que no lo tengan (migración de inventarios guardados antes de
  /// que existiera este campo). Retorna true si tuvo que asignar alguno.
  static bool _asegurarIds(List<Map<String, dynamic>> equipos) {
    bool asignado = false;
    for (int i = 0; i < equipos.length; i++) {
      final id = equipos[i]['id']?.toString() ?? '';
      if (id.isEmpty) {
        equipos[i] = {...equipos[i], 'id': _generarId()};
        asignado = true;
      }
    }
    return asignado;
  }

  /// Busca el índice de un equipo por su id. Si el equipo de referencia no
  /// trae id (dato viejo), cae de vuelta a la búsqueda en cascada por
  /// serie → inventario → nombre+ubicación.
  static int indexPorIdOCascada(
    List<Map<String, dynamic>> lista,
    Map<String, dynamic> referencia,
  ) {
    final id = referencia['id']?.toString() ?? '';
    if (id.isNotEmpty) {
      final porId = lista.indexWhere((e) => e['id']?.toString() == id);
      if (porId != -1) return porId;
    }

    final serie = referencia['serie']?.toString().trim() ?? '';
    final inventario = referencia['inventario']?.toString().trim() ?? '';
    final nombre = referencia['nombre']?.toString().trim() ?? '';
    final ubicacion = referencia['ubicacion']?.toString().trim() ?? '';

    return lista.indexWhere((e) {
      if (serie.isNotEmpty) {
        return e['serie']?.toString().trim() == serie;
      }
      if (inventario.isNotEmpty) {
        return e['inventario']?.toString().trim() == inventario;
      }
      return e['nombre']?.toString().trim() == nombre &&
          e['ubicacion']?.toString().trim() == ubicacion;
    });
  }

  // =====================
  // CARGAR INVENTARIO DE UN CLIENTE
  // =====================
  static Future<void> cargarCliente(String nombreCliente) async {
    final file = await _archivoCliente(nombreCliente);
    if (!await file.exists()) return;

    final data = jsonDecode(await file.readAsString());
    final clienteJson = data['cliente'] ?? {};

    cliente = clienteJson['nombre'] ?? '';
    nit = clienteJson['nit'] ?? '';
    telefono = clienteJson['telefono'] ?? '';
    direccion = clienteJson['direccion'] ?? '';
    ciudad = clienteJson['ciudad'] ?? '';
    clienteActivo = nombreCliente;
    archivoOrigen = data['archivo_origen'] ?? '';

    final List lista = data['equipos'] ?? [];
    final equipos = lista.map((e) => Map<String, dynamic>.from(e)).toList();

    // Migración: si algún equipo no tiene id (inventario guardado antes de
    // este cambio), se le asigna uno y se persiste de inmediato.
    final huboMigracion = _asegurarIds(equipos);
    equiposNotifier.value = equipos;
    if (huboMigracion) await _guardar();

    _conectarSync(equipos);
  }

  // =====================
  // CARGAR CLIENTE DESDE LA NUBE (SIN IMPORTAR EL EXCEL DE NUEVO)
  //
  // Se usa cuando un técnico busca un cliente que YA fue cargado a la nube
  // por otro técnico (BuscarClienteNubePage) — descarga sus equipos de
  // Firestore, los guarda como inventario local (mismo formato que
  // _guardar()) y reusa cargarCliente() para activarlo, así queda
  // exactamente en el mismo estado que si el Excel se hubiera importado en
  // este celular.
  // =====================
  static Future<void> cargarClienteDesdeNube({
    required String clienteId,
    required Map<String, dynamic> clienteMeta,
  }) async {
    final nombreCliente = (clienteMeta['nombre'] ?? '').toString().trim();
    if (nombreCliente.isEmpty) return;

    final equiposRemotos = await InventarioSync.descargarEquipos(clienteId);
    final equiposDescargados =
        equiposRemotos.map((e) => Map<String, dynamic>.from(e)).toList();
    // Por si algún equipo llegara sin 'id' (no debería, pero por
    // consistencia con el resto de la app: todo equipo local necesita uno
    // para que el matching interno funcione).
    _asegurarIds(equiposDescargados);

    final data = {
      'archivo_origen': clienteMeta['archivo_origen'] ?? '',
      'cliente': {
        'nombre': nombreCliente,
        'nit': clienteMeta['nit'] ?? '',
        'telefono': clienteMeta['telefono'] ?? '',
        'direccion': clienteMeta['direccion'] ?? '',
        'ciudad': clienteMeta['ciudad'] ?? '',
      },
      'equipos': equiposDescargados,
      'ultima_modificacion': DateTime.now().toIso8601String(),
    };

    final file = await _archivoCliente(nombreCliente);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));

    // cargarCliente relee este mismo archivo, activa el cliente y conecta
    // el listener en tiempo real (attachCliente) — de ahí en adelante se
    // comporta igual que un cliente que este celular ya conocía.
    await cargarCliente(nombreCliente);
  }

  // =====================
  // SYNC EN LA NUBE (VER inventario_sync.dart)
  //
  // Conecta el listener en tiempo real de Firestore para el cliente activo.
  // No se espera (no `await` desde los llamadores) para no bloquear la UI
  // si el dispositivo está sin señal en ese momento: InventarioSync ya
  // maneja ese caso internamente y no lanza excepción hacia afuera.
  // =====================
  static void _conectarSync(List<Map<String, dynamic>> equiposLocales) {
    InventarioSync.onEquiposRemotos = _aplicarEquiposRemotos;
    unawaited(InventarioSync.attachCliente(
      clienteId: InventarioSync.slug(cliente),
      clienteMeta: {
        'nombre': cliente,
        'nit': nit,
        'telefono': telefono,
        'direccion': direccion,
        'ciudad': ciudad,
        'archivo_origen': archivoOrigen ?? '',
      },
      equiposLocales: equiposLocales,
    ));
  }

  /// Se ejecuta cuando llega un cambio remoto (de este dispositivo o de
  /// cualquier otro técnico trabajando el mismo cliente). Reemplaza la
  /// lista completa por la versión de Firestore, que ya incluye tanto los
  /// cambios propios pendientes de subir como los de los demás.
  static void _aplicarEquiposRemotos(List<Map<String, dynamic>> remotos) {
    if (cliente.isEmpty) return;
    final copia = remotos.map((e) => Map<String, dynamic>.from(e)).toList();
    copia.sort((a, b) {
      final oa = a['orden'] is int ? a['orden'] as int : 0;
      final ob = b['orden'] is int ? b['orden'] as int : 0;
      return oa.compareTo(ob);
    });
    equiposNotifier.value = copia;
    unawaited(_guardar()); // refresca el JSON local (offline/export lo usan)
  }

  // =====================
  // CARGAR DESDE JSON (compatibilidad)
  // =====================
  static Future<void> cargarDesdeJson() async {
    if (clienteActivo != null) {
      await cargarCliente(clienteActivo!);
      return;
    }
    final base = await getApplicationDocumentsDirectory();
    final activoFile = File(p.join(base.path, 'BTMC_SYNC', 'activo.txt'));
    if (await activoFile.exists()) {
      final nombre = await activoFile.readAsString();
      if (nombre.isNotEmpty) await cargarCliente(nombre.trim());
    }
  }

  // =====================
  // GUARDAR INVENTARIO ACTIVO
  // =====================
  static Future<void> _guardar() async {
    if (cliente.isEmpty) return;

    final data = {
      'archivo_origen': archivoOrigen ?? '',
      'cliente': {
        'nombre': cliente,
        'nit': nit,
        'telefono': telefono,
        'direccion': direccion,
        'ciudad': ciudad,
      },
      'equipos': equiposNotifier.value,
      'ultima_modificacion': DateTime.now().toIso8601String(),
    };

    final file = await _archivoCliente(cliente);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(data));

    final base = await getApplicationDocumentsDirectory();
    final activoFile = File(p.join(base.path, 'BTMC_SYNC', 'activo.txt'));
    await activoFile.writeAsString(cliente);
  }

  // =====================
  // GUARDAR NUEVO INVENTARIO DESDE EXCEL
  // Si el cliente ya tenía un inventario guardado, conserva los certificados
  // y fechas previamente asignados en la app para equipos que coincidan.
  // =====================
  static Future<void> guardarNuevoInventario({
    required String nombreArchivo,
    required String nombreCliente,
    required String nitCliente,
    required String telefonoCliente,
    required String direccionCliente,
    required String ciudadCliente,
    required List<Map<String, dynamic>> equipos,
  }) async {
    // Leer datos existentes de la app antes de sobreescribir.
    // Se preservan: id, certificado, fecha, observaciones,
    // fuera_de_servicio, fuera_de_servicio_por, no_pasa_calibracion,
    // no_pasa_calibracion_detalle y no_pasa_calibracion_por (campos que el
    // técnico asigna en la app y que el Excel no trae).
    //
    // Varios equipos pueden compartir el mismo texto de serie/inventario
    // (p.ej. "NO REGISTRA"), así que la clave de emparejamiento no alcanza
    // por sí sola: se agrega un contador de ocurrencia para que el N-ésimo
    // equipo repetido del Excel viejo se empareje con el N-ésimo equipo
    // repetido del Excel nuevo, en vez de que todos los repetidos colapsen
    // sobre un solo registro (lo que cruzaba certificados entre equipos
    // físicamente distintos).
    final Map<String, List<Map<String, dynamic>>> datosExistentes = {};
    final archivoExistente = await _archivoCliente(nombreCliente);
    if (await archivoExistente.exists()) {
      try {
        final dataExistente = jsonDecode(await archivoExistente.readAsString());
        for (final e in (dataExistente['equipos'] as List? ?? [])) {
          final cert = e['certificado']?.toString().trim() ?? '';
          final obs = e['observaciones']?.toString().trim() ?? '';
          final fds = e['fuera_de_servicio'] == true;
          final fdsPor = e['fuera_de_servicio_por']?.toString().trim() ?? '';
          final noPasa = e['no_pasa_calibracion'] == true;
          final noPasaDetalle =
              e['no_pasa_calibracion_detalle']?.toString().trim() ?? '';
          final noPasaPor =
              e['no_pasa_calibracion_por']?.toString().trim() ?? '';
          final id = e['id']?.toString() ?? '';
          if (cert.isEmpty &&
              obs.isEmpty &&
              !fds &&
              !noPasa &&
              id.isEmpty) {
            continue;
          }

          final serie = e['serie']?.toString().trim() ?? '';
          final inv = e['inventario']?.toString().trim() ?? '';
          final nom = e['nombre']?.toString().trim() ?? '';
          final ubic = e['ubicacion']?.toString().trim() ?? '';
          final key = serie.isNotEmpty
              ? 's:$serie'
              : inv.isNotEmpty
                  ? 'i:$inv'
                  : 'n:$nom:$ubic';
          (datosExistentes[key] ??= []).add({
            'id': id,
            'certificado': cert,
            'fecha': e['fecha']?.toString().trim() ?? '',
            'observaciones': obs,
            'fuera_de_servicio': fds,
            'fuera_de_servicio_por': fdsPor,
            'no_pasa_calibracion': noPasa,
            'no_pasa_calibracion_detalle': noPasaDetalle,
            'no_pasa_calibracion_por': noPasaPor,
          });
        }
      } catch (_) {}
    }

    // Aplicar datos existentes a los equipos del nuevo Excel, emparejando
    // por ocurrencia dentro de cada clave repetida.
    if (datosExistentes.isNotEmpty) {
      final Map<String, int> ocurrencia = {};
      equipos = equipos.map((e) {
        final serie = e['serie']?.toString().trim() ?? '';
        final inv = e['inventario']?.toString().trim() ?? '';
        final nom = e['nombre']?.toString().trim() ?? '';
        final ubic = e['ubicacion']?.toString().trim() ?? '';
        final key = serie.isNotEmpty
            ? 's:$serie'
            : inv.isNotEmpty
                ? 'i:$inv'
                : 'n:$nom:$ubic';

        final candidatos = datosExistentes[key];
        if (candidatos == null || candidatos.isEmpty) return e;

        final n = ocurrencia[key] = (ocurrencia[key] ?? 0);
        ocurrencia[key] = n + 1;
        if (n >= candidatos.length) return e;
        final datos = candidatos[n];

        final certExcel = e['certificado']?.toString().trim() ?? '';
        final idPrevio =
            (datos['id'] as String).isNotEmpty ? datos['id'] as String : null;
        return {
          ...e,
          // Conservar el id del equipo previo para que su historial e
          // identidad no se pierdan al reimportar el mismo Excel.
          if (idPrevio != null) 'id': idPrevio,
          // Certificado/fecha: usar el del Excel si lo trae, si no el de la app
          if (certExcel.isEmpty && (datos['certificado'] as String).isNotEmpty)
            'certificado': datos['certificado'],
          if (certExcel.isEmpty && (datos['fecha'] as String).isNotEmpty)
            'fecha': datos['fecha'],
          // Observaciones y fuera_de_servicio: siempre de la app (el Excel no los tiene)
          if ((datos['observaciones'] as String).isNotEmpty)
            'observaciones': datos['observaciones'],
          if (datos['fuera_de_servicio'] == true) 'fuera_de_servicio': true,
          if ((datos['fuera_de_servicio_por'] as String).isNotEmpty)
            'fuera_de_servicio_por': datos['fuera_de_servicio_por'],
          if (datos['no_pasa_calibracion'] == true)
            'no_pasa_calibracion': true,
          if ((datos['no_pasa_calibracion_detalle'] as String).isNotEmpty)
            'no_pasa_calibracion_detalle': datos['no_pasa_calibracion_detalle'],
          if ((datos['no_pasa_calibracion_por'] as String).isNotEmpty)
            'no_pasa_calibracion_por': datos['no_pasa_calibracion_por'],
        };
      }).toList();
    }

    // Todo equipo que siga sin id (nuevo, o Excel reimportado por primera
    // vez) recibe uno ahora.
    _asegurarIds(equipos);

    // 'orden' fija la posición original del Excel para que, al sincronizar
    // por Firestore (que no garantiza el orden de inserción), la lista se
    // pueda reordenar igual en todos los dispositivos.
    equipos = [
      for (int i = 0; i < equipos.length; i++) {...equipos[i], 'orden': i}
    ];

    cliente = nombreCliente;
    nit = nitCliente;
    telefono = telefonoCliente;
    direccion = direccionCliente;
    ciudad = ciudadCliente;
    clienteActivo = nombreCliente;
    archivoOrigen = nombreArchivo;
    equiposNotifier.value = equipos;
    await _guardar();

    // Reimportar un Excel es el momento en que el técnico dice "esta es la
    // lista real de equipos" — a diferencia de solo reabrir un cliente ya
    // cargado, aquí SIEMPRE hay que fusionar esta lista completa contra la
    // nube (ver sincronizarEstructura), nunca dejar que la nube reemplace
    // en pantalla lo que se acaba de importar.
    InventarioSync.onEquiposRemotos = _aplicarEquiposRemotos;
    unawaited(InventarioSync.sincronizarEstructura(
      clienteId: InventarioSync.slug(cliente),
      clienteMeta: {
        'nombre': cliente,
        'nit': nit,
        'telefono': telefono,
        'direccion': direccion,
        'ciudad': ciudad,
        'archivo_origen': archivoOrigen ?? '',
      },
      equipos: equipos,
    ));
  }

  // =====================
  // ELIMINAR INVENTARIO DE UN CLIENTE
  // =====================
  static Future<void> eliminarCliente(String nombreCliente) async {
    final file = await _archivoCliente(nombreCliente);
    if (await file.exists()) await file.delete();
    // Nota: esto solo borra la copia local de este dispositivo. El
    // inventario en la nube (compartido con los demás técnicos) NO se
    // borra aquí a propósito, para que un "eliminar" accidental en un
    // dispositivo no le borre el inventario a todo el equipo.
    if (clienteActivo == nombreCliente) await limpiar();
  }

  // =====================
  // AGREGAR EQUIPO
  // =====================
  static Future<void> agregarEquipo(Map<String, dynamic> equipo) async {
    final copia = List<Map<String, dynamic>>.from(equiposNotifier.value);
    final nuevo = {
      ...equipo,
      'nuevo': true,
      'id': _generarId(),
      'orden': copia.length,
    };
    copia.add(nuevo);
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(InventarioSync.upsertEquipo(InventarioSync.slug(cliente), nuevo));
  }

  // =====================
  // ACTUALIZAR EQUIPO (EDICIÓN MANUAL)
  // Arranca del equipo existente y aplica encima los cambios del diálogo,
  // así cualquier campo futuro que el diálogo no incluya queda preservado.
  // =====================
  static Future<void> actualizar(
      int index, Map<String, dynamic> actualizado) async {
    if (index < 0 || index >= equiposNotifier.value.length) return;
    final copia = List<Map<String, dynamic>>.from(equiposNotifier.value);
    copia[index] = {...copia[index], ...actualizado};
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(
        InventarioSync.upsertEquipo(InventarioSync.slug(cliente), copia[index]));
  }

  // =====================
  // ACTUALIZAR CERTIFICADO / FECHA
  //
  // Búsqueda en cascada por campos naturales del equipo:
  //   1. Por número de serie    (si no está vacío)
  //   2. Por número de inventario (si no está vacío)
  //   3. Por nombre + ubicación  (equipos sin serie ni inventario,
  //                               mostrados como "Por identificar")
  // =====================
  // =====================
  // LIMPIAR CERTIFICADO DE UN EQUIPO
  // Se usa cuando se corrige el equipo de una solicitud existente,
  // para dejar en blanco el certificado del equipo que fue asignado por error.
  // =====================
  static Future<void> limpiarCertificado(Map<String, dynamic> equipo) async {
    final copia = List<Map<String, dynamic>>.from(equiposNotifier.value);

    final index = indexPorIdOCascada(copia, equipo);

    if (index == -1) return;
    copia[index] = {
      ...copia[index],
      'certificado': '',
      'fecha': '',
    };
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(
        InventarioSync.upsertEquipo(InventarioSync.slug(cliente), copia[index]));
  }

  // Retorna true si el equipo fue encontrado y actualizado, false si no.
  static Future<bool> actualizarEquipo({
    required Map<String, dynamic> equipoOriginal,
    required Map<String, dynamic> equipoFinal,
    required String certificado,
    required String fecha,
    required String observaciones,
  }) async {
    final copia = List<Map<String, dynamic>>.from(equiposNotifier.value);

    final index = indexPorIdOCascada(copia, equipoOriginal);

    if (index == -1) {
      final serie = equipoOriginal['serie']?.toString().trim() ?? '';
      final inventario = equipoOriginal['inventario']?.toString().trim() ?? '';
      final nombre = equipoOriginal['nombre']?.toString().trim() ?? '';
      debugPrint('InventarioData.actualizarEquipo: equipo no encontrado '
          '(id="${equipoOriginal['id']}", serie="$serie", '
          'inventario="$inventario", nombre="$nombre").');
      return false;
    }

    copia[index] = {
      ...copia[index], // preservar campos existentes (fuera_de_servicio, etc.)
      ...equipoFinal, // aplicar cambios del formulario
      'certificado': certificado,
      'fecha': fecha,
      'observaciones': observaciones,
      'nuevo': false,
    };
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(
        InventarioSync.upsertEquipo(InventarioSync.slug(cliente), copia[index]));
    return true;
  }

  // =====================
  // ELIMINAR EQUIPO
  // =====================
  static Future<void> eliminarEquipo(int index) async {
    if (index < 0 || index >= equiposNotifier.value.length) return;
    final copia = List<Map<String, dynamic>>.from(equiposNotifier.value);
    final borrado = copia[index];
    copia.removeAt(index);
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(
        InventarioSync.eliminarEquipo(InventarioSync.slug(cliente), borrado));
  }

  // =====================
  // BUSCAR
  // =====================
  static List<Map<String, dynamic>> buscar(String texto) {
    final q = TextUtils.quitarTildes(texto).toLowerCase();
    String norm(dynamic v) => TextUtils.quitarTildes(v.toString()).toLowerCase();
    return equipos.where((e) {
      return norm(e['serie']).contains(q) ||
          norm(e['inventario']).contains(q) ||
          norm(e['nombre']).contains(q) ||
          norm(e['ubicacion']).contains(q);
    }).toList();
  }

  // =====================
  // LIMPIAR ACTIVO (solo memoria)
  // =====================
  static Future<void> limpiar() async {
    await InventarioSync.detach();
    equiposNotifier.value = [];
    cliente = '';
    nit = '';
    telefono = '';
    direccion = '';
    ciudad = '';
    clienteActivo = null;
    archivoOrigen = null;
    versionNotifier.value++;
  }

  // =====================
  // BORRAR TODOS LOS INVENTARIOS (archivos + memoria)
  // =====================
  static Future<void> limpiarTodosLosInventarios() async {
    final dir = await _inventariosDir();
    if (await dir.exists()) await dir.delete(recursive: true);

    final base = await getApplicationDocumentsDirectory();
    final activoFile = File(p.join(base.path, 'BTMC_SYNC', 'activo.txt'));
    if (await activoFile.exists()) await activoFile.delete();

    await limpiar();
  }
}
