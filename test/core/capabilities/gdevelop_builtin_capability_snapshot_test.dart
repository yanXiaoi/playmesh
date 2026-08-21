import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/capabilities/default_capability_plugins.dart';

const _gdevelopCapabilitySnapshotPath =
    'assets/playmesh-library/public/GDevelop/playmesh/scripts/'
    'playmesh-built-in-capabilities.snapshot.json';

void main() {
  test('GDevelop typed capability facade matches the default registry', () {
    final snapshotFile = File(_gdevelopCapabilitySnapshotPath);
    expect(
      snapshotFile.existsSync(),
      isTrue,
      reason: 'Regenerate the Playmesh GDevelop extension capability snapshot.',
    );

    final snapshot = jsonDecode(snapshotFile.readAsStringSync());
    final registryDescriptors = defaultCapabilityDescriptors
        .map((descriptor) => descriptor.toJson())
        .toList(growable: false);

    expect(
      snapshot,
      registryDescriptors,
      reason:
          'A default capability descriptor changed without synchronizing the '
          'GDevelop typed facade snapshot and wrappers.',
    );
  });
}
