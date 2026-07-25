part of '../../developer_web_gateway_io.dart';

class _EmptyDeveloperProjectCatalog implements DeveloperProjectCatalog {
  const _EmptyDeveloperProjectCatalog();

  Never _unavailable() => throw StateError('开发者项目不可用');
  Never _missing() => throw StateError('开发者项目不存在');

  @override
  Future<List<DeveloperProject>> listProjects() async => const [];

  @override
  Future<DeveloperProject> createProject(DeveloperProjectDraft draft) async =>
      _unavailable();

  @override
  Future<DeveloperProject> copyProject(
    String sourceProjectId, {
    required String id,
    required String name,
    required String author,
    required DateTime lastModifiedAt,
  }) async => _unavailable();

  @override
  Future<void> deleteProject(String projectId) async => _unavailable();

  @override
  Future<GameSummary> publishPackage(
    File source, {
    required String author,
    required DateTime lastModifiedAt,
  }) async => _unavailable();

  @override
  Future<List<String>> listFiles(String projectId) async => const [];

  @override
  Future<List<String>> listDirectories(String projectId) async => const [];

  @override
  Future<void> createDirectory(String projectId, String path) async =>
      _missing();

  @override
  Future<void> deleteDirectory(String projectId, String path) async =>
      _missing();

  @override
  Future<void> copyEntry(
    String projectId,
    String source,
    String destination,
  ) async => _missing();

  @override
  Future<void> moveEntry(
    String projectId,
    String source,
    String destination,
  ) async => _missing();

  @override
  Future<List<String>> extractZip(
    String projectId,
    String archivePath,
    String destinationDirectory,
  ) async => _missing();

  @override
  Future<DeveloperProjectFile> readFile(String projectId, String path) async =>
      _missing();

  @override
  Future<DeveloperProjectFile> updateManifest(
    String projectId,
    Map<String, Object?> manifest, {
    int? expectedRevision,
  }) async => _missing();

  @override
  Future<DeveloperProjectFile> writeFile(
    String projectId,
    String path,
    List<int> bytes, {
    int? expectedRevision,
  }) async => _missing();

  @override
  Future<List<DeveloperProjectFile>> writeFilesAtomic(
    String projectId,
    Map<String, List<int>> files, {
    Map<String, int>? expectedRevisions,
  }) async => _missing();

  @override
  Future<void> deleteFile(
    String projectId,
    String path, {
    int? expectedRevision,
  }) async => _missing();

  @override
  Future<DeveloperFileDiff> diffFile(String projectId, String path) async =>
      _missing();

  @override
  Future<List<DeveloperLocalHistoryOperation>> listLocalHistory(
    String projectId,
    String path,
  ) async => const [];

  @override
  Future<DeveloperLocalHistoryDiff> localHistoryDiff(
    String projectId,
    String operationId,
    String path,
  ) async => _missing();

  @override
  Future<void> restoreLocalHistory(
    String projectId,
    String operationId,
    String path,
    DeveloperHistoryVersion version,
  ) async => _missing();

  @override
  Future<DeveloperProjectValidationReport> validateProject(
    String projectId,
  ) async => _missing();

  @override
  Future<bool> clearGameData(String projectId) async => _missing();

  @override
  Future<GameSummary> prepareGame(String projectId) async => _missing();
}
