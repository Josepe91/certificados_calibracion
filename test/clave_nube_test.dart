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

  group('Series repetidas y NO REGISTRA (La Magdalena 2026-11-25)', () {
    Map<String, dynamic> f(String serie, String inv,
            {String cert = '', String ubic = 'UCI', String clave = ''}) =>
        {
          'nombre': 'FLUJÓMETRO DOBLE',
          'marca': 'GENTEC',
          'modelo': 'FM197B',
          'serie': serie,
          'inventario': inv,
          'ubicacion': ubic,
          if (cert.isNotEmpty) 'certificado': cert,
          if (clave.isNotEmpty) 'clave_nube': clave,
        };

    test('misma serie con distinto inventario no se cruza al cambiar el orden',
        () {
      final previos = [
        f('F01241', '180099', cert: 'JS1', clave: 'k1'),
        f('F01241', 'NO REGISTRA', cert: 'JS2', clave: 'k2'),
        f('F01241', '180115', cert: 'JS3', clave: 'k3'),
      ];
      // El Excel nuevo viene en otro orden y sin certificados.
      final r = InventarioData.fusionarConExistentes([
        f('F01241', '180115'),
        f('F01241', 'NO REGISTRA'),
        f('F01241', '180099'),
      ], previos);
      expect(r.map((e) => e['clave_nube']), ['k3', 'k2', 'k1']);
      expect(r.map((e) => e['certificado']), ['JS3', 'JS2', 'JS1']);
    });

    test('inventario cambiado a NO REGISTRA sigue emparejando por certificado',
        () {
      final previos = [
        {...f('FP5-65031574', '50950', cert: 'JS14503-26', clave: 'k1'),
          'nombre': 'DESFIBRILADOR'},
        {...f('FP5-65031690', '50951', cert: 'JS14589-26', clave: 'k2'),
          'nombre': 'DESFIBRILADOR'},
      ];
      final r = InventarioData.fusionarConExistentes([
        {...f('FP5-65031690', '50951', cert: 'JS14589-26'),
          'nombre': 'DESFIBRILADOR'},
        {...f('FP5-65031574', 'NO REGISTRA', cert: 'JS14503-26'),
          'nombre': 'DESFIBRILADOR'},
      ], previos);
      expect(r.map((e) => e['clave_nube']), ['k2', 'k1']);
    });

    test('el certificado de otra fila del Excel no se hereda (se limpia)', () {
      // En la nube el certificado JS2 quedó cruzado en el equipo k1.
      final previos = [
        f('F04091', '170001', cert: 'JS2', clave: 'k1'),
        f('F04091', '170002', clave: 'k2'),
      ];
      final r = InventarioData.fusionarConExistentes([
        f('F04091', '170001'),
        f('F04091', '170002', cert: 'JS2'),
      ], previos);
      expect(r[0]['clave_nube'], 'k1');
      expect(r[0]['certificado'], '');
      expect(r[0]['limpiar_certificado'], true);
      expect(r[1]['clave_nube'], 'k2');
      expect(r[1]['certificado'], 'JS2');
    });

    test('serie repetida sin más datos que la distingan no se adivina', () {
      final previos = [
        f('J07I11', 'NO REGISTRA', ubic: 'URGENCIAS', cert: 'JS5', clave: 'k1'),
        f('J07I11', 'NO REGISTRA', ubic: 'UCI', cert: 'JS6', clave: 'k2'),
      ];
      // Las dos filas nuevas cambiaron de ubicación: no hay cómo saber
      // cuál es cuál, así que ninguna hereda certificado ajeno.
      final r = InventarioData.fusionarConExistentes([
        f('J07I11', 'NO REGISTRA', ubic: 'PISO 2'),
        f('J07I11', 'NO REGISTRA', ubic: 'PISO 3'),
      ], previos);
      expect(r.map((e) => e['certificado']), [null, null]);
    });

    test('rellenos cuentan como vacíos', () {
      for (final t in ['NO REGISTRA', 'n/a', 'S/N', ' - ', '0', 'N.A.', '']) {
        expect(InventarioData.valorParaEmparejar({'serie': t}, 'serie'), '',
            reason: t);
      }
      expect(InventarioData.valorParaEmparejar({'serie': ' f01241 '}, 'serie'),
          'F01241');
    });

    test('indexPorIdOCascada no cae en el primer NO REGISTRA', () {
      final lista = [
        {...f('NO REGISTRA', 'NO REGISTRA'), 'nombre': 'TENSIÓMETRO'},
        {...f('NO REGISTRA', '170339'), 'nombre': 'TENSIÓMETRO'},
      ];
      final ref = {...f('NO REGISTRA', '170339'), 'nombre': 'TENSIÓMETRO'};
      expect(InventarioData.indexPorIdOCascada(lista, ref), 1);
      final ambiguo = [
        f('F01241', '1'),
        f('F01241', '2'),
      ];
      expect(InventarioData.indexPorIdOCascada(ambiguo, f('F01241', '')), -1);
    });
  });
}
