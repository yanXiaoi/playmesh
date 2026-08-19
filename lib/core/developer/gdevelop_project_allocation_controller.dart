import 'foundation/local_version_store.dart';
import 'gdevelop_project_allocation.dart';
import 'gdevelop_project_history.dart';

/// create/import/copy 的 App 权威工作区分配事务入口。
class GDevelopProjectAllocationController {
  const GDevelopProjectAllocationController(this.coordinator);

  final GDevelopProjectAllocationCoordinator coordinator;

  Future<GDevelopProjectAllocationTransaction> prepare({
    required String gameId,
    required String idempotencyKey,
    required GDevelopProjectAllocationOrigin origin,
    required GDevelopProjectAllocationWorkspaceTarget workspaceTarget,
    String? name,
    String? clientId,
  }) => coordinator.prepare(
    gameId: gameId,
    idempotencyKey: idempotencyKey,
    origin: origin,
    workspaceTarget: workspaceTarget,
    name: name,
    clientId: clientId,
  );

  Future<GDevelopProjectAllocationResourcePresence> resourcePresence({
    required String txId,
    required List<GDevelopProjectResource> resources,
  }) => coordinator.resourcePresence(txId: txId, resources: resources);

  Future<LocalCasObjectReference> uploadResource({
    required String txId,
    required String contentHash,
    required Stream<List<int>> bytes,
    int? contentLength,
  }) => coordinator.uploadResource(
    txId: txId,
    contentHash: contentHash,
    bytes: bytes,
    contentLength: contentLength,
  );

  Future<GDevelopProjectAllocationProjectFilesUploadReference>
  uploadWorkspaceProjectFiles({
    required String txId,
    required Stream<List<int>> bytes,
    int? contentLength,
  }) => coordinator.uploadWorkspaceProjectFiles(
    txId: txId,
    bytes: bytes,
    contentLength: contentLength,
  );

  Future<GDevelopProjectAllocationTransaction> finalizeWorkspace({
    required String txId,
    required GDevelopProjectAllocationWorkspaceFinalization evidence,
  }) => coordinator.finalizeWorkspace(txId: txId, evidence: evidence);

  Future<GDevelopProjectAllocationTransaction> commit(String txId) =>
      coordinator.commit(txId);

  Future<GDevelopProjectAllocationTransaction> status(String txId) =>
      coordinator.status(txId);

  Future<GDevelopProjectAllocationTransaction> recover(String txId) =>
      coordinator.recover(txId);

  Future<GDevelopProjectAllocationTransaction> abort(String txId) =>
      coordinator.abort(txId);

  Future<void> ensureMutationAllowed(String gameId) =>
      coordinator.ensureMutationAllowed(gameId);

  void registerMutationGuard(GDevelopProjectAllocationMutationGuard guard) {
    coordinator.registerMutationGuard(guard);
  }
}
