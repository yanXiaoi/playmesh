// @ts-ignore
const PLAYMESH_DECLARATION = String.raw`
/** 取消一个事件、设备或状态订阅。重复调用不会产生新的业务效果。 */
type PlaymeshUnsubscribe = () => void;

/** SDK 可以跨 Bridge、HTTP 或 WebSocket 传输的 JSON 值。不能包含函数、循环引用或类实例。 */
type PlaymeshJson = null | boolean | number | string | PlaymeshJson[] | { [key: string]: PlaymeshJson };
type PlaymeshOrientation = "landscape" | "portrait";
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
  /** 每秒 tick 次数，必须是 1～20 的整数，默认 10。 */
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
  readonly sdkVersion: "3.3.0";
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
}

interface PlaymeshAppUiOptions {
  /** 是否由 SDK 渲染兜底游戏菜单、信息和日志覆盖层；默认 `true`。 */
  fallbackUi?: boolean;
  /** 普通浏览器是否显示可拖动的悬浮菜单按钮；默认 `true`。 */
  floatingButton?: boolean;
}

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
  /** 重新加载当前游戏文档。 @playmesh-completion playmesh.app.ui.restartGame */
  restartGame(): void;
  /** 打开“分享/邀请”；仅当前 Authority 可在有效用户操作中调用。 @playmesh-completion playmesh.app.ui.openSharePanel */
  openSharePanel(): Promise<void>;
  /** 打开 SDK 运行日志覆盖层。 @playmesh-completion playmesh.app.ui.openRuntimeLogs */
  openRuntimeLogs(): Promise<boolean>;
  /** 进入全屏。 @playmesh-completion playmesh.app.ui.enterFullscreen */
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
  readonly version: "3.3.0";
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
    /** 请求 App WebView 进入或退出全屏；进入时可同时锁定横屏或竖屏。 @playmesh-completion playmesh.app.device.setFullscreen */
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
  readonly version: "__PLAYMESH_SDK_VERSION__";
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
    /** 同一 key 只保留最新连续输入；`rateHz` 必须为 1～20。 @playmesh-completion playmesh.main.sync.submitState */
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
  /** Authority 主机上的持久 JSON Bucket。浏览器和加入设备不建立独立副本。 */
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
`;

(function (global) {
  "use strict";

  const PLAYMESH_SDK_VERSION = "4.1.0";

  let sequence = 0;
  let bootstrap = null;
  let browserSocket = null;
  let browserCredential = null;
  let browserConnectionConfig = null;
  let browserReconnectOperation = null;
  let binaryTransportConfig = null;
  let binarySocket = null;
  let binaryConnectOperation = null;
  let binaryReconnectWanted = false;
  let runtimeExited = false;
  let binaryRequestSequence = 0;
  let binaryQueueHead = 0;
  let binaryFlushTimer = null;
  const binaryQueue = [];
  const binaryLatestQueue = new Map();
  const binaryPending = new Map();
  const binaryChannels = new Map();
  let browserNicknameUi = null;
  let capabilityConsentUi = null;
  let transportSequence = 0;
  const pending = new Map();
  const sessionListeners = new Set();
  const playerJoinListeners = new Set();
  const playerLeaveListeners = new Set();
  const playerReconnectListeners = new Set();
  const previouslyConnectedPlayerIds = new Set();
  const messageListeners = new Set();
  const lifecycleListeners = new Set();
  const pauseListeners = new Set();
  const resumeListeners = new Set();
  const exitListeners = new Set();
  const syncListeners = new Set();
  const browserNicknameStorageKey = "playmesh.nickname.v1";
  const browserPlayerIdStorageKey = "playmesh.player-id.v1";
  let syncAuthorityRuntime = null;
  let currentSyncSnapshot = null;
  let syncInputSequence = 0;
  const pendingStateInputs = new Map();
  const BINARY_PROTOCOL_VERSION = 1;
  const BINARY_OP_CREATE = 0x01;
  const BINARY_OP_JOIN = 0x02;
  const BINARY_OP_CLOSE = 0x03;
  const BINARY_OP_SEND = 0x04;
  const BINARY_OP_DECISION = 0x05;
  const BINARY_OP_RESPONSE = 0x81;
  const BINARY_OP_DELIVERY = 0x82;
  const BINARY_OP_REVIEW = 0x83;
  const BINARY_OP_CLOSED = 0x84;
  const BINARY_MODE_AUTHORITY = 1;
  const BINARY_MODE_RELAY = 2;
  const BINARY_FLAG_LATEST = 1;
  const BINARY_FLAG_MULTIPLE_TARGETS = 2;
  const BINARY_FLAG_BROADCAST = 4;
  const BINARY_DECISION_PASS = 1;
  const BINARY_DECISION_REPLACE = 2;
  const BINARY_DECISION_REJECT = 3;
  const BINARY_STATUS_OK = 0;
  const BINARY_STATUS_ERROR = 1;
  const BINARY_STATUS_SUPERSEDED = 2;
  const BINARY_CHANNEL_ID_BYTES = 16;
  const BINARY_MAX_TARGETS = 1024;
  const BINARY_MAX_BUFFERED_BYTES = 8 * 1024 * 1024;
  const BINARY_REQUEST_TIMEOUT_MS = 15000;
  const RECONNECT_BASE_DELAY_MS = 250;
  const RECONNECT_MAX_DELAY_MS = 5000;
  function post(command, payload, extra) {
    const requestId = `sdk-${Date.now()}-${++sequence}`;
    const message = JSON.stringify({
      command,
      requestId,
      sdkVersion: PLAYMESH_SDK_VERSION,
      payload,
      ...extra,
    });
    if (global.__PLAYMESH_BROWSER__ &&
        (command === "game.submitAction" ||
          command === "performance.ping")) {
      return sendBrowserTransport(command, payload);
    }
    const send = global.PlaymeshBridge && global.PlaymeshBridge.postMessage
      ? (value) => global.PlaymeshBridge.postMessage(value)
      : global.chrome && global.chrome.webview
        ? (value) => global.chrome.webview.postMessage(value)
        : null;
    if (!send) {
      return Promise.reject(new Error("Playmesh 传输通道不可用"));
    }
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        pending.delete(requestId);
        reject(new Error(`Playmesh Bridge 请求超时: ${command}`));
      }, 15000);
      pending.set(requestId, { resolve, reject, timer });
      try {
        send(message);
      } catch (error) {
        global.clearTimeout(timer);
        pending.delete(requestId);
        reject(error);
      }
    });
  }

  function reconnectDelay(attempt) {
    if (attempt <= 1) return 0;
    return Math.min(
      RECONNECT_BASE_DELAY_MS * (2 ** Math.min(attempt - 2, 5)),
      RECONNECT_MAX_DELAY_MS,
    );
  }

  async function waitForReconnect(attempt) {
    const delay = reconnectDelay(attempt);
    if (delay > 0) {
      await new Promise((resolve) => global.setTimeout(resolve, delay));
    }
    if (runtimeExited) throw new Error("游戏页面已退出");
  }

  async function sendBrowserTransport(command, payload) {
    let socket = browserSocket;
    if (!socket || socket.readyState !== global.WebSocket.OPEN) {
      if (!browserReconnectOperation) {
        throw new Error("主会话 WebSocket 当前不可用");
      }
      await browserReconnectOperation;
      socket = browserSocket;
    }
    if (!socket || socket.readyState !== global.WebSocket.OPEN) {
      throw new Error("主会话 WebSocket 重连尚未完成");
    }
    const type = command === "game.submitAction"
      ? "game.action"
      : "session.ping";
    socket.send(JSON.stringify({
      type,
      sequence: ++transportSequence,
      payload,
    }));
    return null;
  }

  function subscribe(listeners, callback) {
    listeners.add(callback);
    return function unsubscribe() {
      listeners.delete(callback);
    };
  }

  function emit(listeners, value) {
    for (const listener of listeners) {
      listener(value);
    }
  }

  function binaryModeCode(mode) {
    if (mode === "authority") return BINARY_MODE_AUTHORITY;
    if (mode === "relay") return BINARY_MODE_RELAY;
    throw new Error('Binary Channel mode 必须是 "authority" 或 "relay"');
  }

  function binaryModeName(mode) {
    if (mode === BINARY_MODE_AUTHORITY) return "authority";
    if (mode === BINARY_MODE_RELAY) return "relay";
    throw new Error("主机返回了无效的 Binary Channel mode");
  }

  function binaryChannelIdFromBytes(bytes) {
    let raw = "";
    for (const value of bytes) raw += String.fromCharCode(value);
    return global.btoa(raw)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");
  }

  function binaryChannelIdToBytes(value) {
    if (typeof value !== "string" || !value) {
      throw new Error("Binary Channel ID 必须是非空字符串");
    }
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - normalized.length % 4) % 4);
    let raw;
    try {
      raw = global.atob(padded);
    } catch (_) {
      throw new Error("Binary Channel ID 无效");
    }
    if (raw.length !== BINARY_CHANNEL_ID_BYTES) {
      throw new Error("Binary Channel ID 无效");
    }
    return Uint8Array.from(raw, (character) => character.charCodeAt(0));
  }

  function normalizeBinaryData(data) {
    if (!(data instanceof Uint8Array)) {
      throw new Error("Binary Channel 数据必须是 Uint8Array");
    }
    return new Uint8Array(data);
  }

  function normalizeBinaryTargets(target) {
    const values = Array.isArray(target) ? target : [target];
    if (!values.length || values.length > BINARY_MAX_TARGETS) {
      throw new Error(`Binary Channel 目标数量必须为 1 至 ${BINARY_MAX_TARGETS}`);
    }
    const result = [];
    const seen = new Set();
    for (const playerId of values) {
      if (typeof playerId !== "string" || !playerId) {
        throw new Error("Binary Channel 目标玩家 ID 必须是非空字符串");
      }
      if (seen.has(playerId)) continue;
      seen.add(playerId);
      result.push(playerId);
    }
    return result;
  }

  function encodeBinaryCreate(requestId, mode) {
    const data = new Uint8Array(7);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_CREATE;
    view.setUint32(2, requestId);
    data[6] = mode;
    return data;
  }

  function encodeBinaryChannelOperation(operation, requestId, channelId) {
    const channelBytes = binaryChannelIdToBytes(channelId);
    const data = new Uint8Array(22);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = operation;
    view.setUint32(2, requestId);
    data.set(channelBytes, 6);
    return data;
  }

  function encodeBinarySend(requestId, channelId, flags, targetPlayerIds, payload, broadcast) {
    const encodedTargets = broadcast
      ? []
      : targetPlayerIds.map((playerId) => {
          const encoded = new TextEncoder().encode(playerId);
          if (encoded.length > 0xffff) {
            throw new Error("Binary Channel 目标玩家 ID 过长");
          }
          return encoded;
        });
    if (broadcast) flags |= BINARY_FLAG_BROADCAST;
    if (encodedTargets.length > 1) flags |= BINARY_FLAG_MULTIPLE_TARGETS;
    const channelBytes = binaryChannelIdToBytes(channelId);
    const targetsLength = encodedTargets.reduce(
      (total, target) => total + target.length + (encodedTargets.length > 1 ? 2 : 0),
      0,
    );
    const data = new Uint8Array(25 + targetsLength + payload.length);
    const view = new DataView(data.buffer);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_SEND;
    view.setUint32(2, requestId);
    data.set(channelBytes, 6);
    data[22] = flags;
    view.setUint16(23, broadcast ? 0 : encodedTargets.length > 1
      ? encodedTargets.length
      : encodedTargets[0].length);
    let offset = 25;
    for (const target of encodedTargets) {
      if (encodedTargets.length > 1) {
        view.setUint16(offset, target.length);
        offset += 2;
      }
      data.set(target, offset);
      offset += target.length;
    }
    data.set(payload, offset);
    return data;
  }

  function encodeBinaryDecision(reviewId, decision, payload) {
    const data = new Uint8Array(11 + payload.length);
    data[0] = BINARY_PROTOCOL_VERSION;
    data[1] = BINARY_OP_DECISION;
    data.set(reviewId, 2);
    data[10] = decision;
    data.set(payload, 11);
    return data;
  }

  function nextBinaryRequestId() {
    binaryRequestSequence = (binaryRequestSequence + 1) >>> 0;
    if (binaryRequestSequence === 0) binaryRequestSequence = 1;
    return binaryRequestSequence;
  }

  async function ensureBinarySocket() {
    if (!bootstrap?.session || !binaryTransportConfig?.url) {
      throw new Error("当前游戏没有可用的多人二进制传输");
    }
    if (runtimeExited) throw new Error("游戏页面已退出");
    binaryReconnectWanted = true;
    if (binarySocket?.readyState === global.WebSocket.OPEN) {
      return binarySocket;
    }
    if (binaryConnectOperation) return binaryConnectOperation;
    binaryConnectOperation = connectBinaryWithRetry()
      .finally(() => {
        binaryConnectOperation = null;
        if (!runtimeExited &&
            binaryReconnectWanted &&
            binarySocket?.readyState !== global.WebSocket.OPEN) {
          void ensureBinarySocket().catch(() => {});
        }
      });
    return binaryConnectOperation;
  }

  async function connectBinaryWithRetry() {
    let attempt = 0;
    while (!runtimeExited && binaryReconnectWanted) {
      attempt += 1;
      await waitForReconnect(attempt);
      if (global.__PLAYMESH_BROWSER__?.mode !== "solo" &&
          browserConnectionConfig &&
          browserSocket?.readyState !== global.WebSocket.OPEN) {
        global.console?.info?.("Playmesh Binary WebSocket 等待主会话重连", { attempt });
        if (browserReconnectOperation) {
          await browserReconnectOperation.catch(() => {});
        }
        continue;
      }
      if (attempt > 1) {
        global.console?.info?.("Playmesh Binary WebSocket 正在重连", { attempt });
      }
      try {
        const socket = await openBinarySocket();
        await restoreBinaryChannels();
        if (attempt > 1) {
          global.console?.info?.("Playmesh Binary WebSocket 重连成功", { attempt });
        } else {
          global.console?.info?.("Playmesh Binary WebSocket 已连接");
        }
        scheduleBinaryFlush();
        return socket;
      } catch (error) {
        if (runtimeExited || !binaryReconnectWanted) break;
        const failedSocket = binarySocket;
        binarySocket = null;
        if (failedSocket && failedSocket.readyState < global.WebSocket.CLOSING) {
          failedSocket.close();
        }
        global.console?.warn?.("Playmesh Binary WebSocket 重连失败，将继续重试", {
          attempt,
          error: error?.message || String(error),
          retryInMs: reconnectDelay(attempt + 1),
        });
      }
    }
    throw new Error("游戏页面已退出，停止 Binary WebSocket 重连");
  }

  function openBinarySocket() {
    return new Promise((resolve, reject) => {
      const socket = new global.WebSocket(binaryTransportConfig.url);
      socket.binaryType = "arraybuffer";
      binarySocket = socket;
      let opened = false;
      const fail = () => {
        if (!opened) reject(new Error("无法连接主机 Binary WebSocket"));
      };
      socket.addEventListener("open", () => {
        opened = true;
        socket.removeEventListener?.("error", fail);
        resolve(socket);
      }, { once: true });
      socket.addEventListener("error", fail, { once: true });
      socket.addEventListener("message", (event) => {
        void receiveBinarySocketMessage(event.data);
      });
      socket.addEventListener("close", (event) => {
        if (binarySocket !== socket) return;
        binarySocket = null;
        if (!opened) {
          reject(new Error("Binary WebSocket 在连接完成前关闭"));
          return;
        }
        handleBinaryDisconnect(event);
      });
    });
  }

  function handleBinaryDisconnect(event) {
    const error = new Error("Binary WebSocket 已掉线");
    global.console?.warn?.("Playmesh Binary WebSocket 已掉线", {
      code: event?.code,
      reason: event?.reason || "",
    });
    failBinaryTransport(error, false);
    if (!runtimeExited && binaryReconnectWanted) {
      void ensureBinarySocket().catch(() => {});
    }
  }

  async function restoreBinaryChannels() {
    for (const state of [...binaryChannels.values()]) {
      if (state.closed) continue;
      try {
        await binaryRequest(
          (requestId) => encodeBinaryChannelOperation(BINARY_OP_JOIN, requestId, state.id),
          { expectsChannel: true },
        );
        global.console?.info?.("Playmesh Binary Channel 已恢复", { channelId: state.id });
      } catch (error) {
        state.closed = true;
        binaryChannels.delete(state.id);
        global.console?.error?.("Playmesh Binary Channel 恢复失败，Channel 已关闭", {
          channelId: state.id,
          error: error?.message || String(error),
        });
      }
    }
  }

  function failBinaryTransport(error, closeChannels = true) {
    if (binaryFlushTimer) global.clearTimeout(binaryFlushTimer);
    binaryFlushTimer = null;
    for (let index = binaryQueueHead; index < binaryQueue.length; index += 1) {
      const item = binaryQueue[index];
      if (item?.latestKey && binaryLatestQueue.get(item.latestKey) === item) {
        binaryLatestQueue.delete(item.latestKey);
      }
    }
    binaryQueue.length = 0;
    binaryQueueHead = 0;
    for (const request of binaryPending.values()) {
      global.clearTimeout(request.timer);
      request.reject(error);
    }
    binaryPending.clear();
    if (closeChannels) {
      for (const state of binaryChannels.values()) {
        state.closed = true;
      }
      binaryChannels.clear();
    }
  }

  function closeBinaryTransport(reason = "游戏运行时已退出", permanent = false) {
    if (permanent) binaryReconnectWanted = false;
    const socket = binarySocket;
    binarySocket = null;
    if (socket && socket.readyState < global.WebSocket.CLOSING) {
      socket.close(1000, reason);
    }
    failBinaryTransport(new Error(reason), permanent);
    if (!permanent && !runtimeExited && binaryReconnectWanted) {
      void ensureBinarySocket().catch(() => {});
    }
  }

  function queueBinaryFrame(data, options = {}) {
    const item = {
      data,
      latestKey: options.latestKey || null,
      requestId: options.requestId || 0,
      superseded: false,
    };
    if (item.latestKey) {
      const previous = binaryLatestQueue.get(item.latestKey);
      if (previous && !previous.sent) {
        previous.superseded = true;
        settleBinaryRequest(previous.requestId, BINARY_STATUS_SUPERSEDED);
      }
      binaryLatestQueue.set(item.latestKey, item);
    }
    binaryQueue.push(item);
    scheduleBinaryFlush();
  }

  function scheduleBinaryFlush() {
    if (binaryFlushTimer) return;
    binaryFlushTimer = global.setTimeout(flushBinaryQueue, 0);
  }

  function flushBinaryQueue() {
    binaryFlushTimer = null;
    const socket = binarySocket;
    if (!socket || socket.readyState !== global.WebSocket.OPEN) return;
    while (binaryQueueHead < binaryQueue.length &&
           socket.bufferedAmount < BINARY_MAX_BUFFERED_BYTES) {
      const item = binaryQueue[binaryQueueHead++];
      if (item.superseded) continue;
      item.sent = true;
      if (item.latestKey && binaryLatestQueue.get(item.latestKey) === item) {
        binaryLatestQueue.delete(item.latestKey);
      }
      try {
        socket.send(item.data);
      } catch (error) {
        settleBinaryRequest(item.requestId, BINARY_STATUS_ERROR, error);
      }
    }
    if (binaryQueueHead >= binaryQueue.length) {
      binaryQueue.length = 0;
      binaryQueueHead = 0;
      return;
    }
    binaryFlushTimer = global.setTimeout(flushBinaryQueue, 4);
  }

  async function binaryRequest(frameFactory, options = {}) {
    await ensureBinarySocket();
    const requestId = nextBinaryRequestId();
    const frame = frameFactory(requestId);
    return new Promise((resolve, reject) => {
      const timer = global.setTimeout(() => {
        binaryPending.delete(requestId);
        reject(new Error("Binary Channel 请求超时"));
      }, BINARY_REQUEST_TIMEOUT_MS);
      binaryPending.set(requestId, {
        resolve, reject, timer,
        expectsChannel: options.expectsChannel === true,
      });
      queueBinaryFrame(frame, {
        requestId,
        latestKey: options.latestKey,
      });
    });
  }

  function settleBinaryRequest(requestId, status, error, result) {
    if (!requestId) return;
    const request = binaryPending.get(requestId);
    if (!request) return;
    global.clearTimeout(request.timer);
    binaryPending.delete(requestId);
    if (status === BINARY_STATUS_ERROR) {
      request.reject(error instanceof Error ? error : new Error(String(error || "Binary Channel 请求失败")));
    } else {
      request.resolve(result);
    }
  }

  async function receiveBinarySocketMessage(raw) {
    let data;
    if (raw instanceof ArrayBuffer) {
      data = new Uint8Array(raw);
    } else if (raw instanceof Uint8Array) {
      data = raw;
    } else if (raw?.arrayBuffer) {
      data = new Uint8Array(await raw.arrayBuffer());
    } else {
      closeBinaryTransport("主机返回了无效的二进制帧");
      return;
    }
    if (data.length < 2 || data[0] !== BINARY_PROTOCOL_VERSION) {
      closeBinaryTransport("主机返回了不兼容的二进制协议");
      return;
    }
    switch (data[1]) {
    case BINARY_OP_RESPONSE:
      receiveBinaryResponse(data);
      break;
    case BINARY_OP_DELIVERY:
      receiveBinaryDelivery(data);
      break;
    case BINARY_OP_REVIEW:
      void receiveBinaryReview(data);
      break;
    case BINARY_OP_CLOSED:
      receiveBinaryClosed(data);
      break;
    default:
      closeBinaryTransport("主机返回了未知的二进制操作");
    }
  }

  function receiveBinaryResponse(data) {
    if (data.length < 7) {
      closeBinaryTransport("Binary Channel 响应格式无效");
      return;
    }
    const requestId = new DataView(data.buffer, data.byteOffset, data.byteLength).getUint32(2);
    const status = data[6];
    if (status === BINARY_STATUS_ERROR) {
      settleBinaryRequest(
        requestId,
        status,
        new Error(new TextDecoder().decode(data.subarray(7)) || "Binary Channel 请求失败"),
      );
      return;
    }
    let result;
    if (status === BINARY_STATUS_OK && data.length === 24) {
      result = {
        mode: binaryModeName(data[7]),
        id: binaryChannelIdFromBytes(data.subarray(8, 24)),
      };
    }
    settleBinaryRequest(requestId, status, null, result);
  }

  function receiveBinaryDelivery(data) {
    if (data.length < 21) {
      closeBinaryTransport("Binary Channel 消息格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const senderLength = view.getUint16(19);
    if (!senderLength || data.length < 21 + senderLength) {
      closeBinaryTransport("Binary Channel 发送者格式无效");
      return;
    }
    const channelId = binaryChannelIdFromBytes(data.subarray(2, 18));
    const state = binaryChannels.get(channelId);
    if (!state || state.closed) return;
    const senderPlayerId = new TextDecoder().decode(data.subarray(21, 21 + senderLength));
    const payload = data.slice(21 + senderLength);
    const context = {
      senderPlayerId,
      delivery: data[18] & BINARY_FLAG_LATEST ? "latest" : "queued",
    };
    for (const listener of [...state.listeners]) {
      listener(payload, context);
    }
  }

  async function receiveBinaryReview(data) {
    if (data.length < 31) {
      closeBinaryTransport("Binary Channel Authority 审核帧格式无效");
      return;
    }
    const view = new DataView(data.buffer, data.byteOffset, data.byteLength);
    const reviewId = data.slice(2, 10);
    const channelId = binaryChannelIdFromBytes(data.subarray(10, 26));
    const senderLength = view.getUint16(27);
    const targetField = view.getUint16(29);
    if (!senderLength || !targetField || data.length < 31 + senderLength) {
      closeBinaryTransport("Binary Channel Authority 审核上下文无效");
      return;
    }
    let offset = 31;
    const senderPlayerId = new TextDecoder().decode(data.subarray(offset, offset + senderLength));
    offset += senderLength;
    const targetPlayerIds = [];
    if (data[26] & BINARY_FLAG_MULTIPLE_TARGETS) {
      if (targetField > BINARY_MAX_TARGETS) {
        closeBinaryTransport("Binary Channel Authority 审核目标过多");
        return;
      }
      for (let index = 0; index < targetField; index += 1) {
        if (data.length < offset + 2) {
          closeBinaryTransport("Binary Channel Authority 审核目标格式无效");
          return;
        }
        const targetLength = view.getUint16(offset);
        offset += 2;
        if (!targetLength || data.length < offset + targetLength) {
          closeBinaryTransport("Binary Channel Authority 审核目标格式无效");
          return;
        }
        targetPlayerIds.push(
          new TextDecoder().decode(data.subarray(offset, offset + targetLength)),
        );
        offset += targetLength;
      }
    } else {
      if (data.length < offset + targetField) {
        closeBinaryTransport("Binary Channel Authority 审核目标格式无效");
        return;
      }
      targetPlayerIds.push(
        new TextDecoder().decode(data.subarray(offset, offset + targetField)),
      );
      offset += targetField;
    }
    const payload = data.slice(offset);
    const state = binaryChannels.get(channelId);
    if (!state || state.closed || state.mode !== "authority" || !state.forwardHandler) {
      queueBinaryFrame(encodeBinaryDecision(
        reviewId,
        BINARY_DECISION_REJECT,
        new TextEncoder().encode("Authority 未注册 Binary Channel 审核器"),
      ));
      return;
    }
    try {
      const replacement = await state.forwardHandler(payload, {
        senderPlayerId,
        targetPlayerIds,
        delivery: data[26] & BINARY_FLAG_LATEST ? "latest" : "queued",
      });
      if (replacement === undefined) {
        queueBinaryFrame(encodeBinaryDecision(reviewId, BINARY_DECISION_PASS, new Uint8Array()));
      } else if (replacement instanceof Uint8Array) {
        queueBinaryFrame(encodeBinaryDecision(
          reviewId,
          BINARY_DECISION_REPLACE,
          new Uint8Array(replacement),
        ));
      } else {
        throw new Error("Binary Channel Authority 审核器只能返回 void 或 Uint8Array");
      }
    } catch (error) {
      queueBinaryFrame(encodeBinaryDecision(
        reviewId,
        BINARY_DECISION_REJECT,
        new TextEncoder().encode(error?.message || String(error)),
      ));
    }
  }

  function receiveBinaryClosed(data) {
    if (data.length < 18) {
      closeBinaryTransport("Binary Channel 关闭帧格式无效");
      return;
    }
    const channelId = binaryChannelIdFromBytes(data.subarray(2, 18));
    const state = binaryChannels.get(channelId);
    if (!state) return;
    state.closed = true;
    binaryChannels.delete(channelId);
  }

  function createBinaryChannelHandle(id, mode) {
    const existing = binaryChannels.get(id);
    if (existing && !existing.closed) return existing.handle;
    const state = {
      id,
      mode,
      listeners: new Set(),
      forwardHandler: null,
      closed: false,
      handle: null,
    };
    const sendToTargets = (target, data, latest) => {
      if (state.closed) return Promise.reject(new Error("Binary Channel 已关闭"));
      const targetPlayerIds = normalizeBinaryTargets(target);
      const payload = normalizeBinaryData(data);
      const latestKey = latest
        ? `${id}\u0000${JSON.stringify([...targetPlayerIds].sort())}`
        : null;
      return binaryRequest(
        (requestId) => encodeBinarySend(
          requestId,
          id,
          latest ? BINARY_FLAG_LATEST : 0,
          targetPlayerIds,
          payload,
          false,
        ),
        { latestKey },
      );
    };
    const broadcast = (data, latest) => {
      if (state.closed) return Promise.reject(new Error("Binary Channel 已关闭"));
      const payload = normalizeBinaryData(data);
      return binaryRequest(
        (requestId) => encodeBinarySend(
          requestId,
          id,
          latest ? BINARY_FLAG_LATEST : 0,
          [],
          payload,
          true,
        ),
        { latestKey: latest ? `${id}\u0000broadcast` : null },
      );
    };
    state.handle = Object.freeze({
      id,
      mode,
      send(targetOrData, data) {
        if (data === undefined && targetOrData instanceof Uint8Array) {
          return broadcast(targetOrData, false);
        }
        return sendToTargets(targetOrData, data, false);
      },
      sendLatest(targetOrData, data) {
        if (data === undefined && targetOrData instanceof Uint8Array) {
          return broadcast(targetOrData, true);
        }
        return sendToTargets(targetOrData, data, true);
      },
      onMessage(callback) {
        if (typeof callback !== "function") throw new Error("Binary Channel onMessage 需要函数");
        state.listeners.add(callback);
        return () => state.listeners.delete(callback);
      },
      onForward(handler) {
        if (!main.session.isAuthority() || mode !== "authority") {
          throw new Error("只有 Authority mode 的 Authority 可以注册 Binary Channel 审核器");
        }
        if (typeof handler !== "function") throw new Error("Binary Channel onForward 需要函数");
        state.forwardHandler = handler;
        return () => {
          if (state.forwardHandler === handler) state.forwardHandler = null;
        };
      },
      async close() {
        if (!main.session.isAuthority()) {
          throw new Error("只有 Authority 可以关闭 Binary Channel");
        }
        if (state.closed) return;
        await binaryRequest(
          (requestId) => encodeBinaryChannelOperation(BINARY_OP_CLOSE, requestId, id),
        );
        state.closed = true;
        binaryChannels.delete(id);
      },
    });
    binaryChannels.set(id, state);
    return state.handle;
  }

  function publicPlayer(player) {
    if (!player || typeof player !== "object") return null;
    return {
      id: player.id,
      nickname: player.nickname,
      avatar: typeof player.avatar === "string" ? player.avatar : null,
      role: player.role,
      connected: Boolean(player.connected),
    };
  }

  function publicSession(session) {
    if (!session || typeof session !== "object") return null;
    return {
      ...session,
      players: Array.isArray(session.players)
        ? session.players.map(publicPlayer)
        : [],
    };
  }

  function seedPlayerConnections(session) {
    previouslyConnectedPlayerIds.clear();
    for (const player of session?.players || []) {
      if (player.connected) previouslyConnectedPlayerIds.add(player.id);
    }
  }

  function playerConnectionLogContext(player) {
    const value = publicPlayer(player);
    return {
      playerId: value?.id || null,
      nickname: value?.nickname || null,
      avatar: value?.avatar ?? null,
      playerRole: value?.role || null,
      playerConnected: value?.connected ?? false,
    };
  }

  function sessionConnectionLogContext(session, player) {
    const players = session?.players || [];
    return {
      sessionId: session?.id || null,
      gameId: session?.gameId || null,
      roomType: session?.displayMode || "unknown",
      sessionState: session?.state || "unknown",
      onlinePlayers: players.filter((member) => member.connected).length,
      roomPlayers: players.length,
      minPlayers: session?.minPlayers ?? null,
      maxPlayers: session?.maxPlayers ?? null,
      ...playerConnectionLogContext(player),
      isCurrentPlayer: player?.id === bootstrap?.player?.id,
      isAuthority: player?.id === session?.authorityClientId,
    };
  }

  function emitPlayerConnectionChanges(previousSession, nextSession) {
    if (previousSession?.id !== nextSession?.id) {
      seedPlayerConnections(previousSession?.id === nextSession?.id ? previousSession : null);
    }
    const previousPlayers = new Map((previousSession?.players || []).map((player) => [player.id, player]));
    const nextPlayers = new Map((nextSession?.players || []).map((player) => [player.id, player]));
    for (const player of nextPlayers.values()) {
      const previous = previousPlayers.get(player.id);
      if (player.connected && !previous?.connected) {
        const reconnecting = previouslyConnectedPlayerIds.has(player.id);
        previouslyConnectedPlayerIds.add(player.id);
        global.console?.info?.(
          reconnecting
            ? "Playmesh 玩家已重连"
            : "Playmesh 新玩家已加入房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(reconnecting ? playerReconnectListeners : playerJoinListeners, {
          player,
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      } else if (!player.connected && previous?.connected) {
        global.console?.warn?.(
          "Playmesh 玩家已掉线或退出房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(playerLeaveListeners, {
          player,
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      }
    }
    for (const player of previousPlayers.values()) {
      if (player.connected && !nextPlayers.has(player.id)) {
        global.console?.warn?.(
          "Playmesh 玩家已退出房间",
          sessionConnectionLogContext(nextSession, player),
        );
        emit(playerLeaveListeners, {
          player: { ...player, connected: false },
          session: nextSession,
          isCurrentPlayer: player.id === bootstrap?.player?.id,
        });
      }
    }
  }

  let syncSnapshotSequence = 0;

  function cloneJson(value, label) {
    let encoded;
    try {
      encoded = JSON.stringify(value);
    } catch (error) {
      throw new Error(`${label} 必须可 JSON 序列化: ${error.message || error}`);
    }
    if (encoded === undefined) throw new Error(`${label} 不能是 undefined`);
    return JSON.parse(encoded);
  }

  function canonicalJson(value) {
    if (value === null || typeof value !== "object") return JSON.stringify(value);
    if (Array.isArray(value)) {
      return `[${value.map((entry) => canonicalJson(entry)).join(",")}]`;
    }
    return `{${Object.keys(value).sort().map((key) =>
      `${JSON.stringify(key)}:${canonicalJson(value[key])}`
    ).join(",")}}`;
  }

  function syncTargetIds(session) {
    return [...new Set([
      session.authorityClientId,
      ...session.players.map((player) => player.id),
    ].filter(Boolean))];
  }

  function applySyncState(runtime, nextState) {
    if (nextState === undefined) return false;
    const normalized = cloneJson(nextState, "权威状态");
    const encoded = JSON.stringify(normalized);
    const fingerprint = canonicalJson(normalized);
    if (fingerprint === runtime.stateFingerprint) return false;
    runtime.state = normalized;
    runtime.stateJson = encoded;
    runtime.stateFingerprint = fingerprint;
    runtime.revision += 1;
    return true;
  }

  function syncBroadcastNeeded(runtime) {
    return runtime.reconciliationSequence > runtime.lastBroadcastSequence ||
      runtime.lastBroadcastFingerprint === null ||
      runtime.stateFingerprint !== runtime.lastBroadcastFingerprint ||
      (
        runtime.activeAutoPublish &&
        runtime.activeAutoPublish.snapshot.sequence > runtime.lastBroadcastSequence &&
        runtime.stateFingerprint !== runtime.activeAutoPublish.stateFingerprint
      );
  }

  function settleSyncAutoWaiters(runtime, snapshot, error) {
    const remaining = [];
    for (const waiter of runtime.autoWaiters) {
      if (
        snapshot.sequence < waiter.minimumSequence ||
        snapshot.revision < waiter.minimumRevision
      ) {
        remaining.push(waiter);
      } else if (error) {
        waiter.reject(error);
      } else {
        waiter.resolve(snapshot);
      }
    }
    runtime.autoWaiters = remaining;
  }

  function cancelSyncAutoWaiters(runtime) {
    const waiters = runtime.autoWaiters;
    runtime.autoWaiters = [];
    for (const waiter of waiters) waiter.resolve(null);
  }

  function discardCanceledSyncAutoPublishes(runtime) {
    while (
      runtime.publishQueue[0]?.kind === "auto" &&
      !syncBroadcastNeeded(runtime)
    ) {
      runtime.publishQueue.shift();
      runtime.autoQueued = false;
      runtime.autoAgain = false;
      cancelSyncAutoWaiters(runtime);
    }
  }

  function armSyncPublishQueue(runtime) {
    if (runtime.stopped || runtime.publishRunning || runtime.publishTimer) return;
    discardCanceledSyncAutoPublishes(runtime);
    if (runtime.publishQueue.length === 0) return;
    const wait = Math.max(0, runtime.nextPublishAt - Date.now());
    if (wait === 0) {
      void drainSyncPublishQueue(runtime);
      return;
    }
    runtime.publishTimer = global.setTimeout(() => {
      runtime.publishTimer = null;
      void drainSyncPublishQueue(runtime);
    }, Math.ceil(wait));
    runtime.publishTimer?.unref?.();
  }

  function queueAutomaticSyncPublish(runtime) {
    if (runtime.stopped) return;
    if (!syncBroadcastNeeded(runtime)) {
      runtime.autoAgain = false;
      cancelSyncAutoWaiters(runtime);
      return;
    }
    if (runtime.autoQueued) {
      if (runtime.activeAutoPublish) runtime.autoAgain = true;
      return;
    }
    runtime.autoQueued = true;
    const task = { kind: "auto", targetPlayerIds: null };
    runtime.publishQueue.push(task);
    armSyncPublishQueue(runtime);
  }

  function scheduleSyncChangeWindow(runtime) {
    if (
      runtime.stopped || runtime.onTick || runtime.changeTimer ||
      (runtime.autoQueued && !runtime.activeAutoPublish)
    ) return;
    runtime.changeTimer = global.setTimeout(() => {
      runtime.changeTimer = null;
      queueAutomaticSyncPublish(runtime);
    }, runtime.publishIntervalMs);
    runtime.changeTimer?.unref?.();
  }

  function noteSyncStateChanged(runtime) {
    if (!runtime.onTick) scheduleSyncChangeWindow(runtime);
  }

  function waitForAutomaticSyncPublish(runtime) {
    if (runtime.stopped || !syncBroadcastNeeded(runtime)) {
      return Promise.resolve(null);
    }
    let resolve;
    let reject;
    const promise = new Promise((resolvePromise, rejectPromise) => {
      resolve = resolvePromise;
      reject = rejectPromise;
    });
    runtime.autoWaiters.push({
      minimumSequence: syncSnapshotSequence + 1,
      minimumRevision: runtime.revision,
      resolve,
      reject,
    });
    if (!runtime.onTick) scheduleSyncChangeWindow(runtime);
    return promise;
  }

  function continuousInputs(runtime) {
    const result = {};
    for (const [compoundKey, entry] of runtime.inputs) {
      const separator = compoundKey.indexOf(":");
      const playerId = compoundKey.substring(0, separator);
      const key = compoundKey.substring(separator + 1);
      result[playerId] ??= {};
      result[playerId][key] = cloneJson(entry, "连续输入");
    }
    return result;
  }

  function createSyncSnapshot(runtime) {
    const stateJson = runtime.stateJson;
    return {
      stateFingerprint: runtime.stateFingerprint,
      snapshot: {
        protocolVersion: 1,
        stateType: runtime.stateType,
        full: true,
        revision: runtime.revision,
        sequence: ++syncSnapshotSequence,
        timestamp: Date.now(),
        sourceTick: runtime.tick,
        state: JSON.parse(stateJson),
      },
    };
  }

  function beginDefaultSyncPublish(runtime, stateFingerprint) {
    runtime.pendingDefaultFingerprints.set(
      stateFingerprint,
      (runtime.pendingDefaultFingerprints.get(stateFingerprint) || 0) + 1,
    );
  }

  function endDefaultSyncPublish(runtime, stateFingerprint) {
    const remaining =
      (runtime.pendingDefaultFingerprints.get(stateFingerprint) || 1) - 1;
    if (remaining > 0) {
      runtime.pendingDefaultFingerprints.set(stateFingerprint, remaining);
    } else {
      runtime.pendingDefaultFingerprints.delete(stateFingerprint);
    }
  }

  function applyLocalSyncSnapshot(snapshot) {
    try {
      applySyncSnapshot(snapshot);
    } catch (error) {
      try {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      } catch (_) {}
    }
  }

  function finishSyncPublish(runtime) {
    if (runtime.stopped) return;
    if (!syncBroadcastNeeded(runtime)) {
      runtime.autoAgain = false;
      if (runtime.changeTimer) {
        global.clearTimeout(runtime.changeTimer);
        runtime.changeTimer = null;
      }
      discardCanceledSyncAutoPublishes(runtime);
      cancelSyncAutoWaiters(runtime);
    } else if (!runtime.onTick && !runtime.changeTimer && !runtime.autoQueued) {
      scheduleSyncChangeWindow(runtime);
    }
    armSyncPublishQueue(runtime);
  }

  function publishSyncSnapshot(runtime, targetPlayerIds) {
    if (runtime.stopped) return Promise.resolve(null);
    const session = bootstrap?.session;
    if (!session) return Promise.resolve(null);
    const normalizedTargets = targetPlayerIds == null
      ? null
      : Array.isArray(targetPlayerIds)
        ? [...targetPlayerIds]
        : targetPlayerIds;
    const defaultAudience = normalizedTargets === null;
    const { snapshot, stateFingerprint } = createSyncSnapshot(runtime);
    if (defaultAudience) {
      beginDefaultSyncPublish(runtime, stateFingerprint);
    } else if (
      stateFingerprint !== runtime.lastBroadcastFingerprint &&
      !runtime.pendingDefaultFingerprints.has(stateFingerprint)
    ) {
      runtime.reconciliationSequence = Math.max(
        runtime.reconciliationSequence,
        snapshot.sequence,
      );
      finishSyncPublish(runtime);
    }

    // 先发起 Bridge 发送，再通知本地 observer，保持重入 publish 的发送顺序与 sequence 一致。
    let sending;
    try {
      sending = post("authority.result", { __playmeshSyncSnapshot: snapshot }, {
        targetPlayerIds: defaultAudience
          ? syncTargetIds(session)
          : normalizedTargets,
      });
    } catch (error) {
      sending = Promise.reject(error);
    }
    applyLocalSyncSnapshot(snapshot);

    return Promise.resolve(sending).then(() => {
      if (!runtime.stopped && defaultAudience) {
        if (snapshot.sequence > runtime.lastBroadcastSequence) {
          runtime.lastBroadcastSequence = snapshot.sequence;
          runtime.lastBroadcastFingerprint = stateFingerprint;
        }
        settleSyncAutoWaiters(runtime, snapshot, null);
        finishSyncPublish(runtime);
      }
      return snapshot;
    }).catch((error) => {
      if (
        !runtime.stopped &&
        defaultAudience &&
        stateFingerprint !== runtime.lastBroadcastFingerprint
      ) {
        runtime.reconciliationSequence = Math.max(
          runtime.reconciliationSequence,
          snapshot.sequence,
        );
        finishSyncPublish(runtime);
      }
      throw error;
    }).finally(() => {
      if (defaultAudience) endDefaultSyncPublish(runtime, stateFingerprint);
    });
  }

  async function drainSyncPublishQueue(runtime) {
    if (runtime.stopped || runtime.publishRunning) return;
    discardCanceledSyncAutoPublishes(runtime);
    if (runtime.nextPublishAt > Date.now()) {
      armSyncPublishQueue(runtime);
      return;
    }
    if (!runtime.publishQueue.shift()) return;
    const session = bootstrap?.session;
    if (!session) {
      runtime.autoQueued = false;
      cancelSyncAutoWaiters(runtime);
      armSyncPublishQueue(runtime);
      return;
    }
    const { snapshot, stateFingerprint } = createSyncSnapshot(runtime);
    runtime.publishRunning = true;
    runtime.nextPublishAt = snapshot.timestamp + runtime.publishIntervalMs;
    runtime.activeAutoPublish = { snapshot, stateFingerprint };
    beginDefaultSyncPublish(runtime, stateFingerprint);

    let sending;
    try {
      sending = post("authority.result", { __playmeshSyncSnapshot: snapshot }, {
        targetPlayerIds: syncTargetIds(session),
      });
    } catch (error) {
      sending = Promise.reject(error);
    }
    applyLocalSyncSnapshot(snapshot);

    try {
      await sending;
      if (snapshot.sequence > runtime.lastBroadcastSequence) {
        runtime.lastBroadcastSequence = snapshot.sequence;
        runtime.lastBroadcastFingerprint = stateFingerprint;
      }
      settleSyncAutoWaiters(runtime, snapshot, null);
    } catch (error) {
      if (stateFingerprint !== runtime.lastBroadcastFingerprint) {
        runtime.reconciliationSequence = Math.max(
          runtime.reconciliationSequence,
          snapshot.sequence,
        );
      }
      settleSyncAutoWaiters(runtime, snapshot, error);
      try {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      } catch (_) {}
    } finally {
      endDefaultSyncPublish(runtime, stateFingerprint);
      runtime.publishRunning = false;
      runtime.activeAutoPublish = null;
      runtime.autoQueued = false;
      if (runtime.stopped) {
        cancelSyncAutoWaiters(runtime);
        return;
      }
      if (runtime.autoAgain) {
        runtime.autoAgain = false;
        queueAutomaticSyncPublish(runtime);
      }
      finishSyncPublish(runtime);
    }
  }

  async function runSyncTick(runtime) {
    if (runtime.stopped || runtime.tickRunning) return;
    runtime.tickRunning = true;
    try {
      const now = Date.now();
      const dt = Math.min(1, Math.max(0, (now - runtime.lastTickAt) / 1000));
      runtime.lastTickAt = now;
      runtime.tick += 1;
      if (runtime.onTick) {
        const next = await runtime.onTick({
          state: cloneJson(runtime.state, "权威状态"),
          inputs: continuousInputs(runtime),
          tick: runtime.tick,
          dt,
          now,
          session: bootstrap.session,
          members: bootstrap.session.players,
        });
        if (runtime.stopped) return;
        if (applySyncState(runtime, next)) noteSyncStateChanged(runtime);
      }
    } catch (error) {
      try {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      } catch (_) {}
    } finally {
      runtime.tickRunning = false;
      if (!runtime.stopped) queueAutomaticSyncPublish(runtime);
    }
  }

  async function dispatchSyncAuthorityAction(transportMessage) {
    const envelope = transportMessage.payload?.__playmeshSync;
    if (!envelope) return false;
    const runtime = syncAuthorityRuntime;
    if (!runtime) return true;
    if (envelope.type === "snapshot.request") {
      await publishSyncSnapshot(runtime, [transportMessage.senderPlayerId]);
      return true;
    }
    if (envelope.type !== "input.action" && envelope.type !== "input.state") {
      return true;
    }
    const input = cloneJson(envelope.payload, "同步输入");
    const context = {
      senderPlayerId: transportMessage.senderPlayerId,
      session: transportMessage.session,
      members: transportMessage.session.players,
      state: cloneJson(runtime.state, "权威状态"),
      inputId: envelope.inputId,
      inputType: envelope.type === "input.state" ? "state" : "action",
      key: envelope.key || null,
      receivedAt: Date.now(),
    };
    if (envelope.type === "input.state") {
      runtime.inputs.set(`${context.senderPlayerId}:${envelope.key}`, {
        value: input,
        inputId: envelope.inputId,
        receivedAt: context.receivedAt,
      });
    }
    if (runtime.onInput) {
      const next = await runtime.onInput(input, context);
      if (runtime.stopped) return true;
      if (applySyncState(runtime, next)) {
        noteSyncStateChanged(runtime);
      }
    }
    return true;
  }

  function applySyncSnapshot(snapshot) {
    if (!snapshot || snapshot.protocolVersion !== 1 || snapshot.full !== true) return;
    if (typeof snapshot.revision !== "number" || typeof snapshot.sequence !== "number") return;
    if (currentSyncSnapshot && snapshot.sequence <= currentSyncSnapshot.sequence &&
        snapshot.timestamp <= currentSyncSnapshot.timestamp) return;
    currentSyncSnapshot = cloneJson(snapshot, "同步快照");
    emit(syncListeners, currentSyncSnapshot);
  }

  function submitSyncEnvelope(type, payload, extra = {}) {
    if (!bootstrap?.session) return Promise.reject(new Error("当前游戏没有多人会话"));
    const inputId = `input-${Date.now()}-${++syncInputSequence}`;
    return post("game.submitAction", {
      __playmeshSync: {
        type,
        inputId,
        payload: cloneJson(payload, "同步输入"),
        clientTime: Date.now(),
        ...extra,
      },
    }).then(() => inputId);
  }

  function submitStateInput(key, value, options = {}) {
    if (typeof key !== "string" || !/^[A-Za-z0-9._-]{1,64}$/.test(key)) {
      return Promise.reject(new Error("连续输入 key 无效"));
    }
    const rateHz = options.rateHz ?? 20;
    if (!Number.isFinite(rateHz) || rateHz < 1 || rateHz > 20) {
      return Promise.reject(new Error("连续输入 rateHz 必须在 1 至 20 之间"));
    }
    const existing = pendingStateInputs.get(key) || { lastSentAt: 0, timer: null };
    existing.value = cloneJson(value, "连续输入");
    existing.rateHz = rateHz;
    pendingStateInputs.set(key, existing);
    const wait = Math.max(0, (1000 / rateHz) - (Date.now() - existing.lastSentAt));
    if (!existing.timer) {
      existing.timer = global.setTimeout(() => {
        existing.timer = null;
        existing.lastSentAt = Date.now();
        void submitSyncEnvelope("input.state", existing.value, { key }).catch(() => {});
      }, wait);
      existing.timer?.unref?.();
    }
    return Promise.resolve(null);
  }

  function startSyncAuthority(options) {
    if (!main.session.isAuthority()) {
      throw new Error("只有 Authority Client 可以启动状态同步");
    }
    if (syncAuthorityRuntime) throw new Error("权威状态同步已经启动");
    if (!options || !("initialState" in options)) {
      throw new Error("initialState 为必填项");
    }
    const tickRate = options.tickRate ?? 10;
    if (!Number.isInteger(tickRate) || tickRate < 1 || tickRate > 20) {
      throw new Error("tickRate 必须是 1 至 20 的整数");
    }
    const runtime = {
      state: cloneJson(options.initialState, "initialState"),
      stateType: typeof options.stateType === "string" && options.stateType
        ? options.stateType : "game",
      onInput: typeof options.onInput === "function" ? options.onInput : null,
      onTick: typeof options.onTick === "function" ? options.onTick : null,
      stateJson: null,
      stateFingerprint: null,
      revision: 0,
      tick: 0,
      inputs: new Map(),
      lastTickAt: Date.now(),
      tickRunning: false,
      stopped: false,
      timer: null,
      publishIntervalMs: 1000 / tickRate,
      publishQueue: [],
      publishRunning: false,
      publishTimer: null,
      changeTimer: null,
      nextPublishAt: 0,
      activeAutoPublish: null,
      autoQueued: false,
      autoAgain: false,
      autoWaiters: [],
      lastBroadcastSequence: 0,
      lastBroadcastFingerprint: null,
      reconciliationSequence: 0,
      pendingDefaultFingerprints: new Map(),
    };
    runtime.stateJson = JSON.stringify(runtime.state);
    runtime.stateFingerprint = canonicalJson(runtime.state);
    syncAuthorityRuntime = runtime;
    if (runtime.onTick) {
      runtime.timer = global.setInterval(
        () => { void runSyncTick(runtime); },
        runtime.publishIntervalMs,
      );
      runtime.timer?.unref?.();
    }
    void publishSyncSnapshot(runtime).catch((error) => {
      emit(lifecycleListeners, { state: "error", error: String(error) });
    });
    return {
      getState: () => cloneJson(runtime.state, "权威状态"),
      setState(nextState, publish = true) {
        if (applySyncState(runtime, nextState)) noteSyncStateChanged(runtime);
        return publish
          ? waitForAutomaticSyncPublish(runtime)
          : Promise.resolve(null);
      },
      publish(stateOrTargetPlayerIds, targetPlayerIds) {
        const legacyTargets =
          arguments.length === 0 ||
          stateOrTargetPlayerIds === undefined ||
          (
            Array.isArray(stateOrTargetPlayerIds) &&
            stateOrTargetPlayerIds.every((value) => typeof value === "string")
          );
        const hasState = arguments.length >= 2 || !legacyTargets;
        if (runtime.stopped) return Promise.resolve(null);
        if (hasState && applySyncState(runtime, stateOrTargetPlayerIds)) {
          noteSyncStateChanged(runtime);
        }
        return publishSyncSnapshot(
          runtime,
          hasState ? targetPlayerIds : stateOrTargetPlayerIds,
        );
      },
      stop() {
        if (runtime.stopped) return;
        runtime.stopped = true;
        global.clearInterval(runtime.timer);
        if (runtime.publishTimer) global.clearTimeout(runtime.publishTimer);
        if (runtime.changeTimer) global.clearTimeout(runtime.changeTimer);
        runtime.publishTimer = null;
        runtime.changeTimer = null;
        const active = runtime.activeAutoPublish;
        const remainingWaiters = [];
        for (const waiter of runtime.autoWaiters) {
          if (
            active &&
            active.snapshot.sequence >= waiter.minimumSequence &&
            active.snapshot.revision >= waiter.minimumRevision
          ) {
            remainingWaiters.push(waiter);
          } else {
            waiter.resolve(null);
          }
        }
        runtime.autoWaiters = remainingWaiters;
        runtime.publishQueue = [];
        runtime.autoQueued = active !== null;
        runtime.autoAgain = false;
        if (syncAuthorityRuntime === runtime) syncAuthorityRuntime = null;
      },
    };
  }

  const DEFAULT_AUTHORITY_SERVICE_NAMESPACE =
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


  function configureClientPerformance() {
    appInternalRuntime.configureRuntimePerformance?.({
      multiplayer: Boolean(bootstrap?.session),
      sendLatencyProbe(payload) {
        return post("performance.ping", payload);
      },
    });
  }

  function startLatencyProbes() {
    configureClientPerformance();
  }

  function stopLatencyProbes() {
    appInternalRuntime.configureRuntimePerformance?.({ multiplayer: false });
  }

  function handleLatencyPong(payload) {
    appInternalRuntime.recordRuntimeLatencyPong?.(payload);
  }

  function receive(rawMessage) {
    const message = typeof rawMessage === "string" ? JSON.parse(rawMessage) : rawMessage;
    if (!message || typeof message !== "object") return;
    if (message.type === "platform.ui.restoreGameFocus") {
      appInternalRuntime.restoreGameContentFocus?.();
      return;
    }
    if (message.type === "platform.ui.configure") {
      try {
        configurePlatformUi(
          message.configuration,
          runtimeLocaleUsesBrowserSystem
            ? browserRuntimeLocale
            : message.configuration?.locale,
        );
      } catch (error) {
        global.console?.error?.("Playmesh platform UI localization update failed", error);
      }
      return;
    }
    if (message.type === "sdk.bootstrap") {
      const previousSessionId = bootstrap?.session?.id;
      const publicBootstrap = {
        ...message,
        player: publicPlayer(message.player),
        session: publicSession(message.session),
      };
      if (message.binaryTransport?.url) {
        binaryTransportConfig = { url: String(message.binaryTransport.url) };
      }
      delete publicBootstrap.binaryTransport;
      bootstrap = publicBootstrap;
      seedPlayerConnections(bootstrap.session);
      if (previousSessionId !== bootstrap.session?.id) currentSyncSnapshot = null;
      emit(sessionListeners, bootstrap.session);
      emit(lifecycleListeners, { state: "ready" });
      const request = pending.get(message.requestId);
      if (request) global.clearTimeout(request.timer);
      request?.resolve(publicBootstrap);
      pending.delete(message.requestId);
      global.console?.info?.("Playmesh Game SDK 就绪", {
        mode: bootstrap.session ? "multiplayer" : "solo",
      });
      configureClientPerformance();
      startLatencyProbes();
      if (bootstrap.session && !bootstrap.isAuthority) {
        void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
      }
      return;
    }
    if (message.type === "command.result" || message.type === "command.error") {
      const request = pending.get(message.requestId);
      if (request) {
        global.clearTimeout(request.timer);
        if (message.type === "command.result") {
          request.resolve(message.result);
        } else {
          const error = new Error(message.error);
          error.code = message.code;
          request.reject(error);
        }
        pending.delete(message.requestId);
      }
      return;
    }
    if (message.type === "transport.error" || message.type === "transport.closed") {
      global.console?.warn?.("Playmesh 主会话 WebSocket 已掉线", {
        state: message.type === "transport.closed" ? "closed" : "error",
        error: message.error,
      });
      closeBinaryTransport("主会话连接已关闭");
      stopLatencyProbes();
      emit(lifecycleListeners, {
        state: message.type === "transport.closed" ? "closed" : "error",
        error: message.error,
      });
      if (browserConnectionConfig && !runtimeExited) {
        scheduleBrowserReconnect();
      }
      return;
    }
    if (message.type === "lifecycle.event") {
      const event = { state: message.event };
      emit(lifecycleListeners, event);
      const listeners = message.event === "pause"
        ? pauseListeners
        : message.event === "resume"
          ? resumeListeners
          : exitListeners;
      Promise.allSettled([...listeners].map((handler) => handler(event)))
        .then(() => {
          if (message.event === "exit") {
            markRuntimeExited("游戏运行时已退出");
          }
          if (!global.__PLAYMESH_BROWSER__) {
            return post("lifecycle.complete", {
              lifecycleRequestId: message.requestId,
            });
          }
        });
      return;
    }
    if (message.type !== "transport.message") {
      return;
    }
    const transport = message.message?.session
      ? {
          ...message.message,
          session: publicSession(message.message.session),
        }
      : message.message;
    if (transport.type === "transport.status") {
      const details = {
        attempt: transport.attempt,
        error: transport.error,
      };
      if (transport.state === "reconnected") {
        global.console?.info?.("Playmesh 主会话 WebSocket 重连成功", details);
      } else if (transport.state === "reconnecting") {
        global.console?.info?.("Playmesh 主会话 WebSocket 正在重连", details);
      } else {
        global.console?.warn?.("Playmesh 主会话 WebSocket 已掉线", details);
      }
    } else if (transport.type === "session.state") {
      emitPlayerConnectionChanges(bootstrap.session, transport.session);
      bootstrap.session = transport.session;
      emit(sessionListeners, transport.session);
      startLatencyProbes();
    } else if (transport.type === "game.message") {
      const snapshot = transport.payload?.__playmeshSyncSnapshot;
      if (snapshot) applySyncSnapshot(snapshot);
      else emit(messageListeners, transport.payload);
    } else if (transport.type === "session.pong") {
      handleLatencyPong(transport.payload);
    } else if (transport.type === "authority.ping") {
      post("performance.pong", transport.payload, {
        targetPlayerId: transport.senderPlayerId,
      }).catch(() => {});
    } else if (transport.type === "authority.action") {
      dispatchAuthorityAction(transport).catch((error) => {
        emit(lifecycleListeners, { state: "error", error: String(error) });
      });
    }
  }

  async function connectBrowser(config) {
    if (config.mode === "solo") {
      bootstrap = {
        type: "sdk.bootstrap",
        sdkVersion: PLAYMESH_SDK_VERSION,
        gameInfo: {
          id: config.gameId,
          name: config.gameName,
          tags: [...(config.tags || [])],
          multiplayer: false,
          displayMode: "solo",
          requiredCapabilities: [...(config.requiredCapabilities || [])],
        },
        isAuthority: false,
        player: null,
        session: null,
      };
      emit(lifecycleListeners, { state: "ready" });
      configureClientPerformance();
      return bootstrap;
    }
    const appIdentity = appSdk.isAvailable()
      ? appSdk.identity.getCurrent()
      : null;
    const preferredNickname = appIdentity?.nickname || config.nickname;
    const nickname = preferredNickname
      ? validateNickname(preferredNickname, false)
      : await resolveBrowserNickname();
    if (!appIdentity && config.nickname) writeBrowserNickname(nickname);
    const playerId = appIdentity?.userId || resolveBrowserPlayerId();
    browserConnectionConfig = {
      ...config,
      nickname,
      playerId,
    };
    const joined = await joinBrowserWithRetry(browserConnectionConfig);
    applyBrowserJoin(config, joined);
    try {
      await connectBrowserSocket(config, joined);
      if (appSdk.isAvailable() &&
          typeof appInternalRuntime.syncAvatar === "function") {
        appInternalRuntime.syncAvatar(
          joined.session.id,
          joined.credential.token,
        ).catch((error) => {
          global.console?.warn?.("Playmesh App 头像同步失败，游戏将继续", error);
        });
      }
    } catch (error) {
      global.console?.warn?.("Playmesh 主会话 WebSocket 首次连接失败，将开始重连", {
        error: error?.message || String(error),
      });
      browserReconnectOperation = reconnectBrowserSocket()
        .finally(() => {
          browserReconnectOperation = null;
          if (!runtimeExited &&
              browserConnectionConfig &&
              browserSocket?.readyState !== global.WebSocket.OPEN) {
            scheduleBrowserReconnect();
          }
        });
      await browserReconnectOperation;
    }
    emit(sessionListeners, bootstrap.session);
    emit(lifecycleListeners, { state: "ready" });
    configureClientPerformance();
    startLatencyProbes();
    void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
    return bootstrap;
  }

  function applyBrowserJoin(config, joined) {
    browserCredential = joined.credential;
    const core = new URL(config.coreBase);
    const binarySocketUrl = new URL(joined.binaryWebSocketPath, core);
    binarySocketUrl.protocol = core.protocol === "https:" ? "wss:" : "ws:";
    binarySocketUrl.searchParams.set("token", joined.credential.token);
    binaryTransportConfig = { url: binarySocketUrl.toString() };
    if (joined.credential.reconnected) {
      previouslyConnectedPlayerIds.add(joined.credential.player.id);
    }
    // Core 可能在套接字打开后立即发布连接快照，因此先建立 bootstrap，
    // 让提前到达的 session.state 可以安全更新它。
    bootstrap = {
      type: "sdk.bootstrap",
      sdkVersion: PLAYMESH_SDK_VERSION,
      gameInfo: {
        id: joined.session.gameId,
        name: config.gameName,
        tags: [...(config.tags || [])],
        multiplayer: true,
        displayMode: joined.session.displayMode || config.displayMode,
        requiredCapabilities: [...(config.requiredCapabilities || [])],
      },
      isAuthority: false,
      player: publicPlayer(joined.credential.player),
      session: publicSession(joined.session),
    };
  }

  async function joinBrowserWithRetry(config) {
    const attempts = 30;
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      try {
        return await joinBrowser(config);
      } catch (error) {
        if (!["session_full", "player_connected"].includes(error.code) || attempt === attempts) throw error;
        await new Promise((resolve) => global.setTimeout(resolve, 200));
      }
    }
  }

  async function joinBrowser(config) {
    const response = await fetch(new URL("v1/sessions/join", config.coreBase), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        joinCode: config.joinCode,
        nickname: config.nickname,
        shareToken: config.shareToken,
        playerId: config.playerId,
        source: config.playerSource || (appSdk.isAvailable() ? "lan_app" : "lan_html"),
      }),
    });
    const joined = await response.json();
    if (!response.ok) {
      const error = new Error(joined.error?.message || "加入对局失败");
      error.code = joined.error?.code;
      throw error;
    }
    return joined;
  }

  async function connectBrowserSocket(config, joined) {
    const core = new URL(config.coreBase);
    const socketUrl = new URL(joined.webSocketPath, core);
    socketUrl.protocol = core.protocol === "https:" ? "wss:" : "ws:";
    socketUrl.searchParams.set("token", joined.credential.token);
    const socket = new WebSocket(socketUrl);
    browserSocket = socket;
    let opened = false;
    // 必须在等待打开前订阅，避免首个连接快照落在 open 事件与监听注册之间。
    socket.addEventListener("message", (event) => {
      receive({ type: "transport.message", message: JSON.parse(event.data) });
    });
    socket.addEventListener("close", (event) => {
      if (browserSocket !== socket) return;
      browserSocket = null;
      if (opened) {
        receive({
          type: "transport.closed",
          error: event?.reason || (event?.code ? `close code ${event.code}` : undefined),
        });
      }
    });
    try {
      await new Promise((resolve, reject) => {
        socket.addEventListener("open", () => {
          opened = true;
          resolve();
        }, { once: true });
        socket.addEventListener(
          "error",
          () => reject(new Error("无法连接主机会话")),
          { once: true },
        );
        socket.addEventListener(
          "close",
          () => {
            if (!opened) reject(new Error("主会话 WebSocket 在连接完成前关闭"));
          },
          { once: true },
        );
      });
    } catch (error) {
      if (browserSocket === socket) browserSocket = null;
      if (socket.readyState < global.WebSocket.CLOSING) socket.close();
      throw error;
    }
  }

  function scheduleBrowserReconnect() {
    if (runtimeExited || !browserConnectionConfig || browserReconnectOperation) return;
    browserReconnectOperation = reconnectBrowserSocket()
      .finally(() => {
        browserReconnectOperation = null;
        if (!runtimeExited &&
            browserConnectionConfig &&
            browserSocket?.readyState !== global.WebSocket.OPEN) {
          scheduleBrowserReconnect();
        }
      });
    void browserReconnectOperation.catch(() => {});
  }

  async function reconnectBrowserSocket() {
    let attempt = 0;
    while (!runtimeExited && browserConnectionConfig) {
      attempt += 1;
      await waitForReconnect(attempt);
      global.console?.info?.("Playmesh 主会话 WebSocket 正在重连", { attempt });
      try {
        const previousSession = bootstrap?.session;
        const joined = await joinBrowser(browserConnectionConfig);
        applyBrowserJoin(browserConnectionConfig, joined);
        await connectBrowserSocket(browserConnectionConfig, joined);
        if (appSdk.isAvailable() &&
            typeof appInternalRuntime.syncAvatar === "function") {
          void appInternalRuntime.syncAvatar(
            joined.session.id,
            joined.credential.token,
          ).catch(() => {});
        }
        emitPlayerConnectionChanges(previousSession, bootstrap.session);
        emit(sessionListeners, bootstrap.session);
        startLatencyProbes();
        global.console?.info?.("Playmesh 主会话 WebSocket 重连成功", { attempt });
        if (binaryReconnectWanted) {
          void ensureBinarySocket().catch(() => {});
        }
        if (!bootstrap.isAuthority) {
          void submitSyncEnvelope("snapshot.request", {}).catch(() => {});
        }
        return browserSocket;
      } catch (error) {
        if (runtimeExited) break;
        global.console?.warn?.("Playmesh 主会话 WebSocket 重连失败，将继续重试", {
          attempt,
          error: error?.message || String(error),
          retryInMs: reconnectDelay(attempt + 1),
        });
      }
    }
    throw new Error("游戏页面已退出，停止主会话 WebSocket 重连");
  }

  const PLAYMESH_APP_INTERNAL_KEY =
    Symbol.for("playmesh.app.internal.v1");
  const appInternalRuntime = global[PLAYMESH_APP_INTERNAL_KEY];
  const appSdk = appInternalRuntime?.publicApi;
  if (!appInternalRuntime || !appSdk) {
    throw new Error(
      "Playmesh App SDK 未注入；playmesh-app.js 必须先于 playmesh-main.js 加载",
    );
  }
  function takeAppPlatformUiConfiguration() {
    return appInternalRuntime.takePlatformUiConfiguration?.() || null;
  }
  let browserPlatformUiCatalog =
    global.__PLAYMESH_BROWSER__?._playmeshPlatformUi || null;
  if (global.__PLAYMESH_BROWSER__ &&
      typeof global.__PLAYMESH_BROWSER__ === "object") {
    delete global.__PLAYMESH_BROWSER__._playmeshPlatformUi;
  }
  let platformUiLocale = null;
  let runtimeLocale = null;
  let browserRuntimeLocale = null;
  let runtimeLocaleUsesBrowserSystem = false;
  let platformUiMessages = Object.freeze({});
  let platformUiThemeMode = "system";
  let platformUiTheme = "dark";
  const platformUiDarkModeQuery =
    global.matchMedia?.("(prefers-color-scheme: dark)") || null;
  const BROWSER_RUNTIME_LOCALE_FALLBACK = "zh";
  const BROWSER_PLATFORM_UI_FALLBACK_LOCALE = "zh-CN";

  function effectivePlatformUiTheme(mode) {
    if (mode === "light" || mode === "dark") return mode;
    return platformUiDarkModeQuery?.matches === false ? "light" : "dark";
  }

  function normalizePlatformUiLocaleId(value) {
    if (typeof value !== "string") return null;
    const normalized = value.trim();
    return /^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8}){0,2}$/.test(normalized)
      ? normalized
      : null;
  }

  function browserLocalePreferences() {
    try {
      const navigatorObject = global.navigator;
      const rawValues = [];
      if (Array.isArray(navigatorObject?.languages)) {
        rawValues.push(...navigatorObject.languages);
      }
      rawValues.push(navigatorObject?.language);
      const seen = new Set();
      const locales = [];
      for (const value of rawValues) {
        const locale = normalizePlatformUiLocaleId(value);
        if (!locale) continue;
        const normalized = locale.toLowerCase();
        if (seen.has(normalized)) continue;
        seen.add(normalized);
        locales.push(locale);
      }
      return locales;
    } catch (_) {
      return [];
    }
  }

  function resolveBrowserPlatformUiConfiguration(catalog, preferences) {
    const rawConfigurations = Array.isArray(catalog?.locales)
      ? catalog.locales
      : [];
    const configurations = rawConfigurations.filter((configuration) => {
      const locale = normalizePlatformUiLocaleId(configuration?.locale);
      const messages = configuration?.messages;
      return Boolean(
        locale &&
        messages &&
        typeof messages === "object" &&
        !Array.isArray(messages) &&
        Object.keys(messages).length > 0,
      );
    });
    const fallback = configurations.find(
      (configuration) =>
        configuration.locale.toLowerCase() ===
          BROWSER_PLATFORM_UI_FALLBACK_LOCALE.toLowerCase(),
    );
    if (!fallback) {
      throw new Error(
        `Browser platform UI ${BROWSER_PLATFORM_UI_FALLBACK_LOCALE} fallback is unavailable`,
      );
    }
    for (const preference of preferences) {
      const exact = configurations.find(
        (configuration) =>
          configuration.locale.toLowerCase() === preference.toLowerCase(),
      );
      if (exact) return exact;
    }
    for (const preference of preferences) {
      const language = preference.split("-")[0].toLowerCase();
      const languageMatch = configurations.find(
        (configuration) =>
          configuration.locale.split("-")[0].toLowerCase() === language,
      );
      if (languageMatch) return languageMatch;
    }
    return fallback;
  }

  function takeBrowserPlatformUiConfiguration() {
    const catalog = browserPlatformUiCatalog;
    browserPlatformUiCatalog = null;
    const preferences = browserLocalePreferences();
    browserRuntimeLocale =
      preferences[0] || BROWSER_RUNTIME_LOCALE_FALLBACK;
    return resolveBrowserPlatformUiConfiguration(catalog, preferences);
  }

  function configurePlatformUi(configuration, exposedLocale) {
    const locale = normalizePlatformUiLocaleId(configuration?.locale);
    const normalizedExposedLocale = normalizePlatformUiLocaleId(
      exposedLocale || locale,
    );
    const messages = configuration?.messages;
    const themeMode = configuration?.theme || "system";
    if (!locale ||
        !normalizedExposedLocale ||
        !["system", "light", "dark"].includes(themeMode) ||
        !messages ||
        typeof messages !== "object" ||
        Array.isArray(messages)) {
      throw new Error("Platform UI localization configuration is invalid");
    }
    const entries = Object.entries(messages);
    if (entries.length === 0) {
      throw new Error("Platform UI localization messages are empty");
    }
    for (const [key, value] of entries) {
      if (!/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/.test(key) ||
          typeof value !== "string") {
        throw new Error("Platform UI localization messages must be strings");
      }
    }
    platformUiLocale = locale;
    runtimeLocale = normalizedExposedLocale;
    platformUiMessages = Object.freeze({ ...messages });
    platformUiThemeMode = themeMode;
    platformUiTheme = effectivePlatformUiTheme(themeMode);
    refreshCapabilityConsentUi(capabilityConsentUi);
    refreshBrowserPlatformUi(browserNicknameUi);
  }

  function platformUiSystemThemeChanged() {
    if (platformUiThemeMode !== "system") return;
    platformUiTheme = effectivePlatformUiTheme("system");
    refreshCapabilityConsentUi(capabilityConsentUi);
    refreshBrowserPlatformUi(browserNicknameUi);
  }
  platformUiDarkModeQuery?.addEventListener?.(
    "change",
    platformUiSystemThemeChanged,
  );

  function platformText(key, argumentsMap = {}) {
    const template = platformUiMessages[key];
    if (typeof template !== "string") {
      throw new Error(`Platform UI localization message is unavailable: ${key}`);
    }
    return template.replace(/\{([A-Za-z0-9_]+)\}/g, (_, name) =>
      String(argumentsMap[name] ?? ""));
  }

  function platformHtml(key, argumentsMap = {}) {
    return escapeCapabilityHtml(platformText(key, argumentsMap));
  }

  function isPlatformUiEditableTarget(target) {
    if (!target) return false;
    if (target.isContentEditable === true) return true;
    const tagName = String(target.tagName || "").toLowerCase();
    return tagName === "input" || tagName === "textarea" || tagName === "select";
  }

  function platformUiEventKey(event) {
    if (typeof event?.key === "string" && event.key.length > 0) {
      return event.key;
    }
    return {
      8: "Backspace",
      9: "Tab",
      13: "Enter",
      27: "Escape",
      32: " ",
      35: "End",
      36: "Home",
      37: "ArrowLeft",
      38: "ArrowUp",
      39: "ArrowRight",
      40: "ArrowDown",
    }[event?.keyCode] || "";
  }

  function isPlatformUiBackEvent(event) {
    const key = platformUiEventKey(event);
    if (key === "Escape" ||
        key === "Esc" ||
        key === "Back" ||
        key === "BrowserBack" ||
        key === "GoBack" ||
        key === "XF86Back" ||
        event?.keyCode === 4 ||
        event?.keyCode === 461 ||
        event?.keyCode === 10009) {
      return true;
    }
    return key === "Backspace" && !isPlatformUiEditableTarget(event?.target);
  }

  function isPlatformUiMenuEvent(event) {
    const key = platformUiEventKey(event);
    return key === "F10" ||
      key === "ContextMenu" ||
      key === "Menu" ||
      event?.keyCode === 82 ||
      event?.keyCode === 93 ||
      event?.keyCode === 121;
  }

  function platformUiControls(value) {
    const raw = typeof value === "function" ? value() : value;
    return Array.from(raw || []).filter(
      (control) =>
        control &&
        !control.hidden &&
        !control.disabled &&
        control.getAttribute?.("aria-hidden") !== "true",
    );
  }

  function focusPlatformUiControl(control) {
    if (!control || control.hidden || control.disabled ||
        typeof control.focus !== "function") {
      return false;
    }
    try {
      control.focus({ preventScroll: true });
    } catch (_) {
      control.focus();
    }
    return true;
  }

  function setPlatformUiRovingTabStop(controls, activeControl) {
    const available = platformUiControls(controls);
    const active = available.includes(activeControl)
      ? activeControl
      : available[0] || null;
    for (const control of available) {
      control.setAttribute?.("tabindex", control === active ? "0" : "-1");
    }
    return active;
  }

  function consumePlatformUiKey(event) {
    event?.preventDefault?.();
    event?.stopPropagation?.();
  }

  function activatePlatformUiControl(control) {
    if (!control || control.disabled) return;
    if (typeof control.click === "function") {
      control.click();
      return;
    }
    control.onclick?.({
      currentTarget: control,
      target: control,
      preventDefault() {},
      stopPropagation() {},
    });
  }

  function installPlatformUiKeyboardNavigation(
    container,
    controls,
    { roving = false, trap = false, onBack = null } = {},
  ) {
    if (!container?.addEventListener) return;
    if (roving) setPlatformUiRovingTabStop(controls, null);
    container.addEventListener("keydown", (event) => {
      if (isPlatformUiBackEvent(event)) {
        consumePlatformUiKey(event);
        onBack?.();
        return;
      }
      const available = platformUiControls(controls);
      if (available.length === 0) return;
      const currentIndex = available.indexOf(event.target);
      const key = platformUiEventKey(event);
      if (trap && key === "Tab") {
        consumePlatformUiKey(event);
        const nextIndex = event.shiftKey
          ? (currentIndex <= 0 ? available.length - 1 : currentIndex - 1)
          : (currentIndex < 0 || currentIndex === available.length - 1
              ? 0
              : currentIndex + 1);
        focusPlatformUiControl(available[nextIndex]);
        return;
      }
      if (isPlatformUiEditableTarget(event.target)) return;
      if ((key === "Enter" || key === " " ||
          key === "Spacebar") && currentIndex >= 0) {
        consumePlatformUiKey(event);
        activatePlatformUiControl(available[currentIndex]);
        return;
      }
      let nextIndex = null;
      if (key === "Home") {
        nextIndex = 0;
      } else if (key === "End") {
        nextIndex = available.length - 1;
      } else if (key === "ArrowRight" || key === "ArrowDown") {
        nextIndex = currentIndex < 0
          ? 0
          : (currentIndex + 1) % available.length;
      } else if (key === "ArrowLeft" || key === "ArrowUp") {
        nextIndex = currentIndex <= 0
          ? available.length - 1
          : currentIndex - 1;
      }
      if (nextIndex == null) return;
      consumePlatformUiKey(event);
      const next = available[nextIndex];
      if (roving) setPlatformUiRovingTabStop(available, next);
      focusPlatformUiControl(next);
    });
  }

  function openPlatformUiLayer(layer, initialFocus, returnFocus = null) {
    if (!layer) return;
    layer.__playmeshReturnFocus =
      returnFocus ||
      layer.getRootNode?.().activeElement ||
      global.document?.activeElement ||
      null;
    layer.hidden = false;
    global.setTimeout(() => focusPlatformUiControl(initialFocus), 0);
  }

  function closePlatformUiLayer(layer, fallbackFocus = null) {
    if (!layer) return;
    const returnFocus = layer.__playmeshReturnFocus || fallbackFocus;
    layer.__playmeshReturnFocus = null;
    layer.hidden = true;
    global.setTimeout(
      () => focusPlatformUiControl(returnFocus || fallbackFocus),
      0,
    );
  }

  function normalizeCapabilityList(value) {
    if (!Array.isArray(value)) return [];
    return [...new Set(value.filter((item) => typeof item === "string" && item.length > 0))];
  }

  function capabilityConsentContext(appBootstrap) {
    const browserConfig = global.__PLAYMESH_BROWSER__;
    const declaredForCurrentPage = browserConfig
      ? browserConfig.requiredCapabilities
      : appSdk.isAvailable()
        ? appSdk.capabilities.getDeclared?.()
        : appBootstrap?.device?.declaredCapabilities;
    const required = normalizeCapabilityList(declaredForCurrentPage);
    const available = normalizeCapabilityList(
      appSdk.isAvailable()
        ? appBootstrap?.device?.capabilities || appSdk.capabilities.getAvailable()
        : browserConfig?.availableCapabilities,
    );
    const definitions = Array.isArray(browserConfig?.capabilityRegistry)
      ? browserConfig.capabilityRegistry
      : Array.isArray(appBootstrap?.capabilityRegistry)
        ? appBootstrap.capabilityRegistry
        : [];
    return {
      gameName:
        browserConfig?.gameName || platformText("capability.current_game"),
      required,
      available: new Set(available),
      definitions: new Map(definitions.map((definition) => [definition.code, definition])),
    };
  }

  const platformCapabilityMessageRoots = new Map([
    ["media.camera", "capability.media.camera"],
    ["media.microphone", "capability.media.microphone"],
    ["device.midi", "capability.device.midi"],
    ["device.vibration", "capability.device.vibration"],
  ]);

  function capabilityDisplayText(capability, definition) {
    const messageRoot = platformCapabilityMessageRoots.get(capability);
    if (messageRoot) {
      return {
        name: platformText(`${messageRoot}.name`),
        description: platformText(`${messageRoot}.description`),
      };
    }
    return {
      name: definition?.name || capability,
      description: definition?.description || "",
    };
  }

  async function requestCapabilityConsent(appBootstrap) {
    const context = capabilityConsentContext(appBootstrap);
    if (context.required.length === 0) return;
    const document = global.document;
    if (!document) throw new Error("当前页面无法显示游戏能力确认");
    if (!document.body) {
      await new Promise((resolve) => document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    capabilityConsentUi?.host.remove();
    const returnFocus = document.activeElement || null;
    const host = document.createElement("div");
    host.id = "playmesh-capability-consent";
    host.setAttribute("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    const rows = context.required.map((capability) => {
      const definition = context.definitions.get(capability);
      const displayText = capabilityDisplayText(capability, definition);
      const label = displayText.name;
      const descriptionText = displayText.description;
      const description = descriptionText
        ? `<em class="capability-description">${escapeCapabilityHtml(descriptionText)}</em>`
        : "";
      const unsupported = context.available.has(capability)
        ? ""
        : `<span class="unsupported">${platformHtml("capability.unsupported")}</span>`;
      return `<li data-capability="${escapeCapabilityHtml(capability)}"><span><strong class="capability-name">${escapeCapabilityHtml(label)}</strong>${description}<small>${escapeCapabilityHtml(capability)}</small></span>${unsupported}</li>`;
    }).join("");
    root.innerHTML = `<style>
      :host{all:initial;--pm-overlay:#050b12e8;--pm-surface:#18201d;--pm-text:#f8fafc;--pm-muted:#cbd5e1;--pm-border:#ffffff24;--pm-row:#ffffff0a;--pm-row-border:#ffffff18;--pm-secondary-bg:#ffffff0b;--pm-secondary-border:#ffffff30;--pm-secondary-text:#e2e8f0;--pm-focus:#78a6ff;--pm-warning:#fbbf24;font-family:system-ui,"Microsoft YaHei",sans-serif;letter-spacing:0;color-scheme:dark}
      :host([data-theme="light"]){--pm-overlay:#e8edf4d9;--pm-surface:#ffffff;--pm-text:#17202b;--pm-muted:#526071;--pm-border:#9aa8b8;--pm-row:#f3f6f9;--pm-row-border:#d5dde6;--pm-secondary-bg:#f5f7fa;--pm-secondary-border:#98a6b6;--pm-secondary-text:#1f2937;--pm-focus:#075dce;--pm-warning:#8a4b00;color-scheme:light}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;box-sizing:border-box;padding:max(16px,env(safe-area-inset-top)) max(16px,env(safe-area-inset-right)) max(16px,env(safe-area-inset-bottom)) max(16px,env(safe-area-inset-left));background:var(--pm-overlay);color:var(--pm-text)}
      .card{box-sizing:border-box;display:flex;max-height:calc(100vh - 32px);max-height:calc(100dvh - 32px);width:min(100%,460px);padding:26px;flex-direction:column;overflow:hidden;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface);box-shadow:0 20px 56px #0005}
      .content{min-height:0;overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;scrollbar-gutter:stable;-webkit-overflow-scrolling:touch}
      h2{margin:0;font-size:25px;line-height:1.3}p{margin:10px 0 18px;color:var(--pm-muted);font-size:14px;line-height:1.7}
      ul{display:grid;gap:10px;margin:0;padding:0;list-style:none}li{display:flex;align-items:center;justify-content:space-between;gap:14px;padding:13px 14px;border:1px solid var(--pm-row-border);border-radius:8px;background:var(--pm-row)}
      strong{display:block;font-size:15px}em{display:block;margin-top:4px;color:var(--pm-muted);font:normal 12px/1.5 system-ui}small{display:block;margin-top:4px;color:var(--pm-muted);font-size:11px}.unsupported{flex:none;color:var(--pm-warning);font-size:12px}
      .actions{display:flex;flex:none;gap:10px;margin-top:18px}.actions button{min-height:46px;flex:1;border-radius:8px;font:700 14px/1 system-ui;cursor:pointer;touch-action:manipulation}.actions button:focus-visible{outline:3px solid var(--pm-focus);outline-offset:2px}
      .deny{border:1px solid var(--pm-secondary-border);background:var(--pm-secondary-bg);color:var(--pm-secondary-text)}.allow{border:0;background:#087f6d;color:#fff}
      @media (max-height:440px),(max-width:420px){.overlay{padding:10px}.card{max-height:calc(100vh - 20px);max-height:calc(100dvh - 20px);padding:16px;border-radius:8px}h2{font-size:20px}p{margin:6px 0 10px;line-height:1.45}ul{gap:7px}li{padding:9px 10px}.actions{margin-top:10px}.actions button{min-height:42px}}
    </style><div class="overlay" role="dialog" aria-modal="true" aria-labelledby="capability-title"><div class="card"><div class="content"><h2 class="capability-title" id="capability-title">${platformHtml("capability.title", { gameName: context.gameName })}</h2><p class="capability-copy">${platformHtml("capability.description")}</p><ul>${rows}</ul></div><div class="actions"><button class="deny" type="button" aria-label="${platformHtml("capability.deny")}">${platformHtml("capability.deny")}</button><button class="allow" type="button" aria-label="${platformHtml("capability.allow")}">${platformHtml("capability.allow")}</button></div></div></div>`;
    document.body.appendChild(host);
    capabilityConsentUi = { host, root, context, denied: false };
    const deny = root.querySelector(".deny");
    const allow = root.querySelector(".allow");
    const decision = await new Promise((resolve) => {
      allow.addEventListener("click", () => resolve("allow"), { once: true });
      deny.addEventListener("click", () => resolve("deny"), { once: true });
      installPlatformUiKeyboardNavigation(
        root,
        () => [deny, allow],
        {
          trap: true,
          onBack: () => resolve("back"),
        },
      );
      global.setTimeout(() => focusPlatformUiControl(deny), 0);
    });
    if (decision === "allow") {
      if (appSdk.isAvailable() &&
          typeof appInternalRuntime.confirmCapabilities === "function") {
        await appInternalRuntime.confirmCapabilities();
      }
      host.remove();
      capabilityConsentUi = null;
      focusPlatformUiControl(returnFocus);
      return;
    }
    if (decision === "deny") {
      root.querySelector(".actions").remove();
      capabilityConsentUi.denied = true;
      root.querySelector(".capability-copy").textContent =
        platformText("capability.denied");
    }
    const error = new Error("用户拒绝了当前游戏的能力请求");
    error.code = "capability_denied";
    if (appSdk.isAvailable() &&
        typeof appInternalRuntime.requestExit === "function") {
      await appInternalRuntime.requestExit().catch(() => {});
    } else if (global.history?.length > 1) {
      global.setTimeout(() => global.history.back(), 0);
    }
    if (decision === "back") {
      host.remove();
      capabilityConsentUi = null;
      focusPlatformUiControl(returnFocus);
    }
    throw error;
  }

  function refreshCapabilityConsentUi(ui) {
    if (!ui?.root) return;
    ui.host?.setAttribute?.("data-theme", platformUiTheme);
    const title = ui.root.querySelector?.(".capability-title");
    if (title) {
      title.textContent = platformText("capability.title", {
        gameName: ui.context.gameName,
      });
    }
    const copy = ui.root.querySelector?.(".capability-copy");
    if (copy) {
      copy.textContent = platformText(
        ui.denied ? "capability.denied" : "capability.description",
      );
    }
    const deny = ui.root.querySelector?.(".deny");
    if (deny) {
      deny.textContent = platformText("capability.deny");
      deny.setAttribute?.("aria-label", platformText("capability.deny"));
    }
    const allow = ui.root.querySelector?.(".allow");
    if (allow) {
      allow.textContent = platformText("capability.allow");
      allow.setAttribute?.("aria-label", platformText("capability.allow"));
    }
    for (const element of ui.root.querySelectorAll?.(".unsupported") || []) {
      element.textContent = platformText("capability.unsupported");
    }
    for (const row of ui.root.querySelectorAll?.("[data-capability]") || []) {
      const capability = row.getAttribute?.("data-capability");
      if (!capability) continue;
      const definition = ui.context.definitions.get(capability);
      const displayText = capabilityDisplayText(capability, definition);
      const name = row.querySelector?.(".capability-name");
      const description = row.querySelector?.(".capability-description");
      if (name) {
        name.textContent = displayText.name;
      }
      if (description) {
        description.textContent = displayText.description;
      }
    }
  }

  function escapeCapabilityHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#39;");
  }

  const standardStorageRevisions = new Map();
  const standardStorageBucketOperations = new Map();
  const main = {
    version: PLAYMESH_SDK_VERSION,
    ready: null,
    gameInfo: Object.freeze({
      getCurrent() {
        const info = bootstrap?.gameInfo;
        if (!info) return null;
        return {
          ...info,
          requiredCapabilities: [...(info.requiredCapabilities || [])],
        };
      },
    }),
    session: {
      onStateChange(callback) {
        const unsubscribe = subscribe(sessionListeners, callback);
        if (bootstrap) callback(bootstrap.session);
        return unsubscribe;
      },
      onPlayerJoin(callback) {
        return subscribe(playerJoinListeners, callback);
      },
      onPlayerLeave(callback) {
        return subscribe(playerLeaveListeners, callback);
      },
      onPlayerReconnect(callback) {
        return subscribe(playerReconnectListeners, callback);
      },
      isAuthority() {
        return Boolean(bootstrap && bootstrap.isAuthority);
      },
      getCurrent() {
        return bootstrap && bootstrap.session;
      },
      start() {
        return post("session.start", {}).then(publicSession);
      },
      finish() {
        return post("session.finish", {}).then(publicSession);
      },
    },
    player: {
      getCurrent() {
        return bootstrap && bootstrap.player;
      },
      setNickname(nickname) {
        if (!global.__PLAYMESH_BROWSER__ || appSdk.isAvailable()) {
          return Promise.reject(new Error("修改昵称仅适用于浏览器玩家"));
        }
        if (global.__PLAYMESH_BROWSER__.mode === "solo") {
          return Promise.reject(new Error("单机分享没有玩家昵称"));
        }
        return updateBrowserNickname(nickname);
      },
    },
    game: {
      submitAction(action, options) {
        return post("game.submitAction", encodeAuthorityAction(action, options));
      },
      onMessage(callback) {
        return subscribe(messageListeners, callback);
      },
      onEvent(callback) {
        return subscribe(messageListeners, callback);
      },
    },
    authority: {
      defaultNamespace: DEFAULT_AUTHORITY_SERVICE_NAMESPACE,
      onService: registerAuthorityService,
    },
    binary: {
      authorityPlayerId: "authority",
      async createChannel(options) {
        await main.ready;
        if (!main.session.isAuthority()) {
          throw new Error("只有 Authority 可以创建 Binary Channel");
        }
        const mode = binaryModeCode(options?.mode);
        const result = await binaryRequest(
          (requestId) => encodeBinaryCreate(requestId, mode),
          { expectsChannel: true },
        );
        return createBinaryChannelHandle(result.id, result.mode);
      },
      async joinChannel(channelId) {
        await main.ready;
        const normalized = binaryChannelIdFromBytes(binaryChannelIdToBytes(channelId));
        const existing = binaryChannels.get(normalized);
        if (existing && !existing.closed) return existing.handle;
        const result = await binaryRequest(
          (requestId) => encodeBinaryChannelOperation(BINARY_OP_JOIN, requestId, normalized),
          { expectsChannel: true },
        );
        return createBinaryChannelHandle(result.id, result.mode);
      },
    },
    sync: {
      startAuthority: startSyncAuthority,
      submitAction(payload) {
        return submitSyncEnvelope("input.action", payload);
      },
      submitState: submitStateInput,
      requestSnapshot() {
        return submitSyncEnvelope("snapshot.request", {});
      },
      getSnapshot() {
        return currentSyncSnapshot && cloneJson(currentSyncSnapshot, "同步快照");
      },
      observe(callback) {
        const unsubscribe = subscribe(syncListeners, callback);
        if (currentSyncSnapshot) callback(cloneJson(currentSyncSnapshot, "同步快照"));
        return unsubscribe;
      },
    },
    lifecycle: {
      onChange(callback) {
        return subscribe(lifecycleListeners, callback);
      },
      onPause(callback) {
        return subscribe(pauseListeners, callback);
      },
      onResume(callback) {
        return subscribe(resumeListeners, callback);
      },
      onExit(callback) {
        return subscribe(exitListeners, callback);
      },
    },
    storage: {
      getBucket(bucket) {
        validateSynchronousStorageBucketName(bucket);
        return {
          getData(key) {
            validateStorageName(bucket, "bucket");
            validateStorageName(key, "key");
            return storageCall("storage.get", bucket, key);
          },
          setData(key, value) {
            validateStorageName(bucket, "bucket");
            validateStorageName(key, "key");
            JSON.stringify(value);
            return storageCall("storage.set", bucket, key, value);
          },
          getDataSync(key) {
            validateSynchronousStorageKey(key);
            return storageCallSync("sync.get", bucket, key);
          },
          setDataSync(key, value) {
            validateSynchronousStorageKey(key);
            JSON.stringify(value);
            storageCallSync("sync.set", bucket, key, value);
          },
          removeData(key) {
            validateStorageName(bucket, "bucket");
            validateStorageName(key, "key");
            return storageCall("storage.remove", bucket, key);
          },
          clearData() {
            validateStorageName(bucket, "bucket");
            return storageCall("storage.clear", bucket);
          },
          upload(file) {
            validateStorageName(bucket, "bucket");
            return storageUpload(bucket, file);
          },
        };
      },
    },
  };

  const PLAYMESH_MAIN_INTERNAL_KEY =
    Symbol.for("playmesh.main.internal.v1");
  Object.defineProperty(global, PLAYMESH_MAIN_INTERNAL_KEY, {
    value: Object.freeze({ receive }),
    configurable: true,
    enumerable: false,
    writable: false,
  });
  registerAppPlatformUiRuntime();
  if (global.chrome && global.chrome.webview) {
    global.chrome.webview.addEventListener("message", (event) => receive(event.data));
  }
  global.addEventListener?.("pagehide", () => {
    const refreshing = global.__playmeshDevelopmentRefreshRequested === true;
    markRuntimeExited(refreshing ? "开发游戏页面正在重启" : "游戏页面已退出");
  });
  let readyAppBootstrap = null;
  main.ready = (async () => {
    const appBootstrap = await appSdk.ready;
    readyAppBootstrap = appBootstrap;
    const runtimeGameDeclaration = global.__PLAYMESH_BROWSER__;
    if (runtimeGameDeclaration &&
        appSdk.isAvailable() &&
        typeof appInternalRuntime.configureRuntimeGame === "function") {
      await appInternalRuntime.configureRuntimeGame({
        requiredCapabilities:
          runtimeGameDeclaration.requiredCapabilities || [],
      });
    }
    const appPlatformUiConfiguration = takeAppPlatformUiConfiguration();
    const platformUiConfiguration = appPlatformUiConfiguration ||
      takeBrowserPlatformUiConfiguration();
    if (appPlatformUiConfiguration) browserPlatformUiCatalog = null;
    runtimeLocaleUsesBrowserSystem = !appPlatformUiConfiguration;
    configurePlatformUi(
      platformUiConfiguration,
      appPlatformUiConfiguration?.locale || browserRuntimeLocale,
    );
    global.console?.info?.("Playmesh Game SDK 等待能力确认");
    await requestCapabilityConsent(appBootstrap);
    global.console?.info?.("Playmesh Game SDK 请求宿主就绪");
    return global.__PLAYMESH_BROWSER__
      ? connectBrowserFullscreen({
          ...global.__PLAYMESH_BROWSER__,
          ...(appBootstrap?.runtime?.coreBase
            ? { coreBase: appBootstrap.runtime.coreBase }
            : {}),
          ...(appBootstrap?.runtime?.playerSource
            ? { playerSource: appBootstrap.runtime.playerSource }
            : {}),
        })
      : post("sdk.ready", {});
  })();
  const ready = main.ready.then(
    (mainBootstrap) => Object.freeze({
      main: mainBootstrap,
      app: readyAppBootstrap,
    }),
  );
  global.playmesh = Object.freeze({
    ready,
    main,
    app: appSdk,
  });
  global.console?.info?.("Playmesh Game SDK 注入成功", {
    version: PLAYMESH_SDK_VERSION,
  });

  async function connectBrowserFullscreen(config) {
    if (appSdk.isAvailable() && typeof appSdk.device?.setFullscreen === "function") {
      try {
        await appSdk.device.setFullscreen(true, config.orientation);
        global.console?.info?.("Playmesh 扫码加入页面已自动进入全屏");
      } catch (error) {
        global.console?.warn?.("Playmesh 扫码加入页面自动全屏失败，游戏将继续", error);
      }
    } else {
      void requestBrowserFullscreen(config.orientation).catch((error) => {
        global.console?.info?.(
          "浏览器未允许自动全屏，可通过游戏菜单手动进入",
          error,
        );
      });
    }
    return connectBrowser(config);
  }

  function markRuntimeExited(reason) {
    if (runtimeExited) return;
    runtimeExited = true;
    browserConnectionConfig = null;
    const socket = browserSocket;
    browserSocket = null;
    if (socket && socket.readyState < global.WebSocket.CLOSING) {
      socket.close(1000, reason);
    }
    closeBinaryTransport(reason, true);
    stopLatencyProbes();
    global.console?.info?.(
      reason === "开发游戏页面正在重启"
        ? "Playmesh 开发游戏页面正在重启，已停止旧页面 WebSocket 重连"
        : "Playmesh 游戏页面已退出，停止 WebSocket 重连",
      { reason },
    );
  }

  async function lockBrowserOrientation(orientation) {
    if (orientation !== "landscape" && orientation !== "portrait") return;
    const lock = global.screen?.orientation?.lock;
    if (typeof lock !== "function") {
      throw new Error("当前浏览器不支持锁定屏幕方向");
    }
    await lock.call(global.screen.orientation, orientation);
  }

  async function requestBrowserFullscreen(orientation) {
    const target = global.document?.documentElement;
    if (!target || typeof target.requestFullscreen !== "function") {
      throw new Error("当前浏览器不支持全屏");
    }
    await target.requestFullscreen();
    await lockBrowserOrientation(orientation);
  }

  function storageCall(command, bucket, key, value) {
    const operation = command.slice("storage.".length);
    if (!["get", "set", "remove", "clear"].includes(operation)) {
      throw new Error(`未知存储操作: ${command}`);
    }
    const previous = standardStorageBucketOperations.get(bucket) || Promise.resolve();
    const current = previous
      .catch(() => {})
      .then(() => performStandardStorageCall(operation, bucket, key, value));
    standardStorageBucketOperations.set(bucket, current);
    current.then(
      () => {
        if (standardStorageBucketOperations.get(bucket) === current) {
          standardStorageBucketOperations.delete(bucket);
        }
      },
      () => {
        if (standardStorageBucketOperations.get(bucket) === current) {
          standardStorageBucketOperations.delete(bucket);
        }
      },
    );
    return current;
  }

  async function performStandardStorageCall(operation, bucket, key, value) {
    await main.ready;
    const gameId = bootstrap?.gameInfo?.id;
    if (typeof gameId !== "string" || !gameId) {
      throw new Error("当前游戏存储上下文不可用");
    }
    if (operation !== "get" && !standardStorageRevisions.has(bucket)) {
      await standardStorageRestRequest(
        "get",
        bucket,
        key === undefined ? "_playmesh_revision_probe" : key,
        undefined,
        gameId,
      );
    }
    return standardStorageRestRequest(operation, bucket, key, value, gameId);
  }

  async function standardStorageRestRequest(operation, bucket, key, value, gameId) {
    const requestId = standardStorageRequestId();
    const revision = standardStorageRevisions.get(bucket) || null;
    const envelope = operation === "get"
      ? {
          protocolVersion: "1.0.0",
          requestId,
          gameId,
          operation,
          bucket,
          key,
          revision,
        }
      : operation === "set"
        ? {
            protocolVersion: "1.0.0",
            requestId,
            gameId,
            operation,
            bucket,
            key,
            value,
            expectedRevision: revision,
          }
        : operation === "remove"
          ? {
              protocolVersion: "1.0.0",
              requestId,
              gameId,
              operation,
              bucket,
              key,
              expectedRevision: revision,
            }
          : {
              protocolVersion: "1.0.0",
              requestId,
              gameId,
              operation,
              bucket,
              expectedRevision: revision,
            };
    const body = JSON.stringify(envelope);
    const digest = await standardStorageSha256(body);
    const method = operation === "get"
      ? "GET"
      : operation === "set"
        ? "PUT"
        : "DELETE";
    const url = method === "PUT"
      ? "/bucket/_playmesh-json/v1"
      : `/bucket/_playmesh-json/v1?payload=${standardStorageBase64Url(
          standardStorageUtf8Bytes(body),
        )}`;
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const response = await global.fetch(url, {
          method,
          credentials: "same-origin",
          headers: {
            ...(method === "PUT" ? { "Content-Type": "application/json" } : {}),
            "X-Playmesh-Content-Sha256": digest,
          },
          ...(method === "PUT" ? { body } : {}),
        });
        let payload = null;
        try {
          payload = await response.json();
        } catch (error) {
          if (attempt === 0) {
            lastError = error;
            continue;
          }
          throw new Error("存储 HTTP 响应不是有效 JSON");
        }
        if (response.status >= 500 && attempt === 0) {
          lastError = new Error(
            payload?.error?.message || "存储网关暂时不可用",
          );
          continue;
        }
        if (!response.ok) {
          const error = new Error(
            payload?.error?.message || `存储 HTTP 请求失败: ${response.status}`,
          );
          error.code = payload?.error?.code || "storage_http_failed";
          throw error;
        }
        if (
          payload?.protocolVersion !== "1.0.0" ||
          payload?.requestId !== requestId
        ) {
          throw new Error("存储 HTTP 响应与请求不匹配");
        }
        const result = payload.result;
        if (!result ||
            typeof result !== "object" ||
            !/^[a-f0-9]{64}$/.test(result.revision || "")) {
          throw new Error("存储 HTTP 响应缺少有效修订号");
        }
        standardStorageRevisions.set(bucket, result.revision);
        if (operation === "get") {
          if (!Object.prototype.hasOwnProperty.call(result, "value")) {
            throw new Error("存储 HTTP 读取响应缺少 value");
          }
          return result.value;
        }
        return null;
      } catch (error) {
        lastError = error;
        if (attempt === 0 && error?.code == null) continue;
        throw error;
      }
    }
    throw new Error(
      `存储 HTTP 路由不可用: ${lastError?.message || lastError || "unknown"}`,
    );
  }

  function standardStorageRequestId() {
    const bytes = new Uint8Array(12);
    if (global.crypto?.getRandomValues) {
      global.crypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
    }
    const nonce = [...bytes]
      .map((item) => item.toString(16).padStart(2, "0"))
      .join("");
    return `storage-${Date.now().toString(36)}-${nonce}`;
  }

  async function standardStorageSha256(value) {
    if (!global.crypto?.subtle || typeof global.TextEncoder !== "function") {
      throw new Error("当前 WebView 不支持标准存储 SHA-256 校验");
    }
    const data = new global.TextEncoder().encode(value);
    const digest = await global.crypto.subtle.digest("SHA-256", data);
    return [...new Uint8Array(digest)]
      .map((item) => item.toString(16).padStart(2, "0"))
      .join("");
  }

  function storageCallSync(operation, bucket, key, value) {
    if (operation !== "sync.get" && operation !== "sync.set") {
      throw new Error(`未知同步存储操作: ${operation}`);
    }
    if (operation === "sync.set" && !standardStorageRevisions.has(bucket)) {
      storageCallSync("sync.get", bucket, key);
    }
    const requestId = standardStorageRequestId();
    const gameId = bootstrap?.gameInfo?.id ||
      global.__PLAYMESH_BROWSER__?.gameId ||
      "@playmesh-current-game";
    const revision = standardStorageRevisions.get(bucket) || null;
    const envelope = operation === "sync.get"
      ? {
          protocolVersion: "1.0.0",
          requestId,
          gameId,
          operation,
          bucket,
          key,
          revision,
        }
      : {
          protocolVersion: "1.0.0",
          requestId,
          gameId,
          operation,
          bucket,
          key,
          value,
          expectedRevision: revision,
        };
    const body = JSON.stringify(envelope);
    if (typeof body !== "string") {
      throw new Error("同步存储值必须可序列化为 JSON");
    }
    const digest = standardStorageSha256Sync(body);
    const result = synchronousStorageHttpRequest(
      operation === "sync.get" ? "GET" : "PUT",
      body,
      digest,
      requestId,
    );
    if (!result ||
        typeof result !== "object" ||
        !/^[a-f0-9]{64}$/.test(result.revision || "")) {
      throw new Error("同步存储响应缺少有效修订号");
    }
    standardStorageRevisions.set(bucket, result.revision);
    if (operation === "sync.get") {
      if (!Object.prototype.hasOwnProperty.call(result, "value")) {
        throw new Error("同步存储读取响应缺少 value");
      }
      return result.value;
    }
  }

  function synchronousStorageHttpRequest(method, body, digest, requestId) {
    if (typeof global.XMLHttpRequest !== "function") {
      throw new Error("当前 WebView 不支持同步 XMLHttpRequest 存储");
    }
    const url = method === "GET"
      ? `/bucket/_playmesh-json/v1?payload=${standardStorageBase64Url(
          standardStorageUtf8Bytes(body),
        )}`
      : "/bucket/_playmesh-json/v1";
    let lastError = null;
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const xhr = new global.XMLHttpRequest();
        xhr.open(method, url, false);
        xhr.setRequestHeader("X-Playmesh-Storage-Sync", "1");
        xhr.setRequestHeader("X-Playmesh-Content-Sha256", digest);
        if (method === "PUT") {
          xhr.setRequestHeader("Content-Type", "application/json");
        }
        xhr.send(method === "PUT" ? body : null);
        const status = xhr.status === 1223 ? 204 : xhr.status;
        let payload;
        try {
          payload = JSON.parse(xhr.responseText || "");
        } catch (error) {
          if (attempt === 0) {
            lastError = error;
            continue;
          }
          throw new Error("同步存储 HTTP 响应不是有效 JSON");
        }
        if (status >= 500 && attempt === 0) {
          lastError = new Error(payload?.error?.message || "存储网关暂时不可用");
          continue;
        }
        if (status < 200 || status >= 300) {
          const error = new Error(
            payload?.error?.message || `同步存储 HTTP 请求失败: ${status}`,
          );
          error.code = payload?.error?.code || "storage_sync_http_failed";
          throw error;
        }
        if (payload?.protocolVersion !== "1.0.0" ||
            payload?.requestId !== requestId) {
          if (attempt === 0) {
            lastError = new Error("同步存储 HTTP 响应与请求不匹配");
            continue;
          }
          throw new Error("同步存储 HTTP 响应与请求不匹配");
        }
        return payload.result;
      } catch (error) {
        lastError = error;
        if (attempt === 0 && error?.code == null) continue;
        throw error;
      }
    }
    throw new Error(
      `同步存储 HTTP 路由不可用: ${lastError?.message || lastError || "unknown"}`,
    );
  }

  function standardStorageUtf8Bytes(value) {
    if (typeof global.TextEncoder === "function") {
      return new global.TextEncoder().encode(value);
    }
    const bytes = [];
    for (let index = 0; index < value.length; index += 1) {
      let codePoint = value.charCodeAt(index);
      if (codePoint >= 0xd800 && codePoint <= 0xdbff) {
        const low = value.charCodeAt(index + 1);
        if (low >= 0xdc00 && low <= 0xdfff) {
          codePoint = 0x10000 + ((codePoint - 0xd800) << 10) + (low - 0xdc00);
          index += 1;
        } else {
          codePoint = 0xfffd;
        }
      } else if (codePoint >= 0xdc00 && codePoint <= 0xdfff) {
        codePoint = 0xfffd;
      }
      if (codePoint <= 0x7f) {
        bytes.push(codePoint);
      } else if (codePoint <= 0x7ff) {
        bytes.push(0xc0 | (codePoint >>> 6), 0x80 | (codePoint & 0x3f));
      } else if (codePoint <= 0xffff) {
        bytes.push(
          0xe0 | (codePoint >>> 12),
          0x80 | ((codePoint >>> 6) & 0x3f),
          0x80 | (codePoint & 0x3f),
        );
      } else {
        bytes.push(
          0xf0 | (codePoint >>> 18),
          0x80 | ((codePoint >>> 12) & 0x3f),
          0x80 | ((codePoint >>> 6) & 0x3f),
          0x80 | (codePoint & 0x3f),
        );
      }
    }
    return new Uint8Array(bytes);
  }

  function standardStorageSha256Sync(value) {
    const bytes = standardStorageUtf8Bytes(value);
    const constants = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
      0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
      0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
      0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
      0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
      0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
      0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
      0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
      0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    const state = new Uint32Array([
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]);
    const words = new Uint32Array(64);
    const paddedLength = Math.ceil((bytes.length + 9) / 64) * 64;
    const bitLength = bytes.length * 8;
    const bitLengthHigh = Math.floor(bitLength / 0x100000000);
    const bitLengthLow = bitLength >>> 0;
    const byteAt = (position) => {
      if (position < bytes.length) return bytes[position];
      if (position === bytes.length) return 0x80;
      if (position < paddedLength - 8) return 0;
      const shift = (paddedLength - 1 - position) * 8;
      return shift >= 32
        ? (bitLengthHigh >>> (shift - 32)) & 0xff
        : (bitLengthLow >>> shift) & 0xff;
    };
    const rotateRight = (value, bits) =>
      (value >>> bits) | (value << (32 - bits));
    for (let offset = 0; offset < paddedLength; offset += 64) {
      for (let index = 0; index < 16; index += 1) {
        const position = offset + index * 4;
        words[index] = (
          (byteAt(position) << 24) |
          (byteAt(position + 1) << 16) |
          (byteAt(position + 2) << 8) |
          byteAt(position + 3)
        ) >>> 0;
      }
      for (let index = 16; index < 64; index += 1) {
        const x = words[index - 15];
        const y = words[index - 2];
        const sigma0 = rotateRight(x, 7) ^ rotateRight(x, 18) ^ (x >>> 3);
        const sigma1 = rotateRight(y, 17) ^ rotateRight(y, 19) ^ (y >>> 10);
        words[index] = (
          words[index - 16] + sigma0 + words[index - 7] + sigma1
        ) >>> 0;
      }
      let a = state[0];
      let b = state[1];
      let c = state[2];
      let d = state[3];
      let e = state[4];
      let f = state[5];
      let g = state[6];
      let h = state[7];
      for (let index = 0; index < 64; index += 1) {
        const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
        const choice = (e & f) ^ (~e & g);
        const temporary1 = (h + sum1 + choice + constants[index] + words[index]) >>> 0;
        const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
        const majority = (a & b) ^ (a & c) ^ (b & c);
        const temporary2 = (sum0 + majority) >>> 0;
        h = g;
        g = f;
        f = e;
        e = (d + temporary1) >>> 0;
        d = c;
        c = b;
        b = a;
        a = (temporary1 + temporary2) >>> 0;
      }
      state[0] = (state[0] + a) >>> 0;
      state[1] = (state[1] + b) >>> 0;
      state[2] = (state[2] + c) >>> 0;
      state[3] = (state[3] + d) >>> 0;
      state[4] = (state[4] + e) >>> 0;
      state[5] = (state[5] + f) >>> 0;
      state[6] = (state[6] + g) >>> 0;
      state[7] = (state[7] + h) >>> 0;
    }
    return [...state]
      .map((item) => item.toString(16).padStart(8, "0"))
      .join("");
  }

  function standardStorageBase64Url(bytes) {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let encoded = "";
    for (let index = 0; index < bytes.length; index += 3) {
      const first = bytes[index];
      const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
      const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
      encoded += alphabet[first >>> 2];
      encoded += alphabet[((first & 3) << 4) | (second >>> 4)];
      if (index + 1 < bytes.length) {
        encoded += alphabet[((second & 15) << 2) | (third >>> 6)];
      }
      if (index + 2 < bytes.length) encoded += alphabet[third & 63];
    }
    return encoded;
  }

  async function storageUpload(bucket, file) {
    await main.ready;
    if (!file || typeof file.name !== "string" || typeof file.size !== "number") {
      throw new Error("upload(file) 需要浏览器 File");
    }
    if (file.size > 256 * 1024 * 1024) {
      throw new Error("上传文件不能超过 256 MiB");
    }
    const config = global.__PLAYMESH_BROWSER__;
    const base = config?.bucketEndpoint || "/bucket";
    const url = `${base}/${encodeURIComponent(bucket)}?name=${encodeURIComponent(file.name)}`;
    const headers = {};
    if (config?.shareToken) {
      headers["X-Playmesh-Share-Token"] = config.shareToken;
    }
    const response = await global.fetch(url, {
      method: "POST",
      headers,
      body: file,
    });
    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      // 网关异常返回也统一转换成 SDK Error。
    }
    if (!response.ok || typeof payload?.url !== "string") {
      throw new Error(payload?.error || "文件上传失败");
    }
    return payload.url;
  }

  async function resolveBrowserNickname() {
    const cached = readBrowserNickname();
    if (cached) return cached;
    return openBrowserNicknameDialog({
      required: true,
      current: "",
      submit(nickname) {
        writeBrowserNickname(nickname);
      },
    });
  }

  function readBrowserNickname() {
    try {
      const cached = global.localStorage?.getItem(browserNicknameStorageKey);
      return validateNickname(cached, false);
    } catch (_) {
      return null;
    }
  }

  function writeBrowserNickname(nickname) {
    try {
      global.localStorage?.setItem(browserNicknameStorageKey, nickname);
    } catch (_) {
      // 隐私浏览可能拒绝持久化，但当前会话仍可继续。
    }
  }

  function resolveBrowserPlayerId() {
    try {
      const cached = global.localStorage?.getItem(browserPlayerIdStorageKey);
      if (/^p_[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(cached || "")) return cached;
    } catch (_) {
      // 持久化不可用时继续使用内存身份。
    }
    const bytes = new Uint8Array(16);
    if (global.crypto?.getRandomValues) {
      global.crypto.getRandomValues(bytes);
    } else {
      for (let index = 0; index < bytes.length; index += 1) {
        bytes[index] = Math.floor(Math.random() * 256);
      }
    }
    const playerId = `p_${[...bytes].map((value) => value.toString(16).padStart(2, "0")).join("")}`;
    try {
      global.localStorage?.setItem(browserPlayerIdStorageKey, playerId);
    } catch (_) {
      // 当前页面仍可加入，但刷新后无法恢复这个身份。
    }
    return playerId;
  }

  async function updateBrowserNickname(value) {
    const nickname = validateNickname(value, true);
    await main.ready;
    const config = global.__PLAYMESH_BROWSER__;
    const response = await fetch(new URL(
      `v1/sessions/${encodeURIComponent(bootstrap.session.id)}/players/me`,
      config.coreBase,
    ), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${browserCredential.token}`,
      },
      body: JSON.stringify({
        nickname,
      }),
    });
    const payload = await response.json();
    if (!response.ok) {
      throw new Error(payload.error?.message || payload.error || "修改昵称失败");
    }
    bootstrap.session = publicSession(payload.session);
    bootstrap.player = publicPlayer(payload.player);
    writeBrowserNickname(nickname);
    emit(sessionListeners, bootstrap.session);
    return bootstrap.player;
  }

  function validateNickname(value, throws) {
    const nickname = typeof value === "string" ? value.trim() : "";
    if (nickname && [...nickname].length <= 32) return nickname;
    if (throws) throw new Error("昵称必须为 1 至 32 个字符");
    return null;
  }

  async function editBrowserNickname() {
    if (appSdk.isAvailable()) return false;
    const value = await openBrowserNicknameDialog({
      required: false,
      current: bootstrap?.player?.nickname || readBrowserNickname() || "",
      submit: updateBrowserNickname,
    });
    return value !== null;
  }

  async function openBrowserNicknameDialog(options) {
    const ui = await ensureBrowserNicknameUi();
    if (!ui) throw new Error("浏览器昵称界面不可用");
    ui.nicknameRequired = options.required === true;
    ui.title.textContent = platformText(
      ui.nicknameRequired ? "nickname.set_title" : "nickname.edit_title",
    );
    ui.input.value = options.current;
    ui.error.textContent = "";
    ui.close.hidden = options.required;
    openPlatformUiLayer(
      ui.overlay,
      ui.input,
      options.returnFocus || (options.required ? null : ui.pageReturnFocus),
    );
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = (value, error = null) => {
        if (settled) return;
        settled = true;
        ui.onNicknameBack = null;
        closePlatformUiLayer(
          ui.overlay,
          options.returnFocus || ui.pageReturnFocus,
        );
        if (error) reject(error);
        else resolve(value);
      };
      ui.onNicknameBack = () => {
        if (ui.submit.disabled) return;
        if (!ui.nicknameRequired) {
          finish(null);
          return;
        }
        const error = new Error("Browser nickname setup was cancelled");
        error.name = "AbortError";
        finish(null, error);
      };
      ui.close.onclick = () => finish(null);
      ui.form.onsubmit = async (event) => {
        event.preventDefault();
        ui.error.textContent = "";
        ui.submit.disabled = true;
        try {
          const nickname = validateNickname(ui.input.value, false);
          if (!nickname) {
            ui.error.textContent = platformText("nickname.invalid");
            return;
          }
          await options.submit(nickname);
          finish(nickname);
        } catch (error) {
          global.console?.warn?.("Playmesh browser nickname update failed", error);
          ui.error.textContent = platformText("nickname.update_failed");
        } finally {
          ui.submit.disabled = false;
        }
      };
    });
  }

  function registerAppPlatformUiRuntime() {
    if (typeof appInternalRuntime.registerRuntimeUi !== "function") return;
    appInternalRuntime.registerRuntimeUi({
      async reload() {
        const multiplayer = main.gameInfo.getCurrent()?.multiplayer === true;
        if (multiplayer && main.session.isAuthority()) {
          await post("session.reset", {});
        }
        global.location?.reload?.();
      },
      async getInfo() {
        await main.ready;
        const gameInfo = main.gameInfo.getCurrent();
        if (!gameInfo) return null;
        const session = main.session.getCurrent();
        const player = main.player.getCurrent();
        return {
          gameId: gameInfo.id,
          gameName: gameInfo.name,
          tags: [...(gameInfo.tags || [])],
          requiredCapabilities: [...gameInfo.requiredCapabilities],
          joinCode: session?.joinCode || null,
          multiplayer: gameInfo.multiplayer,
          isAuthority: main.session.isAuthority(),
          playerName: player?.nickname || null,
          canEditNickname: !appSdk.isAvailable(),
          playerCount: Array.isArray(session?.players)
            ? session.players.length
            : null,
          gameSdkVersion: main.version,
          appSdkVersion: appSdk.version,
          platform: appSdk.device.getPlatform() || "browser",
        };
      },
      editNickname() {
        return editBrowserNickname();
      },
    });
  }

  async function ensureBrowserNicknameUi() {
    if (browserNicknameUi) return browserNicknameUi;
    if (!global.document) return null;
    if (!global.document.body) {
      await new Promise((resolve) => global.document.addEventListener("DOMContentLoaded", resolve, { once: true }));
    }
    const pageReturnFocus = global.document.activeElement || null;
    const host = global.document.createElement("div");
    host.id = "playmesh-browser-nickname-ui";
    host.setAttribute?.("lang", platformUiLocale);
    host.setAttribute?.("data-theme", platformUiTheme);
    const root = host.attachShadow({ mode: "closed" });
    root.innerHTML = `<style>
      :host{all:initial;--pm-surface:#20242b;--pm-hover:#343b46;--pm-text:#f4f7fb;--pm-border:#596272;--pm-overlay:#0008;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-focus:#78a6ff;--pm-error:#fda4af;font-family:system-ui,"Microsoft YaHei",sans-serif;color-scheme:dark}
      :host([data-theme="light"]){--pm-surface:#fff;--pm-hover:#e8edf3;--pm-text:#18212c;--pm-border:#91a0b0;--pm-overlay:#dce3ecd9;--pm-field-bg:#fff;--pm-field-text:#111827;--pm-focus:#075dce;--pm-error:#a1122f;color-scheme:light}
      button,input{box-sizing:border-box;font:inherit;letter-spacing:0}
      .overlay{position:fixed;inset:0;z-index:2147483647;display:grid;place-items:center;padding:20px;background:var(--pm-overlay)}
      .overlay[hidden]{display:none}
      form{box-sizing:border-box;width:min(100%,380px);max-height:calc(100dvh - 40px);overflow:auto;padding:20px;border:1px solid var(--pm-border);border-radius:8px;background:var(--pm-surface);color:var(--pm-text);box-shadow:0 16px 40px #0005}
      h2{margin:0 0 16px;font-size:20px;line-height:1.3;letter-spacing:0}
      label{display:block;margin-bottom:6px;font-size:14px;font-weight:700}
      input{width:100%;height:44px;padding:8px 10px;border:1px solid var(--pm-border);border-radius:6px;color:var(--pm-field-text);background:var(--pm-field-bg)}
      .error{min-height:20px;margin:6px 0;color:var(--pm-error);font-size:13px}
      .actions{display:flex;justify-content:flex-end;gap:8px}
      .actions button{height:40px;padding:0 14px;border:1px solid var(--pm-border);border-radius:6px;background:var(--pm-hover);color:var(--pm-text);cursor:pointer}
      .actions .save{border-color:#10b981;background:#0f766e;color:#fff;font-weight:700}
      .actions button:focus-visible,input:focus-visible{outline:3px solid var(--pm-focus);outline-offset:-3px}
      button:disabled{cursor:wait;opacity:.65}
    </style>
    <div class="overlay" role="dialog" aria-modal="true" aria-labelledby="playmesh-nickname-title" hidden>
      <form><h2 id="playmesh-nickname-title"></h2><label class="nickname-label" for="nickname">${platformHtml("nickname.label")}</label>
      <input id="nickname" maxlength="32" autocomplete="nickname" required>
      <div class="error" role="alert"></div><div class="actions">
      <button class="close" type="button" aria-label="${platformHtml("common.cancel")}">${platformHtml("common.cancel")}</button><button class="save" type="submit" aria-label="${platformHtml("common.save")}">${platformHtml("common.save")}</button>
      </div></form>
    </div>`;
    global.document.body.appendChild(host);
    browserNicknameUi = {
      host,
      pageReturnFocus,
      overlay: root.querySelector(".overlay"),
      form: root.querySelector("form"),
      title: root.querySelector("h2"),
      nicknameLabel: root.querySelector(".nickname-label"),
      input: root.querySelector("input"),
      error: root.querySelector(".error"),
      close: root.querySelector(".close"),
      submit: root.querySelector(".save"),
    };
    const ui = browserNicknameUi;
    global.document.addEventListener?.("focusin", (event) => {
      if (event.target && event.target !== host) {
        ui.pageReturnFocus = event.target;
      }
    }, true);
    installPlatformUiKeyboardNavigation(
      ui.overlay,
      () => [ui.input, ui.close, ui.submit],
      {
        trap: true,
        onBack: () => ui.onNicknameBack?.(),
      },
    );
    refreshBrowserPlatformUi(ui);
    return browserNicknameUi;
  }

  function setPlatformControlLabel(element, key, { visible = false } = {}) {
    if (!element) return;
    const label = platformText(key);
    element.setAttribute?.("aria-label", label);
    element.setAttribute?.("title", label);
    if (visible) element.textContent = label;
  }

  function refreshBrowserPlatformUi(ui) {
    if (!ui) return;
    ui.host?.setAttribute?.("data-theme", platformUiTheme);
    ui.host?.setAttribute?.("lang", platformUiLocale);
    if (ui.nicknameLabel) {
      ui.nicknameLabel.textContent = platformText("nickname.label");
    }
    if (ui.title && !ui.overlay.hidden) {
      ui.title.textContent = platformText(
        ui.nicknameRequired ? "nickname.set_title" : "nickname.edit_title",
      );
    }
    setPlatformControlLabel(ui.close, "common.cancel", { visible: true });
    setPlatformControlLabel(ui.submit, "common.save", { visible: true });
  }

  function validateStorageName(value, field) {
    const max = field === "bucket" ? 64 : 128;
    const pattern = field === "bucket"
      ? /^[A-Za-z0-9][A-Za-z0-9_-]*$/
      : /^[A-Za-z0-9._-]+$/;
    if (typeof value !== "string" || value.length < 1 || value.length > max || !pattern.test(value)) {
      throw new Error(`无效的 ${field}`);
    }
  }

  function validateSynchronousStorageBucketName(value) {
    if (typeof value !== "string") throw new Error("无效的 bucket");
    const length = standardStorageUtf8Bytes(value).length;
    if (length < 1 || length > 4096) {
      throw new Error("同步 Bucket 逻辑名必须为 1 至 4096 个 UTF-8 字节");
    }
  }

  function validateSynchronousStorageKey(value) {
    if (value === "$playmesh.gdevelop.root.v1") return;
    validateStorageName(value, "key");
  }
})(window);
