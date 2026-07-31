import '../../models/game_summary.dart';
import '../catalog/game_catalog_publisher.dart';
import '../catalog/online_game_catalog.dart';
import 'developer_web_gateway_contract.dart';

/// 将 Catalog 凭据保留在 Flutter 进程内，只向 Developer Workspace 暴露所需的安全源
/// 元数据和状态值。
class GameCatalogDeveloperProjectPublisher
    implements DeveloperProjectPublisher {
  GameCatalogDeveloperProjectPublisher(this.catalog);

  final GameCatalogController catalog;

  @override
  Future<List<DeveloperPublishSource>> listCandidates() async {
    await catalog.initialize();
    final candidates = <DeveloperPublishSource>[];
    for (final source in catalog.uploadCandidates) {
      final upload = source.declaration?.userUpload;
      final protocolVersion = upload?.protocolVersion;
      final maxUploadBytes = upload?.maxUploadBytes;
      if (protocolVersion == null || maxUploadBytes == null) continue;
      candidates.add(
        DeveloperPublishSource(
          id: source.id,
          name: source.name,
          protocolVersion: protocolVersion,
          maxUploadBytes: maxUploadBytes,
        ),
      );
    }
    return List.unmodifiable(candidates);
  }

  @override
  Future<DeveloperPublishBatchResult> publish({
    required GameSummary game,
    required Iterable<String> sourceIds,
    DeveloperPublishEventCallback? onEvent,
  }) async {
    final result = await catalog.publishGamePackage(
      game: game,
      sourceIds: sourceIds,
      onEvent: onEvent == null
          ? null
          : (event) => onEvent(_sourceResult(event)),
    );
    return DeveloperPublishBatchResult(
      gameId: result.gameId,
      version: result.version,
      sources: List.unmodifiable(result.sources.map(_sourceResult)),
      failedSourceIds: List.unmodifiable(result.failedSourceIds),
    );
  }

  DeveloperPublishSourceResult _sourceResult(
    GameCatalogPublishSourceResult result,
  ) => DeveloperPublishSourceResult(
    sourceId: result.sourceId,
    sourceName: result.sourceName,
    status: result.status.wireValue,
    detail: result.detail,
    retryAfter: result.retryAfter,
    currentHighestVersion: result.currentHighestVersion,
  );
}
