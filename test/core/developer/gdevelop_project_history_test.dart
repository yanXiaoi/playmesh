import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/local_version_store.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_files.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';

void main() {
  test('普通历史协议不包含 AI 专用 reason、source 或变更类型', () {
    expect(
      GDevelopHistoryReason.values.map((value) => value.wireName),
      equals(const [
        'explicit_save',
        'important_change',
        'autosave',
        'before_restore',
        'restore',
      ]),
    );
    expect(
      GDevelopHistorySource.values.map((value) => value.wireName),
      equals(const ['user', 'system']),
    );
    expect(
      GDevelopAuthoritativeProjectChangeReason.values,
      equals(const [
        GDevelopAuthoritativeProjectChangeReason.currentCommitted,
        GDevelopAuthoritativeProjectChangeReason.restored,
      ]),
    );
  });

  test('历史修订持久化文件与资源引用的 A/M/D 摘要', () async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-history-change-summary-',
    );
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.history-change-summary';
    final history = await _history(root, [gameId]);

    Future<GDevelopProjectResource> stageResource(
      String logicalId,
      List<int> bytes,
    ) async {
      final hash = await _hash(bytes);
      await history.stageResourceStream(
        projectId: gameId,
        expectedHash: hash,
        contentLength: bytes.length,
        bytes: Stream.value(bytes),
      );
      return GDevelopProjectResource(
        logicalId: logicalId,
        contentHash: hash,
        mime: 'application/octet-stream',
        size: bytes.length,
      );
    }

    final retained = await stageResource(
      'playmesh-local-resource://summary/retained.bin',
      [1, 2, 3],
    );
    final changedBefore = await stageResource(
      'playmesh-local-resource://summary/changed.bin',
      [4, 5, 6],
    );
    final first = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: const [
        GDevelopProjectFile(path: 'game.json', content: {'name': 'first'}),
        GDevelopProjectFile(
          path: 'externalEvents/Removed.json',
          content: {'events': []},
        ),
      ],
      resources: [retained, changedBefore],
    );
    final firstVersion = (await history.list(gameId)).single;
    expect(firstVersion.changeSummary?.toJson(), {
      'added': 4,
      'modified': 0,
      'deleted': 0,
    });

    final changedAfter = await stageResource(changedBefore.logicalId, [
      7,
      8,
      9,
    ]);
    final added = await stageResource(
      'playmesh-local-resource://summary/added.bin',
      [10, 11, 12],
    );
    await history.snapshot(
      projectId: gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: const [
        GDevelopProjectFile(path: 'game.json', content: {'name': 'second'}),
        GDevelopProjectFile(
          path: 'externalEvents/Added.json',
          content: {'events': []},
        ),
      ],
      resources: [retained, changedAfter, added],
    );

    final versions = await history.list(gameId);
    expect(versions, hasLength(2));
    expect(versions.first.changeSummary?.toJson(), {
      'added': 2,
      'modified': 2,
      'deleted': 1,
    });
    expect(versions.first.toJson(includeChangeSummary: true)['changeSummary'], {
      'added': 2,
      'modified': 2,
      'deleted': 1,
    });
  });

  test('旧历史缺少 changeSummary 时无需迁移且列表返回空摘要', () async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-history-legacy-summary-',
    );
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.history-legacy-summary';
    final history = await _history(root, [gameId]);
    await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'legacy'}),
      resources: const [],
    );

    File? historyStateFile;
    Map<String, Object?>? historyState;
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File ||
          !entity.path.endsWith('${Platform.pathSeparator}state.json')) {
        continue;
      }
      final decoded = jsonDecode(await entity.readAsString());
      if (decoded is! Map || decoded['namespaces'] is! Map) continue;
      final namespaces = decoded['namespaces']! as Map;
      if (!namespaces.containsKey('gdevelop.history.v3')) continue;
      historyStateFile = entity;
      historyState = Map<String, Object?>.from(decoded);
      break;
    }
    expect(historyStateFile, isNotNull);
    final namespaces = historyState!['namespaces']! as Map;
    final namespace = namespaces['gdevelop.history.v3']! as Map;
    final versions = namespace['versions']! as List;
    for (final rawVersion in versions) {
      ((rawVersion as Map)['attributes'] as Map).remove('changeSummary');
    }
    if (namespace['current'] case final Map current) {
      (current['attributes'] as Map).remove('changeSummary');
    }
    await historyStateFile!.writeAsString(
      jsonEncode(historyState),
      flush: true,
    );

    final legacyVersion = (await history.list(gameId)).single;
    expect(legacyVersion.changeSummary, isNull);
    expect(
      legacyVersion.toJson(includeChangeSummary: true),
      isNot(contains('changeSummary')),
    );
  });

  test('SaveAs 保持 gameId 与历史，复制新 gameId 独立', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-save-as-');
    addTearDown(() => root.delete(recursive: true));
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    const gameId = 'com.playmesh.game.gsaveasone';
    const copiedGameId = 'com.playmesh.game.gsaveastwo';
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      fileIdentifier: 'file-a',
      name: 'SaveAs Game',
    );
    await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'before save as'}),
      resources: const [],
    );

    final savedAs = await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.saveAs,
      fileIdentifier: 'file-b',
      name: 'SaveAs Game',
    );
    expect(savedAs.created, isFalse);
    expect(savedAs.fileIdentifiers, ['file-a', 'file-b']);
    expect(_rootProjectContent(await history.current(gameId)), {
      'name': 'before save as',
    });

    final copied = await history.createProjectRoot(
      gameId: copiedGameId,
      origin: GDevelopProjectEnsureOrigin.duplicate,
      fileIdentifier: 'file-copy',
      name: 'Copied Game',
    );
    expect(copied.created, isTrue);
    expect(await history.list(copiedGameId), isEmpty);
    expect(await history.list(gameId), hasLength(1));
  });

  test('diff 返回两侧资源证据且修订资源读取不跨快照回退', () async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-history-resource-evidence-',
    );
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.history-resource-evidence';
    final history = await _history(root, [gameId]);
    final beforeBytes = Uint8List.fromList([1, 2, 3, 4]);
    final afterBytes = Uint8List.fromList([5, 6, 7, 8, 9]);
    final beforeHash = await _hash(beforeBytes);
    final afterHash = await _hash(afterBytes);
    const beforeLogicalId =
        'playmesh-local-resource://history/sprite-before.png';
    const afterLogicalId = 'playmesh-local-resource://history/sprite-after.mp3';
    await history.stageResourceStream(
      projectId: gameId,
      expectedHash: beforeHash,
      contentLength: beforeBytes.length,
      bytes: Stream.value(beforeBytes),
    );
    final first = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {
        'resources': {
          'resources': [
            {'name': 'sprite', 'file': beforeLogicalId, 'kind': 'image'},
          ],
        },
      }),
      resources: [
        GDevelopProjectResource(
          logicalId: beforeLogicalId,
          name: 'sprite',
          contentHash: beforeHash,
          mime: 'image/png',
          size: beforeBytes.length,
        ),
      ],
    );
    await history.stageResourceStream(
      projectId: gameId,
      expectedHash: afterHash,
      contentLength: afterBytes.length,
      bytes: Stream.value(afterBytes),
    );
    final second = await history.snapshot(
      projectId: gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {
        'resources': {
          'resources': [
            {'name': 'sprite', 'file': afterLogicalId, 'kind': 'audio'},
          ],
        },
      }),
      resources: [
        GDevelopProjectResource(
          logicalId: afterLogicalId,
          name: 'sprite',
          contentHash: afterHash,
          mime: 'audio/mpeg',
          size: afterBytes.length,
        ),
      ],
    );

    final diff = await history.diff(
      projectId: gameId,
      fromRevision: first.version.revision,
      toRevision: second.version.revision,
    );
    expect(diff.beforeResources.single.logicalId, beforeLogicalId);
    expect(diff.beforeResources.single.contentHash, beforeHash);
    expect(diff.afterResources.single.logicalId, afterLogicalId);
    expect(diff.afterResources.single.contentHash, afterHash);
    expect(diff.toJson()['resourceEvidence'], {
      'before': [diff.beforeResources.single.toJson()],
      'after': [diff.afterResources.single.toJson()],
    });

    final before = await history.readResourceAtRevision(
      projectId: gameId,
      revision: first.version.revision,
      logicalId: beforeLogicalId,
      contentHash: beforeHash,
    );
    expect(before.bytes, beforeBytes);
    expect(before.resource.mime, 'image/png');
    final after = await history.readResourceAtRevision(
      projectId: gameId,
      revision: second.version.revision,
      logicalId: afterLogicalId,
      contentHash: afterHash,
    );
    expect(after.bytes, afterBytes);
    expect(after.resource.mime, 'audio/mpeg');
    await expectLater(
      history.readResourceAtRevision(
        projectId: gameId,
        revision: first.version.revision,
        logicalId: afterLogicalId,
        contentHash: afterHash,
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      history.readResourceAtRevision(
        projectId: gameId,
        revision: first.version.revision,
        logicalId: beforeLogicalId,
        contentHash: afterHash,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('历史引用保护图片、音频、字体和 3D 资源，零引用后才 GC', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-history-');
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.project-one';
    final history = await _history(
      root,
      [gameId],
      retentionPolicy: const LocalVersionRetentionPolicy(
        maxVersionsPerNamespace: 3,
      ),
    );
    final fixtures = <({String name, String mime, Uint8List bytes})>[
      (
        name: 'image.png',
        mime: 'image/png',
        bytes: Uint8List.fromList([1, 3, 5, 7]),
      ),
      (
        name: 'theme.mp3',
        mime: 'audio/mpeg',
        bytes: Uint8List.fromList([2, 4, 6, 8, 10]),
      ),
      (
        name: 'ui.woff2',
        mime: 'font/woff2',
        bytes: Uint8List.fromList([11, 13, 17, 19, 23, 29]),
      ),
      (
        name: 'level.glb',
        mime: 'model/gltf-binary',
        bytes: Uint8List.fromList([31, 37, 41, 43, 47, 53, 59]),
      ),
    ];
    final resources = <GDevelopProjectResource>[];
    final bytesByHash = <String, Uint8List>{};
    for (final fixture in fixtures) {
      final hash = await _hash(fixture.bytes);
      await history.stageResourceStream(
        projectId: gameId,
        expectedHash: hash,
        contentLength: fixture.bytes.length,
        bytes: Stream.value(fixture.bytes),
      );
      resources.add(
        GDevelopProjectResource(
          logicalId:
              'playmesh-local-resource://project/resource/${fixture.name}',
          name: fixture.name,
          contentHash: hash,
          mime: fixture.mime,
          size: fixture.bytes.length,
        ),
      );
      bytesByHash[hash] = fixture.bytes;
    }

    final first = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'first'}),
      resources: resources,
    );
    final second = await history.snapshot(
      projectId: gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'second'}),
      resources: const [],
    );

    for (final resource in resources) {
      final stillPinned = await history.readResource(
        projectId: gameId,
        contentHash: resource.contentHash,
      );
      expect(stillPinned.bytes, bytesByHash[resource.contentHash]);
    }

    final restored = await history.restore(
      projectId: gameId,
      baseRevision: second.version.revision,
      targetRevision: first.version.revision,
      source: GDevelopHistorySource.user,
      currentProjectFiles: _projectFiles(const {'name': 'unsaved-current'}),
      currentResources: const [],
    );

    expect(_rootProjectContent(restored), {'name': 'first'});
    expect(restored.resources.map((resource) => resource.mime).toSet(), {
      'image/png',
      'audio/mpeg',
      'font/woff2',
      'model/gltf-binary',
    });
    expect(restored.backupVersion?.reason, GDevelopHistoryReason.beforeRestore);
    for (final resource in restored.resources) {
      final downloaded = await history.readResource(
        projectId: gameId,
        contentHash: resource.contentHash,
      );
      expect(downloaded.bytes, bytesByHash[resource.contentHash]);
    }
    expect(_rootProjectContent(await history.current(gameId)), {
      'name': 'first',
    });

    final casRoot = Directory(
      '${root.path}${Platform.pathSeparator}$gameId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
      '${Platform.pathSeparator}history${Platform.pathSeparator}cas',
    );
    Future<void> expectResourceBlobs(bool exist) async {
      for (final resource in resources) {
        expect(
          await File(
            '${casRoot.path}${Platform.pathSeparator}'
            '${resource.contentHash}.blob',
          ).exists(),
          exist,
          reason: '${resource.mime} 应${exist ? '' : '不'}被历史引用保护',
        );
      }
    }

    for (final resource in resources) {
      await File(
        '${casRoot.path}${Platform.pathSeparator}'
        '${resource.contentHash}.blob',
      ).setLastModified(DateTime.now().subtract(const Duration(days: 2)));
    }
    var revision = restored.version.revision;
    for (var index = 0; index < 2; index += 1) {
      final next = await history.snapshot(
        projectId: gameId,
        baseRevision: revision,
        reason: GDevelopHistoryReason.importantChange,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles({'name': 'resource-free-$index'}),
        resources: const [],
      );
      revision = next.version.revision;
      await expectResourceBlobs(true);
    }
    await history.snapshot(
      projectId: gameId,
      baseRevision: revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'resource-free-final'}),
      resources: const [],
    );
    await expectResourceBlobs(false);
    for (final resource in resources) {
      await expectLater(
        history.readResource(
          projectId: gameId,
          contentHash: resource.contentHash,
        ),
        throwsA(isA<StateError>()),
      );
    }
  });

  test('state.json 保留 GDevelop 与其他历史命名空间且互不覆盖', () async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-history-namespace-',
    );
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.namespace-project';
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      fileIdentifier: 'namespace-file',
      name: 'Namespace Project',
    );
    final historyRoot = await resolver.resolveHistoryRoot(gameId);
    final sharedStore = LocalVersionStore(root: historyRoot);
    final sourceDraft = LocalVersionDraft(
      content: Uint8List.fromList([61, 67, 71]),
      attributes: const {'owner': 'source-editor'},
    );
    final sourceCommit = await sharedStore.commit(
      namespace: 'source.history.v1',
      expectedRevision: 0,
      current: sourceDraft,
      history: [sourceDraft],
    );

    final first = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'gdevelop-one'}),
      resources: const [],
    );
    await history.snapshot(
      projectId: gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'gdevelop-two'}),
      resources: const [],
    );

    final state =
        jsonDecode(
              await File(
                '${historyRoot.path}${Platform.pathSeparator}state.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(state['schemaVersion'], LocalVersionStore.schemaVersion);
    final namespaces = Map<String, Object?>.from(state['namespaces']! as Map);
    expect(
      namespaces.keys,
      containsAll(['gdevelop.history.v3', 'source.history.v1']),
    );
    final sourceState = Map<String, Object?>.from(
      namespaces['source.history.v1']! as Map,
    );
    final sourceCurrent = Map<String, Object?>.from(
      sourceState['current']! as Map,
    );
    expect(sourceCurrent['contentHash'], sourceCommit.current.contentHash);
    expect((sourceState['versions']! as List), hasLength(1));
    expect(
      (await sharedStore.current('source.history.v1'))?.contentHash,
      sourceCommit.current.contentHash,
    );
    expect(_rootProjectContent(await history.current(gameId)), {
      'name': 'gdevelop-two',
    });
  });

  test('错误项目不能读取其他项目 pin 的资源', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-authz-');
    addTearDown(() => root.delete(recursive: true));
    final history = await _history(root, [
      'com.example.owner-project',
      'com.example.other-project',
    ]);
    final bytes = Uint8List.fromList([2, 4, 6]);
    final hash = await _hash(bytes);
    await history.stageResourceStream(
      projectId: 'com.example.owner-project',
      expectedHash: hash,
      contentLength: bytes.length,
      bytes: Stream.value(bytes),
    );
    await history.snapshot(
      projectId: 'com.example.owner-project',
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'owner'}),
      resources: [_resource(hash, bytes.length)],
    );

    await expectLater(
      history.readResource(
        projectId: 'com.example.other-project',
        contentHash: hash,
      ),
      throwsA(isA<StateError>()),
    );

    final reference = LocalCasObjectReference(hash: hash, bytes: bytes.length);
    expect(
      await history.missingResources(
        projectId: 'com.example.other-project',
        resources: [reference],
      ),
      [
        isA<LocalCasObjectReference>()
            .having((value) => value.hash, 'hash', hash)
            .having((value) => value.bytes, 'bytes', bytes.length),
      ],
      reason: '项目 B 的 presence 不得看见项目 A 的 CAS',
    );
    await expectLater(
      history.snapshot(
        projectId: 'com.example.other-project',
        baseRevision: 0,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles(const {'name': 'other'}),
        resources: [_resource(hash, bytes.length)],
      ),
      throwsA(isA<LocalVersionObjectMissing>()),
    );
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}com.example.owner-project'
        '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
        '${Platform.pathSeparator}history${Platform.pathSeparator}cas'
        '${Platform.pathSeparator}$hash.blob',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${root.path}${Platform.pathSeparator}com.example.other-project'
        '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
        '${Platform.pathSeparator}history${Platform.pathSeparator}cas'
        '${Platform.pathSeparator}$hash.blob',
      ).exists(),
      isFalse,
    );

    await history.stageResourceStream(
      projectId: 'com.example.other-project',
      expectedHash: hash,
      contentLength: bytes.length,
      bytes: Stream.value(bytes),
    );
    await history.snapshot(
      projectId: 'com.example.other-project',
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'other'}),
      resources: [_resource(hash, bytes.length)],
    );
    expect(
      (await history.readResource(
        projectId: 'com.example.other-project',
        contentHash: hash,
      )).bytes,
      bytes,
      reason: '项目 B 自己上传同内容后才能使用',
    );
  });

  test('拒绝 projectId 和资源逻辑路径穿越', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-path-');
    addTearDown(() => root.delete(recursive: true));
    final history = await _history(root, const []);

    await expectLater(
      history.list('../outside'),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => GDevelopProjectResource.fromJson({
        'logicalId': '../asset.png',
        'contentHash': 'a' * 64,
        'mime': 'image/png',
        'size': 1,
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('恢复拒绝过期 baseRevision 且不切换 current', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-conflict-');
    addTearDown(() => root.delete(recursive: true));
    final history = await _history(root, ['com.example.conflict-project']);
    final first = await history.snapshot(
      projectId: 'com.example.conflict-project',
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'first'}),
      resources: const [],
    );

    await expectLater(
      history.restore(
        projectId: 'com.example.conflict-project',
        baseRevision: 0,
        targetRevision: first.version.revision,
        source: GDevelopHistorySource.user,
        currentProjectFiles: _projectFiles(const {'name': 'changed'}),
        currentResources: const [],
      ),
      throwsA(
        isA<GDevelopHistoryRevisionConflict>().having(
          (error) => error.currentRevision,
          'currentRevision',
          1,
        ),
      ),
    );
    expect(
      _rootProjectContent(
        await history.current('com.example.conflict-project'),
      ),
      {'name': 'first'},
    );
  });

  test('历史配额失败不回滚独立 current', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-quota-');
    addTearDown(() => root.delete(recursive: true));
    final history = await _history(
      root,
      ['com.example.quota-project'],
      retentionPolicy: const LocalVersionRetentionPolicy(
        maxVersionsPerNamespace: 2,
        maxUniqueBytesPerNamespace: 350,
        maxObjectBytes: 512,
      ),
    );
    final first = await history.snapshot(
      projectId: 'com.example.quota-project',
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'first'}),
      resources: const [],
    );
    final big = Uint8List(300);
    final hash = await _hash(big);
    await history.stageResourceStream(
      projectId: 'com.example.quota-project',
      expectedHash: hash,
      contentLength: big.length,
      bytes: Stream.value(big),
    );

    final second = await history.snapshot(
      projectId: 'com.example.quota-project',
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'second'}),
      resources: [_resource(hash, big.length)],
    );
    expect(second.historyCreated, isFalse);
    expect(
      _rootProjectContent(await history.current('com.example.quota-project')),
      {'name': 'second'},
    );
    expect(await history.list('com.example.quota-project'), hasLength(1));
  });

  test('history payload v3 区分 ready 与 explicit missing，且不污染官方工程', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-history-v2-');
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.history-v2';
    final history = await _history(root, [gameId]);
    final config = GDevelopProjectConfig(
      gameId: gameId,
      revision: 3,
      gameType: GDevelopProjectGameType.online,
      minPlayers: 3,
      maxPlayers: 9,
      tags: const ['合作', '动作'],
      updatedAt: DateTime.utc(2026, 8, 5, 2, 3, 4),
    );

    final first = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'official', 'properties': {}}),
      resources: const [],
      projectConfigSnapshot: GDevelopHistoryProjectConfigSnapshot.ready(config),
    );
    final ready = await history.current(gameId);
    expect(_rootProjectContent(ready), const {
      'name': 'official',
      'properties': {},
    });
    expect(
      _rootProjectContent(ready),
      isNot(contains('playmeshProjectConfig')),
    );
    expect(
      ready?.projectConfigSnapshot.semantics,
      GDevelopHistoryProjectConfigSemantics.ready,
    );
    expect(ready?.toJson()['playmeshProjectConfig'], config.toJson());

    await history.snapshot(
      projectId: gameId,
      baseRevision: first.version.revision,
      reason: GDevelopHistoryReason.importantChange,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'missing-config'}),
      resources: const [],
      projectConfigSnapshot:
          const GDevelopHistoryProjectConfigSnapshot.missing(),
    );
    final missing = await history.current(gameId);
    expect(
      missing?.projectConfigSnapshot.semantics,
      GDevelopHistoryProjectConfigSemantics.missing,
    );
    expect(missing?.toJson(), containsPair('playmeshProjectConfig', null));

    final store = LocalVersionStore(
      root: await history.rootResolver.resolveHistoryRoot(gameId),
    );
    final record = await store.current('gdevelop.history.v3');
    final payload =
        jsonDecode(utf8.decode(await store.readRecordContent(record!)))
            as Map<String, Object?>;
    expect(payload['schemaVersion'], 3);
    expect(payload, containsPair('playmeshProjectConfig', null));
  });

  test('删除 history 后 current 源码与资源仍可打开', () async {
    final root = await Directory.systemTemp.createTemp('gdevelop-split-');
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.split-current-history';
    final history = await _history(root, [gameId]);
    final bytes = Uint8List.fromList([8, 6, 7, 5, 3, 0, 9]);
    final hash = await _hash(bytes);
    await history.stageResourceStream(
      projectId: gameId,
      expectedHash: hash,
      contentLength: bytes.length,
      bytes: Stream.value(bytes),
    );
    final saved = await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'independent-current'}),
      resources: [_resource(hash, bytes.length)],
    );
    expect(saved.historyCreated, isTrue);
    expect(await history.list(gameId), hasLength(1));

    await history.clearHistory(gameId);

    expect(await history.list(gameId), isEmpty);
    final current = await history.current(gameId);
    expect(_rootProjectContent(current), const {'name': 'independent-current'});
    expect(current?.version.revision, saved.version.revision);
    expect(
      (await history.readResource(projectId: gameId, contentHash: hash)).bytes,
      bytes,
    );
    final sourceRoot = Directory(
      '${root.path}${Platform.pathSeparator}$gameId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
      '${Platform.pathSeparator}source${Platform.pathSeparator}current',
    );
    expect(
      await File(
        '${sourceRoot.path}${Platform.pathSeparator}project'
        '${Platform.pathSeparator}game.json',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${sourceRoot.path}${Platform.pathSeparator}manifest.json',
      ).exists(),
      isTrue,
    );
    final sourceResources = Directory(
      '${sourceRoot.path}${Platform.pathSeparator}resources',
    );
    expect(
      await File(
        '${sourceResources.path}${Platform.pathSeparator}'
        '$hash.blob',
      ).readAsBytes(),
      bytes,
    );
    final historyRoot = Directory(
      '${root.path}${Platform.pathSeparator}$gameId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
      '${Platform.pathSeparator}history',
    );
    expect(
      await File(
        '${historyRoot.path}${Platform.pathSeparator}state.json',
      ).exists(),
      isFalse,
    );
    expect(
      await Directory(
        '${historyRoot.path}${Platform.pathSeparator}cas',
      ).exists(),
      isFalse,
    );
  });

  test('resource presence uses only the current manifest', () async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-presence-batch-',
    );
    addTearDown(() => root.delete(recursive: true));
    const gameId = 'com.example.presence-batch';
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    var bundleVerificationCount = 0;
    final history = GDevelopProjectHistoryAdapter(
      rootResolver: resolver,
      onCurrentBundleVerification: () => bundleVerificationCount += 1,
    );
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      name: gameId,
    );

    final resourceBytes = <Uint8List>[
      Uint8List.fromList([1, 2, 3]),
      Uint8List.fromList([4, 5, 6, 7]),
      Uint8List.fromList([8, 9, 10, 11, 12]),
    ];
    final resources = <GDevelopProjectResource>[];
    for (var index = 0; index < resourceBytes.length; index += 1) {
      final bytes = resourceBytes[index];
      final hash = await _hash(bytes);
      await history.stageResourceStream(
        projectId: gameId,
        expectedHash: hash,
        contentLength: bytes.length,
        bytes: Stream.value(bytes),
      );
      resources.add(
        GDevelopProjectResource(
          logicalId: 'playmesh-local-resource://project/resource/$index.png',
          name: '$index.png',
          contentHash: hash,
          mime: 'image/png',
          size: bytes.length,
        ),
      );
    }
    await history.snapshot(
      projectId: gameId,
      baseRevision: 0,
      reason: GDevelopHistoryReason.explicitSave,
      source: GDevelopHistorySource.user,
      projectFiles: _projectFiles(const {'name': 'presence batch'}),
      resources: resources,
    );
    expect(bundleVerificationCount, 0);

    final missingBytes = Uint8List.fromList([13, 14, 15]);
    final missingHash = await _hash(missingBytes);
    bundleVerificationCount = 0;
    final missing = await history.missingResources(
      projectId: gameId,
      resources: [
        for (final resource in resources)
          LocalCasObjectReference(
            hash: resource.contentHash,
            bytes: resource.size,
          ),
        // A duplicate remains part of the same metadata-only lookup.
        LocalCasObjectReference(
          hash: resources.first.contentHash,
          bytes: resources.first.size,
        ),
        LocalCasObjectReference(hash: missingHash, bytes: missingBytes.length),
      ],
    );

    expect(bundleVerificationCount, 0);
    expect(missing, [
      isA<LocalCasObjectReference>()
          .having((reference) => reference.hash, 'hash', missingHash)
          .having((reference) => reference.bytes, 'bytes', missingBytes.length),
    ]);

    final corrupted = resources.last;
    await File(
      '${root.path}${Platform.pathSeparator}$gameId'
      '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
      '${Platform.pathSeparator}source${Platform.pathSeparator}current'
      '${Platform.pathSeparator}resources${Platform.pathSeparator}'
      '${corrupted.contentHash}.blob',
    ).writeAsBytes([0], flush: true);
    bundleVerificationCount = 0;
    expect(
      await history.missingResources(
        projectId: gameId,
        resources: [
          LocalCasObjectReference(
            hash: resources.first.contentHash,
            bytes: resources.first.size,
          ),
          LocalCasObjectReference(
            hash: corrupted.contentHash,
            bytes: corrupted.size,
          ),
        ],
      ),
      isEmpty,
      reason: 'presence follows the authoritative manifest without blob scans',
    );
    expect(bundleVerificationCount, 0);
  });

  test(
    'unchanged current resources keep bytes and mtime while removed blobs disappear',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gdevelop-current-resource-reuse-',
      );
      addTearDown(() => root.delete(recursive: true));
      const gameId = 'com.example.current-resource-reuse';
      final history = await _history(root, [gameId]);
      final firstBytes = Uint8List.fromList([1, 3, 5, 7]);
      final secondBytes = Uint8List.fromList([2, 4, 6, 8]);
      final firstHash = await _hash(firstBytes);
      final secondHash = await _hash(secondBytes);
      final resources = [
        GDevelopProjectResource(
          logicalId: 'playmesh-local-resource://project/resource/first.png',
          name: 'first.png',
          contentHash: firstHash,
          mime: 'image/png',
          size: firstBytes.length,
        ),
        GDevelopProjectResource(
          logicalId: 'playmesh-local-resource://project/resource/second.png',
          name: 'second.png',
          contentHash: secondHash,
          mime: 'image/png',
          size: secondBytes.length,
        ),
      ];
      for (final entry in [
        (hash: firstHash, bytes: firstBytes),
        (hash: secondHash, bytes: secondBytes),
      ]) {
        await history.stageResourceStream(
          projectId: gameId,
          expectedHash: entry.hash,
          contentLength: entry.bytes.length,
          bytes: Stream.value(entry.bytes),
        );
      }
      final first = await history.snapshot(
        projectId: gameId,
        baseRevision: 0,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles(const {'name': 'first'}),
        resources: resources,
      );
      final resourceRoot = Directory(
        '${root.path}${Platform.pathSeparator}$gameId'
        '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
        '${Platform.pathSeparator}source${Platform.pathSeparator}current'
        '${Platform.pathSeparator}resources',
      );
      File blob(String hash) =>
          File('${resourceRoot.path}${Platform.pathSeparator}$hash.blob');
      final retainedTime = DateTime.utc(2001, 2, 3, 4, 5, 6);
      await blob(firstHash).setLastModified(retainedTime);
      await blob(secondHash).setLastModified(retainedTime);

      final second = await history.snapshot(
        projectId: gameId,
        baseRevision: first.version.revision,
        reason: GDevelopHistoryReason.importantChange,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles(const {'name': 'same resources'}),
        resources: resources,
      );
      expect(await blob(firstHash).readAsBytes(), firstBytes);
      expect(await blob(secondHash).readAsBytes(), secondBytes);
      expect((await blob(firstHash).stat()).modified.toUtc(), retainedTime);
      expect((await blob(secondHash).stat()).modified.toUtc(), retainedTime);

      await history.snapshot(
        projectId: gameId,
        baseRevision: second.version.revision,
        reason: GDevelopHistoryReason.importantChange,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles(const {'name': 'one resource removed'}),
        resources: [resources.first],
      );
      expect(await blob(firstHash).readAsBytes(), firstBytes);
      expect((await blob(firstHash).stat()).modified.toUtc(), retainedTime);
      expect(await blob(secondHash).exists(), isFalse);
    },
  );

  test(
    'project shards keep official write/readback string comparison',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gdevelop-project-write-readback-',
      );
      addTearDown(() => root.delete(recursive: true));
      const gameId = 'com.example.project-write-readback';
      final resolver = FileSystemGDevelopProjectRootResolver(
        projectsRoot: root,
        cleanupJournal: File(
          '${root.path}${Platform.pathSeparator}cleanup.json',
        ),
      );
      var corruptAfterWrite = false;
      final writtenProjectFiles = <String>[];
      final history = GDevelopProjectHistoryAdapter(
        rootResolver: resolver,
        onCurrentProjectFileWritten: (file) async {
          writtenProjectFiles.add(file.path);
          if (corruptAfterWrite) {
            await file.writeAsString('{"changed":true}\n', flush: true);
          }
        },
      );
      await history.createProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
        name: gameId,
      );
      const initial = {
        'name': 'official bytes',
        'properties': {'folderProject': true},
        'layouts': [
          {'__REFERENCE_TO_SPLIT_OBJECT': true, 'referenceTo': '/layouts/main'},
        ],
      };
      final first = await history.snapshot(
        projectId: gameId,
        baseRevision: 0,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: [
          GDevelopProjectFile(path: 'game.json', content: initial),
          GDevelopProjectFile(
            path: 'layouts/main.json',
            content: const {'name': 'Main'},
          ),
        ],
        resources: const [],
      );
      expect(writtenProjectFiles, hasLength(2));
      expect(
        writtenProjectFiles.last,
        endsWith('${Platform.pathSeparator}game.json'),
      );
      final stored = File(
        '${root.path}${Platform.pathSeparator}$gameId'
        '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
        '${Platform.pathSeparator}source${Platform.pathSeparator}current'
        '${Platform.pathSeparator}project${Platform.pathSeparator}game.json',
      );
      expect(
        await stored.readAsString(),
        encodeOfficialGDevelopProjectFile(initial),
      );

      corruptAfterWrite = true;
      await expectLater(
        history.snapshot(
          projectId: gameId,
          baseRevision: first.version.revision,
          reason: GDevelopHistoryReason.importantChange,
          source: GDevelopHistorySource.user,
          projectFiles: _projectFiles(const {'name': 'must fail'}),
          resources: const [],
        ),
        throwsA(isA<StateError>()),
      );
      expect(_rootProjectContent(await history.current(gameId)), initial);
    },
  );

  test(
    'unchanged snapshot deduplicates history while current revision advances',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gdevelop-history-deduplicate-',
      );
      addTearDown(() => root.delete(recursive: true));
      const gameId = 'com.example.history-deduplicate';
      final history = await _history(root, [gameId]);
      final projectFiles = _projectFiles(const {'name': 'unchanged'});
      final first = await history.snapshot(
        projectId: gameId,
        baseRevision: 0,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: projectFiles,
        resources: const [],
      );
      final second = await history.snapshot(
        projectId: gameId,
        baseRevision: first.version.revision,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: projectFiles,
        resources: const [],
      );

      expect(second.version.revision, first.version.revision + 1);
      expect(second.deduplicated, isTrue);
      expect(second.historyCreated, isFalse);
      expect(await history.list(gameId), hasLength(1));
    },
  );

  test(
    'normal current open and 66 resource reads perform no full bundle verification',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'gdevelop-current-open-read-',
      );
      addTearDown(() => root.delete(recursive: true));
      const gameId = 'com.example.current-open-read';
      final resolver = FileSystemGDevelopProjectRootResolver(
        projectsRoot: root,
        cleanupJournal: File(
          '${root.path}${Platform.pathSeparator}cleanup.json',
        ),
      );
      var bundleVerificationCount = 0;
      final history = GDevelopProjectHistoryAdapter(
        rootResolver: resolver,
        onCurrentBundleVerification: () => bundleVerificationCount += 1,
      );
      await history.createProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
        name: gameId,
      );

      final resources = <GDevelopProjectResource>[];
      final bytesByHash = <String, Uint8List>{};
      for (var index = 0; index < 66; index += 1) {
        final bytes = Uint8List.fromList([
          index,
          index + 1,
          index + 2,
          index + 3,
        ]);
        final hash = await _hash(bytes);
        bytesByHash[hash] = bytes;
        await history.stageResourceStream(
          projectId: gameId,
          expectedHash: hash,
          contentLength: bytes.length,
          bytes: Stream.value(bytes),
        );
        resources.add(
          GDevelopProjectResource(
            logicalId:
                'playmesh-local-resource://project/resource/'
                '${index.toString().padLeft(2, '0')}.png',
            name: '$index.png',
            contentHash: hash,
            mime: 'image/png',
            size: bytes.length,
          ),
        );
      }
      final saved = await history.snapshot(
        projectId: gameId,
        baseRevision: 0,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles(const {'name': 'open performance'}),
        resources: resources,
      );

      bundleVerificationCount = 0;
      final current = (await history.openCurrent(gameId))!;
      expect(_openRootContent(current), const {'name': 'open performance'});
      expect(current['resources'], hasLength(66));
      for (final resource in resources) {
        final result = await history.readOpenResource(
          projectId: gameId,
          contentHash: resource.contentHash,
        );
        expect(result, bytesByHash[resource.contentHash]);
      }
      expect(
        bundleVerificationCount,
        0,
        reason: 'normal open must not hash the project or scan resource blobs',
      );

      final currentRoot = Directory(
        '${root.path}${Platform.pathSeparator}$gameId'
        '${Platform.pathSeparator}.playmesh${Platform.pathSeparator}gdevelop'
        '${Platform.pathSeparator}source${Platform.pathSeparator}current',
      );
      final manifestFile = File(
        '${currentRoot.path}${Platform.pathSeparator}manifest.json',
      );
      final originalManifest = await manifestFile.readAsString();
      final rawManifest =
          Map<String, Object?>.from(jsonDecode(originalManifest) as Map)
            ..['schemaVersion'] = 'not-a-schema-version'
            ..['gameId'] = '../stored-game-id'
            ..['revision'] = 'opaque-revision'
            ..['reason'] = {'stored': 'reason'}
            ..['source'] = ['stored', 'source']
            ..['contentHash'] = {'stored': 'content-hash'}
            ..['contentBytes'] = 'stored-content-bytes'
            ..['projectFilesHash'] = false
            ..['projectFilesSize'] = 'stored-project-bytes'
            ..['playmeshProjectConfig'] = 'stored-project-config'
            ..['resources'] = [
              {
                'logicalId': '../stored-logical-id',
                'contentHash': resources.first.contentHash,
                'mime': 'not a mime',
                'size': 'stored-size',
              },
            ];
      await manifestFile.writeAsString(jsonEncode(rawManifest), flush: true);
      final rawCurrent = (await history.openCurrent(gameId))!;
      final rawVersion = rawCurrent['version']! as Map;
      expect(rawVersion['gameId'], '../stored-game-id');
      expect(rawVersion['revision'], 'opaque-revision');
      expect(rawVersion['reason'], {'stored': 'reason'});
      expect(rawVersion['source'], ['stored', 'source']);
      expect(rawVersion['contentHash'], {'stored': 'content-hash'});
      expect(rawVersion['contentBytes'], 'stored-content-bytes');
      expect(rawCurrent['playmeshProjectConfig'], 'stored-project-config');
      expect((rawCurrent['resources']! as List).single, {
        'logicalId': '../stored-logical-id',
        'contentHash': resources.first.contentHash,
        'mime': 'not a mime',
        'size': 'stored-size',
      });
      await manifestFile.writeAsString(originalManifest, flush: true);
      final projectFile = File(
        '${currentRoot.path}${Platform.pathSeparator}project'
        '${Platform.pathSeparator}game.json',
      );
      final originalProject = await projectFile.readAsString();
      await projectFile.writeAsString('["stored","project"]', flush: true);
      expect(_openRootContent((await history.openCurrent(gameId))!), [
        'stored',
        'project',
      ]);
      await projectFile.writeAsString(originalProject, flush: true);

      final unpinnedHash = '0' * 64;
      const unpinnedBytes = [17, 18, 19];
      await File(
        '${currentRoot.path}${Platform.pathSeparator}resources'
        '${Platform.pathSeparator}$unpinnedHash.blob',
      ).writeAsBytes(unpinnedBytes, flush: true);
      expect(
        await history.readOpenResource(
          projectId: gameId,
          contentHash: unpinnedHash,
        ),
        unpinnedBytes,
        reason: 'normal resource relay uses only the contained URL hash path',
      );
      await expectLater(
        history.readOpenResource(projectId: gameId, contentHash: '../unsafe'),
        throwsA(isA<FormatException>()),
        reason: 'path safety remains the only resource read gate',
      );

      final unrelated = resources.last;
      await File(
        '${currentRoot.path}${Platform.pathSeparator}resources'
        '${Platform.pathSeparator}${unrelated.contentHash}.blob',
      ).writeAsBytes([0], flush: true);
      final first = resources.first;
      expect(
        await history.readOpenResource(
          projectId: gameId,
          contentHash: first.contentHash,
        ),
        bytesByHash[first.contentHash],
        reason: 'an unread resource must not be scanned while reading another',
      );

      const storedAsIs = [255];
      await File(
        '${currentRoot.path}${Platform.pathSeparator}resources'
        '${Platform.pathSeparator}${first.contentHash}.blob',
      ).writeAsBytes(storedAsIs, flush: true);
      final storedResult = await history.readOpenResource(
        projectId: gameId,
        contentHash: first.contentHash,
      );
      expect(storedResult, storedAsIs);
      expect(
        ((await history.openCurrent(gameId))!['resources'] as List)
            .cast<Map>()
            .first['size'],
        first.size,
        reason: 'the response keeps manifest metadata but relays stored bytes',
      );

      await projectFile.writeAsString('{"name":"stored as-is"}', flush: true);
      expect(
        _openRootContent((await history.openCurrent(gameId))!),
        const {'name': 'stored as-is'},
        reason: 'normal current GET must not compare project hash or size',
      );
      expect(bundleVerificationCount, 0);

      await expectLater(
        history.readOpenResource(projectId: gameId, contentHash: 'f' * 64),
        throwsA(isA<StateError>()),
        reason: 'a path-safe hash with no stored file fails at the read itself',
      );

      bundleVerificationCount = 0;
      final next = await history.snapshot(
        projectId: gameId,
        baseRevision: saved.version.revision,
        reason: GDevelopHistoryReason.explicitSave,
        source: GDevelopHistorySource.user,
        projectFiles: _projectFiles(const {'name': 'next write'}),
        resources: resources,
      );
      expect(next.version.revision, saved.version.revision + 1);
      expect(bundleVerificationCount, 0);
    },
  );
}

Future<GDevelopProjectHistoryAdapter> _history(
  Directory projectsRoot,
  List<String> gameIds, {
  LocalVersionRetentionPolicy retentionPolicy =
      const LocalVersionRetentionPolicy(),
}) async {
  final resolver = FileSystemGDevelopProjectRootResolver(
    projectsRoot: projectsRoot,
    cleanupJournal: File(
      '${projectsRoot.path}${Platform.pathSeparator}cleanup.json',
    ),
  );
  final history = GDevelopProjectHistoryAdapter(
    rootResolver: resolver,
    retentionPolicy: retentionPolicy,
  );
  for (final gameId in gameIds) {
    await history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
      fileIdentifier: 'file-${gameId.hashCode.abs()}',
      name: gameId,
    );
  }
  return history;
}

List<GDevelopProjectFile> _projectFiles(Map<String, Object?> content) => [
  GDevelopProjectFile(path: 'game.json', content: content),
];

Map<String, Object?>? _rootProjectContent(GDevelopProjectSnapshot? snapshot) =>
    snapshot == null
    ? null
    : gdevelopRootProjectFile(snapshot.projectFiles).content;

Object? _openRootContent(Map<String, Object?> current) =>
    ((current['projectFiles']! as List).single as Map)['content'];

GDevelopProjectResource _resource(String hash, int size) =>
    GDevelopProjectResource(
      logicalId: 'playmesh-local-resource://project/resource/image.png',
      name: 'image.png',
      contentHash: hash,
      mime: 'image/png',
      size: size,
    );

Future<String> _hash(List<int> bytes) async {
  final digest = await Sha256().hash(bytes);
  return digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
