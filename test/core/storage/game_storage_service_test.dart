import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/storage/game_storage_service.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('playmesh-storage-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('Bucket JSON 写入 data/json 并可重新加载', () async {
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.demo',
      libraryRoot: root,
    );
    await storage.setData('profile', 'coins', 7);
    expect(await storage.getData('profile', 'coins'), 7);
    await storage.close();

    final reloaded = await GameStorageService.create(
      gameId: 'com.playmesh.demo',
      libraryRoot: root,
    );
    expect(await reloaded.getData('profile', 'coins'), 7);
    expect(
      File(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}com.playmesh.demo'
        '${Platform.pathSeparator}data${Platform.pathSeparator}json'
        '${Platform.pathSeparator}profile.json',
      ).existsSync(),
      isTrue,
    );
    await reloaded.close();
  });

  test('Bucket 文件流写入 data/data 并返回公开时间戳地址', () async {
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.upload',
      libraryRoot: root,
    );

    final url = await storage.upload(
      bucket: 'assets',
      originalName: '角色快照.PNG',
      data: Stream.value(<int>[0, 255, 7, 9]),
      contentLength: 4,
    );

    expect(url, matches(RegExp(r'^/bucket/assets/[0-9]{13,}\.PNG$')));
    final fileName = Uri.parse(url).pathSegments.last;
    expect(await storage.dataFile('assets', fileName).readAsBytes(), [
      0,
      255,
      7,
      9,
    ]);
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}com.playmesh.upload'
        '${Platform.pathSeparator}data${Platform.pathSeparator}data'
        '${Platform.pathSeparator}assets',
      ).existsSync(),
      isTrue,
    );
    expect(
      () => storage.dataFile('assets', '../json/save.json'),
      throwsFormatException,
    );
    await storage.close();
  });

  test('清除游戏数据只删除当前游戏 data', () async {
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.demo',
      libraryRoot: root,
    );
    await storage.setData('save', 'level', 3);
    await storage.flushAll();

    await GameStorageService.clearGameData(
      gameId: 'com.playmesh.demo',
      libraryRoot: root,
    );

    final data = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.playmesh.demo${Platform.pathSeparator}data',
    );
    expect(data.existsSync(), isFalse);
  });

  test('拒绝可能越过游戏目录的 Bucket 和 key', () async {
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.demo',
      libraryRoot: root,
    );
    expect(() => storage.getData('../other', 'key'), throwsFormatException);
    expect(() => storage.getData('bad.bucket', 'key'), throwsFormatException);
    expect(() => storage.getData('bad bucket', 'key'), throwsFormatException);
    expect(() => storage.getData('_save', 'key'), throwsFormatException);
    expect(() => storage.getData('-save', 'key'), throwsFormatException);
    expect(() => storage.getData('存档', 'key'), throwsFormatException);
    expect(() => storage.getData('save\n', 'key'), throwsFormatException);
    expect(() => storage.getData('a' * 65, 'key'), throwsFormatException);
    expect(() => storage.setData('save', '../key', 1), throwsFormatException);
  });

  test('同一 Bucket 的高频写入和宿主落盘串行执行且不丢数据', () async {
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.concurrent',
      libraryRoot: root,
    );

    await Future.wait(
      List.generate(80, (index) async {
        await storage.setData('thunder_fighters', 'value_$index', index);
        await storage.flushAll();
      }),
    );
    await storage.close();

    final reloaded = await GameStorageService.create(
      gameId: 'com.playmesh.concurrent',
      libraryRoot: root,
    );
    for (var index = 0; index < 80; index += 1) {
      expect(await reloaded.getData('thunder_fighters', 'value_$index'), index);
    }
    await reloaded.close();
    final dataDirectory = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.playmesh.concurrent'
      '${Platform.pathSeparator}data${Platform.pathSeparator}json',
    );
    expect(
      dataDirectory.listSync().where((entry) => entry.path.endsWith('.tmp')),
      isEmpty,
    );
  });
}
