import 'package:flutter_test/flutter_test.dart';
import 'package:ournet/ui/update_banner.dart';

void main() {
  test('update links point at the public store listings', () {
    expect(updateLinks('android').map((u) => '$u'), [
      'market://details?id=org.chozabu.ournet',
      'https://play.google.com/store/apps/details?id=org.chozabu.ournet',
    ]);
    expect(updateLinks('windows').map((u) => '$u'), [
      'ms-windows-store://pdp/?ProductId=9N6P4X13QG9M',
      'https://apps.microsoft.com/detail/9N6P4X13QG9M',
    ]);
    expect(updateLinks('linux'), isEmpty);
    expect(updateLinks('ios'), isEmpty);
  });
}
