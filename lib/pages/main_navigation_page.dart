import 'package:flutter/material.dart';

import '../data/solicitudes_storage.dart';
import '../data/tecnico_profile.dart';
import '../utils/mayusculas_formatter.dart';
import 'home_page.dart';
import 'inventario_page.dart';

class MainNavigationPage extends StatefulWidget {
  const MainNavigationPage({super.key});

  @override
  State<MainNavigationPage> createState() => _MainNavigationPageState();
}

class _MainNavigationPageState extends State<MainNavigationPage> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _pedirNombreTecnico());
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
