import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_sdk/webview_sdk_navigation_queue.dart';

void main() {
  test('导航完成后严格先释放 App 再释放 Game', () async {
    final sent = <String>[];
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final generation = queue.beginNavigation();

    await queue.addGame('game-bootstrap');
    final appDelivery = queue.addApp('app-bootstrap', generation: generation);
    expect(sent, isEmpty);

    await Future.wait([appDelivery, queue.completeNavigation(generation)]);
    expect(sent, ['app-bootstrap', 'game-bootstrap']);
    expect(queue.appReady, isTrue);
    expect(queue.gameReady, isTrue);
  });

  test('旧页面异步 App 回包不会进入新页面', () async {
    final sent = <String>[];
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final oldGeneration = queue.beginNavigation();
    final newGeneration = queue.beginNavigation();

    await expectLater(
      queue.addApp('old-app-result', generation: oldGeneration),
      throwsStateError,
    );
    final newAppDelivery = queue.addApp(
      'new-app-result',
      generation: newGeneration,
    );
    await queue.addGame('new-game-result');
    await queue.completeNavigation(oldGeneration);
    expect(sent, isEmpty);

    await Future.wait([
      newAppDelivery,
      queue.completeNavigation(newGeneration),
    ]);
    expect(sent, ['new-app-result', 'new-game-result']);
  });

  test('发送失败保留当前文档消息，重试仍保持 App 在前', () async {
    final sent = <String>[];
    var failOnce = true;
    final queue = WebViewSdkNavigationQueue((script) async {
      if (failOnce) {
        failOnce = false;
        throw StateError('document is not ready');
      }
      sent.add(script);
    });
    final generation = queue.beginNavigation();
    final appDelivery = queue.addApp('app-bootstrap', generation: generation);
    await queue.addGame('game-bootstrap');

    await expectLater(queue.completeNavigation(generation), throwsStateError);
    expect(sent, isEmpty);
    expect(queue.gameReady, isFalse);

    await Future.wait([appDelivery, queue.completeNavigation(generation)]);
    expect(sent, ['app-bootstrap', 'game-bootstrap']);
  });

  test('导航切换时清空旧页面尚未发送的 App 与 Game 消息', () async {
    final sent = <String>[];
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final oldGeneration = queue.beginNavigation();
    final oldAppDelivery = queue.addApp('old-app', generation: oldGeneration);
    final oldAppDiscarded = expectLater(oldAppDelivery, throwsStateError);
    await queue.addGame('old-game');

    final newGeneration = queue.beginNavigation();
    await oldAppDiscarded;
    final newAppDelivery = queue.addApp('new-app', generation: newGeneration);
    await queue.addGame('new-game');
    await Future.wait([
      newAppDelivery,
      queue.completeNavigation(newGeneration),
    ]);

    expect(sent, ['new-app', 'new-game']);
  });

  test('恢复焦点副作用只在当前页面 Game 消息真正释放时执行', () async {
    final events = <String>[];
    final queue = WebViewSdkNavigationQueue(
      (script) async => events.add('send:$script'),
    );
    final generation = queue.beginNavigation();
    await queue.addGame(
      'restore-focus',
      beforeSend: () async => events.add('focus'),
    );

    expect(events, isEmpty);
    await queue.completeNavigation(generation);
    expect(events, ['focus', 'send:restore-focus']);
  });

  test('初始 loadUrl 前建代后，同次 loading 通知不清掉早到回包', () async {
    final sent = <String>[];
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final beforeLoadGeneration = queue.beginNavigation();
    final appDelivery = queue.addApp(
      'early-app-bootstrap-result',
      generation: beforeLoadGeneration,
    );

    final loadingEventGeneration = queue.notifyNavigationLoading();
    expect(loadingEventGeneration, beforeLoadGeneration);
    await Future.wait([
      appDelivery,
      queue.completeNavigation(loadingEventGeneration),
    ]);

    expect(sent, ['early-app-bootstrap-result']);
  });

  test('旧代恢复任务尚未开始投递时，新导航使 App 与 Game 全部失效', () async {
    final sent = <String>[];
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final oldGeneration = queue.beginNavigation();
    final oldAppDelivery = queue.addApp('old-app', generation: oldGeneration);
    final oldAppDiscarded = expectLater(oldAppDelivery, throwsStateError);
    await queue.addGame('old-game');

    final oldDelivery = queue.completeNavigation(oldGeneration);
    final newGeneration = queue.beginNavigation();
    await oldAppDiscarded;
    await oldDelivery;
    final newAppDelivery = queue.addApp('new-app', generation: newGeneration);
    await queue.addGame('new-game');
    await Future.wait([
      newAppDelivery,
      queue.completeNavigation(newGeneration),
    ]);

    expect(sent, ['new-app', 'new-game']);
  });

  test('Game 投递的前置异步操作期间换页时不向新页面发送旧回包', () async {
    final sent = <String>[];
    final beforeSendStarted = Completer<void>();
    final releaseBeforeSend = Completer<void>();
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final oldGeneration = queue.beginNavigation();
    await queue.addGame(
      'old-game',
      beforeSend: () async {
        beforeSendStarted.complete();
        await releaseBeforeSend.future;
      },
    );

    final oldDelivery = queue.completeNavigation(oldGeneration);
    await beforeSendStarted.future;
    final newGeneration = queue.beginNavigation();
    releaseBeforeSend.complete();
    await oldDelivery;
    await queue.addGame('new-game');
    await queue.completeNavigation(newGeneration);

    expect(sent, ['new-game']);
  });

  test('dispose 使 pending、迟到 App 回包和旧代恢复任务全部失效', () async {
    final sent = <String>[];
    final queue = WebViewSdkNavigationQueue((script) async => sent.add(script));
    final generation = queue.beginNavigation();
    final pendingAppDelivery = queue.addApp(
      'pending-app',
      generation: generation,
    );
    final pendingAppDiscarded = expectLater(
      pendingAppDelivery,
      throwsStateError,
    );
    await queue.addGame('pending-game');

    queue.dispose();
    await pendingAppDiscarded;
    await expectLater(
      queue.addApp('late-app', generation: generation),
      throwsStateError,
    );
    await queue.addGame('late-game');
    await queue.completeNavigation(generation);

    expect(sent, isEmpty);
  });
}
