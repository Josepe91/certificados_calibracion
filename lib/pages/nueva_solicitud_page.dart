import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../data/certificado_excel.dart';
import '../data/solicitudes_storage.dart';
import '../data/solicitudes_sync.dart';
import '../data/inventario_data.dart';
import '../data/inventario_sync.dart';
import '../data/plantillas_initializer.dart';
import '../data/emp_referencia.dart';
import '../data/tecnico_profile.dart';
import '../utils/text_utils.dart';
import '../utils/mayusculas_formatter.dart';

class NuevaSolicitudPage extends StatefulWidget {
  final File? archivoJson;
  // Equipo con el que arranca la solicitud, elegido desde Inventario. La
  // página ya no tiene su propio buscador de equipo (Inventario ya tiene
  // uno) — se entra siempre con el equipo decidido de antemano, salvo al
  // editar una solicitud existente (archivoJson).
  final Map<String, dynamic>? equipoInicial;

  const NuevaSolicitudPage({super.key, this.archivoJson, this.equipoInicial})
      : assert(archivoJson != null || equipoInicial != null,
            'NuevaSolicitudPage necesita archivoJson o equipoInicial');

  @override
  State<NuevaSolicitudPage> createState() => _NuevaSolicitudPageState();
}

class _NuevaSolicitudPageState extends State<NuevaSolicitudPage> {
  late final ValueNotifier<String> _certificadoNotifier = ValueNotifier('');
  late final ValueNotifier<String> _fechaNotifier = ValueNotifier('');
  final TextEditingController certificadoController = TextEditingController();
  final TextEditingController fechaController = TextEditingController();
  final TextEditingController nombreController = TextEditingController();
  final TextEditingController marcaController = TextEditingController();
  final TextEditingController modeloController = TextEditingController();
  final TextEditingController serieController = TextEditingController();
  final TextEditingController ubicacionController = TextEditingController();
  final TextEditingController inventarioController = TextEditingController();
  final TextEditingController observacionesController = TextEditingController();

  final ImagePicker _picker = ImagePicker();
  final List<File> fotos = [];
  Map<String, dynamic>? equipoSeleccionado;

  final List<String> plantillas = [];
  String? plantillaSeleccionada;
  bool cargando = true;
  String? rutaPlantillas;
  Map<String, dynamic>? configPlantilla;
  final Map<int, Map<int, TextEditingController>> medicionControllers = {};
  final Map<int, Map<int, TextEditingController>> medicionControllers2 = {};
  final Map<int, Map<int, FocusNode>> _medicionFocusNodes = {};
  final Map<int, Map<int, FocusNode>> _medicionFocusNodes2 = {};
  // Puntos de medición confirmados por el técnico como fuera del EMP
  // (Error Máximo Permitido) — clave "seccion-punto", valor = texto
  // legible de qué falló, para guardar en el equipo al final.
  final Map<String, String> _puntosFallidos = {};
  // true una vez que _cargarSolicitud/_seleccionarEquipo terminaron —
  // antes de eso, los valores que se están cargando desde una solicitud
  // guardada no deben disparar el diálogo de confirmación (ya se
  // confirmaron la vez que se guardaron), solo recalcular el estado en
  // silencio. Ver _revisarTolerancia.
  bool _cargaCompleta = false;
  // Sección de mediciones que se muestra ahora. Se avanza con "Siguiente
  // sección" SIN exigir que la sección actual tenga algún valor lleno —
  // hay puntos que a veces no aplican ese día y no deben bloquear seguir.
  int _seccionMedicionActual = 0;

  // Activa los errores inline solo después del primer intento de guardar.
  bool _intentoGuardar = false;
  // Nombre del ZIP de fotos de la solicitud que se está editando.
  String _fotosZipExistente = '';
  // Equipo que tenía la solicitud cuando se abrió para editar.
  // Se usa para detectar si el técnico cambió el equipo y limpiar
  // el certificado incorrecto del equipo anterior en el inventario.
  Map<String, dynamic>? _equipoOriginalDeSolicitud;

  @override
  void initState() {
    super.initState();
    // Diferir la inicialización al primer frame para que el contexto
    // (ScaffoldMessenger) esté disponible.
    WidgetsBinding.instance.addPostFrameCallback((_) => _inicializar());
  }

  @override
  void dispose() {
    certificadoController.dispose();
    fechaController.dispose();
    nombreController.dispose();
    marcaController.dispose();
    modeloController.dispose();
    serieController.dispose();
    ubicacionController.dispose();
    inventarioController.dispose();
    observacionesController.dispose();
    _certificadoNotifier.dispose();
    _fechaNotifier.dispose();
    _disposeMedicionControllers();
    super.dispose();
  }

  void _disposeMedicionControllers() {
    for (final sec in medicionControllers.values) {
      for (final c in sec.values) {
        c.dispose();
      }
    }
    for (final sec in medicionControllers2.values) {
      for (final c in sec.values) {
        c.dispose();
      }
    }
    for (final sec in _medicionFocusNodes.values) {
      for (final f in sec.values) {
        f.dispose();
      }
    }
    for (final sec in _medicionFocusNodes2.values) {
      for (final f in sec.values) {
        f.dispose();
      }
    }
    _medicionFocusNodes.clear();
    _medicionFocusNodes2.clear();
  }

  Future<void> _inicializar() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      rutaPlantillas = p.join(base.path, 'BTMC_PLANTILLAS');

      if (InventarioData.equipos.isEmpty) {
        await InventarioData.cargarDesdeJson();
      }

      await _cargarListaPlantillas();

      if (widget.archivoJson != null) {
        await _cargarSolicitud(widget.archivoJson!);
      } else {
        if (plantillas.isNotEmpty) {
          plantillaSeleccionada = plantillas.first;
          await _cargarConfigPlantilla(plantillas.first);
        }
        final hoy = DateTime.now();
        fechaController.text =
            '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-${hoy.day.toString().padLeft(2, '0')}';
        _fechaNotifier.value = fechaController.text;
        _seleccionarEquipo(widget.equipoInicial!);
      }
    } catch (e, st) {
      debugPrint('NuevaSolicitudPage._inicializar error: $e\n$st');
      if (mounted) {
        _mostrarError('Error al inicializar la página. Intenta de nuevo.');
      }
    }
    // A partir de acá, cualquier valor que cambie en un campo de medición
    // es una edición en vivo del técnico — recién ahí _revisarTolerancia
    // debe mostrar el diálogo de confirmación (los valores cargados arriba,
    // si vienen de una solicitud guardada, ya se confirmaron la vez que se
    // guardaron).
    _cargaCompleta = true;
    if (mounted) setState(() => cargando = false);
  }

  Future<void> _cargarListaPlantillas() async {
    if (PlantillasInitializer.plantillasCache.isNotEmpty) {
      if (mounted) {
        setState(() {
          plantillas
            ..clear()
            ..addAll(PlantillasInitializer.plantillasCache);
        });
      }
      return;
    }

    List<dynamic> lista = [];

    try {
      if (rutaPlantillas != null) {
        final indexFile = File(p.join(rutaPlantillas!, 'index.json'));
        if (await indexFile.exists()) {
          lista = jsonDecode(await indexFile.readAsString());
        }
      }
    } catch (e) {
      debugPrint('NuevaSolicitudPage: error leyendo index.json del disco: $e');
    }

    if (lista.isEmpty) {
      try {
        final indexStr =
            await rootBundle.loadString('assets/plantillas/index.json');
        lista = jsonDecode(indexStr);
      } catch (e) {
        debugPrint(
            'NuevaSolicitudPage: error leyendo index.json de assets: $e');
      }
    }

    if (lista.isNotEmpty) {
      PlantillasInitializer.plantillasCache =
          lista.map((e) => e.toString()).toList();
      if (mounted) {
        setState(() {
          plantillas
            ..clear()
            ..addAll(PlantillasInitializer.plantillasCache);
        });
      }
    }
  }

  Future<void> _cargarConfigPlantilla(String nombrePlantilla) async {
    try {
      if (rutaPlantillas == null) return;

      Map<String, dynamic>? config =
          PlantillasInitializer.configCache[nombrePlantilla];

      if (config == null) {
        final nombreConfig = nombrePlantilla.replaceAll('.xlsx', '.json');
        final configFile = File(p.join(rutaPlantillas!, nombreConfig));

        if (!await configFile.exists()) {
          if (mounted) setState(() => configPlantilla = null);
          return;
        }

        config = jsonDecode(await configFile.readAsString());
        PlantillasInitializer.configCache[nombrePlantilla] = config!;
      }

      _disposeMedicionControllers();
      medicionControllers.clear();
      medicionControllers2.clear();
      _seccionMedicionActual = 0;

      final secciones = config['secciones'] as List;
      for (int s = 0; s < secciones.length; s++) {
        medicionControllers[s] = {};
        medicionControllers2[s] = {};
        _medicionFocusNodes[s] = {};
        _medicionFocusNodes2[s] = {};
        final puntos = secciones[s]['puntos'] as List;
        for (int pt = 0; pt < puntos.length; pt++) {
          medicionControllers[s]![pt] = TextEditingController();
          final fn = FocusNode();
          fn.addListener(() {
            if (!fn.hasFocus) _revisarTolerancia(s, pt);
          });
          _medicionFocusNodes[s]![pt] = fn;

          if (puntos[pt]['celda_lectura_2'] != null) {
            medicionControllers2[s]![pt] = TextEditingController();
            final fn2 = FocusNode();
            fn2.addListener(() {
              if (!fn2.hasFocus) _revisarTolerancia(s, pt);
            });
            _medicionFocusNodes2[s]![pt] = fn2;
          }
        }
      }

      if (mounted) setState(() => configPlantilla = config);
    } catch (e) {
      debugPrint(
          'NuevaSolicitudPage: error cargando config de "$nombrePlantilla": $e');
    }
  }

  Future<void> _cargarSolicitud(File archivo) async {
    final contenido = await archivo.readAsString();
    final data = jsonDecode(contenido);

    final equipo = Map<String, dynamic>.from(data['equipo']);
    equipoSeleccionado = equipo;
    _equipoOriginalDeSolicitud = Map<String, dynamic>.from(equipo);

    nombreController.text = equipo['nombre'] ?? '';
    marcaController.text = equipo['marca'] ?? '';
    modeloController.text = equipo['modelo'] ?? '';
    serieController.text = equipo['serie'] ?? '';
    ubicacionController.text = equipo['ubicacion'] ?? '';
    inventarioController.text = equipo['inventario'] ?? '';
    observacionesController.text = equipo['observaciones'] ?? '';

    certificadoController.text = data['certificado'] ?? '';
    fechaController.text = data['fecha'] ?? '';
    _certificadoNotifier.value = certificadoController.text;
    _fechaNotifier.value = fechaController.text;
    _fotosZipExistente = data['fotos_zip']?.toString() ?? '';
    plantillaSeleccionada = data['plantilla'];

    if (_fotosZipExistente.isNotEmpty) {
      // El ZIP vive junto al JSON (pendientes/ o enviadas/, según de dónde
      // se abrió la solicitud) — se usa la carpeta real del archivo en vez
      // de asumir pendientesDir(), para que editar una solicitud ya enviada
      // también encuentre sus fotos.
      await _cargarFotosExistentes(archivo.parent, _fotosZipExistente);
    }

    if (plantillaSeleccionada != null) {
      await _cargarConfigPlantilla(plantillaSeleccionada!);
    }

    final mediciones = data['mediciones'];
    if (mediciones != null && configPlantilla != null) {
      final secciones = configPlantilla!['secciones'] as List;
      for (int s = 0; s < secciones.length; s++) {
        final titulo = secciones[s]['titulo'];
        final secMed = mediciones[titulo];
        if (secMed == null) continue;

        if (secMed is List) {
          for (int pt = 0; pt < secMed.length; pt++) {
            final entry = secMed[pt];
            medicionControllers[s]?[pt]?.text =
                entry['valor']?.toString() ?? '';
            if (entry['valor_2'] != null) {
              medicionControllers2[s]?[pt]?.text =
                  entry['valor_2']?.toString() ?? '';
            }
          }
        } else if (secMed is Map) {
          final puntos = secciones[s]['puntos'] as List;
          for (int pt = 0; pt < puntos.length; pt++) {
            final nominal = puntos[pt]['nominal'].toString();
            final entry = secMed[nominal];
            if (entry != null) {
              final valor = entry is Map ? entry['valor'] : entry;
              medicionControllers[s]?[pt]?.text = valor?.toString() ?? '';
              if (entry is Map && entry['valor_2'] != null) {
                medicionControllers2[s]?[pt]?.text =
                    entry['valor_2']?.toString() ?? '';
              }
            }
          }
        }
      }
    }

    // Recalcula en silencio (sin diálogo — _cargaCompleta sigue false acá)
    // qué puntos quedan fuera de EMP con los valores recién cargados, para
    // que el estado "no pasa calibración" del equipo no se pierda solo por
    // reabrir la solicitud a editarla sin tocar los campos que fallaron.
    if (configPlantilla != null) {
      final secciones = configPlantilla!['secciones'] as List;
      for (int s = 0; s < secciones.length; s++) {
        final puntos = secciones[s]['puntos'] as List;
        for (int pt = 0; pt < puntos.length; pt++) {
          await _revisarTolerancia(s, pt);
        }
      }
    }

    if (mounted) setState(() {});
  }

  // Compara la lectura de un punto contra su EMP (Error Máximo Permitido):
  // si hay dos lecturas (equipo + patrón), el error es la diferencia entre
  // ambas; si hay una sola, se compara contra el nominal directamente. El
  // EMP sale primero del propio punto (si la plantilla lo sobrescribe) y
  // si no, de la tabla compartida por variable (EmpReferencia).
  //
  // Con _cargaCompleta == false (cargando una solicitud guardada) no pide
  // confirmación — ya se confirmó la vez que se guardó, solo actualiza
  // _puntosFallidos en silencio. Con _cargaCompleta == true (el técnico
  // está escribiendo) sí muestra el diálogo antes de marcar nada.
  // Muestra un número sin ceros de relleno (1.300 -> 1.3, 10.0 -> 10) —
  // toStringAsFixed(3) siempre deja 3 decimales incluso cuando sobran.
  static String _fmtNum(double v) {
    String s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceFirst(RegExp(r'0+$'), '');
      s = s.replaceFirst(RegExp(r'\.$'), '');
    }
    return s;
  }

  Future<void> _revisarTolerancia(int seccionIdx, int puntoIdx) async {
    if (configPlantilla == null) return;
    final secciones = configPlantilla!['secciones'] as List;
    if (seccionIdx >= secciones.length) return;
    final seccion = secciones[seccionIdx];
    final puntos = seccion['puntos'] as List;
    if (puntoIdx >= puntos.length) return;
    final punto = puntos[puntoIdx] as Map<String, dynamic>;

    final nominalRaw = punto['nominal'];
    if (nominalRaw is! num) return;
    final nominal = nominalRaw;

    final unidad = seccion['unidad']?.toString() ?? '';
    final tituloSeccion = seccion['titulo']?.toString() ?? '';
    final key = '$seccionIdx-$puntoIdx';

    double? parse(String? texto) {
      if (texto == null || texto.trim().isEmpty) return null;
      return double.tryParse(texto.trim().replaceAll(',', '.'));
    }

    final equipoVal = parse(medicionControllers[seccionIdx]?[puntoIdx]?.text);
    final tieneDosLecturas = punto['celda_lectura_2'] != null;

    double? referencia;
    if (tieneDosLecturas) {
      referencia = parse(medicionControllers2[seccionIdx]?[puntoIdx]?.text);
    } else {
      referencia = nominal.toDouble();
    }

    if (equipoVal == null || referencia == null) {
      // Falta uno de los dos valores todavía — nada que comparar.
      if (_puntosFallidos.remove(key) != null && mounted) setState(() {});
      return;
    }

    double? empNullable;
    final empPropio = punto['emp'];
    if (empPropio is num) {
      empNullable = empPropio.toDouble();
    } else {
      empNullable = await EmpReferencia.buscar(tituloSeccion, unidad, nominal);
    }
    if (empNullable == null) return; // sin EMP definido todavía
    final emp = empNullable;

    final error = (equipoVal - referencia).abs();
    if (error <= emp) {
      if (_puntosFallidos.remove(key) != null && mounted) setState(() {});
      return;
    }

    final etiqueta = punto['etiqueta']?.toString();
    final nominalTxto = _fmtNum(nominal.toDouble());
    final descripcionPunto = (etiqueta != null && etiqueta.isNotEmpty)
        ? '$tituloSeccion — $etiqueta (nominal $nominalTxto $unidad)'
        : '$tituloSeccion — nominal $nominalTxto $unidad';
    final detalle = '$descripcionPunto: error ${_fmtNum(error)} $unidad '
        '(EMP ±${_fmtNum(emp)} $unidad)';

    if (!_cargaCompleta) {
      // Recalculando desde una solicitud ya guardada: no se vuelve a
      // preguntar, se confía en que ya se confirmó cuando se guardó.
      setState(() => _puntosFallidos[key] = detalle);
      return;
    }

    if (!mounted) return;
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Valor fuera de tolerancia'),
        content: Text(
          '$descripcionPunto\n\n'
          'Error medido: ${_fmtNum(error)} $unidad — '
          'supera el EMP de ±${_fmtNum(emp)} $unidad.\n\n'
          '¿El dato ingresado es correcto?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voy a revisarlo'),
          ),
          ElevatedButton(
            style:
                ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, es correcto'),
          ),
        ],
      ),
    );

    if (confirmar == true) {
      setState(() => _puntosFallidos[key] = detalle);
    } else {
      // "Voy a revisarlo": no se marca como fallido, y si ya lo estaba
      // (edición de un valor que antes se había confirmado) se limpia —
      // el técnico está indicando que va a corregirlo.
      if (_puntosFallidos.remove(key) != null && mounted) setState(() {});
    }
  }

  // Extrae las fotos del ZIP de una solicitud existente y las carga en
  // `fotos` como si el técnico las acabara de tomar — así se ven de
  // inmediato al abrir la solicitud, y agregar/quitar de ahí en adelante
  // usa exactamente el mismo camino (y el mismo _guardar) que fotos nuevas.
  Future<void> _cargarFotosExistentes(
      Directory dirSolicitud, String nombreZip) async {
    try {
      final zipFile = File(p.join(dirSolicitud.path, nombreZip));
      if (!await zipFile.exists()) return;

      final archivoZip = ZipDecoder().decodeBytes(await zipFile.readAsBytes());

      final tempDir = await getTemporaryDirectory();
      final carpetaFotos = Directory(p.join(
          tempDir.path, 'btmc_fotos_vista', p.basenameWithoutExtension(nombreZip)));
      await carpetaFotos.create(recursive: true);

      final extraidas = <File>[];
      for (final entry in archivoZip.files) {
        if (!entry.isFile) continue;
        final destino = File(p.join(carpetaFotos.path, p.basename(entry.name)));
        await destino.writeAsBytes(entry.content as List<int>);
        extraidas.add(destino);
      }

      if (mounted && extraidas.isNotEmpty) {
        setState(() {
          fotos
            ..clear()
            ..addAll(extraidas);
        });
      }
    } catch (e) {
      debugPrint('NuevaSolicitudPage: error extrayendo fotos existentes: $e');
    }
  }

  // Confirma antes de borrar — la "×" es chiquita y queda pegada a la foto,
  // así que un toque sin querer (muy fácil al revisar varias fotos seguidas)
  // ya no borra directo; siempre pide confirmar mostrando cuál foto es.
  Future<void> _confirmarEliminarFoto(int i) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Eliminar esta foto?'),
        content: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.file(fotos[i], height: 180, fit: BoxFit.cover),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (confirmar == true && mounted) {
      setState(() => fotos.removeAt(i));
    }
  }

  void _verFotoCompleta(File foto) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.black,
            iconTheme: const IconThemeData(color: Colors.white),
          ),
          body: Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 5,
              child: Image.file(foto),
            ),
          ),
        ),
      ),
    );
  }

  void _seleccionarEquipo(Map<String, dynamic> e) {
    if (e['fuera_de_servicio'] == true) {
      _mostrarError(
          'Este equipo está fuera de servicio y no requiere calibración');
      return;
    }
    final cert = e['certificado']?.toString().trim() ?? '';
    if (cert.isNotEmpty) {
      _mostrarError('Este equipo ya fue calibrado (Cert: $cert)');
      return;
    }
    setState(() {
      equipoSeleccionado = e;
      nombreController.text = e['nombre'] ?? '';
      marcaController.text = e['marca'] ?? '';
      modeloController.text = e['modelo'] ?? '';
      serieController.text = e['serie'] ?? '';
      ubicacionController.text = e['ubicacion'] ?? '';
      inventarioController.text = e['inventario'] ?? '';
    });
  }

  Future<void> _adjuntarFoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Tomar foto'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Elegir de galería'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final XFile? imagen =
        await _picker.pickImage(source: source, imageQuality: 85);
    if (imagen == null) return;
    setState(() => fotos.add(File(imagen.path)));
  }

  void _mostrarError(String mensaje) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(child: Text(mensaje)),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<bool> _validar() async {
    if (!_intentoGuardar) setState(() => _intentoGuardar = true);

    if (equipoSeleccionado == null) {
      _mostrarError('Selecciona un equipo antes de guardar');
      return false;
    }

    if (plantillaSeleccionada == null) {
      _mostrarError('Selecciona una plantilla de certificado');
      return false;
    }

    if (certificadoController.text.trim().isEmpty) {
      return false;
    }

    if (fechaController.text.trim().isEmpty) {
      return false;
    }

    // Requiere al menos una foto. Al editar, las fotos existentes ya están
    // cargadas en `fotos` (_cargarFotosExistentes), así que esto también
    // bloquea correctamente si el técnico las quitó todas sin agregar otras.
    if (fotos.isEmpty) {
      _mostrarError('Debes tomar al menos una foto');
      return false;
    }

    // Alerta si el número de certificado ya se usó en otra solicitud.
    final equipoDuplicado = await _buscarCertificadoDuplicado(
      certificadoController.text.trim(),
    );
    if (equipoDuplicado != null && mounted) {
      final continuar = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Número de certificado repetido'),
          content: Text(
            'El número "${certificadoController.text.trim()}" ya se usó '
            'en "$equipoDuplicado".\n\n¿Deseas continuar de todas formas?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Continuar'),
            ),
          ],
        ),
      );
      if (continuar != true) return false;
    }

    return true;
  }

  // Compara dos equipos usando la misma lógica de búsqueda en cascada
  // que usa el inventario (serie → inventario → nombre+ubicación).
  bool _mismoEquipo(Map<String, dynamic> a, Map<String, dynamic> b) {
    final idA = a['id']?.toString() ?? '';
    final idB = b['id']?.toString() ?? '';
    if (idA.isNotEmpty && idB.isNotEmpty) return idA == idB;

    // Datos sin id (inventario viejo aún no migrado): cascada por contenido.
    final serieA = a['serie']?.toString().trim() ?? '';
    final serieB = b['serie']?.toString().trim() ?? '';
    if (serieA.isNotEmpty && serieB.isNotEmpty) return serieA == serieB;
    final invA = a['inventario']?.toString().trim() ?? '';
    final invB = b['inventario']?.toString().trim() ?? '';
    if (invA.isNotEmpty && invB.isNotEmpty) return invA == invB;
    return a['nombre']?.toString().trim() == b['nombre']?.toString().trim() &&
        a['ubicacion']?.toString().trim() == b['ubicacion']?.toString().trim();
  }

  Future<String?> _buscarCertificadoDuplicado(String cert) async {
    if (cert.isEmpty) return null;
    final archivoActual = widget.archivoJson?.path;

    Future<String?> buscarEn(Directory dir) async {
      if (!await dir.exists()) {
        return null;
      }
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.toLowerCase().endsWith('.json')) {
          continue;
        }
        if (entity.path == archivoActual) {
          continue;
        }
        try {
          final data = jsonDecode(await entity.readAsString());
          if (data['certificado']?.toString().trim() == cert) {
            return data['equipo']?['nombre']?.toString() ?? 'un equipo';
          }
        } catch (_) {}
      }
      return null;
    }

    return await buscarEn(await SolicitudesStorage.pendientesDir()) ??
        await buscarEn(await SolicitudesStorage.enviadasDir());
  }

  Future<void> _guardarSolicitud() async {
    if (!await _validar()) return;

    // Nombre del técnico solo si hace falta firmar un "no pasa calibración"
    // (mismo criterio que fuera_de_servicio_por): quién guarda ahora mismo
    // queda como responsable de ese resultado.
    final tecnicoActual = _puntosFallidos.isNotEmpty
        ? await TecnicoProfile.obtenerNombre()
        : '';

    final equipoFinal = {
      ...equipoSeleccionado!,
      'nombre': nombreController.text,
      'marca': marcaController.text,
      'modelo': modeloController.text,
      'serie': serieController.text,
      'ubicacion': ubicacionController.text,
      'inventario': inventarioController.text,
      'observaciones': observacionesController.text,
      // Siempre se incluyen los 3 (incluso en false/vacío) para que
      // volver a guardar SIEMPRE refleje el resultado actual de esta
      // sesión — si antes no pasaba y ahora los valores ya están dentro
      // de tolerancia, esto debe limpiar la marca, no dejarla pegada.
      'no_pasa_calibracion': _puntosFallidos.isNotEmpty,
      'no_pasa_calibracion_detalle': _puntosFallidos.values.join(' | '),
      'no_pasa_calibracion_por':
          tecnicoActual.isNotEmpty ? tecnicoActual : null,
    };

    final certificado = TextUtils.normalizar(certificadoController.text);
    final nombreEquipo =
        TextUtils.normalizar(equipoFinal['nombre'] ?? 'equipo');

    // Desambiguador de nombre de archivo: el id del equipo es único de
    // verdad. Usar solo serie/certificado normalizados no alcanza —
    // TextUtils.normalizar() quita puntos, barras, etc., así que
    // certificados distintos como "AB.123" y "AB123" podían normalizar al
    // mismo texto y terminar sobrescribiéndose entre sí en disco. El id
    // (o, si el equipo es de un inventario viejo sin id, la serie) elimina
    // esa colisión sin dejar de ser legible.
    final idEquipo = (equipoFinal['id']?.toString() ?? '').isNotEmpty
        ? equipoFinal['id'].toString()
        : TextUtils.normalizar(
            equipoFinal['serie'] ?? equipoFinal['inventario'] ?? 'sin_serie');

    final baseNombre = '${certificado}_${nombreEquipo}_$idEquipo';
    final dir = await SolicitudesStorage.pendientesDir();

    // El nombre de archivo siempre se recalcula a partir del certificado y
    // equipo ACTUALES. Si se está editando una solicitud y el certificado o
    // el equipo cambiaron, el archivo original (con el nombre viejo) se
    // elimina al final para no dejar copias duplicadas/huérfanas en disco.
    final jsonFileAntiguo = widget.archivoJson;
    final jsonFile = File(p.join(dir.path, '$baseNombre.json'));

    final zipFile = File(p.join(dir.path, '${baseNombre}_fotos.zip'));
    final zipAntiguo = _fotosZipExistente.isNotEmpty
        ? File(p.join(dir.path, _fotosZipExistente))
        : null;

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Material(
                color: Colors.transparent,
                child: Text(
                  'Guardando solicitud...',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
    }

    try {
      // `fotos` siempre refleja el estado final querido por el técnico —
      // fotos preexistentes (extraídas por _cargarFotosExistentes), nuevas
      // agregadas, o algunas quitadas. `_validar()` ya garantizó que no
      // esté vacío. Se reconstruye el zip completo desde acá siempre, para
      // no perder fotos viejas cuando solo se agrega una nueva (bug real:
      // antes, agregar 1 foto nueva a una solicitud con 3 existentes
      // generaba un zip con solo esa 1, descartando las otras 3).
      final encoder = ZipFileEncoder();
      encoder.create(zipFile.path);
      for (final foto in fotos) {
        encoder.addFile(foto, p.basename(foto.path));
      }
      encoder.close();
      final fotosZipFinal = p.basename(zipFile.path);

      // El zip viejo (si el nombre cambió por certificado/equipo distinto)
      // queda reemplazado por el nuevo: se elimina para no dejarlo huérfano.
      if (zipAntiguo != null &&
          zipAntiguo.path != zipFile.path &&
          await zipAntiguo.exists()) {
        await zipAntiguo.delete();
      }

      final Map<String, dynamic> mediciones = {};
      if (configPlantilla != null) {
        final secciones = configPlantilla!['secciones'] as List;
        for (int s = 0; s < secciones.length; s++) {
          final titulo = secciones[s]['titulo'];
          final puntos = secciones[s]['puntos'] as List;
          final List<Map<String, dynamic>> puntosList = [];
          for (int pt = 0; pt < puntos.length; pt++) {
            final nominal = puntos[pt]['nominal'];
            final celda = puntos[pt]['celda_lectura'];
            final celda2 = puntos[pt]['celda_lectura_2'];
            final etiqueta = puntos[pt]['etiqueta'];
            final valor = medicionControllers[s]?[pt]?.text ?? '';
            final valor2 = medicionControllers2[s]?[pt]?.text ?? '';
            puntosList.add({
              'nominal': nominal,
              if (etiqueta != null) 'etiqueta': etiqueta,
              'valor': valor,
              'celda': celda,
              if (celda2 != null) 'valor_2': valor2,
              if (celda2 != null) 'celda_2': celda2,
            });
          }
          mediciones[titulo] = puntosList;
        }
      }

      final solicitud = {
        'plantilla': plantillaSeleccionada,
        'equipo': equipoFinal,
        'cliente': {
          'nombre': InventarioData.cliente,
          'nit': InventarioData.nit,
          'telefono': InventarioData.telefono,
          'direccion': InventarioData.direccion,
          'ciudad': InventarioData.ciudad,
        },
        'certificado': certificadoController.text,
        'fecha': fechaController.text,
        'mediciones': mediciones,
        'fotos_zip': fotosZipFinal,
        'creado_en': DateTime.now().toIso8601String(),
      };
      await jsonFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(solicitud),
      );

      // Si el nombre de archivo cambió (certificado/equipo distinto al de
      // la solicitud original), eliminar el JSON viejo para no dejar una
      // copia duplicada huérfana en pendientes/.
      if (jsonFileAntiguo != null &&
          jsonFileAntiguo.path != jsonFile.path &&
          await jsonFileAntiguo.exists()) {
        await jsonFileAntiguo.delete();
        final xlsxAntiguo =
            File(CertificadoExcel.rutaCertificado(jsonFileAntiguo.path));
        if (await xlsxAntiguo.exists()) await xlsxAntiguo.delete();
      }

      // Certificado en Excel: copia de la plantilla llena con esta
      // solicitud, junto al JSON. Si falla (plantilla faltante o dañada)
      // la solicitud ya quedó guardada igual — se avisa pero no se pierde
      // nada; al compartir desde Inicio se vuelve a intentar.
      File? certificadoXlsx;
      try {
        certificadoXlsx =
            await CertificadoExcel.generarDesdeSolicitud(jsonFile);
      } catch (e, st) {
        debugPrint('NuevaSolicitudPage: error generando certificado: $e\n$st');
      }

      // Si se editó un JSON existente y el equipo cambió, limpiar el
      // certificado del equipo anterior para que no quede mal asignado.
      if (widget.archivoJson != null &&
          _equipoOriginalDeSolicitud != null &&
          !_mismoEquipo(_equipoOriginalDeSolicitud!, equipoSeleccionado!)) {
        await InventarioData.limpiarCertificado(_equipoOriginalDeSolicitud!);
      }

      final inventarioActualizado = await InventarioData.actualizarEquipo(
        equipoOriginal: equipoSeleccionado!,
        equipoFinal: equipoFinal,
        certificado: certificadoController.text,
        fecha: fechaController.text,
        observaciones: observacionesController.text,
      );

      await SolicitudesStorage.refrescarContador();

      // Sube la solicitud (datos + fotos) a la nube para que cualquier
      // técnico la vea desde su propia app — sin esperar (unawaited) para
      // no bloquear el cierre de esta pantalla si la subida tarda o no hay
      // señal; el archivo local ya quedó guardado arriba, así que nunca se
      // pierde trabajo por esto.
      unawaited(SolicitudesSync.subirSolicitud(
        clienteId: InventarioSync.slug(InventarioData.cliente),
        equipo: equipoFinal,
        solicitud: solicitud,
        fotos: fotos,
      ));

      if (mounted) {
        Navigator.of(context).pop(); // cierra el diálogo "Guardando..."
        if (!inventarioActualizado) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.white),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Solicitud guardada, pero el equipo no fue encontrado en el inventario',
                    ),
                  ),
                ],
              ),
              backgroundColor: Colors.orange.shade700,
              duration: const Duration(seconds: 5),
            ),
          );
        } else {
          final xlsx = certificadoXlsx;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(xlsx != null
                        ? 'Solicitud guardada · certificado Excel generado'
                        : 'Solicitud guardada (sin certificado Excel)'),
                  ),
                ],
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 6),
              action: xlsx == null
                  ? null
                  : SnackBarAction(
                      label: 'COMPARTIR',
                      textColor: Colors.white,
                      onPressed: () =>
                          Share.shareXFiles([XFile(xlsx.path)]),
                    ),
            ),
          );
        }
        // Vuelve a la pantalla anterior (Inventario, o la lista de
        // solicitudes si se estaba editando una existente) — el equipo ya
        // quedó certificado, no hay razón para seguir en este formulario.
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('NuevaSolicitudPage._guardarSolicitud error: $e');
      if (mounted) {
        Navigator.of(context).pop();
        _mostrarError('Error al guardar la solicitud: $e');
      }
    }
  }

  Widget _buildMediciones() {
    if (configPlantilla == null) return const SizedBox();
    final secciones = configPlantilla!['secciones'] as List;
    if (secciones.isEmpty) return const SizedBox();

    final s = _seccionMedicionActual.clamp(0, secciones.length - 1);
    final seccion = secciones[s];
    final titulo = seccion['titulo'] as String;
    final unidad = seccion['unidad'] as String;
    final puntos = seccion['puntos'] as List;
    final info = seccion['info'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 30),
        Row(
          children: [
            const Text('MEDICIONES',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const Spacer(),
            if (secciones.length > 1)
              Text(
                'Sección ${s + 1} de ${secciones.length}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.blue.shade50,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.blue.shade200),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blue.shade800,
                ),
              ),
              if (info != null && info.toString().isNotEmpty)
                Text(
                  info.toString(),
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.blue.shade600,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        ...List.generate(puntos.length, (pt) {
          final nominal = puntos[pt]['nominal'];
          final etiqueta = puntos[pt]['etiqueta'];
          final tieneDosLecturas = puntos[pt]['celda_lectura_2'] != null;

          final labelBase = etiqueta != null && etiqueta.toString().isNotEmpty
              ? '$etiqueta — Ref: $nominal $unidad'
              : 'Nominal: $nominal $unidad';

          if (tieneDosLecturas) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    labelBase,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: medicionControllers[s]?[pt],
                          focusNode: _medicionFocusNodes[s]?[pt],
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Equipo ($unidad)',
                            border: const OutlineInputBorder(),
                            suffixText: unidad,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: medicionControllers2[s]?[pt],
                          focusNode: _medicionFocusNodes2[s]?[pt],
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'Patrón ($unidad)',
                            border: const OutlineInputBorder(),
                            suffixText: unidad,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(
              controller: medicionControllers[s]?[pt],
              focusNode: _medicionFocusNodes[s]?[pt],
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '$labelBase — Lectura ($unidad)',
                border: const OutlineInputBorder(),
                suffixText: unidad,
              ),
            ),
          );
        }),
        const SizedBox(height: 12),
        // Navegar entre secciones NUNCA se bloquea por falta de datos: hay
        // puntos que a veces no aplican ese día, y exigirlos frenaría al
        // técnico en medio del trabajo sin motivo real.
        if (secciones.length > 1)
          Row(
            children: [
              if (s > 0)
                TextButton.icon(
                  onPressed: () =>
                      setState(() => _seccionMedicionActual = s - 1),
                  icon: const Icon(Icons.chevron_left),
                  label: const Text('Anterior'),
                )
              else
                const SizedBox(),
              const Spacer(),
              if (s < secciones.length - 1)
                ElevatedButton.icon(
                  onPressed: () =>
                      setState(() => _seccionMedicionActual = s + 1),
                  icon: const Icon(Icons.chevron_right),
                  label: const Text('Siguiente sección'),
                ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (cargando) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    // Hay trabajo sin guardar apenas se selecciona un equipo (mediciones,
    // fotos, certificado que se perderían si se sale sin guardar).
    final hayCambiosSinGuardar = equipoSeleccionado != null;

    return PopScope(
      canPop: !hayCambiosSinGuardar,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final salir = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('¿Salir sin guardar?'),
            content: const Text(
              'Esta solicitud tiene datos sin guardar (equipo, mediciones '
              'o fotos). Si sales ahora se perderán.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Seguir editando'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Salir sin guardar',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        if (salir == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        appBar: AppBar(
          title: Text(widget.archivoJson != null
              ? 'Editar Solicitud'
              : 'Nueva Solicitud'),
        ),
        body: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Autocomplete<String>(
              initialValue: TextEditingValue(
                text: plantillaSeleccionada?.replaceAll('.xlsx', '') ?? '',
              ),
              optionsBuilder: (textEditingValue) {
                final query =
                    TextUtils.quitarTildes(textEditingValue.text).toLowerCase();
                final seleccionadaNombre = plantillaSeleccionada == null
                    ? null
                    : TextUtils.quitarTildes(
                            plantillaSeleccionada!.replaceAll('.xlsx', ''))
                        .toLowerCase();
                if (query.isEmpty || query == seleccionadaNombre) {
                  return plantillas;
                }
                return plantillas.where((p) => TextUtils.quitarTildes(
                        p.replaceAll('.xlsx', ''))
                    .toLowerCase()
                    .contains(query));
              },
              displayStringForOption: (p) => p.replaceAll('.xlsx', ''),
              fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
                // Al enfocar el campo se selecciona todo el texto para que
                // escribir directamente reemplace la plantilla actual, en
                // vez de tener que borrarla letra por letra.
                focusNode.addListener(() {
                  if (focusNode.hasFocus) {
                    controller.selection = TextSelection(
                      baseOffset: 0,
                      extentOffset: controller.text.length,
                    );
                  }
                });
                return ListenableBuilder(
                  listenable: controller,
                  builder: (_, __) => TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: InputDecoration(
                      labelText: 'Plantilla de certificado',
                      border: const OutlineInputBorder(),
                      suffixIcon: controller.text.isEmpty
                          ? const Icon(Icons.search)
                          : IconButton(
                              icon: const Icon(Icons.close),
                              tooltip: 'Limpiar',
                              onPressed: () {
                                controller.clear();
                                focusNode.requestFocus();
                              },
                            ),
                    ),
                  ),
                );
              },
              optionsViewBuilder: (context, onSelected, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: NotificationListener<ScrollNotification>(
                        onNotification: (_) => true,
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: options.length,
                          itemBuilder: (_, i) {
                            final option = options.elementAt(i);
                            final nombre = option.replaceAll('.xlsx', '');
                            return ListTile(
                              dense: true,
                              title: Text(nombre),
                              selected: option == plantillaSeleccionada,
                              selectedTileColor: Colors.blue.shade50,
                              onTap: () => onSelected(option),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
              onSelected: (v) async {
                setState(() => plantillaSeleccionada = v);
                await _cargarConfigPlantilla(v);
              },
            ),
            if (equipoSeleccionado == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Text(
                    'Este equipo no se puede certificar en este momento.\n'
                    'Vuelve a Inventario e intenta de nuevo.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey),
                  ),
                ),
              ),
            if (equipoSeleccionado != null) ...[
              const SizedBox(height: 20),
              const Text('DATOS DEL EQUIPO',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              _campo(nombreController, 'Nombre'),
              _campo(marcaController, 'Marca'),
              _campo(modeloController, 'Modelo'),
              _campo(serieController, 'Serie'),
              _campo(ubicacionController, 'Ubicación'),
              _campo(inventarioController, 'Inventario'),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: TextField(
                  controller: observacionesController,
                  maxLines: 3,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: MayusculasFormatter.lista,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Observaciones',
                    border: OutlineInputBorder(),
                    alignLabelWithHint: true,
                  ),
                ),
              ),
              const Divider(height: 30),
              const Text('DATOS DEL CLIENTE',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('Cliente: ${InventarioData.cliente}'),
              Text('NIT: ${InventarioData.nit}'),
              Text('Teléfono: ${InventarioData.telefono}'),
              Text('Dirección: ${InventarioData.direccion}'),
              Text('Ciudad: ${InventarioData.ciudad}'),
              const Divider(height: 30),
              // Campo certificado: error solo tras intento de guardar.
              ValueListenableBuilder<String>(
                valueListenable: _certificadoNotifier,
                builder: (_, val, __) => TextField(
                  controller: certificadoController,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: MayusculasFormatter.lista,
                  decoration: InputDecoration(
                    labelText: 'Certificado *',
                    border: const OutlineInputBorder(),
                    errorText: _intentoGuardar && val.trim().isEmpty
                        ? 'Obligatorio'
                        : null,
                  ),
                  onChanged: (v) => _certificadoNotifier.value = v,
                ),
              ),
              const SizedBox(height: 10),
              // Campo fecha: error solo tras intento de guardar.
              GestureDetector(
                onTap: () async {
                  final hoy = DateTime.now();
                  DateTime inicial = hoy;
                  if (fechaController.text.isNotEmpty) {
                    try {
                      inicial = DateTime.parse(fechaController.text.trim());
                    } catch (_) {}
                  }
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: inicial,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    locale: const Locale('es', 'CO'),
                    helpText: 'Seleccionar fecha',
                    cancelText: 'Cancelar',
                    confirmText: 'Confirmar',
                  );
                  if (picked != null) {
                    fechaController.text =
                        '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                    _fechaNotifier.value = fechaController.text;
                  }
                },
                child: AbsorbPointer(
                  child: ValueListenableBuilder<String>(
                    valueListenable: _fechaNotifier,
                    builder: (_, val, __) => TextField(
                      controller: fechaController,
                      readOnly: true,
                      decoration: InputDecoration(
                        labelText: 'Fecha *',
                        border: const OutlineInputBorder(),
                        suffixIcon: const Icon(Icons.calendar_today),
                        errorText: _intentoGuardar && val.trim().isEmpty
                            ? 'Obligatorio'
                            : null,
                      ),
                    ),
                  ),
                ),
              ),
              RepaintBoundary(child: _buildMediciones()),
              const Divider(height: 30),
              Row(
                children: [
                  const Text('FOTOS',
                      style:
                          TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: _adjuntarFoto,
                    icon: const Icon(Icons.add_a_photo, size: 18),
                    label: const Text('Adjuntar foto'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (fotos.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.photo_camera_outlined,
                          size: 40, color: Colors.grey.shade400),
                      const SizedBox(height: 6),
                      Text('Sin fotos',
                          style: TextStyle(color: Colors.grey.shade500)),
                    ],
                  ),
                )
              else
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: fotos.length,
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 6,
                    mainAxisSpacing: 6,
                  ),
                  itemBuilder: (_, i) {
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        GestureDetector(
                          onTap: () => _verFotoCompleta(fotos[i]),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(
                              fotos[i],
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                        Positioned(
                          top: 4,
                          right: 4,
                          child: GestureDetector(
                            onTap: () => _confirmarEliminarFoto(i),
                            child: Container(
                              decoration: const BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                              ),
                              padding: const EdgeInsets.all(4),
                              child: const Icon(Icons.close,
                                  color: Colors.white, size: 14),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _guardarSolicitud,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Guardar Solicitud',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _campo(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        textCapitalization: TextCapitalization.characters,
        inputFormatters: MayusculasFormatter.lista,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
            labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }
}
