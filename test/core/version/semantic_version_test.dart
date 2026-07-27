import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/version/semantic_version.dart';

void main() {
  test('strictly parses and compares three-part semantic versions', () {
    expect(
      SemanticVersion.parse('10.2.0') > SemanticVersion.parse('2.99.99'),
      isTrue,
    );
    for (final invalid in [
      'v1.2.3',
      '1.2',
      '1.2.3-beta',
      '01.2.3',
      '1.02.3',
      '1.2.03',
      ' 1.2.3',
    ]) {
      expect(() => SemanticVersion.parse(invalid), throwsFormatException);
    }
  });
}
