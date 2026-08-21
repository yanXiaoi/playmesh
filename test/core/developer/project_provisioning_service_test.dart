import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/project_provisioning_service.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('源码和 GDevelop 新建共用 gameId/name 校验', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-project-validation-',
    );
    addTearDown(() => root.delete(recursive: true));
    final provisioning = ProjectProvisioningService(projectsRoot: root);
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const []),
      workspaceRoot: root,
      projectProvisioning: provisioning,
    );
    final gdevelop = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      provisioning: provisioning,
    );

    await expectLater(
      catalog.createProject(_sourceDraft(id: 'Com.Example.Invalid')),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '项目 ID 必须是小写反向域名格式',
        ),
      ),
    );
    expect(
      () => gdevelop.ensureProjectRoot(
        gameId: 'Com.Example.Invalid',
        name: 'Invalid',
        origin: GDevelopProjectEnsureOrigin.create,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '项目 ID 必须是小写反向域名格式',
        ),
      ),
    );
    await expectLater(
      catalog.createProject(
        _sourceDraft(id: 'com.example.invalid-name', name: '   '),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '项目名称长度必须为 1 到 80 个字符',
        ),
      ),
    );
    expect(
      () => gdevelop.ensureProjectRoot(
        gameId: 'com.example.invalid-name',
        name: '   ',
        origin: GDevelopProjectEnsureOrigin.create,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '项目名称长度必须为 1 到 80 个字符',
        ),
      ),
    );
    final valid = await gdevelop.ensureProjectRoot(
      gameId: 'com.example.visualgame',
      name: 'Visual Game',
      origin: GDevelopProjectEnsureOrigin.create,
    );
    expect(valid.gameId, 'com.example.visualgame');
  });

  test('源码和 GDevelop 对同一 packages 根抛出统一 conflict', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-project-conflict-',
    );
    addTearDown(() => root.delete(recursive: true));
    final provisioning = ProjectProvisioningService(projectsRoot: root);
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const []),
      workspaceRoot: root,
      projectProvisioning: provisioning,
    );
    final gdevelop = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      provisioning: provisioning,
    );

    await catalog.createProject(_sourceDraft(id: 'com.example.source-first'));
    await expectLater(
      gdevelop.ensureProjectRoot(
        gameId: 'com.example.source-first',
        name: 'Visual Project',
        origin: GDevelopProjectEnsureOrigin.create,
      ),
      throwsA(
        isA<ProjectProvisioningConflict>()
            .having(
              (error) => error.gameId,
              'gameId',
              'com.example.source-first',
            )
            .having(
              (error) => error.existingKind,
              'existingKind',
              PlaymeshProjectKind.source,
            ),
      ),
    );

    await gdevelop.ensureProjectRoot(
      gameId: 'com.example.visual-first',
      name: 'Visual First',
      origin: GDevelopProjectEnsureOrigin.create,
    );
    await expectLater(
      catalog.createProject(_sourceDraft(id: 'com.example.visual-first')),
      throwsA(
        isA<ProjectProvisioningConflict>()
            .having(
              (error) => error.gameId,
              'gameId',
              'com.example.visual-first',
            )
            .having(
              (error) => error.existingKind,
              'existingKind',
              PlaymeshProjectKind.gdevelop,
            ),
      ),
    );
    expect(ProjectProvisioningConflict.code, 'project_id_conflict');
    expect(ProjectProvisioningMissing.code, 'project_not_found');
  });

  test('源码 Catalog 仍从模板原子创建并写入 source 元数据', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-source-project-',
    );
    addTearDown(() => root.delete(recursive: true));
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const []),
      workspaceRoot: root,
    );

    final project = await catalog.createProject(
      _sourceDraft(id: 'com.example.provisioned-source'),
    );
    final projectRoot = Directory(project.rootFilePath);
    final manifest = File(
      '${projectRoot.path}${Platform.pathSeparator}main.json',
    );
    final app = Directory('${projectRoot.path}${Platform.pathSeparator}app');
    final metadata = File(
      '${projectRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    );

    expect(await manifest.exists(), isTrue);
    expect(await app.exists(), isTrue);
    final decoded = jsonDecode(await metadata.readAsString()) as Map;
    expect(decoded['gameId'], 'com.example.provisioned-source');
    expect(decoded['kind'], 'source');
    expect(
      await root
          .list()
          .where(
            (entity) => entity.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('.playmesh-create-'),
          )
          .isEmpty,
      isTrue,
    );
  });

  test('open/bind 校验 kind，saveAs 可绑定同一 GDevelop 游戏', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-project-binding-',
    );
    addTearDown(() => root.delete(recursive: true));
    final provisioning = ProjectProvisioningService(projectsRoot: root);
    final resolver = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      provisioning: provisioning,
    );

    await provisioning.createProject(
      gameId: 'com.example.bound-source',
      name: 'Bound Source',
      kind: PlaymeshProjectKind.source,
    );
    for (final origin in [
      GDevelopProjectEnsureOrigin.open,
      GDevelopProjectEnsureOrigin.legacyOpen,
    ]) {
      await expectLater(
        resolver.ensureProjectRoot(
          gameId: 'com.example.bound-source',
          name: 'Wrong Kind',
          origin: origin,
        ),
        throwsA(isA<ProjectProvisioningConflict>()),
      );
    }

    final created = await resolver.ensureProjectRoot(
      gameId: 'com.example.same-visual',
      name: 'Same Visual',
      fileIdentifier: 'original-file',
      origin: GDevelopProjectEnsureOrigin.create,
    );
    final savedAs = await resolver.ensureProjectRoot(
      gameId: 'com.example.same-visual',
      name: 'Same Visual',
      fileIdentifier: 'saved-as-file',
      origin: GDevelopProjectEnsureOrigin.saveAs,
    );

    expect(created.created, isTrue);
    expect(savedAs.created, isFalse);
    expect(savedAs.root.path, created.root.path);
    expect(savedAs.fileIdentifiers, ['original-file', 'saved-as-file']);
  });

  test('枚举仅返回严格匹配 kind/目录身份的托管项目并显式报告坏根', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-project-listing-',
    );
    addTearDown(() => root.delete(recursive: true));
    final provisioning = ProjectProvisioningService(projectsRoot: root);

    for (final entry in const [
      (id: 'com.example.visual-z', name: 'Visual Z'),
      (id: 'com.example.visual-a', name: 'Visual A'),
    ]) {
      await provisioning.createProject(
        gameId: entry.id,
        name: entry.name,
        kind: PlaymeshProjectKind.gdevelop,
        additionalMetadata: {
          'fileIdentifiers': ['file-${entry.id.split('.').last}'],
        },
      );
    }
    await provisioning.createProject(
      gameId: 'com.example.source-only',
      name: 'Source Only',
      kind: PlaymeshProjectKind.source,
    );
    await Directory(
      '${root.path}${Platform.pathSeparator}unmanaged-directory',
    ).create();

    final invalidRoot = Directory(
      '${root.path}${Platform.pathSeparator}com.example.invalid-metadata',
    );
    await File(
      '${invalidRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    ).create(recursive: true);
    await File(
      '${invalidRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    ).writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'kind': 'gdevelop',
        'gameId': 'com.example.invalid-metadata',
      }),
    );

    final mismatchRoot = Directory(
      '${root.path}${Platform.pathSeparator}com.example.wrong-directory',
    );
    final mismatchMetadata = <String, Object?>{
      'schemaVersion': 1,
      'kind': 'gdevelop',
      'gameId': 'com.example.metadata-identity',
      'name': 'Mismatched',
      'fileIdentifiers': const <String>[],
      'createdAt': DateTime.utc(2026, 8, 5).toIso8601String(),
      'updatedAt': DateTime.utc(2026, 8, 5).toIso8601String(),
    };
    await File(
      '${mismatchRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    ).create(recursive: true);
    await File(
      '${mismatchRoot.path}${Platform.pathSeparator}.playmesh'
      '${Platform.pathSeparator}project.json',
    ).writeAsString(jsonEncode(mismatchMetadata));

    final listed = await provisioning.listProjects(
      kind: PlaymeshProjectKind.gdevelop,
    );
    expect(listed.projects.map((project) => project.gameId), [
      'com.example.visual-a',
      'com.example.visual-z',
    ]);
    expect(
      listed.projects.map((project) => project.kind),
      everyElement(PlaymeshProjectKind.gdevelop),
    );
    expect(
      listed.diagnostics.map(
        (diagnostic) => '${diagnostic.directoryName}:${diagnostic.code}',
      ),
      [
        'com.example.invalid-metadata:project_metadata_invalid',
        'com.example.wrong-directory:project_root_identity_mismatch',
      ],
    );

    final resolved = await FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      provisioning: provisioning,
    ).listProjectRoots();
    expect(resolved.projects.map((project) => project.gameId), [
      'com.example.visual-a',
      'com.example.visual-z',
    ]);
    final firstIdentity = resolved.projects.first.toIdentityJson();
    expect(firstIdentity, containsPair('schemaVersion', 1));
    expect(firstIdentity, containsPair('kind', 'gdevelop'));
    expect(firstIdentity, containsPair('gameId', 'com.example.visual-a'));
    expect(firstIdentity, containsPair('name', 'Visual A'));
    expect(firstIdentity, containsPair('fileIdentifiers', ['file-visual-a']));
    expect(firstIdentity['createdAt'], isA<String>());
    expect(firstIdentity['updatedAt'], isA<String>());
    expect(firstIdentity, {
      'schemaVersion': 1,
      'kind': 'gdevelop',
      'gameId': 'com.example.visual-a',
      'name': 'Visual A',
      'fileIdentifiers': ['file-visual-a'],
      'createdAt': firstIdentity['createdAt'],
      'updatedAt': firstIdentity['updatedAt'],
    });
    expect(resolved.diagnostics, hasLength(2));
  });

  test('初始化失败不暴露半成品项目根', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-project-atomic-',
    );
    addTearDown(() => root.delete(recursive: true));
    final provisioning = ProjectProvisioningService(projectsRoot: root);

    await expectLater(
      provisioning.createProject(
        gameId: 'com.example.atomic-failure',
        name: 'Atomic Failure',
        kind: PlaymeshProjectKind.source,
        initialize: (staging) async {
          await File(
            '${staging.path}${Platform.pathSeparator}partial.txt',
          ).writeAsString('partial');
          throw StateError('template failed');
        },
      ),
      throwsStateError,
    );

    expect(
      await Directory(
        '${root.path}${Platform.pathSeparator}com.example.atomic-failure',
      ).exists(),
      isFalse,
    );
    expect(
      await root
          .list()
          .where(
            (entity) => entity.path
                .split(Platform.pathSeparator)
                .last
                .startsWith('.playmesh-create-'),
          )
          .isEmpty,
      isTrue,
    );
  });
}

DeveloperProjectDraft _sourceDraft({
  required String id,
  String name = 'Source Project',
}) => DeveloperProjectDraft(
  id: id,
  name: name,
  author: 'Test Author',
  lastModifiedAt: DateTime.utc(2026, 8, 4),
  mode: 'solo',
  orientation: GameOrientation.landscape,
  displayMode: 'multi_screen',
  minPlayers: 1,
  maxPlayers: 1,
);
