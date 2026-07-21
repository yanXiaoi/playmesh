import 'package:flutter/material.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FullScreen.ensureInitialized();
  runApp(const PlaymeshApp());
}
