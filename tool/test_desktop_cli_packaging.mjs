import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";

const windows = fs.readFileSync("windows/CMakeLists.txt", "utf8");
const linux = fs.readFileSync("linux/CMakeLists.txt", "utf8");
const macProject = fs.readFileSync("macos/Runner.xcodeproj/project.pbxproj", "utf8");
const macScript = fs.readFileSync("tool/build_dev_cli_macos.sh", "utf8");
const release = fs.readFileSync("tool/build_release.ps1", "utf8");
const windowsRelease = fs.readFileSync("tool/build_windows_release_ninja.ps1", "utf8");
const coreRelease = fs.readFileSync("tool/build_go_core.ps1", "utf8");
const runtimeCoreRelease = fs.readFileSync(
  "runtime/src/tool/build_go_core.ps1",
  "utf8",
);
const runtimeWindows = fs.readFileSync(
  "runtime/src/windows/CMakeLists.txt",
  "utf8",
);
const apkSignerCli = fs.readFileSync(
  "go-core/cmd/playmesh-apksign/main.go",
  "utf8",
);
const apkSignerBridge = fs.readFileSync(
  "go-core/appnative/apksig.go",
  "utf8",
);

for (const [name, content] of [["Windows", windows], ["Linux", linux]]) {
  assert.match(content, /PLAYMESH_CLI_SOURCE_DIR/);
  assert.match(content, /playmesh_dev_cli ALL/);
  assert.match(content, /add_dependencies\(\$\{BINARY_NAME\} playmesh_dev_cli\)/);
  assert.match(content, /install\(PROGRAMS "\$\{PLAYMESH_CLI_BINARY\}"/);
  assert.match(content, /install\(FILES "\$\{CMAKE_SOURCE_DIR\}\/\.\.\/LICENSE"/);
  assert.match(content, /playmesh-cli(?:\.exe)?/);
  assert.match(
    content,
    /file\(GLOB_RECURSE PLAYMESH_CLI_SOURCES CONFIGURE_DEPENDS/,
  );
  assert.match(
    content,
    /internal\/adapter\/cocos\/extension\/\*/,
  );
  console.log(`${name} CLI 跟随编译规则存在`);
}

assert.match(macProject, /Build Playmesh CLI/);
assert.match(macProject, /Contents\/MacOS\/playmesh-cli/);
assert.match(macProject, /build_dev_cli_macos\.sh/);
assert.match(macScript, /GOOS=darwin/);
assert.match(macScript, /xcrun lipo -create/);
assert.match(release, /'playmesh-cli\.exe'/);
assert.match(release, /'playmesh-apksign\.exe'/);
assert.match(release, /'APKSIG-GO-LICENSE\.txt'/);
assert.match(release, /'APKSIG-GO-NOTICE\.txt'/);
assert.match(release, /'WINRES-LICENSE\.txt'/);
assert.match(release, /'NFNT-RESIZE-LICENSE\.txt'/);
assert.match(release, /'GOLANG-X-IMAGE-LICENSE\.txt'/);
assert.match(release, /'GOLANG-X-IMAGE-PATENTS\.txt'/);
assert.match(release, /'LICENSE'/);
assert.match(release, /\[ValidateSet\('all', 'android', 'windows'\)\]/);
assert.match(
  coreRelease,
  /\[ValidateSet\("android", "windows", "windows-apksign", "all"\)\]/,
);
assert.doesNotMatch(coreRelease, /PLAYMESH_APKSIG_GO_ROOT/);
assert.doesNotMatch(coreRelease, /New-GoCoreWorkspace|go work init/);
assert.match(coreRelease, /go mod download -json/);
assert.match(coreRelease, /go list -mod=readonly -m -json/);
assert.match(coreRelease, /github\.com\/agusibrahim\/apksig-go@/);
assert.match(coreRelease, /-mod=readonly/);
assert.match(coreRelease, /GOFLAGS\s*=\s*"-buildvcs=false"/);
assert.match(coreRelease, /third_party\/licenses\/apksig-go/);
assert.match(coreRelease, /third_party\/licenses\/winres/);
assert.match(coreRelease, /third_party\/licenses\/nfnt-resize/);
assert.match(coreRelease, /third_party\/licenses\/golang-x-image/);
assert.match(coreRelease, /github\.com\/tc-hib\/winres/);
assert.match(coreRelease, /github\.com\/nfnt\/resize/);
assert.match(coreRelease, /golang\.org\/x\/image/);
assert.match(coreRelease, /playmesh-apksign\.exe/);
assert.match(coreRelease, /\.\/cmd\/playmesh-apksign/);
assert.match(coreRelease, /function Build-WindowsApkSigner/);
assert.match(coreRelease, /\$Target -eq "windows-apksign"/);
assert.match(coreRelease, /CGO_ENABLED\s*=\s*"0"/);
assert.match(coreRelease, /\.\/mobile \.\/appnative/);
assert.match(coreRelease, /META-INF\/LICENSE-apksig-go\.txt/);
assert.match(coreRelease, /META-INF\/NOTICE-apksig-go\.txt/);
assert.match(coreRelease, /META-INF\/LICENSE-winres\.txt/);
assert.match(coreRelease, /META-INF\/LICENSE-nfnt-resize\.txt/);
assert.match(coreRelease, /META-INF\/LICENSE-golang-x-image\.txt/);
assert.match(coreRelease, /META-INF\/PATENTS-golang-x-image\.txt/);
assert.match(windows, /playmesh_apksign ALL/);
assert.match(windows, /-Target windows-apksign/);
assert.match(windows, /install\(PROGRAMS "\$\{PLAYMESH_APKSIGN_BINARY\}"/);
assert.match(windows, /"\$\{PLAYMESH_APKSIGN_LICENSE\}"/);
assert.match(windows, /"\$\{PLAYMESH_APKSIGN_NOTICE\}"/);
assert.match(windows, /third_party\/licenses\/apksig-go\/LICENSE/);
assert.match(windows, /third_party\/licenses\/apksig-go\/NOTICE/);
assert.match(windows, /PLAYMESH_EXPORTER_ATTRIBUTIONS/);
assert.match(windows, /WINRES-LICENSE\.txt/);
assert.match(windows, /NFNT-RESIZE-LICENSE\.txt/);
assert.match(windows, /GOLANG-X-IMAGE-LICENSE\.txt/);
assert.match(windows, /GOLANG-X-IMAGE-PATENTS\.txt/);
assert.match(windows, /third_party\/licenses\/winres\/LICENSE/);
assert.match(windows, /third_party\/licenses\/nfnt-resize\/LICENSE/);
assert.match(windows, /third_party\/licenses\/golang-x-image\/LICENSE/);
assert.match(windows, /third_party\/licenses\/golang-x-image\/PATENTS/);
for (const attributionFile of [
  "third_party/licenses/apksig-go/LICENSE",
  "third_party/licenses/apksig-go/NOTICE",
]) {
  assert.equal(fs.existsSync(attributionFile), true);
}
const verifiedResourceAttributions = new Map([
  [
    "third_party/licenses/winres/LICENSE",
    "0b312a18265be4d536b0fcc33f0f18e47d10bbd9559ff8b0786606173610e22c",
  ],
  [
    "third_party/licenses/nfnt-resize/LICENSE",
    "7b850692b15c71706bc6906b51d6375c1404c2d26233078335b6aaa7def8b3f4",
  ],
  [
    "third_party/licenses/golang-x-image/LICENSE",
    "911f8f5782931320f5b8d1160a76365b83aea6447ee6c04fa6d5591467db9dad",
  ],
  [
    "third_party/licenses/golang-x-image/PATENTS",
    "96f408bfae65bf137fc2525d3ecb030271c50c1e90799f87abf8846d8dd505cc",
  ],
]);
for (const [attributionFile, expectedSha256] of verifiedResourceAttributions) {
  assert.equal(fs.existsSync(attributionFile), true);
  const sha256 = crypto
    .createHash("sha256")
    .update(fs.readFileSync(attributionFile))
    .digest("hex");
  assert.equal(sha256, expectedSha256);
}
assert.doesNotMatch(runtimeCoreRelease, /windows-apksign|playmesh-apksign/i);
assert.doesNotMatch(runtimeWindows, /windows-apksign|playmesh[-_]apksign/i);
assert.doesNotMatch(
  runtimeCoreRelease,
  /winres|nfnt[-/]resize|golang[-/]x[-/]image/i,
);
assert.doesNotMatch(
  runtimeWindows,
  /winres|nfnt[-/]resize|golang[-/]x[-/]image/i,
);
assert.match(runtimeCoreRelease, /-o \$Output `\s*\.\/mobile/);
assert.doesNotMatch(
  runtimeCoreRelease,
  /\.\/appnative\b|playmesh[-_]apksign|agusibrahim\/apksig-go|\bapksig\b/i,
);
assert.match(
  runtimeCoreRelease,
  /\$classNames -contains "appnative\/Appnative\.class"[\s\S]*?must not bind the main-App exporter package/,
);
assert.match(apkSignerCli, /appnative\.SignApk/);
assert.doesNotMatch(apkSignerCli, /flags\.(?:Bool|String)\("align"/);
assert.doesNotMatch(apkSignerCli, /flags\.(?:Bool|String)\("v3/);
assert.match(apkSignerBridge, /Align:\s+false/);
assert.match(release, /-SkipSdkGeneration/);
assert.match(windowsRelease, /pubspec\.yaml version must use MAJOR\.MINOR\.PATCH\+BUILD/);
assert.match(windowsRelease, /\[switch\]\$SkipSdkGeneration/);
assert.match(windowsRelease, /\[switch\]\$ValidateToolchainOnly/);
assert.match(
  windowsRelease,
  /if \(-not \$SkipSdkGeneration\) \{\s*& \(Join-Path \$PSScriptRoot 'generate_sdk\.ps1'\)\s*\}/,
);
assert.match(windowsRelease, /-DPLAYMESH_FLUTTER_VERSION=\$version/);
assert.match(windowsRelease, /build\\flutter_assets/);
assert.match(windowsRelease, /Refusing to clean Flutter assets outside build/);
assert.match(windowsRelease, /set "Path=" && set "PATH=/);
assert.match(windowsRelease, /HashSet\[string\].*OrdinalIgnoreCase/);
assert.match(windows, /set\(FLUTTER_VERSION "\$\{PLAYMESH_FLUTTER_VERSION\}"\)/);

console.log("桌面 CLI 跟随编译与产物命名校验通过");
