import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:playmesh/core/developer/developer_channel.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_distribution.dart';
import 'package:playmesh/core/developer/gdevelop_web_ide_installer_contract.dart';
import 'package:playmesh/core/developer/gdevelop_local_package_source.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/core/download/named_download_endpoint.dart';
import 'package:playmesh/core/download/verified_resumable_download_contract.dart';
import 'package:playmesh/features/developer/game_creation_page.dart';
import 'package:playmesh/features/developer/developer_workspace_page.dart';
import 'package:playmesh/features/developer/developer_workspace_links.dart';
import 'package:playmesh/ui/playmesh_ui.dart';
import 'package:playmesh/core/network/lan_endpoint.dart';

import '../../support/localized_test_app.dart';

void main() {
  setUpAll(initializeLocalizedTestApp);

  testWidgets('shows one developer switch and two creation accordions', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(developerProvider: _FakeDeveloperProvider()),
      ),
    );
    await _pumpAsync(tester);

    expect(find.text('制作游戏'), findsWidgets);
    expect(find.byKey(GameCreationPage.developerSwitchKey), findsOneWidget);
    expect(find.text('源代码开发'), findsOneWidget);
    expect(find.text('可视化开发'), findsOneWidget);
    expect(find.text('开启开发者模式后显示工作区地址、二维码与打开按钮。'), findsOneWidget);
    expect(find.textContaining('基于开源 GDevelop 5'), findsNothing);
  });

  testWidgets('visual development opens its offline third-party notices', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(developerProvider: _FakeDeveloperProvider()),
      ),
    );
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    expect(find.textContaining('非官方修改版'), findsNothing);
    final noticesButton = find.byKey(GameCreationPage.gdevelopNoticesButtonKey);
    await tester.ensureVisible(noticesButton);
    await tester.tap(noticesButton);
    await _pumpAsync(tester);

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('开源与第三方声明'), findsWidgets);
    expect(find.textContaining('installed notices'), findsOneWidget);
    expect(find.textContaining('非官方修改版'), findsOneWidget);
    expect(find.textContaining('5.6.269'), findsWidgets);
    expect(find.textContaining(List.filled(64, 'b').join()), findsOneWidget);
  });

  testWidgets(
    'enables one session and exposes distinct source and visual links',
    (tester) async {
      final provider = _FakeDeveloperProvider();
      await tester.pumpWidget(
        localizedTestApp(home: GameCreationPage(developerProvider: provider)),
      );
      await _pumpAsync(tester);

      await tester.enterText(_tokenField(), 'my-dev-token');
      await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
      await _pumpAsync(tester);

      expect(provider.boundPort, defaultDeveloperPort);
      expect(provider.enabledToken, 'my-dev-token');
      expect(find.text('192.168.1.10'), findsOneWidget);
      expect(find.textContaining('token=my-dev-token'), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('可视化开发'));
      await tester.pumpAndSettle();

      expect(find.text('192.168.1.10'), findsOneWidget);
      expect(find.textContaining('token=my-dev-token'), findsNothing);
      expect(find.text('打开 GDevelop'), findsOneWidget);
      expect(find.byType(DeveloperWorkspaceQrCode), findsOneWidget);
      expect(find.text('安装与管理'), findsOneWidget);
      expect(
        find.text(
          'http://192.168.1.10:16666/dev/devpath/workspace?token=my-dev-token',
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'installed visual workspace remains primary when distribution manifest is empty',
    (tester) async {
      final provider = _FakeDeveloperProvider(
        visualAvailable: true,
        distributionAvailable: false,
      );
      await tester.pumpWidget(
        localizedTestApp(home: GameCreationPage(developerProvider: provider)),
      );
      await _pumpAsync(tester);

      await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
      await _pumpAsync(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('可视化开发'));
      await tester.pumpAndSettle();

      expect(provider.gdevelopWorkspaceLinkCalls, greaterThan(0));
      expect(find.text('打开 GDevelop'), findsOneWidget);
      expect(find.byType(DeveloperWorkspaceQrCode), findsOneWidget);
      expect(find.text('192.168.1.10'), findsOneWidget);
      expect(find.textContaining('token=persisted-dev-token'), findsNothing);
      expect(find.text('安装与管理'), findsOneWidget);
    },
  );

  testWidgets('visual gateway failure keeps access card and retry recovers', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider(
      gdevelopWorkspaceLinkError: StateError('visual gateway unavailable'),
    );
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);

    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    expect(find.byType(DeveloperWorkspaceLinks), findsOneWidget);
    expect(find.textContaining('visual gateway unavailable'), findsOneWidget);
    expect(find.text('重试启动'), findsOneWidget);

    provider.gdevelopWorkspaceLinkError = null;
    await tester.tap(find.text('重试启动'));
    await _pumpAsync(tester);

    expect(find.text('打开 GDevelop'), findsOneWidget);
    expect(find.byType(DeveloperWorkspaceQrCode), findsOneWidget);
    expect(find.textContaining('visual gateway unavailable'), findsNothing);
  });

  testWidgets('closing and reopening GDevelop refreshes its bootstrap URL', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    final provider = _FakeDeveloperProvider(rotatingGdevelopBootstrap: true);
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('打开 GDevelop'));
    final callsBeforeFirstOpen = provider.gdevelopWorkspaceLinkCalls;
    await tester.tap(find.text('打开 GDevelop'));
    await tester.pumpAndSettle();
    expect(provider.gdevelopWorkspaceLinkCalls, callsBeforeFirstOpen + 1);
    var workspace = tester.widget<DeveloperWorkspacePage>(
      find.byType(DeveloperWorkspacePage),
    );
    expect(
      workspace.workspaceUri.queryParameters['editorBootstrap'],
      'bootstrap_${provider.gdevelopWorkspaceLinkCalls}',
    );

    Navigator.of(tester.element(find.byType(DeveloperWorkspacePage))).pop();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('打开 GDevelop'));
    final callsBeforeSecondOpen = provider.gdevelopWorkspaceLinkCalls;
    await tester.tap(find.text('打开 GDevelop'));
    await tester.pumpAndSettle();
    expect(provider.gdevelopWorkspaceLinkCalls, callsBeforeSecondOpen + 1);
    workspace = tester.widget<DeveloperWorkspacePage>(
      find.byType(DeveloperWorkspacePage),
    );
    expect(
      workspace.workspaceUri.queryParameters['editorBootstrap'],
      'bootstrap_${provider.gdevelopWorkspaceLinkCalls}',
    );

    Navigator.of(tester.element(find.byType(DeveloperWorkspacePage))).pop();
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('visual IP selection updates QR and copy keeps visual route', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final provider = _FakeDeveloperProvider(
      extraVisualEndpoint: LanEndpointCandidate(
        uri: Uri.parse(
          'http://198.18.0.1:16666/dev/devpath/gdevelop/?token=persisted-dev-token',
        ),
        interfaceName: 'vEthernet (WSL)',
        interfaceIndex: 7,
        addressType: LanAddressType.benchmarkIpv4,
        risk: LanEndpointRisk.caution,
      ),
    );
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    await tester.dragUntilVisible(
      find.text('198.18.0.1'),
      find.byType(ListView),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('198.18.0.1'));
    await tester.pump();
    expect(
      tester
          .widget<DeveloperWorkspaceQrCode>(
            find.byType(DeveloperWorkspaceQrCode),
          )
          .uri
          .host,
      '198.18.0.1',
    );
    final copyButton = find.byTooltip('复制工作区链接').last;
    await tester.tap(copyButton);
    await tester.pump();
    expect(
      clipboardText,
      'http://198.18.0.1:16666/dev/devpath/gdevelop/?token=persisted-dev-token',
    );
  });

  testWidgets('source QR encodes the exact LAN URI including token', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(developerProvider: _FakeDeveloperProvider()),
      ),
    );
    await _pumpAsync(tester);

    await tester.enterText(_tokenField(), 'qr-exact-token');
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);

    expect(
      tester
          .widget<DeveloperWorkspaceQrCode>(
            find.byType(DeveloperWorkspaceQrCode),
          )
          .uri
          .toString(),
      'http://192.168.1.10:16666/dev/devpath/workspace?token=qr-exact-token',
    );
    expect(
      find.descendant(
        of: find.byType(DeveloperWorkspaceLinks),
        matching: find.textContaining('qr-exact-token'),
      ),
      findsNothing,
    );
    expect(
      tester.getSemantics(find.byType(DeveloperWorkspaceQrCode)).toString(),
      isNot(contains('qr-exact-token')),
    );
    semantics.dispose();
  });

  testWidgets('copy keeps the exact LAN URI including IP and token', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(developerProvider: _FakeDeveloperProvider()),
      ),
    );
    await _pumpAsync(tester);

    await tester.enterText(_tokenField(), 'copy-exact-token');
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.tap(find.byTooltip('复制工作区链接'));
    await tester.pump();

    expect(
      clipboardText,
      'http://192.168.1.10:16666/dev/devpath/workspace?token=copy-exact-token',
    );
    expect(find.text('工作区链接已复制'), findsOneWidget);
  });

  testWidgets('open navigates to the exact in-App URI and keeps token', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = previousPlatform);
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(developerProvider: _FakeDeveloperProvider()),
      ),
    );
    await _pumpAsync(tester);

    await tester.enterText(_tokenField(), 'open-exact-token');
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.tap(find.text('打开工作区'));
    await tester.pumpAndSettle();

    final workspace = tester.widget<DeveloperWorkspacePage>(
      find.byType(DeveloperWorkspacePage),
    );
    expect(
      workspace.workspaceUri.toString(),
      'http://127.0.0.1:16666/dev/devpath/workspace?token=open-exact-token',
    );
    debugDefaultTargetPlatformOverride = previousPlatform;
  });

  testWidgets('loads the persistent developer workspace identity', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider(
      preferredPort: 17777,
      preferredToken: 'saved-dev-token',
    );
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);

    expect(tester.widget<TextField>(_portField()).controller?.text, '17777');
    expect(
      tester.widget<TextField>(_tokenField()).controller?.text,
      'saved-dev-token',
    );
  });

  testWidgets('switch reflects the target state while startup is pending', (
    tester,
  ) async {
    final provider = _DelayedDeveloperProvider();
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);

    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await tester.pump();

    expect(
      tester
          .widget<Switch>(find.byKey(GameCreationPage.developerSwitchKey))
          .value,
      isTrue,
    );
    expect(find.text('正在启动开发者通道并准备工作区地址…'), findsOneWidget);

    provider.completeEnable();
    await _pumpAsync(tester);
    expect(find.textContaining('已开启，Token 尾号'), findsOneWidget);
  });

  testWidgets('shows installed-state guidance when visual Web IDE is absent', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider(visualAvailable: false);
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    expect(find.textContaining('尚未安装 GDevelop Web IDE'), findsOneWidget);
    expect(find.text('打开 GDevelop'), findsNothing);
  });

  testWidgets('installed status shows core version and short SHA build', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider();
    await tester.pumpWidget(
      localizedTestApp(home: GameCreationPage(developerProvider: provider)),
    );
    await _pumpAsync(tester);
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    expect(find.textContaining('核心 5.6.269 · 构建 aaaaaaaaaaaa'), findsOneWidget);
  });

  testWidgets(
    'visual install remains available before Developer Mode is enabled',
    (tester) async {
      final provider = _FakeDeveloperProvider(
        visualAvailable: false,
        distributionAvailable: true,
      );
      await tester.pumpWidget(
        localizedTestApp(home: GameCreationPage(developerProvider: provider)),
      );
      await _pumpAsync(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('可视化开发'));
      await tester.pumpAndSettle();

      final manage = find.byKey(GameCreationPage.gdevelopManageButtonKey);
      expect(manage, findsOneWidget);
      expect(find.text('本地清单'), findsNothing);
      await tester.tap(manage);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('gdevelop-install-dialog')), findsOneWidget);
      expect(find.text('本地清单'), findsNothing);
      await tester.tap(find.text('在线安装'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gdevelop-next-button')));
      await _pumpAsync(tester);
      expect(find.text('本地清单'), findsOneWidget);
      expect(find.text('打开 GDevelop'), findsNothing);
      expect(find.textContaining('开启开发者模式后即可显示地址'), findsNothing);
    },
  );

  testWidgets(
    'cancelling the system ZIP picker leaves installation unchanged',
    (tester) async {
      final provider = _FakeDeveloperProvider(visualAvailable: false);
      var pickerCalls = 0;
      await tester.pumpWidget(
        localizedTestApp(
          home: GameCreationPage(
            developerProvider: provider,
            localPackagePicker: () async {
              pickerCalls += 1;
              return null;
            },
          ),
        ),
      );
      await _pumpAsync(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -180));
      await tester.pumpAndSettle();
      await tester.tap(find.text('可视化开发'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(GameCreationPage.gdevelopManageButtonKey));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从本地 ZIP 安装'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('gdevelop-next-button')));
      await tester.pumpAndSettle();
      final localInstall = find.byKey(
        GameCreationPage.gdevelopLocalInstallButtonKey,
      );
      await tester.tap(localInstall);
      await tester.pumpAndSettle();

      expect(pickerCalls, 1);
      expect(provider.localPackageCalls, 0);
      expect(provider.visualAvailable, isFalse);
      expect(find.byKey(const Key('gdevelop-install-dialog')), findsOneWidget);
    },
  );

  testWidgets('WebIDE install controls require Developer Mode to be off', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider(
      visualAvailable: false,
      distributionAvailable: true,
    );
    final probeService = EndpointProbeService(
      httpClient: _ReachableProbeHttpClient(),
    );
    addTearDown(probeService.close);
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(
          developerProvider: provider,
          gdevelopProbeService: probeService,
        ),
      ),
    );
    await _pumpAsync(tester);
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    final manage = find.byKey(GameCreationPage.gdevelopManageButtonKey);
    expect(tester.widget<OutlinedButton>(manage).onPressed, isNull);
    expect(find.byKey(const Key('gdevelop-install-dialog')), findsNothing);
    expect(find.text('请先关闭开发者模式，再安装、升级或修复 WebIDE；当前版本未被覆盖。'), findsNothing);

    await tester.dragUntilVisible(
      find.byKey(GameCreationPage.developerSwitchKey),
      find.byType(ListView),
      const Offset(0, 180),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);
    await tester.dragUntilVisible(
      manage,
      find.byType(ListView),
      const Offset(0, -180),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<OutlinedButton>(manage).onPressed, isNotNull);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gdevelop-install-dialog')), findsOneWidget);
  });

  testWidgets(
    'landscape creation controls remain scrollable without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        localizedTestApp(
          home: GameCreationPage(
            developerProvider: _FakeDeveloperProvider(
              distributionAvailable: true,
            ),
          ),
        ),
      );
      await _pumpAsync(tester);
      await tester.drag(find.byType(ListView), const Offset(0, -220));
      await tester.pumpAndSettle();
      await tester.tap(find.text('可视化开发'));
      await tester.pumpAndSettle();

      expect(find.byType(ListView), findsOneWidget);
      expect(
        find.byKey(GameCreationPage.gdevelopManageButtonKey),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'landscape visual access remains scrollable with the keyboard inset',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        localizedTestApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(900, 500),
              viewInsets: EdgeInsets.only(bottom: 220),
            ),
            child: GameCreationPage(
              developerProvider: _FakeDeveloperProvider(),
            ),
          ),
        ),
      );
      await _pumpAsync(tester);
      await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
      await _pumpAsync(tester);
      await tester.dragUntilVisible(
        find.text('可视化开发'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('可视化开发'));
      await tester.pumpAndSettle();

      await tester.dragUntilVisible(
        find.text('打开 GDevelop'),
        find.byType(ListView),
        const Offset(0, -160),
      );
      await tester.pumpAndSettle();
      expect(find.text('打开 GDevelop'), findsOneWidget);
      expect(find.byType(DeveloperWorkspaceQrCode), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('requires two manual source choices and exposes forced repair', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider(distributionAvailable: true);
    final probeService = EndpointProbeService(
      httpClient: _ReachableProbeHttpClient(),
    );
    addTearDown(probeService.close);
    await tester.pumpWidget(
      localizedTestApp(
        home: GameCreationPage(
          developerProvider: provider,
          gdevelopProbeService: probeService,
        ),
      ),
    );
    await _pumpAsync(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -180));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可视化开发'));
    await tester.pumpAndSettle();

    expect(provider.manifestCalls, 0, reason: '未选择清单源前不得读取网络清单');
    await tester.tap(find.byKey(GameCreationPage.gdevelopManageButtonKey));
    await tester.pumpAndSettle();
    expect(find.text('本地清单'), findsNothing);
    await tester.tap(find.text('在线安装'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('gdevelop-next-button')));
    await _pumpAsync(tester);
    expect(find.byKey(const Key('gdevelop-back-button')), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地清单'));
    await _pumpAsync(tester);
    expect(provider.manifestCalls, 1);
    await tester.tap(find.byKey(const Key('gdevelop-next-button')));
    await _pumpAsync(tester);
    expect(find.text('本地 ZIP'), findsOneWidget);

    await tester.tap(find.text('本地 ZIP'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gdevelop-next-button')));
    await tester.pumpAndSettle();
    final repair = find.byKey(GameCreationPage.gdevelopRepairButtonKey);
    expect(repair, findsOneWidget);
    await tester.tap(repair);
    await tester.pumpAndSettle();

    expect(provider.forceRedownloadCalls, [true]);
    expect(find.textContaining('修复完成'), findsOneWidget);
  });

  testWidgets('workspace selection keeps readable dark-theme colors', (
    tester,
  ) async {
    final provider = _FakeDeveloperProvider();
    await tester.pumpWidget(
      localizedTestApp(
        home: Theme(
          data: PlaymeshTheme.dark(),
          child: GameCreationPage(developerProvider: provider),
        ),
      ),
    );
    await _pumpAsync(tester);
    await tester.tap(find.byKey(GameCreationPage.developerSwitchKey));
    await _pumpAsync(tester);

    final selectedTile = tester.widget<Material>(
      find.byKey(
        const ValueKey<String>('developer-workspace-link-192.168.1.10'),
      ),
    );
    final colors = PlaymeshTheme.dark().colorScheme;
    expect(selectedTile.color, colors.secondaryContainer);
  });

  testWidgets(
    'shows only IP choices while keeping QR selection and copy actions',
    (tester) async {
      final privateEndpoint = _lan(Uri.parse('http://10.80.0.4:16666/dev'));
      final benchmarkEndpoint = LanEndpointCandidate(
        uri: Uri.parse('http://198.18.0.1:16666/dev'),
        interfaceName: 'vEthernet (WSL)',
        interfaceIndex: 7,
        addressType: LanAddressType.benchmarkIpv4,
        risk: LanEndpointRisk.caution,
      );
      await tester.pumpWidget(
        localizedTestApp(
          home: Scaffold(
            body: DeveloperWorkspaceLinks(
              links: [benchmarkEndpoint, privateEndpoint],
              openLabel: '打开',
              openIcon: Icons.open_in_browser,
              emptyMessage: '空',
              onOpenWorkspace: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('10.80.0.4'), findsOneWidget);
      expect(find.text('198.18.0.1'), findsOneWidget);
      expect(find.textContaining('Wi-Fi'), findsNothing);
      expect(find.textContaining('vEthernet'), findsNothing);
      expect(find.textContaining('IPv4'), findsNothing);
      expect(find.textContaining('http://'), findsNothing);
      expect(find.byTooltip('复制工作区链接'), findsNWidgets(2));
      expect(
        tester
            .widget<DeveloperWorkspaceQrCode>(
              find.byType(DeveloperWorkspaceQrCode),
            )
            .uri
            .host,
        '10.80.0.4',
      );

      await tester.tap(find.text('198.18.0.1'));
      await tester.pump();
      expect(
        tester
            .widget<DeveloperWorkspaceQrCode>(
              find.byType(DeveloperWorkspaceQrCode),
            )
            .uri
            .host,
        '198.18.0.1',
      );
    },
  );
}

Finder _portField() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == '端口',
);

Finder _tokenField() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == 'Token',
);

class _FakeDeveloperProvider
    implements DeveloperModeProvider, DeveloperWorkspacePreferenceProvider {
  _FakeDeveloperProvider({
    this.preferredPort = defaultDeveloperPort,
    this.preferredToken = 'persisted-dev-token',
    this.visualAvailable = true,
    this.distributionAvailable = false,
    this.gdevelopWorkspaceLinkError,
    this.extraVisualEndpoint,
    this.rotatingGdevelopBootstrap = false,
  });

  final int preferredPort;
  final String preferredToken;
  bool visualAvailable;
  final bool distributionAvailable;
  Object? gdevelopWorkspaceLinkError;
  final LanEndpointCandidate? extraVisualEndpoint;
  final bool rotatingGdevelopBootstrap;
  var gdevelopWorkspaceLinkCalls = 0;
  int? boundPort;
  String? enabledToken;
  var manifestCalls = 0;
  var localPackageCalls = 0;
  var installedAt = DateTime.utc(2026, 8, 5);
  final List<bool> forceRedownloadCalls = [];
  final configSource = NamedDownloadEndpoint(
    name: '本地清单',
    url: Uri.parse('https://config.example/update.json'),
  );
  final downloadSource = NamedDownloadEndpoint(
    name: '本地 ZIP',
    url: Uri.parse('https://download.example/GDevelop-webide-v5.6.269.zip'),
  );

  String get releaseSha256 => List.filled(64, 'a').join();

  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  }) async {
    boundPort = port;
    enabledToken = token;
    return _session(port: port, token: token);
  }

  DeveloperSession _session({int? port, String? token}) {
    final resolvedToken = token?.isNotEmpty == true
        ? token!
        : 'generated-token';
    return DeveloperSession(
      enabled: true,
      port: port ?? preferredPort,
      path: 'devpath',
      token: resolvedToken,
      tokenHint: resolvedToken.substring(resolvedToken.length - 6),
      workspacePath: '/dev/devpath/workspace',
      gdevelopWorkspacePath: '/dev/devpath/gdevelop/',
      docsPath: '/dev/docs',
      openApiPath: '/dev/openapi.json',
      sdkManifestPath: '/dev/sdk-manifest.json',
      createdAt: DateTime.utc(2026, 8, 4),
    );
  }

  @override
  Future<DeveloperSession> developerModeStatus() async {
    return const DeveloperSession(enabled: false);
  }

  @override
  Future<DeveloperWorkspacePreference>
  loadDeveloperWorkspacePreference() async => DeveloperWorkspacePreference(
    port: preferredPort,
    token: preferredToken,
    path: 'devpath',
  );

  @override
  Future<void> disableDeveloperMode() async {}

  @override
  Future<List<LanEndpointCandidate>> sourceWorkspaceLinks(
    DeveloperSession session,
  ) async {
    return [
      _lan(
        Uri.parse(
          'http://192.168.1.10:${boundPort ?? session.port}${session.workspacePath}?token=${session.token}',
        ),
      ),
    ];
  }

  @override
  Future<List<LanEndpointCandidate>> gdevelopWorkspaceLinks(
    DeveloperSession session,
  ) async {
    gdevelopWorkspaceLinkCalls += 1;
    if (gdevelopWorkspaceLinkError case final error?) throw error;
    if (!visualAvailable) return const [];
    return [
      _lan(
        Uri(
          scheme: 'http',
          host: '192.168.1.10',
          port: boundPort ?? session.port,
          path: session.gdevelopWorkspacePath,
          queryParameters: {
            'token': session.token,
            if (rotatingGdevelopBootstrap)
              'editorBootstrap': 'bootstrap_$gdevelopWorkspaceLinkCalls',
          },
        ),
      ),
      ?extraVisualEndpoint,
    ];
  }

  @override
  Future<GDevelopWebIdeInstallationInspection>
  inspectGDevelopWebIdeInstallation() async {
    if (!visualAvailable) {
      return const GDevelopWebIdeInstallationInspection(
        state: GDevelopWebIdeInstallationState.absent,
      );
    }
    return GDevelopWebIdeInstallationInspection(
      state: GDevelopWebIdeInstallationState.ready,
      marker: GDevelopWebIdeInstalledMarker(
        version: '5.6.269',
        sha256: releaseSha256,
        noticesSha256: List.filled(64, 'b').join(),
        aiToolsPath: 'playmesh/ai/tools.json',
        aiToolsSha256: List.filled(64, 'c').join(),
        aiToolsContractHash: List.filled(64, 'd').join(),
        size: 123,
        installedAt: installedAt,
        installationKind: GDevelopWebIdeInstallationKind.release,
      ),
    );
  }

  @override
  Future<GDevelopWebIdeInstalledNotices>
  loadInstalledGDevelopWebIdeNotices() async => GDevelopWebIdeInstalledNotices(
    version: '5.6.269',
    archiveSha256: List.filled(64, 'a').join(),
    noticesSha256: List.filled(64, 'b').join(),
    contents:
        'installed notices\n'
        'Playmesh 可视化编辑器是基于 GDevelop 开源技术的非官方修改版。',
  );

  @override
  Future<GDevelopWebIdeConfigSources> loadGDevelopWebIdeConfigSources() async =>
      distributionAvailable
      ? GDevelopWebIdeConfigSources([configSource])
      : const GDevelopWebIdeConfigSources([]);

  @override
  Future<GDevelopWebIdeReleaseManifest> loadGDevelopWebIdeReleaseManifest(
    NamedDownloadEndpoint selectedSource,
  ) async {
    manifestCalls += 1;
    expect(selectedSource, same(configSource));
    return GDevelopWebIdeReleaseManifest(
      version: '5.6.269',
      sha256: releaseSha256,
      size: 123,
      downloads: [downloadSource],
    );
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyGDevelopWebIdeRelease({
    required GDevelopWebIdeReleaseManifest release,
    required NamedDownloadEndpoint selectedDownload,
    required bool forceRedownload,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    expect(selectedDownload, same(downloadSource));
    forceRedownloadCalls.add(forceRedownload);
    onProgress?.call(
      VerifiedDownloadProgress(
        receivedBytes: release.size,
        totalBytes: release.size,
      ),
    );
    visualAvailable = true;
    installedAt = installedAt.add(const Duration(minutes: 1));
    return GDevelopWebIdeInstallResult(
      marker: (await inspectGDevelopWebIdeInstallation()).marker!,
    );
  }

  @override
  Future<GDevelopWebIdeInstallResult> applyLocalGDevelopWebIdePackage({
    required GDevelopLocalPackageSource source,
    required bool allowMemoryFallback,
    DownloadCancellationToken? cancellationToken,
  }) async {
    localPackageCalls += 1;
    visualAvailable = true;
    installedAt = installedAt.add(const Duration(minutes: 1));
    return GDevelopWebIdeInstallResult(
      marker: (await inspectGDevelopWebIdeInstallation()).marker!,
    );
  }
}

LanEndpointCandidate _lan(Uri uri) => LanEndpointCandidate(
  uri: uri,
  interfaceName: 'Wi-Fi',
  interfaceIndex: 1,
  addressType: LanAddressType.privateIpv4,
  risk: LanEndpointRisk.low,
);

class _DelayedDeveloperProvider extends _FakeDeveloperProvider {
  final Completer<DeveloperSession> _enableCompleter = Completer();

  @override
  Future<DeveloperSession> enableDeveloperMode({
    required int port,
    String? token,
  }) {
    boundPort = port;
    enabledToken = token;
    return _enableCompleter.future;
  }

  void completeEnable() {
    _enableCompleter.complete(_session(port: boundPort, token: enabledToken));
  }
}

class _ReachableProbeHttpClient implements EndpointProbeHttpClient {
  @override
  Future<EndpointProbeHttpResponse> send({
    required String method,
    required Uri url,
    required Map<String, String> headers,
    required Duration timeout,
  }) async => EndpointProbeHttpResponse(statusCode: 204);

  @override
  void close() {}
}

Future<void> _pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  await tester.pump(const Duration(milliseconds: 250));
}
