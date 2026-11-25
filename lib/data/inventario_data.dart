import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'certificado_excel.dart';
import 'inventario_sync.dart';
import 'solicitudes_storage.dart';
import 'solicitudes_sync.dart';
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
      // Datos guardados antes de clave_nube: su documento en la nube es el
      // que calcula claveEquipo con el contenido actual.
      if ((equipos[i]['clave_nube']?.toString() ?? '').isEmpty) {
        equipos[i] = {
          ...equipos[i],
          'clave_nube': InventarioSync.claveEquipo(equipos[i]),
        };
        asignado = true;
      }
    }
    return asignado;
  }

  /// Busca el índice de un equipo por clave_nube, luego por id y, si el
  /// equipo de referencia no trae ninguno (dato viejo), en cascada por
  /// serie → inventario → nombre+ubicación.
  ///
  /// clave_nube va primero porque es igual en todos los celulares. El `id`
  /// local no: en la nube gana el del último celular que escribió el
  /// equipo, así que una solicitud guardada antes puede traer un id que ya
  /// no está en la lista, y la cascada por serie terminaba en el PRIMER
  /// equipo con esa serie ("NO REGISTRA") — certificado al equipo
  /// equivocado.
  static int indexPorIdOCascada(
    List<Map<String, dynamic>> lista,
    Map<String, dynamic> referencia,
  ) {
    final clave = referencia['clave_nube']?.toString() ?? '';
    if (clave.isNotEmpty) {
      final porClave =
          lista.indexWhere((e) => e['clave_nube']?.toString() == clave);
      if (porClave != -1) return porClave;
    }

    final id = referencia['id']?.toString() ?? '';
    if (id.isNotEmpty) {
      final porId = lista.indexWhere((e) => e['id']?.toString() == id);
      if (porId != -1) return porId;
    }

    // Dato viejo sin clave ni id: se busca por contenido, pero solo se
    // acepta un resultado ÚNICO. Una serie/inventario de relleno ("NO
    // REGISTRA") o repetida ya no cae en el primer equipo que la tenga:
    // si hay varios candidatos, se prueba con una combinación más
    // específica y, si sigue ambiguo, no se toca ningún equipo (-1).
    for (final campos in const [
      ['serie', 'inventario', 'nombre'],
      ['serie', 'nombre'],
      ['inventario', 'nombre'],
      ['serie', 'inventario'],
      ['serie'],
      ['inventario'],
      ['nombre', 'ubicacion'],
    ]) {
      final claveRef = _claveCampos(referencia, campos);
      if (claveRef == null) continue;
      int encontrado = -1;
      int cuantos = 0;
      for (int i = 0; i < lista.length; i++) {
        if (_claveCampos(lista[i], campos) == claveRef) {
          encontrado = i;
          cuantos++;
        }
      }
      if (cuantos == 1) return encontrado;
    }
    return -1;
  }

  // Textos que los clientes ponen en serie/inventario cuando el equipo no
  // tiene uno: no identifican a ningún equipo.
  static const Set<String> _textosDeRelleno = {
    'NO REGISTRA', 'NOREGISTRA', 'NO REGISTRADO', 'NR', 'N/R', 'NA', 'N/A',
    'NO APLICA', 'S/N', 'SN', 'S/S', 'SIN SERIE', 'SIN SERIAL', 'SIN NUMERO',
    'SIN INVENTARIO', 'SIN CODIGO', 'SIN PLACA', 'NO TIENE', 'NO', 'NINGUNO',
    'ND', 'N/D', 'NO DISPONIBLE', 'X', 'XX', 'XXX',
  };

  /// Valor normalizado de un campo para emparejar equipos: mayúsculas, sin
  /// tildes ni espacios sobrantes. En serie/inventario, un texto de relleno
  /// ("NO REGISTRA", "N/A", "S/N", "0", "-") cuenta como vacío.
  static String valorParaEmparejar(Map<String, dynamic> e, String campo) {
    final s = TextUtils.quitarTildes(
            (e[campo]?.toString() ?? '').trim().toUpperCase())
        .replaceAll(RegExp(r'\s+'), ' ');
    if (campo != 'serie' && campo != 'inventario') return s;
    if (RegExp(r'^[\s\-_/\.0]*$').hasMatch(s)) return '';
    final sinPuntos = s.replaceAll('.', '').trim();
    if (_textosDeRelleno.contains(s) || _textosDeRelleno.contains(sinPuntos)) {
      return '';
    }
    return s;
  }

  /// Clave con los [campos] del equipo, o null si alguno está vacío (o es
  /// relleno): una clave incompleta no sirve para identificar un equipo.
  static String? _claveCampos(Map<String, dynamic> e, List<String> campos) {
    final partes = <String>[];
    for (final c in campos) {
      final v = valorParaEmparejar(e, c);
      if (v.isEmpty) return null;
      partes.add(v);
    }
    return partes.join('\u0001');
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
    // Equipos que otro técnico (o este celular) cambió: sus solicitudes
    // locales toman los datos nuevos.
    final previos = {
      for (final e in equiposNotifier.value)
        InventarioSync.docId(e): e,
    };
    final cambiados = <Map<String, dynamic>>[];
    for (final e in copia) {
      final previo = previos[InventarioSync.docId(e)];
      if (previo != null &&
          copiarCamposDelEquipo(Map<String, dynamic>.from(previo), e)) {
        cambiados.add(e);
      }
    }
    if (cambiados.isNotEmpty) {
      unawaited(propagarASolicitudes(cambiados, subirANube: false));
    }
    _asegurarIds(copia); // equipos creados desde un celular sin id
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
    // Equipos que ya se conocían de este cliente: la copia local (que el
    // listener mantiene al día con la nube) o, si este celular nunca lo
    // tuvo, la nube misma — así un técnico que importa por primera vez un
    // Excel que otro ya cargó reusa los MISMOS documentos (clave_nube) en
    // vez de crear otros porque sus filas quedaron en distinto orden.
    List<Map<String, dynamic>> existentes = [];
    final archivoExistente = await _archivoCliente(nombreCliente);
    if (await archivoExistente.exists()) {
      try {
        final data = jsonDecode(await archivoExistente.readAsString());
        existentes = [
          for (final e in (data['equipos'] as List? ?? []))
            Map<String, dynamic>.from(e as Map)
        ];
      } catch (_) {}
    } else {
      existentes = await InventarioSync.descargarEquipos(
              InventarioSync.slug(nombreCliente))
          .timeout(const Duration(seconds: 10), onTimeout: () => []);
    }

    equipos = fusionarConExistentes(equipos, existentes);

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

  /// Empareja cada fila del Excel nuevo con, a lo sumo, un equipo ya
  /// conocido. Devuelve, por fila nueva, el índice en [existentes] o null.
  ///
  /// La serie sola NO basta: los clientes repiten series (flujómetros,
  /// reguladores) y usan "NO REGISTRA" en serie o inventario. Antes todo
  /// equipo con la misma serie caía en un solo grupo y se emparejaba por
  /// orden de aparición, así que al cambiar el orden o un dato del Excel
  /// el certificado de un equipo quedaba en otro. Ahora se empareja por
  /// pasadas, de la más segura a la más floja:
  ///   1. Mismo número de certificado (lo más confiable), si es único y
  ///      la serie/inventario no lo contradicen.
  ///   2. Combinaciones de serie/inventario/nombre/marca/modelo/ubicación,
  ///      de la más completa a la más corta. Los rellenos cuentan como
  ///      vacíos y una combinación con un campo vacío no se usa.
  ///   3. Serie sola o inventario solo, SOLO si es único en ambos lados.
  /// Lo que queda sin pareja se toma como equipo nuevo (no se adivina).
  static List<int?> emparejar(
    List<Map<String, dynamic>> nuevos,
    List<Map<String, dynamic>> existentes,
  ) {
    final pareja = List<int?>.filled(nuevos.length, null);
    final usados = <int>{};

    // Serie o inventario reales distintos = equipos distintos, aunque
    // compartan otro dato (p. ej. un certificado que quedó cruzado).
    bool compatibles(Map<String, dynamic> a, Map<String, dynamic> b) {
      for (final c in const ['serie', 'inventario']) {
        final va = valorParaEmparejar(a, c);
        final vb = valorParaEmparejar(b, c);
        if (va.isNotEmpty && vb.isNotEmpty && va != vb) return false;
      }
      return true;
    }

    void pasada(List<String> campos, {required bool unico}) {
      final Map<String, List<int>> porClaveNuevos = {};
      final Map<String, List<int>> porClaveExist = {};
      for (int i = 0; i < nuevos.length; i++) {
        if (pareja[i] != null) continue;
        final k = _claveCampos(nuevos[i], campos);
        if (k != null) (porClaveNuevos[k] ??= []).add(i);
      }
      for (int j = 0; j < existentes.length; j++) {
        if (usados.contains(j)) continue;
        final k = _claveCampos(existentes[j], campos);
        if (k != null) (porClaveExist[k] ??= []).add(j);
      }
      porClaveNuevos.forEach((k, filas) {
        final cand = porClaveExist[k];
        if (cand == null) return;
        if (unico && (filas.length != 1 || cand.length != 1)) return;
        if (unico && !compatibles(nuevos[filas[0]], existentes[cand[0]])) {
          return;
        }
        // Con la combinación completa, los repetidos son indistinguibles
        // (mismo nombre, marca, modelo, serie, inventario y ubicación):
        // da igual cuál con cuál, se emparejan en orden.
        for (int n = 0; n < filas.length && n < cand.length; n++) {
          pareja[filas[n]] = cand[n];
          usados.add(cand[n]);
        }
      });
    }

    pasada(['certificado'], unico: true);
    const todos = [
      'nombre',
      'marca',
      'modelo',
      'serie',
      'inventario',
      'ubicacion',
    ];
    pasada(todos, unico: false);
    // Equipos sin serie ni inventario: misma descripción y ubicación, en
    // orden (son indistinguibles por sus datos).
    {
      final sinIdNuevos = [
        for (int i = 0; i < nuevos.length; i++)
          if (pareja[i] == null &&
              valorParaEmparejar(nuevos[i], 'serie').isEmpty &&
              valorParaEmparejar(nuevos[i], 'inventario').isEmpty)
            i
      ];
      final Map<String, List<int>> exist = {};
      for (int j = 0; j < existentes.length; j++) {
        if (usados.contains(j)) continue;
        if (valorParaEmparejar(existentes[j], 'serie').isNotEmpty ||
            valorParaEmparejar(existentes[j], 'inventario').isNotEmpty) {
          continue;
        }
        final k = _claveCampos(existentes[j], const ['nombre', 'ubicacion']);
        if (k == null) continue;
        final k2 = '$k\u0001${valorParaEmparejar(existentes[j], 'marca')}'
            '\u0001${valorParaEmparejar(existentes[j], 'modelo')}';
        (exist[k2] ??= []).add(j);
      }
      for (final i in sinIdNuevos) {
        final k = _claveCampos(nuevos[i], const ['nombre', 'ubicacion']);
        if (k == null) continue;
        final k2 = '$k\u0001${valorParaEmparejar(nuevos[i], 'marca')}'
            '\u0001${valorParaEmparejar(nuevos[i], 'modelo')}';
        final cand = exist[k2];
        if (cand == null || cand.isEmpty) continue;
        final j = cand.removeAt(0);
        pareja[i] = j;
        usados.add(j);
      }
    }
    pasada(['serie', 'inventario', 'nombre'], unico: false);
    pasada(['serie', 'inventario'], unico: false);
    pasada(['serie', 'nombre', 'ubicacion'], unico: true);
    pasada(['inventario', 'nombre', 'ubicacion'], unico: true);
    pasada(['serie', 'nombre'], unico: true);
    pasada(['inventario', 'nombre'], unico: true);
    pasada(['serie'], unico: true);
    pasada(['inventario'], unico: true);
    return pareja;
  }

  /// Aplica sobre los equipos de un Excel recién importado lo que la app
  /// ya sabía de ellos (id, clave_nube, certificado, fecha, observaciones,
  /// fuera de servicio, no pasa calibración — campos que el Excel no trae
  /// o que el técnico registró en la app) y fija `orden` y `clave_nube`.
  /// El emparejamiento está en [emparejar].
  ///
  /// `clave_nube` se hereda del existente emparejado: una fila insertada o
  /// borrada en el Excel ya no cambia el documento de nube de los demás
  /// equipos. Solo los equipos sin pareja reciben una clave nueva.
  ///
  /// Certificado: manda el del Excel. Si la fila no trae, se hereda el de
  /// la app SOLO si ese número no aparece en otra fila del Excel; si
  /// aparece, era un certificado cruzado y se marca `limpiar_certificado`
  /// para borrarlo también de la nube.
  static List<Map<String, dynamic>> fusionarConExistentes(
    List<Map<String, dynamic>> nuevos,
    List<Map<String, dynamic>> existentes,
  ) {
    const textosDeLaApp = [
      'observaciones',
      'fuera_de_servicio_por',
      'no_pasa_calibracion_detalle',
      'no_pasa_calibracion_por',
    ];

    final certsExcel = <String>{
      for (final e in nuevos)
        if (valorParaEmparejar(e, 'certificado').isNotEmpty)
          valorParaEmparejar(e, 'certificado'),
    };
    final pareja = emparejar(nuevos, existentes);

    final resultado = <Map<String, dynamic>>[];
    for (int i = 0; i < nuevos.length; i++) {
      final e = <String, dynamic>{...nuevos[i], 'orden': i};
      e.remove('limpiar_certificado');
      final previo = pareja[i] == null ? null : existentes[pareja[i]!];

      if (previo != null) {
        String v(String campo) => previo[campo]?.toString().trim() ?? '';
        if (v('id').isNotEmpty) e['id'] = v('id');
        // Documento que el equipo YA tiene en la nube (datos viejos sin
        // clave_nube: el que se calculaba con su contenido y orden de
        // entonces).
        e['clave_nube'] = InventarioSync.docId(previo);
        if ((e['certificado']?.toString().trim() ?? '').isEmpty &&
            v('certificado').isNotEmpty) {
          if (certsExcel.contains(valorParaEmparejar(previo, 'certificado'))) {
            e['certificado'] = '';
            e['fecha'] = '';
            e['limpiar_certificado'] = true;
          } else {
            e['certificado'] = v('certificado');
            if (v('fecha').isNotEmpty) e['fecha'] = v('fecha');
          }
        }
        for (final campo in textosDeLaApp) {
          if (v(campo).isNotEmpty) e[campo] = v(campo);
        }
        if (previo['fuera_de_servicio'] == true) e['fuera_de_servicio'] = true;
        if (previo['no_pasa_calibracion'] == true) {
          e['no_pasa_calibracion'] = true;
        }
      }

      if ((e['id']?.toString() ?? '').isEmpty) e['id'] = _generarId();
      if ((e['clave_nube']?.toString() ?? '').isEmpty) {
        e['clave_nube'] = InventarioSync.claveEquipo(e);
      }
      resultado.add(e);
    }
    return resultado;
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
    nuevo['clave_nube'] = InventarioSync.claveEquipo(nuevo);
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
      int index, Map<String, dynamic> actualizado,
      {Map<String, dynamic>? referencia}) async {
    final copia = List<Map<String, dynamic>>.from(equiposNotifier.value);
    // La lista puede reordenarse (cambio de otro técnico) mientras el
    // diálogo está abierto: se busca el equipo de nuevo al guardar.
    if (referencia != null) {
      final i = indexPorIdOCascada(copia, referencia);
      if (i != -1) index = i;
    }
    if (index < 0 || index >= copia.length) return;
    copia[index] = {...copia[index], ...actualizado};
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(InventarioSync.upsertEquipo(
        InventarioSync.slug(cliente), copia[index]));
    unawaited(propagarASolicitudes([copia[index]], subirANube: true));
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
    unawaited(InventarioSync.upsertEquipo(
        InventarioSync.slug(cliente), copia[index]));
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
      // Solo los datos que el formulario de la solicitud edita: el resto de
      // equipoFinal es la copia del equipo tomada al abrir la solicitud
      // (orden, id, fuera de servicio...) y pisaría cambios más nuevos.
      for (final campo in const [
        'nombre',
        'marca',
        'modelo',
        'serie',
        'ubicacion',
        'inventario',
        'no_pasa_calibracion',
        'no_pasa_calibracion_detalle',
        'no_pasa_calibracion_por',
      ])
        if (equipoFinal.containsKey(campo)) campo: equipoFinal[campo],
      'certificado': certificado,
      'fecha': fecha,
      'observaciones': observaciones,
      'nuevo': false,
    };
    equiposNotifier.value = copia;
    await _guardar();
    unawaited(InventarioSync.upsertEquipo(
        InventarioSync.slug(cliente), copia[index]));
    // Otras solicitudes del mismo equipo (p. ej. una enviada antes) quedan
    // con estos datos también.
    unawaited(propagarASolicitudes([copia[index]], subirANube: true));
    return true;
  }

  // =====================
  // DATOS DEL EQUIPO TRANSVERSALES (inventario ⇄ solicitudes)
  //
  // El equipo se edita en tres lugares: el diálogo del inventario, al
  // crear una solicitud y al modificar una solicitud. El inventario es la
  // copia vigente (la última edición, venga de donde venga, y la de otros
  // técnicos por la nube); cada solicitud guarda en su JSON una COPIA del
  // equipo que antes quedaba congelada el día que se guardó. Ahora:
  //   - al abrir una solicitud se toman los datos actuales del inventario
  //     ([equipoActual]);
  //   - cada cambio del equipo en el inventario (propio o remoto) se
  //     copia a las solicitudes de ese equipo ([propagarASolicitudes]).
  // =====================

  /// Datos del equipo que viven en el inventario y se reflejan en las
  /// solicitudes. El certificado y la fecha NO: cada solicitud tiene el
  /// suyo.
  static const List<String> camposDelEquipo = [
    'nombre',
    'marca',
    'modelo',
    'serie',
    'ubicacion',
    'inventario',
    'observaciones',
    'fuera_de_servicio',
    'fuera_de_servicio_por',
  ];

  /// Versión vigente en el inventario del equipo [referencia] (copia del
  /// equipo guardada en una solicitud), o null si su cliente no es el
  /// activo o el equipo no está.
  static Map<String, dynamic>? equipoActual(
    Map<String, dynamic> referencia, {
    required String nombreCliente,
  }) {
    if (cliente.isEmpty ||
        InventarioSync.slug(nombreCliente) != InventarioSync.slug(cliente)) {
      return null;
    }
    final lista = equiposNotifier.value;
    final i = indexPorIdOCascada(lista, referencia);
    return i == -1 ? null : Map<String, dynamic>.from(lista[i]);
  }

  /// [destino] con los [camposDelEquipo] de [fuente]. Devuelve si cambió.
  static bool copiarCamposDelEquipo(
      Map<String, dynamic> destino, Map<String, dynamic> fuente) {
    bool cambio = false;
    for (final campo in camposDelEquipo) {
      if (!fuente.containsKey(campo)) continue;
      final nuevo = fuente[campo];
      if ((destino[campo]?.toString() ?? '') != (nuevo?.toString() ?? '')) {
        destino[campo] = nuevo;
        cambio = true;
      }
    }
    return cambio;
  }

  static bool _mismaClave(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ca = a['clave_nube']?.toString() ?? '';
    final cb = b['clave_nube']?.toString() ?? '';
    if (ca.isNotEmpty && cb.isNotEmpty) return ca == cb;
    final ia = a['id']?.toString() ?? '';
    final ib = b['id']?.toString() ?? '';
    return ia.isNotEmpty && ia == ib;
  }

  static Future<void> _colaPropagar = Future.value();

  /// Copia los datos de [equipos] (ya actualizados en el inventario) a
  /// las solicitudes guardadas en este celular (pendientes y enviadas) de
  /// esos mismos equipos y regenera su certificado .xlsx. Con
  /// [subirANube] (solo el celular donde se hizo la edición) también
  /// actualiza el equipo de esas solicitudes en la nube, para que los
  /// demás técnicos las vean igual. Nunca lanza.
  static Future<void> propagarASolicitudes(
    List<Map<String, dynamic>> equipos, {
    required bool subirANube,
  }) {
    if (equipos.isEmpty || cliente.isEmpty) return Future.value();
    final clienteId = InventarioSync.slug(cliente);
    final copias = [for (final e in equipos) Map<String, dynamic>.from(e)];
    final tarea = _colaPropagar.then((_) async {
      try {
        final archivos = <File>[
          ...await SolicitudesStorage.listarPendientes(),
          ...(await SolicitudesStorage.enviadasDir())
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.json')),
        ];
        for (final f in archivos) {
          try {
            final Map<String, dynamic> data =
                jsonDecode(await f.readAsString());
            final nombreCli =
                (data['cliente'] as Map?)?['nombre']?.toString() ?? '';
            if (InventarioSync.slug(nombreCli) != clienteId) continue;
            final equipo =
                Map<String, dynamic>.from((data['equipo'] as Map?) ?? {});
            Map<String, dynamic>? fuente;
            for (final e in copias) {
              if (_mismaClave(e, equipo)) fuente = e;
            }
            if (fuente == null) continue;
            if (!copiarCamposDelEquipo(equipo, fuente)) continue;
            data['equipo'] = equipo;
            await f.writeAsString(
                const JsonEncoder.withIndent('  ').convert(data));
            try {
              await CertificadoExcel.generarDesdeSolicitud(f);
            } catch (e) {
              debugPrint('InventarioData.propagar: xlsx ${f.path}: $e');
            }
            if (subirANube) {
              unawaited(SolicitudesSync.actualizarEquipoEnNube(
                  clienteId, InventarioSync.docId(equipo), equipo));
            }
          } catch (e) {
            debugPrint('InventarioData.propagar: ${f.path}: $e');
          }
        }
      } catch (e) {
        debugPrint('InventarioData.propagarASolicitudes: $e');
      }
    });
    _colaPropagar = tarea;
    return tarea;
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
    String norm(dynamic v) =>
        TextUtils.quitarTildes(v.toString()).toLowerCase();
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
