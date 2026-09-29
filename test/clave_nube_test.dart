import 'package:certificados_calibracion/data/inventario_data.dart';
import 'package:certificados_calibracion/data/inventario_sync.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> eq(String nombre, String serie, {String ubic = 'UCI'}) =>
    {'nombre': nombre, 'serie': serie, 'ubicacion': ubic};

void main() {
  group('InventarioSync.docId', () {
    test('usa clave_nube aunque se editen los campos del equipo', () {
      final equipo = {...eq('MONITOR', '123'), 'orden': 0};
      final clave = InventarioSync.claveEquipo(equipo);
      final conClave = {...equipo, 'clave_nube': clave};

      final editado = {
        ...conClave,
        'serie': '123-CORREGIDA',
        'ubicacion': 'URG'
      };
      expect(InventarioSync.docId(editado), clave);
    });

    test('sin clave_nube (dato viejo) cae a claveEquipo', () {
      final equipo = {...eq('MONITOR', '123'), 'orden': 2};
      expect(InventarioSync.docId(equipo), InventarioSync.claveEquipo(equipo));
    });
  });

  group('InventarioData.fusionarConExistentes', () {
    test('dos celulares que importan el mismo Excel calculan las mismas claves',
        () {
      final excel = [eq('A', '1'), eq('B', '2'), eq('C', '3')];
      final celular1 = InventarioData.fusionarConExistentes(excel, []);
      final celular2 = InventarioData.fusionarConExistentes(excel, []);
      expect(celular1.map((e) => e['clave_nube']),
          celular2.map((e) => e['clave_nube']));
    });

    test('una fila insertada no cambia la clave de los demás equipos', () {
      final original = InventarioData.fusionarConExistentes(
          [eq('A', '1'), eq('B', '2')], []);
      final reimport = InventarioData.fusionarConExistentes(
          [eq('NUEVO', '9'), eq('A', '1'), eq('B', '2')], original);

      expect(reimport[1]['clave_nube'], original[0]['clave_nube']);
      expect(reimport[2]['clave_nube'], original[1]['clave_nube']);
      expect(reimport[0]['clave_nube'],
          isNot(anyOf(original[0]['clave_nube'], original[1]['clave_nube'])));
      expect(reimport.map((e) => e['orden']), [0, 1, 2]);
    });

    test('dato viejo sin clave_nube hereda la clave que ya tiene en la nube',
        () {
      // Guardado antes de clave_nube: su documento es claveEquipo con su
      // orden de ese momento (1).
      final viejo = {...eq('B', '2'), 'orden': 1, 'id': 'x'};
      final claveEnNube = InventarioSync.claveEquipo(viejo);

      final reimport =
          InventarioData.fusionarConExistentes([eq('B', '2')], [viejo]);
      expect(reimport.single['clave_nube'], claveEnNube);
      expect(reimport.single['orden'], 0);
    });

    test('conserva lo registrado en la app y no pisa el certificado del Excel',
        () {
      final previo = {
        ...eq('A', '1'),
        'id': 'id-a',
        'clave_nube': 'eq_0_A',
        'certificado': 'JS001',
        'fecha': '2026-09-01',
        'observaciones': 'OK',
        'fuera_de_servicio': true,
        'fuera_de_servicio_por': 'GABRIEL',
      };
      final sinCert =
          InventarioData.fusionarConExistentes([eq('A', '1')], [previo]).single;
      expect(sinCert['id'], 'id-a');
      expect(sinCert['certificado'], 'JS001');
      expect(sinCert['fecha'], '2026-09-01');
      expect(sinCert['observaciones'], 'OK');
      expect(sinCert['fuera_de_servicio'], true);
      expect(sinCert['fuera_de_servicio_por'], 'GABRIEL');

      final conCert = InventarioData.fusionarConExistentes([
        {...eq('A', '1'), 'certificado': 'JS999', 'fecha': '2026-10-01'}
      ], [
        previo
      ]).single;
      expect(conCert['certificado'], 'JS999');
      expect(conCert['fecha'], '2026-10-01');
    });

    test('series repetidas se emparejan por orden de aparición', () {
      final previos = [
        {...eq('A', 'NO REGISTRA'), 'clave_nube': 'k1', 'certificado': 'C1'},
        {...eq('B', 'NO REGISTRA'), 'clave_nube': 'k2', 'certificado': 'C2'},
      ];
      final r = InventarioData.fusionarConExistentes([
        eq('A', 'NO REGISTRA'),
        eq('B', 'NO REGISTRA'),
        eq('C', 'NO REGISTRA')
      ], previos);
      expect(r.map((e) => e['clave_nube']).take(2), ['k1', 'k2']);
      expect(r.map((e) => e['certificado']).take(2), ['C1', 'C2']);
      expect(r[2]['certificado'], isNull);
      expect(r[2]['clave_nube'], isNotEmpty);
    });

    test('todo equipo sale con id y clave_nube', () {
      final r =
          InventarioData.fusionarConExistentes([eq('A', ''), eq('B', '')], []);
      for (final e in r) {
        expect(e['id'], isNotEmpty);
        expect(e['clave_nube'], isNotEmpty);
      }
      expect(r[0]['id'], isNot(r[1]['id']));
    });
  });

  group('InventarioData.indexPorIdOCascada', () {
    test('clave_nube gana sobre un id desactualizado y una serie repetida', () {
      final lista = [
        {...eq('A', 'NO REGISTRA'), 'id': 'otro-1', 'clave_nube': 'k1'},
        {...eq('B', 'NO REGISTRA'), 'id': 'otro-2', 'clave_nube': 'k2'},
      ];
      // Solicitud vieja: id que ya no existe en la lista.
      final referencia = {
        ...eq('B', 'NO REGISTRA'),
        'id': 'id-viejo',
        'clave_nube': 'k2',
      };
      expect(InventarioData.indexPorIdOCascada(lista, referencia), 1);
    });
  });
}
