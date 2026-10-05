import 'package:certificados_calibracion/utils/text_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TextUtils.fechaIso', () {
    test('vacío o nulo → null (la solicitud usa la fecha de hoy)', () {
      expect(TextUtils.fechaIso(null), isNull);
      expect(TextUtils.fechaIso(''), isNull);
      expect(TextUtils.fechaIso('   '), isNull);
    });

    test('celda de fecha de Excel (ISO con hora)', () {
      expect(TextUtils.fechaIso('2026-08-15T00:00:00.000Z'), '2026-08-15');
    });

    test('texto ISO y día primero', () {
      expect(TextUtils.fechaIso('2026-8-5'), '2026-08-05');
      expect(TextUtils.fechaIso('15/08/2026'), '2026-08-15');
      expect(TextUtils.fechaIso('5-8-2026'), '2026-08-05');
      expect(TextUtils.fechaIso('05.08.2026'), '2026-08-05');
    });

    test('serial de Excel', () {
      expect(TextUtils.fechaIso('46249'), '2026-08-15');
      expect(TextUtils.fechaIso('46249.0'), '2026-08-15');
    });

    test('texto no reconocido o fecha imposible → null', () {
      expect(TextUtils.fechaIso('agosto'), isNull);
      expect(TextUtils.fechaIso('31/02/2026'), isNull);
      expect(TextUtils.fechaIso('2026-13-01'), isNull);
    });
  });
}
