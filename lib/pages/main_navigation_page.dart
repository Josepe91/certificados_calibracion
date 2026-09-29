import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../data/solicitudes_storage.dart';
import '../data/solicitudes_sync.dart';
import '../data/tecnico_profile.dart';
import '../data/version_app.dart';
import '../utils/mayusculas_formatter.dart';
import 'home_page.dart';
import 'inventario_page.dart';

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key});

  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage>
    with WidgetsBindingObserver {
  int _index = 0;
  bool _bloqueoVisible = false;
  StreamSubscription<List<ConnectivityResult>>? _conexion;
  Timer? _reintentoPeriodico;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reintenta subir solicitudes pendientes apenas vuelve la red...
    _conexion = Connectivity().onConnectivityChanged.listen((r) {
      if (!r.contains(ConnectivityResult.none)) {
        SolicitudesSync.reintentarPendientes();
      }
    });
    // ...y cada 5 min mientras haya pendientes: con señal débil el celular
    // puede estar "conectado" todo el tiempo sin que la subida pase, y ese
    // caso no dispara ningún cambio de conectividad.
    _reintentoPeriodico = Timer.periodic(const Duration(minutes: 5), (_) {
      if (SolicitudesSync.pendientesNube.value.isNotEmpty) {
        SolicitudesSync.reintentarPendientes();
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _pedirNombreTecnico();
      await _verificarVersion();
      // Solicitudes que no alcanzaron a subir (sin señal) la última vez.
      await SolicitudesSync.reintentarPendientes();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _conexion?.cancel();
    _reintentoPeriodico?.cancel();
    super.dispose();
  }

  // También al volver a la app (ej. después de dejarla en segundo plano
  // un día entero): una versión nueva pudo publicarse mientras tanto, y
  // puede haber vuelto la señal para subir lo que quedó pendiente.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _verificarVersion();
      SolicitudesSync.reintentarPendientes();
    }
  }

  // Bloquea la app si este build es más viejo que config/app.version_minima
  // (ver lib/data/version_app.dart). No se puede cerrar el diálogo: seguir
  // trabajando con una versión vieja es justo lo que desincroniza el
  // inventario entre técnicos.
  Future<void> _verificarVersion() async {
    if (_bloqueoVisible) return;
    final minima = await VersionApp.verificar();
    if (minima == null || !mounted) return;
    final actual = await VersionApp.etiqueta();
    if (!mounted) return;

    _bloqueoVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          icon: const Icon(Icons.system_update, size: 40),
          title: const Text('Actualiza la aplicación'),
          content: Text(
            'Hay una versión nueva (build $minima) y este celular tiene la '
            '$actual.\n\n'
            'Ábrela desde la app "Firebase App Tester" e instálala para '
            'seguir trabajando. Así todos los técnicos usan la misma versión '
            'y el inventario se sincroniza bien.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () async {
                final sigue = await VersionApp.verificar();
                if (sigue == null && dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('Ya actualicé'),
            ),
          ],
        ),
      ),
    );
    _bloqueoVisible = false;
  }

  // Se pide una sola vez por dispositivo. El nombre queda guardado en
  // lib/data/tecnico_profile.dart y se usa para firmar (campo
  // `actualizado_por`) cada equipo que este técnico sincroniza a la nube,
  // así al final del día se sabe quién hizo qué sobre el inventario.
  Future<void> _pedirNombreTecnico() async {
    final actual = await TecnicoProfile.obtenerNombre();
    if (actual.isNotEmpty || !mounted) return;

    final controller = TextEditingController();
    final nombre = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('¿Quién eres?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Escribe tu nombre para que tus certificados y cambios en el '
              'inventario queden identificados cuando se sincronicen con '
              'los demás técnicos.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: MayusculasFormatter.lista,
              decoration: const InputDecoration(
                labelText: 'Nombre del técnico',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              final texto = controller.text.trim();
              if (texto.isEmpty) return;
              Navigator.pop(context, texto);
            },
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (nombre != null && nombre.isNotEmpty) {
      await TecnicoProfile.guardarNombre(nombre);
    }
  }

  // Páginas construidas lazy — solo se crean cuando se visitan por primera vez
  // AutomaticKeepAliveClientMixin en cada página preserva el estado
  final List<Widget> _pages = const [
    HomePage(),
    InventarioPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: _pages,
      ),
      bottomNavigationBar: ValueListenableBuilder<int>(
        valueListenable: SolicitudesStorage.contadorNotifier,
        builder: (_, count, __) => BottomNavigationBar(
          currentIndex: _index,
          onTap: (i) => setState(() => _index = i),
          items: [
            BottomNavigationBarItem(
              icon: Badge.count(
                count: count,
                isLabelVisible: count > 0,
                child: const Icon(Icons.home),
              ),
              label: 'Inicio',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.inventory_2),
              label: 'Inventario',
            ),
          ],
        ),
      ),
    );
  }
}
