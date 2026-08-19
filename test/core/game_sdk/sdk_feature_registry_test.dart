import 'dart:io';

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
      'performance.ping',
      'performance.pong',
      'lifecycle.complete',
    });
    expect(SdkFeatureRegistry.appCommandNames, {
      'app.bootstrap',
      'app.game.configure',
      'app.capabilities.confirm',
      'app.capability.create',
      'app.capability.invoke',
      'app.capability.dispose',
      'app.media.open',
      'app.media.close',
      'app.input.takeover',
      'app.ui.openSharePanel',
      'app.lan.discover',
      'app.lan.joinDiscovered',
      'app.lan.joinByLink',
      'app.lan.scanQr',
      'app.lan.setPublished',
      'app.lan.getShareLinks',
      'app.device.fullscreen',
      'app.game.exit',
      'app.identity.syncAvatar',
    });

    final fragments = SdkFeatureRegistry.sourceFragments;
    expect(fragments, hasLength(16));
    expect(fragments.map((fragment) => fragment.id).toSet(), hasLength(16));
    expect(
      fragments.where((fragment) => fragment.target == SdkSourceTarget.game),
      hasLength(8),
    );
    expect(
      fragments.where((fragment) => fragment.target == SdkSourceTarget.app),
      hasLength(8),
    );
    expect(
      fragments.every((fragment) => fragment.typeScript.trim().isNotEmpty),
      isTrue,
    );
    expect(
      fragments
          .where((fragment) => fragment.declaration.trim().isNotEmpty)
          .map((fragment) => fragment.id),
      containsAll(['app.ui', 'app.lan']),
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
    expect(SdkFeatureRegistry.gameSdkVersion, '4.1.0');
    expect(SdkFeatureRegistry.appSdkVersion, '3.3.0');
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
      [('4.1.0', '4.1.0', '4.1.0')],
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
      [('3.2.0', '3.3.0', '3.3.0')],
    );
    expect(SdkFeatureRegistry.resolveAppSdkVersion('3.2.0'), '3.3.0');
    expect(SdkFeatureRegistry.resolveAppSdkVersion('3.3.0'), '3.3.0');
    expect(
      SdkFeatureRegistry.sdkFile('playmesh-app.js', version: '3.2.0'),
      SdkFeatureRegistry.sdkFile('playmesh-app.js', version: '3.3.0'),
    );
    expect(
      SdkFeatureRegistry.gameSdkReleases.single.commandNames,
      SdkFeatureRegistry.gameCommandNames,
    );
    expect(
      SdkFeatureRegistry.appSdkReleases.single.commandNames,
      SdkFeatureRegistry.appCommandNames,
    );
    expect(
      () => SdkFeatureRegistry.resolveGameSdkVersion('1.0.0'),
      throwsUnsupportedError,
    );
    expect(
      () => SdkFeatureRegistry.resolveAppSdkVersion('1.0.0'),
      throwsUnsupportedError,
    );
    expect(
      SdkFeatureRegistry.sdkFile('playmesh-main.js'),
      allOf(
        contains('Symbol.for("playmesh.app.internal.v1")'),
        contains('const appSdk = appInternalRuntime?.publicApi'),
        contains('app: appSdk'),
        isNot(contains('main.__receive')),
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
      SdkFeatureRegistry.sdkFile('playmesh-main.d.ts'),
      allOf([
        contains('interface PlaymeshApi'),
        contains('readonly version: "${SdkFeatureRegistry.gameSdkVersion}"'),
        contains('interface PlaymeshMainApi'),
        contains('readonly main: PlaymeshMainApi'),
        contains('readonly app: PlaymeshAppApi'),
        contains('avatar: string | null'),
        contains('openSharePanel(): Promise<void>'),
        contains('disableSystemMenuTriggers(): void'),
        contains('type PlaymeshAppLanShareLinkType = "lan" | "wan"'),
        contains('interface PlaymeshAppLanApi'),
        contains('readonly lan: PlaymeshAppLanApi'),
        contains('discoverGames(): Promise<readonly PlaymeshLanGame[]>'),
        contains(
          'getShareLinks(): Promise<readonly PlaymeshAppLanShareLink[]>',
        ),
        contains('showGameSidebar(): Promise<boolean>'),
        contains('exitGame(): Promise<void>'),
        contains('readonly media: PlaymeshAppMediaApi'),
        contains('Promise<PlaymeshAppMediaSession>'),
        isNot(contains('hideGameSidebar')),
        isNot(contains('onMenuRequest')),
        isNot(contains('playmesh.authority.openSharePanel')),
        isNot(contains('__PLAYMESH')),
        isNot(contains('platform.ui.restoreGameFocus')),
      ]),
    );
    expect(
      SdkFeatureRegistry.sdkFile('playmesh-app.d.ts').trim(),
      '/// <reference path="./playmesh-main.d.ts" />',
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh.d.ts'),
      throwsArgumentError,
    );
  });

  test('版本选择拒绝未注册范围且当前版仍从统一 Dart 源组装', () {
    expect(
      SdkFeatureRegistry.sdkFile('playmesh-main.js', version: '4.1.0'),
      SdkFeatureRegistry.sdkFile('playmesh-main.js', version: '4.1.0'),
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh-main.js', version: '1.0.0'),
      throwsUnsupportedError,
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh-main.js', version: '4.0.1'),
      throwsUnsupportedError,
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh-app.js', version: '0.9.9'),
      throwsUnsupportedError,
    );
    expect(
      () => SdkFeatureRegistry.sdkFile('playmesh-main.js', version: 'latest'),
      throwsFormatException,
    );
  });

  test('公开 SDK 路由只暴露成对的 JavaScript 与声明文件', () {
    for (final file in const [
      'playmesh-main.js',
      'playmesh-main.d.ts',
      'playmesh-app.js',
      'playmesh-app.d.ts',
    ]) {
      expect(
        SdkFeatureRegistry.sdkFileForPublicPath('sdk/v1/$file'),
        SdkFeatureRegistry.sdkFile(file),
      );
    }
    for (final internalFile in const ['playmesh.ts', 'playmesh-app.ts']) {
      expect(
        SdkFeatureRegistry.sdkFileForPublicPath('sdk/v1/$internalFile'),
        isNull,
      );
    }
  });

  test('官方声明生成物与 Dart declaration fragments 逐字一致', () {
    const generatedFiles = {
      'assets/playmesh-library/public/sdk/v1/playmesh-main.d.ts':
          'playmesh-main.d.ts',
      'assets/playmesh-library/public/sdk/v1/playmesh-app.d.ts':
          'playmesh-app.d.ts',
    };
    for (final entry in generatedFiles.entries) {
      expect(
        File(entry.key).readAsStringSync(),
        SdkFeatureRegistry.sdkFile(entry.value),
        reason: '${entry.key} 必须只由统一生成器产生',
      );
    }
  });

  test('注册表拒绝没有执行器的 Game SDK 命令', () async {
    final context = GameSdkCommandContext(
      standalonePlayer: const {
        'id': 'u-test',
        'nickname': '测试玩家',
        'connected': true,
      },
      completeLifecycle: (_) => false,
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
