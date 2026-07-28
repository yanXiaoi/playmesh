part of '../../sdk_feature_registry.dart';

const gameCoreSdkSource = SdkSourceFragment(
  id: 'game.core',
  target: SdkSourceTarget.game,
  order: 10,
  typeScript: r'''// @ts-ignore
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
  /** 当前玩家在会话中的参与角色；Authority 资格仍以 `session.isAuthority()` 为准。 */
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

/** `await playmesh.ready` 的初始化结果。 */
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

/** `playmesh.sync` 发布的完整权威状态快照。 */
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

/** 启动 Authority 状态同步的配置。只能在 `session.isAuthority()` 为 true 时调用。 */
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

/** Authority 状态同步控制器。 */
interface PlaymeshSyncAuthorityController<T = PlaymeshJson> {
  /** 返回当前权威状态的 JSON 副本。 */
  getState(): T;
  /** 替换权威状态；`publish` 缺省为 true。 */
  setState(state: T, publish?: boolean): Promise<PlaymeshSyncSnapshot<T> | null>;
  /** 立即发布完整快照；省略目标时发送给全部非 Authority 玩家。 */
  publish(targetPlayerIds?: string[]): Promise<PlaymeshSyncSnapshot<T> | null>;
  /** 停止 tick 和同步；停止后需要重新调用 `startAuthority`。 */
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

/** 全平台注册表中的能力插件元数据。 */
interface PlaymeshCapabilityDefinition {
  code: string;
  name: string;
  description: string;
  apiVersion: string;
  appSupported: boolean;
  htmlSupported: boolean;
  optionsSchema: { [key: string]: PlaymeshJson };
  methods: PlaymeshCapabilityMethodDefinition[];
  events: PlaymeshCapabilityEventDefinition[];
}

/** 由 `playmesh.app.capabilities.create()` 创建的有状态能力实例。 */
interface PlaymeshCapabilityHandle {
  readonly id: string;
  readonly code: string;
  readonly apiVersion: string;
  invoke<T = PlaymeshJson>(method: string, args?: { [key: string]: PlaymeshJson }): Promise<T>;
  on(event: string, callback: (data: { [key: string]: PlaymeshJson }) => void): PlaymeshUnsubscribe;
  onError(callback: (error: Error) => void): PlaymeshUnsubscribe;
  dispose(): Promise<void>;
}

/** `playmesh.storage.getBucket()` 返回的 Authority 主机存储分区。 */
interface PlaymeshStorageBucket {
  /** 读取 key；不存在时返回 `null`。key 长度 1～128，只允许字母、数字、点、下划线和连字符。 */
  getData<T = PlaymeshJson>(key: string): Promise<T | null>;
  /** 写入 JSON 值；单值序列化后不能超过宿主限制。 */
  setData(key: string, value: PlaymeshJson): Promise<void>;
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
  readonly version: "__PLAYMESH_APP_SDK_VERSION__";
  /** App Bridge 完成身份和能力插件注册表注入后 resolve。 */
  readonly ready: Promise<unknown>;
  /** 当前页面是否运行在具有 App Bridge 的 Playmesh WebView 中。 @playmesh-completion playmesh.app.isAvailable */
  isAvailable(): boolean;
  readonly identity: {
    /** 返回 App 自动注入的当前用户；普通浏览器返回 `null`。 @playmesh-completion playmesh.app.identity.getCurrent */
    getCurrent(): PlaymeshAppIdentity | null;
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

/** Playmesh 游戏公开 API。所有页面先等待 `playmesh.ready`，再使用其他命名空间。 */
interface PlaymeshApi {
  /** 当前 Game SDK 版本。 */
  readonly version: "__PLAYMESH_SDK_VERSION__";
  /** SDK、身份、能力确认和会话完成初始化后 resolve；初始化失败时 reject。 */
  readonly ready: Promise<PlaymeshBootstrap>;
  /** 当前设备的 App Bridge 能力；普通浏览器中 `isAvailable()` 为 false。 */
  readonly app: PlaymeshAppApi;
  /** 当前游戏页面的只读运行环境信息；不包含平台 UI 词典。 */
  readonly runtime: {
    /** 返回实际显示该页面的 App locale；普通浏览器按浏览器语言解析，失败时返回 `zh`。 @playmesh-completion playmesh.runtime.getLocale */
    getLocale(): string;
  };
  /** 当前页面对应的游戏声明。 */
  readonly gameInfo: {
    /** 返回 Game SDK 初始化后的只读游戏信息；尚未就绪时返回 `null`。 @playmesh-completion playmesh.gameInfo.getCurrent */
    getCurrent(): PlaymeshGameInfo | null;
  };
  /** 对局状态、Authority 身份和玩家成员事件。 */
  readonly session: {
    /** 订阅会话快照；注册后若已就绪会立即回调。 @returns 取消订阅函数。 @playmesh-completion playmesh.session.onStateChange */
    onStateChange(callback: (session: PlaymeshSessionSnapshot | null) => void): PlaymeshUnsubscribe;
    /** 玩家第一次加入时回调。重连不会重复触发本事件。 @playmesh-completion playmesh.session.onPlayerJoin */
    onPlayerJoin(callback: (event: PlaymeshPlayerConnectionEvent) => void): PlaymeshUnsubscribe;
    /** 玩家连接断开时回调；成员可能仍留在会话中。 @playmesh-completion playmesh.session.onPlayerLeave */
    onPlayerLeave(callback: (event: PlaymeshPlayerConnectionEvent) => void): PlaymeshUnsubscribe;
    /** 离线玩家使用相同 ID 恢复连接时回调。 @playmesh-completion playmesh.session.onPlayerReconnect */
    onPlayerReconnect(callback: (event: PlaymeshPlayerConnectionEvent) => void): PlaymeshUnsubscribe;
    /** 当前页面是否是固定 Authority Client。不要根据 `players[0]` 推断。 @playmesh-completion playmesh.session.isAuthority */
    isAuthority(): boolean;
    /** 返回最近会话快照；单机分享页或尚未就绪时返回 `null`。 @playmesh-completion playmesh.session.getCurrent */
    getCurrent(): PlaymeshSessionSnapshot | null;
    /** 仅请求 Core 切换为运行状态；准备、倒计时和玩法条件由游戏 Authority 判断。 @playmesh-completion playmesh.session.start */
    start(): Promise<PlaymeshSessionSnapshot>;
    /** 仅在游戏规则确认结束后请求 Core 停止会话并清理离线成员；SDK 不判断胜负。 @playmesh-completion playmesh.session.finish */
    finish(): Promise<PlaymeshSessionSnapshot>;
  };
  /** 当前参与玩家资料。 */
  readonly player: {
    /** 返回当前玩家；公共 Authority 主屏和单机分享页返回 `null`。 @playmesh-completion playmesh.player.getCurrent */
    getCurrent(): PlaymeshPlayer | null;
    /** 修改当前玩家昵称，去除首尾空白后必须为 1～32 个字符。 @playmesh-completion playmesh.player.setNickname */
    setNickname(nickname: string): Promise<PlaymeshPlayer>;
  };
  /** 自定义低层游戏消息。普通多人游戏优先使用 `playmesh.sync`。 */
  readonly game: {
    /** 向 Authority 提交 JSON 业务动作；发送者身份由平台附加。 @playmesh-completion playmesh.game.submitAction */
    submitAction(action: PlaymeshJson): Promise<unknown>;
    /** 订阅 Authority 发给当前客户端的 JSON 消息。 @playmesh-completion playmesh.game.onMessage */
    onMessage(callback: (message: PlaymeshJson) => void): PlaymeshUnsubscribe;
    /** `onMessage` 的兼容别名；新代码优先使用 `onMessage`。 @playmesh-completion playmesh.game.onEvent */
    onEvent(callback: (message: PlaymeshJson) => void): PlaymeshUnsubscribe;
  };
  /** 自定义 Authority 动作处理。只有 Authority Client 可以注册。 */
  readonly authority: {
    /**
     * 注册权威动作处理器。规则、分数和胜负应在这里决定，不能信任动作中自报的身份。
     * @returns 取消注册函数。
     * @playmesh-completion playmesh.authority.onService
     */
    onService(handler: (action: PlaymeshJson, context: PlaymeshAuthorityContext) => PlaymeshAuthorityResult | PlaymeshAuthorityResult[] | null | undefined | Promise<PlaymeshAuthorityResult | PlaymeshAuthorityResult[] | null | undefined>): PlaymeshUnsubscribe;
  };
  /** 多人会话内的透明二进制分发。SDK 按需维护一条受平台管控的 Binary WebSocket。 */
  readonly binary: {
    /** Authority 在所有 Binary Channel 中使用的固定玩家 ID。 */
    readonly authorityPlayerId: "authority";
    /** 创建逻辑 Channel；只有 Authority 可以调用。 @playmesh-completion playmesh.binary.createChannel */
    createChannel(options: PlaymeshBinaryChannelOptions): Promise<PlaymeshBinaryChannel>;
    /** 使用 Authority 分享的 Channel ID 加入逻辑 Channel。 @playmesh-completion playmesh.binary.joinChannel */
    joinChannel(channelId: string): Promise<PlaymeshBinaryChannel>;
  };
  /** 完整权威状态同步、输入限频与快照订阅。 */
  readonly sync: {
    /** 仅 Authority 启动状态同步；同一页面同时只能有一个同步 runtime。 @playmesh-completion playmesh.sync.startAuthority */
    startAuthority<T = PlaymeshJson>(options: PlaymeshSyncAuthorityOptions<T>): PlaymeshSyncAuthorityController<T>;
    /** 提交一次性语义输入，返回生成的 input ID。 @playmesh-completion playmesh.sync.submitAction */
    submitAction(payload: PlaymeshJson): Promise<string>;
    /** 同一 key 只保留最新连续输入；`rateHz` 必须为 1～20。 @playmesh-completion playmesh.sync.submitState */
    submitState(key: string, value: PlaymeshJson, options?: { rateHz?: number }): Promise<null>;
    /** 请求 Authority 立即向当前玩家发送最新完整快照。 @playmesh-completion playmesh.sync.requestSnapshot */
    requestSnapshot(): Promise<string>;
    /** 返回最近完整快照；尚未收到时返回 `null`。 @playmesh-completion playmesh.sync.getSnapshot */
    getSnapshot<T = PlaymeshJson>(): PlaymeshSyncSnapshot<T> | null;
    /** 订阅完整快照；已有快照时注册后立即回调。 @playmesh-completion playmesh.sync.observe */
    observe<T = PlaymeshJson>(callback: (snapshot: PlaymeshSyncSnapshot<T>) => void): PlaymeshUnsubscribe;
  };
  /** WebView 暂停、恢复、退出和错误事件。 */
  readonly lifecycle: {
    /** 订阅全部生命周期事件。 @playmesh-completion playmesh.lifecycle.onChange */
    onChange(callback: (event: PlaymeshLifecycleEvent) => void): PlaymeshUnsubscribe;
    /** 仅订阅暂停事件。 @playmesh-completion playmesh.lifecycle.onPause */
    onPause(callback: (event: PlaymeshLifecycleEvent) => void): PlaymeshUnsubscribe;
    /** 仅订阅恢复事件。 @playmesh-completion playmesh.lifecycle.onResume */
    onResume(callback: (event: PlaymeshLifecycleEvent) => void): PlaymeshUnsubscribe;
    /** 订阅退出事件；允许返回 Promise，宿主只会有限等待。 @playmesh-completion playmesh.lifecycle.onExit */
    onExit(callback: (event: PlaymeshLifecycleEvent) => void | Promise<void>): PlaymeshUnsubscribe;
  };
  /** 游戏上报的 FPS、自动测量的多人 RTT 与 SDK 性能浮层。 */
  readonly performance: {
    /** 返回最近 FPS；尚未形成统计窗口时返回 `null`。 @playmesh-completion playmesh.performance.getFps */
    getFps(): number | null;
    /** 订阅 FPS；注册后立即回调当前值。 @playmesh-completion playmesh.performance.onFps */
    onFps(callback: (fps: number | null) => void): PlaymeshUnsubscribe;
    /** 返回最近平滑 RTT 毫秒数；单机或 Authority 不在线时返回 `null`。 @playmesh-completion playmesh.performance.getLatency */
    getLatency(): number | null;
    /** 返回最近延迟探测诊断数据；游戏规则不得依赖该数据判定胜负。 @playmesh-completion playmesh.performance.getLatencyDiagnostics */
    getLatencyDiagnostics(): Record<string, unknown> | null;
    /** 订阅延迟毫秒数。 @playmesh-completion playmesh.performance.onLatency */
    onLatency(callback: (latency: number | null) => void): PlaymeshUnsubscribe;
    /** 显示或隐藏 SDK 性能浮层。 @playmesh-completion playmesh.performance.setVisible */
    setVisible(visible: boolean): void;
    /** 在真实画面完成后报告一帧；返回最近 FPS。SDK 不会自行启动 RAF。 @playmesh-completion playmesh.performance.reportFrame */
    reportFrame(timestamp?: number): number | null;
  };
  /** Authority 主机上的持久 JSON Bucket。浏览器和加入设备不建立独立副本。 */
  readonly storage: {
    /** 获取 Bucket；名称必须匹配 `^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$`。 @playmesh-completion playmesh.storage.getBucket */
    getBucket(bucket: string): PlaymeshStorageBucket;
  };
}

/** 游戏页面使用的全局 Playmesh SDK。 */
declare const playmesh: PlaymeshApi;
interface Window { playmesh: PlaymeshApi; }
`;

(function (global) {
  "use strict";

  const PLAYMESH_SDK_VERSION = "3.0.0";

  let sequence = 0;
  let bootstrap = null;
  let authorityService = null;
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
  let browserBackInterceptionInstalled = false;
  let browserBackExitRequested = false;
  let browserBackGuardUrl = null;
  let capabilityConsentUi = null;
  let transportSequence = 0;
  const pending = new Map();
  const browserStoragePending = new Map();
  let browserStorageSequence = 0;
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
  const fpsListeners = new Set();
  const latencyListeners = new Set();
  const syncListeners = new Set();
  const browserNicknameStorageKey = "playmesh.nickname.v1";
  const browserPlayerIdStorageKey = "playmesh.player-id.v1";
  let currentFps = null;
  let fpsFrameCount = 0;
  let fpsWindowStartedAt = null;
  let currentLatency = null;
  let latencyDiagnostics = null;
  let latencyTimer = null;
  let latencyProbeSequence = 0;
  let performanceVisible = false;
  let performanceUi = null;
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
          command === "performance.ping" ||
          command === "performance.latency")) {
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
      : command === "performance.latency"
        ? "performance.latency"
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

''',
);

class _GameCoreFeature implements _GameSdkCommandFeature {
  @override
  SdkSourceFragment get source => gameCoreSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {'sdk.ready'};

  @override
  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) async {
    final connection = context.connection;
    return SdkCommandMessage({
      'type': 'sdk.bootstrap',
      'requestId': command.requestId,
      'sdkVersion': _resolveCommandSdkVersion(SdkSourceTarget.game, command),
      'gameInfo': context.gameInfo,
      if (connection == null) ...{
        'player': context.standalonePlayer,
        'isAuthority': true,
        'session': null,
      } else ...{
        'player': connection.snapshot.displayMode == 'single_screen_multiplayer'
            ? null
            : connection.currentPlayer.toJson(),
        'isAuthority': connection.isAuthority,
        'session': connection.snapshot.toJson(),
        // 只供 SDK 内部建立 Binary WebSocket，公开 bootstrap 会移除此字段。
        'binaryTransport': {'url': connection.binaryEndpoint.toString()},
      },
    });
  }
}
