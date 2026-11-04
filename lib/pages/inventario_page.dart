import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border;

import '../data/inventario_data.dart';
import '../utils/mayusculas_formatter.dart';
import 'nueva_solicitud_page.dart';
import '../data/inventario_sync.dart';
import '../data/auth_tecnico.dart';
import '../data/montajes_sync.dart';
import '../data/tecnico_profile.dart';
import 'buscar_cliente_nube_page.dart';
import '../utils/text_utils.dart';

// Columnas de datos del equipo en el Excel
const int _colNombre = 0;
const int _colMarca = 1;
const int _colModelo = 2;
const int _colSerie = 3;
const int _colUbicacion = 4;
const int _colInventario = 5;
const int _colCertificado = 6;
const int _colFecha = 7;

// Columnas de datos del cliente en el Excel (fila 1)
const int _colClienteNombre = 10;
const int _colClienteNit = 11;
const int _colClienteTelefono = 12;
const int _colClienteDireccion = 13;
const int _colClienteCiudad = 14;

/// ISO8601 -> dd/mm/aaaa (vacío si no se reconoce).
String fechaCorta(dynamic iso) {
  final d = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
  if (d == null) return '';
  String dos(int n) => n.toString().padLeft(2, '0');
  return '${dos(d.day)}/${dos(d.month)}/${d.year}';
}

class InventarioPage extends StatefulWidget {
  const InventarioPage({super.key});

  @override
  State<InventarioPage> createState() => _InventarioPageState();
}

class _InventarioPageState extends State<InventarioPage> {
  // Caché de TextUtils.agruparUbicaciones: solo depende del inventario, no
  // de la búsqueda/filtros — sin esto se recalculaba (agrupar + ordenar)
  // en CADA letra escrita en el buscador, aunque las ubicaciones no hayan
  // cambiado. `lista` es siempre la misma instancia mientras no cambien los
  // equipos (InventarioData.equipos == equiposNotifier.value), así que
  // comparar por identidad basta para saber si hay que recalcular.
  List<Map<String, dynamic>>? _gruposCacheLista;
  Map<String, ({String nombre, int cantidad})>? _gruposCache;
  List<String>? _ubicacionesCache;

  ({
    Map<String, ({String nombre, int cantidad})> grupos,
    List<String> ubicaciones
  }) _grupos(List<Map<String, dynamic>> lista) {
    if (!identical(lista, _gruposCacheLista)) {
      _gruposCacheLista = lista;
      final grupos = TextUtils.agruparUbicaciones(
          lista.map((e) => e['ubicacion']));
      _gruposCache = grupos;
      _ubicacionesCache = grupos.keys.toList()
        ..sort((a, b) => grupos[a]!.nombre.compareTo(grupos[b]!.nombre));
    }
    return (grupos: _gruposCache!, ubicaciones: _ubicacionesCache!);
  }

  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _busquedaNotifier = ValueNotifier('');
  final ValueNotifier<String?> _ubicacionFiltroNotifier = ValueNotifier(null);
  final ValueNotifier<String?> _estadoFiltroNotifier = ValueNotifier(null);
  // Sub-filtro de "Calibrados": null (todos) | 'por_montar' | 'montado'.
  final ValueNotifier<String?> _montajeFiltroNotifier = ValueNotifier(null);
  // Modo "marcar varios como montados" (solo admin): ids de nube elegidos,
  // o null si el modo está apagado.
  final ValueNotifier<Set<String>?> _seleccion = ValueNotifier(null);

  List<Map<String, dynamic>> _inventarios = [];
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      _busquedaNotifier.value = _searchController.text;
    });
    // Refrescar la lista de clientes cuando el inventario es limpiado o
    // reemplazado desde otra pantalla (por ejemplo, desde HomePage).
    InventarioData.versionNotifier.addListener(_onVersionChange);
    _cargarLista();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _busquedaNotifier.dispose();
    _ubicacionFiltroNotifier.dispose();
    _estadoFiltroNotifier.dispose();
    _montajeFiltroNotifier.dispose();
    _seleccion.dispose();
    InventarioData.versionNotifier.removeListener(_onVersionChange);
    super.dispose();
  }

  void _onVersionChange() => _cargarLista();

  Future<void> _cargarLista() async {
    await InventarioData.cargarDesdeJson();
    final lista = await InventarioData.listarInventarios();
    if (mounted) {
      setState(() {
        _inventarios = lista;
        _cargando = false;
      });
    }
  }

  Future<void> _seleccionarInventario(String nombreCliente) async {
    await InventarioData.cargarCliente(nombreCliente);
    if (!mounted) return;
    _ubicacionFiltroNotifier.value = null;
    _estadoFiltroNotifier.value = null;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Inventario de $nombreCliente activado'),
        duration: const Duration(seconds: 2),
        persist: false,
      ),
    );
  }

  // Punto de entrada único del botón "Cargar inventario": antes iba directo
  // al explorador de archivos sin ofrecer primero lo que ya está en la
  // nube (subido por cualquier técnico) — ahora pregunta cuál de las dos
  // opciones quiere el técnico.
  Future<void> _mostrarOpcionesCargarInventario() async {
    final opcion = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('Buscar cliente ya cargado en la nube'),
              subtitle: const Text(
                  'Lo subió otro técnico (o tú, desde otro celular)'),
              onTap: () => Navigator.pop(context, 'nube'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Importar Excel nuevo'),
              subtitle: const Text('Cliente que todavía no está en la nube'),
              onTap: () => Navigator.pop(context, 'excel'),
            ),
          ],
        ),
      ),
    );

    if (opcion == 'nube') {
      await _buscarClienteEnNube();
    } else if (opcion == 'excel') {
      await _cargarExcel();
    }
  }

  Future<void> _buscarClienteEnNube() async {
    final cargado = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const BuscarClienteNubePage()),
    );
    if (cargado == true) await _cargarLista();
  }

  Future<void> _cargarExcel() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['xlsx'],
      withData: true,
    );
    if (result == null) return;

    final nombreArchivo = result.files.single.name;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;

    Excel excel;
    try {
      excel = Excel.decodeBytes(bytes);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('El archivo no es un Excel válido'),
            duration: Duration(seconds: 2),
            persist: false,
          ),
        );
      }
      return;
    }
    if (excel.tables.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('El Excel no tiene hojas'),
            duration: Duration(seconds: 2),
            persist: false,
          ),
        );
      }
      return;
    }
    final sheet = excel.tables.values.first;

    // Validación ligera de encabezados: las columnas de datos del equipo
    // se leen por posición fija (0-7), así que un Excel con columnas
    // reordenadas se importaría en silencio asignando datos al campo
    // equivocado. Se compara el texto del encabezado (fila 0) contra lo
    // esperado y se avisa antes de continuar si no coincide.
    if (sheet.maxRows > 0) {
      const esperado = [
        'nombre',
        'marca',
        'modelo',
        'serie',
        'ubicacion',
        'inventario',
        'certificado',
        'fecha',
      ];
      final encabezado = sheet.row(0);
      final columnas = [
        _colNombre,
        _colMarca,
        _colModelo,
        _colSerie,
        _colUbicacion,
        _colInventario,
        _colCertificado,
        _colFecha,
      ];
      bool coincide = true;
      for (int i = 0; i < columnas.length; i++) {
        final col = columnas[i];
        final texto = col < encabezado.length
            ? TextUtils.quitarTildes(encabezado[col]?.value?.toString() ?? '')
                .toLowerCase()
            : '';
        if (!texto.contains(esperado[i])) {
          coincide = false;
          break;
        }
      }
      if (!coincide && mounted) {
        final continuar = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Encabezados no coinciden'),
            content: const Text(
              'Las columnas de este Excel no coinciden con el formato '
              'esperado (Nombre, Marca, Modelo, Serie, Ubicación, '
              'Inventario, Certificado, Fecha en ese orden).\n\n'
              'Si continúas, los datos podrían quedar asignados al campo '
              'equivocado. ¿Deseas continuar de todas formas?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar'),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Continuar de todas formas',
                    style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
        if (continuar != true) return;
      }
    }

    String nombreCliente = '';
    String nitCliente = '';
    String telefonoCliente = '';
    String direccionCliente = '';
    String ciudadCliente = '';

    if (sheet.maxRows > 1) {
      final row = sheet.row(1);
      nombreCliente = row[_colClienteNombre]?.value?.toString() ?? '';
      nitCliente = row[_colClienteNit]?.value?.toString() ?? '';
      telefonoCliente = row[_colClienteTelefono]?.value?.toString() ?? '';
      direccionCliente = row[_colClienteDireccion]?.value?.toString() ?? '';
      ciudadCliente = row[_colClienteCiudad]?.value?.toString() ?? '';
    }

    if (nombreCliente.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No se encontró nombre de cliente en el Excel'),
            duration: Duration(seconds: 2),
            persist: false,
          ),
        );
      }
      return;
    }

    final List<Map<String, dynamic>> equipos = [];
    for (int i = 1; i < sheet.maxRows; i++) {
      final row = sheet.row(i);
      if ((row[_colNombre]?.value ?? '').toString().isEmpty) continue;
      equipos.add({
        'nombre': row[_colNombre]?.value?.toString().trim() ?? '',
        'marca': row[_colMarca]?.value?.toString().trim() ?? '',
        'modelo': row[_colModelo]?.value?.toString().trim() ?? '',
        'serie': row[_colSerie]?.value?.toString().trim() ?? '',
        'ubicacion': row[_colUbicacion]?.value?.toString().trim() ?? '',
        'inventario': row[_colInventario]?.value?.toString().trim() ?? '',
        'certificado': row[_colCertificado]?.value?.toString().trim() ?? '',
        // Normalizada a yyyy-MM-dd (la celda puede ser fecha de Excel,
        // texto dd/mm/aaaa o serial); si no se reconoce se deja tal cual.
        'fecha': TextUtils.fechaIso(row[_colFecha]?.value?.toString()) ??
            row[_colFecha]?.value?.toString().trim() ??
            '',
        'nuevo': false,
      });
    }

    await InventarioData.guardarNuevoInventario(
      nombreArchivo: nombreArchivo,
      nombreCliente: nombreCliente,
      nitCliente: nitCliente,
      telefonoCliente: telefonoCliente,
      direccionCliente: direccionCliente,
      ciudadCliente: ciudadCliente,
      equipos: equipos,
    );

    await _cargarLista();

    if (mounted) {
      final calibrados = equipos
          .where((e) => (e['certificado']?.toString().trim() ?? '').isNotEmpty)
          .length;
      final mensaje = calibrados > 0
          ? 'Inventario de $nombreCliente cargado · ${equipos.length} equipos · $calibrados ya calibrados ✓'
          : 'Inventario de $nombreCliente cargado (${equipos.length} equipos)';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(mensaje),
          duration: const Duration(seconds: 2),
          persist: false,
        ),
      );
    }
  }

  Future<void> _eliminarInventario(String nombreCliente) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Confirmar'),
        content: Text('¿Eliminar el inventario de $nombreCliente?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirmar != true) return;
    await InventarioData.eliminarCliente(nombreCliente);
    await _cargarLista();
  }

  Future<void> _crearEquipo() async {
    if (InventarioData.clienteActivo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Primero selecciona o carga un inventario'),
          duration: Duration(seconds: 2),
          persist: false,
        ),
      );
      return;
    }
    final nuevo = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => const _CrearEditarEquipoDialog(),
    );
    if (nuevo != null) await InventarioData.agregarEquipo(nuevo);
  }

  Future<void> _eliminarEquipo(Map<String, dynamic> equipo, int index) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar equipo'),
        content: Text(
          '¿Eliminar "${equipo['nombre']}" del inventario?\n\nEsta acción no se puede deshacer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child:
                const Text('Eliminar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmar != true) return;
    await InventarioData.eliminarEquipo(index);
  }

  void _crearSolicitudPara(Map<String, dynamic> equipo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => NuevaSolicitudPage(equipoInicial: equipo),
      ),
    );
  }

  void _alternarSeleccion(String claveNube) {
    final actual = {...?_seleccion.value};
    if (!actual.remove(claveNube)) actual.add(claveNube);
    _seleccion.value = actual;
  }

  Future<void> _editarEquipo(Map<String, dynamic> equipo, int index) async {
    final actualizado = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CrearEditarEquipoDialog(
          equipo: equipo, montaje: MontajesSync.de(equipo)),
    );
    if (actualizado != null) {
      await InventarioData.actualizar(index, actualizado);
    }
  }

  Widget _estadoBadge(bool calibrado, {bool? montado}) {
    if (calibrado && montado != null) {
      final color = montado ? Colors.teal : Colors.amber.shade800;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (AuthTecnico.esAdmin) ...[
              Icon(montado ? Icons.verified : Icons.verified_outlined,
                  size: 11, color: color),
              const SizedBox(width: 3),
            ],
            Text(
              montado ? 'Montado' : 'Por montar',
              style: TextStyle(
                  fontSize: 10, fontWeight: FontWeight.w600, color: color),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: calibrado ? Colors.green.shade50 : Colors.orange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: calibrado ? Colors.green.shade300 : Colors.orange.shade300,
          width: 0.8,
        ),
      ),
      child: Text(
        calibrado ? 'Calibrado' : 'Pendiente',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: calibrado ? Colors.green.shade700 : Colors.orange.shade700,
        ),
      ),
    );
  }

  // Para el admin la etiqueta "Por montar"/"Montado" es el botón para
  // marcar/desmarcar (con su confirmación): no ocupa otro ícono en la
  // tarjeta que le quite ancho al nombre del equipo.
  Widget _badgeMontaje(
      Map<String, dynamic> e, bool calibrado, bool montado, bool habilitado) {
    final badge = _estadoBadge(calibrado, montado: montado);
    if (!calibrado || !AuthTecnico.esAdmin || !habilitado) return badge;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => montado ? _confirmarDesmontar(e) : _confirmarMontar([e]),
      child: Padding(padding: const EdgeInsets.all(4), child: badge),
    );
  }

  // Badge para equipos sin serie ni inventario.
  Widget _badgePorIdentificar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade400, width: 0.8),
      ),
      child: Text(
        'Por identificar',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.grey.shade600,
        ),
      ),
    );
  }

  Widget _badgeFueraDeServicio() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.red.shade300, width: 0.8),
      ),
      child: Text(
        'Fuera de servicio',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.red.shade700,
        ),
      ),
    );
  }

  Widget _badgeNoPasaCalibracion() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.deepOrange.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepOrange.shade300, width: 0.8),
      ),
      child: Text(
        'No pasa calibración',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Colors.deepOrange.shade700,
        ),
      ),
    );
  }

  Widget _chipCliente(Map<String, dynamic> inv) {
    final nombre = inv['nombre']?.toString() ?? '';
    final esActivo = nombre == InventarioData.cliente;
    final colorTexto = esActivo ? Colors.white : Colors.black87;
    final colorSecundario = esActivo ? Colors.white70 : Colors.grey.shade600;
    final ciudad = esActivo ? InventarioData.ciudad.trim() : '';
    final avance =
        '${inv['calibrados'] ?? 0}/${inv['total_equipos']} calibrados';

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Material(
        color: esActivo ? Colors.blue.shade700 : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(
            color: esActivo ? Colors.blue.shade700 : Colors.grey.shade300,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _seleccionarInventario(nombre),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 260),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.business,
                      size: 18,
                      color: esActivo ? Colors.white : Colors.blue.shade700),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          nombre,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                            color: colorTexto,
                          ),
                        ),
                        Text(
                          ciudad.isEmpty ? avance : '$avance · $ciudad',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              TextStyle(fontSize: 10.5, color: colorSecundario),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _eliminarInventario(nombre),
                    icon: const Icon(Icons.close),
                    iconSize: 16,
                    color: colorSecundario,
                    tooltip: 'Eliminar inventario',
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints:
                        const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get _clienteId => InventarioSync.slug(InventarioData.cliente);

  Widget _datosEquipo(Map<String, dynamic> e) {
    String t(String k) => e[k]?.toString().trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t('nombre'), style: const TextStyle(fontWeight: FontWeight.bold)),
        if (t('marca').isNotEmpty || t('modelo').isNotEmpty)
          Text('${t('marca')} · ${t('modelo')}'),
        Text('Serie: ${t('serie')} · Inv: ${t('inventario')}'),
        if (t('ubicacion').isNotEmpty) Text('Ubicación: ${t('ubicacion')}'),
        const SizedBox(height: 6),
        Text(
          'Certificado N.º ${t('certificado')}'
          '${t('fecha').isNotEmpty ? ' · ${t('fecha')}' : ''}',
          style: TextStyle(
              fontWeight: FontWeight.bold, color: Colors.green.shade800),
        ),
      ],
    );
  }

  // Marcar montado SIEMPRE pasa por esta confirmación con los datos del
  // equipo (o la lista, si son varios): evita marcar el equipo equivocado
  // por un toque accidental.
  Future<void> _confirmarMontar(List<Map<String, dynamic>> equipos) async {
    if (equipos.isEmpty) return;
    final uno = equipos.length == 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        icon: Icon(Icons.verified, color: Colors.teal.shade600, size: 36),
        title: Text(uno
            ? '¿Confirmas que el certificado ya está montado?'
            : '¿Marcar ${equipos.length} equipos como montados?'),
        content: SizedBox(
          width: double.maxFinite,
          child: uno
              ? _datosEquipo(equipos.first)
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final e in equipos)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.verified_outlined, size: 18),
                        title: Text(e['nombre']?.toString() ?? ''),
                        subtitle: Text(
                            'Cert ${e['certificado']} · Serie ${e['serie']}'),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            onPressed: () => Navigator.pop(context, true),
            child: Text(uno ? 'Sí, está montado' : 'Sí, marcar todos',
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await MontajesSync.marcar(_clienteId, equipos);
      _seleccion.value = null;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(uno
              ? 'Certificado marcado como montado'
              : '${equipos.length} certificados marcados como montados'),
          duration: const Duration(seconds: 2),
          persist: false,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No se pudo marcar: $e'),
          duration: const Duration(seconds: 2),
          persist: false,
        ));
      }
    }
  }

  Future<void> _confirmarDesmontar(Map<String, dynamic> equipo) async {
    final m = MontajesSync.de(equipo) ?? const {};
    final motivo = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setLocal) => AlertDialog(
          icon: Icon(Icons.remove_done, color: Colors.red.shade600, size: 36),
          title: const Text('¿Quitar la marca de certificado montado?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _datosEquipo(equipo),
                if ((m['montado_por']?.toString() ?? '').isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('Marcado por ${m['montado_por']} el '
                      '${fechaCorta(m['montado_en'])}'),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: motivo,
                  autofocus: true,
                  maxLines: 2,
                  onChanged: (_) => setLocal(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Motivo (obligatorio)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancelar')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: motivo.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: const Text('Quitar marca',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
    final texto = motivo.text.trim();
    if (ok != true) return;
    try {
      await MontajesSync.desmarcar(_clienteId, equipo, texto);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Marca de montado quitada'),
          duration: Duration(seconds: 2),
          persist: false,
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('No se pudo quitar: $e'),
          duration: const Duration(seconds: 2),
          persist: false,
        ));
      }
    }
  }

  Future<void> _menuCuenta(String opcion) async {
    if (opcion == 'varios') {
      if (InventarioData.clienteActivo == null) return;
      _estadoFiltroNotifier.value = 'calibrado';
      _montajeFiltroNotifier.value = 'por_montar';
      _seleccion.value = {};
    } else if (opcion == 'salir') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Cerrar sesión'),
          content: Text('¿Salir de la cuenta ${AuthTecnico.correo}?\n\n'
              'Necesitarás internet para volver a entrar.'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancelar')),
            ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Cerrar sesión')),
          ],
        ),
      );
      if (ok != true) return;
      await InventarioSync.detach();
      await AuthTecnico.cerrarSesion();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventarios'),
        actions: [
          ValueListenableBuilder<String>(
            valueListenable: InventarioSync.estadoNotifier,
            builder: (_, estado, __) => _SyncBadge(estado: estado),
          ),
          IconButton(
            icon: const Icon(Icons.upload_file),
            tooltip: 'Cargar inventario',
            onPressed: _mostrarOpcionesCargarInventario,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.account_circle_outlined),
            onSelected: _menuCuenta,
            itemBuilder: (_) => [
              PopupMenuItem(
                enabled: false,
                child: Text(
                    '${AuthTecnico.correo}${AuthTecnico.esAdmin ? ' (admin)' : ''}',
                    style: const TextStyle(fontSize: 12)),
              ),
              if (AuthTecnico.esAdmin)
                const PopupMenuItem(
                  value: 'varios',
                  child: ListTile(
                    leading: Icon(Icons.library_add_check_outlined),
                    title: Text('Marcar varios como montados'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              const PopupMenuItem(
                value: 'salir',
                child: ListTile(
                  leading: Icon(Icons.logout),
                  title: Text('Cerrar sesión'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Clientes en una sola franja de chips horizontales (antes:
                // título + tarjetas de 120 px + franja aparte con el cliente
                // activo, ~190 px de alto que se le quitaban a la lista de
                // equipos). El chip activo ya muestra nombre, avance y
                // ciudad, así que la franja aparte sobraba.
                if (_inventarios.isNotEmpty) ...[
                  SizedBox(
                    height: 58,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                      itemCount: _inventarios.length,
                      itemBuilder: (_, i) => _chipCliente(_inventarios[i]),
                    ),
                  ),
                  const Divider(height: 1),
                ],
                // El buscador y la ubicación van juntos en una sola fila
                // compacta, dentro del builder (ver abajo), para que la
                // píldora de ubicación muestre los conteos al día.
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      InventarioData.equiposNotifier,
                      _busquedaNotifier,
                      _ubicacionFiltroNotifier,
                      _estadoFiltroNotifier,
                      _montajeFiltroNotifier,
                      _seleccion,
                      MontajesSync.notifier,
                    ]),
                    builder: (_, __) {
                      final lista = InventarioData.equipos;
                      final q = TextUtils.quitarTildes(_busquedaNotifier.value)
                          .toLowerCase();
                      final ubicFiltro = _ubicacionFiltroNotifier.value;
                      final estadoFiltro = _estadoFiltroNotifier.value;
                      final montajeFiltro = _montajeFiltroNotifier.value;
                      final montajes = MontajesSync.notifier.value;
                      final seleccion = _seleccion.value;

                      // Ubicaciones equivalentes (espacios, tildes) se
                      // agrupan en una sola; el filtro guarda la CLAVE.
                      // Memoizado en _grupos: no depende de la búsqueda, no
                      // hay que recalcularlo en cada letra escrita.
                      final (:grupos, :ubicaciones) = _grupos(lista);
                      final ubicFiltroNombre = ubicFiltro == null
                          ? null
                          : (grupos[ubicFiltro]?.nombre ?? ubicFiltro);

                      String norm(dynamic v) =>
                          TextUtils.quitarTildes(v.toString()).toLowerCase();
                      bool esCalE(Map e) =>
                          (e['certificado']?.toString().trim() ?? '')
                              .isNotEmpty;
                      bool esBajaE(Map e) => e['fuera_de_servicio'] == true;

                      // Base = búsqueda + ubicación. Los conteos de los
                      // chips de estado salen de aquí (no de la lista ya
                      // filtrada por estado), así "Calibrados" no marca 0
                      // solo porque estás viendo "Pendientes".
                      final base = lista.where((e) {
                        final matchSearch = q.isEmpty ||
                            norm(e['serie']).contains(q) ||
                            norm(e['inventario']).contains(q) ||
                            norm(e['nombre']).contains(q);
                        final matchUbic = ubicFiltro == null ||
                            TextUtils.claveUbicacion(e['ubicacion']) ==
                                ubicFiltro;
                        return matchSearch && matchUbic;
                      }).toList();

                      final mostrar = base.where((e) {
                        final esCal = esCalE(e);
                        final esBaja = esBajaE(e);
                        final matchEstado = estadoFiltro == null ||
                            (estadoFiltro == 'calibrado' && esCal) ||
                            (estadoFiltro == 'pendiente' &&
                                !esCal &&
                                !esBaja) ||
                            (estadoFiltro == 'baja' && esBaja);
                        final montado = MontajesSync.estaMontado(e, montajes);
                        final matchMontaje = estadoFiltro != 'calibrado' ||
                            montajeFiltro == null ||
                            (montajeFiltro == 'montado' && montado) ||
                            (montajeFiltro == 'por_montar' && !montado);
                        return matchEstado && matchMontaje;
                      }).toList();

                      final calibrados = base.where(esCalE).length;
                      final fuera = base.where(esBajaE).length;
                      final pendientes = base
                          .where((e) => !esCalE(e) && !esBajaE(e))
                          .length;

                      // Índice real en la lista completa por docId (misma
                      // identidad estable que InventarioSync.docId/claveNube
                      // de abajo), una sola pasada por build. Antes cada
                      // tarjeta visible llamaba indexPorIdOCascada, que
                      // recorre TODO el inventario buscando coincidencia —
                      // con inventarios grandes eso se notaba al hacer
                      // scroll o escribir en el buscador (cada tecla
                      // reconstruye las tarjetas visibles).
                      final indicePorDocId = <String, int>{
                        for (var i = 0; i < lista.length; i++)
                          InventarioSync.docId(lista[i]): i,
                      };

                      return Column(
                        children: [
                          // Fila compacta: buscador + píldora de ubicación.
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                            child: Row(
                              children: [
                                Expanded(child: _campoBusqueda()),
                                if (ubicaciones.isNotEmpty) ...[
                                  const SizedBox(width: 8),
                                  _pildoraUbicacion(
                                    nombre: ubicFiltroNombre,
                                    cantidad: ubicFiltro == null
                                        ? lista.length
                                        : (grupos[ubicFiltro]?.cantidad ?? 0),
                                    onTap: () => _elegirUbicacion(
                                        grupos, ubicaciones, ubicFiltro),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          // Chips de estado con su conteo (reemplazan los
                          // botones segmentados, que se partían en el
                          // celular, y la franja de contadores aparte).
                          SizedBox(
                            height: 40,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              padding:
                                  const EdgeInsets.fromLTRB(12, 0, 12, 6),
                              children: [
                                _chipEstado(null, 'Todos', base.length,
                                    Colors.blueGrey, estadoFiltro),
                                _chipEstado('pendiente', 'Pendientes',
                                    pendientes, Colors.orange, estadoFiltro),
                                _chipEstado('calibrado', 'Calibrados',
                                    calibrados, Colors.green, estadoFiltro),
                                if (fuera > 0 || estadoFiltro == 'baja')
                                  _chipEstado('baja', 'Baja', fuera,
                                      Colors.red, estadoFiltro),
                              ],
                            ),
                          ),
                          if (estadoFiltro == 'calibrado')
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                              child: Row(
                                children: [
                                  for (final o in const [
                                    [null, 'Todos'],
                                    ['por_montar', 'Por montar'],
                                    ['montado', 'Montados'],
                                  ])
                                    Padding(
                                      padding: const EdgeInsets.only(right: 6),
                                      child: ChoiceChip(
                                        label: Text(o[1]!,
                                            style:
                                                const TextStyle(fontSize: 11)),
                                        visualDensity: VisualDensity.compact,
                                        selected: montajeFiltro == o[0],
                                        onSelected: (_) =>
                                            _montajeFiltroNotifier.value = o[0],
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          if (seleccion != null)
                            Container(
                              width: double.infinity,
                              color: Colors.teal.shade50,
                              padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      'Toca los equipos a marcar como montados '
                                      '(${seleccion.length} elegidos)',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.teal.shade800),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => _seleccion.value = null,
                                    child: const Text('Cancelar'),
                                  ),
                                ],
                              ),
                            ),
                          if (mostrar.isEmpty)
                            Expanded(
                              child: Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.inventory_2_outlined,
                                        size: 60, color: Colors.grey.shade300),
                                    const SizedBox(height: 12),
                                    Text(
                                      _inventarios.isEmpty
                                          ? 'Carga un inventario Excel\npresionando el botón ↑'
                                          : 'No hay equipos',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.grey.shade500),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Expanded(
                              child: ListView.builder(
                                itemCount: mostrar.length,
                                itemBuilder: (_, i) {
                                  final e = mostrar[i];
                                  final esCalibrado =
                                      (e['certificado']?.toString().trim() ??
                                              '')
                                          .isNotEmpty;
                                  final esNuevo = e['nuevo'] == true;
                                  final esBaja = e['fuera_de_servicio'] == true;
                                  final noPasaCalibracion =
                                      e['no_pasa_calibracion'] == true;
                                  final tieneSerie =
                                      e['serie']?.toString().isNotEmpty ??
                                          false;
                                  final tieneInv =
                                      e['inventario']?.toString().isNotEmpty ??
                                          false;
                                  final montaje =
                                      montajes[InventarioSync.docId(e)];
                                  final esMontado =
                                      MontajesSync.estaMontado(e, montajes);
                                  final claveNube = InventarioSync.docId(e);
                                  final seleccionable = seleccion != null &&
                                      esCalibrado &&
                                      !esMontado &&
                                      !esBaja;

                                  final index =
                                      indicePorDocId[claveNube] ?? -1;

                                  final Color avatarColor = esBaja
                                      ? Colors.grey.shade600
                                      : noPasaCalibracion
                                          ? Colors.deepOrange.shade700
                                          : esNuevo
                                              ? Colors.red
                                              : esCalibrado
                                                  ? Colors.green
                                                  : Colors.orange.shade700;

                                  // Texto secundario más chico y gris.
                                  TextStyle sub(Color c) =>
                                      TextStyle(fontSize: 11.5, color: c);
                                  String dato(dynamic v) {
                                    final s = v?.toString().trim() ?? '';
                                    return (s.isEmpty ||
                                            TextUtils.quitarTildes(s)
                                                    .toUpperCase() ==
                                                'NO REGISTRA')
                                        ? '—'
                                        : s;
                                  }

                                  // Tarjeta compacta: franja de color a la
                                  // izquierda con el estado, nombre en una
                                  // línea completa (sin la etiqueta
                                  // "Pendiente", que ya la dice el color) y
                                  // "Eliminar" dentro del menú ⋮ para no
                                  // quitarle ancho al nombre.
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 3),
                                    elevation: 0.6,
                                    clipBehavior: Clip.antiAlias,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      side: BorderSide(
                                          color: Colors.grey.shade200),
                                    ),
                                    child: InkWell(
                                      onTap: seleccion != null
                                          ? (seleccionable
                                              ? () =>
                                                  _alternarSeleccion(claveNube)
                                              : null)
                                          : index != -1
                                              ? () => _editarEquipo(e, index)
                                              : null,
                                      child: Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            left: BorderSide(
                                                color: avatarColor, width: 4),
                                          ),
                                        ),
                                        padding: const EdgeInsets.fromLTRB(
                                            10, 8, 2, 8),
                                        child: Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (seleccion != null)
                                              SizedBox(
                                                width: 32,
                                                height: 32,
                                                child: Checkbox(
                                                  value: seleccion
                                                      .contains(claveNube),
                                                  onChanged: seleccionable
                                                      ? (_) =>
                                                          _alternarSeleccion(
                                                              claveNube)
                                                      : null,
                                                ),
                                              )
                                            else
                                              CircleAvatar(
                                                radius: 15,
                                                backgroundColor: avatarColor
                                                    .withValues(alpha: 0.12),
                                                child: Icon(
                                                  esBaja
                                                      ? Icons.block_outlined
                                                      : noPasaCalibracion
                                                          ? Icons
                                                              .report_problem
                                                          : esCalibrado
                                                              ? Icons.check
                                                              : Icons
                                                                  .pending_outlined,
                                                  color: avatarColor,
                                                  size: 17,
                                                ),
                                              ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    e['nombre']?.toString() ??
                                                        '',
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 14.5,
                                                      height: 1.2,
                                                      color: esNuevo
                                                          ? Colors.red
                                                          : Colors.black87,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  if (!tieneSerie && !tieneInv)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets
                                                              .only(top: 2),
                                                      child:
                                                          _badgePorIdentificar(),
                                                    )
                                                  else
                                                    Text(
                                                      'Serie: ${dato(e['serie'])}  ·  Inv: ${dato(e['inventario'])}',
                                                      maxLines: 1,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                      style: sub(Colors
                                                          .grey.shade700),
                                                    ),
                                                  // La ubicación solo se
                                                  // muestra si no estás ya
                                                  // filtrando por una.
                                                  if (ubicFiltro == null &&
                                                      (e['ubicacion']
                                                              ?.toString()
                                                              .isNotEmpty ??
                                                          false))
                                                    Row(
                                                      children: [
                                                        Icon(
                                                            Icons
                                                                .location_on_outlined,
                                                            size: 12,
                                                            color: Colors.grey
                                                                .shade500),
                                                        const SizedBox(
                                                            width: 2),
                                                        Flexible(
                                                          child: Text(
                                                            e['ubicacion']
                                                                .toString(),
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis,
                                                            style: sub(Colors
                                                                .grey
                                                                .shade600),
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  if (esBaja ||
                                                      noPasaCalibracion ||
                                                      esCalibrado)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets
                                                              .only(top: 4),
                                                      child: esBaja
                                                          ? _badgeFueraDeServicio()
                                                          : noPasaCalibracion
                                                              ? _badgeNoPasaCalibracion()
                                                              : _badgeMontaje(
                                                                  e,
                                                                  esCalibrado,
                                                                  esMontado,
                                                                  seleccion ==
                                                                      null),
                                                    ),
                                                  if (esCalibrado &&
                                                      (e['fecha']
                                                              ?.toString()
                                                              .isNotEmpty ??
                                                          false))
                                                    Text(
                                                      'Cert: ${e['certificado']} · ${e['fecha']}',
                                                      style: sub(Colors
                                                          .green.shade700),
                                                    ),
                                                  if (esMontado)
                                                    Text(
                                                      'Montado por ${montaje?['montado_por'] ?? ''}'
                                                      '${fechaCorta(montaje?['montado_en']).isNotEmpty ? ' · ${fechaCorta(montaje?['montado_en'])}' : ''}',
                                                      style: sub(Colors
                                                          .teal.shade700),
                                                    ),
                                                  if ((e['observaciones']
                                                          ?.toString()
                                                          .isNotEmpty ??
                                                      false))
                                                    Text(
                                                      'Obs: ${e['observaciones']}',
                                                      style: sub(Colors
                                                          .grey.shade700),
                                                      maxLines: 2,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                    ),
                                                  if (esBaja &&
                                                      (e['fuera_de_servicio_por']
                                                              ?.toString()
                                                              .isNotEmpty ??
                                                          false))
                                                    Text(
                                                      'Marcado por: ${e['fuera_de_servicio_por']}',
                                                      style: sub(Colors
                                                          .red.shade400),
                                                    ),
                                                  if (noPasaCalibracion)
                                                    Text(
                                                      (e['no_pasa_calibracion_detalle']
                                                                  ?.toString()
                                                                  .isNotEmpty ??
                                                              false)
                                                          ? 'No pasa: ${e['no_pasa_calibracion_detalle']}'
                                                          : 'No pasa calibración',
                                                      style: sub(Colors
                                                          .deepOrange
                                                          .shade700),
                                                      maxLines: 2,
                                                      overflow: TextOverflow
                                                          .ellipsis,
                                                    ),
                                                  if (noPasaCalibracion &&
                                                      (e['no_pasa_calibracion_por']
                                                              ?.toString()
                                                              .isNotEmpty ??
                                                          false))
                                                    Text(
                                                      'Confirmado por: ${e['no_pasa_calibracion_por']}',
                                                      style: sub(Colors
                                                          .deepOrange
                                                          .shade400),
                                                    ),
                                                ],
                                              ),
                                            ),
                                            if (index != -1 &&
                                                seleccion == null) ...[
                                              if (!esCalibrado && !esBaja)
                                                IconButton(
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                  icon: Icon(Icons.add_task,
                                                      color: Colors
                                                          .blue.shade600),
                                                  tooltip: 'Crear solicitud',
                                                  onPressed: () =>
                                                      _crearSolicitudPara(e),
                                                ),
                                              PopupMenuButton<String>(
                                                tooltip: 'Más opciones',
                                                icon: Icon(Icons.more_vert,
                                                    size: 20,
                                                    color:
                                                        Colors.grey.shade600),
                                                padding: EdgeInsets.zero,
                                                onSelected: (op) {
                                                  if (op == 'editar') {
                                                    _editarEquipo(e, index);
                                                  } else if (op ==
                                                      'eliminar') {
                                                    _eliminarEquipo(e, index);
                                                  }
                                                },
                                                itemBuilder: (_) => [
                                                  const PopupMenuItem(
                                                    value: 'editar',
                                                    child: ListTile(
                                                      dense: true,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                      leading: Icon(
                                                          Icons.edit_outlined),
                                                      title: Text('Editar'),
                                                    ),
                                                  ),
                                                  PopupMenuItem(
                                                    value: 'eliminar',
                                                    child: ListTile(
                                                      dense: true,
                                                      contentPadding:
                                                          EdgeInsets.zero,
                                                      leading: Icon(
                                                          Icons.delete_outline,
                                                          color: Colors
                                                              .red.shade400),
                                                      title: Text('Eliminar',
                                                          style: TextStyle(
                                                              color: Colors.red
                                                                  .shade400)),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
      floatingActionButton: ValueListenableBuilder<Set<String>?>(
        valueListenable: _seleccion,
        builder: (_, sel, __) => sel == null
            ? FloatingActionButton(
                onPressed: _crearEquipo,
                child: const Icon(Icons.add),
              )
            : FloatingActionButton.extended(
                backgroundColor:
                    sel.isEmpty ? Colors.grey : Colors.teal.shade600,
                foregroundColor: Colors.white,
                onPressed: sel.isEmpty
                    ? null
                    : () => _confirmarMontar(InventarioData.equipos
                        .where((e) => sel.contains(InventarioSync.docId(e)))
                        .toList()),
                icon: const Icon(Icons.verified),
                label: Text('Marcar ${sel.length} montados'),
              ),
      ),
    );
  }

  // ---- Barra de filtros compacta ----

  Widget _campoBusqueda() {
    return SizedBox(
      height: 44,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _searchController,
        builder: (_, v, __) => TextField(
          controller: _searchController,
          style: const TextStyle(fontSize: 14),
          textAlignVertical: TextAlignVertical.center,
          decoration: InputDecoration(
            hintText: 'Buscar equipo, serie o inv.',
            hintStyle: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            prefixIcon: Icon(Icons.search, size: 20, color: Colors.grey.shade600),
            prefixIconConstraints: const BoxConstraints(minWidth: 38),
            suffixIcon: v.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: 'Borrar búsqueda',
                    onPressed: () => _searchController.clear(),
                  ),
            isDense: true,
            filled: true,
            fillColor: Colors.grey.shade100,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: Colors.blue.shade300),
            ),
          ),
        ),
      ),
    );
  }

  /// Píldora con la ubicación activa. Azul lleno cuando hay un servicio
  /// elegido; azul suave cuando se ven todos.
  Widget _pildoraUbicacion({
    required String? nombre,
    required int cantidad,
    required VoidCallback onTap,
  }) {
    final activa = nombre != null;
    final fondo = activa ? Colors.blue.shade700 : Colors.blue.shade50;
    final texto = activa ? Colors.white : Colors.blue.shade800;
    return ConstrainedBox(
      constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.46),
      child: Material(
        color: fondo,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Container(
            height: 44,
            padding: const EdgeInsets.only(left: 10, right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.location_on, size: 18, color: texto),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    nombre ?? 'Todas',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: texto),
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: activa
                        ? Colors.white.withValues(alpha: 0.22)
                        : Colors.blue.shade100,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text('$cantidad',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: texto)),
                ),
                Icon(Icons.arrow_drop_down, size: 20, color: texto),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chipEstado(String? valor, String etiqueta, int cantidad,
      MaterialColor color, String? actual) {
    final sel = actual == valor;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        showCheckmark: false,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        shape: StadiumBorder(
            side: BorderSide(
                color: sel ? color.shade400 : Colors.grey.shade300)),
        backgroundColor: Colors.white,
        selectedColor: color.shade50,
        selected: sel,
        onSelected: (_) {
          _estadoFiltroNotifier.value = valor;
          if (valor != 'calibrado') _montajeFiltroNotifier.value = null;
        },
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(etiqueta,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    color: sel ? color.shade800 : Colors.grey.shade800)),
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: sel ? color.shade600 : color.shade50,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text('$cantidad',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: sel ? Colors.white : color.shade800)),
            ),
          ],
        ),
      ),
    );
  }

  /// Hoja inferior para elegir el servicio: buscador + lista con el avance
  /// de calibración de cada ubicación.
  Future<void> _elegirUbicacion(
    Map<String, ({String nombre, int cantidad})> grupos,
    List<String> ubicaciones,
    String? actual,
  ) async {
    final calPorClave = <String, int>{};
    var calTotal = 0;
    for (final e in InventarioData.equipos) {
      if ((e['certificado']?.toString().trim() ?? '').isEmpty) continue;
      calTotal++;
      final k = TextUtils.claveUbicacion(e['ubicacion']);
      calPorClave[k] = (calPorClave[k] ?? 0) + 1;
    }
    final total = InventarioData.equipos.length;
    var filtro = '';

    final elegido = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final f = TextUtils.quitarTildes(filtro).toLowerCase();
          final visibles = ubicaciones
              .where((u) => TextUtils.quitarTildes(grupos[u]!.nombre)
                  .toLowerCase()
                  .contains(f))
              .toList();

          Widget fila(String clave, String nombre, int cant, int cal,
              {bool todas = false}) {
            final sel = todas ? actual == null : actual == clave;
            final avance = cant == 0 ? 0.0 : cal / cant;
            return ListTile(
              dense: true,
              selected: sel,
              selectedTileColor: Colors.blue.shade50,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              leading: CircleAvatar(
                radius: 17,
                backgroundColor:
                    sel ? Colors.blue.shade700 : Colors.blue.shade50,
                child: Icon(todas ? Icons.apps : Icons.location_on,
                    size: 18,
                    color: sel ? Colors.white : Colors.blue.shade700),
              ),
              title: Text(nombre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: avance,
                          minHeight: 5,
                          backgroundColor: Colors.grey.shade200,
                          color: avance >= 1
                              ? Colors.green
                              : Colors.green.shade400,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$cal/$cant',
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade700)),
                  ],
                ),
              ),
              trailing: sel
                  ? Icon(Icons.check_circle, color: Colors.blue.shade700)
                  : null,
              onTap: () => Navigator.pop(ctx, clave),
            );
          }

          return SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.72,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      const Text('Ubicación / servicio',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const Spacer(),
                      Text('${ubicaciones.length} servicios',
                          style: TextStyle(
                              fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: TextField(
                    onChanged: (v) => setSheet(() => filtro = v),
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: 'Buscar servicio',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.grey.shade100,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    children: [
                      if (f.isEmpty)
                        fila('', 'Todas las ubicaciones', total, calTotal,
                            todas: true),
                      for (final u in visibles)
                        fila(u, grupos[u]!.nombre, grupos[u]!.cantidad,
                            calPorClave[u] ?? 0),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
    if (elegido == null) return; // cerró sin elegir
    _ubicacionFiltroNotifier.value = elegido.isEmpty ? null : elegido;
  }
}

/// Indicador chiquito en el AppBar del estado de sincronización con la
/// nube, para que el técnico sepa si su trabajo ya quedó compartido con el
/// resto del equipo o si está pendiente por falta de señal.
class _SyncBadge extends StatelessWidget {
  final String estado;
  const _SyncBadge({required this.estado});

  @override
  Widget build(BuildContext context) {
    IconData icon;
    Color color;
    String tooltip;
    switch (estado) {
      case 'sincronizado':
        icon = Icons.cloud_done_outlined;
        color = Colors.green;
        tooltip = 'Inventario sincronizado con la nube';
        break;
      case 'sincronizando':
        icon = Icons.cloud_sync_outlined;
        color = Colors.blue;
        tooltip = 'Sincronizando...';
        break;
      case 'sin_conexion':
        icon = Icons.cloud_off_outlined;
        color = Colors.orange;
        tooltip =
            'Sin conexión: los cambios se guardan y se subirán solos al volver el internet';
        break;
      case 'error':
        icon = Icons.cloud_off_outlined;
        color = Colors.red;
        tooltip = 'Error de sincronización';
        break;
      default:
        icon = Icons.cloud_outlined;
        color = Colors.grey;
        tooltip = 'Sync inactivo';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip,
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}

class _CrearEditarEquipoDialog extends StatefulWidget {
  final Map<String, dynamic>? equipo;
  // Solo lectura: la marca de montado se cambia desde la lista (admin).
  final Map<String, dynamic>? montaje;
  const _CrearEditarEquipoDialog({this.equipo, this.montaje});

  @override
  State<_CrearEditarEquipoDialog> createState() =>
      _CrearEditarEquipoDialogState();
}

class _CrearEditarEquipoDialogState extends State<_CrearEditarEquipoDialog> {
  late TextEditingController nombre,
      marca,
      modelo,
      serie,
      ubicacion,
      inventario,
      observaciones;
  final FocusNode _ubicacionFocus = FocusNode();
  // Ubicaciones que ya existen en el inventario, agrupadas por equivalencia
  // (ver TextUtils.claveUbicacion) — para sugerirlas al escribir y para
  // guardar con la misma escritura en vez de crear una ubicación "nueva".
  late final Map<String, ({String nombre, int cantidad})> _ubicaciones =
      TextUtils.agruparUbicaciones(
          InventarioData.equipos.map((e) => e['ubicacion']));
  bool _fueraDeServicio = false;
  late final bool _fueraDeServicioInicial;
  String? _fueraDeServicioPor;
  String _tecnicoActual = '';

  @override
  void initState() {
    super.initState();
    nombre = TextEditingController(text: widget.equipo?['nombre']);
    marca = TextEditingController(text: widget.equipo?['marca']);
    modelo = TextEditingController(text: widget.equipo?['modelo']);
    serie = TextEditingController(text: widget.equipo?['serie']);
    ubicacion = TextEditingController(text: widget.equipo?['ubicacion']);
    inventario = TextEditingController(text: widget.equipo?['inventario']);
    observaciones =
        TextEditingController(text: widget.equipo?['observaciones']);
    _fueraDeServicio = widget.equipo?['fuera_de_servicio'] == true;
    _fueraDeServicioInicial = _fueraDeServicio;
    _fueraDeServicioPor = widget.equipo?['fuera_de_servicio_por']?.toString();
    // El nombre del técnico de este dispositivo ya existe (se pide una vez
    // al abrir la app, ver TecnicoProfile) — se reusa como autor automático
    // de la baja, en vez de pedirlo a mano y arriesgar que quede mal escrito
    // o atribuido al técnico equivocado.
    TecnicoProfile.obtenerNombre().then((n) {
      if (mounted) setState(() => _tecnicoActual = n);
    });
  }

  // Más reciente primero.
  List<Map> get _historialMontaje =>
      ((widget.montaje?['historial'] as List?) ?? const [])
          .whereType<Map>()
          .toList()
          .reversed
          .toList();

  @override
  void dispose() {
    nombre.dispose();
    marca.dispose();
    modelo.dispose();
    serie.dispose();
    ubicacion.dispose();
    _ubicacionFocus.dispose();
    inventario.dispose();
    observaciones.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.equipo == null ? 'Nuevo equipo' : 'Editar equipo'),
      content: SingleChildScrollView(
        child: Column(children: [
          _buildField(nombre, 'Nombre *'),
          _buildField(marca, 'Marca'),
          _buildField(modelo, 'Modelo'),
          _buildField(serie, 'Serie'),
          _buildUbicacionField(),
          _buildField(inventario, 'Inventario'),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: TextField(
              controller: observaciones,
              maxLines: 3,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: MayusculasFormatter.lista,
              decoration: const InputDecoration(
                labelText: 'Observaciones',
                alignLabelWithHint: true,
              ),
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Fuera de servicio'),
            subtitle: const Text('El equipo no requiere calibración'),
            value: _fueraDeServicio,
            activeThumbColor: Colors.red.shade600,
            contentPadding: EdgeInsets.zero,
            onChanged: (v) => setState(() => _fueraDeServicio = v),
          ),
          if (_fueraDeServicio)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Marcado por: ${_fueraDeServicioPor?.isNotEmpty == true ? _fueraDeServicioPor : (_tecnicoActual.isNotEmpty ? _tecnicoActual : '(cargando técnico...)')}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                ),
              ),
            ),
          if (_historialMontaje.isNotEmpty) ...[
            const Divider(),
            Align(
              alignment: Alignment.centerLeft,
              child: Text('Historial de certificado montado',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                      color: Colors.teal.shade800)),
            ),
            for (final h in _historialMontaje)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  h['accion'] == 'montado' ? Icons.verified : Icons.remove_done,
                  size: 18,
                  color: h['accion'] == 'montado'
                      ? Colors.teal
                      : Colors.red.shade400,
                ),
                title: Text(
                  '${h['accion'] == 'montado' ? 'Montado' : 'Desmontado'}'
                  ' · ${fechaCorta(h['en'])} · ${h['por'] ?? ''}',
                  style: const TextStyle(fontSize: 12),
                ),
                subtitle: (h['motivo']?.toString() ?? '').isNotEmpty
                    ? Text('Motivo: ${h['motivo']}',
                        style: const TextStyle(fontSize: 11))
                    : null,
              ),
          ],
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: () {
            if (nombre.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('El nombre es obligatorio'),
                  duration: Duration(seconds: 2),
                  persist: false,
                ),
              );
              return;
            }
            if (_fueraDeServicio && observaciones.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Escribe en Observaciones por qué está fuera de servicio'),
                  duration: Duration(seconds: 2),
                  persist: false,
                ),
              );
              return;
            }

            // Autor de la baja: si ya estaba fuera de servicio y ya tenía
            // autor registrado, se conserva (editar observaciones no debe
            // reatribuir la baja a quien solo corrige el texto). Si se
            // acaba de marcar ahora, o nunca quedó registrado, se firma con
            // el técnico de este dispositivo.
            String? fueraDeServicioPorFinal;
            if (_fueraDeServicio) {
              final conservarAutorPrevio = _fueraDeServicioInicial &&
                  (_fueraDeServicioPor?.isNotEmpty ?? false);
              fueraDeServicioPorFinal = conservarAutorPrevio
                  ? _fueraDeServicioPor
                  : (_tecnicoActual.isNotEmpty
                      ? _tecnicoActual
                      : _fueraDeServicioPor);
            }

            Navigator.pop(context, {
              'nombre': nombre.text,
              'marca': marca.text,
              'modelo': modelo.text,
              'serie': serie.text,
              'ubicacion': _ubicacionFinal(),
              'inventario': inventario.text,
              'certificado': widget.equipo?['certificado'] ?? '',
              'fecha': widget.equipo?['fecha'] ?? '',
              'observaciones': observaciones.text,
              'fuera_de_servicio': _fueraDeServicio,
              'fuera_de_servicio_por': fueraDeServicioPorFinal,
            });
          },
          child: const Text('Guardar'),
        ),
      ],
    );
  }

  /// La ubicación a guardar: sin espacios sobrantes y, si equivale a una
  /// que ya existe ("UCI ADULTO " = "UCI ADULTO", "EXPANSION" =
  /// "EXPANSIÓN"), con la escritura de la existente — así un equipo nuevo
  /// nunca crea una pestaña/ubicación repetida.
  String _ubicacionFinal() {
    final texto = TextUtils.limpiarEspacios(ubicacion.text);
    return _ubicaciones[TextUtils.claveUbicacion(texto)]?.nombre ?? texto;
  }

  Widget _buildUbicacionField() {
    final nombres = _ubicaciones.values.map((g) => g.nombre).toList()..sort();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RawAutocomplete<String>(
        textEditingController: ubicacion,
        focusNode: _ubicacionFocus,
        optionsBuilder: (valor) {
          final q = TextUtils.claveUbicacion(valor.text);
          if (q.isEmpty) return nombres;
          return nombres.where((n) => TextUtils.claveUbicacion(n).contains(q));
        },
        fieldViewBuilder: (_, controller, focusNode, onSubmit) => TextField(
          controller: controller,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: MayusculasFormatter.lista,
          decoration: const InputDecoration(
            labelText: 'Ubicación / Servicio',
            helperText: 'Elige una existente o escribe una nueva',
          ),
          onSubmitted: (_) => onSubmit(),
        ),
        optionsViewBuilder: (_, onSelected, opciones) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220, maxWidth: 280),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final o in opciones)
                    ListTile(
                      dense: true,
                      title: Text(o),
                      onTap: () => onSelected(o),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildField(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
          controller: c,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: MayusculasFormatter.lista,
          decoration: InputDecoration(labelText: label)),
    );
  }
}
