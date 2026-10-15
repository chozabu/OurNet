import 'package:ournet_core/ournet_core.dart';
import 'package:test/test.dart';

void main() {
  test('phrases are rated, not refused', () {
    expect(PhraseStrength.of(''), PhraseStrength.none);
    expect(PhraseStrength.of('   '), PhraseStrength.none);
    expect(PhraseStrength.of('password'), PhraseStrength.weak);
    expect(PhraseStrength.of('Password123'), PhraseStrength.weak);
    expect(PhraseStrength.of('aaaaaaaaaaaa'), PhraseStrength.weak);
    expect(PhraseStrength.of('abc'), PhraseStrength.weak);
    expect(PhraseStrength.of('kettle orbit'), PhraseStrength.weak);
    expect(PhraseStrength.of('kettle orbit violin marsh'), PhraseStrength.fair);
    expect(
      PhraseStrength.of('kettle orbit violin'),
      isNot(PhraseStrength.strong),
    );
    expect(
      PhraseStrength.of('kettle orbit violin marsh plank'),
      PhraseStrength.strong,
    );
    expect(PhraseStrength.of(r'T7#qv!9xLp2@'), PhraseStrength.strong);
  });
}
