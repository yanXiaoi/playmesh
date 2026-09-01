import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Runtime packaging publishes artifacts and hashes automatically', () {
    final source = File(
      'runtime/src/tool/build_runtime_packages.ps1',
    ).readAsStringSync();
    final publishFunction = source.substring(
      source.indexOf('function Publish-RuntimePackages'),
      source.indexOf('function Test-IsRuntimeKeyArtifact'),
    );

    expect(publishFunction, contains(r'"resources\runtime"'));
    expect(
      publishFunction,
      contains(r'$update.version = $publishedReleaseName'),
    );
    expect(publishFunction, contains(r'$update.platform.android.x86.sha256'));
    expect(publishFunction, contains(r'$update.platform.android.arm.sha256'));
    expect(publishFunction, contains(r'$update.platform.windows.sha256'));
    expect(source, contains('function Copy-RuntimePublicationFile'));
    expect(
      source,
      contains(r'for ($attempt = 1; $attempt -le 60; $attempt++)'),
    );
    expect(source, contains('Start-Sleep -Milliseconds 500'));
    expect(
      publishFunction,
      contains(r'Copy-RuntimePublicationFile $stagedUpdatePath $updatePath'),
    );
    expect(
      source,
      contains(
        r'Publish-RuntimePackages $stagingDir @($packages) $releaseName',
      ),
    );
    expect(
      source.indexOf(
        r'Publish-RuntimePackages $stagingDir @($packages) $releaseName',
      ),
      lessThan(
        source.indexOf(
          r'Move-Item -LiteralPath $stagingDir -Destination $outputDir',
        ),
      ),
    );
  });
}
