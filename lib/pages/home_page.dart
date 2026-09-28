import 'package:flutter/material.dart';

import '../data/btmc_storage.dart';
import '../data/drive_sync.dart';
import '../data/excel_nube.dart';
import '../data/version_app.dart';
import '../data/inventario_data.dart';
import '../data/solicitudes_storage.dart';
import 'solicitudes_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    SolicitudesStorage.refrescarContador();
  }

  // =========================
  // LIMPIAR SOLICITUDES
  // =========================
  Future<void> _limpiarSolicitudes(BuildContext context) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Limpiar solicitudes'),
        content: const Text(
          'Esto eliminará todas las solicitudes y fotos guardadas localmente.\n\n'
          'El inventario NO se borrará.\n\n'
          '¿Deseas continuar?',
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

    await BTMCStorage.borrarSolicitudes();
    SolicitudesStorage.contadorNotifier.value = 0;

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Solicitudes eliminadas')),
      );
    }
  }

  // =========================
  // LIMPIAR INVENTARIO
  // =========================
  Future<void> _limpiarInventario(BuildContext context) async {
    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Limpiar inventario'),
        content: const Text(
          'Esto eliminará todos los inventarios de clientes cargados.\n\n'
          'Las solicitudes NO se borrarán.\n\n'
          '¿Deseas continuar?',
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

    await InventarioData.limpiarTodosLosInventarios();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Inventarios eliminados')),
      );
    }
  }

  // =========================
  // COMPARTIR SOLICITUDES
  // =========================
  Future<void> _compartirSolicitudes(BuildContext context) async {
    final haySolicitudes = await DriveSync.syncSolicitudes();

    if (!context.mounted) return;

    if (!haySolicitudes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No hay solicitudes pendientes para compartir')),
      );
      return;
    }

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Se subieron correctamente?'),
        content: const Text(
          'Verifica en Drive que los archivos ya aparecen ahí antes de '
          'confirmar. Si cierras la ventana de compartir sin terminar la '
          'subida y confirmas de todas formas, estas solicitudes se '
          'marcarán como enviadas aunque no hayan llegado a Drive.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('No, dejar pendientes'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sí, marcar como enviadas'),
          ),
        ],
      ),
    );

    if (confirmar != true || !context.mounted) return;

    final cantidad = await SolicitudesStorage.moverTodasAEnviadas();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$cantidad solicitud(es) marcada(s) como enviada(s) ✓'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // =========================
  // SUBIR A LA NUBE (Firebase Storage, ver lib/data/excel_nube.dart)
  // =========================
  Future<void> _subirCertificados(BuildContext context) async {
    if (SolicitudesStorage.contadorNotifier.value == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay solicitudes pendientes')),
      );
      return;
    }
    final (ok, fallidas) = await _conProgreso(
        context, 'Subiendo certificados...', ExcelNube.subirPendientes);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(fallidas == 0
            ? '$ok certificado(s) subido(s) a la nube ✓'
            : '$ok subido(s) · $fallidas sin subir (revisa la señal e '
                'intenta de nuevo)'),
        backgroundColor:
            fallidas == 0 ? Colors.green.shade700 : Colors.orange.shade700,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _subirInventarios(BuildContext context) async {
    final (ok, fallidos) = await _conProgreso(
        context, 'Subiendo inventarios...', ExcelNube.subirInventarios);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok == 0 && fallidos == 0
            ? 'No hay inventarios para subir'
            : fallidos == 0
                ? '$ok inventario(s) subido(s) a la nube ✓'
                : '$ok subido(s) · $fallidos sin subir (revisa la señal)'),
        backgroundColor: fallidos == 0 ? null : Colors.orange.shade700,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<T> _conProgreso<T>(
      BuildContext context, String texto, Future<T> Function() tarea) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(texto)),
            ],
          ),
        ),
      ),
    );
    try {
      return await tarea();
    } finally {
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
  }

  // =========================
  // EXPORTAR INVENTARIO
  // =========================
  Future<void> _exportarInventario(BuildContext context) async {
    final nombres = await DriveSync.enviarInventario();

    if (context.mounted) {
      if (nombres.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No hay inventarios para exportar')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Compartiendo ${nombres.length} inventario(s)...',
            ),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade100,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const SizedBox(height: 20),

              // LOGO
              Center(
                child: Image.asset(
                  'assets/images/app_icon.png',
                  height: 140,
                ),
              ),

              const SizedBox(height: 30),

              // VER SOLICITUDES
              ValueListenableBuilder<int>(
                valueListenable: SolicitudesStorage.contadorNotifier,
                builder: (_, count, __) => _BotonPrincipal(
                  icon: Icons.description,
                  texto: 'Ver solicitudes creadas',
                  badge: count,
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const SolicitudesPage(),
                    ),
                  ).then((_) => SolicitudesStorage.refrescarContador()),
                ),
              ),

              const SizedBox(height: 12),

              // SUBIR CERTIFICADOS (Excel) A LA NUBE
              _BotonPrincipal(
                icon: Icons.cloud_upload,
                texto: 'Subir certificados a la nube',
                onTap: () => _subirCertificados(context),
              ),

              const SizedBox(height: 12),

              // SUBIR INVENTARIO (Excel) A LA NUBE
              _BotonPrincipal(
                icon: Icons.inventory_2,
                texto: 'Subir inventario a la nube',
                onTap: () => _subirInventarios(context),
              ),

              // Compartir por otra app (Drive, WhatsApp, correo): el flujo
              // anterior, por si se necesita mandar los Excel a alguien.
              Wrap(
                alignment: WrapAlignment.center,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Compartir solicitudes'),
                    onPressed: () => _compartirSolicitudes(context),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Compartir inventario'),
                    onPressed: () => _exportarInventario(context),
                  ),
                ],
              ),

              const Spacer(),

              // LIMPIAR SOLICITUDES
              TextButton.icon(
                icon: const Icon(Icons.delete_sweep, color: Colors.red),
                label: const Text(
                  'Limpiar solicitudes',
                  style: TextStyle(color: Colors.red),
                ),
                onPressed: () => _limpiarSolicitudes(context),
              ),

              // LIMPIAR INVENTARIO
              TextButton.icon(
                icon: const Icon(Icons.inventory_2_outlined, color: Colors.red),
                label: const Text(
                  'Limpiar inventario',
                  style: TextStyle(color: Colors.red),
                ),
                onPressed: () => _limpiarInventario(context),
              ),

              // Versión instalada: para comparar entre celulares de un
              // vistazo (ver lib/data/version_app.dart).
              FutureBuilder<String>(
                future: VersionApp.etiqueta(),
                builder: (_, snap) => Text(
                  snap.data ?? '',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                ),
              ),

              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================
// BOTÓN REUTILIZABLE
// =====================
class _BotonPrincipal extends StatelessWidget {
  final IconData icon;
  final String texto;
  final VoidCallback onTap;
  final int badge;

  const _BotonPrincipal({
    required this.icon,
    required this.texto,
    required this.onTap,
    this.badge = 0,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 6,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(icon, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                texto,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (badge > 0) ...[
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.blue.shade600,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '$badge',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    );
  }
}
