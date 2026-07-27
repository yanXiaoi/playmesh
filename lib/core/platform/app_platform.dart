import 'package:flutter/foundation.dart';

bool get isMobileAppPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

bool get supportsPlatformWebView =>
    !kIsWeb &&
    (isMobileAppPlatform || defaultTargetPlatform == TargetPlatform.macOS);
