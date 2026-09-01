/** 取消一个事件、设备或状态订阅。重复调用不会产生新的业务效果。 */
type PlaymeshUnsubscribe = () => void;

/** SDK 可以跨 Bridge、HTTP 或 WebSocket 传输的 JSON 值。不能包含函数、循环引用或类实例。 */
type PlaymeshJson = null | boolean | number | string | PlaymeshJson[] | { [key: string]: PlaymeshJson };
type PlaymeshOrientation = "landscape" | "portrait" | "system";
type PlaymeshDisplayMode = "solo" | "multi_screen" | "single_screen_multiplayer";

/** 当前会话中的玩家。 */
interface PlaymeshPlayer {
  /** 平台分配的稳定玩家 ID。不要相信业务消息中自行上报的玩家 ID。 */
  id: string;
  /** 当前展示昵称，长度为 1～32 个字符。 */
  nickname: string;
  /** App 玩家同步成功后的同源头像路径；未同步及 HTML 玩家为 `null`。 */
  avatar: string | null;
  /** 当前玩家在会话中的参与角色；Authority 资格仍以 `playmesh.main.session.isAuthority()` 为准。 */
  role: "authority" | "authority_player" | "player";
  /** 玩家是否拥有在线连接；离线玩家可以保留在成员列表中等待重连。 */
  connected: boolean;
}

/** 当前对局的只读快照。每次回调都应视为新快照，不要原地修改。 */
interface PlaymeshSessionSnapshot {
  /** 会话 ID。 */
  id: string;
  /** 可分享的局域网联机码；单机环境可能没有。 */
  joinCode?: string;
  /** 当前会话阶段。 */
  state: "lobby" | "running" | "paused" | "stopped";
  /** 固定 Authority Client ID。Authority 不按玩家顺序选举。 */
  authorityClientId: string;
  /** 实际参与游戏的玩家；单屏多人公共主屏不在此数组中。 */
  players: PlaymeshPlayer[];
  /** 开始游戏所需的最少玩家数。 */
  minPlayers: number;
  /** 允许加入的最大玩家数。 */
  maxPlayers?: number;
  [key: string]: unknown;
}

/** 当前页面对应的游戏声明，由 Game SDK 在初始化时统一提供。 */
interface PlaymeshGameInfo {
  /** 稳定的游戏包 ID。 */
  id: string;
  /** 面向玩家显示的游戏名称。 */
  name: string;
  /** 游戏清单中声明的展示标签，最多 5 个。 */
  tags: string[];
  /** 当前页面是否属于多人游戏。 */
  multiplayer: boolean;
  /** 游戏声明的显示模式；单机为 `solo`。 */
  displayMode: PlaymeshDisplayMode;
  /** 当前页面角色声明的能力 code。 */
  requiredCapabilities: string[];
}

/** 玩家连接状态发生变化时的稳定事件载荷。 */
interface PlaymeshPlayerConnectionEvent {
  /** 发生连接变化的玩家。 */
  player: PlaymeshPlayer;
  /** 应用本次变化后的会话快照。 */
  session: PlaymeshSessionSnapshot;
  /** 该玩家是否就是当前页面参与的玩家。 */
  isCurrentPlayer: boolean;
}

/** `await playmesh.main.ready` 的初始化结果。 */
interface PlaymeshBootstrap {
  /** 当前 Game SDK 版本。 */
  sdkVersion: string;
  /** 当前游戏声明。 */
  gameInfo: PlaymeshGameInfo;
  /** 当前页面是否是固定 Authority Client。 */
  isAuthority: boolean;
  /** 当前参与玩家；公共主屏和单机分享页为 `null`。 */
  player: PlaymeshPlayer | null;
  /** 当前多人会话；单机分享页为 `null`。 */
  session: PlaymeshSessionSnapshot | null;
}

/** Authority 处理游戏动作时由平台提供的可信上下文。 */
interface PlaymeshAuthorityContext {
  /** 经过会话验证的发送玩家 ID。 */
  senderPlayerId: string;
  /** 接收动作时的会话快照。 */
  session: PlaymeshSessionSnapshot;
  /** 与 `session.players` 对应的玩家成员。 */
  members: PlaymeshPlayer[];
  [key: string]: unknown;
}

/** Authority 对一次动作的路由结果。 */
interface PlaymeshAuthorityResult {
  /** 接收结果的玩家或 Authority Client ID。 */
  targetPlayerIds: string[];
  /** 推荐使用的业务消息字段。 */
  message?: PlaymeshJson;
  /** 与 `message` 等价的兼容字段；新代码优先使用 `message`。 */
  payload?: PlaymeshJson;
}

/** 为 Authority 动作或服务选择隔离路由。namespace 只是路由标签，不是权限边界。 */
interface PlaymeshAuthorityServiceOptions {
  /** 非空命名空间；建议使用反向域名或产品前缀并带版本。 */
  namespace?: string;
}

/** Authority RPC 请求配置。 */
interface PlaymeshRpcRequestOptions {
  /** 等待 Authority 响应的毫秒数，必须是 100～60000 的整数，默认 10000。 */
  timeoutMs?: number;
}

/** RPC 流请求可发送的字节源。File 继承自 Blob。 */
type PlaymeshRpcStreamSource = Blob | ArrayBuffer | Uint8Array | ReadableStream<Uint8Array>;

/** RPC 流进度。发送端表示已交给网络栈，接收端表示已被 handler 消费。 */
type PlaymeshRpcStreamProgressHandler = (
  transferredBytes: number,
  totalBytes: number | null,
) => void;

/** Authority RPC 流请求配置。 */
interface PlaymeshRpcStreamRequestOptions {
  /** 整个上传与 Authority 处理的超时毫秒数，必须是 1000～1800000 的整数，默认 300000。 */
  timeoutMs?: number;
  /** 流的逻辑文件名；File 默认使用自身名称，其他来源默认 `stream.bin`。 */
  name?: string;
  /** 流的媒体类型；Blob 默认使用自身 type，其他来源默认 `application/octet-stream`。 */
  type?: string;
  /** 监听 source 已交给浏览器网络栈的字节数；回调抛错不会中断传输。 */
  onProgress?: PlaymeshRpcStreamProgressHandler;
}

/** Authority RPC 流监听配置。 */
interface PlaymeshRpcStreamHandlerOptions {
  /** 监听 handler 已消费的字节数；回调抛错不会中断传输。 */
  onProgress?: PlaymeshRpcStreamProgressHandler;
}

/** Authority RPC handler 收到的可信上下文。 */
interface PlaymeshRpcContext extends PlaymeshAuthorityContext {
  /** Core 生成的请求 ID，可用于 Authority 业务日志。 */
  requestId: string;
  /** 已通过 SDK 校验的精确监听路径。 */
  path: string;
}

/** Authority 流请求 handler 收到的可信上下文。 */
interface PlaymeshRpcStreamContext extends PlaymeshRpcContext {
  /** SDK 规范化后的逻辑文件名。 */
  name: string;
  /** SDK 规范化后的媒体类型。 */
  type: string;
  /** 已知的源字节数；ReadableStream 未知长度时为 `null`。 */
  size: number | null;
}

/** Binary Channel 的转发方式。`authority` 先由 Authority 审核，`relay` 直接转发。 */
type PlaymeshBinaryChannelMode = "authority" | "relay";

/** 创建 Binary Channel 的配置。只有 Authority 可以创建。 */
interface PlaymeshBinaryChannelOptions {
  mode: PlaymeshBinaryChannelMode;
}

/** Binary Channel 实际送达消息的可信上下文。 */
interface PlaymeshBinaryMessageContext {
  senderPlayerId: string;
  delivery: "queued" | "latest";
}

/** Authority 审核 Binary Channel 消息时的上下文。 */
interface PlaymeshBinaryForwardContext extends PlaymeshBinaryMessageContext {
  targetPlayerIds: string[];
}

/**
 * Authority Binary Channel 审核器。
 * 返回 `void` 原样通过，返回 `Uint8Array` 替换数据后通过，抛出错误则取消发送。
 */
type PlaymeshBinaryForwardHandler = (
  data: Uint8Array,
  context: PlaymeshBinaryForwardContext,
) => void | Uint8Array | Promise<void | Uint8Array>;

/** 一条复用平台 Binary WebSocket 的逻辑透明字节通道。 */
interface PlaymeshBinaryChannel {
  readonly id: string;
  readonly mode: PlaymeshBinaryChannelMode;
  /** 向当前 Channel 内除自己外的全部在线成员可靠广播。 */
  send(data: Uint8Array): Promise<void>;
  /** 按调用顺序向一个指定玩家发送一帧；Authority mode 会先经过 Authority 审核。 */
  send(targetPlayerId: string, data: Uint8Array): Promise<void>;
  /** 用一个上行帧向多个指定玩家发送相同数据，再由 Core 扇出。 */
  send(targetPlayerIds: readonly string[], data: Uint8Array): Promise<void>;
  /** 同一 Channel、发送者和单个目标尚未发出的旧帧会被最新帧替换。 */
  sendLatest(targetPlayerId: string, data: Uint8Array): Promise<void>;
  /** 多目标最新帧只上传一次，并按每个接收者分别替换尚未发送的旧帧。 */
  sendLatest(targetPlayerIds: readonly string[], data: Uint8Array): Promise<void>;
  /** 向除自己外的全部在线成员广播，只保留每个接收者尚未发送的最新帧。 */
  sendLatest(data: Uint8Array): Promise<void>;
  /** 订阅已经实际送达当前玩家的字节帧。 */
  onMessage(callback: (data: Uint8Array, context: PlaymeshBinaryMessageContext) => void): PlaymeshUnsubscribe;
  /** 注册 Authority 审核器；只有 Authority mode 的 Authority 页面可以调用。 */
  onForward(handler: PlaymeshBinaryForwardHandler): PlaymeshUnsubscribe;
  /** 关闭整个 Channel；只有 Authority 可以调用。 */
  close(): Promise<void>;
}

/** `playmesh.main.sync` 发布的完整权威状态快照。 */
interface PlaymeshSyncSnapshot<T = PlaymeshJson> {
  protocolVersion: 1;
  stateType: string;
  full: true;
  revision: number;
  sequence: number;
  timestamp: number;
  sourceTick: number;
  state: T;
  [key: string]: unknown;
}

/** `onInput` 收到的可信输入上下文。 */
interface PlaymeshSyncInputContext<T> {
  senderPlayerId: string;
  session: PlaymeshSessionSnapshot;
  members: PlaymeshPlayer[];
  state: T;
  inputId: string;
  inputType: "action" | "state";
  key: string | null;
  receivedAt: number;
}

/** Authority 定时更新回调的参数。 */
interface PlaymeshSyncTickContext<T> {
  state: T;
  inputs: Record<string, Record<string, { value: PlaymeshJson; inputId: string; receivedAt: number }>>;
  tick: number;
  /** 距离上一 tick 的秒数，范围被限制在 0～1。 */
  dt: number;
  now: number;
  session: PlaymeshSessionSnapshot;
  members: PlaymeshPlayer[];
}

/** 启动 Authority 状态同步的配置。只能在 `playmesh.main.session.isAuthority()` 为 true 时调用。 */
interface PlaymeshSyncAuthorityOptions<T> {
  /** 首个完整权威状态，必须可 JSON 序列化。 */
  initialState: T;
  /** 状态类型标识，默认 `game`。 */
  stateType?: string;
  /** 每秒 tick 次数，必须是 1～60 的整数，默认 10。 */
  tickRate?: number;
  /** 收到一次性动作或合并状态输入时更新权威状态；返回 `void` 表示保持原状态。 */
  onInput?: (input: PlaymeshJson, context: PlaymeshSyncInputContext<T>) => T | void | Promise<T | void>;
  /** 每个 Authority tick 更新状态；返回 `void` 表示保持原状态。 */
  onTick?: (context: PlaymeshSyncTickContext<T>) => T | void | Promise<T | void>;
}

/** Authority 公共状态同步控制器。 */
interface PlaymeshSyncAuthorityController<T = PlaymeshJson> {
  /** 返回当前 Authority runtime 公共状态的 JSON 副本。 */
  getState(): T;
  /**
   * 整体替换当前公共状态。真实变化按 `tickRate` 窗口合并、去重并串行自动发布。
   * `publish` 默认为 true，使 Promise 等待对应自动发布流程结算为快照或 null；发送失败时拒绝。
   * 传 false 时立即返回 null，状态变化仍可由后续自动发布窗口同步。
   */
  setState(state: T, publish?: boolean): Promise<PlaymeshSyncSnapshot<T> | null>;
  /**
   * 每次调用都在调用时独立构造当前完整公共状态快照并立即发起发送；多次调用可并发执行。
   * `targetPlayerIds` 选择接收者；省略时选择 Authority Client 和 Session players。
   */
  publish(targetPlayerIds?: string[]): Promise<PlaymeshSyncSnapshot<T> | null>;
  /**
   * 在同一调用中整体替换公共状态、使 `getState()` 立即可读，再为同一状态构造快照并发起发送。
   * `targetPlayerIds` 选择接收者；state 为字符串数组时显式传入第二参数（可为 undefined）以选择此重载。
   */
  publish(state: T, targetPlayerIds?: string[]): Promise<PlaymeshSyncSnapshot<T> | null>;
  /**
   * 停止当前页面的 tick 与同步 runtime，并取消尚未执行的自动发布任务；已发起的发送继续结算。
   * 后续同步通过重新调用 `startAuthority` 启动；Session 生命周期保持独立。
   */
  stop(): void;
}

/** 游戏生命周期事件。 */
interface PlaymeshLifecycleEvent {
  state: "ready" | "pause" | "resume" | "exit" | "closed" | "error";
  error?: string;
  [key: string]: unknown;
}

/** App 自动注入的持久身份。普通浏览器中不可用。 */
interface PlaymeshAppIdentity {
  userId: string;
  nickname: string;
  source: string;
}

/** 加速度计或陀螺仪的一次采样。 */
interface PlaymeshCapabilityMethodDefinition {
  name: string;
  description: string;
  requiresUserActivation?: boolean;
  argumentsSchema: { [key: string]: PlaymeshJson };
  resultSchema: { [key: string]: PlaymeshJson };
}

interface PlaymeshCapabilityEventDefinition {
  name: string;
  description: string;
  dataSchema: { [key: string]: PlaymeshJson };
}

type PlaymeshCapabilityPlatform = "WINDOWS" | "ANDROID" | "HTML";

/** 全平台注册表中的能力插件元数据。 */
interface PlaymeshCapabilityDefinition {
  code: string;
  name: string;
  description: string;
  apiVersion: string;
  supportedPlatforms: PlaymeshCapabilityPlatform[];
  optionsSchema: { [key: string]: PlaymeshJson };
  methods: PlaymeshCapabilityMethodDefinition[];
  events: PlaymeshCapabilityEventDefinition[];
}

/** `await playmesh.app.ready` 返回的当前终端初始化结果。 */
interface PlaymeshAppBootstrap {
  /** 当前页面是否连接到 Playmesh App 原生 Bridge。 */
  readonly available: boolean;
  /** 当前 App Bridge SDK 版本。 */
  readonly sdkVersion: "3.5.0";
  /** App 自动注入的本机身份；普通浏览器为 `null`。 */
  readonly identity: PlaymeshAppIdentity | null;
  /** App 提供的受控运行环境；普通浏览器为 `null`。 */
  readonly runtime: {
    readonly coreBase?: string;
    readonly playerSource?: string;
  } | null;
  /** 当前终端的能力插件注册表。 */
  readonly capabilityRegistry: PlaymeshCapabilityDefinition[];
  /** 当前终端的平台与本次页面能力声明。 */
  readonly device: {
    readonly platform: string;
    readonly capabilities: string[];
    readonly declaredCapabilities: string[];
  };
}

/** 由 `playmesh.app.capabilities.create()` 创建的有状态能力实例。 */
interface PlaymeshCapabilityHandle {
  readonly id: string;
  readonly code: string;
  readonly apiVersion: string;
  invoke<T = PlaymeshJson>(method: string, args?: { [key: string]: PlaymeshJson }): Promise<T>;
  on(event: string, callback: (data: { [key: string]: PlaymeshJson }) => void): PlaymeshUnsubscribe;
  /** DOM 风格的事件订阅别名；已有 `on()` 保持兼容。 */
  addEventListener(event: string, callback: (data: { [key: string]: PlaymeshJson }) => void): void;
  removeEventListener(event: string, callback: (data: { [key: string]: PlaymeshJson }) => void): void;
  onError(callback: (error: Error) => void): PlaymeshUnsubscribe;
  dispose(): Promise<void>;
}

/** 由终端能力签发、只能交给 `playmesh.app.media.open()` 的实时媒体源。 */
interface PlaymeshAppMediaSource {
  readonly type: "playmesh.app.media-source";
  readonly version: 1;
  readonly id: string;
  readonly kind: "video" | "audio" | "audio-video";
  readonly protocol: string;
  readonly live: true;
  readonly [key: string]: PlaymeshJson;
}

interface PlaymeshAppMediaOpenOptions {
  /** 取消仍在进行的媒体协商。 */
  signal?: AbortSignal;
}

/** 当前 WebView 对一个终端媒体源的消费会话。 */
interface PlaymeshAppMediaSession {
  readonly id: string;
  readonly source: PlaymeshAppMediaSource;
  readonly stream: MediaStream;
  readonly state: "opening" | "open" | "ended" | "failed";
  close(): Promise<void>;
}

interface PlaymeshAppMediaApi {
  /** 打开能力签发的媒体源；具体传输协议由已注册终端适配器处理。 @playmesh-completion playmesh.app.media.open */
  open(
    source: PlaymeshAppMediaSource,
    options?: PlaymeshAppMediaOpenOptions,
  ): Promise<PlaymeshAppMediaSession>;
}

/** `playmesh.main.storage.getBucket()` 返回的 Authority 主机存储分区。 */
interface PlaymeshStorageBucket {
  /** 读取 key；不存在时返回 `null`。key 长度 1～128，只允许字母、数字、点、下划线和连字符。 */
  getData<T = PlaymeshJson>(key: string): Promise<T | null>;
  /** 写入 JSON 值；单值序列化后不能超过宿主限制。 */
  setData(key: string, value: PlaymeshJson): Promise<void>;
  /** 通过局域网同源 Bucket 网关阻塞读取 JSON；不存在时返回 `null`。 */
  getDataSync<T = PlaymeshJson>(key: string): T | null;
  /** 通过局域网同源 Bucket 网关阻塞写入 JSON；返回时 App 内存状态已提交。 */
  setDataSync(key: string, value: PlaymeshJson): void;
  /** 删除一个 key。 */
  removeData(key: string): Promise<void>;
  /** 清空当前 Bucket，不影响其他 Bucket。 */
  clearData(): Promise<void>;
  /** 上传二进制文件；平台以毫秒时间戳重命名并保留安全后缀，返回同源 `/bucket/...` 地址。 */
  upload(file: File): Promise<string>;
  /**
   * 流式上传字节源。ReadableStream 必须通过 options.name 提供文件名；实现只保留固定
   * 大小缓冲并传播背压，不会把完整文件装入内存。
   */
  upload(source: PlaymeshRpcStreamSource, options: { name: string; type?: string }): Promise<string>;
}

interface PlaymeshAppUiOptions {
  /** 是否由 SDK 渲染兜底游戏菜单、信息和日志覆盖层；默认 `true`。 */
  fallbackUi?: boolean;
  /** 普通浏览器是否显示可拖动的悬浮菜单按钮；默认 `true`。 */
  floatingButton?: boolean;
}

/** Android 系统返回、桌面返回键或浏览器悬浮菜单触发后的后续流程决策。 */
type PlaymeshSystemMenuDecision = "EXIT" | "NEXT" | "STOP";
/** @deprecated 使用 `PlaymeshSystemMenuDecision`。 */
type PlaymeshAppBackDecision = PlaymeshSystemMenuDecision;

interface PlaymeshAppUiApi {
  /** 浏览器专用初始化：启用兜底游戏菜单但不创建悬浮球；App WebView 中返回 `false`。 @playmesh-completion playmesh.app.ui.initializeBrowser */
  initializeBrowser(): boolean;
  /** 配置 SDK 兜底 UI；应在等待 `playmesh.app.ready` 前调用。 @playmesh-completion playmesh.app.ui.configure */
  configure(options: PlaymeshAppUiOptions): PlaymeshAppUiOptions;
  /** 手动打开 SDK 居中游戏菜单；方法名为兼容公开契约保留，禁用兜底 UI 时返回 `false`。 @playmesh-completion playmesh.app.ui.showGameSidebar */
  showGameSidebar(): Promise<boolean>;
  /** 订阅 SDK 游戏菜单成功打开事件；只在关闭到打开的真实状态变化后触发。 @playmesh-completion playmesh.app.ui.onGameMenuOpen */
  onGameMenuOpen(callback: () => void): PlaymeshUnsubscribe;
  /** 订阅 SDK 游戏菜单成功关闭事件；只在打开到关闭的真实状态变化后触发。 @playmesh-completion playmesh.app.ui.onGameMenuClose */
  onGameMenuClose(callback: () => void): PlaymeshUnsubscribe;
  /**
   * 订阅 Android 系统返回、桌面返回键和浏览器悬浮菜单入口；入口事件到达后、产生默认效果前执行回调。
   * `EXIT` 直接退出，`NEXT` 继续该入口的默认流程（仍遵守 `fallbackUi`），`STOP` 终止后续流程。
   * 多个回调会全部执行；`STOP` 优先于 `EXIT`，`EXIT` 优先于 `NEXT`。 @playmesh-completion playmesh.app.ui.onSystemMenuRequest
   */
  onSystemMenuRequest(
    callback: () => PlaymeshSystemMenuDecision |
      Promise<PlaymeshSystemMenuDecision>,
  ): PlaymeshUnsubscribe;
  /**
   * @deprecated 使用 `onSystemMenuRequest()`；此兼容别名具有完全相同的触发与决策语义。
   * @playmesh-completion playmesh.app.ui.onBack
   */
  onBack(
    callback: () => PlaymeshAppBackDecision |
      Promise<PlaymeshAppBackDecision>,
  ): PlaymeshUnsubscribe;
  /** 重新加载当前游戏文档。 @playmesh-completion playmesh.app.ui.restartGame */
  restartGame(): void;
  /** 打开“分享/邀请”；仅当前 Authority 可在有效用户操作中调用。 @playmesh-completion playmesh.app.ui.openSharePanel */
  openSharePanel(): Promise<void>;
  /** 打开 SDK 运行日志覆盖层。 @playmesh-completion playmesh.app.ui.openRuntimeLogs */
  openRuntimeLogs(): Promise<boolean>;
  /** 进入全屏；system 表示解除已有方向锁并跟随系统。 @playmesh-completion playmesh.app.ui.enterFullscreen */
  enterFullscreen(orientation?: PlaymeshOrientation): Promise<unknown>;
  /** 退出全屏。 @playmesh-completion playmesh.app.ui.exitFullscreen */
  exitFullscreen(): Promise<unknown>;
  /** 打开 SDK 游戏信息覆盖层。 @playmesh-completion playmesh.app.ui.openGameInfo */
  openGameInfo(): Promise<boolean>;
  /** 显示或隐藏 SDK 性能浮层。 @playmesh-completion playmesh.app.ui.setPerformanceVisible */
  setPerformanceVisible(visible: boolean): boolean;
  /** 切换 SDK 性能浮层。 @playmesh-completion playmesh.app.ui.togglePerformance */
  togglePerformance(): boolean;
  /** 结束当前游戏。 @playmesh-completion playmesh.app.ui.exitGame */
  exitGame(): Promise<void>;
}

/** App Bridge 与统一平台 UI 能力。App WebView 和普通浏览器都会注入。 */
interface PlaymeshAppApi {
  /** 当前 App Bridge SDK 版本。 */
  readonly version: "3.5.0";
  /** App Bridge 完成身份和能力插件注册表注入后 resolve；原生 Bridge 失败时 reject。 */
  readonly ready: Promise<PlaymeshAppBootstrap>;
  /** 当前页面是否运行在具有 App Bridge 的 Playmesh WebView 中。 @playmesh-completion playmesh.app.isAvailable */
  isAvailable(): boolean;
  readonly identity: {
    /** 返回 App 自动注入的当前用户；普通浏览器返回 `null`。 @playmesh-completion playmesh.app.identity.getCurrent */
    getCurrent(): PlaymeshAppIdentity | null;
  };
  /** 当前客户端只读运行环境；不包含平台 UI 词典。 */
  readonly runtime: {
    /** 返回实际显示该页面的 App locale；普通浏览器按浏览器语言解析，失败时返回 `zh`。 @playmesh-completion playmesh.app.runtime.getLocale */
    getLocale(): string;
  };
  /** 当前客户端游戏页的渲染与联机观测指标。不得用于权威玩法判定。 */
  readonly performance: {
    /** 返回当前页面最近 FPS；尚未形成统计窗口时返回 `null`。 @playmesh-completion playmesh.app.performance.getFps */
    getFps(): number | null;
    /** 订阅当前页面 FPS；注册后立即回调当前值。 @playmesh-completion playmesh.app.performance.onFps */
    onFps(callback: (fps: number | null) => void): PlaymeshUnsubscribe;
    /** 返回当前参与端到 Authority 的最近平滑 RTT 毫秒数；单机或 Authority 不在线时返回 `null`。 @playmesh-completion playmesh.app.performance.getLatency */
    getLatency(): number | null;
    /** 返回当前参与端最近延迟探测诊断数据；游戏规则不得依赖该数据判定胜负。 @playmesh-completion playmesh.app.performance.getLatencyDiagnostics */
    getLatencyDiagnostics(): Record<string, unknown> | null;
    /** 订阅当前参与端到 Authority 的延迟毫秒数。 @playmesh-completion playmesh.app.performance.onLatency */
    onLatency(callback: (latency: number | null) => void): PlaymeshUnsubscribe;
    /** 显示或隐藏当前客户端的 SDK 性能浮层。 @playmesh-completion playmesh.app.performance.setVisible */
    setVisible(visible: boolean): void;
    /** 当前页面在真实画面完成后报告一帧；返回最近 FPS。SDK 不会自行启动 RAF。 @playmesh-completion playmesh.app.performance.reportFrame */
    reportFrame(timestamp?: number): number | null;
  };
  readonly capabilities: {
    /** 返回全平台注册表。 @playmesh-completion playmesh.app.capabilities.getRegistry */
    getRegistry(): PlaymeshCapabilityDefinition[];
    /** 返回当前宿主实际可用且已由项目声明的能力 code。 @playmesh-completion playmesh.app.capabilities.getAvailable */
    getAvailable(): string[];
    /** 返回当前页面角色在 `capabilities.json` 中声明的能力 code。 @playmesh-completion playmesh.app.capabilities.getDeclared */
    getDeclared(): string[];
    /** 创建一个有状态能力实例。 @playmesh-completion playmesh.app.capabilities.create */
    create(code: string, options?: { [key: string]: PlaymeshJson }): Promise<PlaymeshCapabilityHandle>;
  };
  /** 当前终端的协议无关音视频消费入口。 */
  readonly media: PlaymeshAppMediaApi;
  readonly device: {
    /** 返回宿主平台名称，例如 `android` 或 `windows`；普通浏览器返回 `null`。 @playmesh-completion playmesh.app.device.getPlatform */
    getPlatform(): string | null;
    /** 请求 App WebView 进入或退出全屏；进入时可锁定横屏/竖屏，system 表示解除已有方向锁并跟随系统。 @playmesh-completion playmesh.app.device.setFullscreen */
    setFullscreen(enabled: boolean, orientation?: PlaymeshOrientation): Promise<unknown>;
    /** 订阅 App 统一输入事件。 @returns 取消订阅函数。 @playmesh-completion playmesh.app.device.onInput */
    onInput(callback: (input: unknown) => void): PlaymeshUnsubscribe;
  };
  /** 统一居中游戏菜单及其全部动作。 */
  readonly ui: PlaymeshAppUiApi;
}

/** 游戏本体与对局公开 API。所有页面先等待 `playmesh.main.ready`。 */
interface PlaymeshMainApi {
  /** 当前 Game SDK 版本。 */
  readonly version: "4.3.0";
  /** SDK、身份、能力确认和会话完成初始化后 resolve；初始化失败时 reject。 */
  readonly ready: Promise<PlaymeshBootstrap>;
  /** 当前页面对应的游戏声明。 */
  readonly gameInfo: {
    /** 返回 Game SDK 初始化后的只读游戏信息；尚未就绪时返回 `null`。 @playmesh-completion playmesh.main.gameInfo.getCurrent */
    getCurrent(): PlaymeshGameInfo | null;
  };
  /** 对局状态、Authority 身份和玩家成员事件。 */
  readonly session: {
    /** 订阅会话快照；注册后若已就绪会立即回调。 @returns 取消订阅函数。 @playmesh-completion playmesh.main.session.onStateChange */
    onStateChange(callback: (session: PlaymeshSessionSnapshot | null) => void): PlaymeshUnsubscribe;
    /** 玩家第一次加入时回调。重连不会重复触发本事件。 @playmesh-completion playmesh.main.session.onPlayerJoin */
    onPlayerJoin(callback: (event: PlaymeshPlayerConnectionEvent) => void): PlaymeshUnsubscribe;
    /** 玩家连接断开时回调；成员可能仍留在会话中。 @playmesh-completion playmesh.main.session.onPlayerLeave */
    onPlayerLeave(callback: (event: PlaymeshPlayerConnectionEvent) => void): PlaymeshUnsubscribe;
    /** 离线玩家使用相同 ID 恢复连接时回调。 @playmesh-completion playmesh.main.session.onPlayerReconnect */
    onPlayerReconnect(callback: (event: PlaymeshPlayerConnectionEvent) => void): PlaymeshUnsubscribe;
    /** 当前页面是否是固定 Authority Client。不要根据 `players[0]` 推断。 @playmesh-completion playmesh.main.session.isAuthority */
    isAuthority(): boolean;
    /** 返回最近会话快照；单机分享页或尚未就绪时返回 `null`。 @playmesh-completion playmesh.main.session.getCurrent */
    getCurrent(): PlaymeshSessionSnapshot | null;
    /** 仅请求 Core 切换为运行状态；准备、倒计时和玩法条件由游戏 Authority 判断。 @playmesh-completion playmesh.main.session.start */
    start(): Promise<PlaymeshSessionSnapshot>;
    /** 仅在游戏规则确认结束后请求 Core 停止会话并清理离线成员；SDK 不判断胜负。 @playmesh-completion playmesh.main.session.finish */
    finish(): Promise<PlaymeshSessionSnapshot>;
  };
  /** 当前参与玩家资料。 */
  readonly player: {
    /** 返回当前玩家；公共 Authority 主屏和单机分享页返回 `null`。 @playmesh-completion playmesh.main.player.getCurrent */
    getCurrent(): PlaymeshPlayer | null;
    /** 修改当前玩家昵称，去除首尾空白后必须为 1～32 个字符。 @playmesh-completion playmesh.main.player.setNickname */
    setNickname(nickname: string): Promise<PlaymeshPlayer>;
  };
  /** 自定义低层游戏消息。普通多人游戏优先使用 `playmesh.main.sync`。 */
  readonly game: {
    /** 向 Authority 提交 JSON 业务动作；发送者身份由平台附加。 @playmesh-completion playmesh.main.game.submitAction */
    submitAction(action: PlaymeshJson, options?: PlaymeshAuthorityServiceOptions): Promise<unknown>;
    /** 订阅 Authority 发给当前客户端的 JSON 消息。 @playmesh-completion playmesh.main.game.onMessage */
    onMessage(callback: (message: PlaymeshJson) => void): PlaymeshUnsubscribe;
    /** `onMessage` 的兼容别名；新代码优先使用 `onMessage`。 @playmesh-completion playmesh.main.game.onEvent */
    onEvent(callback: (message: PlaymeshJson) => void): PlaymeshUnsubscribe;
  };
  /** 自定义 Authority 动作处理。只有 Authority Client 可以注册。 */
  readonly authority: {
    /** 未传 options 时使用的稳定默认 namespace。 */
    readonly defaultNamespace: "playmesh.authority.default.v1";
    /**
     * 注册权威动作处理器。规则、分数和胜负应在这里决定，不能信任动作中自报的身份。
     * @returns 取消注册函数。
     * @playmesh-completion playmesh.main.authority.onService
     */
    onService(handler: (action: PlaymeshJson, context: PlaymeshAuthorityContext) => PlaymeshAuthorityResult | PlaymeshAuthorityResult[] | null | undefined | Promise<PlaymeshAuthorityResult | PlaymeshAuthorityResult[] | null | undefined>, options?: PlaymeshAuthorityServiceOptions): PlaymeshUnsubscribe;
  };
  /** 由固定 Authority Client 审核和响应的请求/响应通道。 */
  readonly rpc: {
    /**
     * 向 Authority 指定 path 发起异步请求。支持 JSON 兼容值、Blob、File、
     * ArrayBuffer 和 Uint8Array；Promise 只在 Authority handler 返回结果后完成；
     * 客户端超时不会撤销已经开始执行的 Authority handler。
     * @playmesh-completion playmesh.main.rpc.request
     */
    request(path: string, data?: any, options?: PlaymeshRpcRequestOptions): Promise<any>;
    /**
     * 向 Authority 发起字节流请求。File、Blob 和内存字节会由 SDK 自动建立请求体；
     * ReadableStream 会原样转交给浏览器流式发送。结束由流 EOF 表示。
     * @playmesh-completion playmesh.main.rpc.requestStream
     */
    requestStream(path: string, source: PlaymeshRpcStreamSource, options?: PlaymeshRpcStreamRequestOptions): Promise<any>;
    /**
     * 监听一个精确 RPC path。只有 Authority Client 可以调用；handler 可以同步返回
     * 可传输值，也可以返回 Promise。
     * @returns 取消监听函数。
     * @playmesh-completion playmesh.main.rpc.onRequest
     */
    onRequest(path: string, handler: (data: any, context: PlaymeshRpcContext) => any | Promise<any>): PlaymeshUnsubscribe;
    /**
     * 监听一个精确 RPC 流 path。只有 Authority Client 可以调用；流只能消费一次。
     * @returns 取消监听函数。
     * @playmesh-completion playmesh.main.rpc.onStreamRequest
     */
    onStreamRequest(path: string, handler: (source: ReadableStream<Uint8Array>, context: PlaymeshRpcStreamContext) => any | Promise<any>, options?: PlaymeshRpcStreamHandlerOptions): PlaymeshUnsubscribe;
  };
  /** 多人会话内的透明二进制分发。SDK 按需维护一条受平台管控的 Binary WebSocket。 */
  readonly binary: {
    /** Authority 在所有 Binary Channel 中使用的固定玩家 ID。 */
    readonly authorityPlayerId: "authority";
    /** 创建逻辑 Channel；只有 Authority 可以调用。 @playmesh-completion playmesh.main.binary.createChannel */
    createChannel(options: PlaymeshBinaryChannelOptions): Promise<PlaymeshBinaryChannel>;
    /** 使用 Authority 分享的 Channel ID 加入逻辑 Channel。 @playmesh-completion playmesh.main.binary.joinChannel */
    joinChannel(channelId: string): Promise<PlaymeshBinaryChannel>;
  };
  /** 完整权威状态同步、输入限频与快照订阅。 */
  readonly sync: {
    /** 仅 Authority 启动状态同步；同一页面同时只能有一个同步 runtime。 @playmesh-completion playmesh.main.sync.startAuthority */
    startAuthority<T = PlaymeshJson>(options: PlaymeshSyncAuthorityOptions<T>): PlaymeshSyncAuthorityController<T>;
    /** 提交一次性语义输入，返回生成的 input ID。 @playmesh-completion playmesh.main.sync.submitAction */
    submitAction(payload: PlaymeshJson): Promise<string>;
    /** 同一 key 只保留最新连续输入；`rateHz` 必须为 1～60。 @playmesh-completion playmesh.main.sync.submitState */
    submitState(key: string, value: PlaymeshJson, options?: { rateHz?: number }): Promise<null>;
    /** 请求 Authority 立即向当前玩家发送最新完整快照。 @playmesh-completion playmesh.main.sync.requestSnapshot */
    requestSnapshot(): Promise<string>;
    /** 返回最近完整快照；尚未收到时返回 `null`。 @playmesh-completion playmesh.main.sync.getSnapshot */
    getSnapshot<T = PlaymeshJson>(): PlaymeshSyncSnapshot<T> | null;
    /** 订阅完整快照；已有快照时注册后立即回调。 @playmesh-completion playmesh.main.sync.observe */
    observe<T = PlaymeshJson>(callback: (snapshot: PlaymeshSyncSnapshot<T>) => void): PlaymeshUnsubscribe;
  };
  /** WebView 暂停、恢复、退出和错误事件。 */
  readonly lifecycle: {
    /** 订阅全部生命周期事件。 @playmesh-completion playmesh.main.lifecycle.onChange */
    onChange(callback: (event: PlaymeshLifecycleEvent) => void): PlaymeshUnsubscribe;
    /** 仅订阅暂停事件。 @playmesh-completion playmesh.main.lifecycle.onPause */
    onPause(callback: (event: PlaymeshLifecycleEvent) => void): PlaymeshUnsubscribe;
    /** 仅订阅恢复事件。 @playmesh-completion playmesh.main.lifecycle.onResume */
    onResume(callback: (event: PlaymeshLifecycleEvent) => void): PlaymeshUnsubscribe;
    /** 订阅退出事件；允许返回 Promise，宿主只会有限等待。 @playmesh-completion playmesh.main.lifecycle.onExit */
    onExit(callback: (event: PlaymeshLifecycleEvent) => void | Promise<void>): PlaymeshUnsubscribe;
  };
  /** Authority 主机上的持久 Bucket；只有 Authority 页面可读写，宿主后台会拒绝远程玩家。 */
  readonly storage: {
    /** 获取 Bucket；异步方法保持原 64 字符名称规则，同步方法另支持 1～4096 UTF-8 字节的逻辑名。 @playmesh-completion playmesh.main.storage.getBucket */
    getBucket(bucket: string): PlaymeshStorageBucket;
  };
}

interface PlaymeshReadyResult {
  readonly main: PlaymeshBootstrap;
  /** 与 `await playmesh.app.ready` 严格相同的稳定结果引用。 */
  readonly app: PlaymeshAppBootstrap;
}

/** Playmesh 游戏页面的公开根对象；根级只提供聚合就绪状态及 main/app 分区。 */
interface PlaymeshApi {
  /** 复用 `playmesh.main.ready` 初始化链并返回游戏本体与当前客户端结果。 */
  readonly ready: Promise<PlaymeshReadyResult>;
  readonly main: PlaymeshMainApi;
  readonly app: PlaymeshAppApi;
}

/** 游戏页面使用的全局 Playmesh SDK。 */
declare const playmesh: PlaymeshApi;
interface Window { playmesh: PlaymeshApi; }

/** SQLite 可传输参数和结果值。超出 JavaScript 安全整数范围的 INTEGER 以十进制字符串返回。 */
type PlaymeshDatabaseValue = null | number | string | readonly number[];
type PlaymeshDatabaseParameter = null | boolean | number | string;
type PlaymeshDatabaseArguments = readonly PlaymeshDatabaseParameter[] |
  Readonly<Record<string, PlaymeshDatabaseParameter>>;

interface PlaymeshDatabaseChangeResult {
  readonly changes: number;
}

interface PlaymeshDatabaseInsertResult extends PlaymeshDatabaseChangeResult {
  readonly lastInsertRowId: string;
}

interface PlaymeshDatabaseDdl {
  readonly type: "table" | "index";
  readonly name: string;
  readonly tableName: string;
  readonly sql: string;
}

interface PlaymeshDatabaseTransaction {
  /** 使用预编译语句查询；支持位置占位符和命名占位符，参数不会拼接到 SQL。 */
  select<T extends Record<string, PlaymeshDatabaseValue> = Record<string, PlaymeshDatabaseValue>>(sql: string, args?: PlaymeshDatabaseArguments): Promise<T[]>;
  /** 执行 UPDATE 或受支持的表/索引 DDL。 */
  update(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行 DELETE。 */
  delete(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行 INSERT 或 REPLACE。 */
  insert(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseInsertResult>;
  /** 返回事务连接内的原生表/索引 DDL；传名称时返回该表及其索引。 */
  getDDL(name?: string): Promise<PlaymeshDatabaseDdl[]>;
  commit(): Promise<void>;
  rollback(): Promise<void>;
}

interface PlaymeshDatabaseApi {
  /** 打开或创建当前游戏 `data/db/` 目录下固定的 `_game.db`。 @playmesh-completion playmesh.main.db.open */
  open(): Promise<{ readonly file: "_game.db" }>;
  /** 使用预编译语句查询；数组绑定 `?`/`?NNN`。对象键 `name` 绑定 `:name`，也可传完整的 `:name`/`@name`/`$name`。 @playmesh-completion playmesh.main.db.select */
  select<T extends Record<string, PlaymeshDatabaseValue> = Record<string, PlaymeshDatabaseValue>>(sql: string, args?: PlaymeshDatabaseArguments): Promise<T[]>;
  /** 执行表级写 SQL。 @playmesh-completion playmesh.main.db.update */
  update(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行表级写 SQL。 @playmesh-completion playmesh.main.db.delete */
  delete(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseChangeResult>;
  /** 执行表级写 SQL。 @playmesh-completion playmesh.main.db.insert */
  insert(sql: string, args?: PlaymeshDatabaseArguments): Promise<PlaymeshDatabaseInsertResult>;
  /** 返回原生表/索引 DDL；传名称时返回该表及其索引。 @playmesh-completion playmesh.main.db.getDDL */
  getDDL(name?: string): Promise<PlaymeshDatabaseDdl[]>;
  /** 在一条独立 SQLite 连接上开始事务。 @playmesh-completion playmesh.main.db.beginTransaction */
  beginTransaction(): Promise<PlaymeshDatabaseTransaction>;
  /** 自动开始事务；回调成功后提交，抛错后回滚并重新抛出原错误。 @playmesh-completion playmesh.main.db.transaction */
  transaction<T>(callback: (transaction: PlaymeshDatabaseTransaction) => T | Promise<T>): Promise<T>;
}

interface PlaymeshMainApi {
  /** Authority 专用 SQLite；多连接 WAL 允许并发读取，但 SQLite 写入仍串行提交。 */
  readonly db: PlaymeshDatabaseApi;
}

/** 当前设备独占的 App JSON Bucket；不会与 Authority 或其他玩家共享。 */
interface PlaymeshAppStorageBucket {
  /** 读取 key；不存在时返回 `null`。 */
  getData<T = PlaymeshJson>(key: string): Promise<T | null>;
  /** 在当前设备写入 JSON 值。 */
  setData(key: string, value: PlaymeshJson): Promise<void>;
  /** 阻塞读取当前设备的 JSON；不存在时返回 `null`。 */
  getDataSync<T = PlaymeshJson>(key: string): T | null;
  /** 阻塞写入当前设备的 JSON；返回时本地文件已提交。 */
  setDataSync(key: string, value: PlaymeshJson): void;
  /** 在当前设备删除一个 key。 */
  removeData(key: string): Promise<void>;
  /** 清空当前设备上的当前 Bucket。 */
  clearData(): Promise<void>;
}

interface PlaymeshAppApi {
  /** 当前设备独占的玩家本地 JSON 存储，不通过 Authority 或游戏会话共享。 */
  readonly storage: {
    /** 获取本地 Bucket；异步方法使用标准名称规则，同步方法另支持 1～4096 UTF-8 字节逻辑名。 @playmesh-completion playmesh.app.storage.getBucket */
    getBucket(bucket: string): PlaymeshAppStorageBucket;
  };
}

interface PlaymeshAppUiApi {
  /**
   * 解除当前文档用于自动打开系统游戏菜单的按键与返回触发；只能在 `playmesh.app.ready` 完成后调用。
   * 该操作不等于关闭兜底面板，也不会取消 `onSystemMenuRequest` 回调；`NEXT` 仍会遵守此触发器状态。
   * 本操作单向且幂等，不影响显式打开的平台覆盖层。 @playmesh-completion playmesh.app.ui.disableSystemMenuTriggers
   */
  disableSystemMenuTriggers(): void;
}

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
