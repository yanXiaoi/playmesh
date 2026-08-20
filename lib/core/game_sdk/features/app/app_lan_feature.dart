part of '../../sdk_feature_registry.dart';

/// App Bridge 向网页公开的无凭据局域网游戏投影。
final class AppLanDiscoveredGame {
  const AppLanDiscoveredGame({
    required this.instanceId,
    required this.gameId,
    required this.name,
    required this.host,
  });

  final String instanceId;
  final String gameId;
  final String name;
  final String host;
}

/// 已完成邀请预检、只等待 Bridge 回包后执行的加入动作。
final class AppLanJoinAction {
  const AppLanJoinAction(this.afterResponse);

  final Future<void> Function() afterResponse;
}

/// 当前游戏页提供给 App SDK 的 LAN 宿主能力。
///
/// 实现负责 gameId、Authority、短期发现映射、统一邀请预检及导航；SDK feature 不读取
/// 发现服务、网关、Relay、token 或二维码编码器。
abstract interface class AppLanHost {
  Future<List<AppLanDiscoveredGame>> discoverGames();

  Future<AppLanJoinAction> prepareDiscoveredJoin(String instanceId);

  Future<AppLanJoinAction> prepareInvitationJoin(String invitationUrl);

  Future<AppLanJoinAction> prepareQrJoin();

  Future<void> setPublished();

  Future<GameShareLinkSnapshot> getShareLinks();

  /// WebView 文档、游戏或 Bridge 生命周期切换时清除短期发现映射。
  void resetDocument();
}

const appLanSdkSource = SdkSourceFragment(
  id: 'app.lan',
  target: SdkSourceTarget.app,
  order: 26,
  typeScript: r'''
  function appLanError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function requireAppLanReady() {
    if (!appReadyCompleted) {
      throw appLanError("app_not_ready", "请先等待 playmesh.app.ready");
    }
  }

  function requireAppLanArguments(args, expected, method) {
    if (args.length !== expected) {
      throw appLanError(
        "invalid_argument",
        `${method} 参数数量无效`,
      );
    }
  }

  function requireAppLanAvailable() {
    if (bootstrap?.available !== true) {
      throw appLanError(
        "app_unavailable",
        "当前页面不在 Playmesh App WebView 中",
      );
    }
  }

  function freezeAppLanGame(value) {
    if (!value || typeof value !== "object" ||
        typeof value.instanceId !== "string" || !value.instanceId ||
        typeof value.gameId !== "string" || !value.gameId ||
        typeof value.name !== "string" || !value.name ||
        typeof value.host !== "string" || !value.host) {
      throw appLanError(
        "discovery_unavailable",
        "局域网发现结果无效",
      );
    }
    const instanceId = value.instanceId;
    return Object.freeze({
      instanceId,
      gameId: value.gameId,
      name: value.name,
      host: value.host,
      join: async function () {
        requireAppLanReady();
        requireAppLanArguments(arguments, 0, "PlaymeshLanGame.join");
        requireAppLanAvailable();
        await request("app.lan.joinDiscovered", {
          instanceId,
          userActivation: true,
        });
      },
    });
  }

  function freezeAppLanShareLink(value) {
    if (!value || typeof value !== "object" ||
        typeof value.url !== "string" || !value.url ||
        (value.type !== "lan" && value.type !== "wan") ||
        typeof value.img !== "string" ||
        !value.img.startsWith("data:image/png;base64,")) {
      throw appLanError("share_unavailable", "分享链接结果无效");
    }
    return Object.freeze({
      url: value.url,
      type: value.type,
      img: value.img,
    });
  }

  const appLanApi = Object.freeze({
    async discoverGames() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "discoverGames");
      requireAppLanAvailable();
      const result = await request("app.lan.discover");
      if (!Array.isArray(result)) {
        throw appLanError(
          "discovery_unavailable",
          "局域网发现结果无效",
        );
      }
      return Object.freeze(result.map(freezeAppLanGame));
    },
    async joinByLink(invitationUrl) {
      requireAppLanReady();
      requireAppLanArguments(arguments, 1, "joinByLink");
      if (typeof invitationUrl !== "string" || !invitationUrl.trim()) {
        throw appLanError("invalid_argument", "invitationUrl 必须是非空字符串");
      }
      requireAppLanAvailable();
      await request("app.lan.joinByLink", {
        invitationUrl,
        userActivation: true,
      });
    },
    async scanQrAndJoin() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "scanQrAndJoin");
      requireAppLanAvailable();
      await request("app.lan.scanQr", { userActivation: true });
    },
    async setPublished() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "setPublished");
      requireAppLanAvailable();
      await request("app.lan.setPublished");
    },
    async getShareLinks() {
      requireAppLanReady();
      requireAppLanArguments(arguments, 0, "getShareLinks");
      requireAppLanAvailable();
      const result = await request("app.lan.getShareLinks");
      if (!Array.isArray(result)) {
        throw appLanError("share_unavailable", "分享链接结果无效");
      }
      return Object.freeze(result.map(freezeAppLanShareLink));
    },
  });

''',
  declaration: r'''
type PlaymeshAppLanShareLinkType = "lan" | "wan";

interface PlaymeshAppLanShareLink {
  readonly url: string;
  readonly type: PlaymeshAppLanShareLinkType;
  readonly img: `data:image/png;base64,${string}`;
}

interface PlaymeshLanGame {
  readonly instanceId: string;
  readonly gameId: string;
  readonly name: string;
  readonly host: string;
  /** 加入此发现结果；只能在真实用户操作中调用。 @playmesh-completion playmesh.app.lan.discoverGames.join */
  join(): Promise<void>;
}

interface PlaymeshAppLanApi {
  /** 发现与当前游戏匹配的局域网房间；结果不包含邀请 URL 或 token。 @playmesh-completion playmesh.app.lan.discoverGames */
  discoverGames(): Promise<readonly PlaymeshLanGame[]>;
  /** 通过邀请链接加入；宿主完成预检并在 Bridge 回包后切换页面。 @playmesh-completion playmesh.app.lan.joinByLink */
  joinByLink(invitationUrl: string): Promise<void>;
  /** 扫描二维码并加入；取消扫描会 reject。 @playmesh-completion playmesh.app.lan.scanQrAndJoin */
  scanQrAndJoin(): Promise<void>;
  /** 单向公开当前 Authority 房间；严格无参数且本局幂等。 @playmesh-completion playmesh.app.lan.setPublished */
  setPublished(): Promise<void>;
  /** 读取统一分享快照中的完整链接和 PNG Data URL；本方法没有副作用。 @playmesh-completion playmesh.app.lan.getShareLinks */
  getShareLinks(): Promise<readonly PlaymeshAppLanShareLink[]>;
}

interface PlaymeshAppApi {
  readonly lan: PlaymeshAppLanApi;
}
''',
);

final class _AppLanFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appLanSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('3.3.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'app.lan.discover',
    'app.lan.joinDiscovered',
    'app.lan.joinByLink',
    'app.lan.scanQr',
    'app.lan.setPublished',
    'app.lan.getShareLinks',
  };

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final host = context.lanHost;
    if (host == null) {
      throw const SdkCommandException('game_context_unavailable', '当前游戏上下文不可用');
    }
    switch (command.name) {
      case 'app.lan.discover':
        _requireAppLanPayload(command.payload, const {});
        final games = await _runAppLanOperation(
          host.discoverGames,
          fallbackCode: 'discovery_unavailable',
        );
        return games
            .map(
              (game) => <String, Object?>{
                'instanceId': game.instanceId,
                'gameId': game.gameId,
                'name': game.name,
                'host': game.host,
              },
            )
            .toList(growable: false);
      case 'app.lan.joinDiscovered':
        _rejectUnknownAppLanPayload(command.payload, const {
          'instanceId',
          'userActivation',
        });
        _requireAppLanUserActivation(context, command.payload);
        final instanceId = command.payload['instanceId'];
        if (instanceId is! String ||
            !RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(instanceId)) {
          throw const SdkCommandException('invalid_argument', 'instanceId 无效');
        }
        final action = await _runAppLanOperation(
          () => host.prepareDiscoveredJoin(instanceId),
          fallbackCode: 'discovery_unavailable',
        );
        return AppSdkCommandResponse(afterResponse: action.afterResponse);
      case 'app.lan.joinByLink':
        _rejectUnknownAppLanPayload(command.payload, const {
          'invitationUrl',
          'userActivation',
        });
        _requireAppLanUserActivation(context, command.payload);
        final invitationUrl = command.payload['invitationUrl'];
        if (invitationUrl is! String || invitationUrl.trim().isEmpty) {
          throw const SdkCommandException(
            'invalid_argument',
            'invitationUrl 必须是非空字符串',
          );
        }
        final action = await _runAppLanOperation(
          () => host.prepareInvitationJoin(invitationUrl),
          fallbackCode: 'invalid_invitation',
        );
        return AppSdkCommandResponse(afterResponse: action.afterResponse);
      case 'app.lan.scanQr':
        _rejectUnknownAppLanPayload(command.payload, const {'userActivation'});
        _requireAppLanUserActivation(context, command.payload);
        final action = await _runAppLanOperation(
          host.prepareQrJoin,
          fallbackCode: 'scanner_unavailable',
        );
        return AppSdkCommandResponse(afterResponse: action.afterResponse);
      case 'app.lan.setPublished':
        _requireAppLanPayload(command.payload, const {});
        await _runAppLanOperation(
          host.setPublished,
          fallbackCode: 'discovery_unavailable',
        );
        return null;
      case 'app.lan.getShareLinks':
        _requireAppLanPayload(command.payload, const {});
        final snapshot = await _runAppLanOperation(
          host.getShareLinks,
          fallbackCode: 'share_unavailable',
        );
        return snapshot.links
            .map(
              (link) => <String, Object?>{
                'url': link.url.toString(),
                'type': link.type.name,
                'img': 'data:image/png;base64,${base64Encode(link.pngBytes)}',
              },
            )
            .toList(growable: false);
    }
    throw StateError('未注册的 App LAN 命令: ${command.name}');
  }
}

void _requireAppLanPayload(
  Map<String, Object?> payload,
  Set<String> expectedKeys,
) {
  if (payload.length != expectedKeys.length ||
      !payload.keys.every(expectedKeys.contains)) {
    throw const SdkCommandException('invalid_argument', 'App LAN 命令参数无效');
  }
}

void _rejectUnknownAppLanPayload(
  Map<String, Object?> payload,
  Set<String> allowedKeys,
) {
  if (!payload.keys.every(allowedKeys.contains)) {
    throw const SdkCommandException('invalid_argument', 'App LAN 命令参数无效');
  }
}

void _requireAppLanUserActivation(
  AppSdkCommandContext context,
  Map<String, Object?> payload,
) {
  if (payload['userActivation'] != true || !context.consumeUserActivation()) {
    throw const SdkCommandException('user_activation_required', '加入游戏需要当前用户操作');
  }
}

Future<T> _runAppLanOperation<T>(
  Future<T> Function() operation, {
  required String fallbackCode,
}) async {
  try {
    return await operation();
  } on Object catch (error) {
    throw _sanitizeAppLanError(error, fallbackCode);
  }
}

SdkCommandException _sanitizeAppLanError(Object error, String fallbackCode) {
  final reportedCode = switch (error) {
    SdkCommandException() => error.code,
    GameShareException() => error.code,
    _ => fallbackCode,
  };
  final code = _appLanErrorMessages.containsKey(reportedCode)
      ? reportedCode
      : fallbackCode;
  return SdkCommandException(code, _appLanErrorMessages[code]!);
}

const _appLanErrorMessages = <String, String>{
  'app_unavailable': '当前页面不在 Playmesh App WebView 中',
  'app_not_ready': '请先等待 playmesh.app.ready',
  'invalid_argument': 'App LAN 命令参数无效',
  'game_context_unavailable': '当前游戏上下文不可用',
  'not_authority': '当前页面不是本机房主',
  'user_activation_required': '加入游戏需要当前用户操作',
  'discovery_unavailable': '局域网发现不可用',
  'discovery_not_found': '发现的游戏已失效',
  'invalid_invitation': '邀请链接无效',
  'game_mismatch': '邀请链接属于其他游戏',
  'self_invitation': '不能加入当前主机自己的邀请',
  'scanner_unavailable': '当前平台扫码不可用',
  'cancelled': '用户已取消操作',
  'share_unavailable': '分享链接不可用',
  'share_links_too_large': '分享链接负载超过限制',
  'qr_generation_failed': '分享二维码生成失败',
  'operation_cancelled': '游戏退出，操作已取消',
};
