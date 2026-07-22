import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/platform/app_platform.dart';

void main() {
  test(
    'recognizes the Harmony Flutter target without referencing its enum',
    () {
      expect(isHarmonyPlatformName('ohos'), isTrue);
      expect(isHarmonyPlatformName('android'), isFalse);
      expect(isHarmonyPlatformName('windows'), isFalse);
    },
  );
}
