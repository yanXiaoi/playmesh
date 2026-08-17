import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../../../developer/gdevelop-app-runtime-debugger-client.js'
);
const source = await readFile(sourcePath, 'utf8');

class AbstractDebuggerClient {
  constructor(runtimeGame) {
    this.runtimeGame = runtimeGame;
    this.commands = [];
  }

  handleCommand(command) {
    this.commands.push(command);
  }
}

const warnings = [];
const context = {
  performance: { now: () => 42 },
  console: { warn: value => warnings.push(value) },
  gdjs: { AbstractDebuggerClient },
};
context.window = context;
vm.runInNewContext(source, context, {
  filename: 'gdevelop-app-runtime-debugger-client.js',
});

assert.equal(warnings.length, 0);
assert.equal(typeof context.gdjs.DebuggerClient, 'function');
assert.equal(
  Object.prototype.propertyIsEnumerable.call(
    context,
    '__PLAYMESH_GDEVELOP_DEBUGGER_RELAY__'
  ),
  false
);

const relay = context.__PLAYMESH_GDEVELOP_DEBUGGER_RELAY__;
assert.equal(relay.protocolVersion, '1.0.0');
assert.deepEqual(JSON.parse(relay.drain()), {
  protocolVersion: '1.0.0',
  ready: false,
  messages: [],
});

const client = new context.gdjs.DebuggerClient({ id: 'runtime' });
assert.equal(JSON.parse(relay.drain()).ready, true);
client._sendMessage(JSON.stringify({ command: 'status', payload: {} }));
assert.deepEqual(JSON.parse(relay.drain()).messages, [
  JSON.stringify({ command: 'status', payload: {} }),
]);

assert.equal(relay.receive({ command: 'pause' }), true);
assert.deepEqual(client.commands, [{ command: 'pause' }]);
assert.equal(relay.receive(null), false);
assert.equal(relay.receive({}), false);

client._sendMessage('x'.repeat(4 * 1024 * 1024 + 1));
const largeMessage = JSON.parse(relay.drain()).messages;
assert.equal(largeMessage.length, 1);
assert.equal(largeMessage[0].length, 4 * 1024 * 1024 + 1);

for (let index = 0; index < 750; index += 1) {
  client._sendMessage(JSON.stringify({ command: 'console.log', index }));
}
const completeQueue = JSON.parse(relay.drain()).messages;
assert.equal(completeQueue.length, 750);
assert.equal(JSON.parse(completeQueue[0]).index, 0);
assert.equal(JSON.parse(completeQueue.at(-1)).index, 749);

console.log('GDevelop App Runtime debugger client contracts passed.');
