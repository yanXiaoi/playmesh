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
    expect(status.message, '游戏已重新启动');

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
}
