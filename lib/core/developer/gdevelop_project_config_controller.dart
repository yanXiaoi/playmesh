import 'gdevelop_project_config.dart';

/// 独立编排 GDevelop 项目配置用例，避免配置能力耦合官方工程或源码控制器。
class GDevelopProjectConfigController {
  const GDevelopProjectConfigController(this.repository);

  final GDevelopProjectConfigRepository repository;

  Future<GDevelopProjectConfigReadResult> read(String gameId) =>
      repository.read(gameId);

  Future<GDevelopProjectConfig> update({
    required String gameId,
    required GDevelopProjectGameType gameType,
    required int minPlayers,
    required int maxPlayers,
    required List<String> tags,
    bool webRuntimeMultithreading = false,
    required int expectedRevision,
  }) => repository.put(
    gameId: gameId,
    gameType: gameType,
    minPlayers: minPlayers,
    maxPlayers: maxPlayers,
    tags: tags,
    webRuntimeMultithreading: webRuntimeMultithreading,
    expectedRevision: expectedRevision,
  );

  Future<GDevelopProjectConfigEvidence> inspect(String gameId) =>
      repository.inspect(gameId);

  Future<GDevelopProjectConfigEvidence> applyPreparedTarget({
    required String gameId,
    required GDevelopProjectConfigEvidence oldEvidence,
    required GDevelopProjectConfigEvidence targetEvidence,
  }) => repository.applyPreparedTarget(
    gameId: gameId,
    oldEvidence: oldEvidence,
    targetEvidence: targetEvidence,
  );

  Future<bool> initializeNewProject(String gameId) async {
    try {
      await repository.put(
        gameId: gameId,
        gameType: GDevelopProjectGameType.single,
        minPlayers: 1,
        maxPlayers: 1,
        tags: const [],
        webRuntimeMultithreading: false,
        expectedRevision: 0,
      );
      return true;
    } on Object {
      // sidecar 是增强能力；Gateway 或磁盘暂时不可用不能回滚已创建的项目根。
      return false;
    }
  }

  Future<void> deleteArtifacts(String gameId) =>
      repository.deleteArtifacts(gameId);
}
