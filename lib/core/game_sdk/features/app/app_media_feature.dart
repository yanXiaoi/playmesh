part of '../../sdk_feature_registry.dart';

const appMediaSdkSource = SdkSourceFragment(
  id: 'app.media',
  target: SdkSourceTarget.app,
  order: 22,
  typeScript: r'''
  const appMediaAdapters = new Map();
  const appMediaSessions = new Map();

  function registerAppMediaAdapter(protocol, adapter) {
    if (typeof protocol !== "string" || !protocol) {
      throw new TypeError("媒体协议必须是非空字符串");
    }
    if (!adapter || typeof adapter.open !== "function") {
      throw new TypeError(`媒体协议 ${protocol} 没有实现 open`);
    }
    if (appMediaAdapters.has(protocol)) {
      throw new Error(`媒体协议重复注册: ${protocol}`);
    }
    appMediaAdapters.set(protocol, Object.freeze(adapter));
  }

  function validateAppMediaSource(source) {
    if (!source || typeof source !== "object" || Array.isArray(source) ||
        source.type !== "playmesh.app.media-source" ||
        source.version !== 1 ||
        typeof source.id !== "string" || !source.id ||
        typeof source.kind !== "string" || !source.kind ||
        typeof source.protocol !== "string" || !source.protocol ||
        source.live !== true) {
      throw new TypeError("媒体源描述符无效");
    }
  }

  async function openAppMedia(source, options = {}) {
    validateAppMediaSource(source);
    if (!options || typeof options !== "object" || Array.isArray(options)) {
      throw new TypeError("媒体打开参数必须是对象");
    }
    if (options.signal !== undefined &&
        (typeof global.AbortSignal !== "function" ||
         !(options.signal instanceof global.AbortSignal))) {
      throw new TypeError("signal 必须是 AbortSignal");
    }
    if (options.signal?.aborted) throw new DOMException("操作已取消", "AbortError");
    const adapter = appMediaAdapters.get(source.protocol);
    if (!adapter) throw new Error(`当前 App SDK 不支持媒体协议 ${source.protocol}`);
    const session = await adapter.open(clone(source), options);
    if (!session || typeof session.id !== "string" || !session.id ||
        typeof global.MediaStream !== "function" ||
        !(session.stream instanceof global.MediaStream) ||
        typeof session.close !== "function") {
      try {
        await session?.close?.();
      } catch (_) {}
      throw new Error(`媒体协议 ${source.protocol} 返回了无效会话`);
    }
    appMediaSessions.set(session.id, session);
    let active = true;
    return Object.freeze({
      id: session.id,
      source: clone(source),
      stream: session.stream,
      get state() {
        return active ? (session.state || "open") : "ended";
      },
      async close() {
        if (!active) return;
        active = false;
        appMediaSessions.delete(session.id);
        await session.close();
      },
    });
  }

  global.addEventListener?.("pagehide", () => {
    const sessions = [...appMediaSessions.values()];
    appMediaSessions.clear();
    for (const session of sessions) {
      try {
        session.close({ notifyHost: false });
      } catch (_) {}
    }
  });
''',
);

class _AppMediaFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appMediaSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('3.1.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {'app.media.open', 'app.media.close'};

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    switch (command.name) {
      case 'app.media.open':
        return context.mediaRuntime.open(command.payload);
      case 'app.media.close':
        await context.mediaRuntime.close(command.payload);
        return null;
    }
    throw StateError('未注册的 App 媒体命令: ${command.name}');
  }
}
