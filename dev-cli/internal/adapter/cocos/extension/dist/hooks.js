"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const {
  appendCLILog,
  prepareCLILog,
} = require("./cli-log");

const sdkTag = '<script src="/playmesh/sdk/v1/playmesh-main.js"></script>';

exports.throwError = true;

exports.onAfterBuild = async function onAfterBuild(options, result) {
  const root =
    global.Editor && Editor.Project && Editor.Project.path
      ? Editor.Project.path
      : process.cwd();
  const config = readConfig(root);
  if (!config.integration || config.integration.type !== "cocos") {
    return;
  }
  const playmeshOptions =
    options.packages && options.packages.playmesh
      ? options.packages.playmesh
      : {};
  if (playmeshOptions.enabled === false) {
    return;
  }
  const source = result && result.dest ? result.dest : options.dest;
  if (!source) {
    throw new Error("Playmesh 无法读取 Cocos Web 构建输出目录");
  }
  validateBuildPlatform(config, options);
  stageBuild(root, config, source);
  if (
    config.integration.autoRunAfterBuild === false ||
    playmeshOptions.runAfterBuild === false
  ) {
    console.log("[Playmesh] 已更新最近构建，未自动运行。");
    return;
  }
  await runCLI(root, ["run"]);
};

function validateBuildPlatform(config, options) {
  const expected = String(config.integration.platform || "").trim();
  const actual = String(options.platform || "").trim();
  if (!expected || !actual || expected === actual) {
    return;
  }
  throw new Error(
    `Playmesh 项目配置要求 ${expected}，但本次 Cocos 构建平台是 ${actual}；` +
      "请在 Cocos 构建发布面板选择一致的平台后重新构建。",
  );
}

function readConfig(root) {
  const file = path.join(root, "playmesh-cli.json");
  const config = JSON.parse(fs.readFileSync(file, "utf8"));
  if (config.packageRoot !== "playmesh/package") {
    throw new Error(
      'playmesh-cli.json.packageRoot 必须精确为 "playmesh/package"',
    );
  }
  if (config.sdkRoot !== "playmesh/sdk") {
    throw new Error(
      'playmesh-cli.json.sdkRoot 必须精确为 "playmesh/sdk"',
    );
  }
  return config;
}

function resolveInside(root, relative, field) {
  if (!relative || path.isAbsolute(relative)) {
    throw new Error(`playmesh-cli.json.${field} 必须是相对路径`);
  }
  const resolved = path.resolve(root, relative);
  const relation = path.relative(root, resolved);
  if (relation === ".." || relation.startsWith(`..${path.sep}`)) {
    throw new Error(`playmesh-cli.json.${field} 不能越出项目目录`);
  }
  return resolved;
}

function stageBuild(root, config, sourceValue) {
  const source = normalizeBuildPath(root, sourceValue);
  const packageRoot = resolveInside(root, config.packageRoot, "packageRoot");
  rejectSymlinkPath(root, packageRoot, "packageRoot");
  const appRoot = path.join(packageRoot, "app");
  const outputDirectory =
    config.integration.outputDirectory || ".";
  validateOutputDirectory(outputDirectory);
  const destination = resolveInside(
    appRoot,
    outputDirectory,
    "integration.outputDirectory",
  );
  rejectSymlinkPath(root, destination, "integration.outputDirectory");
  const staging = `${destination}.playmesh-staging`;
  const backup = `${destination}.playmesh-backup`;
  rejectSymlinkPath(root, staging, "integration.outputDirectory");
  rejectSymlinkPath(root, backup, "integration.outputDirectory");
  removeTree(staging);
  copyDirectory(source, staging);
  injectSDK(path.join(staging, "index.html"));
  removeTree(backup);
  if (fs.existsSync(destination)) {
    fs.renameSync(destination, backup);
  }
  try {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    fs.renameSync(staging, destination);
    removeTree(backup);
  } catch (error) {
    removeTree(destination);
    if (fs.existsSync(backup)) {
      fs.renameSync(backup, destination);
    }
    throw error;
  }
  console.log(`[Playmesh] 已同步 Cocos 构建产物到 ${destination}`);
}

function validateOutputDirectory(value) {
  if (!value || path.isAbsolute(value) || value.includes("\\")) {
    throw new Error(
      "integration.outputDirectory 必须是 packageRoot/app 内的相对路径",
    );
  }
  if (value === ".") {
    return;
  }
  const segments = value.split("/");
  if (
    segments.some((segment) => !segment || segment === "." || segment === "..") ||
    ["playmesh", "bucket"].includes(segments[0].toLowerCase())
  ) {
    throw new Error("integration.outputDirectory 包含非法或平台保留路径段");
  }
}

function rejectSymlinkPath(root, target, field) {
  const relation = path.relative(root, target);
  const segments = relation ? relation.split(path.sep) : [];
  let current = root;
  for (const segment of ["", ...segments]) {
    if (segment) {
      current = path.join(current, segment);
    }
    let info;
    try {
      info = fs.lstatSync(current);
    } catch (error) {
      if (error && error.code === "ENOENT") {
        return;
      }
      throw error;
    }
    if (info.isSymbolicLink()) {
      throw new Error(`playmesh-cli.json.${field} 不允许经过符号链接`);
    }
  }
}

function normalizeBuildPath(root, value) {
  const withoutScheme = String(value).replace(/^project:\/\//, "");
  const resolved = path.isAbsolute(withoutScheme)
    ? path.normalize(withoutScheme)
    : path.resolve(root, withoutScheme);
  const index = path.join(resolved, "index.html");
  if (
    !fs.existsSync(resolved) ||
    !fs.statSync(resolved).isDirectory() ||
    !fs.existsSync(index)
  ) {
    throw new Error(`Cocos Web 构建目录缺少 index.html: ${resolved}`);
  }
  return resolved;
}

function copyDirectory(source, destination) {
  const info = fs.lstatSync(source);
  if (info.isSymbolicLink()) {
    throw new Error(`Cocos 构建产物不允许符号链接: ${source}`);
  }
  if (!info.isDirectory()) {
    throw new Error(`Cocos 构建输出不是目录: ${source}`);
  }
  fs.mkdirSync(destination, { recursive: true });
  for (const name of fs.readdirSync(source)) {
    const from = path.join(source, name);
    const to = path.join(destination, name);
    const entry = fs.lstatSync(from);
    if (entry.isSymbolicLink()) {
      throw new Error(`Cocos 构建产物不允许符号链接: ${from}`);
    }
    if (entry.isDirectory()) {
      copyDirectory(from, to);
    } else if (entry.isFile()) {
      fs.copyFileSync(from, to);
    }
  }
}

function injectSDK(indexPath) {
  let html = fs.readFileSync(indexPath, "utf8");
  if (html.includes("/playmesh/sdk/v1/playmesh-main.js")) {
    return;
  }
  const firstScript = html.search(/<script\b/i);
  if (firstScript >= 0) {
    html = `${html.slice(0, firstScript)}${sdkTag}\n${html.slice(firstScript)}`;
  } else {
    const head = html.search(/<\/head>/i);
    if (head >= 0) {
      html = `${html.slice(0, head)}${sdkTag}\n${html.slice(head)}`;
    } else {
      html = `${sdkTag}\n${html}`;
    }
  }
  fs.writeFileSync(indexPath, html, "utf8");
}

function removeTree(target) {
  fs.rmSync(target, { recursive: true, force: true });
}

function runCLI(root, args) {
  return new Promise((resolve, reject) => {
    const logPath = prepareCLILog(root, args);
    const child = spawn("playmesh-cli", args, {
      cwd: root,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child.stdout.on("data", (data) => {
      appendCLILog(logPath, data);
      for (const line of String(data).trimEnd().split(/\r?\n/)) {
        if (line) console.log(`[Playmesh] ${line}`);
      }
    });
    child.stderr.on("data", (data) => {
      appendCLILog(logPath, data);
      for (const line of String(data).trimEnd().split(/\r?\n/)) {
        if (line) console.error(`[Playmesh] ${line}`);
      }
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolve();
      } else {
        reject(new Error(`playmesh-cli ${args.join(" ")} 退出码 ${code}`));
      }
    });
  });
}
