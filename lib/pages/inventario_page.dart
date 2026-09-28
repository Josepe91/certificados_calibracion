import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border;

import '../data/inventario_data.dart';
import '../utils/mayusculas_formatter.dart';
import 'nueva_solicitud_page.dart';
import '../data/inventario_sync.dart';
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

class InventarioPage extends StatefulWidget {
  const InventarioPage({super.key});

  @override
  State<InventarioPage> createState() => _InventarioPageState();
}

class _InventarioPageState extends State<InventarioPage> {
  final TextEditingController _searchController = TextEditingController();
  final ValueNotifier<String> _busquedaNotifier = ValueNotifier('');
  final ValueNotifier<String?> _ubicacionFiltroNotifier = ValueNotifier(null);
  final ValueNotifier<String?> _estadoFiltroNotifier = ValueNotifier(null);

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
      SnackBar(content: Text('Inventario de $nombreCliente activado')),
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

    final excel = Excel.decodeBytes(bytes);
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
            ? TextUtils.quitarTildes(
                    encabezado[col]?.value?.toString() ?? '')
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
              content: Text('No se encontró nombre de cliente en el Excel')),
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
        'fecha': row[_colFecha]?.value?.toString().trim() ?? '',
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
          duration: const Duration(seconds: 4),
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
            content: Text('Primero selecciona o carga un inventario')),
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

  Future<void> _editarEquipo(Map<String, dynamic> equipo, int index) async {
    final actualizado = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CrearEditarEquipoDialog(equipo: equipo),
    );
    if (actualizado != null) {
      await InventarioData.actualizar(index, actualizado);
    }
  }

  Widget _estadoBadge(bool calibrado) {
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      labelText: 'Buscar por nombre, serie o inventario',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      InventarioData.equiposNotifier,
                      _busquedaNotifier,
                      _ubicacionFiltroNotifier,
                      _estadoFiltroNotifier,
                    ]),
                    builder: (_, __) {
                      final lista = InventarioData.equipos;
                      final q = TextUtils.quitarTildes(_busquedaNotifier.value)
                          .toLowerCase();
                      final ubicFiltro = _ubicacionFiltroNotifier.value;
                      final estadoFiltro = _estadoFiltroNotifier.value;

                      final ubicaciones = lista
                          .map((e) => e['ubicacion']?.toString() ?? '')
                          .where((u) => u.isNotEmpty)
                          .toSet()
                          .toList()
                        ..sort();

                      String norm(dynamic v) =>
                          TextUtils.quitarTildes(v.toString()).toLowerCase();
                      final mostrar = lista.where((e) {
                        final matchSearch = q.isEmpty ||
                            norm(e['serie']).contains(q) ||
                            norm(e['inventario']).contains(q) ||
                            norm(e['nombre']).contains(q);
                        final matchUbic = ubicFiltro == null ||
                            e['ubicacion'].toString() == ubicFiltro;
                        final esCal =
                            (e['certificado']?.toString().trim() ?? '')
                                .isNotEmpty;
                        final esBaja = e['fuera_de_servicio'] == true;
                        final matchEstado = estadoFiltro == null ||
                            (estadoFiltro == 'calibrado' && esCal) ||
                            (estadoFiltro == 'pendiente' &&
                                !esCal &&
                                !esBaja) ||
                            (estadoFiltro == 'baja' && esBaja);
                        return matchSearch && matchUbic && matchEstado;
                      }).toList();

                      final calibrados = mostrar
                          .where((e) =>
                              (e['certificado']?.toString().trim() ?? '')
                                  .isNotEmpty)
                          .length;
                      final fuera = mostrar
                          .where((e) => e['fuera_de_servicio'] == true)
                          .length;
                      final pendientes = mostrar.length - calibrados - fuera;

                      return Column(
                        children: [
                          if (ubicaciones.isNotEmpty)
                            SizedBox(
                              height: 48,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                                children: [
                                  FilterChip(
                                    label: const Text('Todas'),
                                    selected: ubicFiltro == null,
                                    onSelected: (_) =>
                                        _ubicacionFiltroNotifier.value = null,
                                  ),
                                  ...ubicaciones.map((u) => Padding(
                                        padding: const EdgeInsets.only(left: 6),
                                        child: FilterChip(
                                          label: Text(u),
                                          selected: ubicFiltro == u,
                                          onSelected: (_) =>
                                              _ubicacionFiltroNotifier.value =
                                                  ubicFiltro == u ? null : u,
                                        ),
                                      )),
                                ],
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                            child: SegmentedButton<String?>(
                              segments: const [
                                ButtonSegment(
                                  value: null,
                                  label: Text('Todos'),
                                  icon: Icon(Icons.list, size: 16),
                                ),
                                ButtonSegment(
                                  value: 'calibrado',
                                  label: Text('Calibrados'),
                                  icon: Icon(Icons.check_circle_outline,
                                      size: 16),
                                ),
                                ButtonSegment(
                                  value: 'pendiente',
                                  label: Text('Pendientes'),
                                  icon: Icon(Icons.pending_outlined, size: 16),
                                ),
                                ButtonSegment(
                                  value: 'baja',
                                  label: Text('Baja'),
                                  icon: Icon(Icons.block_outlined, size: 16),
                                ),
                              ],
                              selected: {estadoFiltro},
                              onSelectionChanged: (sel) =>
                                  _estadoFiltroNotifier.value = sel.first,
                              style: ButtonStyle(
                                visualDensity: VisualDensity.compact,
                                textStyle: WidgetStateProperty.all(
                                    const TextStyle(fontSize: 11)),
                              ),
                            ),
                          ),
                          if (mostrar.isNotEmpty)
                            Container(
                              width: double.infinity,
                              color: Colors.grey.shade50,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 6),
                              child: Row(
                                children: [
                                  if (ubicFiltro != null) ...[
                                    Icon(Icons.location_on,
                                        size: 13, color: Colors.blue.shade600),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        ubicFiltro,
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 12,
                                            color: Colors.blue.shade700),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                  ] else
                                    const Expanded(
                                      child: Text(
                                        'Todos los servicios',
                                        style: TextStyle(
                                            fontSize: 12, color: Colors.grey),
                                      ),
                                    ),
                                  _contadorChip(
                                      calibrados, Colors.green, 'calibrados'),
                                  const SizedBox(width: 6),
                                  _contadorChip(
                                      pendientes, Colors.orange, 'pendientes'),
                                  if (fuera > 0) ...[
                                    const SizedBox(width: 6),
                                    _contadorChip(fuera, Colors.red, 'baja'),
                                  ],
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

                                  // Buscar el índice real en la lista completa
                                  // por id (identidad estable, no rompe con
                                  // series/inventarios repetidos como "NO
                                  // REGISTRA" compartidos entre equipos).
                                  final index =
                                      InventarioData.indexPorIdOCascada(
                                          lista, e);

                                  final Color avatarColor = esBaja
                                      ? Colors.grey.shade600
                                      : noPasaCalibracion
                                          ? Colors.deepOrange.shade700
                                          : esNuevo
                                              ? Colors.red
                                              : esCalibrado
                                                  ? Colors.green
                                                  : Colors.orange.shade700;

                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 4),
                                    child: ListTile(
                                      leading: CircleAvatar(
                                        backgroundColor: avatarColor,
                                        child: Icon(
                                          esBaja
                                              ? Icons.block_outlined
                                              : noPasaCalibracion
                                                  ? Icons.report_problem
                                                  : esCalibrado
                                                      ? Icons.check
                                                      : Icons.pending_outlined,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                      title: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              e['nombre']?.toString() ?? '',
                                              style: TextStyle(
                                                color: esNuevo
                                                    ? Colors.red
                                                    : Colors.black87,
                                                fontWeight: FontWeight.w500,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          if (esBaja)
                                            _badgeFueraDeServicio()
                                          else if (noPasaCalibracion)
                                            _badgeNoPasaCalibracion()
                                          else
                                            _estadoBadge(esCalibrado),
                                        ],
                                      ),
                                      subtitle: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          // Si no tiene serie ni inventario,
                                          // mostrar badge "Por identificar".
                                          if (!tieneSerie && !tieneInv)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 2, bottom: 2),
                                              child: _badgePorIdentificar(),
                                            )
                                          else
                                            Text(
                                                'Serie: ${e['serie']} | Inv: ${e['inventario']}'),
                                          if ((e['ubicacion']
                                                  ?.toString()
                                                  .isNotEmpty ??
                                              false))
                                            Row(
                                              children: [
                                                Icon(Icons.location_on,
                                                    size: 11,
                                                    color:
                                                        Colors.grey.shade500),
                                                const SizedBox(width: 2),
                                                Text(
                                                  e['ubicacion'],
                                                  style: TextStyle(
                                                      fontSize: 11,
                                                      color:
                                                          Colors.grey.shade600),
                                                ),
                                              ],
                                            ),
                                          if (esCalibrado &&
                                              (e['fecha']
                                                      ?.toString()
                                                      .isNotEmpty ??
                                                  false))
                                            Text(
                                              'Cert: ${e['certificado']} · ${e['fecha']}',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.green.shade700),
                                            ),
                                          if ((e['observaciones']
                                                  ?.toString()
                                                  .isNotEmpty ??
                                              false))
                                            Text(
                                              'Obs: ${e['observaciones']}',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.grey.shade700),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (esBaja &&
                                              (e['fuera_de_servicio_por']
                                                      ?.toString()
                                                      .isNotEmpty ??
                                                  false))
                                            Text(
                                              'Marcado por: ${e['fuera_de_servicio_por']}',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.red.shade400),
                                            ),
                                          if (noPasaCalibracion)
                                            Text(
                                              (e['no_pasa_calibracion_detalle']
                                                          ?.toString()
                                                          .isNotEmpty ??
                                                      false)
                                                  ? 'No pasa: ${e['no_pasa_calibracion_detalle']}'
                                                  : 'No pasa calibración',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors
                                                      .deepOrange.shade700),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          if (noPasaCalibracion &&
                                              (e['no_pasa_calibracion_por']
                                                      ?.toString()
                                                      .isNotEmpty ??
                                                  false))
                                            Text(
                                              'Confirmado por: ${e['no_pasa_calibracion_por']}',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors
                                                      .deepOrange.shade400),
                                            ),
                                        ],
                                      ),
                                      isThreeLine: true,
                                      trailing: index != -1
                                          ? Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                if (!esCalibrado && !esBaja)
                                                  IconButton(
                                                    icon: Icon(
                                                        Icons.add_task,
                                                        color: Colors
                                                            .blue.shade600),
                                                    tooltip: 'Crear solicitud',
                                                    onPressed: () =>
                                                        _crearSolicitudPara(e),
                                                  ),
                                                IconButton(
                                                  icon: Icon(
                                                      Icons.delete_outline,
                                                      color:
                                                          Colors.red.shade300),
                                                  tooltip: 'Eliminar equipo',
                                                  onPressed: () =>
                                                      _eliminarEquipo(
                                                          e, index),
                                                ),
                                              ],
                                            )
                                          : null,
                                      onTap: index != -1
                                          ? () => _editarEquipo(e, index)
                                          : null,
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
      floatingActionButton: FloatingActionButton(
        onPressed: _crearEquipo,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _contadorChip(int cantidad, Color color, String etiqueta) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Text(
        '$cantidad $etiqueta',
        style:
            TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
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
  const _CrearEditarEquipoDialog({this.equipo});

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

  @override
  void dispose() {
    nombre.dispose();
    marca.dispose();
    modelo.dispose();
    serie.dispose();
    ubicacion.dispose();
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
          _buildField(ubicacion, 'Ubicación / Servicio'),
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
                const SnackBar(content: Text('El nombre es obligatorio')),
              );
              return;
            }
            if (_fueraDeServicio && observaciones.text.trim().isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text(
                        'Escribe en Observaciones por qué está fuera de servicio')),
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
              'ubicacion': ubicacion.text,
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
