part of '../../developer_web_gateway_io.dart';

enum _DeveloperAiApprovalDecision { once, project, always, reject }

enum _DeveloperAiApprovalResult { approved, rejected, timeout }

class _DeveloperAiApprovalRequest {
  _DeveloperAiApprovalRequest({
    required this.id,
    required this.requestId,
    required this.operation,
    required this.projectId,
    required this.channel,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String requestId;
  final DeveloperOperationDefinition operation;
  final String? projectId;
  final String channel;
  final DateTime createdAt;
  final DateTime expiresAt;
  final Completer<_DeveloperAiApprovalResult> completer =
      Completer<_DeveloperAiApprovalResult>();
  Timer? timer;

  Map<String, Object?> toJson() => {
    'approvalId': id,
    'requestId': requestId,
    'operationId': operation.id,
    'summary': operation.summary,
    'description': operation.description,
    'method': operation.normalizedMethod,
    'path': operation.path,
    'risk': operation.risk.name,
    'dangerous': operation.dangerous,
    'projectId': projectId,
    'channel': channel,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'expiresAt': expiresAt.millisecondsSinceEpoch,
    'timeoutSeconds': 30,
  };
}

class _DeveloperAiApprovalBroker {
  static const timeout = Duration(seconds: 30);

  final Map<String, _DeveloperAiApprovalRequest> _pending = {};
  final Set<String> _projectApprovals = {};
  final Set<String> _alwaysApprovals = {};

  List<Map<String, Object?>> get pending =>
      _pending.values.map((item) => item.toJson()).toList(growable: false);

  Future<_DeveloperAiApprovalResult> request({
    required String requestId,
    required DeveloperOperationDefinition operation,
    required String? projectId,
    required String channel,
  }) async {
    if (_alwaysApprovals.contains(operation.id) ||
        (projectId != null &&
            _projectApprovals.contains(_projectKey(operation.id, projectId)))) {
      return _DeveloperAiApprovalResult.approved;
    }
    final createdAt = DateTime.now().toUtc();
    final approval = _DeveloperAiApprovalRequest(
      id: 'approval-${_randomHex(8)}',
      requestId: requestId,
      operation: operation,
      projectId: projectId,
      channel: channel,
      createdAt: createdAt,
      expiresAt: createdAt.add(timeout),
    );
    _pending[approval.id] = approval;
    approval.timer = Timer(timeout, () {
      if (!approval.completer.isCompleted) {
        approval.completer.complete(_DeveloperAiApprovalResult.timeout);
      }
    });
    developerEventHub.emit({
      'type': 'ai.approval.requested',
      ...approval.toJson(),
      'timestamp': createdAt.millisecondsSinceEpoch,
    });
    final result = await approval.completer.future;
    approval.timer?.cancel();
    _pending.remove(approval.id);
    developerEventHub.emit({
      'type': 'ai.approval.resolved',
      'approvalId': approval.id,
      'requestId': requestId,
      'operationId': operation.id,
      'projectId': projectId,
      'result': result.name,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    return result;
  }

  void decide(String approvalId, _DeveloperAiApprovalDecision decision) {
    final approval = _pending[approvalId];
    if (approval == null || approval.completer.isCompleted) {
      throw StateError('AI 操作审批不存在或已经结束');
    }
    switch (decision) {
      case _DeveloperAiApprovalDecision.once:
        approval.completer.complete(_DeveloperAiApprovalResult.approved);
      case _DeveloperAiApprovalDecision.project:
        final projectId = approval.projectId;
        if (projectId == null || projectId.isEmpty) {
          throw const FormatException('该操作不属于具体项目，不能按项目允许');
        }
        _projectApprovals.add(_projectKey(approval.operation.id, projectId));
        approval.completer.complete(_DeveloperAiApprovalResult.approved);
      case _DeveloperAiApprovalDecision.always:
        _alwaysApprovals.add(approval.operation.id);
        approval.completer.complete(_DeveloperAiApprovalResult.approved);
      case _DeveloperAiApprovalDecision.reject:
        approval.completer.complete(_DeveloperAiApprovalResult.rejected);
    }
  }

  void dispose() {
    for (final approval in _pending.values) {
      approval.timer?.cancel();
      if (!approval.completer.isCompleted) {
        approval.completer.complete(_DeveloperAiApprovalResult.rejected);
      }
    }
    _pending.clear();
  }

  String _projectKey(String operationId, String projectId) =>
      '$projectId::$operationId';
}
