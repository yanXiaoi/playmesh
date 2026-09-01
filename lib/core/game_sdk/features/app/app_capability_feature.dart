part of '../../sdk_feature_registry.dart';

const appCapabilitySdkSource = SdkSourceFragment(
  id: 'app.capability',
  target: SdkSourceTarget.app,
  order: 20,
  typeScript: r'''  async function createCapability(code, options = {}) {
    if (typeof code !== "string" || !code) throw new TypeError("能力 code 必须是非空字符串");
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("能力 options 必须是对象");
    }
    if (!bootstrap) throw new Error("请先等待 playmesh.app.ready");
    if (!bootstrap.device?.declaredCapabilities?.includes(code)) {
      throw new Error(`当前游戏未在 capabilities.json 声明 ${code}`);
    }
    if (!bootstrap.device?.capabilities?.includes(code)) {
      throw new Error(`当前设备不支持能力 ${code}`);
    }
    const created = await request("app.capability.create", { code, options });
    const state = {
      id: created.instanceId,
      code,
      apiVersion: created.apiVersion,
      active: true,
      listeners: new Map(),
      errorListeners: new Set(),
    };
    capabilityInstances.set(state.id, state);
    return Object.freeze({
      id: state.id,
      code: state.code,
      apiVersion: state.apiVersion,
      invoke(method, argumentsValue = {}) {
        if (!state.active) return Promise.reject(new Error("能力实例已释放"));
        if (typeof method !== "string" || !method) {
          return Promise.reject(new TypeError("能力方法必须是非空字符串"));
        }
        if (!argumentsValue || typeof argumentsValue !== "object" || Array.isArray(argumentsValue)) {
          return Promise.reject(new TypeError("能力方法参数必须是对象"));
        }
        return request("app.capability.invoke", {
          instanceId: state.id,
          method,
          arguments: argumentsValue,
        });
      },
      on(event, callback) {
        if (!state.active) throw new Error("能力实例已释放");
        if (typeof event !== "string" || !event) throw new TypeError("事件名称必须是非空字符串");
        if (typeof callback !== "function") throw new TypeError("事件回调必须是函数");
        let listeners = state.listeners.get(event);
        if (!listeners) {
          listeners = new Set();
          state.listeners.set(event, listeners);
        }
        listeners.add(callback);
        return () => listeners.delete(callback);
      },
      addEventListener(event, callback) {
        if (!state.active) throw new Error("能力实例已释放");
        if (typeof event !== "string" || !event) throw new TypeError("事件名称必须是非空字符串");
        if (typeof callback !== "function") throw new TypeError("事件回调必须是函数");
        let listeners = state.listeners.get(event);
        if (!listeners) {
          listeners = new Set();
          state.listeners.set(event, listeners);
        }
        listeners.add(callback);
      },
      removeEventListener(event, callback) {
        state.listeners.get(event)?.delete(callback);
      },
      onError(callback) {
        if (typeof callback !== "function") throw new TypeError("错误回调必须是函数");
        state.errorListeners.add(callback);
        return () => state.errorListeners.delete(callback);
      },
      async dispose() {
        if (!state.active) return;
        state.active = false;
        capabilityInstances.delete(state.id);
        state.listeners.clear();
        state.errorListeners.clear();
        await request("app.capability.dispose", { instanceId: state.id });
      },
    });
  }
''',
);

class _AppCapabilityFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appCapabilitySdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'app.capabilities.confirm',
    'app.capability.create',
    'app.capability.invoke',
    'app.capability.dispose',
  };

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    switch (command.name) {
      case 'app.capabilities.confirm':
        return context.confirmCapabilities();
      case 'app.capability.create':
        return context.capabilityRuntime.create(
          command.payload,
          context.sendAppEvent,
        );
      case 'app.capability.invoke':
        return context.capabilityRuntime.invoke(command.payload);
      case 'app.capability.dispose':
        return context.disposeCapability(command.payload);
    }
    throw StateError('未注册的 App 能力命令: ${command.name}');
  }
}
