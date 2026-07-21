import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const commands = [];
globalThis.window = {
  setInterval,
  clearInterval,
  setTimeout,
  clearTimeout,
  PlaymeshBridge: {
    postMessage(message) {
      const command = JSON.parse(message);
      commands.push(command);
      if (command.command === "sdk.ready") {
        window.playmesh.__receive(JSON.stringify({
          type: "sdk.bootstrap",
          requestId: command.requestId,
          sdkVersion: "1.0.0",
          isAuthority: true,
          player: null,
          session: {
            id: "s-1", joinCode: "ABC123", state: "lobby",
            authorityClientId: "p-authority", players: [], minPlayers: 2,
          },
        }));
      } else if (command.command === "performance.ping") {
        window.playmesh.__receive({
          type: "command.result", requestId: command.requestId, result: null,
        });
        window.playmesh.__receive({
          type: "transport.message",
          message: {
            type: "session.pong",
            payload: {
              ...command.payload,
              authorityAvailable: true,
              serverReceivedAt: command.payload.clientSentAt,
              serverSentAt: command.payload.clientSentAt,
            },
          },
        });
      } else if (command.command === "authority.result") {
        window.playmesh.__receive({
          type: "command.result", requestId: command.requestId, result: null,
        });
      } else if (command.command === "lifecycle.complete" || command.command === "performance.latency") {
        window.playmesh.__receive({
          type: "command.result", requestId: command.requestId, result: null,
        });
      } else if (command.command === "session.finish") {
        window.playmesh.__receive({
          type: "command.result",
          requestId: command.requestId,
          result: { ...window.playmesh.session.getCurrent(), state: "stopped" },
        });
      }
    },
  },
};

const source = fs.readFileSync(new URL("../assets/playmesh-library/public/sdk/v1/playmesh.js", import.meta.url), "utf8");
vm.runInThisContext(source, { filename: "playmesh.js" });

await new Promise((resolve) => setTimeout(resolve, 0));
const readyCommand = commands.shift();
assert.equal(readyCommand.command, "sdk.ready");
await window.playmesh.ready;
assert.equal(window.playmesh.session.isAuthority(), true);
assert.equal(window.playmesh.player.getCurrent(), null);
assert.equal(window.playmesh.session.getCurrent().joinCode, "ABC123");
assert.equal(window.playmesh.version, "1.4.2");
assert.equal((await window.playmesh.session.finish()).state, "stopped");
assert.equal(window.playmesh.performance.getLatency() >= 0, true);
assert.equal(
  window.playmesh.performance.getLatencyDiagnostics().authorityAvailable,
  true,
);
await assert.rejects(
  window.playmesh.player.setNickname("App 玩家"),
  /仅适用于浏览器玩家/,
);

let reportedFps = null;
window.playmesh.performance.onFps((fps) => { reportedFps = fps; });
for (let frame = 0; frame <= 60; frame += 1) {
  window.playmesh.performance.reportFrame(frame * (1000 / 60));
}
assert.equal(reportedFps >= 60, true);
const fpsCommand = commands.findLast((command) => command.command === "performance.fps");
assert.equal(fpsCommand.payload.fps, reportedFps);
window.playmesh.__receive({
  type: "command.result", requestId: fpsCommand.requestId, result: null,
});

let pauseCalls = 0;
window.playmesh.lifecycle.onPause(() => { pauseCalls += 1; });
window.playmesh.__receive({ type: "lifecycle.event", event: "pause" });
assert.equal(pauseCalls, 1);

const bucket = window.playmesh.storage.getBucket("fishing_save");
assert.equal(bucket.flush, undefined);
const setOperation = bucket.setData("coins", 9);
const setCommand = commands.findLast((command) => command.command === "storage.set");
assert.equal(setCommand.payload.bucket, "fishing_save");
assert.equal(setCommand.payload.value, 9);
window.playmesh.__receive({
  type: "command.result", requestId: setCommand.requestId, result: null,
});
await setOperation;
assert.throws(() => window.playmesh.storage.getBucket("../save"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("bad.bucket"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("_save"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("-save"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("存档"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket("save\n"), /无效的 bucket/);
assert.throws(() => window.playmesh.storage.getBucket(`a${"b".repeat(64)}`), /无效的 bucket/);

let received = null;
window.playmesh.game.onMessage((message) => { received = message; });
window.playmesh.__receive({
  type: "transport.message",
  message: { type: "game.message", payload: { type: "answer.result", correct: true } },
});
assert.equal(received.correct, true);

window.playmesh.authority.onService((action, context) => ({
  targetPlayerIds: [context.senderPlayerId],
  message: { type: "echo", action },
}));
window.playmesh.__receive({
  type: "transport.message",
  message: {
    type: "authority.action", senderPlayerId: "p-guest", payload: { type: "ping" },
    session: { players: [{ id: "p-host" }, { id: "p-guest" }] },
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
const authorityResult = commands.find((command) => command.command === "authority.result");
assert.deepEqual(authorityResult.targetPlayerIds, ["p-guest"]);
assert.equal(authorityResult.payload.type, "echo");

const syncController = window.playmesh.sync.startAuthority({
  initialState: { score: 0 },
  tickRate: 1,
  onInput(input, context) {
    assert.equal(context.inputType, "action");
    return { score: context.state.score + input.points };
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
assert.equal(window.playmesh.sync.getSnapshot().state.score, 0);
window.playmesh.__receive({
  type: "transport.message",
  message: {
    type: "authority.action",
    senderPlayerId: "p-guest",
    payload: {
      __playmeshSync: {
        type: "input.action", inputId: "input-1", payload: { points: 3 },
      },
    },
    session: {
      authorityClientId: "p-authority",
      players: [{ id: "p-authority" }, { id: "p-guest" }],
    },
  },
});
await new Promise((resolve) => setTimeout(resolve, 0));
await syncController.publish();
assert.equal(syncController.getState().score, 3);
assert.equal(window.playmesh.sync.getSnapshot().state.score, 3);
syncController.stop();
window.playmesh.__receive({ type: "transport.closed" });

console.log("Game SDK bridge contract passed");
