/// How hard a phrase is to guess, judged roughly and locally: a warning for
/// the person choosing it, never a rule. Copies of what it protects can be
/// guessed at offline, without any limit on attempts.
enum PhraseStrength {
  none('No phrase: anyone who gets a copy can open it'),
  weak('Weak: easy to guess'),
  fair('Fair: a few more words would help'),
  strong('Strong');

  final String label;
  const PhraseStrength(this.label);

  /// Bits of guessing work above which a phrase counts as [fair] and
  /// [strong]. Argon2id adds roughly 20 more on top for an attacker.
  static const fairBits = 40.0, strongBits = 60.0;

  static PhraseStrength of(String phrase) {
    final p = phrase.trim();
    if (p.isEmpty) return none;
    final bits = estimateBits(p);
    if (bits >= strongBits) return strong;
    if (bits >= fairBits) return fair;
    return weak;
  }

  /// A deliberately simple estimate: words are counted as dictionary words,
  /// and anything else by its character set, with repeats and common
  /// passwords discounted.
  static double estimateBits(String phrase) {
    final p = phrase.trim();
    if (p.isEmpty) return 0;
    final lower = p.toLowerCase();
    if (_common.contains(lower) ||
        _common.contains(lower.replaceAll(RegExp(r'[^a-z]'), ''))) {
      return 10;
    }
    final words = lower
        .split(RegExp(r'[\s\-_.,]+'))
        .where((w) => w.isNotEmpty)
        .toList();
    // Several real-looking words: each is a pick from a large list, and the
    // separators and case add little.
    if (words.length >= 2 &&
        words.every((w) => RegExp(r'^[a-z]+$').hasMatch(w))) {
      final distinct = words.toSet();
      var bits = 0.0;
      for (final w in distinct) {
        bits += _common.contains(w) || w.length <= 3 ? 8 : 12;
      }
      return bits;
    }
    var pool = 0;
    if (RegExp('[a-z]').hasMatch(p)) pool += 26;
    if (RegExp('[A-Z]').hasMatch(p)) pool += 26;
    if (RegExp('[0-9]').hasMatch(p)) pool += 10;
    if (RegExp(r'[^a-zA-Z0-9]').hasMatch(p)) pool += 33;
    final perChar = _log2(pool);
    // Repeated and sequential characters add almost nothing.
    var effective = 0.0;
    for (var i = 0; i < p.length; i++) {
      final c = p.codeUnitAt(i);
      if (i > 0) {
        final d = c - p.codeUnitAt(i - 1);
        if (d == 0 || d == 1 || d == -1) {
          effective += 0.5;
          continue;
        }
      }
      effective += 1;
    }
    return effective * perChar;
  }

  static double _log2(int n) {
    var bits = 0.0, v = n.toDouble();
    while (v >= 2) {
      v /= 2;
      bits += 1;
    }
    return bits + (v - 1);
  }

  /// The passwords tried first by anyone guessing, and their bare words.
  static const _common = {
    'password',
    'passw0rd',
    'password1',
    'password123',
    '123456',
    '12345678',
    '123456789',
    '1234567890',
    'qwerty',
    'qwertyuiop',
    'abc123',
    'letmein',
    'welcome',
    'monkey',
    'dragon',
    'football',
    'iloveyou',
    'admin',
    'login',
    'master',
    'sunshine',
    'princess',
    'shadow',
    'baseball',
    'trustno1',
    'secret',
    'hello',
    'freedom',
    'whatever',
    'ournet',
    'recovery',
    'phrase',
    'changeme',
    'default',
    'test',
    'love',
    'god',
    'sex',
    'the',
    'and',
    'my',
    'correcthorsebatterystaple',
  };
}
