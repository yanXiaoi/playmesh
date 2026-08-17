import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

enum PendingProjectCommitPhase {
  prepared('PREPARED'),
  payloadFinalized('PAYLOAD_FINALIZED'),
  commitRequested('COMMIT_REQUESTED'),
  historyApplied('HISTORY_APPLIED'),
  backendCommitted('BACKEND_COMMITTED'),
  rollbackRequested('ROLLBACK_REQUESTED'),
  browserPersisted('BROWSER_PERSISTED'),
  rolledBack('ROLLED_BACK'),
  conflict('CONFLICT'),
  aborted('ABORTED');

  const PendingProjectCommitPhase(this.wireName);

  final String wireName;

  static PendingProjectCommitPhase parse(String value) => values.firstWhere(
    (phase) => phase.wireName == value,
    orElse: () => throw const FormatException('项目提交 phase 无效'),
  );
}

class PendingProjectCommitCodec<T> {
  const PendingProjectCommitCodec({required this.encode, required this.decode});

  final Object? Function(T value) encode;
  final T Function(Object? value) decode;
}

class PendingProjectCommitRecord<T> {
  const PendingProjectCommitRecord({
    required this.namespace,
    required this.gameId,
    required this.txId,
    required this.idempotencyKey,
    required this.requestHash,
    required this.phase,
    required this.payload,
    required this.createdAt,
    required this.updatedAt,
    this.expiresAt,
    this.retainedUntil,
    this.payloadFinalizationEvidence,
    this.payloadFinalizationHash,
  });

  final String namespace;
  final String gameId;
  final String txId;
  final String idempotencyKey;
  final String requestHash;
  final PendingProjectCommitPhase phase;
  final T payload;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? expiresAt;
  final DateTime? retainedUntil;
  final Object? payloadFinalizationEvidence;
  final String? payloadFinalizationHash;

  bool get isReceipt =>
      phase == PendingProjectCommitPhase.browserPersisted ||
      phase == PendingProjectCommitPhase.rolledBack ||
      phase == PendingProjectCommitPhase.aborted;

  Map<String, Object?> toJson(PendingProjectCommitCodec<T> codec) => {
    'schemaVersion': PendingProjectCommitStore.schemaVersion,
    'namespace': namespace,
    'gameId': gameId,
    'txId': txId,
    'idempotencyKey': idempotencyKey,
    'requestHash': requestHash,
    'phase': phase.wireName,
    'payload': codec.encode(payload),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    if (expiresAt != null) 'expiresAt': expiresAt!.toUtc().toIso8601String(),
    if (retainedUntil != null)
      'retainedUntil': retainedUntil!.toUtc().toIso8601String(),
    if (payloadFinalizationHash != null) ...{
      'payloadFinalizationEvidence': payloadFinalizationEvidence,
      'payloadFinalizationHash': payloadFinalizationHash,
    },
  };
}

class PendingProjectCommitLocked implements Exception {
  const PendingProjectCommitLocked({
    required this.activeTxId,
    required this.phase,
  });

  final String activeTxId;
  final PendingProjectCommitPhase phase;
}

class PendingProjectCommitIdempotencyConflict implements Exception {
  const PendingProjectCommitIdempotencyConflict(this.idempotencyKey);

  final String idempotencyKey;
}

class PendingProjectCommitInvalidTransition implements Exception {
  const PendingProjectCommitInvalidTransition({
    required this.from,
    required this.to,
  });

  final PendingProjectCommitPhase from;
  final PendingProjectCommitPhase to;
}

class PendingProjectCommitNotFound implements Exception {
  const PendingProjectCommitNotFound(this.txId);

  final String txId;
}

class PendingProjectCommitExpired implements Exception {
  const PendingProjectCommitExpired(this.txId);

  final String txId;
}

class PendingProjectCommitPayloadFinalizationConflict implements Exception {
  const PendingProjectCommitPayloadFinalizationConflict(this.txId);

  final String txId;
}

typedef PendingProjectCommitRename =
    Future<File> Function(File source, String destination);

/// 提供领域无关的 durable intent、项目逻辑锁、幂等 receipt 与 phase 前进。
///
/// payload 的业务比较和执行由上层协调器负责；本层不认识 history、gameType 或资源。
class PendingProjectCommitStore<T> {
  PendingProjectCommitStore({
    required this.root,
    required this.namespace,
    required this.codec,
    this.preparedTtl = const Duration(minutes: 10),
    this.receiptRetention = const Duration(days: 7),
    DateTime Function()? clock,
    String Function()? idFactory,
    PendingProjectCommitRename? renameFile,
  }) : clock = clock ?? DateTime.now,
       idFactory = idFactory ?? _defaultId,
       _renameFile = renameFile ?? _rename;

  static const schemaVersion = 1;
  static final Map<String, Future<void>> _tails = {};
  static int _sequence = 0;

  final Directory root;
  final String namespace;
  final PendingProjectCommitCodec<T> codec;
  final Duration preparedTtl;
  final Duration receiptRetention;
  final DateTime Function() clock;
  final String Function() idFactory;
  final PendingProjectCommitRename _renameFile;

  Future<PendingProjectCommitRecord<T>> prepare({
    required String gameId,
    required String idempotencyKey,
    required T payload,
    Object? requestValue,
  }) => _serialize(() async {
    _validateToken(gameId, 'gameId');
    _validateToken(idempotencyKey, 'idempotencyKey');
    await _cleanupReceiptsUnlocked();
    await _recoverFile(_activeFile);
    final encoded = requestValue ?? codec.encode(payload);
    final requestHash = await PendingProjectCommitComparator.hashJson(encoded);
    var active = await _readActiveUnlocked();
    if (active != null && _isExpiredPreDecision(active)) {
      await _writeTerminalReceipt(
        active,
        phase: PendingProjectCommitPhase.aborted,
        payload: active.payload,
      );
      active = null;
    }
    if (active != null) {
      if (active.idempotencyKey == idempotencyKey) {
        if (active.requestHash != requestHash) {
          throw PendingProjectCommitIdempotencyConflict(idempotencyKey);
        }
        return active;
      }
      throw PendingProjectCommitLocked(
        activeTxId: active.txId,
        phase: active.phase,
      );
    }
    final receipt = await _receiptForIdempotencyKey(idempotencyKey);
    if (receipt != null) {
      if (receipt.requestHash != requestHash) {
        throw PendingProjectCommitIdempotencyConflict(idempotencyKey);
      }
      return receipt;
    }
    final now = clock().toUtc();
    final record = PendingProjectCommitRecord<T>(
      namespace: namespace,
      gameId: gameId,
      txId: _validatedGeneratedId(idFactory()),
      idempotencyKey: idempotencyKey,
      requestHash: requestHash,
      phase: PendingProjectCommitPhase.prepared,
      payload: payload,
      createdAt: now,
      updatedAt: now,
      expiresAt: now.add(preparedTtl),
    );
    await _writeRecord(_activeFile, record);
    return record;
  });

  /// 根据幂等键查找 active 或 receipt，用于在重建服务端冻结字段前快速重放。
  Future<PendingProjectCommitRecord<T>?> findByIdempotencyKey({
    required String idempotencyKey,
    Object? requestValue,
  }) => _serialize(() async {
    _validateToken(idempotencyKey, 'idempotencyKey');
    await _cleanupReceiptsUnlocked();
    var active = await _readActiveUnlocked();
    if (active != null && _isExpiredPreDecision(active)) {
      await _writeTerminalReceipt(
        active,
        phase: PendingProjectCommitPhase.aborted,
        payload: active.payload,
      );
      active = null;
    }
    final found = active?.idempotencyKey == idempotencyKey
        ? active
        : await _receiptForIdempotencyKey(idempotencyKey);
    if (found == null || requestValue == null) return found;
    final requestHash = await PendingProjectCommitComparator.hashJson(
      requestValue,
    );
    if (found.requestHash != requestHash) {
      throw PendingProjectCommitIdempotencyConflict(idempotencyKey);
    }
    return found;
  });

  Future<PendingProjectCommitRecord<T>> status(String txId) =>
      _serialize(() async {
        _validateToken(txId, 'txId');
        await _cleanupReceiptsUnlocked();
        final receipt = await _readReceipt(txId);
        if (receipt != null) {
          await _deleteActiveIfReceiptMatches(receipt);
          return receipt;
        }
        final active = await _readActiveUnlocked();
        if (active == null || active.txId != txId) {
          throw PendingProjectCommitNotFound(txId);
        }
        if (_isExpiredPreDecision(active)) {
          return _writeTerminalReceipt(
            active,
            phase: PendingProjectCommitPhase.aborted,
            payload: active.payload,
          );
        }
        return active;
      });

  Future<PendingProjectCommitRecord<T>?> active() => _serialize(() async {
    await _cleanupReceiptsUnlocked();
    final active = await _readActiveUnlocked();
    if (active == null) return null;
    if (_isExpiredPreDecision(active)) {
      await _writeTerminalReceipt(
        active,
        phase: PendingProjectCommitPhase.aborted,
        payload: active.payload,
      );
      return null;
    }
    return active;
  });

  Future<void> ensureMutationAllowed() async {
    final record = await active();
    if (record == null) return;
    throw PendingProjectCommitLocked(
      activeTxId: record.txId,
      phase: record.phase,
    );
  }

  Future<PendingProjectCommitRecord<T>> advance({
    required String txId,
    required PendingProjectCommitPhase phase,
    required T payload,
    DateTime? expiresAt,
  }) => _serialize(() async {
    _validateToken(txId, 'txId');
    final receipt = await _readReceipt(txId);
    if (receipt != null) return receipt;
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (_isExpiredPreDecision(active)) {
      await _writeTerminalReceipt(
        active,
        phase: PendingProjectCommitPhase.aborted,
        payload: active.payload,
      );
      throw PendingProjectCommitExpired(txId);
    }
    if (active.phase == phase) return active;
    if (!_isNextPhase(active.phase, phase)) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: phase,
      );
    }
    final updated = _copy(
      active,
      phase: phase,
      payload: payload,
      updatedAt: clock().toUtc(),
      expiresAt: expiresAt?.toUtc(),
    );
    await _writeRecord(_activeFile, updated);
    return updated;
  });

  /// 冻结服务端已经完整验证的领域证据，并把提交点推进到 payload 已就绪。
  ///
  /// evidence 使用领域无关 JSON 保存。相同证据可跨重启幂等重放，任意字段变化都
  /// 会被拒绝，避免上层在后续提交阶段替换已经验证过的工作区或资源集合。
  Future<PendingProjectCommitRecord<T>> markPayloadFinalized({
    required String txId,
    required T payload,
    required Object? evidence,
  }) => _serialize(() async {
    _validateToken(txId, 'txId');
    final frozenEvidence = PendingProjectCommitComparator.canonicalizeJson(
      evidence,
    );
    final evidenceHash = await PendingProjectCommitComparator.hashJson(
      frozenEvidence,
    );
    final receipt = await _readReceipt(txId);
    if (receipt != null) {
      _ensureMatchingFinalization(receipt, evidenceHash);
      return receipt;
    }
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (_isExpiredPreDecision(active)) {
      await _writeTerminalReceipt(
        active,
        phase: PendingProjectCommitPhase.aborted,
        payload: active.payload,
      );
      throw PendingProjectCommitExpired(txId);
    }
    if (active.payloadFinalizationHash != null) {
      _ensureMatchingFinalization(active, evidenceHash);
      return active;
    }
    if (active.phase != PendingProjectCommitPhase.prepared) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: PendingProjectCommitPhase.payloadFinalized,
      );
    }
    final updated = _copy(
      active,
      phase: PendingProjectCommitPhase.payloadFinalized,
      payload: payload,
      updatedAt: clock().toUtc(),
      expiresAt: active.expiresAt,
      payloadFinalizationEvidence: frozenEvidence,
      payloadFinalizationHash: evidenceHash,
    );
    await _writeRecord(_activeFile, updated);
    return updated;
  });

  /// 在 phase 不变时持久化可重入副作用的完成标记。
  Future<PendingProjectCommitRecord<T>> updateActive({
    required String txId,
    required T payload,
  }) => _serialize(() async {
    _validateToken(txId, 'txId');
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (active.isReceipt) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: active.phase,
      );
    }
    final updated = _copy(
      active,
      phase: active.phase,
      payload: payload,
      updatedAt: clock().toUtc(),
      expiresAt: active.expiresAt,
    );
    await _writeRecord(_activeFile, updated);
    return updated;
  });

  Future<PendingProjectCommitRecord<T>> markConflict({
    required String txId,
    required T payload,
  }) => _serialize(() async {
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (active.phase == PendingProjectCommitPhase.conflict) return active;
    if (active.isReceipt) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: PendingProjectCommitPhase.conflict,
      );
    }
    final conflicted = _copy(
      active,
      phase: PendingProjectCommitPhase.conflict,
      payload: payload,
      updatedAt: clock().toUtc(),
      expiresAt: null,
    );
    await _writeRecord(_activeFile, conflicted);
    return conflicted;
  });

  Future<PendingProjectCommitRecord<T>> abortPrepared(String txId) =>
      _serialize(() async {
        final receipt = await _readReceipt(txId);
        if (receipt != null) return receipt;
        final active = await _readActiveUnlocked();
        if (active == null || active.txId != txId) {
          throw PendingProjectCommitNotFound(txId);
        }
        if (active.phase != PendingProjectCommitPhase.prepared) {
          throw PendingProjectCommitInvalidTransition(
            from: active.phase,
            to: PendingProjectCommitPhase.aborted,
          );
        }
        return _writeTerminalReceipt(
          active,
          phase: PendingProjectCommitPhase.aborted,
          payload: active.payload,
        );
      });

  /// 在 durable commit decision 之前放弃 PREPARED/PAYLOAD_FINALIZED。
  Future<PendingProjectCommitRecord<T>> abortPreDecision(String txId) =>
      _serialize(() async {
        final receipt = await _readReceipt(txId);
        if (receipt != null) return receipt;
        final active = await _readActiveUnlocked();
        if (active == null || active.txId != txId) {
          throw PendingProjectCommitNotFound(txId);
        }
        if (active.phase != PendingProjectCommitPhase.prepared &&
            active.phase != PendingProjectCommitPhase.payloadFinalized) {
          throw PendingProjectCommitInvalidTransition(
            from: active.phase,
            to: PendingProjectCommitPhase.aborted,
          );
        }
        return _writeTerminalReceipt(
          active,
          phase: PendingProjectCommitPhase.aborted,
          payload: active.payload,
        );
      });

  /// 显式管理员决议：放弃 CONFLICT 并写稳定 ABORTED receipt。
  Future<PendingProjectCommitRecord<T>> abortConflict(String txId) =>
      _serialize(() async {
        final receipt = await _readReceipt(txId);
        if (receipt != null) return receipt;
        final active = await _readActiveUnlocked();
        if (active == null || active.txId != txId) {
          throw PendingProjectCommitNotFound(txId);
        }
        if (active.phase != PendingProjectCommitPhase.conflict) {
          throw PendingProjectCommitInvalidTransition(
            from: active.phase,
            to: PendingProjectCommitPhase.aborted,
          );
        }
        return _writeTerminalReceipt(
          active,
          phase: PendingProjectCommitPhase.aborted,
          payload: active.payload,
        );
      });

  Future<PendingProjectCommitRecord<T>> complete({
    required String txId,
    required T payload,
  }) => _serialize(() async {
    final receipt = await _readReceipt(txId);
    if (receipt != null) {
      await _deleteActiveIfReceiptMatches(receipt);
      return receipt;
    }
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (active.phase != PendingProjectCommitPhase.backendCommitted) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: PendingProjectCommitPhase.browserPersisted,
      );
    }
    return _writeTerminalReceipt(
      active,
      phase: PendingProjectCommitPhase.browserPersisted,
      payload: payload,
    );
  });

  /// 持久化回滚决议。回滚不是正常 phase 前进链的一部分，必须显式调用。
  ///
  /// 已经写成 ROLLED_BACK receipt 的事务可幂等重放；其它终态不会被回滚覆盖。
  Future<PendingProjectCommitRecord<T>> requestRollback({
    required String txId,
    required T payload,
  }) => _serialize(() async {
    _validateToken(txId, 'txId');
    final receipt = await _readReceipt(txId);
    if (receipt != null) {
      if (receipt.phase == PendingProjectCommitPhase.rolledBack) return receipt;
      throw PendingProjectCommitInvalidTransition(
        from: receipt.phase,
        to: PendingProjectCommitPhase.rollbackRequested,
      );
    }
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (active.phase == PendingProjectCommitPhase.rollbackRequested) {
      return active;
    }
    if (active.phase != PendingProjectCommitPhase.commitRequested &&
        active.phase != PendingProjectCommitPhase.historyApplied &&
        active.phase != PendingProjectCommitPhase.backendCommitted) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: PendingProjectCommitPhase.rollbackRequested,
      );
    }
    final updated = _copy(
      active,
      phase: PendingProjectCommitPhase.rollbackRequested,
      payload: payload,
      updatedAt: clock().toUtc(),
      expiresAt: null,
    );
    await _writeRecord(_activeFile, updated);
    return updated;
  });

  /// 在领域层已经撤销外部副作用后写稳定 ROLLED_BACK receipt 并释放项目锁。
  Future<PendingProjectCommitRecord<T>> completeRollback({
    required String txId,
    required T payload,
  }) => _serialize(() async {
    _validateToken(txId, 'txId');
    final receipt = await _readReceipt(txId);
    if (receipt != null) {
      if (receipt.phase == PendingProjectCommitPhase.rolledBack) return receipt;
      throw PendingProjectCommitInvalidTransition(
        from: receipt.phase,
        to: PendingProjectCommitPhase.rolledBack,
      );
    }
    final active = await _readActiveUnlocked();
    if (active == null || active.txId != txId) {
      throw PendingProjectCommitNotFound(txId);
    }
    if (active.phase != PendingProjectCommitPhase.rollbackRequested) {
      throw PendingProjectCommitInvalidTransition(
        from: active.phase,
        to: PendingProjectCommitPhase.rolledBack,
      );
    }
    return _writeTerminalReceipt(
      active,
      phase: PendingProjectCommitPhase.rolledBack,
      payload: payload,
    );
  });

  Future<PendingProjectCommitRecord<T>> updateReceipt({
    required String txId,
    required T payload,
  }) => _serialize(() async {
    final receipt = await _readReceipt(txId);
    if (receipt == null) throw PendingProjectCommitNotFound(txId);
    final updated = _copy(
      receipt,
      phase: receipt.phase,
      payload: payload,
      updatedAt: clock().toUtc(),
      expiresAt: null,
      retainedUntil: receipt.retainedUntil,
    );
    await _writeRecord(_receiptFile(txId), updated);
    return updated;
  });

  /// 按时间倒序返回未过期 receipt，供上层补发可去重事件。
  Future<List<PendingProjectCommitRecord<T>>> receipts() =>
      _serialize(() async {
        await _cleanupReceiptsUnlocked();
        if (!await _receiptsRoot.exists()) return const [];
        final result = <PendingProjectCommitRecord<T>>[];
        await for (final entity in _receiptsRoot.list(followLinks: false)) {
          if (entity is! File || !entity.path.endsWith('.json')) continue;
          result.add(await _readRecord(entity));
        }
        result.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
        return List.unmodifiable(result);
      });

  Future<PendingProjectCommitRecord<T>> _writeTerminalReceipt(
    PendingProjectCommitRecord<T> active, {
    required PendingProjectCommitPhase phase,
    required T payload,
  }) async {
    final now = clock().toUtc();
    final receipt = _copy(
      active,
      phase: phase,
      payload: payload,
      updatedAt: now,
      expiresAt: null,
      retainedUntil: now.add(receiptRetention),
    );
    await _writeRecord(_receiptFile(active.txId), receipt);
    await _deleteActiveIfReceiptMatches(receipt);
    return receipt;
  }

  Future<PendingProjectCommitRecord<T>?> _readActiveUnlocked() async {
    await _recoverFile(_activeFile);
    if (!await _activeFile.exists()) return null;
    final active = await _readRecord(_activeFile);
    final receipt = await _readReceipt(active.txId);
    if (receipt != null && receipt.isReceipt) {
      await _deleteActiveIfReceiptMatches(receipt);
      return null;
    }
    return active;
  }

  Future<PendingProjectCommitRecord<T>?> _readReceipt(String txId) async {
    final file = _receiptFile(txId);
    await _recoverFile(file);
    if (!await file.exists()) return null;
    return _readRecord(file);
  }

  Future<PendingProjectCommitRecord<T>?> _receiptForIdempotencyKey(
    String idempotencyKey,
  ) async {
    if (!await _receiptsRoot.exists()) return null;
    await for (final entity in _receiptsRoot.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final receipt = await _readRecord(entity);
      if (receipt.idempotencyKey == idempotencyKey) return receipt;
    }
    return null;
  }

  Future<void> _cleanupReceiptsUnlocked() async {
    if (!await _receiptsRoot.exists()) return;
    final now = clock().toUtc();
    await for (final entity in _receiptsRoot.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final receipt = await _readRecord(entity);
      if (receipt.retainedUntil case final retainedUntil?
          when !retainedUntil.isAfter(now)) {
        await entity.delete();
      }
    }
  }

  bool _isExpiredPreDecision(PendingProjectCommitRecord<T> record) =>
      (record.phase == PendingProjectCommitPhase.prepared ||
          record.phase == PendingProjectCommitPhase.payloadFinalized) &&
      record.expiresAt != null &&
      !record.expiresAt!.isAfter(clock().toUtc());

  bool _isNextPhase(
    PendingProjectCommitPhase current,
    PendingProjectCommitPhase target,
  ) => switch (current) {
    PendingProjectCommitPhase.prepared =>
      target == PendingProjectCommitPhase.payloadFinalized ||
          target == PendingProjectCommitPhase.commitRequested,
    PendingProjectCommitPhase.payloadFinalized =>
      target == PendingProjectCommitPhase.commitRequested,
    PendingProjectCommitPhase.commitRequested =>
      target == PendingProjectCommitPhase.historyApplied,
    PendingProjectCommitPhase.historyApplied =>
      target == PendingProjectCommitPhase.backendCommitted,
    _ => false,
  };

  PendingProjectCommitRecord<T> _copy(
    PendingProjectCommitRecord<T> source, {
    required PendingProjectCommitPhase phase,
    required T payload,
    required DateTime updatedAt,
    DateTime? expiresAt,
    DateTime? retainedUntil,
    Object? payloadFinalizationEvidence,
    String? payloadFinalizationHash,
  }) => PendingProjectCommitRecord<T>(
    namespace: source.namespace,
    gameId: source.gameId,
    txId: source.txId,
    idempotencyKey: source.idempotencyKey,
    requestHash: source.requestHash,
    phase: phase,
    payload: payload,
    createdAt: source.createdAt,
    updatedAt: updatedAt,
    expiresAt: expiresAt,
    retainedUntil: retainedUntil,
    payloadFinalizationEvidence: payloadFinalizationHash == null
        ? source.payloadFinalizationEvidence
        : payloadFinalizationEvidence,
    payloadFinalizationHash:
        payloadFinalizationHash ?? source.payloadFinalizationHash,
  );

  Future<PendingProjectCommitRecord<T>> _readRecord(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('项目提交 journal 无效');
    final json = Map<String, Object?>.from(decoded);
    final createdAt = DateTime.tryParse(json['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(json['updatedAt'] as String? ?? '');
    final expiresAt = json['expiresAt'] == null
        ? null
        : DateTime.tryParse(json['expiresAt'] as String? ?? '');
    final retainedUntil = json['retainedUntil'] == null
        ? null
        : DateTime.tryParse(json['retainedUntil'] as String? ?? '');
    final payloadFinalizationHash = json['payloadFinalizationHash'];
    final hasPayloadFinalizationEvidence = json.containsKey(
      'payloadFinalizationEvidence',
    );
    if (json['schemaVersion'] != schemaVersion ||
        json['namespace'] != namespace ||
        json['gameId'] is! String ||
        json['txId'] is! String ||
        json['idempotencyKey'] is! String ||
        json['requestHash'] is! String ||
        json['phase'] is! String ||
        createdAt == null ||
        updatedAt == null ||
        (json.containsKey('expiresAt') && expiresAt == null) ||
        (json.containsKey('retainedUntil') && retainedUntil == null) ||
        ((payloadFinalizationHash == null) !=
            !hasPayloadFinalizationEvidence) ||
        (payloadFinalizationHash != null &&
            (payloadFinalizationHash is! String ||
                !RegExp(
                  r'^[a-f0-9]{64}$',
                ).hasMatch(payloadFinalizationHash)))) {
      throw const FormatException('项目提交 journal 无效');
    }
    _validateToken(json['gameId']! as String, 'gameId');
    _validateToken(json['txId']! as String, 'txId');
    _validateToken(json['idempotencyKey']! as String, 'idempotencyKey');
    final requestHash = json['requestHash']! as String;
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(requestHash)) {
      throw const FormatException('项目提交 requestHash 无效');
    }
    final payloadFinalizationEvidence = payloadFinalizationHash == null
        ? null
        : PendingProjectCommitComparator.canonicalizeJson(
            json['payloadFinalizationEvidence'],
          );
    if (payloadFinalizationHash != null &&
        await PendingProjectCommitComparator.hashJson(
              payloadFinalizationEvidence,
            ) !=
            payloadFinalizationHash) {
      throw const FormatException('项目提交 payload finalization evidence 无效');
    }
    return PendingProjectCommitRecord<T>(
      namespace: namespace,
      gameId: json['gameId']! as String,
      txId: json['txId']! as String,
      idempotencyKey: json['idempotencyKey']! as String,
      requestHash: requestHash,
      phase: PendingProjectCommitPhase.parse(json['phase']! as String),
      payload: codec.decode(json['payload']),
      createdAt: createdAt.toUtc(),
      updatedAt: updatedAt.toUtc(),
      expiresAt: expiresAt?.toUtc(),
      retainedUntil: retainedUntil?.toUtc(),
      payloadFinalizationEvidence: payloadFinalizationEvidence,
      payloadFinalizationHash: payloadFinalizationHash as String?,
    );
  }

  void _ensureMatchingFinalization(
    PendingProjectCommitRecord<T> record,
    String evidenceHash,
  ) {
    if (record.payloadFinalizationHash != evidenceHash) {
      throw PendingProjectCommitPayloadFinalizationConflict(record.txId);
    }
  }

  Future<void> _writeRecord(
    File file,
    PendingProjectCommitRecord<T> record,
  ) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    await _recoverFile(file);
    try {
      await temporary.writeAsString(
        jsonEncode(record.toJson(codec)),
        flush: true,
      );
      if (await backup.exists()) await backup.delete();
      if (await file.exists()) await _renameFile(file, backup.path);
      try {
        await _renameFile(temporary, file.path);
        if (await backup.exists()) await backup.delete();
      } on Object {
        if (await file.exists()) await file.delete();
        if (await backup.exists()) await _renameFile(backup, file.path);
        rethrow;
      }
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _recoverFile(File file) async {
    final temporary = File('${file.path}.tmp');
    final backup = File('${file.path}.backup');
    if (!await file.exists() && await backup.exists()) {
      await _renameFile(backup, file.path);
    }
    if (await temporary.exists()) await temporary.delete();
    if (await file.exists() && await backup.exists()) await backup.delete();
  }

  Future<void> _deleteActiveIfReceiptMatches(
    PendingProjectCommitRecord<T> receipt,
  ) async {
    if (!await _activeFile.exists()) return;
    final active = await _readRecord(_activeFile);
    if (active.txId == receipt.txId) await _activeFile.delete();
    final temporary = File('${_activeFile.path}.tmp');
    final backup = File('${_activeFile.path}.backup');
    if (await temporary.exists()) await temporary.delete();
    if (await backup.exists()) await backup.delete();
  }

  File get _activeFile =>
      File('${root.path}${Platform.pathSeparator}active.json');

  Directory get _receiptsRoot =>
      Directory('${root.path}${Platform.pathSeparator}receipts');

  File _receiptFile(String txId) =>
      File('${_receiptsRoot.path}${Platform.pathSeparator}$txId.json');

  Future<R> _serialize<R>(Future<R> Function() action) {
    final path = root.absolute.path;
    final key = '${Platform.isWindows ? path.toLowerCase() : path}\n$namespace';
    final previous = _tails[key] ?? Future<void>.value();
    final operation = previous.then((_) => action());
    final tail = operation.then<void>((_) {}, onError: (_, _) {});
    _tails[key] = tail;
    tail.whenComplete(() {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return operation;
  }

  String _validatedGeneratedId(String value) {
    _validateToken(value, 'txId');
    return value;
  }

  static void _validateToken(String value, String field) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
      throw FormatException('项目提交 $field 无效');
    }
  }

  static String _defaultId() {
    final sequence = _sequence++;
    return 'tx-${DateTime.now().toUtc().microsecondsSinceEpoch}-$sequence';
  }
}

class PendingProjectCommitComparator {
  const PendingProjectCommitComparator._();

  static Future<String> hashJson(Object? value) async {
    final bytes = utf8.encode(jsonEncode(canonicalizeJson(value)));
    final digest = await Sha256().hash(bytes);
    return digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  static Object? canonicalizeJson(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is List) return value.map(canonicalizeJson).toList();
    if (value is Map) {
      final keys = value.keys.map((key) {
        if (key is! String) {
          throw const FormatException('项目提交 JSON key 必须是字符串');
        }
        return key;
      }).toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: canonicalizeJson(value[key]),
      };
    }
    throw const FormatException('项目提交 payload 不可序列化');
  }
}

Future<File> _rename(File source, String destination) =>
    source.rename(destination);
