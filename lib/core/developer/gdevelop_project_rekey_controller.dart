import 'gdevelop_project_rekey.dart';

/// packageName/gameId 身份迁移的独立应用层入口。
class GDevelopProjectRekeyController {
  const GDevelopProjectRekeyController(this.coordinator);

  final GDevelopProjectRekeyCoordinator coordinator;

  Future<GDevelopProjectRekeyTransaction> prepare({
    required String oldGameId,
    required String newGameId,
    required String idempotencyKey,
    required GDevelopProjectRekeyExpectedEvidence expectedOldEvidence,
    required GDevelopProjectRekeyBrowserTarget browserSource,
    required GDevelopProjectRekeyBrowserTarget browserTarget,
    String? clientId,
  }) => coordinator.prepare(
    oldGameId: oldGameId,
    newGameId: newGameId,
    idempotencyKey: idempotencyKey,
    expectedOldEvidence: expectedOldEvidence,
    browserSource: browserSource,
    browserTarget: browserTarget,
    clientId: clientId,
  );

  Future<GDevelopProjectRekeyTransaction> commit({
    required String oldGameId,
    required String txId,
  }) => coordinator.commit(oldGameId: oldGameId, txId: txId);

  Future<GDevelopProjectRekeyTransaction> status({
    required String oldGameId,
    required String txId,
  }) => coordinator.status(oldGameId: oldGameId, txId: txId);

  Future<GDevelopProjectRekeyTransaction> acknowledge({
    required String oldGameId,
    required String txId,
    required GDevelopProjectRekeyBrowserEvidence browserEvidence,
  }) => coordinator.acknowledge(
    oldGameId: oldGameId,
    txId: txId,
    browserEvidence: browserEvidence,
  );

  Future<GDevelopProjectRekeyTransaction> rollback({
    required String oldGameId,
    required String txId,
    GDevelopProjectRekeyBrowserEvidence? browserEvidence,
  }) => coordinator.rollback(
    oldGameId: oldGameId,
    txId: txId,
    browserEvidence: browserEvidence,
  );

  Future<GDevelopProjectRekeyRecoveryResult> recover(String oldGameId) =>
      coordinator.recover(oldGameId);

  Future<GDevelopProjectRekeyTransaction> abort({
    required String oldGameId,
    required String txId,
  }) => coordinator.abort(oldGameId: oldGameId, txId: txId);

  Future<void> ensureMutationAllowed(String gameId) =>
      coordinator.ensureMutationAllowed(gameId);

  void registerMutationGuard(GDevelopProjectRekeyMutationGuard guard) {
    coordinator.registerMutationGuard(guard);
  }

  Future<T> runIdentityMutation<T>(
    String gameId,
    Future<T> Function() action,
  ) => coordinator.runIdentityMutation(gameId, action);
}
