import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import vm from "node:vm";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const childProcess = require("node:child_process");
const originalSpawn = childProcess.spawn;
let cliCalls = 0;
let developmentCalls = 0;
let developmentStops = 0;
const developmentURLs = [];
const configureInputs = [];
let mockConfigureState = null;
let bridgePort = 0;
let openedPanel = "";

childProcess.spawn = (command, args, options) => {
  assert.equal(command, "playmesh-cli");
  assert.ok(options.cwd);
  cliCalls += 1;
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.stdin = {
    end(data) {
      if (args[0] !== "configure") {
        return;
      }
      queueMicrotask(() => {
        if (args[1] === "--out") {
          const value = mockConfigureState || mockCollectedConfiguration();
          child.stdout.emit("data", JSON.stringify(value));
          child.emit("exit", 0);
          return;
        }
        assert.deepEqual(args, ["configure", "--json"]);
        const value = JSON.parse(String(data || ""));
        configureInputs.push(value);
        mockConfigureState = JSON.parse(JSON.stringify(value));
        child.stdout.emit("data", JSON.stringify({ saved: true }));
        child.emit("exit", 0);
      });
    },
  };
  child.killed = false;
  child.kill = () => {
    child.killed = true;
    developmentStops += 1;
    child.emit("exit", 0);
  };
  if (args[0] === "configure") {
    assert.ok(
      (args.length === 2 && args[1] === "--out") ||
      (args.length === 2 && args[1] === "--json"),
    );
  } else if (args[0] === "dev") {
    assert.equal(args.length, 2);
    developmentURLs.push(args[1]);
    developmentCalls += 1;
    queueMicrotask(() => {
      child.stdout.emit("data", "development proxy ready\n");
    });
  } else if (args[0] === "capabilities") {
    assert.deepEqual(args, ["capabilities", "--json"]);
    queueMicrotask(() => {
      child.stdout.emit(
        "data",
        JSON.stringify({
          capabilities: [
            {
              code: "sensor.accelerometer",
              name: "加速度计",
              description: "动作输入",
              supportedPlatforms: ["WINDOWS", "ANDROID"],
            },
            {
              code: "device.vibration",
              name: "振动",
              description: "触觉反馈",
              supportedPlatforms: ["ANDROID"],
            },
          ],
        }),
      );
      child.emit("exit", 0);
    });
  } else {
    assert.deepEqual(args, ["run"]);
    queueMicrotask(() => child.emit("exit", 0));
  }
  return child;
};

function mockCollectedConfiguration() {
  const manifest = JSON.parse(
    fs.readFileSync(
      path.join(root, "playmesh", "package", "main.json"),
      "utf8",
    ),
  );
  const capabilities = JSON.parse(
    fs.readFileSync(
      path.join(root, "playmesh", "package", "capabilities.json"),
      "utf8",
    ),
  );
  const config = JSON.parse(
    fs.readFileSync(path.join(root, "playmesh-cli.json"), "utf8"),
  );
  const multiplayer = manifest.modes?.includes("multiplayer") === true;
  const singleScreen =
    manifest.displayModes?.includes("single_screen_multiplayer") === true;
  return {
    manifest: {
      id: manifest.id,
      name: manifest.name,
      version: manifest.version,
      sdkVersion: manifest.sdkVersion,
      appSdkVersion: manifest.appSdkVersion,
      remarks: manifest.remarks || "",
      tags: manifest.tags || [],
      orientation: manifest.orientation,
      mode: multiplayer ? "multiplayer" : "solo",
      displayMode: singleScreen
        ? "single_screen_multiplayer"
        : "multi_screen",
      controllerOrientation: manifest.controllerOrientation || "",
      controllerEntry: manifest.entries?.controller || "",
      authorityEntry: manifest.authority?.entry || "",
      minPlayers: manifest.players?.min || 1,
      maxPlayers: manifest.players?.max || 1,
      hasControllerEntry: Boolean(manifest.entries?.controller),
      hasAuthorityEntry: Boolean(manifest.authority?.entry),
    },
    capabilities: {
      required: capabilities.required || [],
      controllerRequired: capabilities.controllerRequired || [],
    },
    capabilityOptions: [
      {
        code: "sensor.accelerometer",
        name: "加速度计",
        description: "动作输入",
        supportedPlatforms: ["WINDOWS", "ANDROID"],
      },
      {
        code: "device.vibration",
        name: "振动",
        description: "触觉反馈",
        supportedPlatforms: ["ANDROID"],
      },
    ],
    capabilityWarning: "",
    integration: {
      platform: config.integration.platform,
      autoRunAfterBuild: config.integration.autoRunAfterBuild !== false,
      previewBridgePort: config.integration.previewBridgePort || 0,
    },
  };
}

function bridgeRequest(method, route, { origin, token, body } = {}) {
  assert.ok(bridgePort > 0, "preview bridge port must be discovered at runtime");
  return new Promise((resolve, reject) => {
    const headers = {};
    if (origin) headers.Origin = origin;
    if (token) headers.Authorization = `Bearer ${token}`;
    const encodedBody = body === undefined ? null : JSON.stringify(body);
    if (encodedBody !== null) {
      headers["Content-Type"] = "application/json";
      headers["Content-Length"] = Buffer.byteLength(encodedBody);
    }
    const request = http.request(
      {
        host: "127.0.0.1",
        port: bridgePort,
        method,
        path: route,
        headers,
      },
      (response) => {
        const chunks = [];
        response.on("data", (chunk) => chunks.push(chunk));
        response.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          resolve({
            status: response.statusCode,
            body: text ? JSON.parse(text) : null,
            headers: response.headers,
          });
        });
      },
    );
    request.on("error", reject);
    request.end(encodedBody);
  });
}

const root = fs.mkdtempSync(path.join(os.tmpdir(), "playmesh-cocos-extension-"));
try {
  global.Editor = {
    Project: { path: root },
    Panel: {
      define(definition) {
        return definition;
      },
      open(name) {
        openedPanel = name;
        return Promise.resolve();
      },
    },
  };
  const projectConfig = {
    schemaVersion: 1,
    packageRoot: "playmesh/package",
    sdkRoot: "playmesh/sdk",
    integration: {
      type: "cocos",
      projectRoot: ".",
      platform: "web-mobile",
      outputDirectory: ".",
      entry: "index.html",
      autoRunAfterBuild: true,
    },
  };
  fs.mkdirSync(path.join(root, "build", "web-mobile"), { recursive: true });
  fs.writeFileSync(
    path.join(root, "build", "web-mobile", "index.html"),
    '<!doctype html><html><head></head><body><script src="index.js"></script></body></html>',
  );
  fs.writeFileSync(
    path.join(root, "build", "web-mobile", "index.js"),
    "console.log('cocos');",
  );
  fs.mkdirSync(path.join(root, "playmesh", "package", "app"), {
    recursive: true,
  });
  fs.writeFileSync(
    path.join(root, "playmesh", "package", "main.json"),
    JSON.stringify({
      id: "com.example.cocos",
      name: "Cocos Game",
      author: "Playmesh",
      version: "1.0.0",
      sdkVersion: "4.1.0",
      appSdkVersion: "3.3.0",
      orientation: "landscape",
      modes: ["solo"],
      displayModes: ["multi_screen"],
      players: { min: 1, max: 1 },
      entries: { game: "index.html" },
      tags: ["cocos"],
    }),
  );
  fs.writeFileSync(
    path.join(root, "playmesh", "package", "capabilities.json"),
    JSON.stringify({ required: [] }),
  );
  fs.writeFileSync(
    path.join(root, "playmesh", "package", "app", "stale.js"),
    "stale",
  );
  fs.writeFileSync(
    path.join(root, "playmesh-cli.json"),
    JSON.stringify(projectConfig),
  );

  const hooks = require("./extension/dist/hooks.js");
  await hooks.onAfterBuild(
    {
      platform: "web-mobile",
      taskId: "cocos-build-001",
      version: "2.3.4",
      packages: {
        playmesh: {
          enabled: true,
          runAfterBuild: true,
        },
      },
    },
    { dest: path.join(root, "build", "web-mobile") },
  );

  const published = path.join(root, "playmesh", "package", "app");
  const html = fs.readFileSync(path.join(published, "index.html"), "utf8");
  const sdkIndex = html.indexOf("/playmesh/sdk/v1/playmesh-main.js");
  const cocosIndex = html.indexOf('src="index.js"');
  assert.ok(sdkIndex >= 0, "SDK tag must be injected");
  assert.ok(sdkIndex < cocosIndex, "SDK tag must precede the Cocos startup script");
  assert.ok(fs.existsSync(path.join(published, "index.js")));
  assert.ok(!fs.existsSync(path.join(published, "stale.js")));
  assert.equal(cliCalls, 1, "build hook must invoke playmesh-cli run once");
  assert.equal(
    JSON.parse(
      fs.readFileSync(
        path.join(root, "playmesh", "package", "main.json"),
        "utf8",
      ),
    ).version,
    "1.0.0",
    "Cocos build context must not overwrite the user-managed version",
  );

  projectConfig.integration.outputDirectory = "app";
  projectConfig.integration.entry = "app/index.html";
  fs.writeFileSync(
    path.join(root, "playmesh-cli.json"),
    JSON.stringify(projectConfig),
  );
  await hooks.onAfterBuild(
    {
      platform: "web-mobile",
      taskId: "cocos-user-app-directory",
      packages: {
        playmesh: {
          enabled: true,
          runAfterBuild: false,
        },
      },
    },
    { dest: path.join(root, "build", "web-mobile") },
  );
  assert.ok(
    fs.existsSync(path.join(published, "app", "index.html")),
    "outputDirectory=app must publish to the physical app/app directory",
  );
  projectConfig.integration.outputDirectory = ".";
  projectConfig.integration.entry = "index.html";
  fs.writeFileSync(
    path.join(root, "playmesh-cli.json"),
    JSON.stringify(projectConfig),
  );

  await hooks.onAfterBuild(
    {
      platform: "web-mobile",
      packages: { playmesh: { enabled: false } },
    },
    {},
  );
  assert.equal(cliCalls, 1, "disabled Playmesh publishing must be skipped");

  await assert.rejects(
    hooks.onAfterBuild(
      {
        platform: "web-desktop",
        packages: { playmesh: { enabled: true, runAfterBuild: false } },
      },
      { dest: path.join(root, "build", "web-mobile") },
    ),
    /项目配置要求 web-mobile.*构建平台是 web-desktop/,
    "a build for the wrong Cocos platform must not be staged",
  );
  assert.equal(cliCalls, 1);

  await hooks.onAfterBuild(
    {
      platform: "web-mobile",
      taskId: "cocos-build-003",
      packages: {
        playmesh: {
          enabled: true,
          runAfterBuild: false,
        },
      },
    },
    { dest: path.join(root, "build", "web-mobile") },
  );
  assert.equal(cliCalls, 1, "runAfterBuild=false must only stage the build");
  assert.equal(
    JSON.parse(
      fs.readFileSync(
        path.join(root, "playmesh", "package", "main.json"),
        "utf8",
      ),
    ).version,
    "1.0.0",
  );

  for (const alternative of [
    { packageRoot: "package" },
    { packageRoot: "playmesh/package/" },
    { sdkRoot: "sdk" },
    { sdkRoot: "playmesh/SDK" },
  ]) {
    fs.writeFileSync(
      path.join(root, "playmesh-cli.json"),
      JSON.stringify({ ...projectConfig, ...alternative }),
    );
    await assert.rejects(
      hooks.onAfterBuild(
        {
          platform: "web-mobile",
          taskId: "cocos-invalid-config",
          packages: {
            playmesh: {
              enabled: true,
              runAfterBuild: false,
            },
          },
        },
        { dest: path.join(root, "build", "web-mobile") },
      ),
      /必须精确为/,
    );
  }
  fs.writeFileSync(
    path.join(root, "playmesh-cli.json"),
    JSON.stringify(projectConfig),
  );

  const builder = require("./extension/dist/builder.js");
  for (const platform of ["web-mobile", "web-desktop"]) {
    const config = builder.configs[platform];
    assert.ok(config.options.enabled, `${platform} must expose Playmesh`);
    assert.ok(
      config.options.runAfterBuild,
      `${platform} must expose automatic running`,
    );
  }

  const previewGateSource = fs.readFileSync(
    new URL(
      "./preview-template/playmesh-preview-gate.js",
      import.meta.url,
    ),
    "utf8",
  );
  const previewHandoffSource = fs.readFileSync(
    new URL(
      "./preview-template/playmesh-preview-handoff.js",
      import.meta.url,
    ),
    "utf8",
  );
  assert.doesNotMatch(
    fs.readFileSync(
      new URL("./extension/dist/main.js", import.meta.url),
      "utf8",
    ),
    /setInterval|startPreviewRuntimeRepair/,
    "the extension must write the runtime port once during initialization",
  );
  assert.match(
    previewHandoffSource,
    /扩展运行时配置不存在；请重新初始化或重新加载/,
  );
  let appGateFetches = 0;
  let appReloads = 0;
  let restartControlRequests = 0;
  const appGateContext = {
    URL,
    console,
    location: {
      href: "http://127.0.0.1:7456/",
      origin: "http://127.0.0.1:7456",
      reload() {
        appReloads += 1;
      },
    },
    PlaymeshAppBridge: { postMessage() {} },
    stop() {
      assert.fail("App-hosted preview must not stop document loading");
    },
    document: {
      querySelectorAll() {
        return [
          {
            src: "http://127.0.0.1:7456/scripting/engine/bin/.cache/dev/preview/import-map.json",
          },
          {
            src: "http://127.0.0.1:7456/scripting/engine/bin/.cache/dev/preview/bundled/index.js",
          },
          {
            src: "http://127.0.0.1:7456/settings.js?scene=current_scene",
          },
        ];
      },
      open() {
        assert.fail("App-hosted preview must not pause document loading");
      },
    },
    async fetch(url, options) {
      appGateFetches += 1;
      if (url === "/.playmesh-development/restart") {
        assert.equal(options.method, "POST");
        restartControlRequests += 1;
        return { ok: true, status: 202 };
      }
      return {
        ok: true,
        async text() {
          return url.includes("/settings.js")
            ? "window._CCSettings={};"
            : "{}";
        },
        async arrayBuffer() {
          assert.equal(options.method, "GET");
          return new Uint8Array([1, 2, 3]).buffer;
        },
      };
    },
    setTimeout(callback) {
      callback();
    },
  };
  vm.runInNewContext(previewGateSource, appGateContext);
  assert.equal(appGateFetches, 0);
  assert.equal(typeof appGateContext.__playmeshCocosReload, "function");
  appGateContext.__playmeshCocosReload("disconnect");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(appGateFetches, 0);
  assert.equal(appReloads, 0);
  appGateContext.__playmeshCocosReload("reload");
  await new Promise((resolve) => setImmediate(resolve));
  await new Promise((resolve) => setImmediate(resolve));
  assert.ok(appGateFetches >= 7);
  assert.equal(restartControlRequests, 1);
  assert.equal(appReloads, 0);
  assert.match(
    previewGateSource,
    /__playmeshHostConsoleCaptureInstalled === true/,
  );

  const previewStatus = { textContent: "" };
  const gateRequests = [];
  const gatePreviewPageURL =
    "http://127.0.0.1:7456/web-mobile/task-42/index.html?scene=main";
  const previewSessionStorage = new Map();
  let replacedPreviewURL = "";
  vm.runInNewContext(previewGateSource, {
    console,
    location: {
      href: gatePreviewPageURL,
      replace(value) {
        replacedPreviewURL = value;
      },
    },
    sessionStorage: {
      setItem(key, value) {
        previewSessionStorage.set(key, value);
      },
    },
  });
  assert.equal(
    previewSessionStorage.get("playmesh.preview.url"),
    gatePreviewPageURL,
  );
  assert.equal(replacedPreviewURL, "/playmesh-preview-handoff.html");

  vm.runInNewContext(previewHandoffSource, {
    URL,
    console,
    location: {
      href: "http://127.0.0.1:7456/playmesh-preview-handoff.html",
      origin: "http://127.0.0.1:7456",
    },
    sessionStorage: {
      getItem(key) {
        return previewSessionStorage.get(key) || null;
      },
      setItem(key, value) {
        previewSessionStorage.set(key, value);
      },
    },
    document: {
      getElementById(id) {
        return id === "playmesh-preview-status" ? previewStatus : null;
      },
    },
    async fetch(url, options) {
      gateRequests.push({ url, options });
      if (url.includes("/playmesh-preview-runtime.json?")) {
        return {
          ok: true,
          async json() {
            return { port: 43123 };
          },
        };
      }
      if (url.endsWith("/session")) {
        return {
          ok: true,
          async json() {
            return { token: "generated-session-token" };
          },
        };
      }
      return { ok: true };
    },
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(gateRequests.length, 3);
  assert.match(
    gateRequests[0].url,
    /^http:\/\/127\.0\.0\.1:7456\/playmesh-preview-runtime\.json\?/,
  );
  assert.equal(gateRequests[0].options.cache, "no-store");
  assert.equal(gateRequests[1].url, "http://127.0.0.1:43123/session");
  assert.equal(gateRequests[2].url, "http://127.0.0.1:43123/launch");
  assert.equal(
    gateRequests[2].options.headers.Authorization,
    "Bearer generated-session-token",
  );
  assert.equal(
    gateRequests[2].options.headers["Content-Type"],
    "application/json",
  );
  assert.deepEqual(
    JSON.parse(gateRequests[2].options.body),
    { previewURL: gatePreviewPageURL },
  );
  assert.match(previewStatus.textContent, /启动请求已提交/);
  assert.equal(
    previewSessionStorage.get("playmesh.preview.launched"),
    "true",
  );
  const requestsAfterInitialLaunch = gateRequests.length;
  vm.runInNewContext(previewHandoffSource, {
    URL,
    console,
    location: {
      href: "http://127.0.0.1:7456/playmesh-preview-handoff.html",
      origin: "http://127.0.0.1:7456",
    },
    sessionStorage: {
      getItem(key) {
        return previewSessionStorage.get(key) || null;
      },
      setItem(key, value) {
        previewSessionStorage.set(key, value);
      },
    },
    document: {
      getElementById(id) {
        return id === "playmesh-preview-status" ? previewStatus : null;
      },
    },
    async fetch(url, options) {
      gateRequests.push({ url, options });
      throw new Error("a refreshed handoff page must not call the extension");
    },
  });
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(gateRequests.length, requestsAfterInitialLaunch);
  assert.match(previewStatus.textContent, /只更新 Cocos 预览资源/);

  const extensionMain = require("./extension/dist/main.js");
  await extensionMain.load();
  const previewRuntimePath = path.join(
    root,
    "preview-template",
    "playmesh-preview-runtime.json",
  );
  const previewRuntime = JSON.parse(
    fs.readFileSync(previewRuntimePath, "utf8"),
  );
  bridgePort = previewRuntime.port;
  assert.ok(
    Number.isInteger(bridgePort) && bridgePort > 0 && bridgePort <= 65535,
    "the operating system must allocate an available preview bridge port",
  );

  await extensionMain.methods.openSettings();
  assert.equal(openedPanel, "playmesh.settings");
  const settings = await extensionMain.methods.loadSettings();
  assert.equal(settings.manifest.name, "Cocos Game");
  assert.equal(settings.integration.previewBridgePort, 0);
  assert.deepEqual(
    settings.capabilityOptions.map((item) => item.code).sort(),
    ["device.vibration", "sensor.accelerometer"],
  );
  settings.manifest.name = "Configured Cocos Game";
  settings.manifest.version = "2.5.0";
  settings.manifest.remarks = "Saved from the extension panel";
  settings.manifest.tags = ["cocos", "configured"];
  settings.capabilities.required = ["sensor.accelerometer"];
  settings.integration.platform = "web-desktop";
  settings.integration.autoRunAfterBuild = false;
  settings.integration.previewBridgePort = 0;
  await extensionMain.methods.saveSettings(settings);
  assert.equal(configureInputs.length, 1);
  const savedSettings = configureInputs[0];
  assert.equal(savedSettings.manifest.id, "com.example.cocos");
  assert.equal(savedSettings.manifest.name, "Configured Cocos Game");
  assert.equal(
    savedSettings.manifest.version,
    "2.5.0",
    "the panel must pass the user-managed version to CLI configure",
  );
  assert.deepEqual(savedSettings.manifest.tags, ["cocos", "configured"]);
  assert.deepEqual(savedSettings.capabilities, {
    required: ["sensor.accelerometer"],
    controllerRequired: [],
  });
  assert.equal(savedSettings.integration.platform, "web-desktop");
  assert.equal(savedSettings.integration.autoRunAfterBuild, false);
  assert.equal(savedSettings.integration.previewBridgePort, 0);

  const singleScreenSettings = await extensionMain.methods.loadSettings();
  singleScreenSettings.manifest.mode = "multiplayer";
  singleScreenSettings.manifest.displayMode =
    "single_screen_multiplayer";
  singleScreenSettings.manifest.minPlayers = 2;
  singleScreenSettings.manifest.maxPlayers = 4;
  singleScreenSettings.manifest.controllerOrientation = "landscape";
  singleScreenSettings.manifest.controllerEntry = "controls/pad.html";
  singleScreenSettings.manifest.authorityEntry =
    "static/js/service/index.js";
  singleScreenSettings.capabilities.controllerRequired = [
    "device.vibration",
  ];
  await extensionMain.methods.saveSettings(singleScreenSettings);
  assert.equal(
    configureInputs.at(-1).manifest.controllerEntry,
    "controls/pad.html",
    "the panel must pass the user-entered controller path to CLI configure",
  );
  assert.equal(
    configureInputs.at(-1).manifest.controllerOrientation,
    "landscape",
  );

  const multiScreenSettings = await extensionMain.methods.loadSettings();
  multiScreenSettings.manifest.displayMode = "multi_screen";
  await extensionMain.methods.saveSettings(multiScreenSettings);
  assert.equal(
    configureInputs.at(-1).manifest.displayMode,
    "multi_screen",
    "the panel must send every mode change through CLI configure",
  );
  const previewOrigin = "http://127.0.0.1:7456";
  const previewPageURL =
    `${previewOrigin}/web-mobile/task-42/index.html?scene=main`;
  const missingOrigin = await bridgeRequest("GET", "/session");
  assert.equal(missingOrigin.status, 403);

  const missingToken = await bridgeRequest("POST", "/launch", {
    origin: previewOrigin,
  });
  assert.equal(missingToken.status, 401);
  assert.equal(missingToken.body.error, "missing_preview_token");
  assert.equal(developmentCalls, 0);

  const invalidSession = await bridgeRequest("GET", "/session", {
    origin: previewOrigin,
  });
  const foreignPreview = await bridgeRequest("POST", "/launch", {
    origin: previewOrigin,
    token: invalidSession.body.token,
    body: {
      previewURL:
        "http://127.0.0.1:7457/web-mobile/task-42/index.html",
    },
  });
  assert.equal(foreignPreview.status, 403);
  assert.equal(foreignPreview.body.error, "invalid_preview_url");
  assert.equal(developmentCalls, 0);

  const session = await bridgeRequest("GET", "/session", {
    origin: previewOrigin,
  });
  assert.equal(session.status, 200);
  assert.ok(session.body.token);
  assert.equal(
    session.headers["access-control-allow-origin"],
    previewOrigin,
  );

  const launch = await bridgeRequest("POST", "/launch", {
    origin: previewOrigin,
    token: session.body.token,
    body: { previewURL: previewPageURL },
  });
  assert.equal(launch.status, 202);
  assert.equal(developmentCalls, 1, "dev must start one long-lived CLI process");
  assert.deepEqual(
    developmentURLs,
    [previewPageURL],
    "the complete Cocos preview page URL must be passed as a CLI argument",
  );
  await new Promise((resolve) => setImmediate(resolve));
  const cliLogDirectory = path.join(root, "temp", "logs");
  assert.deepEqual(
    fs.readdirSync(cliLogDirectory).filter((name) => name.endsWith(".log")),
    ["playmesh-cli.log"],
    "all extension CLI commands must share one fixed log file",
  );
  const cliLog = fs.readFileSync(
    path.join(cliLogDirectory, "playmesh-cli.log"),
    "utf8",
  );
  assert.match(cliLog, /^\[Playmesh CLI\] command=dev\n/);
  assert.match(cliLog, /development proxy ready/);
  assert.doesNotMatch(
    cliLog,
    /sensor\.accelerometer/,
    "starting dev must truncate the previous command log",
  );

  const refreshSession = await bridgeRequest("GET", "/session", {
    origin: previewOrigin,
  });
  const refreshedPreviewPageURL =
    `${previewOrigin}/web-mobile/task-43/index.html?scene=main`;
  const refreshedLaunch = await bridgeRequest("POST", "/launch", {
    origin: previewOrigin,
    token: refreshSession.body.token,
    body: { previewURL: refreshedPreviewPageURL },
  });
  assert.equal(refreshedLaunch.status, 200);
  assert.equal(
    developmentStops,
    0,
    "a refreshed preview must not stop the active CLI dev process",
  );
  assert.equal(
    developmentCalls,
    1,
    "a refreshed preview must not start another CLI dev process",
  );
  assert.deepEqual(developmentURLs, [previewPageURL]);

  const replay = await bridgeRequest("POST", "/launch", {
    origin: previewOrigin,
    token: session.body.token,
    body: { previewURL: previewPageURL },
  });
  assert.equal(replay.status, 403, "preview token must be single-use");
  extensionMain.unload();
  assert.equal(developmentStops, 1, "extension unload must stop CLI dev");

  const customPortProbe = http.createServer();
  await new Promise((resolve, reject) => {
    customPortProbe.once("error", reject);
    customPortProbe.listen(0, "127.0.0.1", resolve);
  });
  const customPort = customPortProbe.address().port;
  await new Promise((resolve, reject) => {
    customPortProbe.close((error) => (error ? reject(error) : resolve()));
  });
  projectConfig.integration.previewBridgePort = customPort;
  fs.writeFileSync(
    path.join(root, "playmesh-cli.json"),
    JSON.stringify(projectConfig),
  );
  await extensionMain.load();
  const customRuntime = JSON.parse(
    fs.readFileSync(previewRuntimePath, "utf8"),
  );
  assert.equal(
    customRuntime.port,
    customPort,
    "configured preview bridge port must be used exactly",
  );
  extensionMain.unload();

  const occupiedPortServer = http.createServer();
  await new Promise((resolve, reject) => {
    occupiedPortServer.once("error", reject);
    occupiedPortServer.listen(0, "127.0.0.1", resolve);
  });
  projectConfig.integration.previewBridgePort =
    occupiedPortServer.address().port;
  fs.writeFileSync(
    path.join(root, "playmesh-cli.json"),
    JSON.stringify(projectConfig),
  );
  await assert.rejects(
    extensionMain.load(),
    (error) => error && error.code === "EADDRINUSE",
    "an occupied custom port must fail explicitly",
  );
  await new Promise((resolve, reject) => {
    occupiedPortServer.close((error) => (error ? reject(error) : resolve()));
  });

  const extensionPackage = JSON.parse(
    fs.readFileSync(
      new URL("./extension/package.json", import.meta.url),
      "utf8",
    ),
  );
  assert.equal(extensionPackage.package_version, 2);
  assert.equal(extensionPackage.author, "Playmesh");
  assert.equal(extensionPackage.editor, ">=3.0.0 <4.0.0");
  assert.equal(
    extensionPackage.contributions.messages.dev,
    undefined,
    "automatic development must not expose an unauthenticated editor message",
  );
  assert.deepEqual(
    extensionPackage.contributions.messages["open-settings"].methods,
    ["openSettings"],
  );
  assert.equal(
    extensionPackage.contributions.messages.build,
    undefined,
    "extension must not duplicate the Cocos build panel",
  );
  assert.equal(
    extensionPackage.contributions.messages.run,
    undefined,
    "extension must not expose a recent-build run shortcut",
  );
  const playmeshMenuLabels = extensionPackage.contributions.menu.map(
    (item) => item.label,
  );
  assert.ok(!playmeshMenuLabels.includes("打开 Web 构建发布"));
  assert.ok(!playmeshMenuLabels.includes("上传并运行最近构建"));
  assert.equal(extensionMain.methods.build, undefined);
  assert.equal(extensionMain.methods.run, undefined);
  assert.equal(
    extensionPackage.panels.settings.main,
    "./dist/panels/settings",
  );
  assert.ok(
    fs.existsSync(
      new URL("./extension/static/playmesh.svg", import.meta.url),
    ),
  );
  const settingsPanel = require(
    "./extension/dist/panels/settings/index.js",
  );
  assert.match(settingsPanel.template, /游戏名称/);
  assert.match(settingsPanel.template, /平台能力/);
  assert.match(settingsPanel.template, /预览桥端口/);
  assert.doesNotMatch(settingsPanel.template, /data-field="author"/);
  assert.match(settingsPanel.template, /data-field="version"/);
  const settingsPanelMethods = Object.values(settingsPanel.methods)
    .map((method) => method.toString())
    .join("\n");
  assert.doesNotMatch(
    settingsPanelMethods,
    /shadowRoot/,
    "Cocos panel methods must use registered panel nodes instead of shadowRoot",
  );
  const settingsPanelSource = fs.readFileSync(
    new URL("./extension/dist/panels/settings/index.js", import.meta.url),
    "utf8",
  );
  assert.match(
    settingsPanelSource,
    /const defaultControllerEntry = "controller\/index\.html"/,
  );
  assert.match(
    settingsPanelSource,
    /const defaultAuthorityEntry = "static\/js\/service\/index\.js"/,
  );
  assert.match(
    settingsPanel.methods.field.toString(),
    /this\.\$\.form\.querySelector/,
  );
  console.log("Cocos extension contract passed.");
} finally {
  childProcess.spawn = originalSpawn;
  delete global.Editor;
  fs.rmSync(root, { recursive: true, force: true });
}
