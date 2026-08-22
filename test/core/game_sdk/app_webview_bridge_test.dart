import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:playmesh/core/app_media/app_media_adapter.dart';
import 'package:playmesh/core/app_media/app_media_runtime.dart';
import 'package:playmesh/core/capabilities/camera/camera_capability_plugin.dart';
import 'package:playmesh/core/capabilities/capability_registry.dart';
import 'package:playmesh/core/capabilities/vibration/vibration_capability_plugin.dart';
import 'package:playmesh/core/capabilities/web_permission/web_permission_platform_authorizer.dart';
import 'package:playmesh/core/game_sdk/app_webview_bridge.dart';
import 'package:playmesh/core/game_sdk/sdk_feature_registry.dart';
import 'package:playmesh/core/game_sdk/webview_message_queue.dart';
import 'package:playmesh/core/game_web/game_share_link_snapshot.dart';
import 'package:playmesh/core/platform/app_device_service.dart';
import 'package:playmesh/core/storage/app_local_bucket_store.dart';
import 'package:playmesh/models/game_summary.dart';

void main() {
  test('App Bridge Bucket 只写入当前设备的游戏本地目录', () async {
    final root = await Directory.systemTemp.createTemp(
      'playmesh-app-bridge-bucket-',
    );
    addTearDown(() => root.delete(recursive: true));
    final bridge = AppWebViewBridge(
      userId: 'u-local-bucket',
      nickname: '本机玩家',
      localBucketStore: AppLocalBucketStore(
        gameId: 'com.playmesh.local-bucket',
        gameName: '本地存档游戏',
        libraryRoot: root,
      ),
    );
    addTearDown(bridge.close);

    expect(
      (await _command(
        bridge,
        'app.storage.get',
        'bucket-get-empty',
        payload: {'bucket': 'player_save', 'key': 'progress'},
      ))['result'],
      isNull,
    );
    await _command(
      bridge,
      'app.storage.set',
      'bucket-set',
      payload: {
        'bucket': 'player_save',
        'key': 'progress',
        'value': {'level': 7},
      },
    );
    expect(
      (await _command(
        bridge,
        'app.storage.get',
        'bucket-get',
        payload: {'bucket': 'player_save', 'key': 'progress'},
      ))['result'],
      {'level': 7},
    );
    final file = File(
      '${root.path}${Platform.pathSeparator}data'
      '${Platform.pathSeparator}本地存档游戏'
      '${Platform.pathSeparator}com.playmesh.local-bucket'
      '${Platform.pathSeparator}player_save.json',
    );
    expect(await file.exists(), isTrue);

    await _command(
      bridge,
      'app.storage.remove',
      'bucket-remove',
      payload: {'bucket': 'player_save', 'key': 'progress'},
    );
    await _command(
      bridge,
      'app.storage.clear',
      'bucket-clear',
      payload: {'bucket': 'player_save'},
    );
  });

  test('bootstrap 返回项目声明、平台注册表和当前可用插件', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-current-app',
      nickname: '本机玩家',
      declaredCapabilities: const ['device.vibration'],
      deviceService: _FakeDeviceService(),
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    final response = await _command(bridge, 'app.bootstrap', 'bootstrap');
    final result = response['result']! as Map<String, Object?>;
    final identity = result['identity']! as Map<String, Object?>;
    final device = result['device']! as Map<String, Object?>;
    final registry = result['capabilityRegistry']! as List<Object?>;

    expect(result['available'], isTrue);
    expect(result, isNot(contains('game')));
    expect(identity['userId'], 'u-current-app');
    expect(device['capabilities'], ['device.vibration']);
    expect(device['declaredCapabilities'], ['device.vibration']);
    expect(registry, hasLength(5));
    expect(registry, everyElement(contains('methods')));
    expect(
      registry.where(
        (item) => (item! as Map<String, Object?>)['code'] == 'media.camera',
      ),
      everyElement(containsPair('events', <Object?>[])),
    );
  });

  test('远程 App 入口由 Game SDK 单向配置终端能力声明', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-remote-app',
      nickname: '远程玩家',
      acceptRuntimeGameDeclaration: true,
      coreBaseUri: Uri.parse('http://127.0.0.1:45678/'),
      playerSource: 'server',
      deviceService: _FakeDeviceService(),
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    final bootstrapResponse = await _command(
      bridge,
      'app.bootstrap',
      'remote-bootstrap',
    );
    final bootstrap = bootstrapResponse['result']! as Map<String, Object?>;
    final initialDevice = bootstrap['device']! as Map<String, Object?>;
    expect(bootstrap, isNot(contains('game')));
    expect(initialDevice['declaredCapabilities'], isEmpty);

    final configureResponse = await _command(
      bridge,
      'app.game.configure',
      'remote-game-configure',
      payload: {
        'declaredCapabilities': ['device.vibration'],
      },
    );
    final environment = configureResponse['result']! as Map<String, Object?>;
    final runtime = bootstrap['runtime']! as Map<String, Object?>;
    final device = environment['device']! as Map<String, Object?>;

    expect(device['declaredCapabilities'], ['device.vibration']);
    expect(device['capabilities'], ['device.vibration']);
    expect(bridge.runtimeDeclaredCapabilities, ['device.vibration']);
    expect(runtime['coreBase'], 'http://127.0.0.1:45678/');
    expect(runtime['playerSource'], 'server');

    await bridge.resetCapabilities();
    expect(bridge.runtimeDeclaredCapabilities, isEmpty);
  });

  test('App Bridge 统一按远程页面运行时声明路由 WebView 权限', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-web-permission',
      nickname: '远程玩家',
      acceptRuntimeGameDeclaration: true,
      capabilityRegistry: CapabilityRegistry([
        CameraCapabilityPlugin(
          webPermissionAuthorizer: _AllowWebPermissionAuthorizer(),
        ),
      ]),
    );
    addTearDown(bridge.close);

    expect(await bridge.authorizeWebPermissions(['camera']), isFalse);
    await _command(
      bridge,
      'app.game.configure',
      'configure-camera',
      payload: {
        'declaredCapabilities': ['media.camera'],
      },
    );
    expect(await bridge.authorizeWebPermissions(['camera']), isTrue);
    expect(await bridge.authorizeWebPermissions(['microphone']), isFalse);

    await bridge.resetCapabilities();
    expect(await bridge.authorizeWebPermissions(['camera']), isFalse);
  });

  test('未声明或未确认时拒绝创建插件实例', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-capability',
      nickname: '玩家',
      declaredCapabilities: const ['device.vibration'],
      deviceService: _FakeDeviceService(),
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    final undeclared = await _command(
      bridge,
      'app.capability.create',
      'undeclared',
      payload: {'code': 'media.camera', 'options': <String, Object?>{}},
    );
    expect(undeclared['type'], 'app.command.error');
    expect(undeclared['error'], contains('media.camera'));

    final unconfirmed = await _command(
      bridge,
      'app.capability.create',
      'unconfirmed',
      payload: {'code': 'device.vibration', 'options': <String, Object?>{}},
    );
    expect(unconfirmed['type'], 'app.command.error');
    expect(unconfirmed['error'], contains('能力确认'));
  });

  test('震动能力通过通用插件实例调用原生触觉服务', () async {
    final vibrationDriver = _FakeVibrationDriver();
    final bridge = AppWebViewBridge(
      userId: 'u-haptic',
      nickname: '震动玩家',
      declaredCapabilities: const ['device.vibration'],
      vibrationDriver: vibrationDriver,
    );
    addTearDown(bridge.close);

    await _command(bridge, 'app.capabilities.confirm', 'confirm');
    final create = await _command(
      bridge,
      'app.capability.create',
      'create-vibration',
      payload: {'code': 'device.vibration', 'options': <String, Object?>{}},
    );
    final instanceId =
        (create['result']! as Map<String, Object?>)['instanceId']! as String;

    final invoke = await _command(
      bridge,
      'app.capability.invoke',
      'vibrate',
      payload: {
        'instanceId': instanceId,
        'method': 'vibrate',
        'arguments': {
          'pattern': [0, 80, 40, 120],
          'intensities': [0, 128, 0, 255],
          'repeat': -1,
        },
      },
    );

    expect(invoke['type'], 'app.command.result');
    expect(vibrationDriver.vibrateCount, 1);
    expect(vibrationDriver.lastPattern, [0, 80, 40, 120]);

    final cancel = await _command(
      bridge,
      'app.capability.invoke',
      'cancel-vibration',
      payload: {
        'instanceId': instanceId,
        'method': 'cancel',
        'arguments': <String, Object?>{},
      },
    );
    expect(cancel['type'], 'app.command.result');
    expect(vibrationDriver.cancelCount, 1);
  });

  test('App 媒体命令只转交独立 adapterOptions 并映射公共会话', () async {
    final adapter = _FakeAppMediaAdapter();
    final mediaRuntime = AppMediaRuntime([adapter]);
    final bridge = AppWebViewBridge(
      userId: 'u-media',
      nickname: '媒体玩家',
      mediaRuntime: mediaRuntime,
    );
    addTearDown(bridge.close);
    final source = await mediaRuntime.createSource(
      producer: 'sensor.pose6d',
      kind: 'video',
      sourceOptions: const {'fps': 30},
    );

    final opened = await _command(
      bridge,
      'app.media.open',
      'open-media',
      payload: {
        'source': source,
        'adapterOptions': {
          'offer': {'type': 'offer', 'sdp': 'browser-offer'},
        },
      },
    );
    final result = opened['result']! as Map<String, Object?>;

    expect(opened['type'], 'app.command.result');
    expect(result['protocol'], 'fake');
    expect(result['sessionId'], startsWith('media-session-'));
    expect(adapter.openOptions, {
      'offer': {'type': 'offer', 'sdp': 'browser-offer'},
    });
    expect(source, isNot(contains('offer')));

    final closed = await _command(
      bridge,
      'app.media.close',
      'close-media',
      payload: {'sessionId': result['sessionId']},
    );
    expect(closed['type'], 'app.command.result');
    expect(adapter.closedSessions, ['private-session']);
  });

  test('网页请求退出时通知宿主', () async {
    final exitRequested = Completer<void>();
    final bridge = AppWebViewBridge(
      userId: 'u-exit',
      nickname: '玩家',
      onExitRequested: () async => exitRequested.complete(),
    );
    addTearDown(bridge.close);

    final response = await _command(bridge, 'app.game.exit', 'exit');

    expect(response['type'], 'app.command.result');
    await exitRequested.future.timeout(const Duration(seconds: 1));
  });

  test('App SDK 完成输入监听后明确通知宿主接管', () async {
    var takeoverCount = 0;
    final bridge = AppWebViewBridge(
      userId: 'u-input-takeover',
      nickname: '玩家',
      onInputTakeover: () => takeoverCount += 1,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.input.takeover',
      'input-takeover',
    );

    expect(response['type'], 'app.command.result');
    expect(takeoverCount, 1);
  });

  test('App 级平台 UI 只向宿主转发受限分享动作', () async {
    var shareCount = 0;
    final bridge = AppWebViewBridge(
      userId: 'u-app-ui',
      nickname: '玩家',
      onOpenSharePanel: () async => shareCount += 1,
    );
    addTearDown(bridge.close);

    bridge.recordUserActivation();
    final share = await _command(
      bridge,
      'app.ui.openSharePanel',
      'share',
      payload: {'userActivation': true},
    );
    final obsoleteSidebarCommand = await _command(
      bridge,
      'app.ui.gameSidebar.show',
      'sidebar-show',
    );

    expect(share['type'], 'app.command.result');
    expect(obsoleteSidebarCommand['type'], 'app.command.error');
    expect(obsoleteSidebarCommand['code'], isNull);
    expect(obsoleteSidebarCommand['error'], contains('未注册 App SDK 命令'));
    expect(shareCount, 1);
  });

  test('App 分享命令在缺少用户激活标识时返回稳定错误 code', () async {
    final bridge = AppWebViewBridge(
      userId: 'u-app-ui',
      nickname: '玩家',
      onOpenSharePanel: () async {},
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.ui.openSharePanel',
      'share-denied',
    );

    expect(response['type'], 'app.command.error');
    expect(response['code'], 'user_activation_required');
  });

  test('raw Bridge 自报 userActivation 不构成可信用户激活', () async {
    var shareCount = 0;
    final host = _FakeAppLanHost();
    final bridge = AppWebViewBridge(
      userId: 'u-app-raw-activation',
      nickname: '玩家',
      lanHost: host,
      onOpenSharePanel: () async => shareCount += 1,
    );
    addTearDown(bridge.close);

    final join = await _rawCommand(bridge, {
      'command': 'app.lan.joinDiscovered',
      'requestId': 'raw-lan-activation',
      'payload': {
        'instanceId': 'discovered-instance-0001',
        'userActivation': true,
      },
    });
    final share = await _rawCommand(bridge, {
      'command': 'app.ui.openSharePanel',
      'requestId': 'raw-ui-activation',
      'payload': {'userActivation': true},
    });

    expect(join['code'], 'user_activation_required');
    expect(share['code'], 'user_activation_required');
    expect(host.preparedDiscovered, isEmpty);
    expect(shareCount, 0);
  });

  test('可信 userActivation 票据只能消费一次且 document reset 清除', () async {
    var shareCount = 0;
    final bridge = AppWebViewBridge(
      userId: 'u-app-activation-lifecycle',
      nickname: '玩家',
      onOpenSharePanel: () async => shareCount += 1,
    );
    addTearDown(bridge.close);

    bridge.recordUserActivation();
    final first = await _command(
      bridge,
      'app.ui.openSharePanel',
      'activation-first',
      payload: {'userActivation': true},
    );
    final reused = await _command(
      bridge,
      'app.ui.openSharePanel',
      'activation-reused',
      payload: {'userActivation': true},
    );

    bridge.recordUserActivation();
    await bridge.resetCapabilities();
    final afterReset = await _command(
      bridge,
      'app.ui.openSharePanel',
      'activation-after-reset',
      payload: {'userActivation': true},
    );

    expect(first['type'], 'app.command.result');
    expect(reused['code'], 'user_activation_required');
    expect(afterReset['code'], 'user_activation_required');
    expect(shareCount, 1);
  });

  test('App LAN Bridge 只返回无凭据发现投影并严格校验参数', () async {
    final host = _FakeAppLanHost();
    final bridge = AppWebViewBridge(
      userId: 'u-app-lan',
      nickname: 'LAN 玩家',
      lanHost: host,
    );
    addTearDown(bridge.close);

    final discovered = await _command(
      bridge,
      'app.lan.discover',
      'lan-discover',
    );
    final games = discovered['result']! as List<Object?>;
    final game = games.single! as Map<String, Object?>;

    expect(discovered['type'], 'app.command.result');
    expect(game, {
      'instanceId': 'discovered-instance-0001',
      'gameId': 'game.example.lan',
      'name': 'LAN Game',
      'host': 'Living room',
    });
    expect(game.keys.toSet(), {
      'instanceId',
      'gameId',
      'name',
      'host',
    }, reason: '内部附近列表的主机昵称、IP、人数与单机状态不得扩大到 App SDK');
    expect(jsonEncode(discovered), isNot(contains('inviteToken')));

    final invalidPublished = await _command(
      bridge,
      'app.lan.setPublished',
      'lan-published-invalid',
      payload: {'published': true},
    );
    final invalidActivation = await _command(
      bridge,
      'app.lan.joinDiscovered',
      'lan-join-no-activation',
      payload: {'instanceId': 'discovered-instance-0001'},
    );
    final invalidPayload = await _rawCommand(bridge, {
      'command': 'app.lan.discover',
      'requestId': 'lan-non-object-payload',
      'payload': <Object?>[],
    });

    expect(invalidPublished['code'], 'invalid_argument');
    expect(invalidActivation['code'], 'user_activation_required');
    expect(invalidPayload['code'], 'invalid_argument');
    expect(host.publishCount, 0);
    expect(host.preparedDiscovered, isEmpty);
  });

  test('App LAN 加入只在成功回包后执行宿主动作', () async {
    final events = <String>[];
    final sendMayFinish = Completer<void>();
    final host = _FakeAppLanHost(
      onAfterResponse: () async => events.add('after-response'),
    );
    final bridge = AppWebViewBridge(
      userId: 'u-app-lan-order',
      nickname: 'LAN 玩家',
      lanHost: host,
    );
    addTearDown(bridge.close);

    bridge.recordUserActivation();
    final operation = bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.lan.joinDiscovered',
        'requestId': 'lan-join-order',
        'payload': {
          'instanceId': 'discovered-instance-0001',
          'userActivation': true,
        },
      }),
      (message) async {
        expect(jsonDecode(message), containsPair('type', 'app.command.result'));
        events.add('send-start');
        await sendMayFinish.future;
        events.add('send-finish');
      },
    );
    await Future<void>.delayed(Duration.zero);

    expect(events, ['send-start']);
    expect(host.preparedDiscovered, ['discovered-instance-0001']);
    sendMayFinish.complete();
    await operation;
    await Future<void>.delayed(Duration.zero);

    expect(events, ['send-start', 'send-finish', 'after-response']);
  });

  test('App LAN afterResponse 等待真实 WebView 队列投递而非仅入队', () async {
    final delivered = <Map<String, Object?>>[];
    var afterResponseCount = 0;
    final queue = WebViewMessageQueue((message) async {
      delivered.add(
        Map<String, Object?>.from(jsonDecode(message) as Map<Object?, Object?>),
      );
    });
    final bridge = AppWebViewBridge(
      userId: 'u-app-lan-queued-order',
      nickname: 'LAN 玩家',
      lanHost: _FakeAppLanHost(
        onAfterResponse: () async => afterResponseCount += 1,
      ),
    );
    addTearDown(bridge.close);

    bridge.recordUserActivation();
    final documentGeneration = queue.generation;
    final operation = bridge.handleJavaScriptMessage(
      jsonEncode({
        'command': 'app.lan.joinDiscovered',
        'requestId': 'lan-join-queued-order',
        'payload': {
          'instanceId': 'discovered-instance-0001',
          'userActivation': true,
        },
      }),
      (message) => queue.addAndWait(message, generation: documentGeneration),
    );
    await Future<void>.delayed(Duration.zero);

    expect(delivered, isEmpty);
    expect(afterResponseCount, 0);

    await queue.resume();
    await operation;
    await Future<void>.delayed(Duration.zero);

    expect(delivered, hasLength(1));
    expect(delivered.single['type'], 'app.command.result');
    expect(afterResponseCount, 1);
  });

  test('App LAN 分享序列化统一快照且最终 Bridge JSON 超限整体失败', () async {
    final host = _FakeAppLanHost(
      shareSnapshot: GameShareLinkSnapshot(
        generation: 7,
        links: [
          GameShareLink(
            url: Uri.parse(
              'https://relay.example/j/tunnel#inviteToken=bridge-secret',
            ),
            type: GameShareLinkType.wan,
            pngBytes: const [1, 2, 3, 4],
          ),
        ],
      ),
    );
    final bridge = AppWebViewBridge(
      userId: 'u-app-lan-share',
      nickname: 'LAN 玩家',
      lanHost: host,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.lan.getShareLinks',
      'lan-share-links',
    );
    expect(response['result'], [
      {
        'url': 'https://relay.example/j/tunnel#inviteToken=bridge-secret',
        'type': 'wan',
        'img': 'data:image/png;base64,AQIDBA==',
      },
    ]);

    host.shareSnapshot = GameShareLinkSnapshot(
      generation: 8,
      links: [
        GameShareLink(
          url: Uri.parse('https://relay.example/j/oversized'),
          type: GameShareLinkType.wan,
          pngBytes: List<int>.filled(3 * 1024 * 1024, 0),
        ),
      ],
    );
    final oversized = await _command(
      bridge,
      'app.lan.getShareLinks',
      'lan-share-links-oversized',
    );

    expect(oversized['type'], 'app.command.error');
    expect(oversized['code'], 'share_links_too_large');
    expect(oversized['error'], '分享链接负载超过 4 MiB');
    expect(jsonEncode(oversized), isNot(contains('relay.example')));
    expect(jsonEncode(oversized), isNot(contains('data:image/png')));
  });

  test('App LAN 宿主错误使用稳定文案且不会泄露邀请凭据', () async {
    final host = _FakeAppLanHost(
      discoverError: const SdkCommandException(
        'discovery_unavailable',
        'https://host/join#inviteToken=must-not-leak',
      ),
    );
    final bridge = AppWebViewBridge(
      userId: 'u-app-lan-error',
      nickname: 'LAN 玩家',
      lanHost: host,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.lan.discover',
      'lan-error-redaction',
    );

    expect(response['code'], 'discovery_unavailable');
    expect(response['error'], '局域网发现不可用');
    expect(jsonEncode(response), isNot(contains('must-not-leak')));
    expect(jsonEncode(response), isNot(contains('inviteToken')));
  });

  test('全屏命令把控制器方向传给原生设备服务', () async {
    final deviceService = _FakeDeviceService();
    final bridge = AppWebViewBridge(
      userId: 'u-controller',
      nickname: 'Controller',
      deviceService: deviceService,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.device.fullscreen',
      'fullscreen',
      payload: {'enabled': true, 'orientation': 'portrait'},
    );

    expect(response['type'], 'app.command.result');
    expect(deviceService.fullscreenCalls, [
      (enabled: true, orientation: GameOrientation.portrait),
    ]);
  });

  test('远程昵称先持久化再提交 Core，失败时回滚本机身份', () async {
    final persisted = <String>[];
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount += 1;
      expect(request.method, 'PATCH');
      expect(request.url.path, '/v1/sessions/session-1/players/me');
      expect(request.headers['Authorization'], 'Bearer credential-1');
      final body = Map<String, Object?>.from(jsonDecode(request.body) as Map);
      if (requestCount == 1) {
        return http.Response(
          jsonEncode({
            'session': {
              'id': 'session-1',
              'players': [
                {'id': 'player-1', 'nickname': body['nickname']},
              ],
            },
            'player': {'id': 'player-1', 'nickname': body['nickname']},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode({
          'error': {'code': 'update_failed', 'message': 'failed'},
        }),
        400,
        headers: {'content-type': 'application/json'},
      );
    });
    final bridge = AppWebViewBridge(
      userId: 'player-1',
      nickname: '旧昵称',
      coreBaseUri: Uri.parse('http://core.example/'),
      onNicknameChanged: (nickname) async => persisted.add(nickname),
      httpClient: client,
    );
    addTearDown(bridge.close);

    final success = await _command(
      bridge,
      'app.identity.updateNickname',
      'nickname-success',
      payload: {
        'nickname': '新昵称',
        'sessionId': 'session-1',
        'credentialToken': 'credential-1',
        'playerId': 'player-1',
      },
    );
    expect(success['type'], 'app.command.result');
    expect(
      (success['result']! as Map)['identity'],
      containsPair('nickname', '新昵称'),
    );

    final failure = await _command(
      bridge,
      'app.identity.updateNickname',
      'nickname-failure',
      payload: {
        'nickname': '失败昵称',
        'sessionId': 'session-1',
        'credentialToken': 'credential-1',
        'playerId': 'player-1',
      },
    );
    expect(failure['type'], 'app.command.error');
    expect(failure['code'], 'nickname_update_failed');
    expect(persisted, ['新昵称', '失败昵称', '新昵称']);
    final bootstrap = await _command(
      bridge,
      'app.bootstrap',
      'nickname-bootstrap',
    );
    expect(
      (bootstrap['result']! as Map)['identity'],
      containsPair('nickname', '新昵称'),
    );
  });

  test('本机昵称命令只委托宿主事务并刷新 App 身份', () async {
    Map<String, Object?>? received;
    final bridge = AppWebViewBridge(
      userId: 'player-local',
      nickname: '旧昵称',
      onNicknameUpdate: (payload) async {
        received = payload;
        return {
          'session': {
            'id': 'session-local',
            'players': [
              {'id': 'player-local', 'nickname': '本机新昵称'},
            ],
          },
          'player': {'id': 'player-local', 'nickname': '本机新昵称'},
        };
      },
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.identity.updateNickname',
      'nickname-local',
      payload: {'nickname': '本机新昵称'},
    );

    expect(received, {'nickname': '本机新昵称'});
    expect(response['type'], 'app.command.result');
    expect(
      (response['result']! as Map)['identity'],
      containsPair('nickname', '本机新昵称'),
    );
  });

  test('远程昵称响应丢失时读取 Core 权威状态，不盲目回滚', () async {
    final persisted = <String>[];
    var patchCount = 0;
    final client = MockClient((request) async {
      if (request.method == 'PATCH') {
        patchCount += 1;
        throw TimeoutException('response lost');
      }
      expect(request.method, 'GET');
      expect(request.url.path, '/v1/sessions/session-2');
      return http.Response(
        jsonEncode({
          'id': 'session-2',
          'players': [
            {'id': 'player-2', 'nickname': '已提交昵称'},
          ],
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    final bridge = AppWebViewBridge(
      userId: 'player-2',
      nickname: '旧昵称',
      coreBaseUri: Uri.parse('http://core.example/'),
      onNicknameChanged: (nickname) async => persisted.add(nickname),
      httpClient: client,
    );
    addTearDown(bridge.close);

    final response = await _command(
      bridge,
      'app.identity.updateNickname',
      'nickname-reconcile',
      payload: {
        'nickname': '已提交昵称',
        'sessionId': 'session-2',
        'credentialToken': 'credential-2',
        'playerId': 'player-2',
      },
    );

    expect(response['type'], 'app.command.result');
    expect(patchCount, 2);
    expect(persisted, ['已提交昵称']);
    expect(
      (response['result']! as Map)['identity'],
      containsPair('nickname', '已提交昵称'),
    );
  });
}

Future<Map<String, Object?>> _command(
  AppWebViewBridge bridge,
  String command,
  String requestId, {
  Map<String, Object?> payload = const {},
  List<Map<String, Object?>>? messages,
}) async {
  Map<String, Object?>? response;
  await bridge.handleJavaScriptMessage(
    jsonEncode({
      'command': command,
      'requestId': requestId,
      'payload': payload,
    }),
    (message) async {
      final decoded = Map<String, Object?>.from(jsonDecode(message) as Map);
      messages?.add(decoded);
      if (decoded['requestId'] == requestId) response = decoded;
    },
  );
  return response!;
}

Future<Map<String, Object?>> _rawCommand(
  AppWebViewBridge bridge,
  Map<String, Object?> command,
) async {
  Map<String, Object?>? response;
  await bridge.handleJavaScriptMessage(jsonEncode(command), (message) async {
    response = Map<String, Object?>.from(jsonDecode(message) as Map);
  });
  return response!;
}

class _FakeDeviceService extends AppDeviceService {
  final List<({bool enabled, GameOrientation? orientation})> fullscreenCalls =
      [];

  @override
  Future<void> setFullscreen(
    bool enabled, {
    GameOrientation? orientation,
  }) async {
    fullscreenCalls.add((enabled: enabled, orientation: orientation));
  }
}

class _FakeVibrationDriver implements VibrationDriver {
  int vibrateCount = 0;
  int cancelCount = 0;
  List<int>? lastPattern;

  @override
  bool get platformSupported => true;

  @override
  Future<bool> hasVibrator() async => true;

  @override
  Future<bool> hasAmplitudeControl() async => true;

  @override
  Future<bool> hasCustomVibrationsSupport() async => true;

  @override
  Future<void> vibrate({
    required int duration,
    required List<int> pattern,
    required int repeat,
    required List<int> intensities,
    required int amplitude,
    required double sharpness,
    required String? preset,
  }) async {
    vibrateCount += 1;
    lastPattern = pattern;
  }

  @override
  Future<void> cancel() async {
    cancelCount += 1;
  }
}

class _FakeAppLanHost implements AppLanHost {
  _FakeAppLanHost({
    this.onAfterResponse,
    this.discoverError,
    GameShareLinkSnapshot? shareSnapshot,
  }) : shareSnapshot = shareSnapshot ?? GameShareLinkSnapshot.empty(0);

  final Future<void> Function()? onAfterResponse;
  final Object? discoverError;
  GameShareLinkSnapshot shareSnapshot;
  final List<String> preparedDiscovered = [];
  int publishCount = 0;
  int resetCount = 0;

  @override
  Future<List<AppLanDiscoveredGame>> discoverGames() async {
    final error = discoverError;
    if (error != null) throw error;
    return const [
      AppLanDiscoveredGame(
        instanceId: 'discovered-instance-0001',
        gameId: 'game.example.lan',
        name: 'LAN Game',
        host: 'Living room',
      ),
    ];
  }

  @override
  Future<GameShareLinkSnapshot> getShareLinks() async => shareSnapshot;

  @override
  Future<AppLanJoinAction> prepareDiscoveredJoin(String instanceId) async {
    preparedDiscovered.add(instanceId);
    return AppLanJoinAction(onAfterResponse ?? () async {});
  }

  @override
  Future<AppLanJoinAction> prepareInvitationJoin(String invitationUrl) async =>
      AppLanJoinAction(onAfterResponse ?? () async {});

  @override
  Future<AppLanJoinAction> prepareQrJoin() async =>
      AppLanJoinAction(onAfterResponse ?? () async {});

  @override
  void resetDocument() => resetCount += 1;

  @override
  Future<void> setPublished() async => publishCount += 1;
}

class _AllowWebPermissionAuthorizer implements WebPermissionPlatformAuthorizer {
  @override
  Future<bool> authorize(WebPermissionPlatformRequest request) async => true;
}

class _FakeAppMediaAdapter implements AppMediaAdapter {
  AppMediaJson? openOptions;
  final List<String> closedSessions = [];

  @override
  String get protocol => 'fake';

  @override
  int get priority => 1;

  @override
  bool get isAvailable => true;

  @override
  bool supportsProducer(String producer, String kind) =>
      producer == 'sensor.pose6d' && kind == 'video';

  @override
  Future<AppMediaAdapterSource> createSource(
    AppMediaSourceRequest request,
  ) async => const AppMediaAdapterSource(id: 'private-source');

  @override
  Future<AppMediaAdapterSession> open(
    AppMediaAdapterSource source,
    AppMediaJson adapterOptions,
  ) async {
    openOptions = adapterOptions;
    return const AppMediaAdapterSession(
      id: 'private-session',
      answer: {'type': 'answer', 'sdp': 'host-answer'},
    );
  }

  @override
  Future<void> close(String sessionId) async {
    closedSessions.add(sessionId);
  }

  @override
  Future<void> releaseSource(String sourceId) async {}

  @override
  Future<AppMediaJson> test(Duration timeout) async => const {};

  @override
  Future<void> dispose() async {}
}
