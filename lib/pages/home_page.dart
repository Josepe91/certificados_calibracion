import 'package:flutter/material.dart';

import '../data/btmc_storage.dart';
import '../data/drive_sync.dart';
import '../data/version_app.dart';
import '../data/inventario_data.dart';
import '../data/solicitudes_storage.dart';
import '../data/solicitudes_sync.dart';
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
    // Las ya subidas a la nube están en enviadas/ y antes no había forma de
    // mandarlas a Drive sin abrir y guardar una por una.
    final dias = await showDialog<int>(
      context: context,
      builder: (_) => SimpleDialog(
        title: const Text('¿Qué solicitudes compartir?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 0),
            child: const Text('Solo las pendientes'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 2),
            child: const Text('Pendientes + enviadas de hoy y ayer'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 7),
            child: const Text('Pendientes + enviadas de los últimos 7 días'),
          ),
        ],
      ),
    );
    if (dias == null || !context.mounted) return;

    final hoy = DateTime.now();
    final haySolicitudes = await DriveSync.syncSolicitudes(
      enviadasDesde: dias == 0
          ? null
          : DateTime(hoy.year, hoy.month, hoy.day - (dias - 1)),
    );

    if (!context.mounted) return;

    if (!haySolicitudes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('No hay solicitudes para compartir')),
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

  Future<void> _reintentarSubidas(BuildContext context) async {
    await _conProgreso(context, 'Subiendo solicitudes...',
        SolicitudesSync.reintentarPendientes);
    if (!context.mounted) return;
    final quedan = SolicitudesSync.pendientesNube.value.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(quedan == 0
            ? 'Todas las solicitudes están en la nube ✓'
            : '$quedan sin subir (revisa la señal e intenta de nuevo)'),
        backgroundColor:
            quedan == 0 ? Colors.green.shade700 : Colors.orange.shade700,
        duration: const Duration(seconds: 5),
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

              // Las solicitudes suben solas a la nube al guardarse
              // (SolicitudesSync); esto solo aparece si alguna se atascó.
              ValueListenableBuilder<Set<String>>(
                valueListenable: SolicitudesSync.pendientesNube,
                builder: (_, pendientes, __) => pendientes.isEmpty
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Material(
                          color: Colors.orange.shade100,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            leading: Icon(Icons.cloud_off,
                                color: Colors.orange.shade800),
                            title: Text(
                                '${pendientes.length} solicitud(es) sin subir a la nube'),
                            trailing: TextButton(
                              onPressed: () => _reintentarSubidas(context),
                              child: const Text('Reintentar'),
                            ),
                          ),
                        ),
                      ),
              ),

              // COMPARTIR (Drive, WhatsApp, correo). Los datos ya suben solos
              // a la nube; los Excel se generan aquí al compartir.
              _BotonPrincipal(
                icon: Icons.share,
                texto: 'Compartir solicitudes',
                onTap: () => _compartirSolicitudes(context),
              ),

              const SizedBox(height: 12),

              _BotonPrincipal(
                icon: Icons.inventory_2,
                texto: 'Compartir inventario',
                onTap: () => _exportarInventario(context),
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
