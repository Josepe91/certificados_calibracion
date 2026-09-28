import 'dart:io';

import 'package:certificados_calibracion/data/inventario_excel.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('el Excel exportado se lee con las mismas columnas que la importación',
      () {
    final bytes = InventarioExcel.generar({
      'cliente': {
        'nombre': 'CLÍNICA X',
        'nit': '900-1',
        'telefono': '300',
        'direccion': 'CALLE 1',
        'ciudad': 'NEIVA',
      },
      'equipos': [
        {'nombre': 'B', 'serie': '002', 'orden': 1, 'fuera_de_servicio': true,
         'fuera_de_servicio_por': 'Gabriel', 'observaciones': 'No enciende'},
        {'nombre': 'A', 'serie': '001', 'orden': 0, 'certificado': 'JS1-26',
         'fecha': '2026-09-28'},
      ],
    });
    Directory('build/test_certificados').createSync(recursive: true);
    File('build/test_certificados/INVENTARIO_prueba.xlsx')
        .writeAsBytesSync(bytes);

    final sheet = Excel.decodeBytes(bytes).tables.values.first;
    final r0 = sheet.row(0), r1 = sheet.row(1), r2 = sheet.row(2);
    expect(r0[4]?.value.toString(), 'Ubicación');
    expect(r1[10]?.value.toString(), 'CLÍNICA X'); // cliente en K2
    expect(r1[14]?.value.toString(), 'NEIVA');
    expect(r1[0]?.value.toString(), 'A'); // ordenado por 'orden'
    expect(r1[6]?.value.toString(), 'JS1-26');
    expect(r1[9]?.value.toString(), 'CALIBRADO');
    expect(r2[9]?.value.toString(), 'FUERA DE SERVICIO (Gabriel)');
    expect(r2[8]?.value.toString(), 'No enciende');
  });
}
