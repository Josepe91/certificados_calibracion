class TextUtils {
  static const Map<String, String> _mapaTildes = {
    'á': 'a',
    'é': 'e',
    'í': 'i',
    'ó': 'o',
    'ú': 'u',
    'ü': 'u',
    'Á': 'A',
    'É': 'E',
    'Í': 'I',
    'Ó': 'O',
    'Ú': 'U',
    'Ü': 'U',
    'ñ': 'n',
    'Ñ': 'N',
  };

  /// Quita tildes/diéresis (y ñ→n) de un texto, sin tocar may/minúsculas,
  /// espacios ni ningún otro carácter. Para usar en buscadores — que
  /// escribir "camara" encuentre "cámara" — combinado con `.toLowerCase()`
  /// en el punto de comparación.
  static String quitarTildes(String texto) {
    _mapaTildes.forEach((k, v) => texto = texto.replaceAll(k, v));
    return texto;
  }

  /// Convierte una fecha leída del Excel de inventario a `yyyy-MM-dd`
  /// (el formato que usa el campo fecha de la solicitud). Acepta:
  ///   - celda de fecha de Excel → "2026-08-15T00:00:00.000Z"
  ///   - texto ISO "2026-08-15" o día primero "15/08/2026", "15-8-2026"
  ///   - serial de Excel sin formato de fecha → "46249" / "46249.0"
  /// Devuelve null si el texto está vacío o no se reconoce como fecha.
  static String? fechaIso(String? texto) {
    final s = texto?.trim() ?? '';
    if (s.isEmpty) return null;

    DateTime? fecha;
    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(s);
    final diaPrimero =
        RegExp(r'^(\d{1,2})[/\-.](\d{1,2})[/\-.](\d{4})$').firstMatch(s);
    final serial = double.tryParse(s);
    if (iso != null) {
      fecha = _fechaValida(int.parse(iso[1]!), int.parse(iso[2]!),
          int.parse(iso[3]!));
    } else if (diaPrimero != null) {
      fecha = _fechaValida(int.parse(diaPrimero[3]!),
          int.parse(diaPrimero[2]!), int.parse(diaPrimero[1]!));
    } else if (serial != null && serial >= 1 && serial < 100000) {
      // Serial de Excel: días desde 1899-12-30.
      fecha = DateTime.utc(1899, 12, 30).add(Duration(days: serial.floor()));
    }
    if (fecha == null) return null;
    return '${fecha.year}-${fecha.month.toString().padLeft(2, '0')}-'
        '${fecha.day.toString().padLeft(2, '0')}';
  }

  static DateTime? _fechaValida(int anio, int mes, int dia) {
    final f = DateTime.utc(anio, mes, dia);
    // DateTime desborda días/meses inválidos (31/02 → 03/03): se rechazan.
    if (f.year != anio || f.month != mes || f.day != dia) return null;
    return f;
  }

  /// Normaliza un texto para usarlo en nombres de archivo:
  /// elimina tildes, reemplaza espacios por _ y quita caracteres especiales.
  static String normalizar(String texto) {
    texto = quitarTildes(texto);
    return texto
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
  }
}
