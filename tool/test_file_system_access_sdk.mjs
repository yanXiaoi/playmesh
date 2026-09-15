import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";
import { File } from "node:buffer";

const source = fs.readFileSync(
  new URL("../assets/playmesh-library/public/sdk/v1/playmesh-app.js", import.meta.url),
  "utf8",
);
const commands = [];
const writes = [];
const internalKey = Symbol.for("playmesh.app.internal.v1");

const window = {
  console,
  queueMicrotask,
  setTimeout,
  clearTimeout,
  setInterval() { return { unref() {} }; },
  clearInterval() {},
  navigator: { userActivation: { isActive: true }, language: "en-US" },
  document: {
    body: { isConnected: true, focus() {}, getAttribute() { return null; }, setAttribute() {}, removeAttribute() {} },
    documentElement: { isConnected: true },
    activeElement: null,
  },
  DOMException,
  Blob,
  File,
  TextEncoder,
  ArrayBuffer,
  Uint8Array,
  atob,
  btoa,
  __PLAYMESH_APP_OPTIONS__: { fallbackUi: false },
  showOpenFilePicker() { throw new Error("WebView implementation must be replaced"); },
  showSaveFilePicker() { throw new Error("WebView implementation must be replaced"); },
  showDirectoryPicker() { throw new Error("WebView implementation must be replaced"); },
};

function reply(command, result) {
  queueMicrotask(() => window[internalKey].receive({
    type: "app.command.result",
    requestId: command.requestId,
    result,
  }));
}

window.PlaymeshAppBridge = {
  postMessage(raw) {
    const command = JSON.parse(raw);
    commands.push(command);
    switch (command.command) {
      case "app.bootstrap":
        reply(command, {
          available: true,
          sdkVersion: "3.5.0",
          identity: { userId: "u-file", nickname: "File", source: "playmesh_app" },
          capabilityRegistry: [],
          device: { platform: "windows", capabilities: [], declaredCapabilities: [] },
        });
        break;
      case "app.input.takeover":
        reply(command, null);
        break;
      case "app.fileSystem.pickOpen":
        reply(command, [{ id: "open-file", kind: "file", name: "hello.txt" }]);
        break;
      case "app.fileSystem.pickSave":
        if (command.payload.suggestedName === "cancel.txt") {
          queueMicrotask(() => window[internalKey].receive({
            type: "app.command.error",
            requestId: command.requestId,
            code: "user_cancelled",
            error: "cancelled",
          }));
        } else {
          reply(command, { id: "save-file", kind: "file", name: "saved.txt" });
        }
        break;
      case "app.fileSystem.pickDirectory":
        reply(command, { id: "directory", kind: "directory", name: "folder" });
        break;
      case "app.fileSystem.stat":
        reply(command, { id: command.payload.id, kind: "file", name: "hello.txt", size: 5, type: "text/plain", lastModified: 1234 });
        break;
      case "app.fileSystem.read":
        reply(command, { data: btoa("hello"), eof: true });
        break;
      case "app.fileSystem.createWritable":
        reply(command, { writerId: "writer-1" });
        break;
      case "app.fileSystem.write":
        writes.push(atob(command.payload.data));
        reply(command, null);
        break;
      case "app.fileSystem.list":
        reply(command, { items: [{ id: "child", kind: "file", name: "hello.txt" }] });
        break;
      case "app.fileSystem.getChild":
        reply(command, { id: "child", kind: command.payload.kind, name: command.payload.name });
        break;
      case "app.fileSystem.same":
        reply(command, command.payload.id === command.payload.otherId);
        break;
      case "app.fileSystem.resolve":
        reply(command, ["hello.txt"]);
        break;
      default:
        reply(command, null);
    }
  },
};
window.window = window;

vm.runInNewContext(source, window, { filename: "playmesh-app.js" });
await window[internalKey].publicApi.ready;

const [opened] = await window.showOpenFilePicker({
  multiple: true,
  types: [{ description: "Text", accept: { "text/plain": [".txt"] } }],
});
assert.equal(opened.kind, "file");
assert.equal(opened.name, "hello.txt");
assert.equal((await opened.getFile()).text instanceof Function, true);
assert.equal(await (await opened.getFile()).text(), "hello");

const saved = await window.showSaveFilePicker({ suggestedName: "saved.txt" });
const writable = await saved.createWritable();
await writable.write("abc");
await writable.seek(1);
await writable.truncate(2);
await writable.close();
assert.deepEqual(writes, ["abc"]);

const directory = await window.showDirectoryPicker({ mode: "readwrite" });
const listed = [];
for await (const [name, handle] of directory.entries()) listed.push([name, handle.kind]);
assert.deepEqual(listed, [["hello.txt", "file"]]);
const child = await directory.getFileHandle("hello.txt");
assert.equal(JSON.stringify(await directory.resolve(child)), '["hello.txt"]');
assert.equal(await child.isSameEntry(child), true);

await assert.rejects(
  window.showSaveFilePicker({ suggestedName: "cancel.txt" }),
  (error) => error?.name === "AbortError",
);
assert.equal(commands.some((command) => command.command === "app.fileSystem.pickOpen"), true);
assert.equal(commands.some((command) => command.command === "app.fileSystem.pickDirectory"), true);
console.log("Playmesh File System Access SDK bridge contract passed");
