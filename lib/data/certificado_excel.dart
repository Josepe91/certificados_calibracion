import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../utils/text_utils.dart';
import 'plantillas_initializer.dart';
import 'tecnico_profile.dart';
import 'xlsx_plantilla.dart';

/// Genera el certificado (.xlsx) de una solicitud: copia la plantilla
/// original del equipo y le escribe los datos, sin tocar nada más del
/// archivo (logo, gráficos, formato — ver [XlsxPlantilla]).
///
/// Dónde va cada dato:
/// - Mediciones → hoja `MEDIDA`, en las celdas `celda`/`celda_2` que ya
///   trae cada punto del JSON de la solicitud (las mismas `celda_lectura`
///   del .json de la plantilla). Un punto vacío NO se escribe: la celda
///   queda como está en la plantilla.
/// - Equipo, cliente, certificado, fechas y técnico → hoja `INFORMACIÓN`,
///   de la que `CERTIFICADO` toma todo por fórmula. Las celdas NO están
///   fijas: se ubican buscando las etiquetas ("Marca", "Solicitante:",
///   "Fecha de calibración:"…), porque no todas las plantillas tienen la
///   misma disposición (algunas empiezan en la fila 1, otras tienen
///   "Código interno" como primera columna, ORTHO WORKSTATION es de
///   etiqueta:valor en columnas). Si varias etiquetas están en la misma
///   fila es una fila de encabezados → el valor va debajo; si no, es
///   "etiqueta: valor" → el valor va a la derecha.
class CertificadoExcel {
  /// Genera `<misma ruta que el JSON>.xlsx` junto a la solicitud.
  /// Retorna null si la solicitud no tiene plantilla o la plantilla no
  /// está en el celular.
  static Future<File?> generarDesdeSolicitud(File archivoJson) async {
    final Map<String, dynamic> solicitud =
        jsonDecode(await archivoJson.readAsString());
    final plantilla = solicitud['plantilla']?.toString() ?? '';
    if (plantilla.isEmpty) return null;

    await PlantillasInitializer.inicializar();
    final archivoPlantilla =
        File(p.join(await PlantillasInitializer.rutaLocal, plantilla));
    if (!await archivoPlantilla.exists()) {
      debugPrint('CertificadoExcel: plantilla no encontrada "$plantilla"');
      return null;
    }

    final bytes = await archivoPlantilla.readAsBytes();
    final tecnico = await TecnicoProfile.obtenerNombre();
    // Descomprimir/parsear varias hojas XML toma un momento: fuera del
    // hilo de la UI para no congelar el diálogo "Guardando…".
    final resultado = await compute(_llenarEnIsolate, {
      'plantilla': bytes,
      'solicitud': solicitud,
      'tecnico': tecnico,
    });

    final destino = File(rutaCertificado(archivoJson.path));
    await destino.writeAsBytes(resultado, flush: true);
    return destino;
  }

  /// Ruta del .xlsx que corresponde a una solicitud `.json`.
  static String rutaCertificado(String rutaJson) =>
      rutaJson.replaceAll(RegExp(r'\.json$', caseSensitive: false), '.xlsx');

  static Uint8List _llenarEnIsolate(Map<String, Object> args) => llenar(
        args['plantilla'] as Uint8List,
        args['solicitud'] as Map<String, dynamic>,
        tecnico: args['tecnico'] as String,
      );

  /// Parte pura (sin archivos ni Flutter), para poder probarla directo.
  static Uint8List llenar(
    Uint8List plantilla,
    Map<String, dynamic> solicitud, {
    String tecnico = '',
  }) {
    final x = XlsxPlantilla.desdeBytes(plantilla);

    final hojaInfo = _buscarHoja(x, 'informacion') ?? x.nombresHojas.first;
    _llenarInformacion(x, hojaInfo, solicitud, tecnico);

    final hojaMedida = _buscarHoja(x, 'medida');
    final mediciones = solicitud['mediciones'];
    if (hojaMedida != null && mediciones is Map) {
      for (final puntos in mediciones.values) {
        if (puntos is! List) continue;
        for (final punto in puntos) {
          if (punto is! Map) continue;
          _escribirLectura(x, hojaMedida, punto['celda'], punto['valor']);
          _escribirLectura(x, hojaMedida, punto['celda_2'], punto['valor_2']);
        }
      }
    }

    return x.guardar();
  }

  // Etiqueta normalizada (ver _normalizar) → campo.
  static const Map<String, String> _etiquetas = {
    'instrumento': 'nombre',
    'intrumento': 'nombre', // así está escrito en la mayoría de plantillas
    'nombre del item': 'nombre',
    'marca': 'marca',
    'modelo': 'modelo',
    'serie': 'serie',
    'ubicacion': 'ubicacion',
    'ubicacion del equipo': 'ubicacion',
    'inventario': 'inventario',
    'codigo interno': 'inventario',
    'numero de certificado': 'certificado',
    'certificado n': 'certificado',
    'fecha de recepcion': 'fecha_recepcion',
    'solicitante': 'cliente',
    'nit': 'nit',
    'telefono': 'telefono',
    'direccion': 'direccion',
    'ciudad': 'ciudad',
    'fecha de calibracion': 'fecha_calibracion',
    'fecha de emision': 'fecha_emision',
    'calibracion realiza por': 'tecnico',
    'calibracion realizada por': 'tecnico',
  };

  static void _llenarInformacion(XlsxPlantilla x, String hoja,
      Map<String, dynamic> solicitud, String tecnico) {
    final equipo = (solicitud['equipo'] as Map?) ?? const {};
    final cliente = (solicitud['cliente'] as Map?) ?? const {};
    String txt(Object? v) => v?.toString().trim() ?? '';

    final fechaTexto = txt(solicitud['fecha']);
    final Object fecha = DateTime.tryParse(fechaTexto) ?? fechaTexto;

    final valores = <String, Object>{
      'nombre': txt(equipo['nombre']),
      'marca': txt(equipo['marca']),
      'modelo': txt(equipo['modelo']),
      'serie': txt(equipo['serie']),
      'ubicacion': txt(equipo['ubicacion']),
      'inventario': txt(equipo['inventario']),
      'certificado': txt(solicitud['certificado']),
      'fecha_recepcion': fecha,
      'fecha_calibracion': fecha,
      'fecha_emision': fecha,
      'cliente': txt(cliente['nombre']),
      'nit': txt(cliente['nit']),
      'telefono': txt(cliente['telefono']),
      'direccion': txt(cliente['direccion']),
      'ciudad': txt(cliente['ciudad']),
      'tecnico': tecnico.trim(),
    };

    // Etiquetas encontradas, en orden de lectura (fila, columna).
    final encontradas = <({String campo, int col, int fila})>[];
    x.textos(hoja).forEach((ref, texto) {
      final campo = _etiquetas[_normalizar(texto)];
      if (campo == null) return;
      final m = RegExp(r'^([A-Z]+)(\d+)$').firstMatch(ref)!;
      encontradas.add(
          (campo: campo, col: _col(m[1]!), fila: int.parse(m[2]!)));
    });
    encontradas.sort((a, b) =>
        a.fila != b.fila ? a.fila - b.fila : a.col - b.col);

    final porFila = <int, int>{};
    for (final e in encontradas) {
      porFila[e.fila] = (porFila[e.fila] ?? 0) + 1;
    }

    final escritos = <String>{};
    for (final e in encontradas) {
      if (!escritos.add(e.campo)) continue; // solo la primera aparición
      final valor = valores[e.campo];
      if (valor == null || (valor is String && valor.isEmpty)) continue;
      final esEncabezado = (porFila[e.fila] ?? 0) >= 4;
      final destino = esEncabezado
          ? '${_letra(e.col)}${e.fila + 1}'
          : '${_letra(e.col + 1)}${e.fila}';
      x.escribir(hoja, destino, valor);
    }
  }

  static void _escribirLectura(
      XlsxPlantilla x, String hoja, Object? celda, Object? valor) {
    final ref = celda?.toString().trim() ?? '';
    final texto = valor?.toString().trim() ?? '';
    if (ref.isEmpty || texto.isEmpty) return;
    // Los técnicos escriben con coma decimal ("2,5") — ver CLAUDE.md. Se
    // guarda como número para que las fórmulas de la plantilla lo usen.
    final numero = double.tryParse(texto.replaceAll(',', '.'));
    x.escribir(hoja, ref, numero ?? texto);
  }

  static String? _buscarHoja(XlsxPlantilla x, String nombreNormalizado) {
    for (final h in x.nombresHojas) {
      if (_normalizar(h) == nombreNormalizado) return h;
    }
    return null;
  }

  static String _normalizar(String s) => TextUtils.quitarTildes(s)
      .toLowerCase()
      .replaceAll(RegExp(r'[:°º.]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static int _col(String letras) {
    var n = 0;
    for (final u in letras.codeUnits) {
      n = n * 26 + (u - 64);
    }
    return n;
  }

  static String _letra(int n) {
    var s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }
}
