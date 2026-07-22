import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const root = path.dirname(toolDirectory);
const read = (relativePath) =>
  fs.readFileSync(path.join(root, relativePath), 'utf8');

const releaseScript = read('tool/build_release.ps1');
assert.match(
  releaseScript,
  /ValidateSet\('all', 'harmony', 'android', 'windows'\)/,
  'release target list must contain harmony',
);
assert.match(releaseScript, /build hap --release --target-platform ohos-arm64/);
assert.match(releaseScript, /HarmonySigningProfile/);
assert.match(releaseScript, /AndroidFlutter/);
assert.match(releaseScript, /PLAYMESH_ANDROID_FLUTTER/);
assert.match(releaseScript, /D:\\KaiFaTool\\runtime\\flutter/);
assert.match(releaseScript, /Android builds require the standard Flutter SDK/);
assert.match(releaseScript, /flutter\.sdk=/);
assert.match(releaseScript, /harmonyEnvironmentSnapshot/);
assert.match(releaseScript, /SetEnvironmentVariable/);
assert.match(releaseScript, /HarmonyNdk/);
assert.match(releaseScript, /HarmonyGo/);
assert.match(releaseScript, /ohos-sdk-windows_linux-public/);
assert.match(releaseScript, /flutter-oh-3\.22\.3/);
assert.match(releaseScript, /oh-command-line-tools\\hvigor/);
assert.match(releaseScript, /build_go_core\.ps1/);
assert.match(releaseScript, /entry-default-signed\.hap/);
assert.match(releaseScript, /harmonyos-arm64\.hap/);
assert.match(releaseScript, /libs\/arm64-v8a\/libplaymesh_core\.so/);
assert.match(releaseScript, /libs\/arm64-v8a\/libplaymesh_core_napi\.so/);

const coreBuildScript = read('tool/build_go_core.ps1');
assert.match(
  coreBuildScript,
  /ValidateSet\("harmony", "android", "windows", "all"\)/,
);
assert.match(coreBuildScript, /buildmode=c-shared/);
assert.match(coreBuildScript, /aarch64-linux-ohos/);
assert.match(coreBuildScript, /\$env:GOOS = 'openharmony'/);
assert.match(coreBuildScript, /\$env:GOTOOLCHAIN = 'local'/);
assert.match(coreBuildScript, /-modfile=go\.harmony\.mod/);
assert.match(coreBuildScript, /openharmony\/arm64/);
assert.match(coreBuildScript, /Machine:\\s\+AArch64/);
for (const symbol of [
  'PlaymeshCoreStart',
  'PlaymeshCoreStop',
  'PlaymeshCoreFree',
]) {
  assert.ok(coreBuildScript.includes(symbol), `missing ELF check for ${symbol}`);
}

const harmonyCoreAbi = read('go-core/harmony/main.go');
assert.match(harmonyCoreAbi, /\/\/go:build cgo && openharmony/);
assert.ok(harmonyCoreAbi.includes('core "go-core/mobile"'));
assert.match(harmonyCoreAbi, /\/\/export PlaymeshCoreStart/);
assert.match(harmonyCoreAbi, /\/\/export PlaymeshCoreStop/);
assert.match(harmonyCoreAbi, /\/\/export PlaymeshCoreFree/);

const harmonyGoModule = read('go-core/go.harmony.mod');
assert.match(harmonyGoModule, /^go 1\.24\.0$/m);
assert.doesNotMatch(harmonyGoModule, /golang\.org\/x\/mobile/);

const harmonyPubspec = read('tool/harmony/pubspec.yaml');
for (const dependency of [
  'webview_flutter',
  'file_selector_ohos',
  'path_provider_ohos',
  'mobile_scanner',
  'share_plus',
  'sensors_plus',
]) {
  assert.match(
    harmonyPubspec,
    new RegExp(`^  ${dependency}:`, 'm'),
    `Harmony dependency set must contain ${dependency}`,
  );
}
const refs = [...harmonyPubspec.matchAll(/^\s+ref:\s+([0-9a-f]+)$/gm)].map(
  (match) => match[1],
);
assert.ok(refs.length >= 8, 'native Harmony dependencies must be pinned');
assert.ok(refs.every((ref) => ref.length === 40), 'git refs must be commit SHAs');
assert.doesNotMatch(harmonyPubspec, /webview_flutter_windows/);
assert.match(harmonyPubspec, /mobile_scanner:\s*\n\s+path: ohos\/mobile_scanner_compat/);
assert.doesNotMatch(
  read('ohos/mobile_scanner_compat/pubspec.yaml'),
  /platforms:\s*\n\s+ohos:/,
);

const appManifest = read('ohos/AppScope/app.json5');
assert.match(appManifest, /"bundleName": "top\.zfjmm\.playmesh"/);
const rootVersion = read('pubspec.yaml').match(
  /^version:\s*([^+\s]+)\+(\d+)\s*$/m,
);
assert.ok(rootVersion, 'root pubspec must provide name and build versions');
const parsedAppManifest = JSON.parse(appManifest);
assert.equal(parsedAppManifest.app.versionName, rootVersion[1]);
assert.equal(parsedAppManifest.app.versionCode, Number(rootVersion[2]));
const entryPackage = JSON.parse(read('ohos/entry/oh-package.json5'));
assert.equal(entryPackage.version, rootVersion[1]);

const moduleManifest = read('ohos/entry/src/main/module.json5');
assert.match(moduleManifest, /"deviceTypes": \["default", "tablet"\]/);
assert.match(moduleManifest, /ohos\.permission\.INTERNET/);
assert.match(moduleManifest, /ohos\.permission\.VIBRATE/);

const entryAbility = read(
  'ohos/entry/src/main/ets/entryability/EntryAbility.ets',
);
assert.match(entryAbility, /PlaymeshHarmonyCapabilitiesPlugin/);
assert.match(entryAbility, /this\.addPlugin/);
assert.match(entryAbility, /new NativePlaymeshHarmonyCoreAdapter\(\)/);

const capabilityPlugin = read(
  'ohos/playmesh_harmony_capabilities/src/main/ets/PlaymeshHarmonyCapabilitiesPlugin.ets',
);
for (const channel of [
  'playmesh/harmony_capabilities',
  'playmesh/go_core_host',
  'dev.fluttercommunity.plus/sensors/accelerometer',
  'dev.fluttercommunity.plus/sensors/gyroscope',
]) {
  assert.ok(capabilityPlugin.includes(channel), `missing channel ${channel}`);
}
assert.match(capabilityPlugin, /interface PlaymeshHarmonyCoreAdapter/);
assert.match(capabilityPlugin, /class NativePlaymeshHarmonyCoreAdapter/);
assert.match(capabilityPlugin, /implements FlutterPlugin, MethodCallHandler, AbilityAware/);
assert.match(capabilityPlugin, /onAttachedToAbility\(binding: AbilityPluginBinding\)/);
assert.match(capabilityPlugin, /from 'libplaymesh_core_napi\.so'/);
assert.match(capabilityPlugin, /'go-core-host'/);
assert.doesNotMatch(capabilityPlugin, /coreAdapter\?:/);

const capabilityBuildProfile = read(
  'ohos/playmesh_harmony_capabilities/build-profile.json5',
);
assert.match(capabilityBuildProfile, /"abiFilters": \["arm64-v8a"\]/);
assert.match(capabilityBuildProfile, /"runtimeOS": "OpenHarmony"/);

const coreCmake = read(
  'ohos/playmesh_harmony_capabilities/src/main/cpp/CMakeLists.txt',
);
assert.match(coreCmake, /add_library\(playmesh_core SHARED IMPORTED\)/);
assert.match(coreCmake, /add_library\(playmesh_core_napi SHARED/);
assert.match(coreCmake, /libace_napi\.z\.so/);

const coreNapi = read(
  'ohos/playmesh_harmony_capabilities/src/main/cpp/playmesh_core_napi.cpp',
);
assert.match(coreNapi, /napi_create_async_work/);
assert.match(coreNapi, /PlaymeshCoreStart/);
assert.match(coreNapi, /PlaymeshCoreStop/);

const harmonyGoInstaller = read('tool/install_harmony_go.ps1');
assert.match(harmonyGoInstaller, /go1\.24\.5\.ohosv1r1/);
assert.match(
  harmonyGoInstaller,
  /2d8b23f6923100d8c90d8add9299da2c9d032a20/,
);
assert.match(harmonyGoInstaller, /go-1\.24\.5-openharmony/);
assert.match(harmonyGoInstaller, /openharmony\/arm64/);

const harmonyDocumentation = read('docs/harmony-release.md');
for (const runtimeDirectory of [
  'ohos-sdk-windows_linux-public',
  'flutter-oh-3.22.3',
  'oh-command-line-tools',
  'go-1.24.5-openharmony',
]) {
  assert.ok(
    harmonyDocumentation.includes(runtimeDirectory),
    `Harmony documentation must contain runtime directory ${runtimeDirectory}`,
  );
}
assert.match(harmonyDocumentation, /Public SDK 不含 HMS `@kit\.ScanKit`/);
assert.match(harmonyDocumentation, /entry-default-unsigned\.hap/);

const architectureDocumentation = read('docs/01-architecture.md');
assert.match(architectureDocumentation, /NativePlaymeshHarmonyCoreAdapter/);
assert.match(architectureDocumentation, /扫码页面只提供手动输入回退/);
assert.doesNotMatch(
  architectureDocumentation,
  /鸿蒙端当前可以运行[^。]*扫码/,
);

const harmonyVerification = read(
  'docs/verification/playmesh-1.6.2-harmony-build-2026-07-22.md',
);
assert.match(harmonyVerification, /33,424,471 字节/);
assert.match(
  harmonyVerification,
  /9367B8281CFF5E099B43D03016C3B2565C0DB7BC88EB2F1D99369815667ADCEE/,
);
assert.match(harmonyVerification, /尚未执行 OpenHarmony\/HarmonyOS 真机安装/);

const allBuildVerification = read(
  'docs/verification/playmesh-1.6.2-all-build-2026-07-22.md',
);
for (const artifactHash of [
  '109D998D312B5FBF4A6A95A45C5458E89CFB556443CAF1BF5FC4E77A7F236EDD',
  '1EDB6719AA2F8801FFDF24740606954251C9075F13C73395620D627A9EDD4A05',
  '4EB65939D6514ECC5C8EAFF77CB51191F71988C9D3E58C4481C6FAD129A355F9',
]) {
  assert.match(allBuildVerification, new RegExp(artifactHash));
}
assert.match(allBuildVerification, /unable to resolve class groovy\.xml\.QName/);
assert.match(allBuildVerification, /-Target all -AllowDebugSigning/);
assert.match(allBuildVerification, /尚未执行 Android 或 OpenHarmony\/HarmonyOS 真机安装/);

console.log('Harmony release configuration checks passed.');
