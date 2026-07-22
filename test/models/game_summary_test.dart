import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/models/game_summary.dart';

void main() {
  test('parses the required manifest orientation values', () {
    expect(
      GameOrientation.fromManifestValue('landscape'),
      GameOrientation.landscape,
    );
    expect(
      GameOrientation.fromManifestValue('portrait'),
      GameOrientation.portrait,
    );
  });

  test('rejects an unsupported manifest orientation', () {
    expect(
      () => GameOrientation.fromManifestValue('auto'),
      throwsFormatException,
    );
  });
}
