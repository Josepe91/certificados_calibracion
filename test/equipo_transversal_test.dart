import 'package:certificados_calibracion/data/inventario_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Datos del equipo transversales', () {
    tearDown(() {
      InventarioData.cliente = '';
      InventarioData.equiposNotifier.value = [];
    });

    test('equipoActual devuelve lo vigente del inventario', () {
      InventarioData.cliente = 'Unidad Clínica La Magdalena';
      InventarioData.equiposNotifier.value = [
        {
          'nombre': 'MONITOR',
          'serie': '123',
          'clave_nube': 'k1',
          'observaciones': 'Pantalla rayada',
        },
      ];
      // Copia vieja guardada en una solicitud, antes de la observación.
      final enSolicitud = {'nombre': 'MONITOR', 'serie': '123', 'clave_nube': 'k1'};
      final actual = InventarioData.equipoActual(enSolicitud,
          nombreCliente: 'UNIDAD CLINICA LA MAGDALENA');
      expect(actual?['observaciones'], 'Pantalla rayada');

      // Solicitud de otro cliente: no se mezcla.
      expect(
          InventarioData.equipoActual(enSolicitud, nombreCliente: 'OTRA'),
          isNull);
    });

    test('copiarCamposDelEquipo copia datos del equipo, no el certificado', () {
      final destino = <String, dynamic>{
        'nombre': 'MONITOR',
        'serie': 'VIEJA',
        'certificado': 'JS1-26',
        'clave_nube': 'k1',
      };
      final cambio = InventarioData.copiarCamposDelEquipo(destino, {
        'nombre': 'MONITOR',
        'serie': 'NUEVA',
        'observaciones': 'Sin batería',
        'certificado': 'JS999-26',
        'clave_nube': 'otra',
      });
      expect(cambio, true);
      expect(destino['serie'], 'NUEVA');
      expect(destino['observaciones'], 'Sin batería');
      expect(destino['certificado'], 'JS1-26');
      expect(destino['clave_nube'], 'k1');

      expect(
          InventarioData.copiarCamposDelEquipo(
              destino, Map<String, dynamic>.from(destino)),
          false);
    });
  });
}
