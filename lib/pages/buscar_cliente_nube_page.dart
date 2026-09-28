import 'package:flutter/material.dart';

import '../data/inventario_data.dart';
import '../data/inventario_sync.dart';
import '../utils/text_utils.dart';

/// Lista los clientes que ya existen en la nube (cargados por cualquier
/// técnico) para que otro técnico los busque por nombre y los traiga a su
/// propio celular sin tener que pedir/reimportar el Excel.
class BuscarClienteNubePage extends StatefulWidget {
  const BuscarClienteNubePage({super.key});

  @override
  State<BuscarClienteNubePage> createState() => _BuscarClienteNubePageState();
}

class _BuscarClienteNubePageState extends State<BuscarClienteNubePage> {
  final TextEditingController _busqueda = TextEditingController();
  List<Map<String, dynamic>> _clientes = [];
  bool _cargando = true;
  String? _error;
  // id del cliente que se está descargando ahora mismo, para deshabilitar
  // el resto de la lista mientras tanto y no disparar dos descargas juntas.
  String? _descargando;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _busqueda.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    final lista = await InventarioSync.listarClientesNube();
    lista.sort((a, b) => (a['nombre']?.toString() ?? '')
        .compareTo(b['nombre']?.toString() ?? ''));
    if (!mounted) return;
    setState(() {
      _clientes = lista;
      _cargando = false;
      if (lista.isEmpty) {
        _error = null; // lista vacía es un estado normal, no un error
      }
    });
  }

  List<Map<String, dynamic>> get _filtrados {
    final q = TextUtils.quitarTildes(_busqueda.text.trim()).toLowerCase();
    if (q.isEmpty) return _clientes;
    return _clientes
        .where((c) => TextUtils.quitarTildes(c['nombre']?.toString() ?? '')
            .toLowerCase()
            .contains(q))
        .toList();
  }

  Future<void> _elegir(Map<String, dynamic> clienteMeta) async {
    final id = clienteMeta['id']?.toString() ?? '';
    if (id.isEmpty || _descargando != null) return;

    setState(() => _descargando = id);
    try {
      await InventarioData.cargarClienteDesdeNube(
        clienteId: id,
        clienteMeta: clienteMeta,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _descargando = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo cargar el cliente: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Clientes en la nube'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar lista',
            onPressed: _cargando ? null : _cargar,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _busqueda,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Buscar cliente por nombre...',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_cargando)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_clientes.isEmpty)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off,
                          size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 12),
                      Text(
                        'No hay clientes cargados en la nube todavía.\n'
                        'El primer técnico que importe un Excel de un cliente '
                        'lo deja disponible aquí para los demás.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_filtrados.isEmpty)
            const Expanded(
              child: Center(child: Text('Ningún cliente coincide con la búsqueda')),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _filtrados.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final c = _filtrados[i];
                  final id = c['id']?.toString() ?? '';
                  final descargandoEste = _descargando == id;
                  final yaActivo = c['nombre'] == InventarioData.cliente;
                  return ListTile(
                    leading: const Icon(Icons.business_outlined),
                    title: Text(c['nombre']?.toString() ?? '(sin nombre)'),
                    subtitle: Text([
                      if ((c['ciudad']?.toString() ?? '').isNotEmpty)
                        c['ciudad'],
                      if ((c['nit']?.toString() ?? '').isNotEmpty)
                        'NIT: ${c['nit']}',
                    ].join(' · ')),
                    trailing: descargandoEste
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : yaActivo
                            ? const Icon(Icons.check_circle,
                                color: Colors.green)
                            : const Icon(Icons.cloud_download_outlined),
                    enabled: _descargando == null,
                    onTap: () => _elegir(c),
                  );
                },
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }
}
