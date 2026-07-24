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
const developerSources = [
  "assets/playmesh-library/public/developer/prompts/common.txt",
  "assets/playmesh-library/public/developer/prompts/agent-common.txt",
  "assets/playmesh-library/public/developer/templates/default-game/package/app/index.html",
  "assets/playmesh-library/public/developer/templates/default-game/package/app/controller/index.html",
].map((path) => fs.readFileSync(path, "utf8"));

assert(!game.includes("__PLAYMESH"), "Game SDK 声明包含未替换的占位符");
assert(!app.includes("__PLAYMESH"), "App SDK 声明包含未替换的占位符");
assert.match(game, /readonly version: "2\.2\.1"/);
assert.match(game, /readonly version: "2\.1\.0"/);
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
for (const source of developerSources) {
  assert(!source.includes("/game/"), "开发模板或提示词仍包含旧 /game/ 路径");
}

const completionMarkers = game.match(/@playmesh-completion\s+[A-Za-z0-9_.]+/g) ?? [];
assert(completionMarkers.length >= 40, "SDK 补全标记数量异常");
const chineseCharacters = (game + app).match(/[\u3400-\u9fff]/g) ?? [];
assert(chineseCharacters.length >= 500, "中文 JSDoc 内容不完整");

console.log("Playmesh SDK 中文声明与精确签名校验通过");
