import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_event_hub.dart';

void main() {
  test('未打开日志面板时仍缓存最近 500 条运行日志', () {
    final hub = DeveloperEventHub();

    for (var index = 0; index < 520; index += 1) {
      hub.emit({
        'type': 'runtime.log',
        'level': 'log',
        'message': 'line-$index',
      });
    }

    expect(hub.recentLogs, hasLength(DeveloperEventHub.maxRecentLogs));
    expect(hub.recentLogs.first['message'], 'line-20');
    expect(hub.recentLogs.last['message'], 'line-519');

    hub.clearRecentLogs();
    expect(hub.recentLogs, isEmpty);
  });

  test('本次运行日志带稳定事件 ID 和项目运行归属', () {
    final hub = DeveloperEventHub();
    hub.beginRuntime(projectId: 'com.example.game', runId: 'run-2');

    hub.emit({'type': 'runtime.log', 'message': 'ready'});
    hub.emit({'type': 'runtime.log', 'message': 'started'});

    expect(hub.recentLogs.first['eventId'], 'event-1');
    expect(hub.recentLogs.last['eventId'], 'event-2');
    expect(hub.recentLogs.last['projectId'], 'com.example.game');
    expect(hub.recentLogs.last['runId'], 'run-2');
  });
}
