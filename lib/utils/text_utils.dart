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

  /// Normaliza un texto para usarlo en nombres de archivo:
  /// elimina tildes, reemplaza espacios por _ y quita caracteres especiales.
  static String normalizar(String texto) {
    texto = quitarTildes(texto);
    return texto
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '');
  }
}
