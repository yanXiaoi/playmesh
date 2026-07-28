import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';

void main() {
  test('统一注册表覆盖网页端所有宿主命令且 feature 标识唯一', () {
    expect(SdkFeatureRegistry.gameCommandNames, {
      'sdk.ready',
      'game.submitAction',
      'authority.result',
      'session.start',
      'session.reset',
      'session.finish',
      'storage.get',
      'storage.set',
      'storage.remove',
      'storage.clear',
      'performance.fps',
      'performance.ping',
      'performance.pong',
      'performance.latency',
      'lifecycle.complete',
    });
    expect(SdkFeatureRegistry.appCommandNames, {
      'app.bootstrap',
      'app.game.configure',
      'app.capabilities.confirm',
      'app.capability.create',
      'app.capability.invoke',
      'app.capability.dispose',
      'app.input.takeover',
      'app.ui.openSharePanel',
      'app.device.fullscreen',
      'app.game.exit',
      'app.identity.syncAvatar',
    });

    final fragments = SdkFeatureRegistry.sourceFragments;
    expect(fragments, hasLength(11));
    expect(fragments.map((fragment) => fragment.id).toSet(), hasLength(11));
    expect(
      fragments.where((fragment) => fragment.target == SdkSourceTarget.game),
      hasLength(7),
    );
    expect(
      fragments.where((fragment) => fragment.target == SdkSourceTarget.app),
      hasLength(4),
    );
    expect(
      fragments.every((fragment) => fragment.typeScript.trim().isNotEmpty),
      isTrue,
    );

    final gameTypeScript =
        fragments
            .where((fragment) => fragment.target == SdkSourceTarget.game)
            .toList()
          ..sort((left, right) => left.order.compareTo(right.order));
    expect(
      SdkFeatureRegistry.sdkFile('playmesh.ts'),
      gameTypeScript
          .map((fragment) => fragment.typeScript)
          .join()
          .replaceAll(
            '__PLAYMESH_APP_SDK_VERSION__',
            SdkFeatureRegistry.appSdkVersion,
          ),
    );
    expect(SdkFeatureRegistry.gameSdkVersion, '3.0.0');
    expect(SdkFeatureRegistry.appSdkVersion, '3.0.0');
    expect(
      SdkFeatureRegistry.gameSdkReleases
          .map(
            (release) => (
              release.minimumRequestedVersion,
              release.maximumRequestedVersion,
              release.bundleVersion,
            ),
          )
          .toList(),
      [('1.0.0', '3.0.0', '3.0.0')],
    );
    expect(
      SdkFeatureRegistry.appSdkReleases
          .map(
            (release) => (
              release.minimumRequestedVersion,
              release.maximumRequestedVersion,
              release.bundleVersion,
            ),
          )
          .toList(),
      [('1.0.0', '3.0.0', '3.0.0')],
    );
    expect(
      SdkFeatureRegistry.gameSdkReleases.single.commandNames,
      SdkFeatureRegistry.gameCommandNames,
    );
    expect(
      SdkFeatureRegistry.appSdkReleases.single.commandNames,
      SdkFeatureRegistry.appCommandNames,
    );
    expect(SdkFeatureRegistry.resolveGameSdkVersion('1.0.0'), '3.0.0');
    expect(SdkFeatureRegistry.resolveAppSdkVersion('1.0.0'), '3.0.0');
    expect(
      SdkFeatureRegistry.sdkFile('playmesh.js'),
      allOf(
        contains('version: "${SdkFeatureRegistry.appSdkVersion}"'),
        isNot(contains('__PLAYMESH_APP_SDK_VERSION__')),
        isNot(contains('PLAYMESH_DECLARATION = String.raw')),
      ),
    );
    expect(
      SdkFeatureRegistry.sdkFile('playmesh.ts'),
      allOf(
        contains('version: "${SdkFeatureRegistry.appSdkVersion}"'),
        isNot(contains('__PLAYMESH_APP_SDK_VERSION__')),
      ),
    );
    expect(
      SdkFeatureRegistry.sdkFile('playmesh.d.ts'),
      allOf([
        contains('interface PlaymeshApi'),
        contains('readonly version: "${SdkFeatureRegistry.appSdkVersion}"'),
        contains('avatar: string | null'),
        contains('openSharePanel(): Promise<void>'),
        contains('showGameSidebar(): Promise<boolean>'),
        contains('exitGame(): Promise<void>'),
        isNot(contains('hideGameSidebar')),
        isNot(contains('onMenuRequest')),
        isNot(contains('playmesh.authority.openSharePanel')),
        isNot(contains('__PLAYMESH')),
        isNot(contains('platform.ui.restoreGameFocus')),
      ]),
    );
  });

  test('版本选择拒绝未注册范围且兼容版仍从统一 Dart 源组装', () {
    expect(
      SdkFeatureRegistry.sdkFile('playmesh.js', version: '1.0.0'),
      SdkFeatureRegistry.sdkFile('playmesh.js', version: '3.0.0'),
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh.js', version: '3.0.1'),
      throwsUnsupportedError,
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh-app.js', version: '0.9.9'),
      throwsUnsupportedError,
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh.js', version: 'latest'),
      throwsFormatException,
    );
  });

  test('注册表拒绝没有执行器的 Game SDK 命令', () async {
    final context = GameSdkCommandContext(
      standalonePlayer: const {
        'id': 'u-test',
        'nickname': '测试玩家',
        'connected': true,
      },
      ensureStorage: () => throw UnimplementedError(),
      emitFps: (_) {},
      emitLatency: (_) {},
      completeLifecycle: (_) => false,
      routeRemoteStorage: (_, _, _) async {},
    );

    expect(
      () => SdkFeatureRegistry.dispatchGame(
        context,
        const SdkCommandEnvelope(
          name: 'future.unregistered',
          requestId: 'bad-1',
          payload: {},
          raw: {},
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('future.unregistered'),
        ),
      ),
    );
  });

  test('同一命令只禁止相同支持版本命中多个 Dart 执行器', () {
    expect(
      () => validateSdkCommandVersionRanges({
        'game.example': [
          const [SdkVersionRange('1.0.0', '2.9.9')],
          const [SdkVersionRange('3.0.0', SdkVersionRange.last)],
        ],
      }),
      returnsNormally,
    );
    expect(
      () => validateSdkCommandVersionRanges({
        'game.example': [
          const [SdkVersionRange('1.0.0', SdkVersionRange.last)],
          const [SdkVersionRange('3.0.0', SdkVersionRange.last)],
        ],
      }),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('多个 Dart 执行器'),
        ),
      ),
    );
    const openRange = SdkVersionRange('1.0.0', SdkVersionRange.last);
    expect(openRange.supports('999.0.0'), isTrue);
  });
}
