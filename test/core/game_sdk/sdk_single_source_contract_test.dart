import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('所有运行时 SDK 消费入口只通过 Dart feature 注册表', () {
    final dartFiles = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    final forbidden = <String, List<String>>{};
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      final reasons = <String>[
        if (source.contains('generated_sdk_versions')) '引用已删除的生成版本常量',
        if (source.contains('assets/playmesh-library/public/sdk/'))
          '直接引用打包 SDK 静态资源',
        if (RegExp(
          r'''rootBundle\.(?:load|loadString)\(\s*['"][^'"]*public/sdk/''',
        ).hasMatch(source))
          '通过 rootBundle 读取 SDK',
      ];
      if (reasons.isNotEmpty) forbidden[file.path] = reasons;
    }
    expect(
      forbidden,
      isEmpty,
      reason: 'SDK 内容必须由 SdkFeatureRegistry 即时组装，禁止恢复静态旁路',
    );

    const requiredConsumers = {
      'lib/core/game_package/game_asset_gateway_io.dart':
          'SdkFeatureRegistry.sdkFileForPublicPath',
      'lib/core/game_web/game_web_gateway_io.dart':
          'SdkFeatureRegistry.sdkFileForPublicPath',
      'lib/core/developer/operations/infrastructure/developer_http_support.dart':
          'SdkFeatureRegistry.sdkFileForPublicPath',
      'lib/core/developer/operations/system/sdk_bundle_operation.dart':
          'SdkFeatureRegistry.sdkFile(name)',
      'lib/core/developer/operations/ai/project_prompt_operation.dart':
          "SdkFeatureRegistry.sdkFile('playmesh-main.d.ts')",
      'lib/core/developer/operations/system/status_operation.dart':
          'SdkFeatureRegistry.gameSdkVersion',
      'lib/core/game_sdk/app_webview_bridge.dart':
          'SdkFeatureRegistry.dispatchApp',
      'lib/core/game_sdk/features/game/game_core_feature.dart':
          '_resolveCommandSdkVersion',
      'lib/features/game/game_launcher.dart': 'game.sdkVersion.isEmpty',
      'lib/features/game/game_page.dart': 'game.sdkVersion.isEmpty',
    };
    for (final entry in requiredConsumers.entries) {
      expect(
        File(entry.key).readAsStringSync(),
        contains(entry.value),
        reason: '${entry.key} 必须通过统一 SDK 注册表',
      );
    }

    final registry = File(
      'lib/core/game_sdk/sdk_feature_registry.dart',
    ).readAsStringSync();
    expect(
      registry,
      contains('final feature = release._gameCommands[command.name]'),
    );
    expect(
      registry,
      contains('final feature = release._appCommands[command.name]'),
    );
    expect(registry, contains("static const String last = 'last'"));

    for (final feature
        in Directory('lib/core/game_sdk/features')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('_feature.dart'))) {
      final source = feature.readAsStringSync();
      if (!source.contains('Set<String> get commands')) continue;
      expect(
        source,
        contains('List<SdkVersionRange> get supportedVersions'),
        reason: '${feature.path} 的命令执行器必须自行声明支持的 SDK 版本',
      );
    }
  });
}
