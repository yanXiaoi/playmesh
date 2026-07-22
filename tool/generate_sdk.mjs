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
const outputDirectory = path.join(
  repositoryRoot,
  "assets",
  "playmesh-library",
  "public",
  "sdk",
  "v1",
);
const dartVersionFile = path.join(
  repositoryRoot,
  "lib",
  "core",
  "game_sdk",
  "generated_sdk_versions.dart",
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

function generate({ sourceName, outputName, declarationName, versionName, placeholder }) {
  const sourcePath = path.join(sourceDirectory, sourceName);
  const source = fs.readFileSync(sourcePath, "utf8").replaceAll("\r\n", "\n");
  const declarationPattern = new RegExp(
    "const " + declarationName + " = String\\.raw`([\\s\\S]*?)`;\\n+",
  );
  const declarationMatch = source.match(declarationPattern);
  if (!declarationMatch) {
    throw new Error(`${sourceName} 缺少 ${declarationName} 声明模板`);
  }
  const versionPattern = new RegExp(
    `const ${versionName} = ["'](\\d+\\.\\d+\\.\\d+)["'];`,
  );
  const versionMatch = source.match(versionPattern);
  if (!versionMatch) {
    throw new Error(`${sourceName} 缺少合法的 ${versionName}`);
  }
  const version = versionMatch[1];
  const javascript = source.replace(declarationPattern, "");
  const declaration = declarationMatch[1]
    .replaceAll(placeholder, version)
    .trimStart();
  fs.mkdirSync(outputDirectory, { recursive: true });
  fs.writeFileSync(path.join(outputDirectory, `${outputName}.js`), javascript, "utf8");
  fs.writeFileSync(path.join(outputDirectory, `${outputName}.d.ts`), declaration, "utf8");
  return version;
}

const gameSdkVersion = generate({
  sourceName: "playmesh.ts",
  outputName: "playmesh",
  declarationName: "PLAYMESH_DECLARATION",
  versionName: "PLAYMESH_SDK_VERSION",
  placeholder: "__PLAYMESH_SDK_VERSION__",
});
const appSdkVersion = generate({
  sourceName: "playmesh-app.ts",
  outputName: "playmesh-app",
  declarationName: "PLAYMESH_APP_DECLARATION",
  versionName: "PLAYMESH_APP_SDK_VERSION",
  placeholder: "__PLAYMESH_APP_SDK_VERSION__",
});

// playmesh.d.ts 同时声明 playmesh.app，必须嵌入同一次生成的 App SDK 版本。
const gameDeclarationPath = path.join(outputDirectory, "playmesh.d.ts");
fs.writeFileSync(
  gameDeclarationPath,
  fs.readFileSync(gameDeclarationPath, "utf8")
    .replaceAll("__PLAYMESH_APP_SDK_VERSION__", appSdkVersion),
  "utf8",
);
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

const dartSource = `// 此文件由 tool/generate_sdk.mjs 自动生成，请勿手工修改。\n` +
  `const generatedGameSdkVersion = '${gameSdkVersion}';\n` +
  `const generatedAppSdkVersion = '${appSdkVersion}';\n`;
fs.writeFileSync(dartVersionFile, dartSource, "utf8");

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
