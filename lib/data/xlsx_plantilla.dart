import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Edita celdas de un .xlsx existente tocando SOLO el XML de esas celdas.
///
/// Por qué no se usa el paquete `excel` para esto: al guardar, `excel`
/// reconstruye el libro desde cero y pierde imágenes (logo, firmas),
/// gráficos, encabezados/pies de página, configuración de impresión y
/// vínculos — justo lo que las plantillas de certificados necesitan
/// conservar. Acá el .xlsx se trata como el ZIP que es: todos los archivos
/// internos se copian byte a byte, y solo se reescriben las hojas en las
/// que se escribió algo (+ workbook.xml para forzar el recálculo).
///
/// Detalles que importan (cada uno rompía el archivo o dejaba datos
/// viejos visibles si se omitía):
/// - El estilo de la celda (`s="…"`) se conserva siempre: la celda queda
///   con el mismo formato (fecha, decimales, bordes) que en la plantilla.
/// - Si la celda era la "maestra" de una fórmula compartida
///   (`<f t="shared" ref="…" si="N">`), las demás celdas del grupo solo
///   guardan `si="N"` sin texto; al pisar la maestra se quedarían sin
///   fórmula. Antes de escribir se "expanden": cada una recibe su propia
///   fórmula traducida a su posición.
/// - Se borran los valores en caché de TODAS las fórmulas del libro y se
///   activa `fullCalcOnLoad`: así Excel recalcula al abrir, y un visor que
///   no calcula (vista previa del celular) muestra la celda vacía en vez
///   del dato del cliente/equipo que traía la plantilla de ejemplo.
/// - Se elimina `calcChain.xml`: lista las celdas con fórmula, y al
///   reemplazar una fórmula por un valor quedaría desactualizado (Excel
///   lo reporta como archivo dañado). Excel lo regenera solo.
class XlsxPlantilla {
  XlsxPlantilla._(this._archivo, this._rutasHojas, this._compartidos);

  final Archive _archivo;
  final Map<String, String> _rutasHojas; // nombre de hoja → ruta en el zip
  final List<String> _compartidos; // sharedStrings.xml, por índice
  final Map<String, XmlDocument> _hojasEditadas = {};

  factory XlsxPlantilla.desdeBytes(List<int> bytes) {
    final archivo = ZipDecoder().decodeBytes(bytes);

    final workbook = _parsear(archivo, 'xl/workbook.xml')!;
    final rels = _parsear(archivo, 'xl/_rels/workbook.xml.rels')!;

    final destinos = <String, String>{};
    for (final r in _hijos(rels.rootElement, 'Relationship')) {
      destinos[r.getAttribute('Id') ?? ''] = r.getAttribute('Target') ?? '';
    }

    final rutasHojas = <String, String>{};
    for (final hoja in workbook.rootElement.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'sheet')) {
      final nombre = hoja.getAttribute('name') ?? '';
      // r:id — se busca por nombre local + prefijo en vez de por URI de
      // namespace para no depender de cómo el generador nombró el prefijo.
      final rid = hoja.attributes
              .where((a) => a.name.local == 'id' && a.name.prefix != null)
              .firstOrNull
              ?.value ??
          '';
      final destino = destinos[rid];
      if (destino == null) continue;
      rutasHojas[nombre] = destino.startsWith('/')
          ? destino.substring(1)
          : 'xl/$destino';
    }

    final compartidos = <String>[];
    final ss = _parsear(archivo, 'xl/sharedStrings.xml');
    if (ss != null) {
      for (final si in _hijos(ss.rootElement, 'si')) {
        compartidos.add(_textoDe(si));
      }
    }

    return XlsxPlantilla._(archivo, rutasHojas, compartidos);
  }

  List<String> get nombresHojas => _rutasHojas.keys.toList();

  /// Texto visible de cada celda no vacía de [hoja] (`"B7" → "Nit:"`).
  /// Para fórmulas devuelve el resultado en caché, no la fórmula.
  Map<String, String> textos(String hoja) {
    final doc = _hoja(hoja);
    final res = <String, String>{};
    for (final c in doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'c')) {
      final ref = c.getAttribute('r');
      if (ref == null) continue;
      final tipo = c.getAttribute('t');
      String? texto;
      if (tipo == 'inlineStr') {
        final is_ = _hijo(c, 'is');
        if (is_ != null) texto = _textoDe(is_);
      } else {
        final v = _hijo(c, 'v')?.innerText;
        if (v != null) {
          if (tipo == 's') {
            final i = int.tryParse(v);
            texto = (i != null && i < _compartidos.length)
                ? _compartidos[i]
                : null;
          } else {
            texto = v;
          }
        }
      }
      if (texto != null && texto.isNotEmpty) res[ref] = texto;
    }
    return res;
  }

  /// Escribe [valor] en la celda [ref] (ej. "D7") de [hoja], conservando
  /// el estilo de la celda. `num` y `DateTime` se guardan como número
  /// (la fecha como serial de Excel, así el formato de fecha de la
  /// plantilla la muestra bien); cualquier otra cosa, como texto.
  void escribir(String hoja, String ref, Object valor) {
    final doc = _hoja(hoja);
    final sheetData = doc.descendants
        .whereType<XmlElement>()
        .firstWhere((e) => e.name.local == 'sheetData');
    final prefijo = sheetData.name.prefix;
    XmlName nombre(String local) => XmlName(local, prefijo);

    final (col, fila) = _parsearRef(ref);

    // Fila: buscarla o insertarla en orden.
    final filas = _hijos(sheetData, 'row').toList();
    XmlElement? row;
    XmlElement? filaSiguiente;
    for (final r in filas) {
      final n = int.tryParse(r.getAttribute('r') ?? '') ?? 0;
      if (n == fila) {
        row = r;
        break;
      }
      if (n > fila) {
        filaSiguiente = r;
        break;
      }
    }
    if (row == null) {
      row = XmlElement(nombre('row'), [XmlAttribute(XmlName('r'), '$fila')]);
      if (filaSiguiente != null) {
        sheetData.children
            .insert(sheetData.children.indexOf(filaSiguiente), row);
      } else {
        sheetData.children.add(row);
      }
    }

    // Celda: buscarla o insertarla en orden de columna.
    XmlElement? celda;
    XmlElement? celdaSiguiente;
    for (final c in _hijos(row, 'c')) {
      final r = c.getAttribute('r');
      if (r == null) continue;
      final (cc, _) = _parsearRef(r);
      if (cc == col) {
        celda = c;
        break;
      }
      if (cc > col) {
        celdaSiguiente = c;
        break;
      }
    }
    if (celda == null) {
      celda = XmlElement(nombre('c'), [XmlAttribute(XmlName('r'), ref)]);
      if (celdaSiguiente != null) {
        row.children.insert(row.children.indexOf(celdaSiguiente), celda);
      } else {
        row.children.add(celda);
      }
    }

    final f = _hijo(celda, 'f');
    if (f != null &&
        f.getAttribute('t') == 'shared' &&
        f.getAttribute('ref') != null) {
      _expandirCompartida(sheetData, f.getAttribute('si') ?? '', ref,
          f.innerText);
    }

    celda.children.removeWhere((n) =>
        n is XmlElement &&
        (n.name.local == 'f' || n.name.local == 'v' || n.name.local == 'is'));
    celda.removeAttribute('t');

    if (valor is DateTime) {
      valor = _serialExcel(valor);
    }
    if (valor is num) {
      celda.children.add(XmlElement(nombre('v'), [], [XmlText(_numero(valor))]));
    } else {
      final texto = valor.toString();
      celda.setAttribute('t', 'inlineStr');
      final t = XmlElement(nombre('t'), [], [XmlText(texto)]);
      if (texto.trim() != texto) {
        t.attributes.add(XmlAttribute(XmlName('space', 'xml'), 'preserve'));
      }
      celda.children.add(XmlElement(nombre('is'), [], [t]));
    }
  }

  /// Arma el .xlsx final. Los archivos internos no tocados se copian tal
  /// cual (imágenes, gráficos, estilos, impresión…).
  Uint8List guardar() {
    // Todas las hojas pasan por acá (no solo las editadas) para quitar
    // los valores en caché de sus fórmulas — ver doc de la clase.
    for (final nombre in _rutasHojas.keys) {
      final doc = _hoja(nombre);
      for (final c in doc.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == 'c')
          .toList()) {
        if (_hijo(c, 'f') == null) continue;
        c.children
            .removeWhere((n) => n is XmlElement && n.name.local == 'v');
        c.removeAttribute('t');
      }
    }

    final reemplazos = <String, List<int>>{};
    for (final e in _hojasEditadas.entries) {
      reemplazos[_rutasHojas[e.key]!] = utf8.encode(e.value.toXmlString());
    }

    final workbook = _parsear(_archivo, 'xl/workbook.xml')!;
    _activarRecalculo(workbook.rootElement);
    reemplazos['xl/workbook.xml'] = utf8.encode(workbook.toXmlString());

    // calcChain fuera: archivo, relación y content-type.
    const calcChain = 'xl/calcChain.xml';
    final rels = _parsear(_archivo, 'xl/_rels/workbook.xml.rels')!;
    rels.rootElement.children.removeWhere((n) =>
        n is XmlElement &&
        (n.getAttribute('Type') ?? '').endsWith('/calcChain'));
    reemplazos['xl/_rels/workbook.xml.rels'] =
        utf8.encode(rels.toXmlString());
    final tipos = _parsear(_archivo, '[Content_Types].xml')!;
    tipos.rootElement.children.removeWhere((n) =>
        n is XmlElement && n.getAttribute('PartName') == '/$calcChain');
    reemplazos['[Content_Types].xml'] = utf8.encode(tipos.toXmlString());

    final salida = Archive();
    for (final f in _archivo.files) {
      if (!f.isFile || f.name == calcChain) continue;
      final bytes = reemplazos[f.name] ?? f.content as List<int>;
      salida.addFile(ArchiveFile(f.name, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(salida)!);
  }

  // ------------------------------------------------------------------

  XmlDocument _hoja(String nombre) {
    final existente = _hojasEditadas[nombre];
    if (existente != null) return existente;
    final ruta = _rutasHojas[nombre];
    if (ruta == null) throw ArgumentError('La hoja "$nombre" no existe');
    final doc = _parsear(_archivo, ruta)!;
    _hojasEditadas[nombre] = doc;
    return doc;
  }

  void _expandirCompartida(
      XmlElement sheetData, String si, String refMaestra, String formula) {
    final (colM, filaM) = _parsearRef(refMaestra);
    for (final c in sheetData.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'c')) {
      final f = _hijo(c, 'f');
      if (f == null ||
          f.getAttribute('t') != 'shared' ||
          f.getAttribute('si') != si) {
        continue;
      }
      final ref = c.getAttribute('r');
      if (ref == null || ref == refMaestra) continue;
      final (col, fila) = _parsearRef(ref);
      final traducida = desplazarFormula(formula, fila - filaM, col - colM);
      f.attributes.clear();
      f.children
        ..clear()
        ..add(XmlText(traducida));
    }
  }

  static void _activarRecalculo(XmlElement workbook) {
    var calcPr = _hijo(workbook, 'calcPr');
    if (calcPr == null) {
      calcPr = XmlElement(XmlName('calcPr', workbook.name.prefix));
      // Orden del esquema: calcPr va antes de estos elementos.
      const despues = {
        'oleSize', 'customWorkbookViews', 'pivotCaches', 'smartTagPr',
        'smartTagTypes', 'webPublishing', 'fileRecoveryPr',
        'webPublishObjects', 'extLst',
      };
      final siguiente = workbook.children.whereType<XmlElement>().where(
          (e) => despues.contains(e.name.local));
      if (siguiente.isEmpty) {
        workbook.children.add(calcPr);
      } else {
        workbook.children
            .insert(workbook.children.indexOf(siguiente.first), calcPr);
      }
    }
    calcPr.setAttribute('fullCalcOnLoad', '1');
  }

  /// Traduce las referencias relativas de [formula] como si se copiara
  /// [dFilas] filas abajo y [dCols] columnas a la derecha (lo que hace
  /// Excel con una fórmula compartida). Respeta `$` y no toca texto entre
  /// comillas ni nombres de hoja entre apóstrofos.
  static String desplazarFormula(String formula, int dFilas, int dCols) {
    final refRe = RegExp(
        r'(?<![A-Za-z0-9_.])(\$?)([A-Z]{1,3})(\$?)(\d+)(?![A-Za-z0-9_(])');
    final sb = StringBuffer();
    var i = 0;
    while (i < formula.length) {
      final ch = formula[i];
      if (ch == '"' || ch == "'") {
        final fin = formula.indexOf(ch, i + 1);
        final hasta = fin < 0 ? formula.length : fin + 1;
        sb.write(formula.substring(i, hasta));
        i = hasta;
        continue;
      }
      var fin = i;
      while (fin < formula.length &&
          formula[fin] != '"' &&
          formula[fin] != "'") {
        fin++;
      }
      sb.write(formula.substring(i, fin).replaceAllMapped(refRe, (m) {
        final colAbs = m[1]!.isNotEmpty;
        final filaAbs = m[3]!.isNotEmpty;
        var col = _colANumero(m[2]!);
        var fila = int.parse(m[4]!);
        if (!colAbs) col += dCols;
        if (!filaAbs) fila += dFilas;
        if (col < 1 || fila < 1) return '#REF!';
        return '${m[1]}${_numeroACol(col)}${m[3]}$fila';
      }));
      i = fin;
    }
    return sb.toString();
  }

  static XmlDocument? _parsear(Archive archivo, String ruta) {
    final f = archivo.findFile(ruta);
    if (f == null) return null;
    return XmlDocument.parse(utf8.decode(f.content as List<int>));
  }

  static Iterable<XmlElement> _hijos(XmlElement e, String local) =>
      e.children.whereType<XmlElement>().where((c) => c.name.local == local);

  static XmlElement? _hijo(XmlElement e, String local) {
    for (final c in _hijos(e, local)) {
      return c;
    }
    return null;
  }

  /// Texto de un `<si>`/`<is>`: concatena los `<t>` (texto enriquecido),
  /// ignorando la guía fonética (`<rPh>`).
  static String _textoDe(XmlElement e) {
    final sb = StringBuffer();
    void visitar(XmlElement n) {
      for (final c in n.children.whereType<XmlElement>()) {
        if (c.name.local == 'rPh') continue;
        if (c.name.local == 't') {
          sb.write(c.innerText);
        } else {
          visitar(c);
        }
      }
    }

    visitar(e);
    return sb.toString();
  }

  static (int, int) _parsearRef(String ref) {
    final m = RegExp(r'^\$?([A-Za-z]+)\$?(\d+)$').firstMatch(ref.trim());
    if (m == null) throw ArgumentError('Referencia de celda inválida: $ref');
    return (_colANumero(m[1]!.toUpperCase()), int.parse(m[2]!));
  }

  static int _colANumero(String letras) {
    var n = 0;
    for (final u in letras.codeUnits) {
      n = n * 26 + (u - 64);
    }
    return n;
  }

  static String _numeroACol(int n) {
    var s = '';
    while (n > 0) {
      final r = (n - 1) % 26;
      s = String.fromCharCode(65 + r) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  static double _serialExcel(DateTime fecha) {
    final base = DateTime.utc(1899, 12, 30);
    final d = DateTime.utc(fecha.year, fecha.month, fecha.day);
    return d.difference(base).inDays.toDouble();
  }

  static String _numero(num n) {
    if (n is double && n == n.roundToDouble() && n.abs() < 1e15) {
      return n.toInt().toString();
    }
    return n.toString();
  }
}
