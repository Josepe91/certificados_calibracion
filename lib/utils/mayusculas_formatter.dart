import 'package:flutter/services.dart';

/// Convierte a MAYÚSCULAS todo lo que se escribe o pega en un campo.
///
/// Los certificados y el inventario van en mayúsculas; forzarlo al
/// escribir evita que un mismo dato quede "Clínica x" en un celular y
/// "CLÍNICA X" en otro. Va junto con
/// `textCapitalization: TextCapitalization.characters`, que solo hace que
/// el teclado arranque en mayúsculas: sin este formatter, el técnico
/// igual podía cambiar a minúsculas o pegar texto en minúsculas.
///
/// Uso: `inputFormatters: MayusculasFormatter.lista` +
/// `textCapitalization: TextCapitalization.characters`.
class MayusculasFormatter extends TextInputFormatter {
  const MayusculasFormatter();

  static const List<TextInputFormatter> lista = [MayusculasFormatter()];

  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    final mayus = newValue.text.toUpperCase();
    if (mayus == newValue.text) return newValue;
    // toUpperCase puede cambiar el largo en casos raros (ß → SS); si pasa,
    // el cursor va al final para no quedar fuera de rango.
    if (mayus.length != newValue.text.length) {
      return TextEditingValue(
        text: mayus,
        selection: TextSelection.collapsed(offset: mayus.length),
      );
    }
    return newValue.copyWith(text: mayus);
  }
}
