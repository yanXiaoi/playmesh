import 'package:flutter/material.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';

import 'app.dart';
import 'core/platform/app_platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // flutter_fullscreen does not currently declare the OHOS platform. Harmony
  // uses the native capability channel in AppDeviceService instead.
  if (!isHarmonyOS) {
    await FullScreen.ensureInitialized();
  }
  runApp(const PlaymeshApp());
}
