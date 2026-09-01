part of '../../sdk_feature_registry.dart';

const gameWebRTCSdkSource = SdkSourceFragment(
  id: 'game.webrtc',
  target: SdkSourceTarget.game,
  order: 35,
  typeScript: r'''
  let webRTCSignalingRequestSequence = 0;

  function freezeWebRTCSignalingEndpoint(value, coreBase) {
    if (!value || value.type !== "playmesh.webrtc-signaling-endpoint" ||
        value.version !== 1 || typeof value.identifier !== "string" ||
        typeof value.expiresAt !== "string" ||
        typeof value.playerId !== "string" || typeof value.role !== "string" ||
        typeof value.timestamp !== "number" || typeof value.requestId !== "string") {
      throw new Error("Core 返回了无效的 WebRTC 信令端点");
    }
    let url = typeof value.url === "string" ? value.url : null;
    if (!url && typeof value.webSocketPath === "string" && coreBase) {
      const endpoint = new URL(value.webSocketPath, coreBase);
      endpoint.protocol = endpoint.protocol === "https:" ? "wss:" : "ws:";
      url = endpoint.toString();
    }
    if (!url || !/^wss?:/.test(url)) {
      throw new Error("Core 返回了无效的 WebRTC WebSocket 地址");
    }
    const iceServers = Array.isArray(value.iceServers)
      ? value.iceServers.map((server) => Object.freeze({
          urls: Object.freeze([...(server?.urls || [])].map(String)),
          ...(server?.username ? { username: String(server.username) } : {}),
          ...(server?.credential ? { credential: String(server.credential) } : {}),
        }))
      : [];
    return Object.freeze({
      type: value.type,
      version: value.version,
      timestamp: value.timestamp,
      requestId: value.requestId,
      identifier: value.identifier,
      url,
      expiresAt: value.expiresAt,
      playerId: value.playerId,
      role: value.role,
      iceServers: Object.freeze(iceServers),
    });
  }

  async function getWebRTCSignalingEndpoint(identifier) {
    await main.ready;
    if (!bootstrap?.session) {
      throw new Error("单机模式没有多人会话信令通道");
    }
    if (global.__PLAYMESH_BROWSER__) {
      if (!browserCredential || !browserConnectionConfig?.coreBase) {
        throw new Error("当前浏览器会话凭据不可用");
      }
      const coreBase = browserConnectionConfig.coreBase;
      const timestamp = Date.now();
      const requestId = `webrtc-${timestamp}-${++webRTCSignalingRequestSequence}`;
      const endpointUrl = new URL(
        `v1/sessions/${encodeURIComponent(bootstrap.session.id)}/webrtc/signaling-endpoints`,
        coreBase,
      );
      const response = await fetch(endpointUrl, {
        method: "POST",
        headers: {
          "Authorization": `Bearer ${browserCredential.token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          type: "playmesh.webrtc-signaling-endpoint.request",
          version: 1,
          timestamp,
          requestId,
          identifier,
        }),
      });
      const result = await response.json();
      if (!response.ok) {
        const error = new Error(result?.error?.message || "无法取得 WebRTC 信令端点");
        error.code = result?.error?.code;
        throw error;
      }
      return freezeWebRTCSignalingEndpoint(result, coreBase);
    }
    return freezeWebRTCSignalingEndpoint(
      await post("webrtc.getSignalingEndpoint", { identifier }),
      null,
    );
  }
''',
);

class _GameWebRTCFeature implements _GameSdkCommandFeature {
  @override
  SdkSourceFragment get source => gameWebRTCSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('4.1.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {'webrtc.getSignalingEndpoint'};

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final connection = context.connection;
    if (connection == null) {
      throw const SdkCommandException('session_unavailable', '单机模式没有多人会话信令通道');
    }
    final identifier = sdkRequiredString(command.payload, 'identifier');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$').hasMatch(identifier)) {
      throw const SdkCommandException(
        'invalid_identifier',
        'identifier 必须是 1～128 位安全通道标识',
      );
    }
    return SdkCommandResult(
      await connection.createWebRTCSignalingEndpoint(
        identifier,
        requestId: command.requestId,
      ),
    );
  }
}
