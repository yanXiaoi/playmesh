import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_config_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

void main() {
  test('读取 schema v2、迁移 v1，并将损坏、未知版本和超限文件标为 invalid', () async {
    final fixture = await _ConfigFixture.create('com.example.strict-config');
    addTearDown(fixture.close);

    expect(
      (await fixture.store.read(fixture.gameId)).status,
      GDevelopProjectConfigStatus.missing,
    );

    final ready = await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.single,
      expectedRevision: 0,
    );
    expect(ready.revision, 1);
    expect(
      (await fixture.store.read(fixture.gameId)).config?.gameType,
      GDevelopProjectGameType.single,
    );

    await fixture.configFile.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'gameId': fixture.gameId,
        'revision': 2,
        'gameType': 'online',
        'updatedAt': '2026-08-05T00:00:00.000Z',
      }),
    );
    final migrated = (await fixture.store.read(fixture.gameId)).config!;
    expect(migrated.gameType, GDevelopProjectGameType.online);
    expect(migrated.minPlayers, 2);
    expect(migrated.maxPlayers, 5);
    expect(migrated.tags, isEmpty);
    expect(migrated.toJson()['schemaVersion'], 2);

    await fixture.configFile.writeAsString('{not-json');
    expect(
      (await fixture.store.read(fixture.gameId)).status,
      GDevelopProjectConfigStatus.invalid,
    );

    await fixture.configFile.writeAsString(
      jsonEncode({
        'schemaVersion': 999,
        'gameId': fixture.gameId,
        'revision': 1,
        'gameType': 'online',
        'updatedAt': '2026-08-05T00:00:00.000Z',
      }),
    );
    final unknown = await fixture.store.read(fixture.gameId);
    expect(unknown.status, GDevelopProjectConfigStatus.invalid);
    expect(unknown.config, isNull, reason: '未知 schema 不能猜成 online');

    await fixture.configFile.writeAsBytes(
      List<int>.filled(GDevelopProjectConfigStore.maxBytes + 1, 0x20),
    );
    expect(
      (await fixture.store.read(fixture.gameId)).status,
      GDevelopProjectConfigStatus.invalid,
    );
  });

  test('严格拒绝额外字段、错误 gameId、非法类型和畸形 UTF-8', () async {
    final fixture = await _ConfigFixture.create('com.example.strict-fields');
    addTearDown(fixture.close);
    final valid = <String, Object?>{
      'schemaVersion': 2,
      'gameId': fixture.gameId,
      'revision': 1,
      'gameType': 'single',
      'minPlayers': 1,
      'maxPlayers': 1,
      'tags': <String>[],
      'updatedAt': '2026-08-05T00:00:00.000Z',
    };

    for (final invalid in <Object>[
      {...valid, 'extra': true},
      {...valid, 'gameId': 'com.example.someone-else'},
      {...valid, 'gameType': 'multiplayer'},
    ]) {
      await fixture.configFile.writeAsString(jsonEncode(invalid));
      expect(
        (await fixture.store.read(fixture.gameId)).status,
        GDevelopProjectConfigStatus.invalid,
      );
    }
    await fixture.configFile.writeAsBytes(const [0xc3, 0x28]);
    expect(
      (await fixture.store.read(fixture.gameId)).status,
      GDevelopProjectConfigStatus.invalid,
    );

    await fixture.configFile.delete();
    await Directory(fixture.configFile.path).create();
    expect(
      (await fixture.store.read(fixture.gameId)).status,
      GDevelopProjectConfigStatus.invalid,
      reason: '路径类型或 IO 读取异常也必须 fail-safe',
    );
  });

  test('PUT 使用 revision CAS，冲突携带当前 revision 且不覆盖文件', () async {
    final fixture = await _ConfigFixture.create('com.example.config-cas');
    addTearDown(fixture.close);

    final first = await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.single,
      expectedRevision: 0,
    );
    final second = await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.online,
      expectedRevision: first.revision,
    );
    expect(second.revision, 2);

    await expectLater(
      fixture.store.put(
        gameId: fixture.gameId,
        gameType: GDevelopProjectGameType.single,
        expectedRevision: 1,
      ),
      throwsA(
        isA<GDevelopProjectConfigRevisionConflict>().having(
          (error) => error.currentRevision,
          'currentRevision',
          2,
        ),
      ),
    );
    expect(
      (await fixture.store.read(fixture.gameId)).config?.gameType,
      GDevelopProjectGameType.online,
    );
  });

  test('原子替换失败会从 backup 恢复旧配置并清理 temp', () async {
    var failNextInstall = false;
    final fixture = await _ConfigFixture.create(
      'com.example.config-recovery',
      renameFile: (source, destination) async {
        if (failNextInstall &&
            source.path.endsWith('.tmp') &&
            destination.endsWith('project-config.json')) {
          failNextInstall = false;
          throw FileSystemException('injected install failure', source.path);
        }
        return source.rename(destination);
      },
    );
    addTearDown(fixture.close);
    await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.single,
      expectedRevision: 0,
    );

    failNextInstall = true;
    await expectLater(
      fixture.store.put(
        gameId: fixture.gameId,
        gameType: GDevelopProjectGameType.online,
        expectedRevision: 1,
      ),
      throwsA(isA<FileSystemException>()),
    );

    final recovered = await fixture.store.read(fixture.gameId);
    expect(recovered.status, GDevelopProjectConfigStatus.ready);
    expect(recovered.config?.revision, 1);
    expect(recovered.config?.gameType, GDevelopProjectGameType.single);
    expect(await File('${fixture.configFile.path}.tmp').exists(), isFalse);
    expect(await File('${fixture.configFile.path}.backup').exists(), isFalse);
  });

  test('进程中断仅留下 backup/temp 时，下次读取恢复已提交配置', () async {
    final fixture = await _ConfigFixture.create('com.example.config-crash');
    addTearDown(fixture.close);
    final backup = File('${fixture.configFile.path}.backup');
    await backup.parent.create(recursive: true);
    await backup.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'gameId': fixture.gameId,
        'revision': 7,
        'gameType': 'online',
        'updatedAt': '2026-08-05T00:00:00.000Z',
      }),
    );
    await File('${fixture.configFile.path}.tmp').writeAsString('partial');

    final recovered = await fixture.store.read(fixture.gameId);
    expect(recovered.status, GDevelopProjectConfigStatus.ready);
    expect(recovered.config?.revision, 7);
    expect(recovered.config?.gameType, GDevelopProjectGameType.online);
    expect(await fixture.configFile.exists(), isTrue);
    expect(await backup.exists(), isFalse);
    expect(await File('${fixture.configFile.path}.tmp').exists(), isFalse);
  });

  test('同项目写入串行，不同项目可以并行进入原子替换', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-config-tail-');
    addTearDown(() => root.delete(recursive: true));
    final resolver = FileSystemGDevelopProjectRootResolver(projectsRoot: root);
    for (final gameId in const [
      'com.example.serial-a',
      'com.example.parallel-b',
    ]) {
      await resolver.ensureProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
        name: gameId,
      );
    }
    final entered = <String>[];
    final releaseFirst = Completer<void>();
    final firstEntered = Completer<void>();
    final otherEntered = Completer<void>();
    Future<File> renameFile(File source, String destination) async {
      if (!source.path.endsWith('.tmp')) {
        return source.rename(destination);
      }
      final gameId = source.path.contains('serial-a')
          ? 'serial-a'
          : 'parallel-b';
      entered.add(gameId);
      if (gameId == 'parallel-b' && !otherEntered.isCompleted) {
        otherEntered.complete();
      }
      if (!firstEntered.isCompleted) {
        firstEntered.complete();
        await releaseFirst.future;
      }
      return source.rename(destination);
    }

    final firstStore = GDevelopProjectConfigStore(
      rootResolver: resolver,
      renameFile: renameFile,
    );
    final secondStore = GDevelopProjectConfigStore(
      rootResolver: resolver,
      renameFile: renameFile,
    );

    final first = firstStore.put(
      gameId: 'com.example.serial-a',
      gameType: GDevelopProjectGameType.single,
      expectedRevision: 0,
    );
    await firstEntered.future;
    final sameProject = secondStore.put(
      gameId: 'com.example.serial-a',
      gameType: GDevelopProjectGameType.online,
      expectedRevision: 1,
    );
    final otherProject = secondStore.put(
      gameId: 'com.example.parallel-b',
      gameType: GDevelopProjectGameType.online,
      expectedRevision: 0,
    );
    try {
      await otherEntered.future.timeout(const Duration(seconds: 2));
      expect(entered, contains('parallel-b'));
      expect(entered.where((value) => value == 'serial-a'), hasLength(1));
    } finally {
      if (!releaseFirst.isCompleted) releaseFirst.complete();
    }
    await Future.wait([first, sameProject, otherProject]);
    expect(entered.where((value) => value == 'serial-a'), hasLength(2));
  });

  test('新项目 single 初始化是 best-effort，旧 missing 项目不会自动写入', () async {
    final repository = _ThrowingConfigRepository();
    final controller = GDevelopProjectConfigController(repository);
    expect(
      await controller.initializeNewProject('com.example.best-effort'),
      isFalse,
    );
    expect(repository.putCalls, 1);
    expect(repository.lastGameType, GDevelopProjectGameType.single);

    final missing = await controller.read('com.example.legacy');
    expect(missing.status, GDevelopProjectConfigStatus.missing);
    expect(repository.putCalls, 1, reason: '读取旧项目不得偷偷初始化 sidecar');
  });

  test('prepared target 仅在 exact-old 写入，exact-target 幂等，第三态冲突', () async {
    final fixture = await _ConfigFixture.create('com.example.config-exact');
    addTearDown(fixture.close);
    await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.single,
      expectedRevision: 0,
    );
    final oldEvidence = await fixture.store.inspect(fixture.gameId);
    final targetConfig = GDevelopProjectConfig(
      gameId: fixture.gameId,
      revision: 5,
      gameType: GDevelopProjectGameType.online,
      minPlayers: 2,
      maxPlayers: 8,
      tags: const ['party'],
      updatedAt: DateTime.utc(2026, 8, 5, 6, 7, 8),
    );
    final targetEvidence = await GDevelopProjectConfigEvidence.forReady(
      targetConfig,
    );

    final applied = await fixture.store.applyPreparedTarget(
      gameId: fixture.gameId,
      oldEvidence: oldEvidence,
      targetEvidence: targetEvidence,
    );
    expect(applied.matches(targetEvidence), isTrue);
    expect(
      (await fixture.store.applyPreparedTarget(
        gameId: fixture.gameId,
        oldEvidence: oldEvidence,
        targetEvidence: targetEvidence,
      )).matches(targetEvidence),
      isTrue,
      reason: '响应丢失后 exact-target 必须稳定成功',
    );
    expect(
      await GDevelopProjectConfigEvidence.contentHashFor(targetConfig),
      targetEvidence.contentHash,
      reason: 'prepare 固定的 bytes/updatedAt 必须与落盘内容一致',
    );

    await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.single,
      expectedRevision: targetConfig.revision,
    );
    await expectLater(
      fixture.store.applyPreparedTarget(
        gameId: fixture.gameId,
        oldEvidence: oldEvidence,
        targetEvidence: targetEvidence,
      ),
      throwsA(isA<GDevelopProjectConfigApplyConflict>()),
    );
  });

  test('prepared explicit missing 原子删除 sidecar 并可重复前滚', () async {
    final fixture = await _ConfigFixture.create('com.example.config-missing');
    addTearDown(fixture.close);
    await fixture.store.put(
      gameId: fixture.gameId,
      gameType: GDevelopProjectGameType.online,
      expectedRevision: 0,
    );
    final oldEvidence = await fixture.store.inspect(fixture.gameId);
    const targetEvidence = GDevelopProjectConfigEvidence.missing();

    final deleted = await fixture.store.applyPreparedTarget(
      gameId: fixture.gameId,
      oldEvidence: oldEvidence,
      targetEvidence: targetEvidence,
    );
    expect(deleted.status, GDevelopProjectConfigStatus.missing);
    expect(await fixture.configFile.exists(), isFalse);
    expect(
      (await fixture.store.applyPreparedTarget(
        gameId: fixture.gameId,
        oldEvidence: oldEvidence,
        targetEvidence: targetEvidence,
      )).status,
      GDevelopProjectConfigStatus.missing,
    );
  });
}

class _ConfigFixture {
  _ConfigFixture({
    required this.root,
    required this.gameId,
    required this.store,
  });

  final Directory root;
  final String gameId;
  final GDevelopProjectConfigStore store;

  File get configFile => File(
    '${root.path}${Platform.pathSeparator}$gameId'
    '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
    '${Platform.pathSeparator}project-config.json',
  );

  Future<void> close() => root.delete(recursive: true);

  static Future<_ConfigFixture> create(
    String gameId, {
    Future<File> Function(File source, String destination)? renameFile,
  }) async {
    final root = await Directory.systemTemp.createTemp('gdevelop-config-');
    final resolver = FileSystemGDevelopProjectRootResolver(projectsRoot: root);
    await resolver.ensureProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: gameId,
    );
    return _ConfigFixture(
      root: root,
      gameId: gameId,
      store: GDevelopProjectConfigStore(
        rootResolver: resolver,
        clock: () => DateTime.utc(2026, 8, 5, 1, 2, 3),
        renameFile: renameFile,
      ),
    );
  }
}

class _ThrowingConfigRepository implements GDevelopProjectConfigRepository {
  int putCalls = 0;
  GDevelopProjectGameType? lastGameType;

  @override
  Future<GDevelopProjectConfigReadResult> read(String gameId) async =>
      const GDevelopProjectConfigReadResult.missing();

  @override
  Future<GDevelopProjectConfigEvidence> inspect(String gameId) async =>
      const GDevelopProjectConfigEvidence.missing();

  @override
  Future<GDevelopProjectConfigEvidence> applyPreparedTarget({
    required String gameId,
    required GDevelopProjectConfigEvidence oldEvidence,
    required GDevelopProjectConfigEvidence targetEvidence,
  }) async => targetEvidence;

  @override
  Future<GDevelopProjectConfig> put({
    required String gameId,
    required GDevelopProjectGameType gameType,
    int? minPlayers,
    int? maxPlayers,
    List<String>? tags,
    required int expectedRevision,
  }) async {
    putCalls += 1;
    lastGameType = gameType;
    throw StateError('gateway unavailable');
  }

  @override
  Future<void> deleteArtifacts(String gameId) async {}
}
