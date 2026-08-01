import 'package:flutter_test/flutter_test.dart';

import 'package:ishaqiyin_admin/models.dart';

void main() {
  test('parseDate handles ISO strings', () {
    final d = parseDate('2024-01-15T10:00:00.000Z');
    expect(d.year, 2024);
    expect(d.month, 1);
  });

  test('parseDate handles null', () {
    expect(parseDate(null).millisecondsSinceEpoch, 0);
  });
}
