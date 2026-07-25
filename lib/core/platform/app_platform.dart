import 'package:flutter/foundation.dart';

/// Harmony Flutter adds `ohos` to [TargetPlatform]. Comparing by name keeps
/// this source compatible with both the upstream Flutter SDK and the Harmony
/// fork, whose enum members are not identical.
bool isHarmonyPlatformName(String name) => name == 'ohos';

bool get isHarmonyOS =>
    !kIsWeb && isHarmonyPlatformName(defaultTargetPlatform.name);

bool get isMobileAppPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        isHarmonyOS);

bool get supportsPlatformWebView =>
    !kIsWeb &&
    (isMobileAppPlatform || defaultTargetPlatform == TargetPlatform.macOS);
