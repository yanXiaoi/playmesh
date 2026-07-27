import 'package:flutter/material.dart';
import 'package:flutter_fullscreen/flutter_fullscreen.dart';

import 'app.dart';
import 'core/localization/playmesh_ui_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FullScreen.ensureInitialized();
  try {
    final uiBootstrap = await PlaymeshUiBootstrap.load();
    runApp(PlaymeshApp(uiBootstrap: uiBootstrap));
  } on Object catch (error, stackTrace) {
    debugPrint('playmesh_localization_bootstrap_failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    runApp(_LocalizationBootstrapFailure(error: error));
  }
}

class _LocalizationBootstrapFailure extends StatelessWidget {
  const _LocalizationBootstrapFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: SelectableText(
            'playmesh_localization_bootstrap_failed\n$error',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
