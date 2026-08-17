import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'foundation/developer_ai_approval.dart';
import 'gdevelop_ai_event.dart';
import 'gdevelop_ai_project_context.dart';
import 'gdevelop_ai_tool_registry.dart';

enum GDevelopAiMode {
  chat('chat'),
  agent('agent');

  const GDevelopAiMode(this.wireName);

  final String wireName;

  static GDevelopAiMode parse(String value) => values.firstWhere(
    (mode) => mode.wireName == value,
    orElse: () => throw const FormatException('GDevelop AI mode 无效'),
  );
}

enum GDevelopAiCallState {
  queued('queued'),
  awaitingApproval('awaiting_approval'),
  running('running'),
  finished('finished'),
  failed('failed'),
  cancelled('cancelled'),
  timedOut('timed_out');

  const GDevelopAiCallState(this.wireName);

  final String wireName;

  bool get terminal => const {
    GDevelopAiCallState.finished,
    GDevelopAiCallState.failed,
    GDevelopAiCallState.cancelled,
    GDevelopAiCallState.timedOut,
  }.contains(this);
}

class GDevelopAiSessionNotFound implements Exception {
  const GDevelopAiSessionNotFound();
}

class GDevelopAiCallConflict implements Exception {
  const GDevelopAiCallConflict(this.code, this.message);

  final String code;
  final String message;
}

class GDevelopAiExecutionOutputValidationException implements Exception {
  const GDevelopAiExecutionOutputValidationException(this.code, this.message);

  final String code;
  final String message;
}

class GDevelopAiWriterLease {
  const GDevelopAiWriterLease({
    required this.gameId,
    required this.ownerEditorSessionId,
    required this.callId,
  });

  final String gameId;
  final String ownerEditorSessionId;
  final String callId;
}

class GDevelopAiEditorSession {
  const GDevelopAiEditorSession({
    required this.id,
    required this.gameId,
    required this.mode,
    required this.locale,
    required this.projectContext,
    required this.createdAt,
    required this.expiresAt,
    required this.sequence,
    required this.closed,
    required this.toolContractHash,
  });

  final String id;
  final String gameId;
  final GDevelopAiMode mode;
  final String locale;
  final GDevelopAiProjectContext? projectContext;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final int sequence;
  final bool closed;
  final String toolContractHash;

  Map<String, Object?> toJson() => {
    'editorSessionId': id,
    'gameId': gameId,
    'mode': mode.wireName,
    'locale': locale,
    'projectContext': projectContext?.metadataJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt?.toUtc().toIso8601String(),
    'sequence': sequence,
    'closed': closed,
    'toolContractHash': toolContractHash,
  };
}

class GDevelopAiTurn {
  const GDevelopAiTurn({
    required this.id,
    required this.editorSessionId,
    required this.sequence,
    required this.createdAt,
    this.clientMessageId,
  });

  final String id;
  final String editorSessionId;
  final int sequence;
  final DateTime createdAt;
  final String? clientMessageId;

  Map<String, Object?> toJson() => {
    'turnId': id,
    'editorSessionId': editorSessionId,
    'sequence': sequence,
    'createdAt': createdAt.toUtc().toIso8601String(),
    if (clientMessageId != null) 'clientMessageId': clientMessageId,
  };
}

class GDevelopAiCall {
  const GDevelopAiCall({
    required this.id,
    required this.editorSessionId,
    required this.turnId,
    required this.toolName,
    required this.arguments,
    required this.idempotencyKey,
    required this.state,
    required this.sequence,
    required this.createdAt,
    required this.updatedAt,
    this.input,
    this.output,
    this.errorCode,
    this.errorMessage,
  });

  final String id;
  final String editorSessionId;
  final String turnId;
  final String toolName;
  final Map<String, Object?> arguments;
  final String idempotencyKey;
  final GDevelopAiCallState state;
  final int sequence;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Transient browser execution input. It is exposed only while the call is
  /// active and is discarded as soon as the call becomes terminal.
  final Map<String, Object?>? input;

  /// 仅保存浏览器执行器返回的普通结果，不保留任何 Gateway 命名空间。
  final Map<String, Object?>? output;

  final String? errorCode;
  final String? errorMessage;

  Map<String, Object?> toJson({String? requestId}) => {
    'callId': id,
    'editorSessionId': editorSessionId,
    'turnId': turnId,
    'toolName': toolName,
    'arguments': arguments,
    'idempotencyKey': idempotencyKey,
    'state': state.wireName,
    'sequence': sequence,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'input': ?input,
    'output': ?output,
    if (errorCode != null)
      'error': {
        'stage': 'tool_execution',
        'operation': toolName,
        'status': 0,
        'code': errorCode,
        'reason': errorMessage?.trim().isNotEmpty == true
            ? errorMessage
            : errorCode,
        'requestId': requestId ?? 'unavailable',
        'type': 'GDevelopAiToolExecutionError',
        'message': errorMessage,
      },
  };
}

class _MutableGDevelopAiSession {
  _MutableGDevelopAiSession({
    required this.id,
    required this.gameId,
    required this.mode,
    required this.locale,
    required this.projectContext,
    required this.createdAt,
    required this.expiresAt,
    required this.toolRegistry,
  });

  final String id;
  final String gameId;
  final GDevelopAiMode mode;
  String locale;
  GDevelopAiProjectContext? projectContext;
  final DateTime createdAt;
  DateTime? expiresAt;
  int sequence = 0;
  bool closed = false;
  final GDevelopAiToolRegistry toolRegistry;
  final Map<String, GDevelopAiTurn> turns = {};
  final Map<String, _MutableGDevelopAiCall> calls = {};
  final Map<String, String> idempotencyCallIds = {};

  GDevelopAiEditorSession snapshot() => GDevelopAiEditorSession(
    id: id,
    gameId: gameId,
    mode: mode,
    locale: locale,
    projectContext: projectContext,
    createdAt: createdAt,
    expiresAt: expiresAt,
    sequence: sequence,
    closed: closed,
    toolContractHash: toolRegistry.contractHash,
  );
}

class _MutableGDevelopAiCall {
  _MutableGDevelopAiCall({
    required this.id,
    required this.editorSessionId,
    required this.turnId,
    required this.toolName,
    required this.arguments,
    required this.idempotencyKey,
    required this.requestFingerprint,
    required this.state,
    required this.sequence,
    required this.createdAt,
  }) : updatedAt = createdAt;

  final String id;
  final String editorSessionId;
  final String turnId;
  final String toolName;
  final Map<String, Object?> arguments;
  final String idempotencyKey;
  final String requestFingerprint;
  GDevelopAiCallState state;
  int sequence;
  final DateTime createdAt;
  DateTime updatedAt;
  Map<String, Object?>? input;
  Map<String, Object?>? output;
  String? errorCode;
  String? errorMessage;
  Timer? timeoutTimer;
  final DeveloperAiCancellationController cancellation =
      DeveloperAiCancellationController();

  GDevelopAiCall snapshot() => GDevelopAiCall(
    id: id,
    editorSessionId: editorSessionId,
    turnId: turnId,
    toolName: toolName,
    arguments: arguments,
    idempotencyKey: idempotencyKey,
    state: state,
    sequence: sequence,
    createdAt: createdAt,
    updatedAt: updatedAt,
    input: input,
    output: output,
    errorCode: errorCode,
    errorMessage: errorMessage,
  );
}

class _MutableGDevelopAiWriterLease {
  _MutableGDevelopAiWriterLease({
    required this.gameId,
    required this.ownerEditorSessionId,
    required this.callId,
  });

  final String gameId;
  final String ownerEditorSessionId;
  final String callId;

  GDevelopAiWriterLease snapshot() => GDevelopAiWriterLease(
    gameId: gameId,
    ownerEditorSessionId: ownerEditorSessionId,
    callId: callId,
  );
}

/// In-memory protocol state. Authentication is enforced by the Gateway's typed
/// principals and exact-operation policy; an editorSessionId is only a scope /
/// idempotency key and is never an auth secret.
class GDevelopAiSessionService {
  GDevelopAiSessionService({this.sessionTtl, DateTime Function()? clock})
    : clock = clock ?? DateTime.now {
    if (sessionTtl != null && sessionTtl! <= Duration.zero) {
      throw const FormatException('GDevelop AI session TTL 无效');
    }
  }

  static const protocolVersion = '2.0.0';

  GDevelopAiToolRegistry toolRegistryForSession(String editorSessionId) =>
      _requireSession(editorSessionId).toolRegistry;

  /// Null in production: editor AI sessions live for the Developer Gateway
  /// lifetime and are disposed together when Developer Mode is turned off.
  /// A finite value remains injectable for deterministic expiry tests only.
  final Duration? sessionTtl;
  final DateTime Function() clock;
  final Map<String, _MutableGDevelopAiSession> _sessions = {};
  final Map<String, Timer> _sessionTimers = {};
  final Map<String, _MutableGDevelopAiWriterLease> _writerLeases = {};
  final Map<String, Map<String, List<int>>> _stagedResources = {};
  final Set<String> _claimedApprovalCalls = {};
  final StreamController<({String gameId, GDevelopAiCall call})> _callUpdates =
      StreamController.broadcast(sync: true);
  final StreamController<GDevelopAiEvent> _aiEvents =
      StreamController<GDevelopAiEvent>.broadcast(sync: true);
  final StreamController<
    ({String gameId, String editorSessionId, String reason})
  >
  _sessionClosures = StreamController.broadcast(sync: true);
  final Random _random = Random.secure();
  bool _disposed = false;

  Stream<({String gameId, GDevelopAiCall call})> get callUpdates =>
      _callUpdates.stream;

  Stream<GDevelopAiEvent> get aiEvents => _aiEvents.stream;

  Stream<({String gameId, String editorSessionId, String reason})>
  get sessionClosures => _sessionClosures.stream;

  DeveloperAiCancellationSignal cancellationSignal(
    String editorSessionId,
    String callId,
  ) => _requireCall(editorSessionId, callId).call.cancellation.signal;

  GDevelopAiWriterLease? writerLease(String gameId) {
    _validateGameId(gameId);
    return _writerLeases[gameId]?.snapshot();
  }

  Future<void> stageResource({
    required String editorSessionId,
    required String expectedHash,
    required List<int> bytes,
  }) async {
    _requireSession(editorSessionId);
    _validateHash(expectedHash);
    if (bytes.isEmpty) throw const FormatException('GDevelop AI resource 为空');
    final digest = await Sha256().hash(bytes);
    final actualHash = digest.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    if (actualHash != expectedHash) {
      throw const FormatException('GDevelop AI resource contentHash 不匹配');
    }
    (_stagedResources[editorSessionId] ??= {})[expectedHash] =
        List<int>.unmodifiable(bytes);
  }

  List<int> takeStagedResource({
    required String editorSessionId,
    required String contentHash,
    required int size,
  }) {
    _requireSession(editorSessionId);
    _validateHash(contentHash);
    final sessionResources = _stagedResources[editorSessionId];
    final bytes = sessionResources?[contentHash];
    if (bytes != null && bytes.length == size) {
      sessionResources!.remove(contentHash);
      return bytes;
    }
    throw const GDevelopAiCallConflict(
      'gdevelop_ai_resource_missing',
      'GDevelop AI 暂存资源不存在',
    );
  }

  GDevelopAiEditorSession open({
    required String gameId,
    required GDevelopAiMode mode,
    required String locale,
    GDevelopAiProjectContext? projectContext,
    String? resumeEditorSessionId,
    required GDevelopAiToolRegistry registry,
  }) {
    _ensureActive();
    _validateGameId(gameId);
    _validateLocale(locale);
    final now = clock().toUtc();
    final id = resumeEditorSessionId == null
        ? 'gdas-${_randomHex(16)}'
        : _validateClientId(resumeEditorSessionId, 'resumeEditorSessionId');
    if (_sessions.containsKey(id)) {
      throw const GDevelopAiCallConflict(
        'editor_session_id_conflict',
        'GDevelop AI editor session id 已被占用',
      );
    }
    final session = _MutableGDevelopAiSession(
      id: id,
      gameId: gameId,
      mode: mode,
      locale: locale,
      projectContext: projectContext,
      createdAt: now,
      expiresAt: sessionTtl == null ? null : now.add(sessionTtl!),
      toolRegistry: registry,
    );
    _sessions[id] = session;
    if (sessionTtl != null) {
      _sessionTimers[id] = Timer(sessionTtl!, () => _expireSession(id));
    }
    final snapshot = session.snapshot();
    _emitAiEvent(
      GDevelopAiEvent.sessionUpdated(
        gameId: gameId,
        editorSessionId: id,
        sequence: session.sequence,
        state: GDevelopAiSessionEventState.opened,
      ),
    );
    return snapshot;
  }

  /// Reattaches a WebIDE page/panel to the Developer-Mode-scoped session for
  /// this project. Calls and the stable session id survive panel close, WebIDE
  /// backgrounding and a page reload; the opened event only rebinds the
  /// session to the current single-editor lease generation.
  GDevelopAiEditorSession reattachOrOpen({
    required String gameId,
    required GDevelopAiMode mode,
    required String locale,
    GDevelopAiProjectContext? projectContext,
    String? resumeEditorSessionId,
    required GDevelopAiToolRegistry registry,
  }) {
    _ensureActive();
    _validateGameId(gameId);
    _validateLocale(locale);
    final normalizedResumeId = resumeEditorSessionId == null
        ? null
        : _validateClientId(resumeEditorSessionId, 'resumeEditorSessionId');
    final registrySnapshot = registry;
    _MutableGDevelopAiSession? existing;
    if (normalizedResumeId != null) {
      final candidate = _sessions[normalizedResumeId];
      if (candidate != null &&
          !candidate.closed &&
          candidate.gameId == gameId &&
          candidate.mode == mode &&
          candidate.toolRegistry.contractHash ==
              registrySnapshot.contractHash) {
        existing = candidate;
      }
    }
    existing ??=
        (_sessions.values
                .where(
                  (candidate) =>
                      !candidate.closed &&
                      candidate.gameId == gameId &&
                      candidate.mode == mode &&
                      candidate.toolRegistry.contractHash ==
                          registrySnapshot.contractHash,
                )
                .toList(growable: false)
              ..sort(
                (left, right) => right.createdAt.compareTo(left.createdAt),
              ))
            .firstOrNull;
    if (existing == null) {
      return open(
        gameId: gameId,
        mode: mode,
        locale: locale,
        projectContext: projectContext,
        resumeEditorSessionId: null,
        registry: registrySnapshot,
      );
    }
    // A page reload cannot prove whether an in-flight EditorFunction already
    // mutated the WebIDE memory project. Never lease that write again: the
    // browser may retry only its exact terminal result submission.
    for (final call in existing.calls.values.toList(growable: false)) {
      final inFlight = call.state == GDevelopAiCallState.running;
      if (inFlight &&
          existing.toolRegistry.definition(call.toolName).modifiesProject) {
        call.cancellation.cancel('worker_reloaded');
        _transition(
          existing,
          call,
          GDevelopAiCallState.failed,
          errorCode: 'worker_reloaded',
          errorMessage: 'WebIDE 页面已重新加载，未完成的写工具不会再次执行',
        );
      }
    }
    existing
      ..locale = locale
      ..projectContext = projectContext
      ..sequence += 1;
    final snapshot = existing.snapshot();
    _emitAiEvent(
      GDevelopAiEvent.sessionUpdated(
        gameId: gameId,
        editorSessionId: existing.id,
        sequence: existing.sequence,
        state: GDevelopAiSessionEventState.opened,
      ),
    );
    return snapshot;
  }

  GDevelopAiEditorSession session(String editorSessionId) =>
      _requireSession(editorSessionId).snapshot();

  GDevelopAiCall call(String editorSessionId, String callId) =>
      _requireCall(editorSessionId, callId).call.snapshot();

  /// Claims the single approval request slot for an awaiting call. Replayed
  /// enqueue requests therefore reuse the same pending approval instead of
  /// creating multiple user prompts.
  bool claimApprovalRequest(String editorSessionId, String callId) {
    final pair = _requireCall(editorSessionId, callId);
    if (pair.call.state != GDevelopAiCallState.awaitingApproval) return false;
    return _claimedApprovalCalls.add('$editorSessionId\u0000$callId');
  }

  GDevelopAiEditorSession useLocale(String editorSessionId, String locale) {
    return updateSession(editorSessionId, locale: locale);
  }

  GDevelopAiEditorSession useProjectContext(
    String editorSessionId,
    GDevelopAiProjectContext projectContext,
  ) {
    return updateSession(editorSessionId, projectContext: projectContext);
  }

  GDevelopAiEditorSession updateSession(
    String editorSessionId, {
    String? locale,
    GDevelopAiProjectContext? projectContext,
  }) {
    if (locale == null && projectContext == null) {
      throw const FormatException('GDevelop AI session PATCH 没有可更新字段');
    }
    if (locale != null) _validateLocale(locale);
    final session = _requireSession(editorSessionId);
    if (locale != null) session.locale = locale;
    if (projectContext != null) {
      session.projectContext = projectContext;
    }
    session.sequence += 1;
    final snapshot = session.snapshot();
    _emitAiEvent(
      GDevelopAiEvent.sessionUpdated(
        gameId: session.gameId,
        editorSessionId: session.id,
        sequence: session.sequence,
        state: GDevelopAiSessionEventState.updated,
      ),
    );
    return snapshot;
  }

  GDevelopAiTurn createTurn(String editorSessionId, {String? clientMessageId}) {
    final normalizedMessageId = clientMessageId == null
        ? null
        : _validateClientId(clientMessageId, 'clientMessageId');
    final session = _requireSession(editorSessionId);
    if (normalizedMessageId != null) {
      for (final turn in session.turns.values) {
        if (turn.clientMessageId == normalizedMessageId) return turn;
      }
    }
    session.sequence += 1;
    final turn = GDevelopAiTurn(
      id: 'turn-${_randomHex(12)}',
      editorSessionId: session.id,
      sequence: session.sequence,
      createdAt: clock().toUtc(),
      clientMessageId: normalizedMessageId,
    );
    session.turns[turn.id] = turn;
    _emitAiEvent(
      GDevelopAiEvent.turnCreated(
        gameId: session.gameId,
        editorSessionId: session.id,
        sequence: turn.sequence,
        turnId: turn.id,
      ),
    );
    return turn;
  }

  List<GDevelopAiCall> cancelTurn(String editorSessionId, String turnId) {
    final normalizedTurnId = _validateClientId(turnId, 'turnId');
    final session = _requireSession(editorSessionId);
    if (!session.turns.containsKey(normalizedTurnId)) {
      throw const GDevelopAiCallConflict('turn_not_found', 'AI turn 不存在');
    }
    final activeCalls = session.calls.values
        .where(
          (item) => item.turnId == normalizedTurnId && !item.state.terminal,
        )
        .toList(growable: false);
    if (activeCalls.any((call) => _isRunningProjectWriter(session, call))) {
      throw const GDevelopAiCallConflict(
        'write_execution_non_cancellable',
        '已开始执行的 GDevelop 写工具不能取消',
      );
    }
    final cancelled = <GDevelopAiCall>[];
    for (final call in activeCalls) {
      cancelled.add(
        _transition(
          session,
          call,
          GDevelopAiCallState.cancelled,
          errorCode: 'turn_cancelled',
          errorMessage: 'GDevelop AI turn 已取消',
        ),
      );
    }
    return List.unmodifiable(cancelled);
  }

  GDevelopAiCall enqueueCall({
    required String editorSessionId,
    required String turnId,
    required String callId,
    required String idempotencyKey,
    required String toolName,
    required Map<String, Object?> arguments,
    Map<String, Object?>? input,
    bool allowAgentOnlyTools = false,
  }) {
    final normalizedTurnId = _validateClientId(turnId, 'turnId');
    final normalizedCallId = _validateClientId(callId, 'callId');
    final normalizedIdempotency = _validateClientId(
      idempotencyKey,
      'idempotencyKey',
    );
    final session = _requireSession(editorSessionId);
    if (!session.turns.containsKey(normalizedTurnId)) {
      throw const GDevelopAiCallConflict('turn_not_found', 'AI turn 不存在');
    }
    final validatedArguments = session.toolRegistry.validateCall(
      toolName,
      arguments,
      allowAgentOnlyTools: allowAgentOnlyTools,
    );
    final definition = session.toolRegistry.definition(toolName);
    final expectsEventPayload =
        definition.executionKind == GDevelopAiToolExecutionKind.eventPayload;
    final rawEventPayload = input?['eventPayload'];
    if (expectsEventPayload &&
        (input == null ||
            input.length != 1 ||
            !input.containsKey('eventPayload') ||
            rawEventPayload is! Map)) {
      throw const FormatException('事件工具 input 必须精确为 {eventPayload: <完整对象>}');
    }
    if (!expectsEventPayload && input != null) {
      throw const FormatException('非事件工具不允许提供 input');
    }
    final immutableInput = input == null ? null : _immutableJsonMap(input);
    final fingerprint = jsonEncode({
      'turnId': normalizedTurnId,
      'callId': normalizedCallId,
      'toolName': toolName,
      'arguments': validatedArguments,
      'input': ?immutableInput,
    });
    final existingId = session.idempotencyCallIds[normalizedIdempotency];
    if (existingId != null) {
      final existing = session.calls[existingId]!;
      if (existing.requestFingerprint != fingerprint) {
        throw const GDevelopAiCallConflict(
          'idempotency_conflict',
          '相同 idempotencyKey 对应不同调用',
        );
      }
      return existing.snapshot();
    }
    if (session.calls.containsKey(normalizedCallId)) {
      throw const GDevelopAiCallConflict('call_id_conflict', 'callId 已被使用');
    }
    session.sequence += 1;
    final now = clock().toUtc();
    final call = _MutableGDevelopAiCall(
      id: normalizedCallId,
      editorSessionId: editorSessionId,
      turnId: normalizedTurnId,
      toolName: toolName,
      arguments: validatedArguments,
      idempotencyKey: normalizedIdempotency,
      requestFingerprint: fingerprint,
      state: definition.approvalRequired
          ? GDevelopAiCallState.awaitingApproval
          : GDevelopAiCallState.queued,
      sequence: session.sequence,
      createdAt: now,
    );
    call.input = immutableInput;
    session.calls[call.id] = call;
    session.idempotencyCallIds[normalizedIdempotency] = call.id;
    final snapshot = call.snapshot();
    _emitCallUpdate(session, snapshot);
    return snapshot;
  }

  GDevelopAiCall approvalDecision({
    required String editorSessionId,
    required String callId,
    required bool approved,
    String rejectionCode = 'approval_rejected',
    String rejectionMessage = '用户拒绝了 GDevelop AI 调用',
  }) {
    final pair = _requireCall(editorSessionId, callId);
    final call = pair.call;
    if (call.state != GDevelopAiCallState.awaitingApproval) {
      if (call.state.terminal) return call.snapshot();
      throw const GDevelopAiCallConflict(
        'approval_state_conflict',
        '调用当前不等待审批',
      );
    }
    return _transition(
      pair.session,
      call,
      approved ? GDevelopAiCallState.queued : GDevelopAiCallState.cancelled,
      errorCode: approved ? null : rejectionCode,
      errorMessage: approved ? null : rejectionMessage,
    );
  }

  GDevelopAiCall? leaseNext(String editorSessionId) {
    final session = _requireSession(editorSessionId);
    final queued =
        session.calls.values
            .where((call) => call.state == GDevelopAiCallState.queued)
            .toList(growable: false)
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    if (queued.isEmpty) return null;
    _MutableGDevelopAiCall? call;
    for (final candidate in queued) {
      final modifiesProject = session.toolRegistry
          .definition(candidate.toolName)
          .modifiesProject;
      if (!modifiesProject || _writerLeases[session.gameId] == null) {
        call = candidate;
        break;
      }
    }
    if (call == null) return null;
    final result = _transition(session, call, GDevelopAiCallState.running);
    if (session.toolRegistry.definition(call.toolName).modifiesProject) {
      _acquireWriterLease(session, call);
    }
    _armTimeout(session, call);
    return result;
  }

  GDevelopAiCall finishCall({
    required String editorSessionId,
    required String callId,
    required bool success,
    required Map<String, Object?> output,
    String? errorCode,
    String? errorMessage,
  }) {
    final pair = _requireCall(editorSessionId, callId);
    if (pair.call.state != GDevelopAiCallState.running) {
      if (pair.call.state.terminal) return pair.call.snapshot();
      throw const GDevelopAiCallConflict(
        'execution_state_conflict',
        '调用当前不在运行中',
      );
    }
    final validatedOutput = _validatedClientExecutionOutput(output);
    pair.call.output = validatedOutput;
    return _transition(
      pair.session,
      pair.call,
      success ? GDevelopAiCallState.finished : GDevelopAiCallState.failed,
      errorCode: errorCode,
      errorMessage: errorMessage,
    );
  }

  GDevelopAiCall cancelCall(String editorSessionId, String callId) {
    final pair = _requireCall(editorSessionId, callId);
    if (pair.call.state.terminal) return pair.call.snapshot();
    if (_isRunningProjectWriter(pair.session, pair.call)) {
      throw const GDevelopAiCallConflict(
        'write_execution_non_cancellable',
        '已开始执行的 GDevelop 写工具不能取消',
      );
    }
    return _transition(
      pair.session,
      pair.call,
      GDevelopAiCallState.cancelled,
      errorCode: 'cancelled',
      errorMessage: 'GDevelop AI 调用已取消',
    );
  }

  List<GDevelopAiCall> calls(String editorSessionId, {int afterSequence = 0}) {
    final session = _requireSession(editorSessionId);
    if (afterSequence < 0) throw const FormatException('afterSequence 无效');
    final result =
        session.calls.values
            .where((call) => call.sequence > afterSequence)
            .map((call) => call.snapshot())
            .toList(growable: false)
          ..sort((left, right) => left.sequence.compareTo(right.sequence));
    return List.unmodifiable(result);
  }

  bool close(
    String editorSessionId, {
    bool force = false,
    String reason = 'session_closed',
  }) => closeWithSnapshot(editorSessionId, force: force, reason: reason).closed;

  ({bool closed, GDevelopAiEditorSession? snapshot}) closeWithSnapshot(
    String editorSessionId, {
    bool force = false,
    String reason = 'session_closed',
  }) {
    final normalizedSessionId = _validateClientId(
      editorSessionId,
      'editorSessionId',
    );
    final session = _sessions[normalizedSessionId];
    if (session == null) return (closed: true, snapshot: null);
    for (final call in session.calls.values) {
      if (!call.state.terminal) {
        _transition(
          session,
          call,
          GDevelopAiCallState.cancelled,
          errorCode: 'session_closed',
          errorMessage: 'GDevelop AI 编辑器会话已关闭',
        );
      }
    }
    session
      ..sequence += 1
      ..closed = true;
    _emitAiEvent(
      GDevelopAiEvent.sessionUpdated(
        gameId: session.gameId,
        editorSessionId: session.id,
        sequence: session.sequence,
        state: GDevelopAiSessionEventState.closed,
      ),
    );
    if (!_sessionClosures.isClosed) {
      _sessionClosures.add((
        gameId: session.gameId,
        editorSessionId: session.id,
        reason: reason,
      ));
    }
    final closedSnapshot = session.snapshot();
    _sessions.remove(normalizedSessionId);
    _stagedResources.remove(normalizedSessionId);
    _sessionTimers.remove(normalizedSessionId)?.cancel();
    _claimedApprovalCalls.removeWhere(
      (key) => key.startsWith('$normalizedSessionId\u0000'),
    );
    return (closed: true, snapshot: closedSnapshot);
  }

  int closeProject(String gameId) {
    _validateGameId(gameId);
    final ids = _sessions.values
        .where((session) => session.gameId == gameId)
        .map((session) => session.id)
        .toList(growable: false);
    for (final id in ids) {
      close(id, force: true, reason: 'project_closed');
    }
    return ids.length;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final id in _sessions.keys.toList(growable: false)) {
      close(id, force: true, reason: 'service_disposed');
    }
    _writerLeases.clear();
    _stagedResources.clear();
    unawaited(_callUpdates.close());
    unawaited(_aiEvents.close());
    unawaited(_sessionClosures.close());
  }

  GDevelopAiCall _transition(
    _MutableGDevelopAiSession session,
    _MutableGDevelopAiCall call,
    GDevelopAiCallState state, {
    String? errorCode,
    String? errorMessage,
  }) {
    call.timeoutTimer?.cancel();
    call.timeoutTimer = null;
    session.sequence += 1;
    call
      ..state = state
      ..sequence = session.sequence
      ..updatedAt = clock().toUtc()
      ..errorCode = errorCode
      ..errorMessage = errorMessage;
    if (state == GDevelopAiCallState.cancelled ||
        state == GDevelopAiCallState.timedOut) {
      call.cancellation.cancel(errorCode ?? state.wireName);
    }
    if (state.terminal) {
      call.input = null;
      _claimedApprovalCalls.remove('${session.id}\u0000${call.id}');
      _releaseWriterLease(session.gameId, session.id, call.id);
    }
    final snapshot = call.snapshot();
    _emitCallUpdate(session, snapshot);
    return snapshot;
  }

  void _emitCallUpdate(_MutableGDevelopAiSession session, GDevelopAiCall call) {
    if (!_callUpdates.isClosed) {
      _callUpdates.add((gameId: session.gameId, call: call));
    }
    _emitAiEvent(
      GDevelopAiEvent.callUpdated(
        gameId: session.gameId,
        editorSessionId: call.editorSessionId,
        sequence: call.sequence,
        turnId: call.turnId,
        callId: call.id,
        state: call.state.wireName,
      ),
    );
  }

  void _emitAiEvent(GDevelopAiEvent event) {
    if (_aiEvents.isClosed) return;
    try {
      _aiEvents.add(event);
    } on Object {
      // The event channel is only a wake-up hint. Listener failures cannot
      // alter an already-applied session/call transition.
    }
  }

  void _acquireWriterLease(
    _MutableGDevelopAiSession session,
    _MutableGDevelopAiCall call,
  ) {
    if (_writerLeases.containsKey(session.gameId)) {
      throw const GDevelopAiCallConflict(
        'writer_lease_conflict',
        '当前工程已有活动 writer lease',
      );
    }
    final lease = _MutableGDevelopAiWriterLease(
      gameId: session.gameId,
      ownerEditorSessionId: session.id,
      callId: call.id,
    );
    _writerLeases[session.gameId] = lease;
  }

  bool _isRunningProjectWriter(
    _MutableGDevelopAiSession session,
    _MutableGDevelopAiCall call,
  ) =>
      call.state == GDevelopAiCallState.running &&
      session.toolRegistry.definition(call.toolName).modifiesProject;

  void _releaseWriterLease(
    String gameId,
    String editorSessionId,
    String callId,
  ) {
    final lease = _writerLeases[gameId];
    if (lease == null ||
        lease.ownerEditorSessionId != editorSessionId ||
        lease.callId != callId) {
      return;
    }
    _writerLeases.remove(gameId);
  }

  void _expireSession(String editorSessionId) {
    final session = _sessions[editorSessionId];
    if (session == null) return;
    final expiresAt = session.expiresAt;
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(clock().toUtc());
    if (remaining > Duration.zero) {
      _sessionTimers[editorSessionId] = Timer(
        remaining,
        () => _expireSession(editorSessionId),
      );
      return;
    }
    if (close(editorSessionId, reason: 'expired')) return;
    _sessionTimers[editorSessionId] = Timer(
      const Duration(seconds: 1),
      () => _expireSession(editorSessionId),
    );
  }

  void _armTimeout(
    _MutableGDevelopAiSession session,
    _MutableGDevelopAiCall call,
  ) {
    final definition = session.toolRegistry.definition(call.toolName);
    if (definition.modifiesProject) return;
    final duration = definition.timeout;
    call.timeoutTimer?.cancel();
    call.timeoutTimer = Timer(duration, () {
      if (call.state.terminal || !_sessions.containsKey(session.id)) return;
      _transition(
        session,
        call,
        GDevelopAiCallState.timedOut,
        errorCode: 'tool_timeout',
        errorMessage: 'GDevelop AI tool execution timed out',
      );
    });
  }

  ({_MutableGDevelopAiSession session, _MutableGDevelopAiCall call})
  _requireCall(String editorSessionId, String callId) {
    final normalizedCallId = _validateClientId(callId, 'callId');
    final session = _requireSession(editorSessionId);
    final call = session.calls[normalizedCallId];
    if (call == null) {
      throw const GDevelopAiCallConflict('call_not_found', 'AI call 不存在');
    }
    return (session: session, call: call);
  }

  _MutableGDevelopAiSession _requireSession(String editorSessionId) {
    _ensureActive();
    final normalizedSessionId = _validateClientId(
      editorSessionId,
      'editorSessionId',
    );
    final session = _sessions[normalizedSessionId];
    if (session == null || session.closed) {
      throw const GDevelopAiSessionNotFound();
    }
    final expiresAt = session.expiresAt;
    if (expiresAt != null && !clock().toUtc().isBefore(expiresAt)) {
      close(normalizedSessionId);
      throw const GDevelopAiSessionNotFound();
    }
    return session;
  }

  void _ensureActive() {
    if (_disposed) throw StateError('GDevelop AI session service 已关闭');
  }

  void _validateGameId(String value) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(value)) {
      throw const FormatException('GDevelop gameId 无效');
    }
  }

  void _validateLocale(String value) {
    if (!RegExp(r'^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$').hasMatch(value)) {
      throw const FormatException('GDevelop AI locale 无效');
    }
  }

  void _validateHash(String value) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
      throw const FormatException('GDevelop contentHash 无效');
    }
  }

  String _validateClientId(String value, String field) {
    final match = RegExp(r'^[A-Za-z0-9._-]+$').firstMatch(value);
    if (value.length > 128 || match == null || match.end != value.length) {
      throw FormatException('GDevelop AI $field 无效');
    }
    return value;
  }

  String _randomHex(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
}

Map<String, Object?> _validatedClientExecutionOutput(
  Map<String, Object?> output,
) => _immutableJsonMap(output);

Map<String, Object?> _immutableJsonMap(Map<Object?, Object?> input) {
  final result = <String, Object?>{};
  for (final entry in input.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const GDevelopAiExecutionOutputValidationException(
        'gdevelop_ai_execution_output_invalid',
        'GDevelop AI execution output 只能包含字符串字段名',
      );
    }
    result[key] = _immutableJsonValue(entry.value);
  }
  return Map.unmodifiable(result);
}

Object? _immutableJsonValue(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is Map) {
    return _immutableJsonMap(value);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableJsonValue));
  }
  throw const GDevelopAiExecutionOutputValidationException(
    'gdevelop_ai_execution_output_invalid',
    'GDevelop AI execution output 必须是 JSON 值',
  );
}
