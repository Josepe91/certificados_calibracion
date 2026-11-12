import 'package:certificados_calibracion/data/certificado_excel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('certificado + equipo + serie, con tildes y espacios', () {
    expect(
      CertificadoExcel.nombreOficina({
        'certificado': 'JS11260-26',
        'equipo': {'nombre': 'VENTILADOR MECÁNICO', 'serie': 'VG70(U)XZZS33267'},
      }),
      'JS11260-26 VENTILADOR MECÁNICO VG70(U)XZZS33267',
    );
  });

  test('caracteres que Windows no acepta pasan a _', () {
    expect(
      CertificadoExcel.nombreOficina({
        'certificado': 'JS11264-26',
        'equipo': {'nombre': 'LÁMPARA CIELÍTICA', 'serie': '20/15081'},
      }),
      'JS11264-26 LÁMPARA CIELÍTICA 20_15081',
    );
  });

  test('sin serie usa el inventario; sin ninguno, solo cert + equipo', () {
    expect(
      CertificadoExcel.nombreOficina({
        'certificado': 'JS1-26',
        'equipo': {'nombre': 'BÁSCULA', 'serie': 'NO REGISTRA', 'inventario': '15320000425'},
      }),
      'JS1-26 BÁSCULA 15320000425',
    );
    expect(
      CertificadoExcel.nombreOficina({
        'certificado': 'JS2-26',
        'equipo': {'nombre': 'TENSIÓMETRO', 'serie': '', 'inventario': 'NO REGISTRA'},
      }),
      'JS2-26 TENSIÓMETRO',
    );
  });
}
