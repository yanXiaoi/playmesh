import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_fullscreen_bridge.dart';

void main() {
  test(
    'native developer fullscreen hook supports Flutter and Windows hosts',
    () {
      expect(
        playmeshDeveloperFullscreenScript,
        contains('global.PlaymeshDeveloperFullscreen'),
      );
      expect(
        playmeshDeveloperFullscreenScript,
        contains('global.chrome && global.chrome.webview'),
      );
      expect(
        playmeshDeveloperFullscreenScript,
        contains('__playmeshDeveloperFullscreen'),
      );
      expect(
        playmeshDeveloperFullscreenScript,
        contains('playmeshdeveloperfullscreenchange'),
      );
      expect(
        playmeshDeveloperFullscreenScript,
        isNot(contains('SystemChrome')),
      );
      expect(
        playmeshDeveloperFullscreenScript,
        isNot(contains('windowManager')),
      );
    },
  );

  test('accepts only the exact bounded toggle intent', () {
    expect(
      isPlaymeshDeveloperFullscreenToggleMessage(
        jsonEncode({
          '__playmeshDeveloperFullscreen': {'action': 'toggle'},
        }),
      ),
      isTrue,
    );
    for (final forged in <Object?>[
      null,
      '',
      '{}',
      jsonEncode({
        '__playmeshDeveloperFullscreen': {'action': 'enter'},
      }),
      jsonEncode({
        '__playmeshDeveloperFullscreen': {
          'action': 'toggle',
          'orientation': 'landscape',
        },
      }),
      jsonEncode({
        '__playmeshDeveloperFullscreen': {'action': 'toggle'},
        'extra': true,
      }),
    ]) {
      expect(isPlaymeshDeveloperFullscreenToggleMessage(forged), isFalse);
    }
  });

  test('state script publishes only a boolean to the installed hook', () {
    expect(
      playmeshDeveloperFullscreenStateScript(true),
      'globalThis.__playmeshApplyDeveloperFullscreenState?.(true);',
    );
    expect(
      playmeshDeveloperFullscreenStateScript(false),
      'globalThis.__playmeshApplyDeveloperFullscreenState?.(false);',
    );
  });
}
