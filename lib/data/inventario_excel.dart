import 'dart:typed_data';

import 'package:excel/excel.dart';

/// Arma el Excel de inventario de un cliente a partir del JSON local
/// (`{cliente: {...}, equipos: [...]}`, el mismo que escribe
/// `InventarioData._guardar`).
///
/// Usa EXACTAMENTE el formato que importa `InventarioPage._cargarExcel`
/// (columnas A–H de equipo, datos del cliente en K–O de la fila 2), así
/// el archivo exportado se puede volver a importar tal cual. Las columnas
/// I–J (Observaciones, Estado) y P en adelante las ignora la importación:
/// son solo para quien lee el archivo en la oficina.
///
/// Acá sí se usa el paquete `excel` (a diferencia de los certificados,
/// ver `XlsxPlantilla`): es un libro nuevo, no hay formato original que
/// conservar.
class InventarioExcel {
  static const _encabezados = [
    'Nombre',
    'Marca',
    'Modelo',
    'Serie',
    'Ubicación',
    'Inventario',
    'Certificado',
    'Fecha',
    'Observaciones',
    'Estado',
    'Cliente',
    'NIT',
    'Teléfono',
    'Dirección',
    'Ciudad',
  ];

  static Uint8List generar(Map<String, dynamic> data) {
    final cliente = (data['cliente'] as Map?) ?? const {};
    final equipos = ((data['equipos'] as List?) ?? const [])
        .whereType<Map>()
        .toList();

    final excel = Excel.createExcel();
    final nombreHoja = excel.getDefaultSheet() ?? 'Sheet1';
    excel.rename(nombreHoja, 'Inventario');
    final hoja = excel['Inventario'];

    final estiloEncabezado = CellStyle(
      bold: true,
      backgroundColorHex: ExcelColor.fromHexString('#D9E1F2'),
    );
    void celda(int col, int fila, String valor, {CellStyle? estilo}) {
      hoja.updateCell(
        CellIndex.indexByColumnRow(columnIndex: col, rowIndex: fila),
        TextCellValue(valor),
        cellStyle: estilo,
      );
    }

    for (var c = 0; c < _encabezados.length; c++) {
      celda(c, 0, _encabezados[c], estilo: estiloEncabezado);
    }

    String txt(Object? v) => v?.toString().trim() ?? '';

    // Datos del cliente: fila 2 (índice 1), columnas K–O — donde los lee
    // la importación.
    celda(10, 1, txt(cliente['nombre']));
    celda(11, 1, txt(cliente['nit']));
    celda(12, 1, txt(cliente['telefono']));
    celda(13, 1, txt(cliente['direccion']));
    celda(14, 1, txt(cliente['ciudad']));

    // Mismo orden en que se importaron (campo `orden`), no el orden en que
    // llegaron las ediciones de la nube.
    equipos.sort((a, b) {
      final oa = (a['orden'] as num?) ?? 1 << 30;
      final ob = (b['orden'] as num?) ?? 1 << 30;
      return oa.compareTo(ob);
    });

    for (var i = 0; i < equipos.length; i++) {
      final e = equipos[i];
      final fila = i + 1;
      celda(0, fila, txt(e['nombre']));
      celda(1, fila, txt(e['marca']));
      celda(2, fila, txt(e['modelo']));
      celda(3, fila, txt(e['serie']));
      celda(4, fila, txt(e['ubicacion']));
      celda(5, fila, txt(e['inventario']));
      celda(6, fila, txt(e['certificado']));
      celda(7, fila, txt(e['fecha']));
      celda(8, fila, txt(e['observaciones']));
      celda(9, fila, _estado(e));
    }

    const anchos = [28.0, 18, 18, 18, 22, 16, 16, 12, 36, 34, 30, 16, 14, 30, 16];
    for (var c = 0; c < anchos.length; c++) {
      hoja.setColumnWidth(c, anchos[c].toDouble());
    }

    return Uint8List.fromList(excel.encode()!);
  }

  static String _estado(Map e) {
    String txt(Object? v) => v?.toString().trim() ?? '';
    if (e['fuera_de_servicio'] == true) {
      final por = txt(e['fuera_de_servicio_por']);
      return por.isEmpty ? 'FUERA DE SERVICIO' : 'FUERA DE SERVICIO ($por)';
    }
    if (e['no_pasa_calibracion'] == true) {
      final detalle = txt(e['no_pasa_calibracion_detalle']);
      return detalle.isEmpty
          ? 'NO PASA CALIBRACIÓN'
          : 'NO PASA CALIBRACIÓN: $detalle';
    }
    if (txt(e['certificado']).isNotEmpty) return 'CALIBRADO';
    return 'PENDIENTE';
  }
}
