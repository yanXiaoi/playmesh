import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_background_host.dart';

void main() {
  test('Android developer notification projects App messages and raw port', () {
    for (final localeId in const ['zh-CN', 'en-US']) {
      final source = jsonDecode(
        File(
          'assets/playmesh-localization/locales/$localeId/app.json',
        ).readAsStringSync(),
      );
      final messages = Map<String, String>.from(source as Map);
      final localization =
          DeveloperBackgroundNotificationLocalization.fromAppMessages(
            localeId: localeId,
            messages: messages,
          );

      final arguments = localization.toChannelArguments(port: 49152);
      expect(arguments['port'], 49152);
      expect(arguments['localeId'], localeId);
      expect(
        (arguments['messages']! as Map).keys.toSet(),
        developerBackgroundNotificationMessageKeys,
      );
      expect(
        localization.messages['platform.android.developer_service.listening'],
        contains('{port}'),
      );
      expect(
        localization.messages.values.any(
          (message) => message.contains('49152'),
        ),
        isFalse,
      );
    }
  });

  test(
    'Android developer notification rejects an incomplete App projection',
    () {
      expect(
        () => DeveloperBackgroundNotificationLocalization.fromAppMessages(
          localeId: 'zh-CN',
          messages: const {},
        ),
        throwsStateError,
      );
    },
  );
}
