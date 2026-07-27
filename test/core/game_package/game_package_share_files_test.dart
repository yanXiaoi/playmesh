import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_package_share_files.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  test('分享文件使用安全名称、唯一路径并在下次创建前清理', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-share-');
    addTearDown(() => root.delete(recursive: true));
    final manager = GamePackageShareFiles(temporaryRoot: root);
    final first = await manager.create(_game);
    await first.writeAsString('old');
    await manager.complete(first, deleteNow: false);
    final second = await manager.create(_game);
    expect(await first.exists(), isFalse);
    expect(second.path, isNot(first.path));
    expect(second.path, endsWith('Bad_Name_-v1.2.3.zip'));
  });

  test('截断后再次移除 Windows 不接受的尾随点和空格', () {
    final longName = '${List.filled(79, 'a').join()}.b';
    final game = GameSummary(
      id: _game.id,
      name: longName,
      version: _game.version,
      description: _game.description,
      minPlayers: _game.minPlayers,
      maxPlayers: _game.maxPlayers,
      supportsMultiplayer: _game.supportsMultiplayer,
      displayModeLabel: _game.displayModeLabel,
      displayMode: _game.displayMode,
      orientation: _game.orientation,
      entry: _game.entry,
    );

    expect(
      gamePackageShareFileName(game),
      '${List.filled(79, 'a').join()}-v1.2.3.zip',
    );
  });

  test('连续二十次分享后只保留当前租约文件', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-share-20-');
    addTearDown(() => root.delete(recursive: true));
    final manager = GamePackageShareFiles(temporaryRoot: root);

    File? current;
    for (var index = 0; index < 20; index += 1) {
      if (current != null) {
        await manager.complete(current, deleteNow: false);
      }
      current = await manager.create(_game);
      await current.writeAsBytes([index]);
    }

    final entries = await manager.directory.list(followLinks: false).toList();
    expect(entries, hasLength(1));
    expect(entries.single.path, current!.path);
  });

  test('App 重启后的新管理器会清理上次未消费完成的分享文件', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-share-restart-',
    );
    addTearDown(() => root.delete(recursive: true));
    final beforeRestart = GamePackageShareFiles(temporaryRoot: root);
    final stale = await beforeRestart.create(_game);
    await stale.writeAsString('pending receiver');
    await beforeRestart.complete(stale, deleteNow: false);

    final afterRestart = GamePackageShareFiles(temporaryRoot: root);
    await afterRestart.cleanup();

    expect(await stale.exists(), isFalse);
  });

  test('并发分享保留全部活动租约并只清理已结束任务', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-share-concurrent-',
    );
    addTearDown(() => root.delete(recursive: true));
    final manager = GamePackageShareFiles(temporaryRoot: root);
    final first = await manager.create(_game);
    await first.writeAsString('first');
    final second = await manager.create(_game);
    await second.writeAsString('second');

    await manager.cleanup();
    expect(await first.exists(), isTrue);
    expect(await second.exists(), isTrue);

    await manager.complete(first, deleteNow: false);
    await manager.cleanup();
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue);
  });

  test('拒绝删除专用分享目录之外的文件', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-share-safe-');
    addTearDown(() => root.delete(recursive: true));
    final outside = File('${root.path}${Platform.pathSeparator}keep.txt');
    await outside.writeAsString('keep');
    final manager = GamePackageShareFiles(temporaryRoot: root);

    await expectLater(manager.delete(outside), throwsStateError);
    expect(await outside.readAsString(), 'keep');

    final lexicalEscape = File(
      '${manager.directory.path}${Platform.pathSeparator}..'
      '${Platform.pathSeparator}keep.txt',
    );
    await expectLater(manager.delete(lexicalEscape), throwsStateError);
    expect(await outside.readAsString(), 'keep');
  });
}

const _game = GameSummary(
  id: 'game',
  name: 'Bad<Name>. ',
  version: '1.2.3',
  description: '',
  minPlayers: 1,
  maxPlayers: 1,
  supportsMultiplayer: false,
  displayModeLabel: '多屏',
  displayMode: 'multi_screen',
  orientation: GameOrientation.landscape,
  entry: LocalGameEntry(assetPath: 'app/index.html', statusLabel: 'SDK'),
);
