import assert from "node:assert/strict";
import fs from "node:fs";

const game = fs.readFileSync(
  "assets/playmesh-library/public/sdk/v1/playmesh.d.ts",
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
const sdkRegistrySource = fs.readFileSync(
  "lib/core/game_sdk/sdk_feature_registry.dart",
  "utf8",
);
const sdkGeneratorSource = fs.readFileSync("tool/generate_sdk.mjs", "utf8");
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
const promptSources = [
  "assets/playmesh-library/public/developer/prompts/common.txt",
  "assets/playmesh-library/public/developer/prompts/agent-common.txt",
].map((path) => fs.readFileSync(path, "utf8"));
const developerSources = [
  ...promptSources,
  ...[
    "assets/playmesh-library/public/developer/templates/default-game/package/app/index.html",
    "assets/playmesh-library/public/developer/templates/default-game/package/app/controller/index.html",
  ].map((path) => fs.readFileSync(path, "utf8")),
];

assert(!game.includes("__PLAYMESH"), "Game SDK 声明包含未替换的占位符");
assert(!app.includes("__PLAYMESH"), "App SDK 声明包含未替换的占位符");
assert.match(game, /readonly version: "2\.4\.0"/);
assert.match(game, /readonly version: "2\.2\.0"/);
assert.match(
  game,
  /interface PlaymeshAppApi \{[\s\S]*?readonly version: "2\.2\.0";/,
);
assert.match(
  gameRuntimeSource,
  /version: "__PLAYMESH_APP_SDK_VERSION__"/,
);
assert(!gameRuntimeSource.includes("2.0.0-empty"));
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
assert.match(game, /capabilities\.create/);
assert.doesNotMatch(game, /onDevice\(/);
assert.match(app, /reference path="\.\/playmesh\.d\.ts"/);
assert.match(
  game,
  /submitState\(key: string, value: PlaymeshJson, options\?: \{ rateHz\?: number \}\): Promise<null>/,
);
assert.match(game, /onChange\(callback: \(event: PlaymeshLifecycleEvent\) => void\)/);
assert.match(game, /当前会话中的玩家/);
assert.match(game, /固定 Authority Client/);
assert.match(game, /Authority 主机上的持久 JSON Bucket/);
assert.match(game, /准备、倒计时和玩法条件由游戏 Authority 判断/);
assert.match(game, /SDK 不判断胜负/);
assert.match(game, /readonly runtime:[\s\S]*getLocale\(\): string/);
assert.doesNotMatch(game, /_playmeshPlatformUi|platformUiMessages/);
assert.match(
  game,
  /interface PlaymeshPlayer \{[\s\S]*avatar: string \| null;[\s\S]*role: "authority" \| "authority_player" \| "player";[\s\S]*connected: boolean;/,
);
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
assert.match(game, /showToolDock\(\): Promise<void>/);
assert.match(game, /hideToolDock\(\): Promise<void>/);
assert.match(game, /exitGame\(\): Promise<void>/);
assert.match(game, /send\(data: Uint8Array\): Promise<void>/);
assert.match(game, /send\(targetPlayerIds: readonly string\[\], data: Uint8Array\): Promise<void>/);
assert.match(game, /sendLatest\(data: Uint8Array\): Promise<void>/);
assert.match(game, /sendLatest\(targetPlayerIds: readonly string\[\], data: Uint8Array\): Promise<void>/);
assert.match(game, /interface PlaymeshBinaryForwardContext[\s\S]*targetPlayerIds: string\[\]/);
assert.doesNotMatch(game, /sendLast\(/);
assert.match(app, /游戏业务使用 playmesh\.app/);
assert.equal(sdkManifest.projectRules.appUrlRoot, "/app/");
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
  (namespace) => namespace.name === "playmesh.runtime",
);
assert.equal(runtimeNamespace.members[0].name, "getLocale");
assert.equal(runtimeNamespace.members[0].signature, "getLocale(): string");
assert.match(runtimeNamespace.members[0].behavior, /fall back to zh$/);
const appNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.app",
);
const openSharePanel = appNamespace.members.find(
  (member) => member.name === "openSharePanel",
);
assert.equal(openSharePanel.signature, "openSharePanel(): Promise<void>");
assert.match(openSharePanel.behavior, /returns no token, URL, QR code/);
for (const memberName of ["showToolDock", "hideToolDock", "exitGame"]) {
  assert(appNamespace.members.some((member) => member.name === memberName));
}
const authorityNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.authority",
);
assert.equal(
  authorityNamespace.members.some((member) => member.name === "openSharePanel"),
  false,
);
assert.equal(sdkSchema.$defs.RuntimeLocale.type, "string");
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
assert.equal(defaultGameManifest.sdkVersion, "2.4.0");
assert.equal("permissions" in defaultGameManifest, false);
assert.equal("icon" in defaultGameManifest, false);
assert.equal("permissions" in gameManifestSchema.properties, false);
assert.equal("icon" in gameManifestSchema.properties, false);
for (const source of developerSources) {
  assert(!source.includes("/game/"), "开发模板或提示词仍包含旧 /game/ 路径");
}
for (const source of promptSources) {
  assert.match(source, /playmesh\.runtime\.getLocale\(\)/);
  assert.match(source, /平台不会翻译游戏 DOM/);
  assert.match(source, /Authority 主机语言/);
}

const completionMarkers = game.match(/@playmesh-completion\s+[A-Za-z0-9_.]+/g) ?? [];
assert(completionMarkers.length >= 40, "SDK 补全标记数量异常");
const chineseCharacters = (game + app).match(/[\u3400-\u9fff]/g) ?? [];
assert(chineseCharacters.length >= 500, "中文 JSDoc 内容不完整");

console.log("Playmesh SDK 中文声明与精确签名校验通过");
