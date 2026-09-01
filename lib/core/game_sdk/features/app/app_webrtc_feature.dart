part of '../../sdk_feature_registry.dart';

const appWebRTCSdkSource = SdkSourceFragment(
  id: 'app.webrtc',
  target: SdkSourceTarget.app,
  order: 29,
  typeScript: r'''
  let appWebRTCSignalingEndpointProvider = null;

  const appWebRTCApi = Object.freeze({
    getSignalingEndpoint(identifier) {
      if (typeof identifier !== "string" ||
          !/^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/.test(identifier)) {
        return Promise.reject(new TypeError(
          "identifier 必须是 1～128 位安全通道标识",
        ));
      }
      if (typeof appWebRTCSignalingEndpointProvider !== "function") {
        return Promise.reject(new Error("当前页面没有可用的多人会话信令通道"));
      }
      return Promise.resolve(appWebRTCSignalingEndpointProvider(identifier));
    },
  });
''',
  declaration: r'''
interface PlaymeshWebRTCIceServer {
  readonly urls: readonly string[];
  readonly username?: string;
  readonly credential?: string;
}

interface PlaymeshWebRTCSignalingEndpoint {
  readonly type: "playmesh.webrtc-signaling-endpoint";
  readonly version: 1;
  /** Core 生成该描述符时的 Unix 毫秒时间戳。 */
  readonly timestamp: number;
  /** 可用于关联本次签发请求的稳定请求 ID。 */
  readonly requestId: string;
  /** 业务通道标识；真实隔离键还包含当前 sessionId 与 Core 认证的 playerId。 */
  readonly identifier: string;
  /** 一次性票据已经写入查询参数的短期 WebSocket 地址。 */
  readonly url: string;
  readonly expiresAt: string;
  readonly playerId: string;
  readonly role: string;
  /** 可直接传给 RTCPeerConnection({ iceServers })。 */
  readonly iceServers: readonly PlaymeshWebRTCIceServer[];
}

interface PlaymeshAppSdk {
  readonly webrtc: {
    /**
     * 获取当前多人会话中受身份约束的通用信令端点。Core 只中转 JSON payload，
     * HTML 自行管理 SDP、ICE、媒体轨道、DataChannel、重启和关闭。
     * @playmesh-completion playmesh.app.webrtc.getSignalingEndpoint
     */
    getSignalingEndpoint(identifier: string): Promise<PlaymeshWebRTCSignalingEndpoint>;
  };
}
''',
);
