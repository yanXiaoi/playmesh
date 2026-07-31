import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';

void main() {
  test('重启已注册的开发游戏并保留分享信息', () async {
    var restarted = 0;
    final controller = DeveloperRunController();
    controller.reportRunning(
      projectId: 'com.example.game',
      joinCode: 'ABC123',
      links: [Uri.parse('http://192.168.1.2/join/ABC123')],
    );
    final unregister = controller.registerRestartHandler(
      'com.example.game',
      () async => restarted += 1,
    );

    final status = await controller.restart('com.example.game');

    expect(restarted, 1);
    expect(status.phase, DeveloperRunPhase.running);
    expect(status.joinCode, 'ABC123');
    expect(status.links, hasLength(1));
    expect(status.message, '游戏内容已刷新');

    unregister();
    await expectLater(controller.restart('com.example.game'), throwsStateError);
  });

  test('重启失败会进入错误状态并继续抛出异常', () async {
    final controller = DeveloperRunController();
    controller.registerRestartHandler(
      'com.example.failed',
      () async => throw StateError('reset failed'),
    );

    await expectLater(
      controller.restart('com.example.failed'),
      throwsStateError,
    );
    expect(
      controller.status('com.example.failed').phase,
      DeveloperRunPhase.error,
    );
  });

  test('停止已注册的开发游戏并进入 stopped 状态', () async {
    var stopped = 0;
    final controller = DeveloperRunController();
    controller.reportRunning(projectId: 'com.example.game');
    final unregister = controller.registerStopHandler(
      'com.example.game',
      () async => stopped += 1,
    );

    final status = await controller.stop('com.example.game');

    expect(stopped, 1);
    expect(status.phase, DeveloperRunPhase.stopped);
    expect(status.message, '游戏已停止');

    unregister();
    await expectLater(controller.stop('com.example.game'), throwsStateError);
  });

  test('旧页面退出不能把同项目的新 run 标记为 stopped', () async {
    final controller = DeveloperRunController();
    controller.reportRunning(projectId: 'com.example.game');
    final oldRunId = controller.status('com.example.game').runId;
    controller.registerRestartHandler('com.example.game', () async {});

    await controller.restart('com.example.game');
    final newRunId = controller.status('com.example.game').runId;

    controller.reportStopped('com.example.game', expectedRunId: oldRunId);

    expect(newRunId, isNot(oldRunId));
    expect(controller.status('com.example.game').runId, newRunId);
    expect(
      controller.status('com.example.game').phase,
      DeveloperRunPhase.running,
    );
  });

  test('向当前游戏 WebView 执行 JavaScript 并返回结果', () async {
    final controller = DeveloperRunController();
    final sources = <String>[];
    controller.reportRunning(projectId: 'com.example.game');
    final unregister = controller.registerJavaScriptExecutor(
      'com.example.game',
      (source) async {
        sources.add(source);
        return {'title': 'Playmesh', 'count': 2};
      },
    );

    final result = await controller.executeJavaScript(
      'com.example.game',
      '({title: document.title, count: 1 + 1})',
    );

    expect(sources, ['({title: document.title, count: 1 + 1})']);
    expect(result, {'title': 'Playmesh', 'count': 2});

    await expectLater(
      controller.executeJavaScript('com.example.other', 'document.title'),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('不属于项目 com.example.other'),
        ),
      ),
    );
    expect(sources, ['({title: document.title, count: 1 + 1})']);

    unregister();
    await expectLater(
      controller.executeJavaScript('com.example.game', 'document.title'),
      throwsStateError,
    );
  });

  test('开发资源会话只在内存绑定并随停止运行撤销', () async {
    DeveloperProjectLaunchRequest? launched;
    var stopped = 0;
    final controller = DeveloperRunController(
      onLaunch: (request) async => launched = request,
    );
    controller.registerStopHandler(
      'com.example.development',
      () async => stopped += 1,
    );
    final session = DeveloperResourceSession(
      projectId: 'com.example.development',
      resourceBaseUri: Uri.parse('http://192.168.1.8:4173/'),
      credential: List<String>.filled(40, 'a').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );

    final started = await controller.runDevelopment(session);

    expect(started.phase, DeveloperRunPhase.starting);
    expect(launched?.projectId, session.projectId);
    expect(launched?.resourceSession, same(session));
    expect(controller.resourceSession(session.projectId), same(session));

    final stoppedStatus = await controller.stopDevelopment(session.projectId);
    expect(stopped, 1);
    expect(stoppedStatus.phase, DeveloperRunPhase.stopped);
    expect(controller.resourceSession(session.projectId), isNull);
  });

  test('开发资源启动失败时不残留会话凭据', () async {
    final controller = DeveloperRunController(
      onLaunch: (_) async => throw StateError('launch failed'),
    );
    final session = DeveloperResourceSession(
      projectId: 'com.example.failed-development',
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'b').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );

    await expectLater(controller.runDevelopment(session), throwsStateError);

    expect(controller.resourceSession(session.projectId), isNull);
    expect(controller.status(session.projectId).phase, DeveloperRunPhase.error);
  });

  test('重复开发启动会先完整停止旧运行再绑定新凭据', () async {
    late DeveloperRunController controller;
    final launched = <DeveloperProjectLaunchRequest>[];
    final stoppedRunIds = <String>[];
    controller = DeveloperRunController(
      onLaunch: (request) async {
        launched.add(request);
        controller.registerStopHandler(
          request.projectId,
          () async => stoppedRunIds.add(request.runId),
          expectedRunId: request.runId,
        );
      },
    );
    final first = DeveloperResourceSession(
      projectId: 'com.example.repeated-development',
      resourceBaseUri: Uri.parse('http://192.168.1.8:4173/'),
      credential: List<String>.filled(40, 'c').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
    final second = DeveloperResourceSession(
      projectId: first.projectId,
      resourceBaseUri: Uri.parse('http://192.168.1.8:5173/'),
      credential: List<String>.filled(40, 'd').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );

    final firstStatus = await controller.runDevelopment(first);
    controller.reportRunning(
      projectId: first.projectId,
      expectedRunId: firstStatus.runId,
    );
    final secondStatus = await controller.runDevelopment(second);

    expect(launched, hasLength(2));
    expect(stoppedRunIds, [firstStatus.runId]);
    expect(secondStatus.runId, isNot(firstStatus.runId));
    expect(controller.resourceSession(first.projectId), same(second));
  });

  test('启动后立即停止会等待对应页面注册处理器', () async {
    DeveloperProjectLaunchRequest? request;
    final controller = DeveloperRunController(
      onLaunch: (value) async => request = value,
      stopHandlerTimeout: const Duration(seconds: 1),
    );
    final session = DeveloperResourceSession(
      projectId: 'com.example.immediate-stop',
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'e').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
    await controller.runDevelopment(session);

    final stopping = controller.stopDevelopment(session.projectId);
    await Future<void>.delayed(Duration.zero);
    var stopped = 0;
    controller.registerStopHandler(
      session.projectId,
      () async => stopped += 1,
      expectedRunId: request!.runId,
    );
    final status = await stopping;

    expect(stopped, 1);
    expect(status.phase, DeveloperRunPhase.stopped);
    expect(controller.resourceSession(session.projectId), isNull);
  });

  test('停止失败保留开发会话并允许使用同一处理器重试', () async {
    late DeveloperRunController controller;
    var attempts = 0;
    controller = DeveloperRunController(
      onLaunch: (request) async {
        controller.registerStopHandler(request.projectId, () async {
          attempts += 1;
          if (attempts == 1) throw StateError('temporary stop failure');
        }, expectedRunId: request.runId);
      },
    );
    final session = DeveloperResourceSession(
      projectId: 'com.example.retry-stop',
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'f').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
    await controller.runDevelopment(session);

    await expectLater(
      controller.stopDevelopment(session.projectId),
      throwsStateError,
    );
    expect(controller.resourceSession(session.projectId), same(session));

    final stopped = await controller.stopDevelopment(session.projectId);
    expect(attempts, 2);
    expect(stopped.phase, DeveloperRunPhase.stopped);
    expect(controller.resourceSession(session.projectId), isNull);
  });

  test('开发会话重启会复用当前运行标识并保留开发资源源', () async {
    late DeveloperRunController controller;
    final launched = <DeveloperProjectLaunchRequest>[];
    var restarted = 0;
    controller = DeveloperRunController(
      onLaunch: (request) async {
        launched.add(request);
        controller.registerRestartHandler(
          request.projectId,
          () async => restarted += 1,
          expectedRunId: request.runId,
        );
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
      },
    );
    final session = DeveloperResourceSession(
      projectId: 'com.example.formal-after-development',
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'g').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 10)),
    );
    final development = await controller.runDevelopment(session);
    controller.reportRunning(
      projectId: session.projectId,
      expectedRunId: development.runId,
    );

    final refreshed = await controller.restart(session.projectId);

    expect(launched, hasLength(1));
    expect(launched.first.resourceSession, same(session));
    expect(restarted, 1);
    expect(refreshed.runId, development.runId);
    expect(controller.resourceSession(session.projectId), same(session));
    expect(refreshed.message, contains('资源会话保持运行'));
  });

  test('开发会话到期会停止对应运行并从状态查询中撤销', () async {
    late DeveloperRunController controller;
    controller = DeveloperRunController(
      onLaunch: (request) async {
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
      },
    );
    final session = DeveloperResourceSession(
      projectId: 'com.example.expiring-development',
      resourceBaseUri: Uri.parse('http://127.0.0.1:4173/'),
      credential: List<String>.filled(40, 'h').join(),
      expiresAt: DateTime.now().toUtc().add(const Duration(milliseconds: 30)),
    );

    await controller.runDevelopment(session);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(controller.resourceSession(session.projectId), isNull);
    expect(
      controller.status(session.projectId).phase,
      DeveloperRunPhase.stopped,
    );
  });
}
