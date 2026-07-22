import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/settings/game_display_preferences.dart';

void main() {
  test('性能悬浮层开关保存在当前 App 设置中', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-display-');
    addTearDown(() => root.delete(recursive: true));
    final preferences = GameDisplayPreferences(libraryRoot: root);

    expect(await preferences.loadPerformanceVisible(), isTrue);
    await preferences.savePerformanceVisible(false);

    expect(
      await GameDisplayPreferences(libraryRoot: root).loadPerformanceVisible(),
      isFalse,
    );
  });
}
