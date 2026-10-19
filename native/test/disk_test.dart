import 'dart:io';

import 'package:ournet_native/ournet_native.dart';
import 'package:test/test.dart';

void main() {
  test('free space is known for a real folder and unknown for none', () {
    final free = NativeDisk.freeBytes(Directory.systemTemp.path);
    expect(free, isNotNull);
    expect(free, greaterThan(0));
    expect(
      NativeDisk.freeBytes('${Directory.systemTemp.path}/no/such/place/here'),
      isNull,
    );
  });
}
