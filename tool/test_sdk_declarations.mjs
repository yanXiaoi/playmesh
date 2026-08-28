import assert from "node:assert/strict";
import fs from "node:fs";

const game = fs.readFileSync(
  "assets/playmesh-library/public/sdk/v1/playmesh-main.d.ts",
  "utf8",
);
const app = fs.readFileSync(
  "assets/playmesh-library/public/sdk/v1/playmesh-app.d.ts",
  "utf8",
);
const gameRuntimeSource = fs.readFileSync(
  "lib/core/game_sdk/features/game/game_runtime_feature.dart",
  "utf8",
);
const gameCoreSource = fs.readFileSync(
  "lib/core/game_sdk/features/game/game_core_feature.dart",
  "utf8",
);
const gameAuthoritySource = fs.readFileSync(
  "lib/core/game_sdk/features/game/game_authority_feature.dart",
  "utf8",
);
const gameStorageLifecycleSource = fs.readFileSync(
  "lib/core/game_sdk/features/game/game_storage_lifecycle_feature.dart",
  "utf8",
);
const gameDatabaseSource = fs.readFileSync(
  "lib/core/game_sdk/features/game/game_database_feature.dart",
  "utf8",
);
const appDeviceSource = fs.readFileSync(
  "lib/core/game_sdk/features/app/app_device_feature.dart",
  "utf8",
);
const appLanSource = fs.readFileSync(
  "lib/core/game_sdk/features/app/app_lan_feature.dart",
  "utf8",
);
const appUiSource = fs.readFileSync(
  "lib/core/game_sdk/features/app/app_ui_feature.dart",
  "utf8",
);
const sdkRegistrySource = fs.readFileSync(
  "lib/core/game_sdk/sdk_feature_registry.dart",
  "utf8",
);
const sdkGeneratorSource = fs.readFileSync("tool/generate_sdk.mjs", "utf8");
const runtimeSdkCompatibilitySource = fs.readFileSync(
  "runtime/src/lib/runtime/runtime_sdk_compatibility.dart",
  "utf8",
);
const sdkManifest = JSON.parse(
  fs.readFileSync(
    "assets/playmesh-library/public/developer/contracts/sdk-manifest.json",
    "utf8",
  ),
);
const sdkSchema = JSON.parse(
  fs.readFileSync(
    "assets/playmesh-library/public/developer/contracts/schemas/sdk-v1.json",
    "utf8",
  ),
);
const gameManifestSchema = JSON.parse(
  fs.readFileSync(
    "assets/playmesh-library/public/developer/contracts/schemas/game-manifest.json",
    "utf8",
  ),
);
const defaultGameManifest = JSON.parse(
  fs.readFileSync(
    "assets/playmesh-library/public/developer/templates/default-game/package/main.json",
    "utf8",
  ),
);
const promptRoot = "assets/playmesh-library/public/developer/prompts";
const promptManifest = JSON.parse(
  fs.readFileSync(`${promptRoot}/manifest.json`, "utf8"),
);
const localizationRoot = "assets/playmesh-localization";
const localizationManifest = JSON.parse(
  fs.readFileSync(`${localizationRoot}/manifest.json`, "utf8"),
);
const enabledPromptLocales = localizationManifest.locales.filter(
  ({ enabled }) => enabled,
);
const pubspecSource = fs.readFileSync("pubspec.yaml", "utf8");
for (const { id } of enabledPromptLocales) {
  assert(
    pubspecSource.includes(
      `assets/playmesh-library/public/developer/prompts/${id}/`,
    ),
    `pubspec.yaml 必须打包 ${id} 提示词目录`,
  );
}
const promptSourcesByLocale = new Map(
  enabledPromptLocales.map(({ id }) => [
    id,
    promptManifest.templates.map(({ files }) =>
      fs.readFileSync(`${promptRoot}/${files[id]}`, "utf8"),
    ),
  ]),
);
const promptSources = promptManifest.templates
  .filter(({ id }) => ["common", "agent-common"].includes(id))
  .map(({ files }) => fs.readFileSync(`${promptRoot}/${files["zh-CN"]}`, "utf8"));
const allPromptSources = [...promptSourcesByLocale.values()].flat();
const developerSources = [
  ...allPromptSources,
  ...[
    "assets/playmesh-library/public/developer/templates/default-game/package/app/index.html",
    "assets/playmesh-library/public/developer/templates/default-game/package/app/controller/index.html",
  ].map((path) => fs.readFileSync(path, "utf8")),
];

assert(
  fs.existsSync("assets/playmesh-library/public/sdk/v1/playmesh-main.js"),
  "Game SDK JavaScript must be emitted as playmesh-main.js",
);
assert(
  fs.existsSync("assets/playmesh-library/public/sdk/v1/playmesh-main.d.ts"),
  "Game SDK declaration must be emitted as playmesh-main.d.ts",
);
assert(
  !fs.existsSync("assets/playmesh-library/public/sdk/v1/playmesh.js"),
  "breaking SDK update must not keep the legacy playmesh.js",
);
assert(
  !fs.existsSync("assets/playmesh-library/public/sdk/v1/playmesh.d.ts"),
  "breaking SDK update must not keep the legacy playmesh.d.ts",
);
assert(!game.includes("__PLAYMESH"), "Game SDK 声明包含未替换的占位符");
assert(!app.includes("__PLAYMESH"), "App SDK 声明包含未替换的占位符");
assert.match(
  game,
  /interface PlaymeshMainApi \{[\s\S]*?readonly version: "4\.3\.0";/,
);
assert.match(
  game,
  /interface PlaymeshAppApi \{[\s\S]*?readonly version: "3\.5\.0";/,
);
assert.match(
  game,
  /submitAction\(action: PlaymeshJson, options\?: PlaymeshAuthorityServiceOptions\): Promise<unknown>;/,
);
assert.match(
  game,
  /readonly defaultNamespace: "playmesh\.authority\.default\.v1";/,
);
assert.match(
  game,
  /onService\([\s\S]*?options\?: PlaymeshAuthorityServiceOptions\): PlaymeshUnsubscribe;/,
);
assert.match(
  game,
  /requestStream\(path: string, source: PlaymeshRpcStreamSource, options\?: PlaymeshRpcStreamRequestOptions\): Promise<any>;/,
);
assert.match(
  game,
  /onStreamRequest\(path: string, handler: \(source: ReadableStream<Uint8Array>, context: PlaymeshRpcStreamContext\)[\s\S]*?options\?: PlaymeshRpcStreamHandlerOptions\): PlaymeshUnsubscribe;/,
);
assert.match(
  game,
  /type PlaymeshRpcStreamProgressHandler = \([\s\S]*?transferredBytes: number,[\s\S]*?totalBytes: number \| null,[\s\S]*?\) => void;/,
);
assert.match(
  game,
  /interface PlaymeshRpcStreamRequestOptions \{[\s\S]*?onProgress\?: PlaymeshRpcStreamProgressHandler;/,
);
assert.match(
  game,
  /interface PlaymeshRpcStreamHandlerOptions \{[\s\S]*?onProgress\?: PlaymeshRpcStreamProgressHandler;/,
);
assert.match(
  game,
  /upload\(source: PlaymeshRpcStreamSource, options: \{ name: string; type\?: string \}\): Promise<string>;/,
);
assert.match(
  gameAuthoritySource,
  /const authorityServices = new Map\(\);[\s\S]*?function encodeAuthorityAction[\s\S]*?function decodeAuthorityAction[\s\S]*?function registerAuthorityService[\s\S]*?function normalizeAuthorityResults[\s\S]*?async function dispatchAuthorityAction/,
);
assert.match(
  gameRuntimeSource,
  /Symbol\.for\("playmesh\.app\.internal\.v1"\)[\s\S]*?const appSdk = appInternalRuntime\?\.publicApi/,
);
assert.match(gameRuntimeSource, /playmesh-app\.js 必须先于 playmesh-main\.js/);
assert.doesNotMatch(gameRuntimeSource, /global\.playmeshApp/);
assert.doesNotMatch(appDeviceSource, /global\.playmesh\s*=/);
assert.match(
  gameStorageLifecycleSource,
  /main\.ready = \(async \(\) => \{\s*const appBootstrap = await appSdk\.ready;/,
);
assert.match(
  gameStorageLifecycleSource,
  /const ready = main\.ready\.then\(\s*\(mainBootstrap\) => Object\.freeze\(\{\s*main: mainBootstrap,\s*app: readyAppBootstrap,/,
);
assert.doesNotMatch(
  gameStorageLifecycleSource,
  /appBootstrap\s*=\s*await appInternalRuntime\.configureRuntimeGame/,
);
assert.doesNotMatch(
  gameStorageLifecycleSource,
  /Promise\.all\(\s*\[\s*main\.ready\s*,\s*appSdk\.ready/,
);
assert.match(
  gameCoreSource,
  /readonly version: "__PLAYMESH_APP_SDK_VERSION__"/,
);
assert.match(
  sdkRegistrySource,
  /gameTypeScript = game\.typeScript\.replaceAll\([\s\S]*?appVersionPlaceholder,[\s\S]*?app\.version/,
);
assert.match(
  sdkGeneratorSource,
  /replacements:\s*\{\s*__PLAYMESH_APP_SDK_VERSION__:\s*appSdkVersion/,
);
assert.match(
  game,
  /setFullscreen\(enabled: boolean, orientation\?: PlaymeshOrientation\)/,
);
assert.match(game, /interface PlaymeshCapabilityHandle/);
assert.match(
  game,
  /interface PlaymeshGameInfo \{[\s\S]*id: string;[\s\S]*name: string;[\s\S]*multiplayer: boolean;[\s\S]*displayMode: PlaymeshDisplayMode;[\s\S]*requiredCapabilities: string\[\];/,
);
assert.match(game, /interface PlaymeshMainApi \{[\s\S]*?readonly gameInfo: \{/);
assert.match(game, /getCurrent\(\): PlaymeshGameInfo \| null;/);
assert.match(game, /capabilities\.create/);
assert.match(game, /addEventListener\(event: string, callback:/);
assert.match(game, /removeEventListener\(event: string, callback:/);
assert.match(game, /interface PlaymeshAppMediaSource/);
assert.match(game, /interface PlaymeshWebRTCSignalingEndpoint/);
assert.match(
  game,
  /readonly webrtc:[\s\S]*?getSignalingEndpoint\(identifier: string\): Promise<PlaymeshWebRTCSignalingEndpoint>/,
);
assert.match(
  game,
  /type PlaymeshSystemMenuDecision = "EXIT" \| "NEXT" \| "STOP"/,
);
assert.match(
  game,
  /onSystemMenuRequest\([\s\S]*?callback: \(\) => PlaymeshSystemMenuDecision \|[\s\S]*?Promise<PlaymeshSystemMenuDecision>/,
);
assert.match(
  game,
  /@deprecated 使用 `onSystemMenuRequest\(\)`；[\s\S]*?onBack\(/,
);
assert.match(
  game,
  /onBack\([\s\S]*?callback: \(\) => PlaymeshAppBackDecision \|[\s\S]*?Promise<PlaymeshAppBackDecision>/,
);
assert.doesNotMatch(game, /onBack\([\s\S]{0,160}Promise<boolean>/);
assert.match(
  game,
  /open\([\s\S]*?source: PlaymeshAppMediaSource,[\s\S]*?options\?: PlaymeshAppMediaOpenOptions/,
);
assert.doesNotMatch(game, /onDevice\(/);
assert.match(app, /reference path="\.\/playmesh-main\.d\.ts"/);
assert.doesNotMatch(app, /declare const playmesh:/);
assert.doesNotMatch(app, /interface Window \{ playmesh:/);
assert.doesNotMatch(app, /playmeshApp/);
assert.match(
  game,
  /submitState\(key: string, value: PlaymeshJson, options\?: \{ rateHz\?: number \}\): Promise<null>/,
);
assert.match(game, /onChange\(callback: \(event: PlaymeshLifecycleEvent\) => void\)/);
assert.match(game, /当前会话中的玩家/);
assert.match(game, /固定 Authority Client/);
assert.match(game, /只有 Authority 页面可读写，宿主后台会拒绝远程玩家/);
assert.match(
  game,
  /interface PlaymeshAppStorageBucket \{[\s\S]*?getData<[\s\S]*?setData\([\s\S]*?getDataSync<[\s\S]*?setDataSync\([\s\S]*?removeData\([\s\S]*?clearData\(\): Promise<void>/,
);
assert.match(
  game,
  /interface PlaymeshAppApi \{[\s\S]*?readonly storage:[\s\S]*?getBucket\(bucket: string\): PlaymeshAppStorageBucket/,
);
assert.match(game, /准备、倒计时和玩法条件由游戏 Authority 判断/);
assert.match(game, /SDK 不判断胜负/);
assert.match(
  game,
  /interface PlaymeshAppApi \{[\s\S]*?readonly runtime:[\s\S]*?getLocale\(\): string/,
);
assert.match(
  game,
  /interface PlaymeshAppApi \{[\s\S]*?readonly performance:[\s\S]*?reportFrame\(timestamp\?: number\): number \| null/,
);
assert.match(
  game,
  /interface PlaymeshAppApi \{[\s\S]*?readonly ready: Promise<PlaymeshAppBootstrap>;/,
);
assert.match(
  game,
  /interface PlaymeshReadyResult \{[\s\S]*?readonly main: PlaymeshBootstrap;[\s\S]*?readonly app: PlaymeshAppBootstrap;/,
);
const mainApi = game.match(/interface PlaymeshMainApi \{[\s\S]*?\n\}/)?.[0] ?? "";
assert.doesNotMatch(mainApi, /readonly performance:/);
assert.match(
  game,
  /interface PlaymeshApi \{[\s\S]*?readonly ready: Promise<PlaymeshReadyResult>;[\s\S]*?readonly main: PlaymeshMainApi;[\s\S]*?readonly app: PlaymeshAppApi;[\s\S]*?\}/,
);
const publicRootApi = game.match(/interface PlaymeshApi \{[\s\S]*?\n\}/)?.[0] ?? "";
for (const removedRootMember of [
  "version",
  "gameInfo",
  "session",
  "player",
  "game",
  "authority",
  "binary",
  "sync",
  "lifecycle",
  "performance",
  "storage",
  "db",
  "runtime",
]) {
  assert.doesNotMatch(publicRootApi, new RegExp(`readonly ${removedRootMember}:`));
}
assert.doesNotMatch(game, /_playmeshPlatformUi|platformUiMessages/);
assert.match(
  game,
  /interface PlaymeshPlayer \{[\s\S]*avatar: string \| null;[\s\S]*role: "authority" \| "authority_player" \| "player";[\s\S]*connected: boolean;/,
);
assert.doesNotMatch(game, /interface PlaymeshPlayer \{[\s\S]*connectionMode:/);
assert.match(
  game,
  /interface PlaymeshPlayerConnectionEvent \{[\s\S]*player: PlaymeshPlayer;[\s\S]*session: PlaymeshSessionSnapshot;[\s\S]*isCurrentPlayer: boolean;/,
);
for (const eventName of [
  "onPlayerJoin",
  "onPlayerLeave",
  "onPlayerReconnect",
]) {
  assert.match(
    game,
    new RegExp(
      `${eventName}\\(callback: \\(event: PlaymeshPlayerConnectionEvent\\) => void\\): PlaymeshUnsubscribe`,
    ),
  );
}
assert.match(game, /openSharePanel\(\): Promise<void>/);
assert.match(game, /disableSystemMenuTriggers\(\): void/);
assert.match(
  game,
  /type PlaymeshSystemMenuDecision = "EXIT" \| "NEXT" \| "STOP"/,
);
assert.match(
  game,
  /onSystemMenuRequest\(\s*callback: \(\) => PlaymeshSystemMenuDecision \|\s*Promise<PlaymeshSystemMenuDecision>,\s*\): PlaymeshUnsubscribe/,
);
assert.match(
  game,
  /onBack\(\s*callback: \(\) => PlaymeshAppBackDecision \|\s*Promise<PlaymeshAppBackDecision>,\s*\): PlaymeshUnsubscribe/,
);
assert.doesNotMatch(game, /onBack\([\s\S]{0,160}Promise<boolean>/);
assert.match(game, /type PlaymeshAppLanShareLinkType = "lan" \| "wan"/);
assert.match(game, /interface PlaymeshAppLanShareLink/);
assert.match(game, /interface PlaymeshLanGame/);
assert.match(game, /interface PlaymeshAppLanApi/);
assert.match(game, /readonly lan: PlaymeshAppLanApi/);
assert.match(game, /discoverGames\(\): Promise<readonly PlaymeshLanGame\[\]>/);
assert.match(game, /joinByLink\(invitationUrl: string\): Promise<void>/);
assert.match(game, /scanQrAndJoin\(\): Promise<void>/);
assert.match(game, /setPublished\(\): Promise<void>/);
assert.match(
  game,
  /getShareLinks\(\): Promise<readonly PlaymeshAppLanShareLink\[\]>/,
);
assert.equal(
  (game.match(/type PlaymeshAppLanShareLinkType/g) ?? []).length,
  1,
  "named LAN type alias must be emitted physically exactly once",
);
assert.doesNotMatch(app, /PlaymeshAppLanShareLinkType|PlaymeshAppLanApi/);
assert.match(appLanSource, /declaration:\s*r'''[\s\S]*interface PlaymeshAppLanApi/);
assert.match(appUiSource, /declaration:\s*r'''[\s\S]*disableSystemMenuTriggers/);
for (const forbiddenLanDependency of [
  "NetworkInterface",
  "GameWebGateway",
  "RelayHostSession",
  "ShareQrCodeEncoder",
  "invitationCandidates",
]) {
  assert.equal(
    appLanSource.includes(forbiddenLanDependency),
    false,
    `App LAN feature must not depend on ${forbiddenLanDependency}`,
  );
}
assert.match(sdkRegistrySource, /final String declaration;/);
assert.match(sdkGeneratorSource, /declarationFragments: dartSdkSources\.declarations/);
assert.match(game, /configure\(options: PlaymeshAppUiOptions\): PlaymeshAppUiOptions/);
assert.match(game, /initializeBrowser\(\): boolean/);
assert.match(game, /showGameSidebar\(\): Promise<boolean>/);
assert.match(
  game,
  /onGameMenuOpen\(callback: \(\) => void\): PlaymeshUnsubscribe/,
);
assert.match(
  game,
  /onGameMenuClose\(callback: \(\) => void\): PlaymeshUnsubscribe/,
);
assert.match(game, /restartGame\(\): void/);
assert.match(game, /openRuntimeLogs\(\): Promise<boolean>/);
assert.match(game, /openGameInfo\(\): Promise<boolean>/);
assert.match(game, /setPerformanceVisible\(visible: boolean\): boolean/);
assert.match(game, /togglePerformance\(\): boolean/);
assert.match(game, /exitGame\(\): Promise<void>/);
assert.doesNotMatch(game, /hideGameSidebar\(\)/);
assert.doesNotMatch(game, /onMenuRequest/);
const appApiPrefix = game
  .slice(game.indexOf("interface PlaymeshAppApi {"))
  .split("readonly identity:")[0];
for (const topLevelUiMethod of [
  "configure",
  "initializeBrowser",
  "showGameSidebar",
  "onGameMenuOpen",
  "onGameMenuClose",
  "restartGame",
  "openSharePanel",
  "openRuntimeLogs",
  "openGameInfo",
  "enterFullscreen",
  "exitFullscreen",
  "setPerformanceVisible",
  "togglePerformance",
  "exitGame",
]) {
  assert.doesNotMatch(appApiPrefix, new RegExp(`\\n\\s*${topLevelUiMethod}\\(`));
}
assert.match(game, /send\(data: Uint8Array\): Promise<void>/);
assert.match(game, /send\(targetPlayerIds: readonly string\[\], data: Uint8Array\): Promise<void>/);
assert.match(game, /sendLatest\(data: Uint8Array\): Promise<void>/);
assert.match(game, /sendLatest\(targetPlayerIds: readonly string\[\], data: Uint8Array\): Promise<void>/);
assert.match(game, /interface PlaymeshBinaryForwardContext[\s\S]*targetPlayerIds: string\[\]/);
assert.match(
  game,
  /interface PlaymeshRpcRequestOptions[\s\S]*timeoutMs\?: number/,
);
assert.match(
  game,
  /interface PlaymeshRpcContext extends PlaymeshAuthorityContext[\s\S]*requestId: string;[\s\S]*path: string;/,
);
assert.match(
  game,
  /request\(path: string, data\?: any, options\?: PlaymeshRpcRequestOptions\): Promise<any>/,
);
assert.match(
  game,
  /onRequest\(path: string, handler: \(data: any, context: PlaymeshRpcContext\) => any \| Promise<any>\): PlaymeshUnsubscribe/,
);
assert.doesNotMatch(game, /sendLast\(/);
assert.equal(app.trim(), '/// <reference path="./playmesh-main.d.ts" />');
assert.equal(sdkManifest.projectRules.appUrlRoot, "/");
assert.equal(sdkManifest.script, "/playmesh/sdk/v1/playmesh-main.js");
assert.equal(
  sdkManifest.projectRules.sdkImport,
  "/playmesh/sdk/v1/playmesh-main.js",
);
assert.equal("gameUrlRoot" in sdkManifest.projectRules, false);
assert.equal(
  sdkSchema.$defs.BinaryForwardContext.properties.targetPlayerIds.type,
  "array",
);
assert.equal(
  "targetPlayerId" in sdkSchema.$defs.BinaryForwardContext.properties,
  false,
);
const runtimeNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.app.runtime",
);
assert.equal(runtimeNamespace.members[0].name, "getLocale");
assert.equal(runtimeNamespace.members[0].signature, "getLocale(): string");
assert.match(runtimeNamespace.members[0].behavior, /fall back to zh$/);
const gameInfoNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main.gameInfo",
);
assert.equal(gameInfoNamespace.members[0].name, "getCurrent");
assert.equal(
  gameInfoNamespace.members[0].signature,
  "getCurrent(): PlaymeshGameInfo | null",
);
const appNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.app",
);
const mainNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main",
);
assert.equal(
  mainNamespace.members.find((member) => member.name === "ready").type,
  "Promise<PlaymeshBootstrap>",
);
assert.equal(
  appNamespace.members.find((member) => member.name === "ready").type,
  "Promise<PlaymeshAppBootstrap>",
);
const openSharePanel = appNamespace.members.find(
  (member) => member.name === "ui.openSharePanel",
);
assert.equal(openSharePanel.signature, "ui.openSharePanel(): Promise<void>");
assert.match(openSharePanel.behavior, /returns no token, URL, QR code/);
const systemMenuRequest = appNamespace.members.find(
  (member) => member.name === "ui.onSystemMenuRequest",
);
assert.match(systemMenuRequest.signature, /PlaymeshSystemMenuDecision/);
const deprecatedBack = appNamespace.members.find(
  (member) => member.name === "ui.onBack",
);
assert.equal(deprecatedBack.deprecated, "Use ui.onSystemMenuRequest");
for (const memberName of [
  "ui.configure",
  "ui.initializeBrowser",
  "ui.showGameSidebar",
  "ui.onGameMenuOpen",
  "ui.onGameMenuClose",
  "ui.onSystemMenuRequest",
  "ui.onBack",
  "ui.restartGame",
  "ui.openRuntimeLogs",
  "ui.openGameInfo",
  "ui.setPerformanceVisible",
  "ui.togglePerformance",
  "ui.exitGame",
]) {
  assert(appNamespace.members.some((member) => member.name === memberName));
}
for (const removedMemberName of [
  "hideGameSidebar",
  "onMenuRequest",
]) {
  assert.equal(
    appNamespace.members.some((member) => member.name === removedMemberName),
    false,
  );
}
const authorityNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main.authority",
);
assert.equal(
  authorityNamespace.members.find((member) => member.name === "defaultNamespace")
    .value,
  "playmesh.authority.default.v1",
);
assert.match(
  authorityNamespace.members.find((member) => member.name === "onService")
    .signature,
  /options\?: \{namespace\?: string\}/,
);
const rpcNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main.rpc",
);
assert.deepEqual(
  rpcNamespace.members.map((member) => member.name),
  ["request", "onRequest", "requestStream", "onStreamRequest"],
);
assert.match(
  rpcNamespace.members.find((member) => member.name === "requestStream")
    .signature,
  /onProgress.*totalBytes: number \| null/,
);
assert.match(
  rpcNamespace.members.find((member) => member.name === "onStreamRequest")
    .behavior,
  /StorageBucket\.upload/,
);
const gameNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main.game",
);
assert.match(
  gameNamespace.members.find((member) => member.name === "submitAction")
    .signature,
  /options\?: \{namespace\?: string\}/,
);
const storageNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main.storage",
);
const storageBucketMembers = storageNamespace.members.find(
  (member) => member.name === "getBucket",
).bucketMembers;
assert.deepEqual(storageBucketMembers, [
  "getData(key): Promise<JsonValue | null>",
  "setData(key, value): Promise<null>",
  "getDataSync(key): JsonValue | null",
  "setDataSync(key, value): void",
  "removeData(key): Promise<null>",
  "clearData(): Promise<null>",
  "upload(file): Promise<string>",
  "upload(source, {name, type?}): Promise<string>",
]);
const databaseNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.main.db",
);
assert.deepEqual(
  databaseNamespace.members.map((member) => member.name),
  [
    "open",
    "select",
    "update",
    "delete",
    "insert",
    "getDDL",
    "beginTransaction",
    "transaction",
  ],
);
assert.deepEqual(databaseNamespace.transactionMembers, [
  "select(sql, args?)",
  "update(sql, args?)",
  "delete(sql, args?)",
  "insert(sql, args?)",
  "getDDL(name?)",
  "commit()",
  "rollback()",
]);
assert.match(
  game,
  /type PlaymeshDatabaseArguments = readonly PlaymeshDatabaseParameter\[\] \|[\s\S]*Readonly<Record<string, PlaymeshDatabaseParameter>>;/,
);
assert.match(
  game,
  /interface PlaymeshDatabaseApi \{[\s\S]*?open\(\): Promise<\{ readonly file: "_game\.db" \}>;[\s\S]*?beginTransaction\(\): Promise<PlaymeshDatabaseTransaction>;[\s\S]*?transaction<T>/,
);
assert.match(
  gameDatabaseSource,
  /Array\.isArray\(args\)[\s\S]*?SQL args 必须是数组或命名参数对象[\s\S]*?db\.transaction\.begin/,
);
assert.doesNotMatch(game, /interface PlaymeshDatabaseApi \{[\s\S]*?\bclose\s*\(/);
const appStorageNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.app.storage",
);
const appStorageBucketMembers = appStorageNamespace.members.find(
  (member) => member.name === "getBucket",
).bucketMembers;
assert.deepEqual(appStorageBucketMembers, [
  "getData(key): Promise<JsonValue | null>",
  "setData(key, value): Promise<null>",
  "getDataSync(key): JsonValue | null",
  "setDataSync(key, value): void",
  "removeData(key): Promise<null>",
  "clearData(): Promise<null>",
]);
assert.deepEqual(sdkSchema.$defs.StorageBucketMethodName.enum, [
  "getData",
  "setData",
  "getDataSync",
  "setDataSync",
  "removeData",
  "clearData",
  "upload",
]);
assert.deepEqual(sdkSchema.$defs.AppStorageBucketMethodName.enum, [
  "getData",
  "setData",
  "getDataSync",
  "setDataSync",
  "removeData",
  "clearData",
]);
assert.match(game, /getDataSync<T = PlaymeshJson>\(key: string\): T \| null;/);
assert.match(game, /setDataSync\(key: string, value: PlaymeshJson\): void;/);
for (const forbiddenSyncStorageName of ["getSync", "setSync", "getBucketSync"]) {
  assert.doesNotMatch(game, new RegExp(`\\b${forbiddenSyncStorageName}\\s*\\(`));
}
assert.equal(
  authorityNamespace.members.some((member) => member.name === "openSharePanel"),
  false,
);
assert.equal(sdkSchema.$defs.RuntimeLocale.type, "string");
assert.deepEqual(
  sdkSchema.$defs.GameInfo.required,
  ["id", "name", "multiplayer", "displayMode", "requiredCapabilities"],
);
assert.equal(
  sdkSchema.$defs.PlaymeshBootstrap.properties.gameInfo.$ref,
  "#/$defs/GameInfo",
);
assert(sdkSchema.$defs.PlaymeshBootstrap.required.includes("gameInfo"));
assert.equal(
  sdkSchema.$defs.PlaymeshAppBootstrap.properties.sdkVersion.const,
  "3.5.0",
);
assert.equal(
  sdkSchema.$defs.PlaymeshReadyResult.properties.app.$ref,
  "#/$defs/PlaymeshAppBootstrap",
);
assert.match("en-US", new RegExp(sdkSchema.$defs.RuntimeLocale.pattern));
assert(sdkSchema.$defs.RuntimeLocale.examples.includes("zh"));
assert.deepEqual(
  [...sdkSchema.$defs.Player.required].sort(),
  ["avatar", "connected", "id", "nickname", "role"],
);
assert.deepEqual(sdkSchema.$defs.Player.properties.avatar.type, [
  "string",
  "null",
]);
assert.equal("source" in sdkSchema.$defs.Player.properties, false);
assert.equal("latencyMs" in sdkSchema.$defs.Player.properties, false);
assert.equal("connectionMode" in sdkSchema.$defs.Player.properties, false);
assert.equal(defaultGameManifest.sdkVersion, "4.3.0");
assert.equal(defaultGameManifest.appSdkVersion, "3.5.0");
assert.deepEqual(defaultGameManifest.config, {
  webRuntime: { multithreading: false },
});
assert.deepEqual(gameManifestSchema.properties.sdkVersion.enum, ["4.1.0", "4.2.0", "4.3.0"]);
assert.equal(
  sdkManifest.projectRules.gameSdkVersion,
  "main.json sdkVersion is required and must be one of 4.1.0, 4.2.0, 4.3.0; new projects use 4.3.0",
);
assert.deepEqual(gameManifestSchema.properties.appSdkVersion.enum, [
  "3.2.0",
  "3.3.0",
  "3.4.0",
  "3.5.0",
]);
assert.equal(
  sdkManifest.projectRules.appSdkVersion,
  "main.json appSdkVersion is required and must be one of 3.2.0, 3.3.0, 3.4.0, 3.5.0; new projects use 3.5.0",
);
assert.deepEqual(sdkManifest.compatibility, {
  game: {
    baselineVersions: ["4.1.0"],
    bundleVersion: "4.3.0",
    supportedRequestedVersions: ["4.1.0", "4.2.0", "4.3.0"],
  },
  app: {
    baselineVersions: ["3.2.0", "3.3.0"],
    bundleVersion: "3.5.0",
    supportedRequestedVersions: ["3.2.0", "3.3.0", "3.4.0", "3.5.0"],
  },
});
assert.match(
  runtimeSdkCompatibilitySource,
  /gameBaselineVersions\s*=\s*\[\s*'4\.1\.0',?\s*\]/,
);
assert.match(
  runtimeSdkCompatibilitySource,
  /appBaselineVersions\s*=\s*\[\s*'3\.2\.0',\s*'3\.3\.0',?\s*\]/,
);
assert.match(
  runtimeSdkCompatibilitySource,
  /gameBundleVersion = '4\.3\.0'/,
);
assert.match(
  runtimeSdkCompatibilitySource,
  /appBundleVersion = '3\.5\.0'/,
);
assert.match(
  runtimeSdkCompatibilitySource,
  /gameMinimumVersion = '4\.1\.0'/,
);
assert.match(
  runtimeSdkCompatibilitySource,
  /appMinimumVersion = '3\.2\.0'/,
);
assert.match(
  runtimeSdkCompatibilitySource,
  /_isWithinInclusiveRange/,
);
assert.equal("permissions" in defaultGameManifest, false);
assert.equal("icon" in defaultGameManifest, false);
assert.equal("permissions" in gameManifestSchema.properties, false);
assert.equal("icon" in gameManifestSchema.properties, false);
assert.equal("type" in gameManifestSchema.properties.config, false);
for (const source of developerSources) {
  assert(!source.includes("/game/"), "开发模板或提示词仍包含旧 /game/ 路径");
}
for (const source of promptSources) {
  assert.match(source, /playmesh\.app\.runtime\.getLocale\(\)/);
  assert.match(source, /平台不会翻译游戏 DOM/);
  assert.match(source, /Authority 主机语言/);
  assert.equal(
    source.includes(defaultGameManifest.sdkVersion),
    false,
    "提示词不得复制 Game SDK 版本，版本事实源属于类型声明",
  );
  assert.equal(
    source.includes(defaultGameManifest.appSdkVersion),
    false,
    "提示词不得复制 App SDK 版本，版本事实源属于类型声明",
  );
}
assert.equal(localizationManifest.defaultLocale, "zh-CN");
assert(promptSourcesByLocale.has("en-US"), "提示词清单必须声明英文 locale");
for (const [locale, sources] of promptSourcesByLocale) {
  assert.equal(
    sources.length,
    promptManifest.templates.length,
    `${locale} 必须为每个提示词模板声明文件`,
  );
  for (const source of sources) {
    assert(source.trim().length > 0, `${locale} 提示词模板不能为空`);
  }
}
const runtimeKeySets = enabledPromptLocales.map(({ id, bundles }) => {
  const messages = JSON.parse(
    fs.readFileSync(`${localizationRoot}/${bundles.app}`, "utf8"),
  );
  return [
    id,
    Object.keys(messages)
      .filter((key) => key.startsWith("developer.prompt.runtime."))
      .sort(),
  ];
});
for (const [locale, keys] of runtimeKeySets.slice(1)) {
  assert.deepEqual(
    keys,
    runtimeKeySets[0][1],
    `${locale} runtime 提示词资源键必须与 ${runtimeKeySets[0][0]} 一致`,
  );
}

const completionMarkers = game.match(/@playmesh-completion\s+[A-Za-z0-9_.]+/g) ?? [];
assert(completionMarkers.length >= 40, "SDK 补全标记数量异常");
const chineseCharacters = (game + app).match(/[\u3400-\u9fff]/g) ?? [];
assert(chineseCharacters.length >= 500, "中文 JSDoc 内容不完整");

console.log("Playmesh SDK 中文声明与精确签名校验通过");
