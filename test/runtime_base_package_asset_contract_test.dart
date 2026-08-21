import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Main App assets contain the export key but no Runtime base package', () async {
    final assets = (await AssetManifest.loadFromAssetBundle(
      rootBundle,
    )).listAssets().toSet();

    expect(
      assets,
      contains('assets/runtime-export/playmesh-default-export.p12'),
    );
    expect(
      assets.where(
        (asset) =>
            asset.startsWith('resources/runtime/') ||
            asset.endsWith('/playmesh-runtime-arm.apk') ||
            asset.endsWith('/playmesh-runtime-x86.apk') ||
            asset.endsWith('/playmesh-runtime-win.zip'),
      ),
      isEmpty,
    );
  });
}
