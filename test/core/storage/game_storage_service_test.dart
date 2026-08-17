import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/profile/avatar_image.dart';
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

  test('逻辑桶 envelope 摘要不一致或 JSON 损坏时 fail closed', () async {
    const digestBucket = 'GDevelop/存档/摘要';
    const brokenBucket = 'GDevelop/存档/损坏';
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.logical-damage',
      libraryRoot: root,
    );
    await storage.setLogicalData(digestBucket, 'root', {'level': 3});
    await storage.setLogicalData(brokenBucket, 'root', {'level': 4});
    await storage.close();

    final logicalRoot = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.playmesh.logical-damage'
      '${Platform.pathSeparator}data${Platform.pathSeparator}json'
      '${Platform.pathSeparator}logical',
    );
    final filesByBucket = <String, File>{};
    for (final file in logicalRoot.listSync().whereType<File>()) {
      final envelope = jsonDecode(await file.readAsString()) as Map;
      filesByBucket[envelope['bucket']! as String] = file;
    }
    final digestFile = filesByBucket[digestBucket]!;
    final digestEnvelope = jsonDecode(await digestFile.readAsString()) as Map;
    digestEnvelope['bucketSha256'] = '0' * 64;
    await digestFile.writeAsString(jsonEncode(digestEnvelope), flush: true);
    await filesByBucket[brokenBucket]!.writeAsString('{', flush: true);

    final reloaded = await GameStorageService.create(
      gameId: 'com.playmesh.logical-damage',
      libraryRoot: root,
    );
    await expectLater(
      reloaded.getLogicalData(digestBucket, 'root'),
      throwsFormatException,
    );
    await expectLater(
      reloaded.getLogicalData(brokenBucket, 'root'),
      throwsFormatException,
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
    await storage.close();

    await GameStorageService.clearGameData(
      gameId: 'com.playmesh.demo',
      libraryRoot: root,
    );

    final data = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}com.playmesh.demo${Platform.pathSeparator}data',
    );
    expect(data.existsSync(), isFalse);
    expect(
      File(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}com.playmesh.demo'
        '${Platform.pathSeparator}.playmesh-storage.lock',
      ).existsSync(),
      isTrue,
    );
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
    await storage.close();
  });

  test('运行中的同项目实例阻止清除，全部关闭后才允许', () async {
    final first = await GameStorageService.create(
      gameId: 'com.playmesh.busy',
      libraryRoot: root,
    );
    final second = await GameStorageService.create(
      gameId: 'com.playmesh.busy',
      libraryRoot: root,
    );
    await first.setData('save', 'level', 8);

    await expectLater(
      GameStorageService.clearGameData(
        gameId: 'com.playmesh.busy',
        libraryRoot: root,
      ),
      throwsA(isA<GameStorageBusyException>()),
    );
    await first.close();
    await expectLater(
      GameStorageService.clearGameData(
        gameId: 'com.playmesh.busy',
        libraryRoot: root,
      ),
      throwsA(isA<GameStorageBusyException>()),
    );

    await second.close();
    final reloaded = await GameStorageService.create(
      gameId: 'com.playmesh.busy',
      libraryRoot: root,
    );
    expect(await reloaded.getData('save', 'level'), 8);
    await reloaded.close();
    await GameStorageService.clearGameData(
      gameId: 'com.playmesh.busy',
      libraryRoot: root,
    );
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}com.playmesh.busy'
        '${Platform.pathSeparator}data',
      ).existsSync(),
      isFalse,
    );
  });

  test('项目级锁不会阻塞其他 gameId 的清除', () async {
    final active = await GameStorageService.create(
      gameId: 'com.playmesh.active',
      libraryRoot: root,
    );
    final other = await GameStorageService.create(
      gameId: 'com.playmesh.other',
      libraryRoot: root,
    );
    await other.setData('save', 'ready', true);
    await other.close();

    await GameStorageService.clearGameData(
      gameId: 'com.playmesh.other',
      libraryRoot: root,
    );
    expect(
      Directory(
        '${root.path}${Platform.pathSeparator}packages'
        '${Platform.pathSeparator}com.playmesh.other'
        '${Platform.pathSeparator}data',
      ).existsSync(),
      isFalse,
    );
    await active.close();
  });

  test('游戏 API 拒绝保留 Bucket，平台头像使用固定路径原子写入', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-avatar-');
    addTearDown(() => root.delete(recursive: true));
    final storage = await GameStorageService.create(
      gameId: 'com.playmesh.avatar',
      libraryRoot: root,
    );
    expect(
      () => storage.setData('_sys-user-avatars', 'value', 1),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('平台保留前缀'),
        ),
      ),
    );
    final normalized = await AvatarImage.normalize(
      base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l'
        'EQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
      ),
    );
    final path = await storage.writeUserAvatar(
      playerId: 'u_avatar',
      pngBytes: normalized.pngBytes,
      sha256: normalized.sha256,
    );

    expect(path, '/bucket/_sys-user-avatars/u_avatar.png');
    expect(
      await storage.dataFile('_sys-user-avatars', 'u_avatar.png').readAsBytes(),
      normalized.pngBytes,
    );
    expect(await storage.avatarEtag('u_avatar'), contains(normalized.sha256));
    await storage.close();
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

  test('同项目多实例的交错写入共享同一 Bucket 状态', () async {
    final first = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance',
      libraryRoot: root,
    );
    final second = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance',
      libraryRoot: root,
    );
    addTearDown(first.close);
    addTearDown(second.close);

    // 先让两个实例各自加载空桶，稳定复现旧实现的分裂缓存。
    expect(await first.getData('save', 'missing'), isNull);
    expect(await second.getData('save', 'missing'), isNull);

    await first.setData('save', 'left', 1);
    await second.setData('save', 'right', 2);

    expect(await first.getData('save', 'right'), 2);
    expect(await second.getData('save', 'left'), 1);
  });

  test('同项目多实例的同 key 写入按调用顺序一致可见', () async {
    final first = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance-order',
      libraryRoot: root,
    );
    final second = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance-order',
      libraryRoot: root,
    );
    addTearDown(first.close);
    addTearDown(second.close);

    await first.setData('save', 'level', 1);
    await second.setData('save', 'level', 2);

    expect(await first.getData('save', 'level'), 2);
    expect(await second.getData('save', 'level'), 2);
  });

  test('关闭一个项目实例不会终止共享状态或其他实例', () async {
    final first = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance-close',
      libraryRoot: root,
    );
    final second = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance-close',
      libraryRoot: root,
    );
    await first.setData('save', 'beforeClose', true);

    await first.close();
    expect(await second.getData('save', 'beforeClose'), isTrue);
    await second.setData('save', 'afterClose', true);
    await second.close();

    final reloaded = await GameStorageService.create(
      gameId: 'com.playmesh.multi-instance-close',
      libraryRoot: root,
    );
    expect(await reloaded.getData('save', 'beforeClose'), isTrue);
    expect(await reloaded.getData('save', 'afterClose'), isTrue);
    await reloaded.close();
  });

  test('未落盘的逻辑桶已对同项目新实例可见', () async {
    const gameId = 'com.playmesh.multi-instance-live';
    const bucket = 'GDevelop/临时存档';
    final first = await GameStorageService.create(
      gameId: gameId,
      libraryRoot: root,
    );
    final second = await GameStorageService.create(
      gameId: gameId,
      libraryRoot: root,
    );
    addTearDown(first.close);
    addTearDown(second.close);

    await first.setLogicalData(bucket, 'root', {'scene': 4});
    final logicalDirectory = Directory(
      '${root.path}${Platform.pathSeparator}packages'
      '${Platform.pathSeparator}$gameId${Platform.pathSeparator}data'
      '${Platform.pathSeparator}json${Platform.pathSeparator}logical',
    );
    expect(logicalDirectory.existsSync(), isFalse);
    expect(await second.getLogicalData(bucket, 'root'), {'scene': 4});
  });

  test('不同 gameId 的存储队列可并行工作且状态隔离', () async {
    final first = await GameStorageService.create(
      gameId: 'com.playmesh.parallel-one',
      libraryRoot: root,
    );
    final second = await GameStorageService.create(
      gameId: 'com.playmesh.parallel-two',
      libraryRoot: root,
    );
    addTearDown(first.close);
    addTearDown(second.close);

    await Future.wait([
      first.setData('save', 'owner', 'one'),
      second.setData('save', 'owner', 'two'),
    ]);
    expect(await first.getData('save', 'owner'), 'one');
    expect(await second.getData('save', 'owner'), 'two');
  });
}
