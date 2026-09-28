import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../data/certificado_excel.dart';
import '../data/inventario_data.dart';
import '../data/inventario_sync.dart';
import '../data/solicitudes_storage.dart';
import '../data/solicitudes_sync.dart';
import '../utils/text_utils.dart';
import 'nueva_solicitud_page.dart';

class SolicitudesPage extends StatefulWidget {
  const SolicitudesPage({super.key});

  @override
  State<SolicitudesPage> createState() => _SolicitudesPageState();
}

class _SolicitudesPageState extends State<SolicitudesPage> {
  // Cada entrada contiene el archivo + metadata legible del JSON
  List<_SolicitudMeta> solicitudes = [];
  bool cargando = true;
  final TextEditingController _searchController = TextEditingController();
  String _busqueda = '';

  @override
  void initState() {
    super.initState();
    _cargarSolicitudes();
    _searchController.addListener(() {
      setState(() => _busqueda =
          TextUtils.quitarTildes(_searchController.text).toLowerCase().trim());
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _cargarSolicitudes() async {
    final archivos = await SolicitudesStorage.listarPendientes();

    final List<_SolicitudMeta> resultado = [];
    final Set<String> clavesLocales = {};
    for (final f in archivos) {
      try {
        final data = jsonDecode(await f.readAsString());
        final equipoData = data['equipo'] as Map<String, dynamic>?;
        if (equipoData != null) {
          clavesLocales.add(InventarioSync.claveEquipo(equipoData));
        }
        resultado.add(_SolicitudMeta(
          file: f,
          equipo: data['equipo']?['nombre']?.toString() ?? '',
          serie: data['equipo']?['serie']?.toString() ?? '',
          cliente: data['cliente']?['nombre']?.toString() ?? '',
          fecha: data['fecha']?.toString() ?? '',
          certificado: data['certificado']?.toString() ?? '',
        ));
      } catch (_) {
        // Si el JSON no se puede leer, mostrar solo el nombre del archivo
        resultado.add(_SolicitudMeta(file: f));
      }
    }

    // Solicitudes en la nube del cliente activo hechas por CUALQUIER
    // técnico — se excluyen las que ya tienen archivo local (serían la
    // misma solicitud, y la copia local puede tener cambios sin subir
    // todavía) para no duplicarlas en la lista.
    if (InventarioData.cliente.isNotEmpty) {
      final clienteId = InventarioSync.slug(InventarioData.cliente);
      final nube = await SolicitudesSync.listarResumenNube(clienteId);
      for (final data in nube) {
        final clave = data['equipo_clave']?.toString() ?? '';
        if (clave.isEmpty || clavesLocales.contains(clave)) continue;
        resultado.add(_SolicitudMeta(
          equipoClave: clave,
          clienteIdNube: clienteId,
          equipo: data['equipo']?['nombre']?.toString() ?? '',
          serie: data['equipo']?['serie']?.toString() ?? '',
          cliente: data['cliente']?['nombre']?.toString() ?? '',
          fecha: data['fecha']?.toString() ?? '',
          certificado: data['certificado']?.toString() ?? '',
          actualizadoPor: data['actualizado_por']?.toString() ?? '',
        ));
      }
    }

    if (!mounted) return;
    setState(() {
      solicitudes = resultado;
      cargando = false;
    });
    SolicitudesStorage.contadorNotifier.value =
        resultado.where((s) => s.file != null).length;
  }

  Future<void> _abrirDeNube(_SolicitudMeta meta) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    final archivo = await SolicitudesSync.descargarComoArchivoLocal(
      clienteId: meta.clienteIdNube!,
      equipoClave: meta.equipoClave!,
    );
    if (!mounted) return;
    Navigator.of(context).pop(); // cierra el spinner

    if (archivo == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No se pudo descargar la solicitud de la nube')),
      );
      return;
    }

    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NuevaSolicitudPage(archivoJson: archivo)),
    );
    if (mounted) await _cargarSolicitudes();
  }

  Future<void> _eliminarSolicitud(_SolicitudMeta meta) async {
    final f = meta.file;
    if (f == null) return; // las de la nube no se borran deslizando (ver build)
    if (await f.exists()) await f.delete();

    // Eliminar el ZIP de fotos asociado si existe
    final zipPath = f.path
        .replaceAll(RegExp(r'\.json$', caseSensitive: false), '_fotos.zip');
    final zip = File(zipPath);
    if (await zip.exists()) await zip.delete();

    final xlsx = File(CertificadoExcel.rutaCertificado(f.path));
    if (await xlsx.exists()) await xlsx.delete();

    setState(() => solicitudes.removeWhere((s) => s.file?.path == f.path));
    SolicitudesStorage.contadorNotifier.value =
        solicitudes.where((s) => s.file != null).length;
  }

  @override
  Widget build(BuildContext context) {
    if (cargando) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    String norm(String v) => TextUtils.quitarTildes(v).toLowerCase();
    final mostrar = _busqueda.isEmpty
        ? solicitudes
        : solicitudes
            .where((s) =>
                norm(s.certificado).contains(_busqueda) ||
                norm(s.serie).contains(_busqueda) ||
                norm(s.equipo).contains(_busqueda))
            .toList();

    return Scaffold(
      appBar: AppBar(title: const Text('Solicitudes creadas')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                labelText: 'Buscar por certificado o serie',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: mostrar.isEmpty
                ? Center(
                    child: Text(solicitudes.isEmpty
                        ? 'No hay solicitudes guardadas'
                        : 'Sin resultados para "$_busqueda"'),
                  )
                : ListView.builder(
                    itemCount: mostrar.length,
                    itemBuilder: (_, i) {
                      final meta = mostrar[i];
                      final enNube = meta.file == null;

                      final tarjeta = Card(
                        margin: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: enNube
                                ? Colors.orange.shade50
                                : Colors.blue.shade50,
                            child: Icon(
                              enNube
                                  ? Icons.cloud_download_outlined
                                  : Icons.description,
                              color: enNube
                                  ? Colors.orange.shade700
                                  : Colors.blue.shade700,
                            ),
                          ),
                          title: Text(
                            meta.equipo.isNotEmpty
                                ? meta.equipo
                                : (meta.file?.uri.pathSegments.last ?? ''),
                            style:
                                const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (meta.cliente.isNotEmpty)
                                Text(meta.cliente,
                                    style: const TextStyle(fontSize: 12)),
                              Row(
                                children: [
                                  if (meta.certificado.isNotEmpty) ...[
                                    const Icon(Icons.badge_outlined,
                                        size: 12, color: Colors.grey),
                                    const SizedBox(width: 3),
                                    Text(
                                      meta.certificado,
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.grey),
                                    ),
                                    const SizedBox(width: 10),
                                  ],
                                  if (meta.fecha.isNotEmpty) ...[
                                    const Icon(Icons.calendar_today,
                                        size: 12, color: Colors.grey),
                                    const SizedBox(width: 3),
                                    Text(
                                      meta.fecha,
                                      style: const TextStyle(
                                          fontSize: 12, color: Colors.grey),
                                    ),
                                  ],
                                ],
                              ),
                              if (enNube)
                                Text(
                                  meta.actualizadoPor.isNotEmpty
                                      ? 'En la nube · ${meta.actualizadoPor}'
                                      : 'En la nube',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.orange.shade700),
                                ),
                            ],
                          ),
                          trailing: enNube
                              ? const Icon(Icons.download)
                              : const Icon(Icons.chevron_right),
                          onTap: enNube
                              ? () => _abrirDeNube(meta)
                              : () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => NuevaSolicitudPage(
                                          archivoJson: meta.file!),
                                    ),
                                  ).then((_) => _cargarSolicitudes());
                                },
                        ),
                      );

                      // Las de la nube todavía no tienen archivo local que
                      // borrar — se descargan primero (tap normal) y desde
                      // ahí sí se pueden eliminar como cualquier otra.
                      if (enNube) return tarjeta;

                      return Dismissible(
                        key: Key(meta.file!.path),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          color: Colors.red,
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        confirmDismiss: (_) async {
                          return await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Eliminar solicitud'),
                              content: Text(
                                '¿Eliminar la solicitud de "${meta.equipo.isNotEmpty ? meta.equipo : meta.file!.uri.pathSegments.last}"?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () =>
                                      Navigator.pop(context, false),
                                  child: const Text('Cancelar'),
                                ),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red),
                                  onPressed: () => Navigator.pop(context, true),
                                  child: const Text('Eliminar'),
                                ),
                              ],
                            ),
                          );
                        },
                        onDismissed: (_) => _eliminarSolicitud(meta),
                        child: tarjeta,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Metadata de una solicitud, local (archivo en disco) o de la nube (sin
/// descargar todavía — `file` null, `equipoClave`/`clienteIdNube` presentes
/// en su lugar).
class _SolicitudMeta {
  final File? file;
  final String? equipoClave;
  final String? clienteIdNube;
  final String equipo;
  final String serie;
  final String cliente;
  final String fecha;
  final String certificado;
  final String actualizadoPor;

  const _SolicitudMeta({
    this.file,
    this.equipoClave,
    this.clienteIdNube,
    this.equipo = '',
    this.serie = '',
    this.cliente = '',
    this.fecha = '',
    this.certificado = '',
    this.actualizadoPor = '',
  });
}
