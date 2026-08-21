import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
);
const runnerPath = path.join(
  repositoryRoot,
  "tool",
  "test_gdevelop_multiplayer_e2e.mjs",
);
const controlRoot = fs.mkdtempSync(
  path.join(os.tmpdir(), "playmesh-gdevelop-e2e-cleanup-test-"),
);
const tracePath = path.join(controlRoot, "cleanup-trace.json");

function runInjectedFailure() {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [runnerPath], {
      cwd: repositoryRoot,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        PLAYMESH_GDEVELOP_E2E_INJECT_FAILURE_STAGE: "after-core-start",
        PLAYMESH_GDEVELOP_E2E_CLEANUP_TRACE_PATH: tracePath,
      },
    });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk;
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      resolve({ code, signal, stdout, stderr });
    });
  });
}

function isProcessAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error?.code === "ESRCH") return false;
    throw error;
  }
}

function assertPortCanBeRebound(baseUrl) {
  const url = new URL(baseUrl);
  const port = Number(url.port);
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen({ host: url.hostname, port, exclusive: true }, () => {
      server.close((error) => error ? reject(error) : resolve());
    });
  });
}

try {
  const result = await runInjectedFailure();
  assert.notEqual(result.code, 0, "注入失败的 E2E 子进程必须以失败状态退出");
  assert.match(
    result.stderr,
    /注入失败：go-core 启动后验证清理路径/,
    `子进程未报告预期注入失败：\n${result.stdout}\n${result.stderr}`,
  );
  const trace = JSON.parse(fs.readFileSync(tracePath, "utf8"));
  assert.equal(trace.cleanupComplete, true);
  assert.equal(trace.temporaryRootExistsAfterCleanup, false);
  assert.equal(fs.existsSync(trace.temporaryRoot), false);
  assert.equal(isProcessAlive(trace.corePid), false, "go-core 子进程仍然存活");
  await assertPortCanBeRebound(trace.baseUrl);
  console.log(
    "GDevelop real multiplayer E2E injected-failure cleanup test passed " +
      "(go-core process exited, dynamic port released, temp directory removed).",
  );
} finally {
  fs.rmSync(controlRoot, { recursive: true, force: true });
}
