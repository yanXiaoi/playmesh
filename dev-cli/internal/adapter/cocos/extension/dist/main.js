"use strict";

const crypto = require("crypto");
const { spawn } = require("child_process");
const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const {
  appendCLILog,
  prepareCLILog,
} = require("./cli-log");

const previewBridgeHost = "127.0.0.1";
const previewTokenLifetimeMilliseconds = 15_000;
const previewRuntimeRelativePath = path.join(
  "preview-template",
  "playmesh-preview-runtime.json",
);

let logsProcess = null;
let developmentProcess = null;
let previewBridgeServer = null;
let activePreviewBridgePort = null;
const previewTokens = new Map();

function projectRoot() {
  if (global.Editor && Editor.Project && Editor.Project.path) {
    return Editor.Project.path;
  }
  return process.cwd();
}

function report(stream, value) {
  const text = String(value).trimEnd();
  if (!text) {
    return;
  }
  for (const line of text.split(/\r?\n/)) {
    if (stream === "error") {
      console.error(`[Playmesh] ${line}`);
    } else {
      console.log(`[Playmesh] ${line}`);
    }
  }
}

function startCLI(args, wait) {
  const root = projectRoot();
  const logPath = prepareCLILog(root, args);
  const child = spawn("playmesh-cli", args, {
    cwd: root,
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: process.env,
  });
  child.stdout.on("data", (data) => {
    appendCLILog(logPath, data);
    report("log", data);
  });
  child.stderr.on("data", (data) => {
    appendCLILog(logPath, data);
    report("error", data);
  });
  child.on("error", (error) => {
    console.error(`[Playmesh] 无法启动 playmesh-cli: ${error.message}`);
  });
  if (!wait) {
    return child;
  }
  return new Promise((resolve, reject) => {
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

function requestCLIJSON(args, input = undefined) {
  return new Promise((resolve, reject) => {
    const root = projectRoot();
    const logPath = prepareCLILog(root, args);
    const child = spawn("playmesh-cli", args, {
      cwd: root,
      windowsHide: true,
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const fail = (error) => {
      if (!settled) {
        settled = true;
        reject(error);
      }
    };
    child.stdout.on("data", (data) => {
      appendCLILog(logPath, data);
      stdout += String(data);
      if (stdout.length > 1_048_576) {
        child.kill();
        fail(new Error("playmesh-cli JSON 输出过大"));
      }
    });
    child.stderr.on("data", (data) => {
      appendCLILog(logPath, data);
      stderr += String(data);
    });
    child.once("error", fail);
    child.once("exit", (code) => {
      if (settled) {
        return;
      }
      if (code !== 0) {
        fail(
          new Error(
            stderr.trim() ||
              `playmesh-cli ${args.join(" ")} 退出码 ${code}`,
          ),
        );
        return;
      }
      try {
        const value = JSON.parse(stdout);
        settled = true;
        resolve(value);
      } catch (error) {
        fail(new Error(`playmesh-cli 返回了无效 JSON: ${error.message}`));
      }
    });
    if (input === undefined) {
      child.stdin.end();
    } else {
      child.stdin.end(JSON.stringify(input));
    }
  });
}

async function loadProjectSettings() {
  const collected = await requestCLIJSON(["configure", "--out"]);
  if (
    !collected ||
    typeof collected !== "object" ||
    !collected.manifest ||
    !collected.capabilities ||
    !collected.integration ||
    !Array.isArray(collected.capabilityOptions)
  ) {
    throw new Error("playmesh-cli configure --out 返回无效配置");
  }
  return collected;
}

function saveProjectSettings(payload) {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
    throw new Error("项目设置数据无效");
  }
  return requestCLIJSON(["configure", "--json"], payload);
}

function configuredPreviewBridgePort() {
  const configPath = path.join(projectRoot(), "playmesh-cli.json");
  let config;
  try {
    config = JSON.parse(fs.readFileSync(configPath, "utf8"));
  } catch (error) {
    throw new Error(
      `无法读取 playmesh-cli.json 的预览端口配置: ${error.message}`,
    );
  }
  const value = config?.integration?.previewBridgePort;
  if (value === undefined || value === 0) {
    return 0;
  }
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(
      "integration.previewBridgePort 必须是 0 或 1-65535 的整数",
    );
  }
  return value;
}

function writePreviewBridgeRuntime(port) {
  const runtimePath = path.join(projectRoot(), previewRuntimeRelativePath);
  const temporaryPath = `${runtimePath}.${process.pid}.${crypto
    .randomBytes(8)
    .toString("hex")}.tmp`;
  fs.mkdirSync(path.dirname(runtimePath), { recursive: true });
  const content = `${JSON.stringify({ port })}\n`;
  try {
    fs.writeFileSync(temporaryPath, content, { encoding: "utf8", mode: 0o644 });
    fs.renameSync(temporaryPath, runtimePath);
  } catch (error) {
    try {
      fs.unlinkSync(temporaryPath);
    } catch (_) {
      // 临时文件可能尚未创建。
    }
    throw error;
  }
}

function localPreviewAddresses() {
  const values = new Set(["localhost", "127.0.0.1", "::1"]);
  for (const addresses of Object.values(os.networkInterfaces())) {
    for (const address of addresses || []) {
      if (address && address.address) {
        values.add(String(address.address).toLowerCase());
      }
    }
  }
  return values;
}

function normalizeLocalPreviewOrigin(value) {
  let parsed;
  try {
    parsed = new URL(String(value || "").trim());
  } catch (_) {
    return "";
  }
  if (
    !["http:", "https:"].includes(parsed.protocol) ||
    parsed.username ||
    parsed.password ||
    parsed.pathname !== "/" ||
    parsed.search ||
    parsed.hash ||
    !localPreviewAddresses().has(parsed.hostname.toLowerCase())
  ) {
    return "";
  }
  return parsed.origin;
}

function normalizePreviewPageURL(value, origin) {
  let parsed;
  try {
    parsed = new URL(String(value || "").trim());
  } catch (_) {
    return "";
  }
  if (
    !["http:", "https:"].includes(parsed.protocol) ||
    parsed.username ||
    parsed.password ||
    parsed.origin !== origin
  ) {
    return "";
  }
  return parsed.href;
}

async function readPreviewRequestJSON(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > 8 * 1024) {
      throw new Error("预览启动请求过大");
    }
    chunks.push(chunk);
  }
  if (length === 0) {
    throw new Error("预览启动请求缺少正文");
  }
  const value = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("预览启动请求必须是 JSON 对象");
  }
  return value;
}

function cleanExpiredPreviewTokens(now = Date.now()) {
  for (const [token, record] of previewTokens) {
    if (record.expiresAt <= now) {
      previewTokens.delete(token);
    }
  }
}

function writeJSON(response, statusCode, value) {
  const body = JSON.stringify(value);
  response.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
  });
  response.end(body);
}

function allowPreviewOrigin(response, origin) {
  response.setHeader("Access-Control-Allow-Origin", origin);
  response.setHeader("Vary", "Origin");
  response.setHeader("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  response.setHeader(
    "Access-Control-Allow-Headers",
    "Authorization, Content-Type",
  );
  response.setHeader("Access-Control-Max-Age", "60");
}

async function handlePreviewBridgeRequest(request, response) {
  const origin = normalizeLocalPreviewOrigin(request.headers.origin);
  if (!origin) {
    writeJSON(response, 403, {
      error: "invalid_preview_origin",
      message: "请求不是来自本机 Cocos 浏览器预览。",
    });
    return;
  }
  allowPreviewOrigin(response, origin);

  if (request.method === "OPTIONS") {
    if (
      request.headers["access-control-request-private-network"] === "true"
    ) {
      response.setHeader("Access-Control-Allow-Private-Network", "true");
    }
    response.writeHead(204, { "Cache-Control": "no-store" });
    response.end();
    return;
  }

  const requestURL = new URL(
    request.url || "/",
    `http://${previewBridgeHost}:${activePreviewBridgePort || 80}`,
  );
  if (requestURL.pathname === "/session" && request.method === "GET") {
    cleanExpiredPreviewTokens();
    const token = crypto.randomBytes(32).toString("base64url");
    const expiresAt = Date.now() + previewTokenLifetimeMilliseconds;
    previewTokens.set(token, { origin, expiresAt });
    writeJSON(response, 200, { token, expiresAt });
    return;
  }

  if (requestURL.pathname === "/launch" && request.method === "POST") {
    const authorization = String(request.headers.authorization || "");
    if (!authorization.startsWith("Bearer ")) {
      writeJSON(response, 401, {
        error: "missing_preview_token",
        message: "启动请求缺少预览 token。",
      });
      return;
    }
    const token = authorization.slice("Bearer ".length).trim();
    const record = previewTokens.get(token);
    previewTokens.delete(token);
    if (
      !record ||
      record.origin !== origin ||
      record.expiresAt <= Date.now()
    ) {
      writeJSON(response, 403, {
        error: "invalid_preview_token",
        message: "预览 token 无效、已使用或已过期。",
      });
      return;
    }
    let body;
    try {
      body = await readPreviewRequestJSON(request);
    } catch (error) {
      writeJSON(response, 400, {
        error: "invalid_preview_request",
        message: error instanceof Error ? error.message : String(error),
      });
      return;
    }
    if (
      Object.keys(body).length !== 1 ||
      !Object.hasOwn(body, "previewURL")
    ) {
      writeJSON(response, 400, {
        error: "invalid_preview_request",
        message: "预览启动请求只能包含 previewURL",
      });
      return;
    }
    const previewURL = normalizePreviewPageURL(body.previewURL, origin);
    if (!previewURL) {
      writeJSON(response, 403, {
        error: "invalid_preview_url",
        message: "预览页面 URL 与 token 来源不一致",
      });
      return;
    }
    try {
      const started = startDevelopment(previewURL);
      writeJSON(response, started ? 202 : 200, {
        status: started ? "accepted" : "already_running",
        previewServerURL: previewURL,
      });
    } catch (error) {
      writeJSON(response, 500, {
        error: "development_start_failed",
        message: error instanceof Error ? error.message : String(error),
      });
    }
    return;
  }

  writeJSON(response, 404, {
    error: "not_found",
    message: "未知的 Playmesh Cocos 预览请求。",
  });
}

exports.load = function load() {
  if (previewBridgeServer) {
    return Promise.resolve();
  }
  return new Promise((resolve, reject) => {
    let configuredPort;
    try {
      configuredPort = configuredPreviewBridgePort();
    } catch (error) {
      reject(error);
      return;
    }
    const server = http.createServer((request, response) => {
      void handlePreviewBridgeRequest(request, response).catch((error) => {
        if (response.headersSent) {
          response.destroy(error);
          return;
        }
        writeJSON(response, 500, {
          error: "preview_bridge_failed",
          message: error instanceof Error ? error.message : String(error),
        });
      });
    });
    previewBridgeServer = server;
    const startupError = (error) => {
      if (previewBridgeServer === server) {
        previewBridgeServer = null;
      }
      activePreviewBridgePort = null;
      if (configuredPort > 0 && error?.code === "EADDRINUSE") {
        const conflict = new Error(
          `integration.previewBridgePort ${configuredPort} 已被占用`,
        );
        conflict.code = error.code;
        reject(conflict);
        return;
      }
      reject(error);
    };
    server.once("error", startupError);
    server.listen(configuredPort, previewBridgeHost, () => {
      server.off("error", startupError);
      const address = server.address();
      if (!address || typeof address === "string") {
        server.close();
        previewBridgeServer = null;
        reject(new Error("无法确定 Cocos 自动预览服务端口"));
        return;
      }
      activePreviewBridgePort = address.port;
      try {
        writePreviewBridgeRuntime(activePreviewBridgePort);
      } catch (error) {
        server.close();
        previewBridgeServer = null;
        activePreviewBridgePort = null;
        reject(
          new Error(`无法写入 Cocos 自动预览运行时配置: ${error.message}`),
        );
        return;
      }
      server.on("error", (error) => {
        console.error(
          `[Playmesh] Cocos 自动预览服务错误 (${previewBridgeHost}:${activePreviewBridgePort}): ${error.message}`,
        );
      });
      console.log(
        `[Playmesh] Cocos 自动预览服务已监听 http://${previewBridgeHost}:${activePreviewBridgePort}`,
      );
      resolve();
    });
  });
};

exports.unload = function unload() {
  if (previewBridgeServer) {
    previewBridgeServer.close();
  }
  previewBridgeServer = null;
  activePreviewBridgePort = null;
  previewTokens.clear();
  if (developmentProcess && !developmentProcess.killed) {
    developmentProcess.kill();
  }
  developmentProcess = null;
  if (logsProcess && !logsProcess.killed) {
    logsProcess.kill();
  }
  logsProcess = null;
};

exports.methods = {
  openSettings() {
    if (!global.Editor || !Editor.Panel) {
      throw new Error("无法访问 Cocos Creator 面板系统");
    }
    return Editor.Panel.open("playmesh.settings");
  },

  loadSettings() {
    return loadProjectSettings();
  },

  saveSettings(payload) {
    return saveProjectSettings(payload);
  },

  logs() {
    if (logsProcess && !logsProcess.killed) {
      console.log("[Playmesh] 日志已经在输出。");
      return;
    }
    logsProcess = startCLI(["logs"], false);
    logsProcess.on("exit", () => {
      logsProcess = null;
    });
  },

  async update() {
    await startCLI(["update"], true);
  },
};

function startDevelopment(previewServerURL) {
  if (developmentProcess) {
    return false;
  }
  console.log(
    `[Playmesh] 正在启动 playmesh-cli dev，预览页：${previewServerURL}`,
  );
  const child = startCLI(["dev", previewServerURL], false);
  developmentProcess = child;
  let finished = false;
  const clearDevelopmentProcess = () => {
    if (finished) {
      return;
    }
    finished = true;
    if (developmentProcess === child) {
      developmentProcess = null;
    }
  };
  child.once("error", clearDevelopmentProcess);
  child.once("exit", clearDevelopmentProcess);
  return true;
}
