part of '../../sdk_feature_registry.dart';

const appCoreSdkSource = SdkSourceFragment(
  id: 'app.core',
  target: SdkSourceTarget.app,
  order: 10,
  typeScript: r'''// @ts-ignore
const PLAYMESH_APP_DECLARATION = String.raw`
/// <reference path="./playmesh.d.ts" />

/** App WebView 自动注入的底层对象。游戏业务使用 playmesh.app。 */
declare const playmeshApp: PlaymeshAppApi;
interface Window { playmeshApp: PlaymeshAppApi; }
`;

(function (global) {
  "use strict";

  const PLAYMESH_APP_SDK_VERSION = "3.0.0";
  const PLAYMESH_PLATFORM_UI_CONFIGURATION_KEY =
    typeof Symbol === "function" && typeof Symbol.for === "function"
      ? Symbol.for("playmesh.platform-ui.configuration")
      : "__PLAYMESH_PLATFORM_UI_CONFIGURATION__";

  let sequence = 0;
  let bootstrap = null;
  const pending = new Map();
  const inputListeners = new Set();
  const capabilityInstances = new Map();

  function nativeSender() {
    if (global.PlaymeshAppBridge?.postMessage) {
      return (message) => global.PlaymeshAppBridge.postMessage(message);
    }
    if (global.chrome?.webview) {
      return (message) => global.chrome.webview.postMessage(message);
    }
    return null;
  }

  function request(command, payload = {}) {
    const send = nativeSender();
    if (!send) return Promise.reject(new Error("当前页面不在 Playmesh App WebView 中"));
    const requestId = `app-sdk-${Date.now()}-${++sequence}`;
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`Playmesh App Bridge 请求超时: ${command}`));
      }, 30000);
      pending.set(requestId, { resolve, reject, timer });
      try {
        send(JSON.stringify({
          command,
          requestId,
          sdkVersion: PLAYMESH_APP_SDK_VERSION,
          payload,
        }));
      } catch (error) {
        global.clearTimeout(timer);
        pending.delete(requestId);
        reject(error);
      }
    });
  }

  function clone(value) {
    return value == null ? value : JSON.parse(JSON.stringify(value));
  }

  function receive(rawMessage) {
    const message = typeof rawMessage === "string" ? JSON.parse(rawMessage) : rawMessage;
    if (!message || typeof message !== "object") return;
    if (message.type === "app.device.input") {
      for (const listener of [...inputListeners]) listener(clone(message.input));
      return;
    }
    if (message.type === "app.capability.event") {
      const state = capabilityInstances.get(message.instanceId);
      const listeners = state?.listeners.get(message.event);
      if (listeners) {
        for (const listener of [...listeners]) listener(clone(message.data));
      }
      return;
    }
    if (message.type === "app.capability.error") {
      const state = capabilityInstances.get(message.instanceId);
      if (state?.errorListeners.size) {
        const error = new Error(message.error || "能力插件运行失败");
        for (const listener of [...state.errorListeners]) listener(error);
      } else {
        console.error(`Playmesh 能力实例 ${message.instanceId} 运行失败`, message.error);
      }
      return;
    }
    if (message.type !== "app.command.result" && message.type !== "app.command.error") return;
    const operation = pending.get(message.requestId);
    if (!operation) return;
    pending.delete(message.requestId);
    global.clearTimeout(operation.timer);
    if (message.type === "app.command.error") {
      const error = new Error(message.error || "Playmesh App Bridge 调用失败");
      if (typeof message.code === "string") error.code = message.code;
      operation.reject(error);
    } else {
      operation.resolve(clone(message.result));
    }
  }

''',
);

class _AppCoreFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appCoreSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {'app.bootstrap'};

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) {
    return context.bootstrap(
      command.payload,
      _resolveCommandSdkVersion(SdkSourceTarget.app, command),
    );
  }
}
