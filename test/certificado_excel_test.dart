import 'dart:convert';
import 'dart:io';

import 'package:certificados_calibracion/data/certificado_excel.dart';
import 'package:certificados_calibracion/data/xlsx_plantilla.dart';
import 'package:flutter_test/flutter_test.dart';

/// Llena plantillas reales de assets/ y deja el resultado en
/// build/test_certificados/ para revisarlo a mano en Excel.
void main() {
  final salida = Directory('build/test_certificados')
    ..createSync(recursive: true);

  Map<String, dynamic> solicitudPara(String plantilla) {
    final config = jsonDecode(File('assets/plantillas/'
            '${plantilla.replaceAll('.xlsx', '.json')}')
        .readAsStringSync());
    final mediciones = <String, dynamic>{};
    var i = 0;
    for (final s in config['secciones']) {
      mediciones[s['titulo']] = [
        for (final pt in s['puntos'])
          {
            'nominal': pt['nominal'],
            'valor': '${pt['nominal']},${(i++) % 10}',
            'celda': pt['celda_lectura'],
            if (pt['celda_lectura_2'] != null) 'valor_2': '${pt['nominal']}',
            if (pt['celda_lectura_2'] != null) 'celda_2': pt['celda_lectura_2'],
          }
      ];
    }
    return {
      'plantilla': plantilla,
      'equipo': {
        'nombre': 'EQUIPO PRUEBA',
        'marca': 'MARCA X',
        'modelo': 'MOD-1',
        'serie': '0012345',
        'ubicacion': 'UCI',
        'inventario': 'INV-9',
      },
      'cliente': {
        'nombre': 'CLINICA DE PRUEBA',
        'nit': '900.000.000-1',
        'telefono': '3000000000',
        'direccion': 'CALLE 1 # 2-3',
        'ciudad': 'NEIVA',
      },
      'certificado': 'JS9999-26',
      'fecha': '2026-09-28',
      'mediciones': mediciones,
    };
  }

  test('desplazarFormula respeta \$ y comillas', () {
    expect(XlsxPlantilla.desplazarFormula(r'=A1+$B$2+C$3+"D4"+MEDIDA!E5', 2, 1),
        r'=B3+$B$2+D$3+"D4"+MEDIDA!F7');
    expect(XlsxPlantilla.desplazarFormula('LOG10(A1)', 1, 0), 'LOG10(A2)');
  });

  final plantillas = (jsonDecode(
          File('assets/plantillas/index.json').readAsStringSync()) as List)
      .cast<String>()
      .where((f) =>
          File('assets/plantillas/${f.replaceAll('.xlsx', '.json')}')
              .existsSync())
      .toList();

  for (final plantilla in plantillas) {
    test('llena $plantilla', () {
      final bytes = File('assets/plantillas/$plantilla').readAsBytesSync();
      final out = CertificadoExcel.llenar(bytes, solicitudPara(plantilla),
          tecnico: 'ING. PRUEBA');
      File('${salida.path}/$plantilla').writeAsBytesSync(out);

      final x = XlsxPlantilla.desdeBytes(out);
      final info = x.textos(x.nombresHojas.first);
      expect(info.values, contains('CLINICA DE PRUEBA'));
      expect(info.values, contains('JS9999-26'));
      expect(info.values, contains('MARCA X'));
    });
  }
}
