import fs from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";

const toolDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.dirname(toolDirectory);
const sourceDirectory = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "sdk-src",
);
const sourceRegistryPath = path.join(
  repositoryRoot,
  "lib",
  "core",
  "game_sdk",
  "sdk_feature_registry.dart",
);
const outputDirectory = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "sdk",
  "v1",
);
const developerContracts = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "developer",
  "contracts",
);
function loadDartSdkSources() {
  const registry = fs.readFileSync(sourceRegistryPath, "utf8");
  function supportedRequestVersions(name) {
    const block = registry.match(
      new RegExp(
        `static const List<String> ${name}\\s*=\\s*\\[([\\s\\S]*?)\\];`,
      ),
    )?.[1];
    if (!block) {
      throw new Error(`SDK feature 注册表缺少 ${name}`);
    }
    const versions = [...block.matchAll(/'(\d+\.\d+\.\d+)'/g)].map(
      (match) => match[1],
    );
    if (!versions.length || new Set(versions).size !== versions.length) {
      throw new Error(`${name} 必须包含唯一的语义版本`);
    }
    for (let index = 1; index < versions.length; index += 1) {
      if (compareVersions(versions[index - 1], versions[index]) >= 0) {
        throw new Error(`${name} 必须严格递增`);
      }
    }
    return versions;
  }
  const partPaths = [
    ...registry.matchAll(/part '([^']*features\/[^']+\.dart)';/g),
  ].map((match) => match[1]);
  if (partPaths.length === 0) {
    throw new Error("SDK feature 注册表没有声明任何源码 part");
  }
  const registeredBlock = registry.match(
    /static const List<SdkSourceFragment> sourceFragments = \[([\s\S]*?)\n  \];/,
  )?.[1];
  if (!registeredBlock) {
    throw new Error("SDK feature 注册表缺少 sourceFragments");
  }
  const registeredNames = [
    ...registeredBlock.matchAll(/\b([A-Za-z][A-Za-z0-9]*SdkSource)\s*,/g),
  ].map((match) => match[1]);
  const fragments = [];
  for (const relativePartPath of partPaths) {
    const filePath = path.join(
      path.dirname(sourceRegistryPath),
      relativePartPath.replaceAll("/", path.sep),
    );
    const dart = fs.readFileSync(filePath, "utf8");
    const match = dart.match(
      /const\s+([A-Za-z][A-Za-z0-9]*SdkSource)\s*=\s*SdkSourceFragment\(\s*id:\s*'([^']+)',\s*target:\s*SdkSourceTarget\.(game|app),\s*order:\s*(\d+),\s*typeScript:\s*r'''([\s\S]*?)''',\s*(?:declaration:\s*r'''([\s\S]*?)''',\s*)?\);/,
    );
    if (!match) {
      throw new Error(`${relativePartPath} 缺少合法的 SdkSourceFragment`);
    }
    fragments.push({
      name: match[1],
      id: match[2],
      target: match[3],
      order: Number(match[4]),
      source: match[5],
      declaration: match[6] ?? "",
      dart,
    });
  }
  const discoveredNames = fragments.map((fragment) => fragment.name);
  const registeredNameSet = new Set(registeredNames);
  if (
    registeredNameSet.size !== registeredNames.length ||
    registeredNames.some((name) => !discoveredNames.includes(name))
  ) {
    throw new Error(
      "sourceFragments 引用了未发现或重复的 feature 源；最新版 SDK 必须在统一注册表声明",
    );
  }
  const selectedFragments = registeredNames.map((name) =>
    fragments.find((fragment) => fragment.name === name),
  );
  const ids = new Set();
  for (const fragment of fragments) {
    if (ids.has(fragment.id)) {
      throw new Error(`SDK feature id 重复: ${fragment.id}`);
    }
    ids.add(fragment.id);
  }
  const orders = new Set();
  for (const fragment of selectedFragments) {
    const orderKey = `${fragment.target}:${fragment.order}`;
    if (orders.has(orderKey)) {
      throw new Error(`SDK feature order 重复: ${orderKey}`);
    }
    orders.add(orderKey);
  }
  function assemble(target) {
    return selectedFragments
      .filter((fragment) => fragment.target === target)
      .sort((left, right) => left.order - right.order)
      .map((fragment) => fragment.source)
      .join("");
  }
  return {
    game: assemble("game"),
    app: assemble("app"),
    declarations: selectedFragments
      .filter((fragment) => fragment.declaration.trim())
      .sort((left, right) => {
        const targetComparison =
          (left.target === "game" ? 0 : 1) -
          (right.target === "game" ? 0 : 1);
        return targetComparison || left.order - right.order;
      })
      .map((fragment) => fragment.declaration),
    gameSupportedRequestVersions: supportedRequestVersions(
      "gameSdkSupportedRequestVersions",
    ),
    appSupportedRequestVersions: supportedRequestVersions(
      "appSdkSupportedRequestVersions",
    ),
    gameCompatibilityBaselineVersions: supportedRequestVersions(
      "gameSdkCompatibilityBaselineVersions",
    ),
    appCompatibilityBaselineVersions: supportedRequestVersions(
      "appSdkCompatibilityBaselineVersions",
    ),
    fragments,
  };
}

function compareVersions(left, right) {
  const leftParts = left.split(".").map(Number);
  const rightParts = right.split(".").map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (leftParts[index] !== rightParts[index]) {
      return leftParts[index] - rightParts[index];
    }
  }
  return 0;
}

function versionInRange(version, range) {
  return (
    compareVersions(version, range.minimum) >= 0 &&
    (range.maximum === "last" ||
      compareVersions(version, range.maximum) <= 0)
  );
}

function rangesOverlap(left, right) {
  return (
    (right.maximum === "last" ||
      compareVersions(left.minimum, right.maximum) <= 0) &&
    (left.maximum === "last" ||
      compareVersions(right.minimum, left.maximum) <= 0)
  );
}

function registeredCommands(fragments, target, bundleVersion) {
  const registrations = new Map();
  for (const fragment of fragments.filter(
    (candidate) => candidate.target === target,
  )) {
    for (const feature of fragment.dart.matchAll(
      /List<SdkVersionRange>\s+get supportedVersions\s*=>\s*const\s*\[([\s\S]*?)\];[\s\S]*?Set<String> get commands => const \{([\s\S]*?)\};/g,
    )) {
      const ranges = [
        ...feature[1].matchAll(
          /SdkVersionRange\(\s*'(\d+\.\d+\.\d+)'\s*,\s*(?:'(\d+\.\d+\.\d+)'|SdkVersionRange\.last)\s*\)/g,
        ),
      ].map((range) => ({
        minimum: range[1],
        maximum: range[2] ?? "last",
      }));
      if (!ranges.length) {
        throw new Error(`${fragment.id} 的 Dart 执行器没有声明支持版本`);
      }
      for (let left = 0; left < ranges.length; left += 1) {
        if (
          ranges[left].maximum !== "last" &&
          compareVersions(ranges[left].minimum, ranges[left].maximum) > 0
        ) {
          throw new Error(`${fragment.id} 的 Dart 执行器版本范围无效`);
        }
        for (let right = left + 1; right < ranges.length; right += 1) {
          if (rangesOverlap(ranges[left], ranges[right])) {
            throw new Error(`${fragment.id} 的 Dart 执行器版本范围重叠`);
          }
        }
      }
      for (const command of feature[2].matchAll(
        /'([a-z][A-Za-z0-9.]+)'/g,
      )) {
        const commandRegistrations = registrations.get(command[1]) ?? [];
        for (const registered of commandRegistrations) {
          if (
            ranges.some((range) =>
              registered.ranges.some((other) =>
                rangesOverlap(range, other),
              ),
            )
          ) {
            throw new Error(
              `${target} SDK 命令 ${command[1]} 的支持版本存在多个 Dart 执行器`,
            );
          }
        }
        commandRegistrations.push({ ranges, fragment: fragment.id });
        registrations.set(command[1], commandRegistrations);
      }
    }
  }
  const commands = new Set();
  for (const [command, commandRegistrations] of registrations) {
    const matches = commandRegistrations.filter((registration) =>
      registration.ranges.some((range) =>
        versionInRange(bundleVersion, range),
      ),
    );
    if (matches.length > 1) {
      throw new Error(
        `${target} SDK 命令 ${command} 在 ${bundleVersion} 存在多个 Dart 执行器`,
      );
    }
    if (matches.length === 1) commands.add(command);
  }
  return commands;
}

function invokedCommands(source, target) {
  const invocationNames = target === "game"
    ? new Set(["post", "sendBrowserTransport"])
    : new Set(["request"]);
  const commandPattern = target === "game"
    ? /^[a-z][A-Za-z0-9.]+$/
    : /^app\.[A-Za-z0-9.]+$/;
  const commands = new Set();
  let index = 0;
  while (index < source.length) {
    const current = source[index];
    if (current === "'" || current === '"' || current === "`") {
      index = skipJavaScriptQuoted(source, index, current);
      continue;
    }
    if (current === "/" && source[index + 1] === "/") {
      index = skipJavaScriptLineComment(source, index + 2);
      continue;
    }
    if (current === "/" && source[index + 1] === "*") {
      index = skipJavaScriptBlockComment(source, index + 2);
      continue;
    }
    if (current === "/" && isJavaScriptRegexStart(source, index)) {
      index = skipJavaScriptRegex(source, index);
      continue;
    }
    if (!/[A-Za-z_$]/.test(current)) {
      index += 1;
      continue;
    }
    const identifierStart = index;
    index += 1;
    while (index < source.length && /[A-Za-z0-9_$]/.test(source[index])) {
      index += 1;
    }
    const identifier = source.slice(identifierStart, index);
    if (!invocationNames.has(identifier)) continue;
    const previous = previousSignificantCharacter(source, identifierStart);
    if (previous === ".") continue;
    let cursor = skipJavaScriptTrivia(source, index);
    if (source[cursor] !== "(") continue;
    cursor = skipJavaScriptTrivia(source, cursor + 1);
    if (source[cursor] !== "'" && source[cursor] !== '"') continue;
    const literal = readJavaScriptCommandLiteral(source, cursor);
    if (literal && commandPattern.test(literal.value)) {
      commands.add(literal.value);
    }
  }
  return commands;
}

function previousSignificantCharacter(source, index) {
  for (let cursor = index - 1; cursor >= 0; cursor -= 1) {
    if (!/\s/.test(source[cursor])) return source[cursor];
  }
  return null;
}

function skipJavaScriptTrivia(source, start) {
  let index = start;
  while (index < source.length) {
    if (/\s/.test(source[index])) {
      index += 1;
      continue;
    }
    if (source[index] === "/" && source[index + 1] === "/") {
      index = skipJavaScriptLineComment(source, index + 2);
      continue;
    }
    if (source[index] === "/" && source[index + 1] === "*") {
      index = skipJavaScriptBlockComment(source, index + 2);
      continue;
    }
    break;
  }
  return index;
}

function skipJavaScriptLineComment(source, start) {
  const end = source.indexOf("\n", start);
  return end < 0 ? source.length : end + 1;
}

function skipJavaScriptBlockComment(source, start) {
  const end = source.indexOf("*/", start);
  return end < 0 ? source.length : end + 2;
}

function isJavaScriptRegexStart(source, index) {
  const previous = previousSignificantCharacter(source, index);
  return previous === null || "(=:[{!,?;|&+-*%^~<>".includes(previous);
}

function skipJavaScriptRegex(source, start) {
  let inCharacterClass = false;
  let index = start + 1;
  while (index < source.length) {
    const current = source[index];
    if (current === "\\") {
      index += 2;
      continue;
    }
    if (current === "\n" || current === "\r") return start + 1;
    if (current === "[") inCharacterClass = true;
    if (current === "]") inCharacterClass = false;
    if (current === "/" && !inCharacterClass) {
      index += 1;
      while (index < source.length && /[A-Za-z]/.test(source[index])) {
        index += 1;
      }
      return index;
    }
    index += 1;
  }
  return source.length;
}

function skipJavaScriptQuoted(source, start, quote) {
  let index = start + 1;
  while (index < source.length) {
    if (source[index] === "\\") {
      index += 2;
      continue;
    }
    if (source[index] === quote) return index + 1;
    index += 1;
  }
  return source.length;
}

function readJavaScriptCommandLiteral(source, start) {
  const quote = source[start];
  let value = "";
  for (let index = start + 1; index < source.length; index += 1) {
    const current = source[index];
    if (current === quote) return { value, end: index + 1 };
    if (current === "\\" || current === "\n" || current === "\r") {
      return null;
    }
    value += current;
  }
  return null;
}

function assertInvokedCommandSyntax() {
  const gameFixture = String.raw`
    // post("ignored.comment", {});
    const ignored = "sendBrowserTransport('ignored.string', {})";
    function post(command, payload) { return sendBrowserTransport(command, payload); }
    const ignoredPattern = /post\("ignored.regex", \{\}\)/g;
    post("sdk.ready", {});
    sendBrowserTransport('future.host.command', {});
    storageCall("storage.set", "save", "score", 1);
  `;
  const actual = [...invokedCommands(gameFixture, "game")].sort();
  const expected = ["future.host.command", "sdk.ready"];
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `Game SDK 宿主命令语法扫描器自检失败: ${JSON.stringify(actual)}`,
    );
  }
}

function assertCommandParity(sources) {
  for (const target of ["game", "app"]) {
    const versionName =
      target === "game"
        ? "PLAYMESH_SDK_VERSION"
        : "PLAYMESH_APP_SDK_VERSION";
    const versionMatch = sources[target].match(
      new RegExp(`const ${versionName} = ["'](\\d+\\.\\d+\\.\\d+)["'];`),
    );
    if (!versionMatch) {
      throw new Error(`${target} SDK 缺少合法版本`);
    }
    const invoked = invokedCommands(sources[target], target);
    const registered = registeredCommands(
      sources.fragments,
      target,
      versionMatch[1],
    );
    const missing = [...invoked].filter((command) => !registered.has(command));
    const stale = [...registered].filter((command) => !invoked.has(command));
    if (missing.length || stale.length) {
      throw new Error(
        `${target} SDK 命令与 Dart 执行器不一致；` +
          `缺少执行器=[${missing.join(", ")}]，未被 TS 使用=[${stale.join(", ")}]`,
      );
    }
  }
}

function generate({
  source,
  sourceName,
  outputName,
  javascriptOutputName = outputName,
  declarationOutputName = outputName,
  declarationName,
  versionName,
  placeholder,
  replacements = {},
  declarationFragments = [],
}) {
  let resolvedSource = source;
  for (const [from, to] of Object.entries(replacements)) {
    if (!resolvedSource.includes(from)) {
      throw new Error(`${sourceName} 缺少待替换的版本占位符 ${from}`);
    }
    resolvedSource = resolvedSource.replaceAll(from, to);
  }
  const sourcePath = path.join(sourceDirectory, sourceName);
  const declarationPattern = new RegExp(
    "const " + declarationName + " = String\\.raw`([\\s\\S]*?)`;\\n+",
  );
  const declarationMatch = resolvedSource.match(declarationPattern);
  if (!declarationMatch) {
    throw new Error(`${sourceName} 缺少 ${declarationName} 声明模板`);
  }
  const versionPattern = new RegExp(
    `const ${versionName} = ["'](\\d+\\.\\d+\\.\\d+)["'];`,
  );
  const versionMatch = resolvedSource.match(versionPattern);
  if (!versionMatch) {
    throw new Error(`${sourceName} 缺少合法的 ${versionName}`);
  }
  const version = versionMatch[1];
  const javascript = resolvedSource.replace(declarationPattern, "");
  const declaration = [
    declarationMatch[1].replaceAll(placeholder, version).trim(),
    ...declarationFragments
      .map((fragment) => {
        let resolvedFragment = fragment.replaceAll(placeholder, version);
        for (const [from, to] of Object.entries(replacements)) {
          resolvedFragment = resolvedFragment.replaceAll(from, to);
        }
        return resolvedFragment.trim();
      })
      .filter(Boolean),
  ].join("\n\n") + "\n";
  fs.mkdirSync(sourceDirectory, { recursive: true });
  fs.writeFileSync(sourcePath, resolvedSource, "utf8");
  fs.mkdirSync(outputDirectory, { recursive: true });
  fs.writeFileSync(
    path.join(outputDirectory, `${javascriptOutputName}.js`),
    javascript,
    "utf8",
  );
  fs.writeFileSync(
    path.join(outputDirectory, `${declarationOutputName}.d.ts`),
    declaration,
    "utf8",
  );
  return version;
}

const dartSdkSources = loadDartSdkSources();
assertInvokedCommandSyntax();
assertCommandParity(dartSdkSources);
const appSdkVersion = generate({
  source: dartSdkSources.app,
  sourceName: "playmesh-app.ts",
  outputName: "playmesh-app",
  declarationName: "PLAYMESH_APP_DECLARATION",
  versionName: "PLAYMESH_APP_SDK_VERSION",
  placeholder: "__PLAYMESH_APP_SDK_VERSION__",
});
const gameSdkVersion = generate({
  source: dartSdkSources.game,
  sourceName: "playmesh.ts",
  outputName: "playmesh",
  javascriptOutputName: "playmesh-main",
  declarationOutputName: "playmesh-main",
  declarationName: "PLAYMESH_DECLARATION",
  versionName: "PLAYMESH_SDK_VERSION",
  placeholder: "__PLAYMESH_SDK_VERSION__",
  replacements: {
    __PLAYMESH_APP_SDK_VERSION__: appSdkVersion,
  },
  declarationFragments: dartSdkSources.declarations,
});
const gameSupportedRequestVersions =
  dartSdkSources.gameSupportedRequestVersions;
const appSupportedRequestVersions = dartSdkSources.appSupportedRequestVersions;
for (const [target, versions, bundleVersion, baselineVersions] of [
  [
    "Game",
    gameSupportedRequestVersions,
    gameSdkVersion,
    dartSdkSources.gameCompatibilityBaselineVersions,
  ],
  [
    "App",
    appSupportedRequestVersions,
    appSdkVersion,
    dartSdkSources.appCompatibilityBaselineVersions,
  ],
]) {
  if (
    versions.length < baselineVersions.length ||
    baselineVersions.some((version, index) => versions[index] !== version)
  ) {
    throw new Error(
      `${target} SDK 兼容请求版本集合不能移除或改写基线 ${baselineVersions.join(", ")}`,
    );
  }
  if (versions.at(-1) !== bundleVersion) {
    throw new Error(
      `${target} SDK 当前 Bundle ${bundleVersion} 必须是兼容请求版本集合的最后一项`,
    );
  }
  if (
    versions.some(
      (version) => version.split(".")[0] !== versions[0].split(".")[0],
    )
  ) {
    throw new Error(`${target} SDK 兼容请求版本不得跨 MAJOR`);
  }
}
fs.rmSync(path.join(outputDirectory, "playmesh.js"), { force: true });
fs.rmSync(path.join(outputDirectory, "playmesh.d.ts"), { force: true });
for (const name of ["playmesh.ts", "playmesh-main.js", "playmesh-main.d.ts"]) {
  if (
    fs
      .readFileSync(
        name.endsWith(".ts") && !name.endsWith(".d.ts")
          ? path.join(sourceDirectory, name)
          : path.join(outputDirectory, name),
        "utf8",
      )
      .includes("__PLAYMESH_APP_SDK_VERSION__")
  ) {
    throw new Error(`${name} 仍包含未替换的 App SDK 版本占位符`);
  }
}
for (const name of ["playmesh-main.d.ts", "playmesh-app.d.ts"]) {
  if (fs.readFileSync(path.join(outputDirectory, name), "utf8").includes("__PLAYMESH")) {
    throw new Error(`${name} 仍包含未替换的版本占位符`);
  }
}

function updateJson(filePath, update) {
  const value = JSON.parse(fs.readFileSync(filePath, "utf8"));
  update(value);
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, "utf8");
}

updateJson(path.join(developerContracts, "sdk-manifest.json"), (manifest) => {
  manifest.version = gameSdkVersion;
  manifest.channelVersion = appSdkVersion;
  manifest.script = "/playmesh/sdk/v1/playmesh-main.js";
  const versionMember = manifest.namespaces
    ?.find((namespace) => namespace.name === "playmesh.main")
    ?.members?.find((member) => member.name === "version");
  if (versionMember) versionMember.value = gameSdkVersion;
  const appVersionMember = manifest.namespaces
    ?.find((namespace) => namespace.name === "playmesh.app")
    ?.members?.find((member) => member.name === "version");
  if (appVersionMember) appVersionMember.value = appSdkVersion;
  if (manifest.projectRules) {
    manifest.projectRules.gameSdkVersion =
      `main.json sdkVersion is required and must be one of ${gameSupportedRequestVersions.join(", ")}; new projects use ${gameSdkVersion}`;
    manifest.projectRules.appSdkVersion =
      `main.json appSdkVersion is required and must be one of ${appSupportedRequestVersions.join(", ")}; new projects use ${appSdkVersion}`;
  }
  manifest.compatibility = {
    game: {
      baselineVersions: dartSdkSources.gameCompatibilityBaselineVersions,
      bundleVersion: gameSdkVersion,
      supportedRequestedVersions: gameSupportedRequestVersions,
    },
    app: {
      baselineVersions: dartSdkSources.appCompatibilityBaselineVersions,
      bundleVersion: appSdkVersion,
      supportedRequestedVersions: appSupportedRequestVersions,
    },
  };
});
updateJson(path.join(developerContracts, "schemas", "sdk-v1.json"), (schema) => {
  schema.$defs.PlaymeshBootstrap.properties.sdkVersion.const = gameSdkVersion;
  schema.$defs.PlaymeshAppBootstrap.properties.sdkVersion.const = appSdkVersion;
});
updateJson(
  path.join(developerContracts, "schemas", "game-manifest.json"),
  (schema) => {
    delete schema.properties.sdkVersion.const;
    schema.properties.sdkVersion.enum = gameSupportedRequestVersions;
    schema.properties.appSdkVersion.enum = appSupportedRequestVersions;
  },
);
updateJson(
  path.join(
    repositoryRoot,
    "assets",
    "playmesh-library",
    "public",
    "developer",
    "templates",
    "default-game",
    "package",
    "main.json",
  ),
  (manifest) => {
    manifest.sdkVersion = gameSdkVersion;
    manifest.appSdkVersion = appSdkVersion;
  },
);

if (!process.argv.includes("--quiet")) {
  console.log(`Generated Game SDK ${gameSdkVersion} and App SDK ${appSdkVersion}`);
}
