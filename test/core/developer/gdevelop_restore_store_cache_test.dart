import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_project_config.dart';
import 'package:playmesh/core/developer/gdevelop_project_config_controller.dart';
import 'package:playmesh/core/developer/gdevelop_project_history.dart';
import 'package:playmesh/core/developer/gdevelop_project_root_resolver.dart';
import 'package:playmesh/core/developer/gdevelop_restore_transaction.dart';
import 'package:playmesh/core/developer/project_provisioning_service.dart';

void main() {
  test('missing store 失败被驱逐，随后 create 后可以 open', () async {
    final fixture = await _StoreCacheFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.store-cache-create';

    await fixture.coordinator.runProjectAllocation(gameId, () async {
      await fixture.history.createProjectRoot(
        gameId: gameId,
        origin: GDevelopProjectEnsureOrigin.create,
      );
    });

    expect(
      await fixture.coordinator.runProjectMutation(
        gameId,
        () async => 'opened',
      ),
      'opened',
    );
    expect(fixture.resolver.probes[gameId], 2);
  });

  test('同 key 并发 missing 只共享一次探测', () async {
    final fixture = await _StoreCacheFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.store-cache-missing';

    final results = await Future.wait([
      for (var index = 0; index < 2; index++)
        fixture.coordinator
            .runProjectMutation(gameId, () async => 'unexpected')
            .then<Object>((value) => value, onError: (Object error) => error),
    ]);

    expect(results, everyElement(isA<ProjectProvisioningMissing>()));
    expect(fixture.resolver.probes[gameId], 1);
  });

  test('失败驱逐后并发成功仍保持同 key single-flight', () async {
    final fixture = await _StoreCacheFixture.create();
    addTearDown(fixture.close);
    const gameId = 'com.example.store-cache-retry';

    await expectLater(
      fixture.coordinator.runProjectMutation(gameId, () async => null),
      throwsA(isA<ProjectProvisioningMissing>()),
    );
    await fixture.history.createProjectRoot(
      gameId: gameId,
      origin: GDevelopProjectEnsureOrigin.create,
    );

    final results = await Future.wait([
      fixture.coordinator.runProjectMutation(gameId, () async => 'first'),
      fixture.coordinator.runProjectMutation(gameId, () async => 'second'),
    ]);

    expect(results, ['first', 'second']);
    expect(fixture.resolver.probes[gameId], 2);
  });

  test('不同 key 的成功与失败缓存互不影响', () async {
    final fixture = await _StoreCacheFixture.create();
    addTearDown(fixture.close);
    const existing = 'com.example.store-cache-existing';
    const missing = 'com.example.store-cache-isolated-missing';
    await fixture.history.createProjectRoot(
      gameId: existing,
      origin: GDevelopProjectEnsureOrigin.create,
    );

    final results = await Future.wait([
      fixture.coordinator
          .runProjectMutation(missing, () async => 'unexpected')
          .then<Object>((value) => value, onError: (Object error) => error),
      fixture.coordinator
          .runProjectMutation(existing, () async => 'opened')
          .then<Object>((value) => value),
    ]);

    expect(results.first, isA<ProjectProvisioningMissing>());
    expect(results.last, 'opened');
    expect(fixture.resolver.probes, {missing: 1, existing: 1});
  });
}

class _StoreCacheFixture {
  _StoreCacheFixture({
    required this.root,
    required this.resolver,
    required this.history,
    required this.coordinator,
  });

  final Directory root;
  final _CountingRootResolver resolver;
  final GDevelopProjectHistoryAdapter history;
  final GDevelopRestoreTransactionCoordinator coordinator;

  static Future<_StoreCacheFixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'gdevelop-restore-store-cache-',
    );
    final delegate = FileSystemGDevelopProjectRootResolver(
      projectsRoot: root,
      cleanupJournal: File('${root.path}${Platform.pathSeparator}cleanup.json'),
    );
    final resolver = _CountingRootResolver(delegate);
    final history = GDevelopProjectHistoryAdapter(rootResolver: resolver);
    final config = GDevelopProjectConfigController(
      GDevelopProjectConfigStore(rootResolver: resolver),
    );
    final coordinator = GDevelopRestoreTransactionCoordinator(
      history: history,
      projectConfig: config,
      rootResolver: resolver,
    );
    return _StoreCacheFixture(
      root: root,
      resolver: resolver,
      history: history,
      coordinator: coordinator,
    );
  }

  Future<void> close() => root.delete(recursive: true);
}

class _CountingRootResolver implements GDevelopProjectRootResolver {
  _CountingRootResolver(this.delegate);

  final GDevelopProjectRootResolver delegate;
  final Map<String, int> probes = {};

  @override
  Future<GDevelopProjectRootListResult> listProjectRoots() =>
      delegate.listProjectRoots();

  @override
  Future<GDevelopProjectCleanupResult> deleteProject(String gameId) =>
      delegate.deleteProject(gameId);

  @override
  Future<GDevelopProjectRootInfo> ensureProjectRoot({
    required String gameId,
    required GDevelopProjectEnsureOrigin origin,
    String? fileIdentifier,
    String? name,
  }) => delegate.ensureProjectRoot(
    gameId: gameId,
    origin: origin,
    fileIdentifier: fileIdentifier,
    name: name,
  );

  @override
  Future<Set<String>> historicalGameIds(String gameId) =>
      delegate.historicalGameIds(gameId);

  @override
  Future<Directory> projectRootLocation(String gameId) =>
      delegate.projectRootLocation(gameId);

  @override
  Future<Directory> resolveHistoryRoot(String gameId) =>
      delegate.resolveHistoryRoot(gameId);

  @override
  Future<T> runInProjectRoot<T>(
    String gameId,
    Future<T> Function(Directory root) action,
  ) {
    probes.update(gameId, (value) => value + 1, ifAbsent: () => 1);
    return delegate.runInProjectRoot(gameId, action);
  }

  @override
  Future<GDevelopProjectRootInfo> updateMetadata({
    required String gameId,
    String? fileIdentifier,
    String? name,
  }) => delegate.updateMetadata(
    gameId: gameId,
    fileIdentifier: fileIdentifier,
    name: name,
  );
}
