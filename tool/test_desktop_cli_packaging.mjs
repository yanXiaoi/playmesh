import assert from "node:assert/strict";
import fs from "node:fs";

const windows = fs.readFileSync("windows/CMakeLists.txt", "utf8");
const linux = fs.readFileSync("linux/CMakeLists.txt", "utf8");
const macProject = fs.readFileSync("macos/Runner.xcodeproj/project.pbxproj", "utf8");
const macScript = fs.readFileSync("tool/build_dev_cli_macos.sh", "utf8");
const release = fs.readFileSync("tool/build_release.ps1", "utf8");
const windowsRelease = fs.readFileSync("tool/build_windows_release_ninja.ps1", "utf8");
const coreRelease = fs.readFileSync("tool/build_go_core.ps1", "utf8");

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
assert.match(release, /'LICENSE'/);
assert.match(release, /\[ValidateSet\('all', 'android', 'windows'\)\]/);
assert.match(coreRelease, /\[ValidateSet\("android", "windows", "all"\)\]/);
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
