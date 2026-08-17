part of '../../sdk_feature_registry.dart';

const gameAuthoritySdkSource = SdkSourceFragment(
  id: 'game.authority',
  target: SdkSourceTarget.game,
  order: 45,
  typeScript: r'''  const DEFAULT_AUTHORITY_SERVICE_NAMESPACE =
    "playmesh.authority.default.v1";
  const AUTHORITY_ACTION_ENVELOPE_TYPE = "playmesh.authority.action.v1";
  const authorityServices = new Map();

  function validateAuthorityNamespace(namespace) {
    if (
      typeof namespace !== "string" ||
      !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(namespace)
    ) {
      throw new Error("Authority 服务 namespace 无效");
    }
    return namespace;
  }

  function authorityNamespaceFromOptions(options) {
    if (options === undefined) return DEFAULT_AUTHORITY_SERVICE_NAMESPACE;
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new Error("Authority 服务 options 必须是对象");
    }
    return validateAuthorityNamespace(
      options.namespace === undefined
        ? DEFAULT_AUTHORITY_SERVICE_NAMESPACE
        : options.namespace,
    );
  }

  function encodeAuthorityAction(action, options) {
    // 没有第二参数时保留既有线格式，由接收端归一化到默认 namespace。
    if (options === undefined) return action;
    return {
      __playmeshAuthorityAction: {
        type: AUTHORITY_ACTION_ENVELOPE_TYPE,
        namespace: authorityNamespaceFromOptions(options),
        action,
      },
    };
  }

  function decodeAuthorityAction(payload) {
    const envelope =
      payload &&
      typeof payload === "object" &&
      !Array.isArray(payload) &&
      payload.__playmeshAuthorityAction;
    if (
      !envelope ||
      typeof envelope !== "object" ||
      Array.isArray(envelope) ||
      envelope.type !== AUTHORITY_ACTION_ENVELOPE_TYPE
    ) {
      return {
        namespace: DEFAULT_AUTHORITY_SERVICE_NAMESPACE,
        action: payload,
      };
    }
    return {
      namespace: validateAuthorityNamespace(envelope.namespace),
      action: envelope.action,
    };
  }

  function registerAuthorityService(handler, options) {
    if (!main.session.isAuthority()) {
      throw new Error("只有 Authority Client 可以注册权威服务");
    }
    if (typeof handler !== "function") {
      throw new Error("Authority 服务处理器必须是函数");
    }
    const namespace = authorityNamespaceFromOptions(options);
    if (
      namespace !== DEFAULT_AUTHORITY_SERVICE_NAMESPACE &&
      authorityServices.has(namespace)
    ) {
      throw new Error(`Authority 服务 namespace 已注册: ${namespace}`);
    }
    const registration = { handler };
    authorityServices.set(namespace, registration);
    return function unregister() {
      if (authorityServices.get(namespace) === registration) {
        authorityServices.delete(namespace);
      }
    };
  }

  function normalizeAuthorityResults(output) {
    const normalized = [];
    for (const result of Array.isArray(output) ? output : [output]) {
      if (!result || !Array.isArray(result.targetPlayerIds)) continue;
      const message =
        result.message !== undefined ? result.message : result.payload;
      if (message === undefined) continue;
      normalized.push({ targetPlayerIds: result.targetPlayerIds, message });
    }
    return normalized;
  }

  async function dispatchAuthorityAction(transportMessage) {
    if (await dispatchSyncAuthorityAction(transportMessage)) return;
    const decoded = decodeAuthorityAction(transportMessage.payload);
    const registration = authorityServices.get(decoded.namespace);
    if (!registration) {
      global.console?.warn?.("Playmesh Authority 动作没有已注册的 namespace", {
        namespace: decoded.namespace,
        senderPlayerId: transportMessage.senderPlayerId,
        sessionId: transportMessage.session?.id || null,
      });
      return;
    }
    const context = {
      senderPlayerId: transportMessage.senderPlayerId,
      session: transportMessage.session,
      members: transportMessage.session.players,
    };
    const output = await registration.handler(decoded.action, context);
    for (const result of normalizeAuthorityResults(output)) {
      await post("authority.result", result.message, {
        targetPlayerIds: result.targetPlayerIds,
      });
    }
  }

''',
);
