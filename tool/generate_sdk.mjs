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
const developerPrompts = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "developer",
  "prompts",
);

function loadDartSdkSources() {
  const registry = fs.readFileSync(sourceRegistryPath, "utf8");
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
      /const\s+([A-Za-z][A-Za-z0-9]*SdkSource)\s*=\s*SdkSourceFragment\(\s*id:\s*'([^']+)',\s*target:\s*SdkSourceTarget\.(game|app),\s*order:\s*(\d+),\s*typeScript:\s*r'''([\s\S]*?)''',\s*\);/,
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
  const commands = new Set();
  const pattern =
    target === "game"
      ? /\b(?:post|storageCall)\((["'])([a-z][A-Za-z0-9.]+)\1/g
      : /\brequest\((["'])(app\.[A-Za-z0-9.]+)\1/g;
  for (const match of source.matchAll(pattern)) commands.add(match[2]);
  return commands;
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
  declarationName,
  versionName,
  placeholder,
  replacements = {},
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
  const declaration = declarationMatch[1]
    .replaceAll(placeholder, version)
    .trimStart();
  fs.mkdirSync(sourceDirectory, { recursive: true });
  fs.writeFileSync(sourcePath, resolvedSource, "utf8");
  fs.mkdirSync(outputDirectory, { recursive: true });
  fs.writeFileSync(path.join(outputDirectory, `${outputName}.js`), javascript, "utf8");
  fs.writeFileSync(path.join(outputDirectory, `${outputName}.d.ts`), declaration, "utf8");
  return version;
}

const dartSdkSources = loadDartSdkSources();
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
  declarationName: "PLAYMESH_DECLARATION",
  versionName: "PLAYMESH_SDK_VERSION",
  placeholder: "__PLAYMESH_SDK_VERSION__",
  replacements: {
    __PLAYMESH_APP_SDK_VERSION__: appSdkVersion,
  },
});
for (const name of ["playmesh.ts", "playmesh.js", "playmesh.d.ts"]) {
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
for (const name of ["playmesh.d.ts", "playmesh-app.d.ts"]) {
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
  const versionMember = manifest.namespaces
    ?.find((namespace) => namespace.name === "playmesh")
    ?.members?.find((member) => member.name === "version");
  if (versionMember) versionMember.value = gameSdkVersion;
});
updateJson(path.join(developerContracts, "schemas", "sdk-v1.json"), (schema) => {
  schema.$defs.SdkBootstrap.properties.sdkVersion.const = gameSdkVersion;
});
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

for (const promptName of ["common.txt", "agent-common.txt"]) {
  const promptPath = path.join(developerPrompts, promptName);
  const prompt = fs.readFileSync(promptPath, "utf8");
  const updated = prompt.replace(
    /当前 Game SDK 版本字符串，当前为 \d+\.\d+\.\d+。/,
    `当前 Game SDK 版本字符串，当前为 ${gameSdkVersion}。`,
  );
  if (updated === prompt && !prompt.includes(`当前为 ${gameSdkVersion}。`)) {
    throw new Error(`${promptName} 缺少 Game SDK 版本摘要标记`);
  }
  fs.writeFileSync(promptPath, updated, "utf8");
}

if (!process.argv.includes("--quiet")) {
  console.log(`Generated Game SDK ${gameSdkVersion} and App SDK ${appSdkVersion}`);
}
