import 'dart:async';

import 'developer_event_hub.dart';

typedef DeveloperProjectLaunch = Future<void> Function(String projectId);
typedef DeveloperProjectRestart = Future<void> Function();
typedef DeveloperProjectStop = Future<void> Function();
typedef DeveloperWebViewJavaScriptExecutor =
    Future<Object?> Function(String source);

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

class DeveloperRunController {
  DeveloperRunController({this.onLaunch});

  DeveloperProjectLaunch? onLaunch;
  final Map<String, DeveloperRunStatus> _statuses = {};
  final Map<String, DeveloperProjectRestart> _restartHandlers = {};
  final Map<String, DeveloperProjectStop> _stopHandlers = {};
  final Map<String, DeveloperWebViewJavaScriptExecutor> _javaScriptExecutors =
      {};
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
    final launch = onLaunch;
    if (launch == null) {
      throw StateError('当前 App 未连接开发者运行入口');
    }
    _set(
      projectId,
      DeveloperRunPhase.starting,
      runId: _nextRunId(projectId),
      message: '正在请求 App 启动游戏',
    );
    try {
      await launch(projectId);
      return status(projectId);
    } on Object catch (error) {
      _set(
        projectId,
        DeveloperRunPhase.error,
        runId: status(projectId).runId,
        message: error.toString(),
      );
      rethrow;
    }
  }

  void Function() registerRestartHandler(
    String projectId,
    DeveloperProjectRestart handler,
  ) {
    _restartHandlers[projectId] = handler;
    return () {
      if (identical(_restartHandlers[projectId], handler)) {
        _restartHandlers.remove(projectId);
      }
    };
  }

  Future<DeveloperRunStatus> restart(String projectId) async {
    final restart = _restartHandlers[projectId];
    if (restart == null) throw StateError('当前项目没有正在运行的游戏实例');
    final previous = status(projectId);
    final runId = _nextRunId(projectId);
    _set(
      projectId,
      DeveloperRunPhase.starting,
      runId: runId,
      message: '正在刷新游戏内容',
    );
    try {
      await restart();
      _set(
        projectId,
        DeveloperRunPhase.running,
        runId: runId,
        joinCode: previous.joinCode,
        links: previous.links,
        message: '游戏内容已刷新',
      );
      return status(projectId);
    } on Object catch (error) {
      _set(
        projectId,
        DeveloperRunPhase.error,
        runId: status(projectId).runId,
        message: error.toString(),
      );
      rethrow;
    }
  }

  void Function() registerStopHandler(
    String projectId,
    DeveloperProjectStop handler,
  ) {
    _stopHandlers[projectId] = handler;
    return () {
      if (identical(_stopHandlers[projectId], handler)) {
        _stopHandlers.remove(projectId);
      }
    };
  }

  Future<DeveloperRunStatus> stop(String projectId) async {
    final stop = _stopHandlers[projectId];
    if (stop == null) throw StateError('当前项目没有正在运行的游戏实例');
    try {
      await stop();
      reportStopped(projectId);
      return status(projectId);
    } on Object catch (error) {
      _set(
        projectId,
        DeveloperRunPhase.error,
        runId: status(projectId).runId,
        message: error.toString(),
      );
      rethrow;
    }
  }

  void Function() registerJavaScriptExecutor(
    String projectId,
    DeveloperWebViewJavaScriptExecutor executor,
  ) {
    _javaScriptExecutors[projectId] = executor;
    return () {
      if (identical(_javaScriptExecutors[projectId], executor)) {
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
    final executor = _javaScriptExecutors[projectId];
    if (executor == null) {
      throw StateError('当前项目没有可执行 JavaScript 的运行中游戏 WebView');
    }
    return await executor(source);
  }

  DeveloperRunStatus status(String projectId) =>
      _statuses[projectId] ??
      DeveloperRunStatus(
        projectId: projectId,
        phase: DeveloperRunPhase.idle,
        updatedAt: DateTime.now().toUtc(),
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
    _set(
      projectId,
      DeveloperRunPhase.stopped,
      runId: expectedRunId ?? current.runId,
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
      updatedAt: DateTime.now().toUtc(),
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
    return 'run-${DateTime.now().toUtc().microsecondsSinceEpoch}-'
        '$_runSequence-$projectId';
  }
}
