import assert from "node:assert/strict";
import fs from "node:fs";

const read = (path) => fs.readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const manifest = JSON.parse(read("assets/playmesh-localization/manifest.json"));
const platformAssetsSource = read("lib/core/localization/platform_game_ui_assets.dart");
const gameCoreSource = read("lib/core/game_sdk/features/game/game_core_feature.dart");
const runtimeSource = read("lib/core/game_sdk/features/game/game_runtime_feature.dart");
const lifecycleSource = read("lib/core/game_sdk/features/game/game_storage_lifecycle_feature.dart");
const gamePerformanceSource = read(
  "lib/core/game_sdk/features/game/game_performance_feature.dart",
);
const appDeviceSource = read("lib/core/game_sdk/features/app/app_device_feature.dart");
const appPerformanceSource = read("lib/core/game_sdk/features/app/app_performance_feature.dart");
const appUiSource = read("lib/core/game_sdk/features/app/app_ui_feature.dart");
const appBridgeSource = read("lib/core/game_sdk/app_webview_bridge.dart");
const localGameWebViewSource = read("lib/features/game/local_game_web_view.dart");
const remoteGamePageSource = read("lib/features/game/remote_game_page.dart");
const webGatewaySource = read("lib/core/game_web/game_web_gateway_io.dart");
const sdkManifest = JSON.parse(
  read("assets/playmesh-library/public/developer/contracts/sdk-manifest.json"),
);
const sdkSchema = JSON.parse(
  read("assets/playmesh-library/public/developer/contracts/schemas/sdk-v1.json"),
);

const requiredBlock = platformAssetsSource.match(
  /const platformGameUiRequiredKeys = <String>\{([\s\S]*?)\};/,
)?.[1];
assert.ok(requiredBlock, "platform UI required key registry is missing");
const requiredKeys = [...requiredBlock.matchAll(/'([^']+)'/g)].map((match) => match[1]);
assert.ok(requiredKeys.length > 30, "platform UI required key registry is unexpectedly small");

const platformKeysByLocale = new Map();
for (const locale of manifest.locales) {
  const appPath = locale.bundles?.app;
  assert.equal(typeof appPath, "string", `${locale.id} app bundle is missing`);
  const messages = JSON.parse(read(`assets/playmesh-localization/${appPath}`));
  const platformMessages = Object.fromEntries(
    Object.entries(messages)
      .filter(([key]) => key.startsWith("platform.game."))
      .map(([key, value]) => [key.slice("platform.game.".length), value]),
  );
  for (const key of requiredKeys) {
    assert.equal(
      typeof platformMessages[key],
      "string",
      `${locale.id} is missing platform.game.${key}`,
    );
  }
  platformKeysByLocale.set(locale.id, Object.keys(platformMessages).sort());
}

const firstKeys = platformKeysByLocale.get(manifest.locales[0].id);
for (const [localeId, keys] of platformKeysByLocale) {
  assert.deepEqual(keys, firstKeys, `${localeId} platform UI keys differ`);
}

for (const phrase of [
  'title="展开游戏工具"',
  ">拒绝并退出<",
  ">同意并进入<",
  ">暂无运行日志<",
  ">玩家昵称<",
]) {
  assert.equal(
    runtimeSource.includes(phrase) || lifecycleSource.includes(phrase),
    false,
    `injected UI still hardcodes: ${phrase}`,
  );
}

assert.match(runtimeSource, /configurePlatformUi/);
assert.match(runtimeSource, /message\.type === "platform\.ui\.configure"/);
assert.doesNotMatch(runtimeSource, /readPlatformUiJson/);
assert.match(runtimeSource, /navigatorObject\?\.languages/);
assert.match(runtimeSource, /navigatorObject\?\.language/);
assert.match(runtimeSource, /BROWSER_RUNTIME_LOCALE_FALLBACK = "zh"/);
assert.match(
  runtimeSource,
  /BROWSER_PLATFORM_UI_FALLBACK_LOCALE = "zh-CN"/,
);
assert.doesNotMatch(runtimeSource, /"en-US"/);
assert.match(runtimeSource, /platformText\("capability\.denied"\)/);
assert.match(
  appUiSource,
  /host\.setAttribute\?\.\("data-theme", appUiConfiguration\?\.theme \|\| "dark"\)/,
);
assert.match(appUiSource, /:host\(\[data-theme="light"\]\)/);
assert.doesNotMatch(
  appUiSource,
  /appUiText\([^)\n]+,\s*["']/,
  "App SDK 平台 UI 不得维护本地化 fallback 文案",
);
assert.match(appPerformanceSource, /recordAppRuntimeLatencyPong/);
assert.match(appPerformanceSource, /reportAppPerformanceFrame/);
assert.match(appPerformanceSource, /appPerformanceProbeSequence/);
assert.match(appPerformanceSource, /global\.setInterval\(/);
assert.match(appPerformanceSource, /sendAppRuntimeLatencyProbe/);
assert.doesNotMatch(appPerformanceSource, /__reset/);
assert.doesNotMatch(appPerformanceSource, /post\("performance\.(?:fps|latency)"/);
assert.match(
  gamePerformanceSource,
  /sendLatencyProbe\(payload\) \{\s*return post\("performance\.ping", payload\);/,
);
assert.match(
  gamePerformanceSource,
  /appInternalRuntime\.recordRuntimeLatencyPong\?\.\(payload\)/,
);
assert.doesNotMatch(gamePerformanceSource, /setInterval|latencyProbeSequence/);
assert.match(lifecycleSource, /platformText\("nickname\.invalid"\)/);
assert.match(lifecycleSource, /platformText\("nickname\.update_failed"\)/);
assert.doesNotMatch(
  lifecycleSource,
  /sidebar-layer|info-overlay|logs-overlay|performance-panel/,
  "Main SDK 不得创建 App SDK 所属的平台菜单、信息、日志或性能 UI",
);
assert.match(appUiSource, /class="performance-panel"/);
assert.match(appUiSource, /class="dialog-layer info-layer"/);
assert.match(appUiSource, /class="dialog-layer logs-layer"/);
assert.doesNotMatch(lifecycleSource, /getLocale\(\)/);
assert.match(appDeviceSource, /getLocale\(\)/);
assert.doesNotMatch(
  `${runtimeSource}\n${lifecycleSource}`,
  /document\.documentElement\.(?:lang|setAttribute\(["']lang["'])/,
);
assert.match(gameCoreSource, /readonly runtime:/);
assert.match(gameCoreSource, /getLocale\(\): string/);
assert.doesNotMatch(gameCoreSource, /platformUiMessages|_playmeshPlatformUi/);
assert.match(appBridgeSource, /'_playmeshPlatformUi'/);
assert.match(appDeviceSource, /delete bootstrap\._playmeshPlatformUi/);
assert.match(appDeviceSource, /const appBootstrapResult = Object\.freeze/);
assert.match(appDeviceSource, /return appBootstrapResult/);
for (const appWebViewSource of [localGameWebViewSource, remoteGamePageSource]) {
  assert.match(
    appWebViewSource,
    /final brightness = Theme\.of\(context\)\.brightness;/,
  );
  assert.match(
    appWebViewSource,
    /platformGameUiConfigurationFor\(\s*localizations,\s*brightness:\s*brightness/,
  );
  assert.match(appWebViewSource, /'type': 'platform\.ui\.configure'/);
}
assert.match(platformAssetsSource, /PlatformGameUiBrowserCatalog/);
assert.match(platformAssetsSource, /platformGameBrowserFallbackLocaleId = 'zh-CN'/);
assert.match(webGatewaySource, /platformUiAssets\.browserCatalog\.toJson\(\)/);
assert.doesNotMatch(webGatewaySource, /acceptLanguageHeader/);
assert.match(webGatewaySource, /'_playmeshPlatformUi'/);
const runtimeNamespace = sdkManifest.namespaces.find(
  (namespace) => namespace.name === "playmesh.app.runtime",
);
assert.equal(runtimeNamespace?.members?.[0]?.name, "getLocale");
assert.equal(sdkSchema.$defs.RuntimeLocale.type, "string");
assert.equal("PlatformUiConfiguration" in sdkSchema.$defs, false);

console.log("Playmesh injected platform UI localization source contract passed.");
