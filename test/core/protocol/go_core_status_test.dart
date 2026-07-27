import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/protocol/go_core_status.dart';

void main() {
  test('parses a supported health response', () {
    final status = GoCoreStatus.fromJson({
      'type': 'core.health',
      'protocolVersion': '1.3.0',
      'timestamp': 1760000000100,
      'requestId': 'req-model-1',
      'data': {
        'status': 'online',
        'coreVersion': '0.1.0',
        'startedAt': 1760000000000,
      },
    });

    expect(status.requestId, 'req-model-1');
    expect(status.status, 'online');
    expect(status.coreVersion, '0.1.0');
    expect(status.startedAt.millisecondsSinceEpoch, 1760000000000);
  });

  test('rejects an incompatible protocol version', () {
    expect(
      () => GoCoreStatus.fromJson({
        'type': 'core.health',
        'protocolVersion': '2.0.0',
        'timestamp': 1760000000100,
        'requestId': 'req-model-2',
        'data': {
          'status': 'online',
          'coreVersion': '0.1.0',
          'startedAt': 1760000000000,
        },
      }),
      throwsFormatException,
    );
  });
}
