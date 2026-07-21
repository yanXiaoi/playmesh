import assert from "node:assert/strict";
import fs from "node:fs";

const serviceFile = new URL(
  "../assets/playmesh-library/public/developer/templates/default-game/package/app/static/js/service/index.js",
  import.meta.url,
);
const playerFile = new URL(
  "../assets/playmesh-library/public/developer/templates/default-game/package/app/static/js/player/index.js",
  import.meta.url,
);
const source = fs.readFileSync(serviceFile, "utf8");
const playerSource = fs.readFileSync(playerFile, "utf8");

assert.equal(/WebSocket|fetch\s*\(|document\./.test(source), false);
assert.match(playerSource, /playmesh\.session\.isAuthority\(\)/);
assert.match(playerSource, /playmesh\.sync\.observe/);

let authorityOptions = null;
const authorityController = { stop() {} };
globalThis.playmesh = {
  sync: {
    startAuthority(options) {
      authorityOptions = options;
      return authorityController;
    },
  },
};

const executableSource = source.replace(
  /import\s+\{\s*InputTypes\s*\}\s+from\s+["'][^"']+["'];?/,
  'const InputTypes = Object.freeze({ primary: "game.primary" });',
);
const moduleUrl = `data:text/javascript;base64,${Buffer.from(executableSource).toString("base64")}`;
const { startAuthoritySync } = await import(moduleUrl);

assert.equal(startAuthoritySync(), authorityController);
assert.equal(authorityOptions.tickRate, 10);
assert.deepEqual(authorityOptions.initialState, {
  actionCount: 0,
  lastPlayerId: null,
});

const state = authorityOptions.initialState;
assert.equal(
  authorityOptions.onInput(
    { type: "game.ignored" },
    { state, senderPlayerId: "player-1" },
  ),
  state,
);
assert.deepEqual(
  authorityOptions.onInput(
    { type: "game.primary" },
    { state, senderPlayerId: "player-1" },
  ),
  { actionCount: 1, lastPlayerId: "player-1" },
);

delete globalThis.playmesh;
console.log("Default Authority sync template contract passed");
