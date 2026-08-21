import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/local_version_store.dart';

void main() {
  test('同一项目的两个 Store 实例串行提交并拒绝过期修订', () async {
    final root = await Directory.systemTemp.createTemp('local-version-store-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(root: root);
    final secondStore = LocalVersionStore(root: root);
    final draft = LocalVersionDraft(
      content: Uint8List.fromList([1, 2, 3]),
      attributes: const {'kind': 'test'},
    );

    Future<Object> capture(Future<Object> operation) async {
      try {
        return await operation;
      } on Object catch (error) {
        return error;
      }
    }

    final results = await Future.wait<Object>([
      capture(
        secondStore.commit(
          namespace: 'test:one',
          expectedRevision: 0,
          current: draft,
          history: [draft],
        ),
      ),
      capture(
        store.commit(
          namespace: 'test:one',
          expectedRevision: 0,
          current: draft,
          history: [draft],
        ),
      ),
    ]);

    expect(results.whereType<LocalVersionCommitResult>(), hasLength(1));
    expect(results.whereType<LocalVersionRevisionConflict>(), hasLength(1));
    expect(await store.list('test:one'), hasLength(1));
  });

  test('不同项目拥有独立锁，不被另一项目阻塞', () async {
    final base = await Directory.systemTemp.createTemp(
      'local-version-parallel-',
    );
    addTearDown(() => base.delete(recursive: true));
    final rootA = Directory('${base.path}${Platform.pathSeparator}project-a');
    final rootB = Directory('${base.path}${Platform.pathSeparator}project-b');
    final storeA = LocalVersionStore(root: rootA);
    final storeB = LocalVersionStore(root: rootB);
    final draft = LocalVersionDraft(
      content: Uint8List.fromList([7]),
      attributes: const {'kind': 'parallel'},
    );

    final results = await Future.wait([
      storeA.commit(
        namespace: 'test:parallel',
        expectedRevision: 0,
        current: draft,
        history: [draft],
      ),
      storeB.commit(
        namespace: 'test:parallel',
        expectedRevision: 0,
        current: draft,
        history: [draft],
      ),
    ]).timeout(const Duration(seconds: 1));
    expect(results, hasLength(2));
    expect(await storeA.list('test:parallel'), hasLength(1));
    expect(await storeB.list('test:parallel'), hasLength(1));
  });

  test('批量 stage 保持输入顺序且整批只执行一次 GC', () async {
    final root = await Directory.systemTemp.createTemp(
      'local-version-stage-batch-',
    );
    addTearDown(() => root.delete(recursive: true));
    var garbageCollections = 0;
    final store = LocalVersionStore(
      root: root,
      onGarbageCollection: () => garbageCollections += 1,
    );
    final contents = [
      Uint8List.fromList([1]),
      Uint8List.fromList([2]),
      Uint8List.fromList([3]),
    ];

    final first = await store.stageObjects(contents);

    expect(first.map((reference) => reference.bytes), [1, 1, 1]);
    expect(garbageCollections, 1);

    garbageCollections = 0;
    final second = await store.stageObjects(contents);

    expect(second.map((reference) => reference.hash), first.map((e) => e.hash));
    expect(garbageCollections, 1);
  });

  test('内存对象命中 CAS 时不创建临时文件且不刷新目标 mtime', () async {
    final root = await Directory.systemTemp.createTemp(
      'local-version-stage-hit-',
    );
    addTearDown(() => root.delete(recursive: true));
    final fixedClock = DateTime.now().toUtc();
    final store = LocalVersionStore(
      root: root,
      clock: () => fixedClock,
      retentionPolicy: const LocalVersionRetentionPolicy(
        stagingTtl: Duration.zero,
      ),
    );
    final content = Uint8List.fromList([90, 91, 92]);
    final existing = await store.stageObject(content);
    final target = File(
      '${root.path}${Platform.pathSeparator}cas${Platform.pathSeparator}'
      '${existing.hash}.blob',
    );
    final preservedMtime = DateTime.fromMillisecondsSinceEpoch(
      fixedClock.millisecondsSinceEpoch -
          const Duration(hours: 1).inMilliseconds,
      isUtc: true,
    );
    await target.setLastModified(preservedMtime);
    final targetMtimeBeforeHit = (await target.stat()).modified;
    final blockedTemporary = Directory(
      '${target.path}.tmp-${fixedClock.microsecondsSinceEpoch}',
    );
    await blockedTemporary.create();
    final blockedStaging = File('${root.path}${Platform.pathSeparator}staging');
    await blockedStaging.writeAsString('不应创建流式临时文件');

    final staged = await store.stageObject(content);

    expect(staged.hash, existing.hash);
    expect(staged.bytes, existing.bytes);
    expect(
      (await target.stat()).modified.millisecondsSinceEpoch,
      targetMtimeBeforeHit.millisecondsSinceEpoch,
    );
    expect(await blockedTemporary.exists(), isTrue);
    expect(await blockedStaging.readAsString(), '不应创建流式临时文件');
  });

  test('两个 Store 实例并发批量 stage 同一对象时串行复用 CAS', () async {
    final root = await Directory.systemTemp.createTemp(
      'local-version-stage-serial-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(root: root);
    final secondStore = LocalVersionStore(root: root);
    final contents = [
      Uint8List.fromList([4, 5, 6]),
      Uint8List.fromList([7, 8, 9]),
    ];

    final results = await Future.wait([
      store.stageObjects(contents),
      secondStore.stageObjects(contents),
    ]);

    expect(
      results[0].map((reference) => reference.hash),
      results[1].map((reference) => reference.hash),
    );
    final cas = Directory('${root.path}${Platform.pathSeparator}cas');
    expect(
      await cas
          .list(followLinks: false)
          .where((entity) => entity is File && entity.path.endsWith('.blob'))
          .length,
      2,
    );
  });

  test('流式上传字节不足会清理临时文件', () async {
    final root = await Directory.systemTemp.createTemp('local-version-stream-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(root: root);

    await expectLater(
      store.stageStream(Stream.value([1, 2]), expectedBytes: 3),
      throwsA(isA<FormatException>()),
    );

    final staging = Directory('${root.path}${Platform.pathSeparator}staging');
    expect(await staging.list().toList(), isEmpty);
  });

  test('流式上传不依赖 Content-Length，仍按实际字节和独立上限裁决', () async {
    final root = await Directory.systemTemp.createTemp(
      'local-version-chunked-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(root: root);

    final staged = await store.stageStream(
      Stream.fromIterable(const [
        [1, 2],
        [3, 4],
      ]),
      maxBytes: 4,
    );
    expect(staged.bytes, 4);
    expect(await store.readObject(staged), [1, 2, 3, 4]);

    await expectLater(
      store.stageStream(Stream.value([1, 2, 3]), maxBytes: 2),
      throwsA(
        isA<LocalVersionQuotaExceeded>()
            .having((error) => error.scope, 'scope', 'object')
            .having((error) => error.limit, 'limit', 2),
      ),
    );
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');
    expect(await staging.list().toList(), isEmpty);
  });

  test('流式上传命中 expectedHash 时不创建 staging 临时文件', () async {
    final root = await Directory.systemTemp.createTemp(
      'local-version-stream-hit-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(root: root);
    final content = Uint8List.fromList([10, 20, 30]);
    final existing = await store.stageObject(content);
    final staging = File('${root.path}${Platform.pathSeparator}staging');
    await staging.writeAsString('命中 CAS 时不应访问此路径');

    final staged = await store.stageStream(
      Stream.value(content),
      expectedBytes: content.length,
      expectedHash: existing.hash,
    );

    expect(staged.hash, existing.hash);
    expect(staged.bytes, existing.bytes);
    expect(await staging.readAsString(), '命中 CAS 时不应访问此路径');
  });

  test('流式上传空闲超时会清理临时文件', () async {
    final root = await Directory.systemTemp.createTemp(
      'local-version-timeout-',
    );
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(root: root);
    final controller = StreamController<List<int>>();
    addTearDown(controller.close);

    await expectLater(
      store.stageStream(
        controller.stream,
        expectedBytes: 1,
        timeout: const Duration(milliseconds: 10),
      ),
      throwsA(isA<TimeoutException>()),
    );

    final staging = Directory('${root.path}${Platform.pathSeparator}staging');
    expect(await staging.list().toList(), isEmpty);
  });

  test('413 配额失败不污染已提交 current 和 history', () async {
    final root = await Directory.systemTemp.createTemp('local-version-quota-');
    addTearDown(() => root.delete(recursive: true));
    final store = LocalVersionStore(
      root: root,
      retentionPolicy: const LocalVersionRetentionPolicy(
        maxVersionsPerNamespace: 3,
        maxUniqueBytesPerNamespace: 32,
        maxObjectBytes: 64,
      ),
    );
    final initial = LocalVersionDraft(
      content: Uint8List.fromList([1, 2, 3]),
      attributes: const {'kind': 'initial'},
    );
    await store.commit(
      namespace: 'test:quota',
      expectedRevision: 0,
      current: initial,
      history: [initial],
    );
    final before = await store.current('test:quota');

    final staged = await store.stageObject(Uint8List(30));
    final oversized = LocalVersionDraft(
      content: Uint8List.fromList([4, 5, 6]),
      attributes: const {'kind': 'oversized'},
      references: [staged],
    );
    await expectLater(
      store.commit(
        namespace: 'test:quota',
        expectedRevision: 1,
        current: oversized,
        history: [oversized],
      ),
      throwsA(isA<LocalVersionQuotaExceeded>()),
    );

    expect(
      (await store.current('test:quota'))?.contentHash,
      before?.contentHash,
    );
    expect(await store.list('test:quota'), hasLength(1));
  });

  test('一个项目的配额失败不淘汰其他项目', () async {
    final base = await Directory.systemTemp.createTemp(
      'local-version-isolated-',
    );
    addTearDown(() => base.delete(recursive: true));
    const policy = LocalVersionRetentionPolicy(
      maxVersionsPerNamespace: 3,
      maxUniqueBytesPerNamespace: 32,
      maxObjectBytes: 64,
    );
    final storeA = LocalVersionStore(
      root: Directory('${base.path}${Platform.pathSeparator}project-a'),
      retentionPolicy: policy,
    );
    final storeB = LocalVersionStore(
      root: Directory('${base.path}${Platform.pathSeparator}project-b'),
      retentionPolicy: policy,
    );
    final initial = LocalVersionDraft(
      content: Uint8List.fromList([1, 2, 3]),
      attributes: const {'kind': 'initial'},
    );
    await storeB.commit(
      namespace: 'test:isolation',
      expectedRevision: 0,
      current: initial,
      history: [initial],
    );
    final oversizedReference = await storeA.stageObject(Uint8List(30));
    final oversized = LocalVersionDraft(
      content: Uint8List.fromList([4, 5, 6]),
      attributes: const {'kind': 'oversized'},
      references: [oversizedReference],
    );

    await expectLater(
      storeA.commit(
        namespace: 'test:isolation',
        expectedRevision: 0,
        current: oversized,
        history: [oversized],
      ),
      throwsA(isA<LocalVersionQuotaExceeded>()),
    );
    expect(await storeB.list('test:isolation'), hasLength(1));
    expect(
      await storeB.readRecordContent(
        (await storeB.list('test:isolation')).single,
      ),
      [1, 2, 3],
    );
  });

  test('项目删除只清理自身 Store 目录', () async {
    final base = await Directory.systemTemp.createTemp('local-version-delete-');
    addTearDown(() async {
      if (await base.exists()) await base.delete(recursive: true);
    });
    final rootA = Directory('${base.path}${Platform.pathSeparator}project-a');
    final rootB = Directory('${base.path}${Platform.pathSeparator}project-b');
    final storeA = LocalVersionStore(root: rootA);
    final storeB = LocalVersionStore(root: rootB);
    final draft = LocalVersionDraft(
      content: Uint8List.fromList([1]),
      attributes: const {'kind': 'delete'},
    );
    await storeA.commit(
      namespace: 'test:delete',
      expectedRevision: 0,
      current: draft,
      history: [draft],
    );
    await storeB.commit(
      namespace: 'test:delete',
      expectedRevision: 0,
      current: draft,
      history: [draft],
    );

    await storeA.deleteStore();
    expect(await rootA.exists(), isFalse);
    expect(await rootB.exists(), isTrue);
    expect(await storeB.list('test:delete'), hasLength(1));
  });

  test('状态写入失败仅让当前项目事务失败', () async {
    final base = await Directory.systemTemp.createTemp('local-version-disk-');
    addTearDown(() => base.delete(recursive: true));
    final rootA = Directory('${base.path}${Platform.pathSeparator}project-a');
    final rootB = Directory('${base.path}${Platform.pathSeparator}project-b');
    await Directory(
      '${rootA.path}${Platform.pathSeparator}state.json',
    ).create(recursive: true);
    final storeA = LocalVersionStore(root: rootA);
    final storeB = LocalVersionStore(root: rootB);
    final draft = LocalVersionDraft(
      content: Uint8List.fromList([9]),
      attributes: const {'kind': 'disk-failure'},
    );
    await storeB.commit(
      namespace: 'test:disk',
      expectedRevision: 0,
      current: draft,
      history: [draft],
    );

    await expectLater(
      storeA.commit(
        namespace: 'test:disk',
        expectedRevision: 0,
        current: draft,
        history: [draft],
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await storeB.list('test:disk'), hasLength(1));
  });
}
