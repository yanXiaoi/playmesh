import 'dart:async';

import 'developer_event_hub.dart';

typedef DeveloperProjectLaunch =
    Future<void> Function(DeveloperProjectLaunchRequest request);
typedef DeveloperProjectRestart = Future<void> Function();
typedef DeveloperProjectStop = Future<void> Function();
typedef DeveloperWebViewJavaScriptExecutor =
    Future<Object?> Function(String source);
typedef DeveloperRunClock = DateTime Function();

DateTime _developerRunUtcNow() => DateTime.now().toUtc();

class DeveloperResourceSession {
  const DeveloperResourceSession({
    required this.projectId,
    required this.resourceBaseUri,
    required this.credential,
    required this.expiresAt,
  });

  final String projectId;
  final Uri resourceBaseUri;
  final String credential;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime value) => !value.toUtc().isBefore(expiresAt);
}

class DeveloperProjectLaunchRequest {
  const DeveloperProjectLaunchRequest({
    required this.projectId,
    required this.runId,
    this.resourceSession,
  });

  final String projectId;
  final String runId;
  final DeveloperResourceSession? resourceSession;
}

enum DeveloperRunPhase { idle, starting, running, stopped, error }

class DeveloperRunStatus {
  const DeveloperRunStatus({
    required this.projectId,
    required this.phase,
    required this.updatedAt,
    this.runId,
    this.joinCode,
    this.links = const [],
    this.message,
  });

  final String projectId;
  final DeveloperRunPhase phase;
  final DateTime updatedAt;
  final String? runId;
  final String? joinCode;
  final List<Uri> links;
  final String? message;

  Map<String, Object?> toJson() => {
    'projectId': projectId,
    'runId': runId,
    'phase': phase.name,
    'joinCode': joinCode,
    'links': links.map((link) => link.toString()).toList(),
    'message': message,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
  };
}

class _RegisteredRunHandler<T extends Function> {
  const _RegisteredRunHandler({required this.runId, required this.handler});

  // 测试和非路由嵌入方可能在控制器分配运行前注册；
  // 游戏路由始终显式绑定不可变的 App runId。
  final String? runId;
  final T handler;

  bool matches(String expectedRunId) => runId == null || runId == expectedRunId;
}

class _StopHandlerWaiter {
  _StopHandlerWaiter(this.runId);

  final String runId;
  final Completer<void> ready = Completer<void>();
}

class DeveloperRunController {
  DeveloperRunController({
    this.onLaunch,
    this.stopHandlerTimeout = const Duration(seconds: 10),
    DeveloperRunClock? clock,
  }) : clock = clock ?? _developerRunUtcNow;

  DeveloperProjectLaunch? onLaunch;
  final Duration stopHandlerTimeout;
  final DeveloperRunClock clock;
  final Map<String, DeveloperRunStatus> _statuses = {};
  final Map<String, _RegisteredRunHandler<DeveloperProjectRestart>>
  _restartHandlers = {};
  final Map<String, _RegisteredRunHandler<DeveloperProjectStop>> _stopHandlers =
      {};
  final Map<String, _RegisteredRunHandler<DeveloperWebViewJavaScriptExecutor>>
  _javaScriptExecutors = {};
  final Map<String, DeveloperResourceSession> _resourceSessions = {};
  final Map<String, Timer> _resourceSessionTimers = {};
  final Map<String, _StopHandlerWaiter> _stopHandlerWaiters = {};
  Future<void> _operationTail = Future<void>.value();
  var _runSequence = 0;

  DeveloperRunStatus? get activeStatus {
    final active =
        _statuses.values
            .where(
              (status) =>
                  status.phase == DeveloperRunPhase.starting ||
                  status.phase == DeveloperRunPhase.running,
            )
            .toList()
          ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return active.isEmpty ? null : active.first;
  }

  Future<DeveloperRunStatus> run(String projectId) async {
    return _serialize(() async {
      await _stopRunsBeforeLaunch();
      return _launch(projectId: projectId, startingMessage: '正在请求 App 启动游戏');
    });
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _operationTail.then((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<DeveloperRunStatus> runDevelopment(
    DeveloperResourceSession session,
  ) async {
    return _serialize(() async {
      if (session.isExpiredAt(clock())) {
        throw StateError('开发资源会话已经过期');
      }
      await _stopRunsBeforeLaunch();
      _setResourceSession(session);
      try {
        return await _launch(
          projectId: session.projectId,
          resourceSession: session,
          startingMessage: '正在请求 App 启动开发资源会话',
        );
      } on Object {
        _removeResourceSession(session.projectId, expectedSession: session);
        rethrow;
      }
    });
  }

  DeveloperResourceSession? resourceSession(String projectId) {
    final session = _resourceSessions[projectId];
    if (session == null) return null;
    if (!session.isExpiredAt(clock())) return session;
    unawaited(_expireResourceSession(session));
    return null;
  }

  Future<DeveloperRunStatus> stopDevelopment(String projectId) async {
    return _serialize(() => _stopDevelopment(projectId));
  }

  Future<void> stopAllDevelopment() async {
    await _serialize(() async {
      Object? firstError;
      StackTrace? firstStackTrace;
      final projectIds = _resourceSessions.keys.toList(growable: false);
      for (final projectId in projectIds) {
        try {
          await _stopDevelopment(projectId);
        } on Object catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }
    });
  }

  Future<DeveloperRunStatus> _launch({
    required String projectId,
    required String startingMessage,
    DeveloperResourceSession? resourceSession,
  }) async {
    final launch = onLaunch;
    if (launch == null) {
      throw StateError('当前 App 未连接开发者运行入口');
    }
    final runId = _nextRunId(projectId);
    _stopHandlerWaiters[projectId] = _StopHandlerWaiter(runId);
    _set(
      projectId,
      DeveloperRunPhase.starting,
      runId: runId,
      message: startingMessage,
    );
    try {
      await launch(
        DeveloperProjectLaunchRequest(
          projectId: projectId,
          runId: runId,
          resourceSession: resourceSession,
        ),
      );
      return status(projectId);
    } on Object catch (error) {
      _stopHandlerWaiters.remove(projectId);
      _set(
        projectId,
        DeveloperRunPhase.error,
        runId: runId,
        message: error.toString(),
      );
      rethrow;
    }
  }

  void Function() registerRestartHandler(
    String projectId,
    DeveloperProjectRestart handler, {
    String? expectedRunId,
  }) {
    final registration = _RegisteredRunHandler(
      runId: expectedRunId,
      handler: handler,
    );
    _restartHandlers[projectId] = registration;
    return () {
      if (identical(_restartHandlers[projectId], registration)) {
        _restartHandlers.remove(projectId);
      }
    };
  }

  Future<DeveloperRunStatus> restart(String projectId) async {
    return _serialize(() async {
      final previous = status(projectId);
      final registration = _restartHandlers[projectId];
      if (registration == null ||
          (previous.runId != null && !registration.matches(previous.runId!))) {
        throw StateError('当前项目没有正在运行的游戏实例');
      }
      final isDevelopmentRestart = _resourceSessions.containsKey(projectId);
      final runId = isDevelopmentRestart
          ? previous.runId ?? _nextRunId(projectId)
          : _nextRunId(projectId);
      _set(
        projectId,
        DeveloperRunPhase.starting,
        runId: runId,
        message: _resourceSessions.containsKey(projectId)
            ? '正在重启开发游戏页面并保留资源会话'
            : '正在刷新游戏内容',
      );
      try {
        await registration.handler();
        if (!isDevelopmentRestart && previous.runId != null) {
          _rebindHandlers(projectId, previous.runId!, runId);
        }
        _set(
          projectId,
          DeveloperRunPhase.running,
          runId: runId,
          joinCode: previous.joinCode,
          links: previous.links,
          message: _resourceSessions.containsKey(projectId)
              ? '开发游戏页面已重启，资源会话保持运行'
              : '游戏内容已刷新',
        );
        return status(projectId);
      } on Object catch (error) {
        _set(
          projectId,
          DeveloperRunPhase.error,
          runId: runId,
          message: error.toString(),
        );
        rethrow;
      }
    });
  }

  void Function() registerStopHandler(
    String projectId,
    DeveloperProjectStop handler, {
    String? expectedRunId,
  }) {
    final currentRunId = status(projectId).runId;
    final registration = _RegisteredRunHandler(
      runId: expectedRunId,
      handler: handler,
    );
    if (expectedRunId != null &&
        currentRunId != null &&
        expectedRunId != currentRunId) {
      // 被后续启动取代后才完成构建的路由必须自行销毁，不能覆盖当前路由的处理器。
      unawaited(handler());
      return () {};
    }
    _stopHandlers[projectId] = registration;
    final waiter = _stopHandlerWaiters[projectId];
    if (waiter != null &&
        (expectedRunId == null || waiter.runId == expectedRunId) &&
        !waiter.ready.isCompleted) {
      waiter.ready.complete();
    }
    return () {
      if (identical(_stopHandlers[projectId], registration)) {
        _stopHandlers.remove(projectId);
      }
    };
  }

  Future<DeveloperRunStatus> stop(String projectId) async {
    return _serialize(() => _stopRun(projectId));
  }

  Future<DeveloperRunStatus> _stopRun(String projectId) async {
    final current = status(projectId);
    final runId = current.runId;
    if (runId == null ||
        ((current.phase == DeveloperRunPhase.idle ||
                current.phase == DeveloperRunPhase.stopped) &&
            !_resourceSessions.containsKey(projectId))) {
      throw StateError('当前项目没有正在运行的游戏实例');
    }
    final stop = await _stopHandler(projectId, runId);
    try {
      await stop();
      reportStopped(projectId, expectedRunId: runId);
      return status(projectId);
    } on Object catch (error) {
      _set(
        projectId,
        DeveloperRunPhase.error,
        runId: runId,
        message: error.toString(),
      );
      rethrow;
    }
  }

  Future<DeveloperRunStatus> _stopDevelopment(String projectId) async {
    final session = _resourceSessions[projectId];
    if (session == null) {
      throw StateError('当前项目没有活动的开发资源会话');
    }
    final stopped = await _stopRun(projectId);
    _removeResourceSession(projectId, expectedSession: session);
    return stopped;
  }

  Future<void> _stopRunsBeforeLaunch() async {
    final candidates =
        _statuses.values
            .where(
              (candidate) =>
                  candidate.runId != null &&
                  (candidate.phase == DeveloperRunPhase.starting ||
                      candidate.phase == DeveloperRunPhase.running ||
                      _resourceSessions.containsKey(candidate.projectId) ||
                      _stopHandlers.containsKey(candidate.projectId)),
            )
            .toList(growable: false)
          ..sort((left, right) => left.updatedAt.compareTo(right.updatedAt));
    for (final candidate in candidates) {
      await _stopRun(candidate.projectId);
    }
  }

  Future<DeveloperProjectStop> _stopHandler(
    String projectId,
    String runId,
  ) async {
    var registration = _stopHandlers[projectId];
    if (registration != null && registration.matches(runId)) {
      return registration.handler;
    }
    final waiter = _stopHandlerWaiters.putIfAbsent(
      projectId,
      () => _StopHandlerWaiter(runId),
    );
    if (waiter.runId != runId) {
      throw StateError('当前项目运行实例已经变更');
    }
    try {
      await waiter.ready.future.timeout(stopHandlerTimeout);
    } on TimeoutException {
      throw StateError('等待当前游戏页面注册停止处理器超时');
    }
    registration = _stopHandlers[projectId];
    if (registration == null || !registration.matches(runId)) {
      throw StateError('当前游戏页面未提供可用的停止处理器');
    }
    return registration.handler;
  }

  void _setResourceSession(DeveloperResourceSession session) {
    _removeResourceSession(session.projectId);
    _resourceSessions[session.projectId] = session;
    final delay = session.expiresAt.difference(clock());
    _resourceSessionTimers[session.projectId] = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => unawaited(_expireResourceSession(session)),
    );
  }

  void _removeResourceSession(
    String projectId, {
    DeveloperResourceSession? expectedSession,
  }) {
    final current = _resourceSessions[projectId];
    if (expectedSession != null && !identical(current, expectedSession)) return;
    _resourceSessions.remove(projectId);
    _resourceSessionTimers.remove(projectId)?.cancel();
  }

  Future<void> _expireResourceSession(DeveloperResourceSession session) async {
    try {
      await _serialize(() async {
        if (!identical(_resourceSessions[session.projectId], session)) return;
        try {
          await _stopRun(session.projectId);
          _removeResourceSession(session.projectId, expectedSession: session);
        } on Object catch (error) {
          reportError(
            session.projectId,
            '开发资源会话到期后停止失败: $error',
            expectedRunId: status(session.projectId).runId,
          );
        }
      });
    } on Object {
      // 到期清理是尽力执行的异步操作；停止失败时保留会话，供显式 DELETE 重试。
    }
  }

  void _rebindHandlers(
    String projectId,
    String previousRunId,
    String nextRunId,
  ) {
    final restart = _restartHandlers[projectId];
    if (restart != null && restart.runId == previousRunId) {
      _restartHandlers[projectId] = _RegisteredRunHandler(
        runId: nextRunId,
        handler: restart.handler,
      );
    }
    final stop = _stopHandlers[projectId];
    var hasStopHandler = false;
    if (stop != null && stop.runId == previousRunId) {
      _stopHandlers[projectId] = _RegisteredRunHandler(
        runId: nextRunId,
        handler: stop.handler,
      );
      hasStopHandler = true;
    }
    final executor = _javaScriptExecutors[projectId];
    if (executor != null && executor.runId == previousRunId) {
      _javaScriptExecutors[projectId] = _RegisteredRunHandler(
        runId: nextRunId,
        handler: executor.handler,
      );
    }
    final waiter = _StopHandlerWaiter(nextRunId);
    if (hasStopHandler) waiter.ready.complete();
    _stopHandlerWaiters[projectId] = waiter;
  }

  void Function() registerJavaScriptExecutor(
    String projectId,
    DeveloperWebViewJavaScriptExecutor executor, {
    String? expectedRunId,
  }) {
    final registration = _RegisteredRunHandler(
      runId: expectedRunId,
      handler: executor,
    );
    if (expectedRunId != null &&
        status(projectId).runId != null &&
        status(projectId).runId != expectedRunId) {
      return () {};
    }
    _javaScriptExecutors[projectId] = registration;
    return () {
      if (identical(_javaScriptExecutors[projectId], registration)) {
        _javaScriptExecutors.remove(projectId);
      }
    };
  }

  Future<Object?> executeJavaScript(String projectId, String source) async {
    final active = activeStatus;
    if (active == null ||
        active.phase != DeveloperRunPhase.running ||
        active.projectId != projectId) {
      throw StateError('当前运行游戏的 WebView 不属于项目 $projectId');
    }
    final registration = _javaScriptExecutors[projectId];
    if (registration == null ||
        active.runId == null ||
        !registration.matches(active.runId!)) {
      throw StateError('当前项目没有可执行 JavaScript 的运行中游戏 WebView');
    }
    return await registration.handler(source);
  }

  DeveloperRunStatus status(String projectId) =>
      _statuses[projectId] ??
      DeveloperRunStatus(
        projectId: projectId,
        phase: DeveloperRunPhase.idle,
        updatedAt: clock(),
      );

  void reportRunning({
    required String projectId,
    String? expectedRunId,
    String? joinCode,
    List<Uri> links = const [],
  }) {
    final current = status(projectId);
    if (expectedRunId != null && current.runId != expectedRunId) return;
    _set(
      projectId,
      DeveloperRunPhase.running,
      runId: expectedRunId ?? current.runId ?? _nextRunId(projectId),
      joinCode: joinCode,
      links: links,
      message: links.isEmpty ? '游戏已在 App 中运行' : '游戏已运行，可使用下方地址加入',
    );
  }

  void reportError(String projectId, Object error, {String? expectedRunId}) {
    final current = status(projectId);
    if (expectedRunId != null && current.runId != expectedRunId) return;
    _set(
      projectId,
      DeveloperRunPhase.error,
      runId: expectedRunId ?? current.runId,
      message: error.toString(),
    );
  }

  void reportStopped(String projectId, {String? expectedRunId}) {
    final current = status(projectId);
    if (expectedRunId != null && current.runId != expectedRunId) return;
    final stoppedRunId = expectedRunId ?? current.runId;
    _removeResourceSession(projectId);
    final restart = _restartHandlers[projectId];
    if (stoppedRunId == null ||
        restart == null ||
        restart.matches(stoppedRunId)) {
      _restartHandlers.remove(projectId);
    }
    final stop = _stopHandlers[projectId];
    if (stoppedRunId == null || stop == null || stop.matches(stoppedRunId)) {
      _stopHandlers.remove(projectId);
    }
    final executor = _javaScriptExecutors[projectId];
    if (stoppedRunId == null ||
        executor == null ||
        executor.matches(stoppedRunId)) {
      _javaScriptExecutors.remove(projectId);
    }
    final waiter = _stopHandlerWaiters[projectId];
    if (stoppedRunId == null ||
        waiter == null ||
        waiter.runId == stoppedRunId) {
      _stopHandlerWaiters.remove(projectId);
    }
    _set(
      projectId,
      DeveloperRunPhase.stopped,
      runId: stoppedRunId,
      message: '游戏已停止',
    );
  }

  void _set(
    String projectId,
    DeveloperRunPhase phase, {
    String? runId,
    String? joinCode,
    List<Uri> links = const [],
    String? message,
  }) {
    final status = DeveloperRunStatus(
      projectId: projectId,
      phase: phase,
      updatedAt: clock(),
      runId: runId,
      joinCode: joinCode,
      links: List.unmodifiable(links),
      message: message,
    );
    _statuses[projectId] = status;
    developerEventHub.emit({'type': 'run.status', ...status.toJson()});
  }

  String _nextRunId(String projectId) {
    _runSequence += 1;
    return 'run-${clock().microsecondsSinceEpoch}-'
        '$_runSequence-$projectId';
  }
}
