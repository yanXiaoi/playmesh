import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_channel.dart';
import 'package:playmesh/core/developer/developer_preferences.dart';

void main() {
  test('生成默认工作区身份并持久化端口、Token 和路径', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-developer-preferences-',
    );
    addTearDown(() => root.delete(recursive: true));
    final preferences = DeveloperPreferences(libraryRoot: root);

    final generated = await preferences.load();
    expect(generated.port, defaultDeveloperPort);
    expect(generated.token, hasLength(64));
    expect(generated.path, hasLength(32));

    const saved = DeveloperWorkspacePreference(
      port: 17777,
      token: 'persistent-dev-token',
      path: 'persistent-workspace-path',
    );
    await preferences.save(saved);

    final loaded = await preferences.load();
    expect(loaded.port, saved.port);
    expect(loaded.token, saved.token);
    expect(loaded.path, saved.path);
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}developer'
        '${Platform.pathSeparator}settings.json',
      ).readAsString(),
      '{"port":17777,"token":"persistent-dev-token",'
      '"path":"persistent-workspace-path"}',
    );
  });

  test('拒绝持久化无效端口', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-developer-preferences-',
    );
    addTearDown(() => root.delete(recursive: true));

    await expectLater(
      DeveloperPreferences(libraryRoot: root).save(
        const DeveloperWorkspacePreference(
          port: 0,
          token: 'persistent-dev-token',
          path: 'persistent-workspace-path',
        ),
      ),
      throwsFormatException,
    );
  });
}
