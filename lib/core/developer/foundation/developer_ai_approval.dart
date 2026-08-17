import 'dart:async';

import '../developer_event_hub.dart';
import 'developer_ai_approval_store.dart';

enum DeveloperAiApprovalDecision { once, project, always, reject }

enum DeveloperAiApprovalResult { approved, rejected, timeout }

class DeveloperAiCancellation {
  const DeveloperAiCancellation({required this.reason});

  final String reason;
}

/// 只读取消能力；它只在当前进程内按对象身份绑定，不能由 HTTP 字段伪造。
class DeveloperAiCancellationSignal {
  DeveloperAiCancellationSignal._(this._controller);

  final DeveloperAiCancellationController _controller;

  bool get isCancelled => _controller.isCancelled;

  DeveloperAiCancellation? get cancellation => _controller.cancellation;

  Future<DeveloperAiCancellation> get whenCancelled =>
      _controller.whenCancelled;

  /// 监听器在 [DeveloperAiCancellationController.cancel] 内同步执行，确保取消
  /// 与后续审批决策之间具有明确的线性化顺序。
  void Function() addListener(
    void Function(DeveloperAiCancellation cancellation) listener,
  ) => _controller._addListener(listener);
}

/// 取消能力的唯一写端。调用方只把 [signal] 交给审批 Broker 或执行器。
class DeveloperAiCancellationController {
  DeveloperAiCancellationController()
    : _completer = Completer<DeveloperAiCancellation>.sync() {
    signal = DeveloperAiCancellationSignal._(this);
  }

  final Completer<DeveloperAiCancellation> _completer;
  final List<void Function(DeveloperAiCancellation)> _listeners = [];
  late final DeveloperAiCancellationSignal signal;
  DeveloperAiCancellation? _cancellation;

  bool get isCancelled => _cancellation != null;

  DeveloperAiCancellation? get cancellation => _cancellation;

  Future<DeveloperAiCancellation> get whenCancelled => _completer.future;

  bool cancel(String reason) {
    if (_cancellation != null) return false;
    final cancellation = DeveloperAiCancellation(reason: reason);
    _cancellation = cancellation;
    final listeners = List.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener(cancellation);
      } on Object {
        // Cancellation is a safety boundary: one faulty consumer must not
        // prevent the broker or a future executor from observing it.
      }
    }
    _completer.complete(cancellation);
    return true;
  }

  void Function() _addListener(
    void Function(DeveloperAiCancellation cancellation) listener,
  ) {
    final cancellation = _cancellation;
    if (cancellation != null) {
      listener(cancellation);
      return () {};
    }
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }
}

/// AI 审批的领域对象，不依赖 HTTP 路由或某一种编辑器的操作定义。
///
/// `scopeKind + scopeId + operationId` 同时构成审批缓存边界，避免源码工作区
/// 与 GDevelop 工具恰好同名时互相继承授权。
class DeveloperAiApprovalSubject {
  const DeveloperAiApprovalSubject({
    required this.scopeKind,
    required this.scopeId,
    required this.operationId,
    required this.summary,
    required this.description,
    required this.risk,
    required this.dangerous,
    required this.channel,
    this.method,
    this.path,
    this.callId,
    this.editorSessionId,
  });

  final String scopeKind;
  final String? scopeId;
  final String operationId;
  final String summary;
  final String description;
  final String risk;
  final bool dangerous;
  final String channel;
  final String? method;
  final String? path;
  final String? callId;
  final String? editorSessionId;

  String get projectCacheKey => '$scopeKind::${scopeId ?? ''}::$operationId';

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'summary': summary,
    'description': description,
    if (method != null) 'method': method,
    if (path != null) 'path': path,
    'risk': risk,
    'dangerous': dangerous,
    'scopeKind': scopeKind,
    'scopeId': scopeId,
    // 保留源码工作区现有 DTO 字段；GDevelop 使用明确的 gameId 字段。
    if (scopeKind == 'source') 'projectId': scopeId,
    if (scopeKind == 'gdevelop') 'gameId': scopeId,
    'channel': channel,
    if (callId != null) 'callId': callId,
    if (editorSessionId != null) 'editorSessionId': editorSessionId,
  };
}

class DeveloperAiApprovalRequest {
  DeveloperAiApprovalRequest({
    required this.id,
    required this.requestId,
    required this.subject,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String requestId;
  final DeveloperAiApprovalSubject subject;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Completer<DeveloperAiApprovalResult> completer =
      Completer<DeveloperAiApprovalResult>();
  Timer? timer;
  bool cancelled = false;
  DeveloperAiApprovalGrant? pendingPersistentGrant;
  Future<void>? persistentRollback;
  void Function()? removeCancellationListener;

  Map<String, Object?> toJson() => {
    'approvalId': id,
    'requestId': requestId,
    ...subject.toJson(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'timeoutSeconds': DeveloperAiApprovalBroker.timeout.inSeconds,
  };
}

class DeveloperAiApprovalBroker {
  DeveloperAiApprovalBroker({
    DateTime Function()? clock,
    this.idFactory,
    DeveloperAiApprovalPersistence? persistence,
  }) : _clock = clock ?? DateTime.now,
       _persistence = persistence ?? FileDeveloperAiApprovalPersistence();

  static const timeout = Duration(seconds: 30);

  final DateTime Function() _clock;
  final String Function()? idFactory;
  final DeveloperAiApprovalPersistence _persistence;
  final Map<String, DeveloperAiApprovalRequest> _pending = {};
  final Set<String> _projectApprovals = {};
  Map<String, DeveloperAiApprovalGrant> _alwaysApprovals = {};
  Future<void>? _initialization;
  Future<void> _persistentTail = Future<void>.value();
  bool _disposed = false;
  int _sequence = 0;

  List<Map<String, Object?>> get pending =>
      _pending.values.map((item) => item.toJson()).toList(growable: false);

  Future<void> initialize() => _initialization ??= () async {
    try {
      final loaded = await _persistence.load();
      if (_disposed) return;
      _alwaysApprovals = {for (final grant in loaded) grant.cacheKey: grant};
    } on Object {
      // A missing/corrupt/unreadable grant file must fail closed. It must never
      // turn an unknown persisted decision into an implicit approval.
      if (!_disposed) _alwaysApprovals = {};
    }
  }();

  Future<List<Map<String, Object?>>> listAlwaysGrants() async {
    await _persistentBarrier();
    final grants = _alwaysApprovals.values.toList()
      ..sort((left, right) => left.cacheKey.compareTo(right.cacheKey));
    return List.unmodifiable(
      grants.map(
        (grant) => Map<String, Object?>.unmodifiable(grant.toPublicJson()),
      ),
    );
  }

  Future<DeveloperAiApprovalResult> request({
    required String requestId,
    required DeveloperAiApprovalSubject subject,
    DeveloperAiCancellationSignal? cancellation,
  }) async {
    if (!subject.dangerous) return DeveloperAiApprovalResult.approved;
    await _persistentBarrier();
    if (_disposed || cancellation?.isCancelled == true) {
      return DeveloperAiApprovalResult.rejected;
    }
    if (_alwaysApprovals.containsKey(subject.projectCacheKey) ||
        (subject.scopeId != null &&
            _projectApprovals.contains(subject.projectCacheKey))) {
      return DeveloperAiApprovalResult.approved;
    }
    final createdAt = _clock().toUtc();
    final approval = DeveloperAiApprovalRequest(
      id:
          idFactory?.call() ??
          'approval-${createdAt.microsecondsSinceEpoch}-${++_sequence}',
      requestId: requestId,
      subject: subject,
      createdAt: createdAt,
      expiresAt: createdAt.add(timeout),
    );
    _pending[approval.id] = approval;
    approval.removeCancellationListener = cancellation?.addListener((_) {
      _cancelApprovalNow(approval);
    });
    if (approval.cancelled) return DeveloperAiApprovalResult.rejected;
    approval.timer = Timer(timeout, () {
      if (!approval.completer.isCompleted) {
        approval.completer.complete(DeveloperAiApprovalResult.timeout);
      }
    });
    developerEventHub.emit({
      'type': 'ai.approval.requested',
      ...approval.toJson(),
      'timestamp': createdAt.millisecondsSinceEpoch,
    });
    final result = await approval.completer.future;
    approval.timer?.cancel();
    approval.removeCancellationListener?.call();
    if (identical(_pending[approval.id], approval)) {
      _pending.remove(approval.id);
    }
    developerEventHub.emit({
      'type': 'ai.approval.resolved',
      'approvalId': approval.id,
      'requestId': requestId,
      'operationId': subject.operationId,
      'scopeKind': subject.scopeKind,
      'scopeId': subject.scopeId,
      if (subject.scopeKind == 'source') 'projectId': subject.scopeId,
      if (subject.scopeKind == 'gdevelop') 'gameId': subject.scopeId,
      if (subject.callId != null) 'callId': subject.callId,
      if (subject.editorSessionId != null)
        'editorSessionId': subject.editorSessionId,
      'result': result.name,
      'timestamp': _clock().toUtc().millisecondsSinceEpoch,
    });
    return result;
  }

  Future<void> decide(
    String approvalId,
    DeveloperAiApprovalDecision decision,
  ) async {
    final approval = _pending[approvalId];
    if (approval == null || approval.completer.isCompleted) {
      throw StateError('AI 操作审批不存在或已经结束');
    }
    await _decideApproval(approval, decision);
  }

  Future<void> _decideApproval(
    DeveloperAiApprovalRequest approval,
    DeveloperAiApprovalDecision decision,
  ) async {
    switch (decision) {
      case DeveloperAiApprovalDecision.once:
        approval.completer.complete(DeveloperAiApprovalResult.approved);
      case DeveloperAiApprovalDecision.project:
        if (approval.subject.scopeId == null ||
            approval.subject.scopeId!.isEmpty) {
          throw const FormatException('该操作不属于具体项目，不能按项目允许');
        }
        if (approval.cancelled) {
          throw StateError('AI 操作审批不存在或已经结束');
        }
        _projectApprovals.add(approval.subject.projectCacheKey);
        approval.completer.complete(DeveloperAiApprovalResult.approved);
      case DeveloperAiApprovalDecision.always:
        final scopeId = approval.subject.scopeId;
        if (scopeId == null || scopeId.isEmpty) {
          throw const FormatException('该操作不属于具体项目，不能始终允许');
        }
        final grant = DeveloperAiApprovalGrant.fromJson({
          'scopeKind': approval.subject.scopeKind,
          'scopeId': scopeId,
          'operationId': approval.subject.operationId,
        });
        approval.timer?.cancel();
        approval.pendingPersistentGrant = grant;
        try {
          final operation = _enqueuePersistent((current) {
            if (approval.cancelled) return current;
            return {...current, grant.cacheKey: grant};
          });
          await operation;
          if (approval.cancelled) {
            approval.persistentRollback ??= _enqueuePersistent(
              (current) =>
                  Map<String, DeveloperAiApprovalGrant>.from(current)
                    ..remove(grant.cacheKey),
              allowDisposed: true,
            );
            await approval.persistentRollback;
            return;
          }
        } on Object {
          if (!approval.cancelled) _restoreApprovalTimer(approval);
          rethrow;
        }
        approval.completer.complete(DeveloperAiApprovalResult.approved);
      case DeveloperAiApprovalDecision.reject:
        approval.completer.complete(DeveloperAiApprovalResult.rejected);
    }
  }

  Future<bool> revokeAlways(String grantId) async {
    var removed = false;
    await _updatePersistent((current) {
      final matches = current.values
          .where((grant) => grant.id == grantId)
          .toList(growable: false);
      if (matches.length != 1) return current;
      final next = Map<String, DeveloperAiApprovalGrant>.from(current);
      next.remove(matches.single.cacheKey);
      removed = true;
      return next;
    });
    return removed;
  }

  Future<void> clearScopeApprovals({
    required String scopeKind,
    required String scopeId,
  }) async {
    for (final approval
        in _pending.values
            .where(
              (item) =>
                  item.subject.scopeKind == scopeKind &&
                  item.subject.scopeId == scopeId,
            )
            .toList(growable: false)) {
      _cancelApprovalNow(approval);
    }
    await _persistentBarrier();
    final prefix = '$scopeKind::$scopeId::';
    final removedProjectApprovals = _projectApprovals
        .where((key) => key.startsWith(prefix))
        .toSet();
    _projectApprovals.removeAll(removedProjectApprovals);
    try {
      await _updatePersistent((current) {
        final next = Map<String, DeveloperAiApprovalGrant>.from(current)
          ..removeWhere(
            (_, grant) =>
                grant.scopeKind == scopeKind && grant.scopeId == scopeId,
          );
        return next;
      });
    } on Object {
      if (!_disposed) _projectApprovals.addAll(removedProjectApprovals);
      rethrow;
    }
  }

  /// 原子迁移持久授权并拒绝旧 scope 的待决请求。
  Future<void> migrateScopeApprovals({
    required String scopeKind,
    required String oldScopeId,
    required String newScopeId,
  }) async {
    if (oldScopeId == newScopeId) {
      throw const FormatException('AI 审批 scope 迁移目标不能与来源相同');
    }
    for (final approval
        in _pending.values
            .where(
              (item) =>
                  item.subject.scopeKind == scopeKind &&
                  item.subject.scopeId == oldScopeId,
            )
            .toList(growable: false)) {
      _cancelApprovalNow(approval);
    }
    await _persistentBarrier();

    final oldPrefix = '$scopeKind::$oldScopeId::';
    final oldProjectApprovals = _projectApprovals
        .where((key) => key.startsWith(oldPrefix))
        .toSet();
    await _updatePersistent((current) {
      final next = Map<String, DeveloperAiApprovalGrant>.from(current);
      final migrating = current.values
          .where(
            (grant) =>
                grant.scopeKind == scopeKind && grant.scopeId == oldScopeId,
          )
          .toList(growable: false);
      next.removeWhere(
        (_, grant) =>
            grant.scopeKind == scopeKind && grant.scopeId == oldScopeId,
      );
      for (final grant in migrating) {
        final moved = DeveloperAiApprovalGrant.fromJson({
          'scopeKind': scopeKind,
          'scopeId': newScopeId,
          'operationId': grant.operationId,
        });
        next[moved.cacheKey] = moved;
      }
      return next;
    });

    _projectApprovals.removeAll(oldProjectApprovals);
    for (final key in oldProjectApprovals) {
      _projectApprovals.add(
        '$scopeKind::$newScopeId::${key.substring(oldPrefix.length)}',
      );
    }
  }

  Future<void> _persistentBarrier() async {
    await initialize();
    await _persistentTail;
  }

  Future<void> _updatePersistent(
    Map<String, DeveloperAiApprovalGrant> Function(
      Map<String, DeveloperAiApprovalGrant> current,
    )
    update,
  ) async {
    await initialize();
    await _enqueuePersistent(update);
  }

  Future<void> _enqueuePersistent(
    Map<String, DeveloperAiApprovalGrant> Function(
      Map<String, DeveloperAiApprovalGrant> current,
    )
    update, {
    bool allowDisposed = false,
  }) {
    final operation = _persistentTail.then((_) async {
      if (_disposed && !allowDisposed) {
        throw StateError('AI 审批 Broker 已关闭');
      }
      final next = update(
        Map<String, DeveloperAiApprovalGrant>.from(_alwaysApprovals),
      );
      await _persistence.save(next.values);
      _alwaysApprovals = Map.unmodifiable(next);
    });
    _persistentTail = operation.then<void>((_) {}, onError: (_, _) {});
    return operation;
  }

  void _cancelApprovalNow(DeveloperAiApprovalRequest approval) {
    if (approval.cancelled || approval.completer.isCompleted) return;
    approval
      ..cancelled = true
      ..timer?.cancel();
    if (identical(_pending[approval.id], approval)) {
      _pending.remove(approval.id);
    }
    final grant = approval.pendingPersistentGrant;
    if (grant != null) {
      approval.persistentRollback ??= _enqueuePersistent(
        (current) =>
            Map<String, DeveloperAiApprovalGrant>.from(current)
              ..remove(grant.cacheKey),
        allowDisposed: true,
      );
    }
    approval.completer.complete(DeveloperAiApprovalResult.rejected);
  }

  void _restoreApprovalTimer(DeveloperAiApprovalRequest approval) {
    if (approval.completer.isCompleted) return;
    final remaining = approval.expiresAt.difference(_clock().toUtc());
    if (remaining <= Duration.zero) {
      approval.completer.complete(DeveloperAiApprovalResult.timeout);
      return;
    }
    approval.timer = Timer(remaining, () {
      if (!approval.completer.isCompleted) {
        approval.completer.complete(DeveloperAiApprovalResult.timeout);
      }
    });
  }

  void dispose() {
    for (final approval in _pending.values.toList(growable: false)) {
      _cancelApprovalNow(approval);
    }
    _disposed = true;
    _pending.clear();
    _projectApprovals.clear();
    _alwaysApprovals = {};
  }
}
