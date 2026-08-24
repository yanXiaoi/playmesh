import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptsDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryDirectory = resolve(scriptsDirectory, '..', '..', '..', '..', '..', '..');
const sdkDeclarationPath = resolve(repositoryDirectory, 'assets', 'playmesh-library', 'public', 'sdk', 'v1', 'playmesh-main.d.ts');
const sdkDeclarationSource = readFileSync(sdkDeclarationPath, 'utf8');
const extensionIconPath = resolve(
  repositoryDirectory,
  'assets',
  'playmesh-library',
  'public',
  'developer',
  'playmesh-logo.png'
);
const extensionIconBytes = readFileSync(extensionIconPath);
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
if (
  extensionIconBytes.length < 33 ||
  !extensionIconBytes.subarray(0, pngSignature.length).equals(pngSignature) ||
  extensionIconBytes.readUInt32BE(8) !== 13 ||
  extensionIconBytes.subarray(12, 16).toString('ascii') !== 'IHDR' ||
  extensionIconBytes.readUInt32BE(16) !== 256 ||
  extensionIconBytes.readUInt32BE(20) !== 256 ||
  extensionIconBytes[24] !== 8 ||
  extensionIconBytes[25] !== 6
) {
  throw new Error(
    `Playmesh extension icon must be the 256x256 8-bit RGBA PNG brand derivative: ${extensionIconPath}`
  );
}

const executeCommands = [
  'playmesh.main.gameInfo.getCurrent',
  'playmesh.main.session.isAuthority',
  'playmesh.main.session.getCurrent',
  'playmesh.main.session.start',
  'playmesh.main.session.finish',
  'playmesh.main.player.getCurrent',
  'playmesh.main.player.setNickname',
  'playmesh.main.game.submitAction',
  'playmesh.main.rpc.request',
  'playmesh.main.binary.createChannel',
  'playmesh.main.binary.joinChannel',
  'playmesh.main.sync.startAuthority',
  'playmesh.main.sync.submitAction',
  'playmesh.main.sync.submitState',
  'playmesh.main.sync.requestSnapshot',
  'playmesh.main.sync.getSnapshot',
  'playmesh.main.storage.getBucket',
  'PlaymeshBinaryChannel.send',
  'PlaymeshBinaryChannel.sendLatest',
  'PlaymeshBinaryChannel.close',
  'PlaymeshSyncAuthorityController.getState',
  'PlaymeshSyncAuthorityController.setState',
  'PlaymeshSyncAuthorityController.publish',
  'PlaymeshSyncAuthorityController.stop',
  'PlaymeshStorageBucket.getData',
  'PlaymeshStorageBucket.setData',
  'PlaymeshStorageBucket.getDataSync',
  'PlaymeshStorageBucket.setDataSync',
  'PlaymeshStorageBucket.removeData',
  'PlaymeshStorageBucket.clearData',
  'PlaymeshStorageBucket.upload',
  'playmesh.app.isAvailable',
  'playmesh.app.identity.getCurrent',
  'playmesh.app.runtime.getLocale',
  'playmesh.app.storage.getBucket',
  'PlaymeshAppStorageBucket.getData',
  'PlaymeshAppStorageBucket.setData',
  'PlaymeshAppStorageBucket.getDataSync',
  'PlaymeshAppStorageBucket.setDataSync',
  'PlaymeshAppStorageBucket.removeData',
  'PlaymeshAppStorageBucket.clearData',
  'playmesh.app.performance.getFps',
  'playmesh.app.performance.getLatency',
  'playmesh.app.performance.getLatencyDiagnostics',
  'playmesh.app.performance.setVisible',
  'playmesh.app.performance.reportFrame',
  'playmesh.app.capabilities.getRegistry',
  'playmesh.app.capabilities.getAvailable',
  'playmesh.app.capabilities.getDeclared',
  'playmesh.app.capabilities.create',
  'playmesh.app.media.open',
  'playmesh.app.device.getPlatform',
  'playmesh.app.device.setFullscreen',
  'playmesh.app.ui.disableSystemMenuTriggers',
  'playmesh.app.ui.initializeBrowser',
  'playmesh.app.ui.configure',
  'playmesh.app.ui.showGameSidebar',
  'playmesh.app.ui.restartGame',
  'playmesh.app.ui.openSharePanel',
  'playmesh.app.ui.openRuntimeLogs',
  'playmesh.app.ui.enterFullscreen',
  'playmesh.app.ui.exitFullscreen',
  'playmesh.app.ui.openGameInfo',
  'playmesh.app.ui.setPerformanceVisible',
  'playmesh.app.ui.togglePerformance',
  'playmesh.app.ui.exitGame',
  'playmesh.app.lan.discoverGames',
  'playmesh.app.lan.joinByLink',
  'playmesh.app.lan.scanQrAndJoin',
  'playmesh.app.lan.setPublished',
  'playmesh.app.lan.getShareLinks',
  'PlaymeshCapabilityHandle.invoke',
  'PlaymeshCapabilityHandle.removeEventListener',
  'PlaymeshCapabilityHandle.dispose',
  'PlaymeshAppMediaSession.close',
  'PlaymeshLanGame.join',
];

const subscribeCommands = [
  'playmesh.main.session.onStateChange',
  'playmesh.main.session.onPlayerJoin',
  'playmesh.main.session.onPlayerLeave',
  'playmesh.main.session.onPlayerReconnect',
  'playmesh.main.game.onMessage',
  'playmesh.main.game.onEvent',
  'playmesh.main.sync.observe',
  'playmesh.main.lifecycle.onChange',
  'playmesh.main.lifecycle.onPause',
  'playmesh.main.lifecycle.onResume',
  'playmesh.main.lifecycle.onExit',
  'PlaymeshBinaryChannel.onMessage',
  'playmesh.app.performance.onFps',
  'playmesh.app.performance.onLatency',
  'playmesh.app.device.onInput',
  'playmesh.app.ui.onGameMenuOpen',
  'playmesh.app.ui.onGameMenuClose',
  'PlaymeshCapabilityHandle.on',
  'PlaymeshCapabilityHandle.addEventListener',
  'PlaymeshCapabilityHandle.onError',
];

const handlerCommands = [
  'playmesh.main.authority.onService',
  'playmesh.main.rpc.onRequest',
  'PlaymeshBinaryChannel.onForward',
];

const propertyCommands = [
  'playmesh.main.version',
  'playmesh.app.version',
  'playmesh.main.authority.defaultNamespace',
  'playmesh.main.binary.authorityPlayerId',
  'PlaymeshBinaryChannel.id',
  'PlaymeshBinaryChannel.mode',
  'PlaymeshCapabilityHandle.id',
  'PlaymeshCapabilityHandle.code',
  'PlaymeshCapabilityHandle.apiVersion',
  'PlaymeshAppMediaSession.id',
  'PlaymeshAppMediaSession.source',
  'PlaymeshAppMediaSession.state',
  'PlaymeshAppMediaSession.stream',
  'PlaymeshLanGame.instanceId',
  'PlaymeshLanGame.gameId',
  'PlaymeshLanGame.name',
  'PlaymeshLanGame.host',
];

const callableCommands = [...executeCommands, ...subscribeCommands, ...handlerCommands];

// The checked-in declaration is the public SDK contract. Keep the wrapper
// catalogue fail-closed: a renamed/removed SDK member must make generation
// fail instead of silently leaving a stale editor action behind.
const sdkCompletionTags = new Set(
  [...sdkDeclarationSource.matchAll(/@playmesh-completion\s+([^\s*]+)/gu)].map(match => match[1])
);

const interfaceBody = interfaceName => {
  const marker = new RegExp(`\\binterface\\s+${interfaceName}(?:\\s*<[^>{}]*>)?\\s*\\{`, 'u');
  const match = marker.exec(sdkDeclarationSource);
  if (!match) throw new Error(`Missing SDK declaration interface: ${interfaceName}`);
  const openIndex = sdkDeclarationSource.indexOf('{', match.index);
  let depth = 0;
  for (let index = openIndex; index < sdkDeclarationSource.length; index += 1) {
    if (sdkDeclarationSource[index] === '{') depth += 1;
    else if (sdkDeclarationSource[index] === '}') {
      depth -= 1;
      if (depth === 0) return sdkDeclarationSource.slice(openIndex + 1, index);
    }
  }
  throw new Error(`Unterminated SDK declaration interface: ${interfaceName}`);
};

const returnedInterfaceBodies = new Map([
  ['PlaymeshBinaryChannel', interfaceBody('PlaymeshBinaryChannel')],
  ['PlaymeshSyncAuthorityController', interfaceBody('PlaymeshSyncAuthorityController')],
  ['PlaymeshStorageBucket', interfaceBody('PlaymeshStorageBucket')],
  ['PlaymeshAppStorageBucket', interfaceBody('PlaymeshAppStorageBucket')],
  ['PlaymeshCapabilityHandle', interfaceBody('PlaymeshCapabilityHandle')],
  ['PlaymeshAppMediaSession', interfaceBody('PlaymeshAppMediaSession')],
  ['PlaymeshLanGame', interfaceBody('PlaymeshLanGame')],
]);

for (const command of callableCommands) {
  if (command.startsWith('playmesh.')) {
    if (!sdkCompletionTags.has(command)) {
      throw new Error(`SDK declaration has no completion contract for: ${command}`);
    }
    continue;
  }
  const separator = command.lastIndexOf('.');
  const interfaceName = command.slice(0, separator);
  const methodName = command.slice(separator + 1);
  const body = returnedInterfaceBodies.get(interfaceName);
  if (!body || !new RegExp(`\\b${methodName}\\s*(?:<[^;>{}]*>)?\\s*\\(`, 'u').test(body)) {
    throw new Error(`SDK declaration has no returned-handle member for: ${command}`);
  }
}

const splitTopLevel = (source, delimiter = ',') => {
  const values = [];
  let start = 0;
  let quote = '';
  let escaped = false;
  const stack = [];
  const opening = new Map([['(', ')'], ['[', ']'], ['{', '}'], ['<', '>']]);
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (opening.has(character)) {
      stack.push(opening.get(character));
      continue;
    }
    if (stack.length && character === stack[stack.length - 1]) {
      stack.pop();
      continue;
    }
    if (character === delimiter && stack.length === 0) {
      values.push(source.slice(start, index).trim());
      start = index + 1;
    }
  }
  values.push(source.slice(start).trim());
  return values.filter(Boolean);
};

const splitDartMapEntry = source => {
  let quote = '';
  let escaped = false;
  const stack = [];
  const opening = new Map([['(', ')'], ['[', ']'], ['{', '}'], ['<', '>']]);
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === "'" || character === '"') {
      quote = character;
      continue;
    }
    if (opening.has(character)) stack.push(opening.get(character));
    else if (stack.length && character === stack[stack.length - 1]) stack.pop();
    else if (character === ':' && stack.length === 0) return [source.slice(0, index).trim(), source.slice(index + 1).trim()];
  }
  throw new Error(`Invalid Dart map/named entry: ${source}`);
};

const decodeDartString = source => {
  const quote = source[0];
  const body = source.slice(1, -1);
  return body.replace(/\\([\\'"nrtbf])/gu, (_match, escaped) => ({
    '\\': '\\',
    "'": "'",
    '"': '"',
    n: '\n',
    r: '\r',
    t: '\t',
    b: '\b',
    f: '\f',
  })[escaped] ?? escaped).replace(new RegExp(`\\\\${quote}`, 'gu'), quote);
};

const parseDartConstValue = (sourceInput, constants = new Map()) => {
  let source = sourceInput.trim();
  while (source.startsWith('const ')) source = source.slice(6).trim();
  if (/^<[^>]+>\s*[\[{]/u.test(source)) source = source.replace(/^<[^>]+>\s*/u, '');
  if ((source.startsWith("'") && source.endsWith("'")) || (source.startsWith('"') && source.endsWith('"'))) return decodeDartString(source);
  if (source === 'true') return true;
  if (source === 'false') return false;
  if (source === 'null') return null;
  if (/^-?(?:\d+\.?\d*|\.\d+)$/u.test(source)) return Number(source);
  if (constants.has(source)) return constants.get(source);
  if (/^CapabilityPlatform\.[A-Z_]+$/u.test(source)) return source.slice(source.lastIndexOf('.') + 1);
  if (source.startsWith('[') && source.endsWith(']')) {
    return splitTopLevel(source.slice(1, -1)).map(value => parseDartConstValue(value, constants));
  }
  if (source.startsWith('{') && source.endsWith('}')) {
    const value = {};
    for (const entry of splitTopLevel(source.slice(1, -1))) {
      const [keySource, valueSource] = splitDartMapEntry(entry);
      const key = parseDartConstValue(keySource, constants);
      if (typeof key !== 'string') throw new Error(`Dart descriptor map key is not a string: ${keySource}`);
      value[key] = parseDartConstValue(valueSource, constants);
    }
    return value;
  }
  const constructorMatch = /^(\w+)\s*\(([\s\S]*)\)$/u.exec(source);
  if (constructorMatch) {
    const fields = {};
    for (const entry of splitTopLevel(constructorMatch[2])) {
      const [name, valueSource] = splitDartMapEntry(entry);
      fields[name] = parseDartConstValue(valueSource, constants);
    }
    return { constructor: constructorMatch[1], ...fields };
  }
  throw new Error(`Unsupported Dart const descriptor value: ${source.slice(0, 160)}`);
};

const readStaticConstExpression = (source, name) => {
  const marker = new RegExp(`static\\s+const(?:\\s+[^=;]+)?\\s+${name}\\s*=`, 'u');
  const match = marker.exec(source);
  if (!match) throw new Error(`Missing Dart static const ${name}`);
  const start = match.index + match[0].length;
  let quote = '';
  let escaped = false;
  const stack = [];
  const opening = new Map([['(', ')'], ['[', ']'], ['{', '}'], ['<', '>']]);
  for (let index = start; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === "'" || character === '"') quote = character;
    else if (opening.has(character)) stack.push(opening.get(character));
    else if (stack.length && character === stack[stack.length - 1]) stack.pop();
    else if (character === ';' && stack.length === 0) return source.slice(start, index).trim();
  }
  throw new Error(`Unterminated Dart static const ${name}`);
};

const defaultCapabilityPluginsPath = resolve(repositoryDirectory, 'lib', 'core', 'capabilities', 'default_capability_plugins.dart');
const defaultCapabilityPluginsSource = readFileSync(defaultCapabilityPluginsPath, 'utf8');
const capabilityImports = new Map(
  [...defaultCapabilityPluginsSource.matchAll(/import\s+'([^']+)'\s*;/gu)].map(match => {
    const path = resolve(dirname(defaultCapabilityPluginsPath), match[1]);
    return [path, readFileSync(path, 'utf8')];
  })
);
const registeredCapabilityClasses = [...defaultCapabilityPluginsSource.matchAll(/descriptor:\s*(\w+)\.capabilityDescriptor/gu)].map(match => match[1]);
if (registeredCapabilityClasses.length === 0) throw new Error('No default Playmesh capability descriptors are registered.');

const extractedBuiltInCapabilityDescriptors = registeredCapabilityClasses.map(className => {
  const imported = [...capabilityImports].find(([, source]) => new RegExp(`\\bclass\\s+${className}\\b|\\bclass\\s+${className}\\s`, 'u').test(source));
  if (!imported) throw new Error(`Cannot locate registered capability class source: ${className}`);
  const [sourcePath, source] = imported;
  const constants = new Map();
  constants.set('code', parseDartConstValue(readStaticConstExpression(source, 'code')));
  if (/static\s+const(?:\s+[^=;]+)?\s+supportedPresets\s*=/u.test(source)) {
    constants.set('supportedPresets', parseDartConstValue(readStaticConstExpression(source, 'supportedPresets')));
  }
  const parsed = parseDartConstValue(readStaticConstExpression(source, 'capabilityDescriptor'), constants);
  if (parsed.constructor !== 'CapabilityDescriptor') throw new Error(`Unexpected descriptor constructor in ${sourcePath}`);
  const normalizeMethod = method => ({
    name: method.name,
    description: method.description,
    requiresUserActivation: method.requiresUserActivation === true,
    argumentsSchema: method.argumentsSchema || { type: 'object' },
    resultSchema: method.resultSchema || { type: 'null' },
  });
  const normalizeEvent = event => ({
    name: event.name,
    description: event.description,
    dataSchema: event.dataSchema || { type: 'object' },
  });
  return {
    code: parsed.code,
    name: parsed.name,
    description: parsed.description,
    apiVersion: parsed.apiVersion,
    supportedPlatforms: parsed.supportedPlatforms,
    optionsSchema: parsed.optionsSchema || { type: 'object' },
    methods: (parsed.methods || []).map(normalizeMethod),
    events: (parsed.events || []).map(normalizeEvent),
  };
});

if (new Set(extractedBuiltInCapabilityDescriptors.map(descriptor => descriptor.code)).size !== extractedBuiltInCapabilityDescriptors.length) {
  throw new Error('Default Playmesh capability codes are not unique.');
}

const builtInCapabilitySnapshotPath = resolve(scriptsDirectory, 'playmesh-built-in-capabilities.snapshot.json');
const extractedBuiltInCapabilitySnapshotSource = `${JSON.stringify(extractedBuiltInCapabilityDescriptors, null, 2)}\n`;
const builtInCapabilityDescriptors = JSON.parse(extractedBuiltInCapabilitySnapshotSource);

const features = [
  'nullable',
  'jsonPath',
  'operation',
  'error',
  'event',
  'request',
  'handle',
  'binary',
  'file',
  'media',
  'dynamicCapability',
];

const runtimeCode = String.raw`(() => {
  "use strict";

  const PLAYMESH_SDK_SURFACE = Object.freeze({
    execute: Object.freeze(${JSON.stringify(executeCommands)}),
    subscribe: Object.freeze(${JSON.stringify(subscribeCommands)}),
    handler: Object.freeze(${JSON.stringify(handlerCommands)}),
    features: Object.freeze(${JSON.stringify(features)})
  });
  const PLAYMESH_BUILTIN_CAPABILITIES = Object.freeze(${JSON.stringify(builtInCapabilityDescriptors)});

  const safeConsoleError = (value) => {
    try {
      if (globalThis.console && typeof console.error === "function") console.error(value);
    } catch (_) {}
  };

  try {
    if (gdjs._playmeshExtension && gdjs._playmeshExtension.runtimeVersion === 2) return;

    const executeSet = new Set(PLAYMESH_SDK_SURFACE.execute);
    const subscribeSet = new Set(PLAYMESH_SDK_SURFACE.subscribe);
    const handlerSet = new Set(PLAYMESH_SDK_SURFACE.handler);
    const forbiddenPathKeys = new Set(["__proto__", "prototype", "constructor"]);
    const limits = Object.freeze({
      errors: 64,
      operations: 256,
      handles: 256,
      subscriptions: 128,
      handlers: 64,
      eventsPerSubscription: 128,
      requests: 128,
      requestsPerHandler: 128,
      text: 1024,
      depth: 16,
      objectKeys: 256
    });

    const errors = [];
    const operations = new Map();
    const operationOrder = [];
    const handles = new Map();
    const objectHandles = new WeakMap();
    const subscriptions = new Map();
    const eventQueues = new Map();
    const handlers = new Map();
    const requests = new Map();
    const requestQueues = new Map();
    let nextId = 1;
    let eventSequence = 1;
    let lastOperationId = "";
    let lastHandleId = "";

    const now = () => {
      try { return Date.now(); } catch (_) { return 0; }
    };

    const clipped = (value, maximum = limits.text) => {
      const text = String(value == null ? "" : value);
      return text.length <= maximum ? text : text.slice(0, maximum);
    };

    const makeFault = (code, message) => {
      const fault = new Error(clipped(message));
      fault.playmeshCode = clipped(code, 96);
      return fault;
    };

    const errorView = (error, fallbackCode = "extension_error") => {
      if (error && typeof error === "object") {
        return {
          code: clipped(error.playmeshCode || error.code || fallbackCode, 96),
          name: clipped(error.name || "Error", 96),
          message: clipped(error.message || String(error)),
          stack: clipped(error.stack || "", 4096)
        };
      }
      return { code: clipped(fallbackCode, 96), name: "Error", message: clipped(error), stack: "" };
    };

    const recordError = (error, context = {}) => {
      const view = errorView(error, context.code || "extension_error");
      const entry = {
        sequence: nextId++,
        timestamp: now(),
        code: view.code,
        name: view.name,
        message: view.message,
        stack: view.stack,
        command: clipped(context.command || "", 192),
        operationId: clipped(context.operationId || "", 128),
        handleId: clipped(context.handleId || "", 128)
      };
      errors.push(entry);
      if (errors.length > limits.errors) errors.splice(0, errors.length - limits.errors);
      safeConsoleError("[Playmesh GDevelop] " + entry.code + ": " + entry.message);
      return entry;
    };

    const getSdk = () => {
      let sdk;
      try { sdk = globalThis.playmesh; } catch (error) {
        throw makeFault("sdk_unreadable", error && error.message ? error.message : "Playmesh SDK cannot be read.");
      }
      if (!sdk || (typeof sdk !== "object" && typeof sdk !== "function")) {
        throw makeFault("sdk_missing", "Playmesh SDK is not available in the current page context.");
      }
      return sdk;
    };

    const normalId = (value, prefix) => {
      const supplied = clipped(value || "", 128).trim();
      return supplied || prefix + "-" + nextId++;
    };

    const storeOperation = (operation) => {
      const id = operation.operationId;
      if (!operations.has(id)) operationOrder.push(id);
      operations.set(id, operation);
      while (operationOrder.length > limits.operations) {
        const expired = operationOrder.shift();
        if (expired !== undefined) operations.delete(expired);
      }
      lastOperationId = id;
      return operation;
    };

    const operationSuccess = (id, value, valueType) => storeOperation({
      ok: true,
      status: "fulfilled",
      operationId: id,
      timestamp: now(),
      value: value === undefined ? null : value,
      valueType: valueType || (value === undefined ? "undefined" : value === null ? "null" : typeof value)
    });

    const operationFailure = (id, errorEntry) => storeOperation({
      ok: false,
      status: "rejected",
      operationId: id,
      timestamp: now(),
      value: null,
      valueType: "null",
      error: errorEntry
    });

    const rejectOperation = (operationIdInput, code, message, command = "typed-validation") => {
      const operationId = normalId(operationIdInput, "operation");
      const entry = recordError(makeFault(code || "typed_argument_invalid", message || "A typed Playmesh argument is invalid."), { command, operationId });
      return Promise.resolve(operationFailure(operationId, entry));
    };

    const parseJsonInput = (input, emptyValue = []) => {
      if (input === undefined || input === null) return emptyValue;
      if (typeof input !== "string") return input;
      const text = input.trim();
      if (!text) return emptyValue;
      return JSON.parse(text);
    };

    const bytesToBase64 = (bytes) => {
      const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      let output = "";
      for (let index = 0; index < bytes.length; index += 3) {
        const first = bytes[index];
        const second = index + 1 < bytes.length ? bytes[index + 1] : 0;
        const third = index + 2 < bytes.length ? bytes[index + 2] : 0;
        const value = (first << 16) | (second << 8) | third;
        output += alphabet[(value >>> 18) & 63];
        output += alphabet[(value >>> 12) & 63];
        output += index + 1 < bytes.length ? alphabet[(value >>> 6) & 63] : "=";
        output += index + 2 < bytes.length ? alphabet[value & 63] : "=";
      }
      return output;
    };

    const base64ToBytes = (input) => {
      const clean = String(input || "").replace(/\s+/g, "");
      if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(clean)) {
        throw makeFault("binary_base64_invalid", "The binary base64 value is invalid.");
      }
      const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
      const output = [];
      for (let index = 0; index < clean.length; index += 4) {
        const a = alphabet.indexOf(clean[index]);
        const b = alphabet.indexOf(clean[index + 1]);
        const c = clean[index + 2] === "=" ? 0 : alphabet.indexOf(clean[index + 2]);
        const d = clean[index + 3] === "=" ? 0 : alphabet.indexOf(clean[index + 3]);
        const value = (a << 18) | (b << 12) | (c << 6) | d;
        output.push((value >>> 16) & 255);
        if (clean[index + 2] !== "=") output.push((value >>> 8) & 255);
        if (clean[index + 3] !== "=") output.push(value & 255);
      }
      return new Uint8Array(output);
    };

    const hexToBytes = (input) => {
      const clean = String(input || "").replace(/[\s:_-]+/g, "");
      if (clean.length % 2 !== 0 || !/^[0-9a-fA-F]*$/.test(clean)) {
        throw makeFault("binary_hex_invalid", "The binary hex value is invalid.");
      }
      const output = new Uint8Array(clean.length / 2);
      for (let index = 0; index < output.length; index++) output[index] = parseInt(clean.slice(index * 2, index * 2 + 2), 16);
      return output;
    };

    const bytesToHex = (bytes) => {
      let output = "";
      for (const value of bytes) output += value.toString(16).padStart(2, "0");
      return output;
    };

    const utf8ToBytes = (text) => {
      const Encoder = globalThis.TextEncoder;
      if (typeof Encoder === "function") return new Encoder().encode(String(text));
      const encoded = unescape(encodeURIComponent(String(text)));
      const output = new Uint8Array(encoded.length);
      for (let index = 0; index < encoded.length; index++) output[index] = encoded.charCodeAt(index);
      return output;
    };

    const bytesToUtf8 = (bytes) => {
      const Decoder = globalThis.TextDecoder;
      if (typeof Decoder === "function") return new Decoder("utf-8", { fatal: false }).decode(bytes);
      let encoded = "";
      for (const value of bytes) encoded += String.fromCharCode(value);
      return decodeURIComponent(escape(encoded));
    };

    const bytesFromArray = (value) => {
      const source = Array.isArray(value) ? value : value && typeof value === "object" ? Object.keys(value).sort((a, b) => Number(a) - Number(b)).map((key) => value[key]) : [];
      const output = new Uint8Array(source.length);
      for (let index = 0; index < source.length; index++) {
        const byte = Number(source[index]);
        if (!Number.isInteger(byte) || byte < 0 || byte > 255) throw makeFault("binary_byte_invalid", "Every binary byte must be an integer from 0 to 255.");
        output[index] = byte;
      }
      return output;
    };

    const decodeBinary = (specification) => {
      if (specification instanceof Uint8Array) return specification;
      if (Array.isArray(specification)) return bytesFromArray(specification);
      if (typeof specification === "string") return base64ToBytes(specification);
      if (!specification || typeof specification !== "object") throw makeFault("binary_argument_invalid", "A binary argument is required.");
      if (Object.prototype.hasOwnProperty.call(specification, "$binaryBase64")) return base64ToBytes(specification.$binaryBase64);
      if (Object.prototype.hasOwnProperty.call(specification, "$binaryUtf8")) return utf8ToBytes(specification.$binaryUtf8);
      if (Object.prototype.hasOwnProperty.call(specification, "$binaryHex")) return hexToBytes(specification.$binaryHex);
      if (Object.prototype.hasOwnProperty.call(specification, "$binaryBytes")) return bytesFromArray(specification.$binaryBytes);
      const value = specification.$binary || specification;
      const encoding = String(value.encoding || "base64").toLowerCase();
      if (encoding === "base64") return base64ToBytes(value.data);
      if (encoding === "utf8" || encoding === "text") return utf8ToBytes(value.data);
      if (encoding === "hex") return hexToBytes(value.data);
      if (encoding === "bytes" || encoding === "array") return bytesFromArray(typeof value.data === "string" ? parseJsonInput(value.data, []) : value.data);
      throw makeFault("binary_encoding_invalid", "Unsupported binary encoding: " + encoding);
    };

    const registerHandle = (type, value, sdk, preferredId, metadata = {}) => {
      if ((typeof value !== "object" && typeof value !== "function") || value === null) throw makeFault("handle_value_invalid", "The SDK did not return a handle object.");
      const existing = objectHandles.get(value);
      if (existing && handles.has(existing)) return existing;
      if (handles.size >= limits.handles) throw makeFault("handle_limit", "The Playmesh handle limit was reached.");
      let id = normalId(preferredId, "handle");
      if (handles.has(id)) id = normalId("", "handle");
      handles.set(id, { id, type, value, sdk: sdk || null, metadata, createdAt: now() });
      objectHandles.set(value, id);
      lastHandleId = id;
      return id;
    };

    const requireHandle = (id, expectedType, sdk, requireSameSdk = true) => {
      const entry = handles.get(String(id || ""));
      if (!entry) throw makeFault("handle_missing", "Unknown Playmesh handle: " + String(id || ""));
      if (expectedType && entry.type !== expectedType) throw makeFault("handle_type", "Expected " + expectedType + " but received " + entry.type + ".");
      if (requireSameSdk && entry.sdk && entry.sdk !== sdk) throw makeFault("handle_stale", "The handle belongs to a different Playmesh SDK context.");
      return entry;
    };

    const releaseHandle = (id) => {
      const entry = handles.get(String(id || ""));
      if (!entry) return false;
      handles.delete(entry.id);
      return true;
    };

    const makeBinaryView = (bytes) => ({
      encoding: "base64",
      data: bytesToBase64(bytes),
      base64: bytesToBase64(bytes),
      byteLength: bytes.byteLength
    });

    const looksLikeMediaSource = (value) => value && typeof value === "object" && value.type === "playmesh.app.media-source" && value.version === 1;
    const looksLikeMediaStream = (value) => value && typeof value === "object" && typeof value.getTracks === "function";

    const plainValue = (value, sdk, depth = 0, seen = new WeakSet()) => {
      if (value === undefined || value === null || typeof value === "string" || typeof value === "boolean") return value;
      if (typeof value === "number") return Number.isFinite(value) ? value : null;
      if (typeof value === "bigint") return String(value);
      if (typeof value === "function") return undefined;
      if (value instanceof Uint8Array) return makeBinaryView(value);
      if (value instanceof Error) return errorView(value);
      if (looksLikeMediaSource(value)) {
        if (seen.has(value)) return "[Circular]";
        seen.add(value);
        const handleId = registerHandle("PlaymeshAppMediaSource", value, sdk);
        const output = {
          handleId,
          handleType: "PlaymeshAppMediaSource",
          type: clipped(value.type, 128),
          version: Number(value.version) || 1,
          id: clipped(value.id, 256),
          kind: clipped(value.kind, 64),
          protocol: clipped(value.protocol, 128),
          live: value.live === true
        };
        const reserved = new Set(["handleId", "handleType", "type", "version", "id", "kind", "protocol", "live"]);
        if (depth < limits.depth) {
          for (const key of Object.keys(value).slice(0, limits.objectKeys)) {
            if (reserved.has(key) || forbiddenPathKeys.has(key)) continue;
            try {
              const converted = plainValue(value[key], sdk, depth + 1, seen);
              if (converted !== undefined) output[key] = converted;
            } catch (error) {
              output[key] = { unreadable: true, error: errorView(error) };
            }
          }
        }
        seen.delete(value);
        return output;
      }
      if (looksLikeMediaStream(value)) {
        const handleId = registerHandle("MediaStream", value, sdk);
        return { handleId, handleType: "MediaStream", opaque: true, active: value.active !== false };
      }
      if (depth >= limits.depth) return "[DepthLimit]";
      if (typeof value !== "object") return clipped(value);
      if (seen.has(value)) return "[Circular]";
      seen.add(value);
      let output;
      if (Array.isArray(value)) {
        output = value.slice(0, limits.objectKeys).map((item) => plainValue(item, sdk, depth + 1, seen));
      } else {
        output = {};
        const keys = Object.keys(value).slice(0, limits.objectKeys);
        for (const key of keys) {
          if (forbiddenPathKeys.has(key)) continue;
          try {
            const converted = plainValue(value[key], sdk, depth + 1, seen);
            if (converted !== undefined) output[key] = converted;
          } catch (error) {
            output[key] = { unreadable: true, error: errorView(error) };
          }
        }
      }
      seen.delete(value);
      return output;
    };

    const rpcTransferValue = async (value, sdk, depth = 0, seen = new WeakSet()) => {
      if (value === undefined || value === null || typeof value !== "object") {
        return plainValue(value, sdk);
      }
      if (value instanceof Uint8Array) {
        return { $binary: { encoding: "base64", data: bytesToBase64(value) } };
      }
      if (value instanceof ArrayBuffer) {
        return {
          $binary: {
            encoding: "base64",
            data: bytesToBase64(new Uint8Array(value)),
          },
        };
      }
      const FileType = globalThis.File;
      const BlobType = globalThis.Blob;
      if (typeof FileType === "function" && value instanceof FileType) {
        return {
          $file: {
            name: clipped(value.name || "file.bin", 255),
            type: clipped(value.type || "application/octet-stream", 255),
            lastModified: Number(value.lastModified) || 0,
            encoding: "base64",
            data: bytesToBase64(new Uint8Array(await value.arrayBuffer())),
          },
        };
      }
      if (typeof BlobType === "function" && value instanceof BlobType) {
        return {
          $file: {
            name: "blob.bin",
            type: clipped(value.type || "application/octet-stream", 255),
            lastModified: 0,
            encoding: "base64",
            data: bytesToBase64(new Uint8Array(await value.arrayBuffer())),
          },
        };
      }
      if (depth >= limits.depth || seen.has(value)) {
        throw makeFault("rpc_transfer_invalid", "RPC data is too deep or circular.");
      }
      seen.add(value);
      let output;
      if (Array.isArray(value)) {
        output = [];
        for (const item of value.slice(0, limits.objectKeys)) {
          output.push(await rpcTransferValue(item, sdk, depth + 1, seen));
        }
      } else {
        output = {};
        for (const key of Object.keys(value).slice(0, limits.objectKeys)) {
          if (forbiddenPathKeys.has(key)) continue;
          output[key] = await rpcTransferValue(value[key], sdk, depth + 1, seen);
        }
      }
      seen.delete(value);
      return output;
    };

    const handleDescriptor = (entry) => {
      const value = entry.value;
      const output = { handleId: entry.id, handleType: entry.type };
      if (entry.type === "PlaymeshBinaryChannel") {
        output.id = clipped(value.id, 256);
        output.mode = clipped(value.mode, 64);
      } else if (entry.type === "PlaymeshCapabilityHandle") {
        output.id = clipped(value.id, 256);
        output.code = clipped(value.code, 256);
        output.apiVersion = clipped(value.apiVersion, 128);
      } else if (entry.type === "PlaymeshAppMediaSession") {
        output.id = clipped(value.id, 256);
        output.state = clipped(value.state, 64);
        output.source = plainValue(value.source, entry.sdk);
        output.stream = plainValue(value.stream, entry.sdk);
      } else if (entry.type === "PlaymeshLanGame") {
        output.instanceId = clipped(value.instanceId, 256);
        output.gameId = clipped(value.gameId, 256);
        output.name = clipped(value.name, 512);
        output.host = clipped(value.host, 512);
      } else if (entry.type === "MediaStream") {
        output.opaque = true;
        output.active = value.active !== false;
      } else if (entry.type === "AbortController") {
        output.aborted = !!(value.signal && value.signal.aborted);
      }
      return output;
    };

    const commandResult = (command, value, sdk) => {
      let type = "";
      if (command === "playmesh.main.binary.createChannel" || command === "playmesh.main.binary.joinChannel") type = "PlaymeshBinaryChannel";
      else if (command === "playmesh.main.sync.startAuthority") type = "PlaymeshSyncAuthorityController";
      else if (command === "playmesh.main.storage.getBucket") type = "PlaymeshStorageBucket";
      else if (command === "playmesh.app.storage.getBucket") type = "PlaymeshAppStorageBucket";
      else if (command === "playmesh.app.capabilities.create") type = "PlaymeshCapabilityHandle";
      else if (command === "playmesh.app.media.open") type = "PlaymeshAppMediaSession";
      if (type) return handleDescriptor(handles.get(registerHandle(type, value, sdk)));
      if (command === "playmesh.app.lan.discoverGames") {
        const games = Array.isArray(value) ? value : [];
        return games.map((game) => handleDescriptor(handles.get(registerHandle("PlaymeshLanGame", game, sdk))));
      }
      if (command === "playmesh.main.rpc.request") {
        return rpcTransferValue(value, sdk);
      }
      return plainValue(value, sdk);
    };

    const parsePath = (input) => {
      const path = String(input == null ? "" : input).trim();
      if (!path || path === "$") return [];
      if (path.startsWith("/")) return path.slice(1).split("/").map((part) => part.replace(/~1/g, "/").replace(/~0/g, "~"));
      const tokens = [];
      let index = path[0] === "$" ? 1 : 0;
      while (index < path.length) {
        if (path[index] === ".") { index++; continue; }
        if (path[index] === "[") {
          index++;
          while (/\s/.test(path[index] || "")) index++;
          let token = "";
          const quote = path[index] === "\"" || path[index] === "'" ? path[index++] : "";
          if (quote) {
            while (index < path.length && path[index] !== quote) {
              if (path[index] === "\\" && index + 1 < path.length) index++;
              token += path[index++];
            }
            if (path[index] !== quote) throw makeFault("json_path_invalid", "JSON path has an unterminated quoted key.");
            index++;
            while (/\s/.test(path[index] || "")) index++;
          } else {
            while (index < path.length && path[index] !== "]") token += path[index++];
            token = token.trim();
          }
          if (path[index] !== "]") throw makeFault("json_path_invalid", "JSON path has an unterminated bracket.");
          index++;
          tokens.push(token);
          continue;
        }
        let token = "";
        while (index < path.length && path[index] !== "." && path[index] !== "[") token += path[index++];
        if (!token) throw makeFault("json_path_invalid", "JSON path contains an empty key.");
        tokens.push(token);
      }
      for (const token of tokens) if (forbiddenPathKeys.has(token)) throw makeFault("json_path_forbidden", "JSON path contains a forbidden key.");
      return tokens;
    };

    const pathResult = (root, path) => {
      let current = root;
      for (const token of parsePath(path)) {
        if (current === null || current === undefined || (typeof current !== "object" && typeof current !== "string")) return { exists: false, value: undefined };
        if (!Object.prototype.hasOwnProperty.call(Object(current), token)) return { exists: false, value: undefined };
        current = current[token];
      }
      return { exists: true, value: current };
    };

    const safeJson = (value) => {
      try {
        const result = JSON.stringify(value === undefined ? null : value);
        return result === undefined ? "null" : result;
      } catch (_) { return "null"; }
    };

    const stringValue = (value) => {
      if (value === null || value === undefined) return "";
      if (typeof value === "string") return value;
      if (typeof value === "number" || typeof value === "boolean" || typeof value === "bigint") return String(value);
      return safeJson(value);
    };

    const numberValue = (value) => {
      const number = Number(value);
      return Number.isFinite(number) ? number : 0;
    };

    const writeVariable = (variable, value) => {
      if (!variable) return false;
      if (typeof variable.fromJSObject === "function") {
        variable.fromJSObject(value === undefined ? null : value);
        return true;
      }
      if (value && typeof value === "object") return false;
      if (typeof value === "number" && typeof variable.setNumber === "function") variable.setNumber(value);
      else if (typeof value === "boolean" && typeof variable.setBoolean === "function") variable.setBoolean(value);
      else if (typeof variable.setString === "function") variable.setString(stringValue(value));
      else return false;
      return true;
    };

    const readVariable = (variable) => {
      if (!variable) return null;
      try {
        if (typeof variable.toJSObject === "function") return variable.toJSObject();
        if (typeof variable.getAsBoolean === "function" && typeof variable.isBoolean === "function" && variable.isBoolean()) return variable.getAsBoolean();
        if (typeof variable.getAsNumber === "function" && typeof variable.isNumber === "function" && variable.isNumber()) return variable.getAsNumber();
        if (typeof variable.getAsString === "function") {
          const value = variable.getAsString();
          try { return parseJsonInput(value, value); } catch (_) { return value; }
        }
      } catch (error) {
        recordError(error, { code: "variable_read_failed" });
      }
      return null;
    };

    const resolveDirect = (sdk, command) => {
      const parts = command.split(".").slice(1);
      let owner = sdk;
      for (let index = 0; index < parts.length - 1; index++) {
        owner = owner == null ? undefined : owner[parts[index]];
        if (owner == null) throw makeFault("sdk_path_missing", "SDK path is unavailable: " + command);
      }
      const name = parts[parts.length - 1];
      const callable = owner == null ? undefined : owner[name];
      if (typeof callable !== "function") throw makeFault("sdk_method_missing", "SDK method is unavailable: " + command);
      return { owner, callable };
    };

    const handleCommand = (sdk, command, handleId) => {
      const separator = command.lastIndexOf(".");
      const type = command.slice(0, separator);
      const method = command.slice(separator + 1);
      const entry = requireHandle(handleId, type, sdk);
      const callable = entry.value[method];
      if (typeof callable !== "function") throw makeFault("handle_method_missing", "Handle method is unavailable: " + command);
      return { entry, owner: entry.value, callable, method };
    };

    const createFile = (specification) => {
      const FileType = globalThis.File;
      if (typeof FileType !== "function") throw makeFault("file_unavailable", "File is not available in this page context.");
      const spec = specification && specification.$file ? specification.$file : specification;
      if (!spec || typeof spec !== "object") throw makeFault("file_argument_invalid", "A file argument is required.");
      const name = clipped(spec.name || "upload.bin", 255);
      const mime = clipped(spec.type || spec.mimeType || "application/octet-stream", 255);
      const encoding = String(spec.encoding || (Object.prototype.hasOwnProperty.call(spec, "base64") ? "base64" : "text")).toLowerCase();
      let bytes;
      if (encoding === "text" || encoding === "utf8") bytes = utf8ToBytes(spec.data == null ? spec.text || "" : spec.data);
      else if (encoding === "base64") bytes = base64ToBytes(spec.data == null ? spec.base64 || "" : spec.data);
      else if (encoding === "hex") bytes = hexToBytes(spec.data);
      else if (encoding === "bytes" || encoding === "array") bytes = bytesFromArray(typeof spec.data === "string" ? parseJsonInput(spec.data, []) : spec.data);
      else throw makeFault("file_encoding_invalid", "Unsupported file encoding: " + encoding);
      const options = { type: mime };
      if (Number.isFinite(Number(spec.lastModified))) options.lastModified = Number(spec.lastModified);
      return new FileType([bytes], name, options);
    };

    const decodeValue = (value, sdk, depth = 0) => {
      if (depth > limits.depth) throw makeFault("argument_depth", "SDK argument nesting is too deep.");
      if (!value || typeof value !== "object") return value;
      if (Object.prototype.hasOwnProperty.call(value, "$handle")) return requireHandle(value.$handle, "", sdk).value;
      if (Object.prototype.hasOwnProperty.call(value, "$abortSignal")) return requireHandle(value.$abortSignal, "AbortController", sdk, false).value.signal;
      if (Object.prototype.hasOwnProperty.call(value, "$file")) return createFile(value);
      if (Object.prototype.hasOwnProperty.call(value, "$binary") || Object.prototype.hasOwnProperty.call(value, "$binaryBase64") || Object.prototype.hasOwnProperty.call(value, "$binaryUtf8") || Object.prototype.hasOwnProperty.call(value, "$binaryHex") || Object.prototype.hasOwnProperty.call(value, "$binaryBytes")) return decodeBinary(value);
      if (Array.isArray(value)) return value.map((item) => decodeValue(item, sdk, depth + 1));
      const output = {};
      for (const key of Object.keys(value)) {
        if (forbiddenPathKeys.has(key)) continue;
        output[key] = decodeValue(value[key], sdk, depth + 1);
      }
      return output;
    };

    const normalizeArguments = (input, sdk) => {
      const parsed = parseJsonInput(input, []);
      const args = Array.isArray(parsed) ? parsed : [parsed];
      return { parsed, args: args.map((value) => decodeValue(value, sdk)) };
    };

    const requestPayload = (value, sdk) => plainValue(value, sdk);

    const createRequest = (handlerId, kind, payload, sdk, defaultValue, timeoutMs) => {
      const id = normalId("", "request");
      if (requests.size >= limits.requests) {
        recordError(makeFault("request_limit", "The Playmesh request limit was reached."), { command: kind });
        return Promise.resolve(defaultValue);
      }
      const ownerId = normalId(handlerId, "handler");
      const timeout = Math.max(100, Math.min(60000, Number(timeoutMs) || 15000));
      const record = {
        requestId: id,
        handlerId: ownerId,
        kind,
        timestamp: now(),
        payload: requestPayload(payload, sdk),
        sdk,
        defaultValue,
        resolve: null,
        reject: null,
        timer: null
      };
      const promise = new Promise((resolve, reject) => {
        record.resolve = resolve;
        record.reject = reject;
      });
      requests.set(id, record);
      const queue = requestQueues.get(ownerId) || [];
      queue.push({ requestId: id, handlerId: ownerId, kind, timestamp: record.timestamp, payload: record.payload });
      if (queue.length > limits.requestsPerHandler) queue.splice(0, queue.length - limits.requestsPerHandler);
      requestQueues.set(ownerId, queue);
      if (typeof globalThis.setTimeout === "function") {
        record.timer = globalThis.setTimeout(() => {
          if (!requests.has(id)) return;
          finishRequest(record);
          recordError(makeFault("request_timeout", "A Playmesh callback request timed out."), { command: kind });
          try { record.resolve(defaultValue); } catch (_) {}
        }, timeout);
      }
      return promise;
    };

    const finishRequest = (record) => {
      requests.delete(record.requestId);
      const queue = requestQueues.get(record.handlerId);
      if (queue) {
        const index = queue.findIndex((item) => item.requestId === record.requestId);
        if (index >= 0) queue.splice(index, 1);
      }
      if (record.timer && typeof globalThis.clearTimeout === "function") {
        try { globalThis.clearTimeout(record.timer); } catch (_) {}
      }
    };

    const respond = (requestId, responseInput, modeInput) => {
      const record = requests.get(String(requestId || ""));
      if (!record) {
        recordError(makeFault("request_missing", "Unknown or completed Playmesh request: " + String(requestId || "")));
        return false;
      }
      try {
        const mode = String(modeInput || "result").toLowerCase();
        let value;
        if (mode === "keep" || mode === "pass" || mode === "void") value = undefined;
        else if (mode === "null") value = null;
        else if (mode === "replace" || mode === "replacebase64") {
          let binaryInput = responseInput;
          try { binaryInput = parseJsonInput(responseInput, responseInput); } catch (_) {}
          value = decodeBinary(binaryInput);
        }
        else if (mode === "reject") {
          let parsed = responseInput;
          try { parsed = parseJsonInput(responseInput, responseInput); } catch (_) {}
          const message = typeof parsed === "string" ? parsed : parsed && parsed.message ? parsed.message : "The Playmesh callback request was rejected.";
          finishRequest(record);
          const error = makeFault("request_rejected", message);
          recordError(error, { command: record.kind });
          record.reject(error);
          return true;
        } else {
          value = parseJsonInput(responseInput, null);
          if (record.kind === "playmesh.main.rpc.onRequest") {
            value = decodeValue(value, record.sdk);
          }
        }
        finishRequest(record);
        record.resolve(value);
        return true;
      } catch (error) {
        recordError(error, { command: record.kind });
        return false;
      }
    };

    const cancelRequest = (requestId) => {
      const record = requests.get(String(requestId || ""));
      if (!record) return false;
      finishRequest(record);
      try { record.resolve(record.defaultValue); } catch (_) {}
      return true;
    };

    const invokeExecuteCommand = async (sdk, command, parsed, args, handleId) => {
      let target;
      if (command.startsWith("playmesh.")) target = resolveDirect(sdk, command);
      else target = handleCommand(sdk, command, handleId);

      if (command === "playmesh.main.sync.startAuthority") {
        const source = args[0] && typeof args[0] === "object" ? args[0] : {};
        const options = { initialState: source.initialState };
        if (source.stateType !== undefined) options.stateType = source.stateType;
        if (source.tickRate !== undefined) options.tickRate = source.tickRate;
        const inputHandlerId = source.onInputHandlerId || source.onInput;
        const tickHandlerId = source.onTickHandlerId || source.onTick;
        const timeoutMs = source.callbackTimeoutMs;
        if (inputHandlerId) options.onInput = (input, context) => createRequest(inputHandlerId, "PlaymeshSyncAuthorityOptions.onInput", { input, context }, sdk, undefined, timeoutMs);
        if (tickHandlerId) options.onTick = (context) => createRequest(tickHandlerId, "PlaymeshSyncAuthorityOptions.onTick", { context }, sdk, undefined, timeoutMs);
        return target.callable.call(target.owner, options);
      }

      if (command === "PlaymeshSyncAuthorityController.publish") {
        const source = !Array.isArray(parsed) && parsed && typeof parsed === "object" ? decodeValue(parsed, sdk) : args[0] && typeof args[0] === "object" && Object.prototype.hasOwnProperty.call(args[0], "hasState") ? args[0] : null;
        if (source && Object.prototype.hasOwnProperty.call(source, "hasState")) {
          if (source.hasState === true) return target.callable.call(target.owner, source.state, source.targetPlayerIds);
          return target.callable.call(target.owner, source.targetPlayerIds);
        }
      }

      if (command === "PlaymeshCapabilityHandle.removeEventListener") {
        const eventName = String(args[0] || "");
        const subscriptionId = String(args[1] || "");
        const subscription = subscriptions.get(subscriptionId);
        if (!subscription || subscription.command !== "PlaymeshCapabilityHandle.addEventListener" || subscription.handleId !== String(handleId || "") || subscription.eventName !== eventName) {
          throw makeFault("subscription_callback_missing", "removeEventListener requires the event and subscription ID created by addEventListener.");
        }
        target.callable.call(target.owner, eventName, subscription.callback);
        subscriptions.delete(subscriptionId);
        eventQueues.delete(subscriptionId);
        return undefined;
      }

      return target.callable.apply(target.owner, args);
    };

    async function execute(commandInput, argumentsInput, operationIdInput, handleIdInput) {
      const command = String(commandInput || "");
      const operationId = normalId(operationIdInput, "operation");
      try {
        const sdk = getSdk();
        const normalized = normalizeArguments(argumentsInput, sdk);
        if (subscribeSet.has(command)) {
          const subscribed = subscribe(command, normalized.parsed, operationId, handleIdInput);
          if (!subscribed.ok) return operationFailure(operationId, subscribed.error);
          return operationSuccess(operationId, subscribed, "subscription");
        }
        if (handlerSet.has(command)) {
          const registered = registerHandler(command, normalized.parsed, operationId, handleIdInput);
          if (!registered.ok) return operationFailure(operationId, registered.error);
          return operationSuccess(operationId, registered, "handler");
        }
        if (!executeSet.has(command)) throw makeFault("command_not_allowed", "Playmesh command is not in the extension allowlist: " + command);
        let invokeError = null;
        const rawValue = await Promise.resolve(invokeExecuteCommand(sdk, command, normalized.parsed, normalized.args, handleIdInput)).catch((error) => {
          invokeError = error;
          return undefined;
        });
        if (invokeError) throw invokeError;
        const publicValue = await Promise.resolve(commandResult(command, rawValue, sdk));
        return operationSuccess(operationId, publicValue, rawValue === undefined ? "undefined" : rawValue === null ? "null" : handles.has(publicValue && publicValue.handleId) ? "handle" : typeof rawValue);
      } catch (error) {
        const entry = recordError(error, { command, operationId, handleId: handleIdInput });
        return operationFailure(operationId, entry);
      }
    }

    const callSync = (commandInput, argumentsInput, handleIdInput) => {
      const command = String(commandInput || "");
      try {
        if (!executeSet.has(command)) throw makeFault("command_not_allowed", "Playmesh command is not in the extension allowlist: " + command);
        const sdk = getSdk();
        const normalized = normalizeArguments(argumentsInput, sdk);
        const target = command.startsWith("playmesh.") ? resolveDirect(sdk, command) : handleCommand(sdk, command, handleIdInput);
        const rawValue = target.callable.apply(target.owner, normalized.args);
        if (rawValue && typeof rawValue.then === "function") throw makeFault("sync_value_async", "The requested SDK value is asynchronous: " + command);
        return { ok: true, value: commandResult(command, rawValue, sdk), valueType: rawValue === undefined ? "undefined" : rawValue === null ? "null" : typeof rawValue };
      } catch (error) {
        return { ok: false, value: null, valueType: "null", error: recordError(error, { command, handleId: handleIdInput }) };
      }
    };

    const eventValue = (command, callbackArguments, sdk) => {
      if (command === "PlaymeshBinaryChannel.onMessage") {
        return { data: makeBinaryView(callbackArguments[0] instanceof Uint8Array ? callbackArguments[0] : new Uint8Array(callbackArguments[0] || [])), context: plainValue(callbackArguments[1], sdk) };
      }
      if (callbackArguments.length === 0) return {};
      if (callbackArguments.length === 1) return plainValue(callbackArguments[0], sdk);
      return callbackArguments.map((value) => plainValue(value, sdk));
    };

    const pushEvent = (subscriptionId, command, callbackArguments, sdk) => {
      const queue = eventQueues.get(subscriptionId) || [];
      queue.push({ subscriptionId, command, sequence: eventSequence++, timestamp: now(), value: eventValue(command, callbackArguments, sdk) });
      if (queue.length > limits.eventsPerSubscription) queue.splice(0, queue.length - limits.eventsPerSubscription);
      eventQueues.set(subscriptionId, queue);
    };

    function subscribe(commandInput, argumentsInput, subscriptionIdInput, handleIdInput) {
      const command = String(commandInput || "");
      const subscriptionId = normalId(subscriptionIdInput, "subscription");
      try {
        if (!subscribeSet.has(command)) throw makeFault("subscription_not_allowed", "Playmesh subscription is not in the extension allowlist: " + command);
        const sdk = getSdk();
        if (subscriptions.size >= limits.subscriptions && !subscriptions.has(subscriptionId)) throw makeFault("subscription_limit", "The Playmesh subscription limit was reached.");
        if (subscriptions.has(subscriptionId)) unsubscribe(subscriptionId);
        const normalized = normalizeArguments(argumentsInput, sdk);
        const target = command.startsWith("playmesh.") ? resolveDirect(sdk, command) : handleCommand(sdk, command, handleIdInput);
        let callback;
        let requestHandlerId = "";
        if (command === "playmesh.main.lifecycle.onExit") {
          const configuration = normalized.args[0] && typeof normalized.args[0] === "object" ? normalized.args[0] : {};
          requestHandlerId = configuration.handlerId ? String(configuration.handlerId) : "";
          callback = (event) => {
            try { pushEvent(subscriptionId, command, [event], sdk); }
            catch (error) { recordError(error, { command, handleId: handleIdInput }); }
            return requestHandlerId ? createRequest(requestHandlerId, command, { event }, sdk, undefined, configuration.callbackTimeoutMs) : undefined;
          };
        } else {
          callback = (...callbackArguments) => {
            try { pushEvent(subscriptionId, command, callbackArguments, sdk); }
            catch (error) { recordError(error, { command, handleId: handleIdInput }); }
            return undefined;
          };
        }
        let returned;
        let eventName = "";
        if (command === "PlaymeshCapabilityHandle.on" || command === "PlaymeshCapabilityHandle.addEventListener") {
          eventName = String(normalized.args[0] || "");
          returned = target.callable.call(target.owner, eventName, callback);
        } else returned = target.callable.call(target.owner, callback);
        subscriptions.set(subscriptionId, {
          subscriptionId,
          command,
          handleId: String(handleIdInput || ""),
          sdk,
          callback,
          eventName,
          requestHandlerId,
          owner: target.owner,
          returned: typeof returned === "function" ? returned : null
        });
        eventQueues.set(subscriptionId, eventQueues.get(subscriptionId) || []);
        return { ok: true, subscriptionId, command };
      } catch (error) {
        return { ok: false, subscriptionId, command, error: recordError(error, { command, handleId: handleIdInput }) };
      }
    }

    function unsubscribe(subscriptionIdInput) {
      const subscriptionId = String(subscriptionIdInput || "");
      const subscription = subscriptions.get(subscriptionId);
      if (!subscription) return false;
      subscriptions.delete(subscriptionId);
      try {
        const sdk = getSdk();
        if (subscription.sdk !== sdk) throw makeFault("subscription_stale", "The subscription belongs to a different Playmesh SDK context.");
        if (subscription.returned) subscription.returned();
        else if (subscription.command === "PlaymeshCapabilityHandle.addEventListener") {
          const callable = subscription.owner.removeEventListener;
          if (typeof callable === "function") callable.call(subscription.owner, subscription.eventName, subscription.callback);
        }
      } catch (error) {
        recordError(error, { command: subscription.command, handleId: subscription.handleId });
      }
      if (subscription.requestHandlerId) {
        for (const request of Array.from(requests.values())) if (request.handlerId === subscription.requestHandlerId) cancelRequest(request.requestId);
      }
      return true;
    }

    function registerHandler(commandInput, argumentsInput, handlerIdInput, handleIdInput) {
      const command = String(commandInput || "");
      const handlerId = normalId(handlerIdInput, "handler");
      try {
        if (!handlerSet.has(command)) throw makeFault("handler_not_allowed", "Playmesh handler is not in the extension allowlist: " + command);
        const sdk = getSdk();
        if (handlers.size >= limits.handlers && !handlers.has(handlerId)) throw makeFault("handler_limit", "The Playmesh handler limit was reached.");
        if (handlers.has(handlerId)) unregisterHandler(handlerId);
        const normalized = normalizeArguments(argumentsInput, sdk);
        const target = command.startsWith("playmesh.") ? resolveDirect(sdk, command) : handleCommand(sdk, command, handleIdInput);
        const optionSource = command === "playmesh.main.rpc.onRequest"
          ? normalized.args[1]
          : normalized.args[0];
        const options = optionSource && typeof optionSource === "object" ? { ...optionSource } : {};
        const timeoutMs = options.callbackTimeoutMs;
        delete options.callbackTimeoutMs;
        let callback;
        let returned;
        if (command === "playmesh.main.authority.onService") {
          callback = (action, context) => createRequest(handlerId, command, { action, context }, sdk, null, timeoutMs);
          returned = Object.keys(options).length ? target.callable.call(target.owner, callback, options) : target.callable.call(target.owner, callback);
        } else if (command === "playmesh.main.rpc.onRequest") {
          const path = String(normalized.args[0] || "");
          callback = async (data, context) => createRequest(
            handlerId,
            command,
            { data: await rpcTransferValue(data, sdk), context },
            sdk,
            undefined,
            timeoutMs || 10000,
          );
          returned = target.callable.call(target.owner, path, callback);
        } else {
          callback = (data, context) => createRequest(handlerId, command, { data: makeBinaryView(data instanceof Uint8Array ? data : new Uint8Array(data || [])), context }, sdk, undefined, timeoutMs);
          returned = target.callable.call(target.owner, callback);
        }
        handlers.set(handlerId, { handlerId, command, handleId: String(handleIdInput || ""), sdk, returned: typeof returned === "function" ? returned : null });
        requestQueues.set(handlerId, requestQueues.get(handlerId) || []);
        return { ok: true, handlerId, command };
      } catch (error) {
        return { ok: false, handlerId, command, error: recordError(error, { command, handleId: handleIdInput }) };
      }
    }

    function unregisterHandler(handlerIdInput) {
      const handlerId = String(handlerIdInput || "");
      const handler = handlers.get(handlerId);
      if (!handler) return false;
      handlers.delete(handlerId);
      try {
        const sdk = getSdk();
        if (handler.sdk !== sdk) throw makeFault("handler_stale", "The handler belongs to a different Playmesh SDK context.");
        if (handler.returned) handler.returned();
      } catch (error) {
        recordError(error, { command: handler.command, handleId: handler.handleId });
      }
      for (const request of Array.from(requests.values())) if (request.handlerId === handlerId) cancelRequest(request.requestId);
      return true;
    }

    const directProperties = new Set([
      "playmesh.main.version",
      "playmesh.app.version",
      "playmesh.main.authority.defaultNamespace",
      "playmesh.main.binary.authorityPlayerId"
    ]);
    const handleProperties = new Map([
      ["PlaymeshBinaryChannel.id", ["PlaymeshBinaryChannel", "id"]],
      ["PlaymeshBinaryChannel.mode", ["PlaymeshBinaryChannel", "mode"]],
      ["PlaymeshCapabilityHandle.id", ["PlaymeshCapabilityHandle", "id"]],
      ["PlaymeshCapabilityHandle.code", ["PlaymeshCapabilityHandle", "code"]],
      ["PlaymeshCapabilityHandle.apiVersion", ["PlaymeshCapabilityHandle", "apiVersion"]],
      ["PlaymeshAppMediaSession.id", ["PlaymeshAppMediaSession", "id"]],
      ["PlaymeshAppMediaSession.source", ["PlaymeshAppMediaSession", "source"]],
      ["PlaymeshAppMediaSession.state", ["PlaymeshAppMediaSession", "state"]],
      ["PlaymeshAppMediaSession.stream", ["PlaymeshAppMediaSession", "stream"]],
      ["PlaymeshLanGame.instanceId", ["PlaymeshLanGame", "instanceId"]],
      ["PlaymeshLanGame.gameId", ["PlaymeshLanGame", "gameId"]],
      ["PlaymeshLanGame.name", ["PlaymeshLanGame", "name"]],
      ["PlaymeshLanGame.host", ["PlaymeshLanGame", "host"]]
    ]);

    const propertyValue = (propertyInput, handleIdInput) => {
      const property = String(propertyInput || "");
      try {
        const sdk = getSdk();
        if (directProperties.has(property)) {
          const parts = property.split(".").slice(1);
          let value = sdk;
          for (const part of parts) value = value == null ? undefined : value[part];
          if (value === undefined) throw makeFault("property_missing", "SDK property is unavailable: " + property);
          return { ok: true, value: plainValue(value, sdk) };
        }
        const mapping = handleProperties.get(property);
        if (!mapping) throw makeFault("property_not_allowed", "Playmesh property is not in the extension allowlist: " + property);
        const entry = requireHandle(handleIdInput, mapping[0], sdk);
        return { ok: true, value: plainValue(entry.value[mapping[1]], sdk) };
      } catch (error) {
        return { ok: false, value: null, error: recordError(error, { command: property, handleId: handleIdInput }) };
      }
    };

    const readProperty = (property, handleId, operationIdInput) => {
      const operationId = normalId(operationIdInput, "operation");
      const result = propertyValue(property, handleId);
      if (!result.ok) return operationFailure(operationId, result.error);
      return operationSuccess(operationId, result.value, result.value === null ? "null" : typeof result.value);
    };

    const operationValueAt = (operationId, path) => {
      const operation = operations.get(String(operationId || ""));
      if (!operation || !operation.ok || operation.valueType === "undefined") return { exists: false, value: undefined };
      return pathResult(operation.value, path);
    };

    const eventAt = (subscriptionId, path) => {
      const queue = eventQueues.get(String(subscriptionId || "")) || [];
      if (!queue.length) return { exists: false, value: undefined };
      return pathResult(queue[0], path);
    };

    const requestAt = (handlerId, path) => {
      const queue = requestQueues.get(String(handlerId || "")) || [];
      if (!queue.length) return { exists: false, value: undefined };
      return pathResult(queue[0], path);
    };

    const queryJson = (jsonInput, path) => {
      try { return pathResult(parseJsonInput(jsonInput, null), path); }
      catch (error) {
        recordError(error, { code: "json_invalid" });
        return { exists: false, value: undefined };
      }
    };

    const jsonEquals = (actual, expectedInput) => {
      try { return safeJson(actual) === safeJson(parseJsonInput(expectedInput, null)); }
      catch (_) { return false; }
    };

    const variableBytes = (variable) => {
      if (!variable) return new Uint8Array(0);
      const value = typeof variable.toJSObject === "function" ? variable.toJSObject() : typeof variable.getAsString === "function" ? variable.getAsString() : "";
      if (typeof value === "string") return utf8ToBytes(value);
      return bytesFromArray(value);
    };

    const binaryArgumentJson = (encoding, data) => {
      const value = String(encoding || "base64").toLowerCase();
      let parsed = data;
      if (value === "bytes" || value === "array") parsed = parseJsonInput(data, []);
      return safeJson({ $binary: { encoding: value, data: parsed } });
    };

    const fileArgumentJson = (name, mimeType, encoding, data) => safeJson({ $file: { name, type: mimeType, encoding, data: String(encoding || "text").toLowerCase() === "bytes" ? parseJsonInput(data, []) : data } });

    const createAbort = (preferredId) => {
      try {
        const Controller = globalThis.AbortController;
        if (typeof Controller !== "function") throw makeFault("abort_unavailable", "AbortController is not available in this page context.");
        const value = new Controller();
        return { ok: true, handleId: registerHandle("AbortController", value, null, preferredId), aborted: false };
      } catch (error) {
        return { ok: false, handleId: "", error: recordError(error) };
      }
    };

    const abort = (handleId) => {
      try {
        const entry = requireHandle(handleId, "AbortController", null, false);
        entry.value.abort();
        return true;
      } catch (error) {
        recordError(error, { handleId });
        return false;
      }
    };

    const reportWrapperError = (error, context) => recordError(error, { code: "event_function_error", command: context || "" });

    const runtime = {
      runtimeVersion: 2,
      surface: PLAYMESH_SDK_SURFACE,
      builtInCapabilities: PLAYMESH_BUILTIN_CAPABILITIES,
      execute,
      rejectOperation,
      callSync,
      subscribe,
      unsubscribe,
      registerHandler,
      unregisterHandler,
      respond,
      cancelRequest,
      readProperty,
      propertyValue,
      releaseHandle,
      createAbort,
      abort,
      reportWrapperError,
      recordError,
      writeVariable,
      readVariable,
      queryJson,
      queryValue: (value, path) => pathResult(value, path),
      jsonEquals,
      safeJson,
      stringValue,
      numberValue,
      binaryArgumentJson,
      fileArgumentJson,
      bytesToBase64,
      base64ToBytes,
      bytesToHex,
      hexToBytes,
      utf8ToBytes,
      bytesToUtf8,
      variableBytes,
      getOperation: (id) => operations.get(String(id || "")) || null,
      operationValueAt,
      forgetOperation: (id) => operations.delete(String(id || "")),
      getLastOperationId: () => lastOperationId,
      hasSubscription: (id) => subscriptions.has(String(id || "")),
      eventAt,
      eventCount: (id) => (eventQueues.get(String(id || "")) || []).length,
      peekEvent: (id) => (eventQueues.get(String(id || "")) || [])[0] || null,
      popEvent: (id) => {
        const queue = eventQueues.get(String(id || "")) || [];
        return queue.length ? queue.shift() : null;
      },
      clearEvents: (id) => { eventQueues.set(String(id || ""), []); },
      requestAt,
      requestCount: (id) => (requestQueues.get(String(id || "")) || []).length,
      peekRequest: (id) => (requestQueues.get(String(id || "")) || [])[0] || null,
      popRequest: (id) => {
        const queue = requestQueues.get(String(id || "")) || [];
        return queue.length ? queue.shift() : null;
      },
      hasHandle: (id) => handles.has(String(id || "")),
      handleType: (id) => {
        const entry = handles.get(String(id || ""));
        return entry ? entry.type : "";
      },
      getLastHandleId: () => lastHandleId,
      handlePropertyAt: (id, path) => {
        const entry = handles.get(String(id || ""));
        return entry ? pathResult(handleDescriptor(entry), path) : { exists: false, value: undefined };
      },
      errorCount: () => errors.length,
      lastError: () => errors.length ? errors[errors.length - 1] : null,
      popError: () => errors.length ? errors.shift() : null,
      clearErrors: () => { errors.length = 0; },
      isCommandAllowed: (command) => executeSet.has(String(command || "")) || subscribeSet.has(String(command || "")) || handlerSet.has(String(command || "")),
      isSdkPresent: () => {
        try { return !!globalThis.playmesh; } catch (_) { return false; }
      }
    };

    gdjs._playmeshExtension = runtime;
  } catch (error) {
    const failure = { code: "extension_initialization_failed", name: "Error", message: String(error && error.message ? error.message : error), stack: "" };
    safeConsoleError("[Playmesh GDevelop] " + failure.code + ": " + failure.message);
    const failedOperations = new Map();
    gdjs._playmeshExtension = {
      runtimeVersion: 2,
      surface: PLAYMESH_SDK_SURFACE,
      builtInCapabilities: PLAYMESH_BUILTIN_CAPABILITIES,
      execute: async (_command, _arguments, operationId) => {
        const id = String(operationId || "operation-failed");
        const result = { ok: false, status: "rejected", operationId: id, value: null, valueType: "null", error: failure };
        failedOperations.set(id, result);
        return result;
      },
      rejectOperation: async (operationId) => {
        const id = String(operationId || "operation-failed");
        const result = { ok: false, status: "rejected", operationId: id, value: null, valueType: "null", error: failure };
        failedOperations.set(id, result);
        return result;
      },
      subscribe: () => ({ ok: false, error: failure }),
      callSync: () => ({ ok: false, value: null, valueType: "null", error: failure }),
      registerHandler: () => ({ ok: false, error: failure }),
      respond: () => false,
      getOperation: (id) => failedOperations.get(String(id || "")) || null,
      errorCount: () => 1,
      lastError: () => failure,
      isSdkPresent: () => false,
      isCommandAllowed: () => false,
      reportWrapperError: safeConsoleError
    };
  }
})();`;

const jsEvent = (inlineCode) => ({
  type: 'BuiltinCommonInstructions::JsCode',
  inlineCode,
  parameterObjects: '',
  useStrict: true,
  eventsSheetExpanded: false,
});

// GDevelop 5.6.276 translates extension metadata through the editor's compiled
// message catalog. A locally bundled extension cannot add messages to that
// catalog at runtime, and some metadata (notably groups in libGD) is retained as
// source text. Keep all serialized identifiers in English, but make the
// canonical editor-facing fallback Chinese so it is useful offline as-is.
const containsHan = value => /[\u3400-\u9fff]/u.test(String(value || ''));

const chineseGroupSegments = new Map([
  ['Main SDK', 'Main SDK（游戏 SDK）'],
  ['App SDK', 'App SDK（原生 SDK）'],
  ['Results', 'Results（结果）'],
  ['Data', 'Data（数据）'],
  ['Resources', 'Resources（资源）'],
  ['Diagnostics', 'Diagnostics（诊断）'],
  ['Game info', '游戏信息'],
  ['Session', '会话'],
  ['Player', '玩家'],
  ['Game', '游戏'],
  ['Authority', '权威端'],
  ['RPC', '请求响应'],
  ['Binary', '二进制通信'],
  ['Sync', '状态同步'],
  ['Lifecycle', '生命周期'],
  ['Storage', '存储'],
  ['Availability', '可用性'],
  ['Identity', '身份'],
  ['Runtime', '运行环境'],
  ['Performance', '性能'],
  ['Capabilities', '能力注册表'],
  ['Capability registry', '能力注册表'],
  ['Dynamic capability (advanced)', '动态能力（高级）'],
  ['Advanced JSON', '高级 JSON'],
  ['Media', '媒体会话'],
  ['Device', '设备环境'],
  ['Device environment', '设备环境'],
  ['Microphone', '麦克风'],
  ['Vibration', '震动'],
  ['6DoF', '6DoF 空间位姿'],
  ['Camera', '摄像头'],
  ['MIDI', 'MIDI'],
  ['UI', '界面'],
  ['LAN', '局域网'],
  ['Operations', '操作结果'],
  ['Events', '事件'],
  ['Requests', '回调请求'],
  ['Handles', '句柄'],
  ['Errors', '错误'],
  ['JSON', 'JSON 数据'],
  ['Binary and files', '二进制与文件'],
  ['SDK', 'SDK 状态'],
]);

const localizeGroup = group => String(group || '')
  .split(' ❯ ')
  .map(segment => {
    if (!segment || containsHan(segment)) return segment;
    const translated = chineseGroupSegments.get(segment);
    if (!translated) throw new Error(`Missing Chinese group label for: ${segment}`);
    return translated;
  })
  .join(' ❯ ');

const chineseFunctionFullNames = new Map([
  ['IsSdkPresent', '当前上下文存在 Playmesh SDK'],
  ['OperationFinished', 'Playmesh 操作已完成'],
  ['OperationSucceeded', 'Playmesh 操作成功'],
  ['OperationFailed', 'Playmesh 操作失败'],
  ['OperationValueExists', '操作结果中的 JSON 路径存在'],
  ['OperationValueIsNull', '操作结果值为 null'],
  ['OperationValueType', 'Playmesh 操作结果值类型'],
  ['OperationValueEquals', '操作结果值等于 JSON'],
  ['OperationJson', '以 JSON 获取操作结果'],
  ['OperationValueJson', '以 JSON 获取操作结果路径'],
  ['OperationValueString', '以文本获取操作结果路径'],
  ['OperationValueNumber', '以数字获取操作结果路径'],
  ['CopyOperationValueToVariable', '将操作结果值复制到变量'],
  ['ForgetOperation', '忘记一个 Playmesh 操作'],
  ['LastOperationId', '最近的 Playmesh 操作 ID'],
  ['Unsubscribe', '取消订阅 Playmesh 事件'],
  ['HasSubscription', 'Playmesh 订阅存在'],
  ['HasEvent', 'Playmesh 事件已入队'],
  ['EventValueExists', '队列事件中的 JSON 路径存在'],
  ['EventCount', 'Playmesh 队列事件数量'],
  ['PeekEventJson', '以 JSON 查看最早的队列事件'],
  ['EventValueJson', '以 JSON 获取队列事件路径'],
  ['PopEventToVariable', '弹出 Playmesh 事件到变量'],
  ['ClearEvents', '清空 Playmesh 队列事件'],
  ['UnregisterHandler', '注销 Playmesh 请求处理器'],
  ['HasRequest', 'Playmesh 请求已入队'],
  ['RequestValueExists', '队列请求中的 JSON 路径存在'],
  ['RequestCount', 'Playmesh 队列请求数量'],
  ['PeekRequestJson', '以 JSON 查看最早的 Playmesh 请求'],
  ['RequestValueJson', '以 JSON 获取队列请求路径'],
  ['PopRequestToVariable', '弹出 Playmesh 请求到变量'],
  ['RespondRequest', '响应 Playmesh 回调请求'],
  ['CancelRequest', '取消 Playmesh 回调请求'],
  ['HasHandle', 'Playmesh 句柄存在'],
  ['HandlePropertyExists', '句柄描述中的 JSON 路径存在'],
  ['IsOpaqueMediaStream', '句柄是不透明媒体流'],
  ['HandleType', 'Playmesh 句柄类型'],
  ['LastHandleId', '最近的 Playmesh 句柄 ID'],
  ['HandlePropertyJson', '以 JSON 获取句柄描述路径'],
  ['CopyHandlePropertyToVariable', '将句柄描述路径复制到变量'],
  ['ReleaseHandle', '释放 Playmesh 句柄'],
  ['HasError', 'Playmesh 扩展存在错误'],
  ['ErrorCount', 'Playmesh 扩展错误数量'],
  ['LastErrorJson', '以 JSON 获取最近的 Playmesh 扩展错误'],
  ['LastErrorCode', '最近的 Playmesh 扩展错误代码'],
  ['LastErrorMessage', '最近的 Playmesh 扩展错误消息'],
  ['PopErrorToVariable', '弹出 Playmesh 扩展错误到变量'],
  ['ClearErrors', '清空 Playmesh 扩展错误'],
  ['JsonPathExists', 'JSON 路径存在'],
  ['JsonPathJson', '以 JSON 获取 JSON 路径'],
  ['JsonPathString', '以文本获取 JSON 路径'],
  ['JsonPathNumber', '以数字获取 JSON 路径'],
  ['CopyJsonPathToVariable', '将 JSON 路径复制到变量'],
  ['Utf8ToBase64', '将 UTF-8 文本转换为 Base64'],
  ['Base64ToUtf8', '将 Base64 转换为 UTF-8 文本'],
  ['Base64ToHex', '将 Base64 转换为十六进制'],
  ['HexToBase64', '将十六进制转换为 Base64'],
  ['BinaryArgumentJson', '生成二进制 SDK 参数 JSON'],
  ['VariableToBase64', '将变量字节转换为 Base64'],
  ['Base64ToVariable', '将 Base64 字节写入变量'],
  ['FileArgumentJson', '生成文件 SDK 参数 JSON'],
  ['UploadFile', '上传文件到 Playmesh 存储桶'],
  ['CreateAbortHandle', '创建媒体中止句柄'],
  ['AbortMediaOpen', '中止媒体打开操作'],
  ['OpenMedia', '打开 Playmesh 媒体源'],
]);

const chineseParameterDescriptions = new Map([
  ['AbortController handle ID.', 'AbortController 句柄 ID。'],
  ['Base64 value.', 'Base64 值。'],
  ['Destination variable.', '目标变量。'],
  ['Encoded file data.', '已编码的文件数据。'],
  ['Expected JSON value.', '期望的 JSON 值。'],
  ['File name.', '文件名。'],
  ['Handle ID.', '句柄 ID。'],
  ['Handler ID.', '处理器 ID。'],
  ['Handler or sync callback ID.', '处理器或同步回调 ID。'],
  ['Hexadecimal value.', '十六进制值。'],
  ['JSON arguments. Capability events use ["eventName"]; onError uses [].', 'JSON 参数。原生能力事件使用 ["eventName"]；onError 使用 []。'],
  ['JSON arguments. Use [] when there are no arguments.', 'JSON 参数。没有参数时使用 []。'],
  ['JSON arguments. onExit accepts {"handlerId":"cleanup","callbackTimeoutMs":15000}; other lifecycle subscriptions use [].', 'JSON 参数。onExit 可使用 {"handlerId":"cleanup","callbackTimeoutMs":15000}；其他生命周期订阅使用 []。'],
  ['JSON path, such as $.players[0].id or /players/0/id.', 'JSON 路径，例如 $.players[0].id 或 /players/0/id。'],
  ['JSON path.', 'JSON 路径。'],
  ['JSON response. Binary replace accepts a binary argument object.', 'JSON 响应。二进制 replace 模式接受二进制参数对象。'],
  ['JSON value.', 'JSON 值。'],
  ['MIME type.', 'MIME 类型。'],
  ['Operation ID.', '操作 ID。'],
  ['Optional AbortController handle ID.', '可选的 AbortController 句柄 ID。'],
  ['PlaymeshAppMediaSource handle ID.', 'PlaymeshAppMediaSource 句柄 ID。'],
  ['PlaymeshStorageBucket handle ID.', 'PlaymeshStorageBucket 句柄 ID。'],
  ['Preferred handle ID, or empty to generate one.', '首选句柄 ID；留空则自动生成。'],
  ['Request ID from the queued record.', '队列记录中的请求 ID。'],
  ['Request ID.', '请求 ID。'],
  ['Returned-object handle ID, or empty for root SDK commands.', '返回对象的句柄 ID；调用 SDK 根命令时留空。'],
  ['Returned-object handle ID, when required.', '需要时填写返回对象的句柄 ID。'],
  ['Source variable.', '源变量。'],
  ['Subscription ID.', '订阅 ID。'],
  ['Text, base64, hex, or a JSON byte array.', '文本、Base64、十六进制或 JSON 字节数组。'],
  ['UTF-8 text.', 'UTF-8 文本。'],
  ['result, next, keep, pass, void, null, replace, or reject.', '可选模式：result、next、keep、pass、void、null、replace 或 reject。'],
  ['text, base64, hex, or bytes.', '可选编码：text、base64、hex 或 bytes。'],
  ['utf8, base64, hex, or bytes.', '可选编码：utf8、base64、hex 或 bytes。'],
]);

const localizeParameterDescription = description => {
  const source = String(description || '');
  if (!source || containsHan(source)) return source;
  const commandOrProperty = /^A (.+) (command|property)\.$/u.exec(source);
  if (commandOrProperty) {
    return `${localizeGroup(commandOrProperty[1])}中允许的${commandOrProperty[2] === 'command' ? '命令' : '属性'}。`;
  }
  return chineseParameterDescriptions.get(source) || `参数说明：${source}`;
};

const localizeDescription = (fullName, description) => {
  const source = String(description || '');
  if (!source) return fullName;
  if (containsHan(source)) return source;
  return `用于“${fullName}”。技术说明：${source}`;
};

const localizeSentence = (fullName, sentence) => {
  const source = String(sentence || '');
  if (!source || containsHan(source)) return source;
  return `${fullName}：${source}`;
};

const parameter = (name, type, description, supplementaryInformation, options = {}) => {
  const value = { description: localizeParameterDescription(description), name, type };
  if (supplementaryInformation) value.supplementaryInformation = supplementaryInformation;
  if (options.optional === true) value.optional = true;
  if (Object.prototype.hasOwnProperty.call(options, 'defaultValue')) {
    value.defaultValue = type === 'expression'
      ? String(options.defaultValue)
      : type === 'yesorno' || type === 'trueorfalse'
        ? options.defaultValue ? 'yes' : 'no'
        : JSON.stringify(String(options.defaultValue));
  }
  return value;
};

const semanticGroupAliases = new Map([
  ['Operations', 'Results ❯ Operations'],
  ['Event subscriptions', 'Results ❯ Events'],
  ['Request handlers', 'Results ❯ Requests'],
  ['Handles', 'Resources ❯ Handles'],
  ['Errors', 'Diagnostics ❯ Errors'],
  ['JSON paths', 'Data ❯ JSON'],
  ['Binary and files', 'Data ❯ Binary and files'],
  ['Media', 'Resources ❯ Media'],
]);

const eventFunction = ({
  name,
  fullName,
  description,
  group,
  functionType = 'Action',
  sentence = '',
  parameters = [],
  code,
  async = false,
  private: isPrivate = false,
  expressionType,
}) => {
  const sourceFullName = fullName === undefined ? name : fullName;
  const visibleFullName = isPrivate || !sourceFullName
    ? sourceFullName
    : containsHan(sourceFullName)
      ? sourceFullName
      : chineseFunctionFullNames.get(name);
  if (!isPrivate && !visibleFullName) {
    throw new Error(`Missing Chinese function label for: ${name}`);
  }
  const sourceGroup = semanticGroupAliases.get(group) || group || '';
  const value = {
    description: isPrivate ? (description || '') : localizeDescription(visibleFullName, description),
    fullName: visibleFullName,
    functionType,
    group: isPrivate ? sourceGroup : localizeGroup(sourceGroup),
    name,
    sentence: isPrivate ? sentence : localizeSentence(visibleFullName, sentence),
    events: [jsEvent(code)],
    parameters,
    objectGroups: [],
  };
  if (async) value.async = true;
  if (isPrivate) value.private = true;
  if (expressionType) value.expressionType = expressionType;
  return value;
};

const extensionGuard = (fallback, expression) => String.raw`const extension = gdjs._playmeshExtension;
try {
  if (!extension) throw new Error("Playmesh extension runtime is unavailable.");
  ${expression}
} catch (error) {
  if (extension && extension.reportWrapperError) extension.reportWrapperError(error, "event function");
  else { try { console.error(error); } catch (_) {} }
  ${fallback}
}`;

const asyncGuard = (expression) => String.raw`const extension = gdjs._playmeshExtension;
let promise = Promise.resolve();
try {
  if (!extension) throw new Error("Playmesh extension runtime is unavailable.");
  promise = Promise.resolve(${expression});
} catch (error) {
  if (extension && extension.reportWrapperError) extension.reportWrapperError(error, "async event function");
}
eventsFunctionContext.task = new gdjs.PromiseTask(Promise.resolve(promise).then(
  () => undefined,
  (error) => {
    if (extension && extension.reportWrapperError) extension.reportWrapperError(error, "async event function");
    return undefined;
  }
));`;

const stringExpression = { type: 'string' };
const numberExpression = { type: 'expression' };
const stringParam = (name, description, selector, options = {}) => parameter(name, selector ? 'stringWithSelector' : 'string', description, selector ? JSON.stringify(selector) : undefined, options);
const numberParam = (name, description, options = {}) => parameter(name, 'expression', description, undefined, options);
const booleanParam = (name, description, options = {}) => parameter(name, 'yesorno', description, undefined, options);
const variableParam = (name, description, options = {}) => parameter(name, 'variable', description, undefined, options);

const commandGroups = [
  { id: 'MainGameInfo', group: 'Main SDK ❯ Game info', matches: command => command.startsWith('playmesh.main.gameInfo.'), properties: ['playmesh.main.version'] },
  { id: 'MainSession', group: 'Main SDK ❯ Session', matches: command => command.startsWith('playmesh.main.session.'), properties: [] },
  { id: 'MainPlayer', group: 'Main SDK ❯ Player', matches: command => command.startsWith('playmesh.main.player.'), properties: [] },
  { id: 'MainGame', group: 'Main SDK ❯ Game', matches: command => command.startsWith('playmesh.main.game.'), properties: [] },
  { id: 'MainAuthority', group: 'Main SDK ❯ Authority', matches: command => command.startsWith('playmesh.main.authority.'), properties: ['playmesh.main.authority.defaultNamespace'] },
  { id: 'MainRpc', group: 'Main SDK ❯ RPC', matches: command => command.startsWith('playmesh.main.rpc.'), properties: [] },
  { id: 'MainBinary', group: 'Main SDK ❯ Binary', matches: command => command.startsWith('playmesh.main.binary.') || command.startsWith('PlaymeshBinaryChannel.'), properties: ['playmesh.main.binary.authorityPlayerId', 'PlaymeshBinaryChannel.id', 'PlaymeshBinaryChannel.mode'] },
  { id: 'MainSync', group: 'Main SDK ❯ Sync', matches: command => command.startsWith('playmesh.main.sync.') || command.startsWith('PlaymeshSyncAuthorityController.'), properties: [] },
  { id: 'MainLifecycle', group: 'Main SDK ❯ Lifecycle', matches: command => command.startsWith('playmesh.main.lifecycle.'), properties: [] },
  { id: 'MainStorage', group: 'Main SDK ❯ Storage', matches: command => command.startsWith('playmesh.main.storage.') || command.startsWith('PlaymeshStorageBucket.'), properties: [] },
  { id: 'AppAvailability', group: 'App SDK ❯ Availability', matches: command => command === 'playmesh.app.isAvailable', properties: ['playmesh.app.version'] },
  { id: 'AppIdentity', group: 'App SDK ❯ Identity', matches: command => command.startsWith('playmesh.app.identity.'), properties: [] },
  { id: 'AppRuntime', group: 'App SDK ❯ Runtime', matches: command => command.startsWith('playmesh.app.runtime.'), properties: [] },
  { id: 'AppStorage', group: 'App SDK ❯ Storage', matches: command => command.startsWith('playmesh.app.storage.') || command.startsWith('PlaymeshAppStorageBucket.'), properties: [] },
  { id: 'AppPerformance', group: 'App SDK ❯ Performance', matches: command => command.startsWith('playmesh.app.performance.'), properties: [] },
  { id: 'AppCapabilities', group: 'App SDK ❯ Capabilities', matches: command => command.startsWith('playmesh.app.capabilities.') || command.startsWith('PlaymeshCapabilityHandle.'), properties: ['PlaymeshCapabilityHandle.id', 'PlaymeshCapabilityHandle.code', 'PlaymeshCapabilityHandle.apiVersion'] },
  { id: 'AppMedia', group: 'App SDK ❯ Media', matches: command => command.startsWith('playmesh.app.media.') || command.startsWith('PlaymeshAppMediaSession.'), properties: ['PlaymeshAppMediaSession.id', 'PlaymeshAppMediaSession.source', 'PlaymeshAppMediaSession.state', 'PlaymeshAppMediaSession.stream'] },
  { id: 'AppDevice', group: 'App SDK ❯ Device', matches: command => command.startsWith('playmesh.app.device.'), properties: [] },
  { id: 'AppUi', group: 'App SDK ❯ UI', matches: command => command.startsWith('playmesh.app.ui.'), properties: [] },
  { id: 'AppLan', group: 'App SDK ❯ LAN', matches: command => command.startsWith('playmesh.app.lan.') || command.startsWith('PlaymeshLanGame.'), properties: ['PlaymeshLanGame.instanceId', 'PlaymeshLanGame.gameId', 'PlaymeshLanGame.name', 'PlaymeshLanGame.host'] },
].map(definition => ({
  ...definition,
  execute: executeCommands.filter(definition.matches),
  subscribe: subscribeCommands.filter(definition.matches),
  handler: handlerCommands.filter(definition.matches),
}));

const groupedCallableCommands = commandGroups.flatMap(definition => [...definition.execute, ...definition.subscribe, ...definition.handler]);
if (groupedCallableCommands.length !== callableCommands.length || new Set(groupedCallableCommands).size !== callableCommands.length || callableCommands.some(command => !groupedCallableCommands.includes(command))) {
  throw new Error('Every Playmesh callable must belong to exactly one semantic command group.');
}

const semanticCommandFunctions = commandGroups.flatMap(definition => {
  const functions = [];
  const makeCommandFunction = (kind, commands, idLabel) => {
    if (commands.length === 0) return;
    const name = kind === 'Register' ? `Register${definition.id}Handler` : `${kind}${definition.id}`;
    const displayKind = kind === 'Register' ? '注册处理器：' : kind === 'Subscribe' ? '订阅' : '调用';
    const visibleGroup = localizeGroup(definition.group);
    const operationName = idLabel || 'OperationId';
    const argumentsDescription = definition.id === 'MainLifecycle' && kind === 'Subscribe'
      ? 'JSON 参数。onExit 可使用 {"handlerId":"cleanup","callbackTimeoutMs":15000}；其他生命周期订阅使用 []。'
      : definition.id === 'AppCapabilities' && kind === 'Subscribe'
        ? 'JSON 参数。原生能力事件使用 ["eventName"]；onError 使用 []。'
        : 'JSON 参数。没有参数时使用 []。';
    functions.push(eventFunction({
      name,
      fullName: `${displayKind}${visibleGroup.replace(' ❯ ', ' ')}`,
      description: `${displayKind}${visibleGroup}中一个允许的命令。参数使用 JSON；失败会被记录，异步动作始终结束。`,
      group: definition.group,
      sentence: `${displayKind}命令 _PARAM1_，JSON 参数 _PARAM2_，句柄 _PARAM3_，结果 ID _PARAM4_`,
      async: true,
      parameters: [
        stringParam('Command', `${visibleGroup}中允许的命令。`, commands),
        stringParam('ArgumentsJson', argumentsDescription),
        stringParam('HandleId', '返回对象的句柄 ID；调用 SDK 根命令时留空。'),
        stringParam(operationName, `${operationName === 'SubscriptionId' ? '订阅' : operationName === 'HandlerId' ? '处理器' : '操作'} ID。`),
      ],
      code: asyncGuard(`extension.execute(eventsFunctionContext.getArgument("Command"), eventsFunctionContext.getArgument("ArgumentsJson"), eventsFunctionContext.getArgument("${operationName}"), eventsFunctionContext.getArgument("HandleId"))`),
      private: true,
    }));
  };
  makeCommandFunction('Call', definition.execute, 'OperationId');
  makeCommandFunction('Subscribe', definition.subscribe, 'SubscriptionId');
  makeCommandFunction('Register', definition.handler, 'HandlerId');
  if (definition.properties.length > 0) {
    const visibleGroup = localizeGroup(definition.group);
    functions.push(eventFunction({
      name: `Read${definition.id}Property`,
      fullName: `读取${visibleGroup.replace(' ❯ ', ' ')}属性`,
      description: `读取${visibleGroup}中一个允许的属性，并将结果保存为操作。`,
      group: definition.group,
      sentence: '读取属性 _PARAM1_，句柄 _PARAM2_，操作 ID _PARAM3_',
      parameters: [stringParam('Property', `${visibleGroup}中允许的属性。`, definition.properties), stringParam('HandleId', '需要时填写返回对象的句柄 ID。'), stringParam('OperationId', '操作 ID。')],
      code: extensionGuard('', 'extension.readProperty(eventsFunctionContext.getArgument("Property"), eventsFunctionContext.getArgument("HandleId"), eventsFunctionContext.getArgument("OperationId"));'),
      private: true,
    }));
  }
  return functions;
});

const argumentCode = name => `eventsFunctionContext.getArgument(${JSON.stringify(name)})`;
const variableCode = name => `extension.readVariable(${argumentCode(name)})`;
const binaryCode = (encodingName = 'Encoding', dataName = 'Data', bytesName = 'Bytes') => `(() => { const encoding = String(${argumentCode(encodingName)} || "base64"); return { $binary: { encoding, data: encoding === "bytes" ? ${variableCode(bytesName)} : ${argumentCode(dataName)} } }; })()`;
const fileCode = () => `(() => { const encoding = String(${argumentCode('Encoding')} || "text"); return { $file: { name: ${argumentCode('FileName')}, type: ${argumentCode('MimeType')}, encoding, data: encoding === "bytes" ? ${variableCode('Bytes')} : ${argumentCode('Data')} } }; })()`;

const requiredString = (name, description, selector) => stringParam(name, description, selector);
const optionalString = (name, description, selector, defaultValue = '') => stringParam(name, description, selector, { optional: true, defaultValue });
const requiredNumber = (name, description) => numberParam(name, description);
const optionalNumber = (name, description, defaultValue = 0) => numberParam(name, description, { optional: true, defaultValue });
const requiredBoolean = (name, description) => booleanParam(name, description);
const requiredVariable = (name, description) => variableParam(name, description);
const optionalOperationId = () => optionalString('OperationId', '可选诊断操作 ID；留空时自动生成。');
const resultVariable = description => requiredVariable('Result', description || '接收调用结果的变量；返回句柄时包含 handleId。');
const handleIdParameter = (description = '由前一个 Playmesh 调用返回的句柄 ID。') => requiredString('HandleId', description);
const binaryParameters = () => [
  requiredString('Encoding', '二进制编码。bytes 模式从 Bytes 变量读取。', ['utf8', 'base64', 'hex', 'bytes']),
  optionalString('Data', 'UTF-8、Base64 或十六进制数据；bytes 模式忽略此值。'),
  requiredVariable('Bytes', 'bytes 模式的 0～255 数组变量；其他模式忽略此变量。'),
];

const typedExecuteSpecs = [
  {
    command: 'playmesh.main.gameInfo.getCurrent', name: 'GetCurrentGameInfo', group: 'Main SDK ❯ Game info', label: '获取当前游戏信息',
    description: '获取当前页面的游戏声明；未就绪时结果为 null。', result: '将游戏信息对象或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.session.isAuthority', name: 'GetIsAuthority', group: 'Main SDK ❯ Session', label: '获取当前页面是否为 Authority',
    description: '获取当前页面的固定 Authority 身份。', result: '将布尔结果写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.session.getCurrent', name: 'GetCurrentSession', group: 'Main SDK ❯ Session', label: '获取当前会话快照',
    description: '获取最近会话快照；没有多人会话时结果为 null。', result: '将会话快照或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.session.start', name: 'StartSession', group: 'Main SDK ❯ Session', label: '请求启动会话',
    description: '请求 Core 切换到运行状态并返回会话快照。', result: '将启动后的会话快照写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.session.finish', name: 'FinishSession', group: 'Main SDK ❯ Session', label: '请求结束会话',
    description: '在游戏规则确认结束后请求停止会话并返回会话快照。', result: '将结束后的会话快照写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.player.getCurrent', name: 'GetCurrentPlayer', group: 'Main SDK ❯ Player', label: '获取当前玩家',
    description: '获取当前参与玩家；公共主屏和单机分享页返回 null。', result: '将玩家对象或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.player.setNickname', name: 'SetPlayerNickname', group: 'Main SDK ❯ Player', label: '修改当前玩家昵称',
    description: '修改当前玩家昵称；去除首尾空白后必须为 1～32 个字符。', parameters: [requiredString('Nickname', '新的玩家昵称，1～32 个字符。')], result: '将更新后的玩家对象写入变量。', args: `[${argumentCode('Nickname')}]`,
  },
  {
    command: 'playmesh.main.game.submitAction', name: 'SubmitGameAction', group: 'Main SDK ❯ Game', label: '向 Authority 提交游戏动作',
    description: '提交任意可传输 JSON 动作；可选 namespace 只用于路由隔离。',
    parameters: [requiredVariable('Action', '游戏动作 JSON 变量。'), requiredBoolean('UseNamespace', '是否显式传入 namespace。'), optionalString('Namespace', '路由 namespace；UseNamespace 为否时真正省略。')],
    result: '将 Authority 返回值写入变量。',
    args: `(() => { const values = [${variableCode('Action')}]; if (${argumentCode('UseNamespace')}) values.push({ namespace: ${argumentCode('Namespace')} }); return values; })()`,
  },
  {
    command: 'playmesh.main.rpc.request', name: 'RequestAuthorityRpc', group: 'Main SDK ❯ RPC', label: '向 Authority 请求路径数据',
    description: '通过认证二进制通道请求 Authority；数据变量可包含 JSON、$binary 或 $file 参数。',
    parameters: [requiredString('Path', 'Authority 监听的精确 RPC path。'), requiredVariable('Data', 'JSON、$binary 或 $file 请求数据。'), requiredBoolean('UseTimeout', '是否显式设置请求超时。'), optionalNumber('TimeoutMs', '请求等待毫秒数，100～60000。', 10000)],
    result: '将 Authority 返回的 JSON、$binary 或 $file 数据写入变量。',
    args: `(() => { const values = [${argumentCode('Path')}, ${variableCode('Data')}]; if (${argumentCode('UseTimeout')}) values.push({ timeoutMs: ${argumentCode('TimeoutMs')} }); return values; })()`,
  },
  {
    command: 'playmesh.main.binary.createChannel', name: 'CreateBinaryChannel', group: 'Main SDK ❯ Binary', label: '创建二进制通道',
    description: '仅 Authority 创建 authority 审核或 relay 直传通道。', parameters: [requiredString('Mode', '二进制通道模式。', ['authority', 'relay'])], result: '将通道描述和 handleId 写入变量。', args: `[{ mode: ${argumentCode('Mode')} }]`,
  },
  {
    command: 'playmesh.main.binary.joinChannel', name: 'JoinBinaryChannel', group: 'Main SDK ❯ Binary', label: '加入二进制通道',
    description: '使用 Authority 分享的 Channel ID 加入通道。', parameters: [requiredString('ChannelId', '要加入的二进制 Channel ID。')], result: '将通道描述和 handleId 写入变量。', args: `[${argumentCode('ChannelId')}]`,
  },
  {
    command: 'playmesh.main.sync.startAuthority', name: 'StartAuthoritySync', group: 'Main SDK ❯ Sync', label: '启动 Authority 状态同步',
    description: '以初始状态启动同步；onInput/onTick 可桥接成可响应请求。',
    parameters: [
      requiredVariable('InitialState', '首个完整权威状态变量。'),
      requiredBoolean('UseStateType', '是否显式传入状态类型。'), optionalString('StateType', '状态类型；默认 game。', undefined, 'game'),
      requiredBoolean('UseTickRate', '是否显式传入每秒 tick 次数。'), optionalNumber('TickRate', '每秒 tick 次数，1～20；默认 10。', 10),
      requiredBoolean('UseOnInputHandler', '是否将 onInput 回调桥接到请求队列。'), optionalString('OnInputHandlerId', '接收 onInput 请求的处理器 ID。'),
      requiredBoolean('UseOnTickHandler', '是否将 onTick 回调桥接到请求队列。'), optionalString('OnTickHandlerId', '接收 onTick 请求的处理器 ID。'),
      requiredBoolean('UseCallbackTimeout', '是否显式设置回调超时。'), optionalNumber('CallbackTimeoutMs', '回调请求超时毫秒数，100～60000。', 15000),
    ],
    result: '将同步控制器描述和 handleId 写入变量。',
    args: `(() => { const options = { initialState: ${variableCode('InitialState')} }; if (${argumentCode('UseStateType')}) options.stateType = ${argumentCode('StateType')}; if (${argumentCode('UseTickRate')}) options.tickRate = ${argumentCode('TickRate')}; if (${argumentCode('UseOnInputHandler')}) options.onInputHandlerId = ${argumentCode('OnInputHandlerId')}; if (${argumentCode('UseOnTickHandler')}) options.onTickHandlerId = ${argumentCode('OnTickHandlerId')}; if (${argumentCode('UseCallbackTimeout')}) options.callbackTimeoutMs = ${argumentCode('CallbackTimeoutMs')}; return [options]; })()`,
  },
  {
    command: 'playmesh.main.sync.submitAction', name: 'SubmitSyncAction', group: 'Main SDK ❯ Sync', label: '提交一次性同步输入',
    description: '提交一次性语义输入并返回 input ID。', parameters: [requiredVariable('Payload', '一次性同步输入 JSON 变量。')], result: '将 input ID 写入变量。', args: `[${variableCode('Payload')}]`,
  },
  {
    command: 'playmesh.main.sync.submitState', name: 'SubmitSyncState', group: 'Main SDK ❯ Sync', label: '提交可合并同步状态输入',
    description: '同一 key 只保留最新连续输入；可选 rateHz 为 1～20。',
    parameters: [requiredString('Key', '连续输入 key，1～64 个允许字符。'), requiredVariable('Value', '连续输入值 JSON 变量。'), requiredBoolean('UseRateHz', '是否显式传入发送频率。'), optionalNumber('RateHz', '每秒最大发送次数，1～20。', 20)],
    result: '将 SDK 的 null 结果写入变量。',
    args: `(() => { const values = [${argumentCode('Key')}, ${variableCode('Value')}]; if (${argumentCode('UseRateHz')}) values.push({ rateHz: ${argumentCode('RateHz')} }); return values; })()`,
  },
  {
    command: 'playmesh.main.sync.requestSnapshot', name: 'RequestSyncSnapshot', group: 'Main SDK ❯ Sync', label: '请求最新同步快照',
    description: '请求 Authority 立即发送最新完整快照。', result: '将请求 input ID 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.sync.getSnapshot', name: 'GetLatestSyncSnapshot', group: 'Main SDK ❯ Sync', label: '获取最近同步快照',
    description: '获取最近完整快照；尚未收到时为 null。', result: '将同步快照或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.main.storage.getBucket', name: 'GetStorageBucket', group: 'Main SDK ❯ Storage', label: '获取存储桶句柄',
    description: '获取 Authority 主机上的持久 JSON Bucket。', parameters: [requiredString('Bucket', '存储桶逻辑名称。')], result: '将存储桶 handleId 写入变量。', args: `[${argumentCode('Bucket')}]`,
  },
  {
    command: 'PlaymeshBinaryChannel.send', name: 'BroadcastBinary', group: 'Main SDK ❯ Binary', label: '可靠广播编码二进制帧',
    description: '以 UTF-8、Base64 或十六进制编码向通道内其他在线成员可靠广播。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredString('Encoding', '输入编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '对应编码的帧数据。')],
    args: `[{ $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId',
  },
  {
    command: 'PlaymeshBinaryChannel.sendLatest', name: 'BroadcastLatestBinary', group: 'Main SDK ❯ Binary', label: '广播最新编码二进制帧',
    description: '以 UTF-8、Base64 或十六进制编码广播可被新帧替换的最新帧。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredString('Encoding', '输入编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '对应编码的帧数据。')],
    args: `[{ $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId',
  },
  { command: 'PlaymeshBinaryChannel.close', name: 'CloseBinaryChannel', group: 'Main SDK ❯ Binary', label: '关闭二进制通道', description: '关闭整个通道；只有 Authority 可以调用。', parameters: [handleIdParameter('二进制通道 handleId。')], args: '[]', handle: 'HandleId', void: true },
  { command: 'PlaymeshSyncAuthorityController.getState', name: 'GetAuthoritySyncState', group: 'Main SDK ❯ Sync', label: '获取 Authority 当前同步状态', description: '获取同步 runtime 当前公共状态的 JSON 副本。', parameters: [handleIdParameter('同步控制器 handleId。')], result: '将当前状态写入变量。', args: '[]', handle: 'HandleId' },
  {
    command: 'PlaymeshSyncAuthorityController.setState', name: 'SetAuthoritySyncState', group: 'Main SDK ❯ Sync', label: '替换 Authority 同步状态', description: '整体替换公共状态；可选择是否等待对应自动发布。',
    parameters: [handleIdParameter('同步控制器 handleId。'), requiredVariable('State', '新的完整公共状态变量。'), requiredBoolean('UsePublish', '是否显式传入 publish。'), booleanParam('Publish', '是否等待对应自动发布；默认 true。', { optional: true, defaultValue: true })],
    result: '将发布快照或 null 写入变量。', args: `(() => { const values = [${variableCode('State')}]; if (${argumentCode('UsePublish')}) values.push(${argumentCode('Publish')}); return values; })()`, handle: 'HandleId',
  },
  {
    command: 'PlaymeshSyncAuthorityController.publish', name: 'PublishCurrentAuthoritySyncState', group: 'Main SDK ❯ Sync', label: '广播当前 Authority 同步状态', description: '立即向默认接收者发布当前公共状态。',
    parameters: [handleIdParameter('同步控制器 handleId。')], result: '将发布快照或 null 写入变量。', args: `({ hasState: false })`, handle: 'HandleId',
  },
  { command: 'PlaymeshSyncAuthorityController.stop', name: 'StopAuthoritySync', group: 'Main SDK ❯ Sync', label: '停止 Authority 状态同步', description: '停止 tick、runtime 与尚未执行的自动发布任务。', parameters: [handleIdParameter('同步控制器 handleId。')], args: '[]', handle: 'HandleId', void: true },
  { command: 'PlaymeshStorageBucket.getData', name: 'GetBucketData', group: 'Main SDK ❯ Storage', label: '异步读取存储桶数据', description: '异步读取 key；不存在时结果为 null。', parameters: [handleIdParameter('存储桶 handleId。'), requiredString('Key', '存储 key，1～128 个允许字符。')], result: '将 JSON 值或 null 写入变量。', args: `[${argumentCode('Key')}]`, handle: 'HandleId' },
  { command: 'PlaymeshStorageBucket.setData', name: 'SetBucketData', group: 'Main SDK ❯ Storage', label: '异步写入存储桶数据', description: '异步写入一个 JSON 值。', parameters: [handleIdParameter('存储桶 handleId。'), requiredString('Key', '存储 key，1～128 个允许字符。'), requiredVariable('Value', '要写入的 JSON 值变量。')], args: `[${argumentCode('Key')}, ${variableCode('Value')}]`, handle: 'HandleId', void: true },
  { command: 'PlaymeshStorageBucket.getDataSync', name: 'GetBucketDataSync', group: 'Main SDK ❯ Storage', label: '同步读取存储桶数据', description: '通过同源 Bucket 网关阻塞读取；不存在时为 null。', parameters: [handleIdParameter('存储桶 handleId。'), requiredString('Key', '存储 key，1～128 个允许字符。')], result: '将 JSON 值或 null 写入变量。', args: `[${argumentCode('Key')}]`, handle: 'HandleId' },
  { command: 'PlaymeshStorageBucket.setDataSync', name: 'SetBucketDataSync', group: 'Main SDK ❯ Storage', label: '同步写入存储桶数据', description: '通过同源 Bucket 网关阻塞写入 JSON。', parameters: [handleIdParameter('存储桶 handleId。'), requiredString('Key', '存储 key，1～128 个允许字符。'), requiredVariable('Value', '要写入的 JSON 值变量。')], args: `[${argumentCode('Key')}, ${variableCode('Value')}]`, handle: 'HandleId', void: true },
  { command: 'PlaymeshStorageBucket.removeData', name: 'RemoveBucketData', group: 'Main SDK ❯ Storage', label: '删除存储桶数据', description: '删除指定 key。', parameters: [handleIdParameter('存储桶 handleId。'), requiredString('Key', '要删除的存储 key。')], args: `[${argumentCode('Key')}]`, handle: 'HandleId', void: true },
  { command: 'PlaymeshStorageBucket.clearData', name: 'ClearBucketData', group: 'Main SDK ❯ Storage', label: '清空存储桶', description: '清空当前 Bucket，不影响其他 Bucket。', parameters: [handleIdParameter('存储桶 handleId。')], args: '[]', handle: 'HandleId', void: true },
  {
    command: 'PlaymeshStorageBucket.upload', name: 'UploadBucketEncodedFile', group: 'Main SDK ❯ Storage', label: '上传编码文件到存储桶', description: '从文本、Base64 或十六进制数据创建 File 并上传。',
    parameters: [handleIdParameter('存储桶 handleId。'), requiredString('FileName', '上传文件名。'), requiredString('MimeType', '文件 MIME 类型。'), requiredString('Encoding', '文件数据编码。', ['text', 'base64', 'hex']), requiredString('Data', '对应编码的文件数据。')],
    result: '将上传后的同源 URL 写入变量。', args: `[{ $file: { name: ${argumentCode('FileName')}, type: ${argumentCode('MimeType')}, encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId',
  },
];

typedExecuteSpecs.push(
  {
    command: 'playmesh.app.isAvailable', name: 'GetAppAvailability', group: 'App SDK ❯ Availability', label: '获取原生 App Bridge 是否可用',
    description: '获取当前页面是否运行在具有原生宿主能力的 Playmesh WebView 中。', result: '将布尔可用性写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.identity.getCurrent', name: 'GetAppIdentity', group: 'App SDK ❯ Identity', label: '获取当前 App 身份',
    description: '获取 App 自动注入的当前用户；普通浏览器为 null。', result: '将身份对象或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.runtime.getLocale', name: 'GetAppLocale', group: 'App SDK ❯ Runtime', label: '获取 App 显示语言',
    description: '获取实际显示当前页面的 locale。', result: '将 locale 文本写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.storage.getBucket', name: 'GetAppStorageBucket', group: 'App SDK ❯ Storage', label: '获取当前设备存储桶句柄',
    description: '获取只属于当前设备、不会通过 Authority 或会话共享的 JSON Bucket。', parameters: [requiredString('Bucket', '存储桶名称；同步接口还支持 GDevelop 等运行时使用的逻辑名称。')], result: '将当前设备存储桶 handleId 写入变量。', args: `[${argumentCode('Bucket')}]`,
  },
  { command: 'PlaymeshAppStorageBucket.getData', name: 'GetAppBucketData', group: 'App SDK ❯ Storage', label: '读取当前设备存储桶数据', description: '异步读取当前设备上的 key；不存在时结果为 null。', parameters: [handleIdParameter('当前设备存储桶 handleId。'), requiredString('Key', '存储 key，1～128 个允许字符。')], result: '将 JSON 值或 null 写入变量。', args: `[${argumentCode('Key')}]`, handle: 'HandleId' },
  { command: 'PlaymeshAppStorageBucket.setData', name: 'SetAppBucketData', group: 'App SDK ❯ Storage', label: '写入当前设备存储桶数据', description: '异步写入一个只保存在当前设备的 JSON 值。', parameters: [handleIdParameter('当前设备存储桶 handleId。'), requiredString('Key', '存储 key，1～128 个允许字符。'), requiredVariable('Value', '要写入的 JSON 值变量。')], args: `[${argumentCode('Key')}, ${variableCode('Value')}]`, handle: 'HandleId', void: true },
  { command: 'PlaymeshAppStorageBucket.getDataSync', name: 'GetAppBucketDataSync', group: 'App SDK ❯ Storage', label: '同步读取当前设备存储桶数据', description: '同步读取当前设备上的 JSON 值；不存在时结果为 null。', parameters: [handleIdParameter('当前设备存储桶 handleId。'), requiredString('Key', '存储 key；运行时保留 key 由对应接线内部使用。')], result: '将 JSON 值或 null 写入变量。', args: `[${argumentCode('Key')}]`, handle: 'HandleId' },
  { command: 'PlaymeshAppStorageBucket.setDataSync', name: 'SetAppBucketDataSync', group: 'App SDK ❯ Storage', label: '同步写入当前设备存储桶数据', description: '同步写入一个只保存在当前设备的 JSON 值。', parameters: [handleIdParameter('当前设备存储桶 handleId。'), requiredString('Key', '存储 key；运行时保留 key 由对应接线内部使用。'), requiredVariable('Value', '要写入的 JSON 值变量。')], args: `[${argumentCode('Key')}, ${variableCode('Value')}]`, handle: 'HandleId', void: true },
  { command: 'PlaymeshAppStorageBucket.removeData', name: 'RemoveAppBucketData', group: 'App SDK ❯ Storage', label: '删除当前设备存储桶数据', description: '删除当前设备存储桶中的指定 key。', parameters: [handleIdParameter('当前设备存储桶 handleId。'), requiredString('Key', '要删除的存储 key。')], args: `[${argumentCode('Key')}]`, handle: 'HandleId', void: true },
  { command: 'PlaymeshAppStorageBucket.clearData', name: 'ClearAppBucketData', group: 'App SDK ❯ Storage', label: '清空当前设备存储桶', description: '清空当前设备上的当前 Bucket，不影响 Main Bucket。', parameters: [handleIdParameter('当前设备存储桶 handleId。')], args: '[]', handle: 'HandleId', void: true },
  {
    command: 'playmesh.app.performance.getFps', name: 'GetAppFps', group: 'App SDK ❯ Performance', label: '获取最近 FPS',
    description: '获取最近 FPS；尚未形成统计窗口时为 null。', result: '将 FPS 或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.performance.getLatency', name: 'GetAppLatency', group: 'App SDK ❯ Performance', label: '获取最近网络延迟',
    description: '获取当前参与端到 Authority 的平滑 RTT 毫秒数；不可用时为 null。', result: '将延迟毫秒数或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.performance.getLatencyDiagnostics', name: 'GetAppLatencyDiagnostics', group: 'App SDK ❯ Performance', label: '获取延迟诊断数据',
    description: '获取开放结构的最近延迟探测诊断数据；不得用于权威玩法判定。', result: '将诊断对象或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.performance.setVisible', name: 'SetAppPerformanceVisible', group: 'App SDK ❯ Performance', label: '设置性能浮层可见性',
    description: '显示或隐藏当前客户端的 SDK 性能浮层。', parameters: [requiredBoolean('Visible', '是否显示性能浮层。')], args: `[${argumentCode('Visible')}]`, void: true,
  },
  {
    command: 'playmesh.app.performance.reportFrame', name: 'ReportAppFrame', group: 'App SDK ❯ Performance', label: '报告一帧已完成',
    description: '在真实画面完成后报告一帧；可省略时间戳让 SDK 使用当前时钟。', parameters: [requiredBoolean('UseTimestamp', '是否显式传入时间戳。'), optionalNumber('Timestamp', '有限的帧时间戳；未使用时真正省略。')],
    result: '将最近 FPS 或 null 写入变量。', args: `(${argumentCode('UseTimestamp')} ? [${argumentCode('Timestamp')}] : [])`,
  },
  {
    command: 'playmesh.app.capabilities.getRegistry', name: 'GetCapabilityRegistry', group: 'App SDK ❯ Capability registry', label: '获取能力注册表',
    description: '获取全平台注册表及其开放 JSON Schema。', result: '将能力定义数组写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.capabilities.getAvailable', name: 'GetAvailableCapabilities', group: 'App SDK ❯ Capability registry', label: '获取当前可用能力',
    description: '获取当前宿主实际可用且已由项目声明的能力 code。', result: '将能力 code 数组写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.capabilities.getDeclared', name: 'GetDeclaredCapabilities', group: 'App SDK ❯ Capability registry', label: '获取项目声明能力',
    description: '获取当前页面角色在 capabilities.json 中声明的能力 code。', result: '将能力 code 数组写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.capabilities.create', name: 'CreateDynamicCapability', group: 'App SDK ❯ Dynamic capability (advanced)', label: '创建动态能力实例（高级）',
    description: '按开放注册表 code 创建能力；已知内置能力请优先使用各自的专用动作。',
    parameters: [requiredString('Code', '注册表中的能力 code。'), requiredBoolean('UseOptions', '是否显式传入创建 options。'), requiredVariable('Options', '开放 JSON 创建 options 变量。')],
    result: '将能力句柄描述和 handleId 写入变量。', args: `(${argumentCode('UseOptions')} ? [${argumentCode('Code')}, ${variableCode('Options')}] : [${argumentCode('Code')}])`,
  },
  {
    command: 'playmesh.app.media.open', name: 'OpenAppMediaSession', group: 'App SDK ❯ Media', label: '打开媒体会话',
    description: '打开能力签发的媒体源；可选 AbortController 中止仍在进行的协商。',
    parameters: [requiredString('SourceHandleId', 'PlaymeshAppMediaSource handleId。'), requiredBoolean('UseAbortSignal', '是否传入中止信号。'), optionalString('AbortHandleId', 'AbortController handleId。')],
    result: '将媒体会话描述、session handleId 和不透明 stream handleId 写入变量。',
    args: `(() => { const values = [{ $handle: ${argumentCode('SourceHandleId')} }]; if (${argumentCode('UseAbortSignal')}) values.push({ signal: { $abortSignal: ${argumentCode('AbortHandleId')} } }); return values; })()`,
  },
  {
    command: 'playmesh.app.device.getPlatform', name: 'GetDevicePlatform', group: 'App SDK ❯ Device environment', label: '获取设备宿主平台',
    description: '获取 android、windows 等宿主平台名称；普通浏览器为 null。', result: '将平台文本或 null 写入变量。', args: '[]',
  },
  {
    command: 'playmesh.app.device.setFullscreen', name: 'SetDeviceFullscreen', group: 'App SDK ❯ Device environment', label: '设置设备全屏状态',
    description: '请求 App WebView 进入或退出全屏；进入时可选方向锁定。',
    parameters: [requiredBoolean('Enabled', '是否进入全屏。'), requiredBoolean('UseOrientation', '是否显式传入方向。'), optionalString('Orientation', '全屏方向；UseOrientation 为否时真正省略。', ['landscape', 'portrait'])],
    result: '将宿主返回的开放结果写入变量。', args: `(${argumentCode('UseOrientation')} ? [${argumentCode('Enabled')}, ${argumentCode('Orientation')}] : [${argumentCode('Enabled')}])`,
  },
  { command: 'playmesh.app.ui.disableSystemMenuTriggers', name: 'DisableSystemMenuTriggers', group: 'App SDK ❯ UI', label: '禁用系统菜单自动触发', description: '解除当前文档用于自动打开系统游戏菜单的按键与返回触发。', args: '[]', void: true },
  { command: 'playmesh.app.ui.initializeBrowser', name: 'InitializeBrowserUi', group: 'App SDK ❯ UI', label: '初始化浏览器兜底界面', description: '启用浏览器兜底游戏菜单但不创建悬浮球；App WebView 中返回 false。', result: '将是否初始化成功写入变量。', args: '[]' },
  {
    command: 'playmesh.app.ui.configure', name: 'ConfigureAppUi', group: 'App SDK ❯ UI', label: '配置 SDK 兜底界面', description: '逐字段配置兜底菜单与浏览器悬浮按钮。',
    parameters: [requiredBoolean('UseFallbackUi', '是否显式设置 fallbackUi。'), booleanParam('FallbackUi', '是否由 SDK 渲染兜底界面。', { optional: true, defaultValue: true }), requiredBoolean('UseFloatingButton', '是否显式设置 floatingButton。'), booleanParam('FloatingButton', '普通浏览器是否显示悬浮菜单按钮。', { optional: true, defaultValue: true })],
    result: '将实际配置对象写入变量。', args: `(() => { const options = {}; if (${argumentCode('UseFallbackUi')}) options.fallbackUi = ${argumentCode('FallbackUi')}; if (${argumentCode('UseFloatingButton')}) options.floatingButton = ${argumentCode('FloatingButton')}; return [options]; })()`,
  },
  { command: 'playmesh.app.ui.showGameSidebar', name: 'ShowGameMenu', group: 'App SDK ❯ UI', label: '打开游戏菜单', description: '手动打开 SDK 居中游戏菜单。', result: '将是否成功打开写入变量。', args: '[]' },
  { command: 'playmesh.app.ui.restartGame', name: 'RestartGame', group: 'App SDK ❯ UI', label: '重新启动当前游戏', description: '重新加载当前游戏文档；公开契约无返回值。', args: '[]', void: true },
  { command: 'playmesh.app.ui.openSharePanel', name: 'OpenSharePanel', group: 'App SDK ❯ UI', label: '打开分享邀请面板', description: '仅当前 Authority 可在有效用户操作中打开分享与邀请。', args: '[]', void: true },
  { command: 'playmesh.app.ui.openRuntimeLogs', name: 'OpenRuntimeLogs', group: 'App SDK ❯ UI', label: '打开 SDK 运行日志', description: '打开 SDK 运行日志覆盖层。', result: '将是否成功打开写入变量。', args: '[]' },
  {
    command: 'playmesh.app.ui.enterFullscreen', name: 'EnterUiFullscreen', group: 'App SDK ❯ UI', label: '通过平台界面进入全屏', description: '进入全屏；可省略方向。',
    parameters: [requiredBoolean('UseOrientation', '是否显式传入方向。'), optionalString('Orientation', '全屏方向。', ['landscape', 'portrait'])], result: '将宿主开放结果写入变量。', args: `(${argumentCode('UseOrientation')} ? [${argumentCode('Orientation')}] : [])`,
  },
  { command: 'playmesh.app.ui.exitFullscreen', name: 'ExitUiFullscreen', group: 'App SDK ❯ UI', label: '通过平台界面退出全屏', description: '退出全屏。', result: '将宿主开放结果写入变量。', args: '[]' },
  { command: 'playmesh.app.ui.openGameInfo', name: 'OpenGameInfo', group: 'App SDK ❯ UI', label: '打开游戏信息', description: '打开 SDK 游戏信息覆盖层。', result: '将是否成功打开写入变量。', args: '[]' },
  { command: 'playmesh.app.ui.setPerformanceVisible', name: 'SetUiPerformanceVisible', group: 'App SDK ❯ UI', label: '设置界面性能浮层可见性', description: '显示或隐藏 SDK 性能浮层。', parameters: [requiredBoolean('Visible', '是否显示性能浮层。')], result: '将设置后的布尔状态写入变量。', args: `[${argumentCode('Visible')}]` },
  { command: 'playmesh.app.ui.togglePerformance', name: 'ToggleUiPerformance', group: 'App SDK ❯ UI', label: '切换界面性能浮层', description: '切换 SDK 性能浮层。', result: '将切换后的布尔状态写入变量。', args: '[]' },
  { command: 'playmesh.app.ui.exitGame', name: 'ExitCurrentGame', group: 'App SDK ❯ UI', label: '退出当前游戏', description: '请求平台结束当前游戏。', args: '[]', void: true },
  { command: 'playmesh.app.lan.discoverGames', name: 'DiscoverLanGames', group: 'App SDK ❯ LAN', label: '发现局域网游戏', description: '发现与当前游戏匹配的局域网房间，每项包含稳定 LanGame handleId。', result: '将发现结果数组和每项 handleId 写入变量。', args: '[]' },
  { command: 'playmesh.app.lan.joinByLink', name: 'JoinGameByInvitationLink', group: 'App SDK ❯ LAN', label: '通过邀请链接加入游戏', description: '由宿主预检邀请链接并切换页面。', parameters: [requiredString('InvitationUrl', '非空 Playmesh 邀请链接。')], args: `[${argumentCode('InvitationUrl')}]`, void: true },
  { command: 'playmesh.app.lan.scanQrAndJoin', name: 'ScanQrAndJoinGame', group: 'App SDK ❯ LAN', label: '扫码并加入游戏', description: '打开扫码流程并加入；取消扫描会记录为非致命失败。', args: '[]', void: true },
  { command: 'playmesh.app.lan.setPublished', name: 'PublishLanGame', group: 'App SDK ❯ LAN', label: '公开当前局域网房间', description: '单向公开当前 Authority 房间；本局幂等。', args: '[]', void: true },
  { command: 'playmesh.app.lan.getShareLinks', name: 'GetLanShareLinks', group: 'App SDK ❯ LAN', label: '获取完整分享链接', description: '读取 LAN/WAN 分享链接和 PNG Data URL。', result: '将分享链接数组写入变量。', args: '[]' },
  {
    command: 'PlaymeshCapabilityHandle.invoke', name: 'InvokeDynamicCapability', group: 'App SDK ❯ Dynamic capability (advanced)', label: '调用动态能力方法（高级）', description: '对开放注册表能力句柄调用任意声明方法；已知内置能力请优先使用专用动作。',
    parameters: [handleIdParameter('能力实例 handleId。'), requiredString('Method', '能力注册表声明的方法名。'), requiredBoolean('UseArguments', '是否显式传入方法参数对象。'), requiredVariable('Arguments', '开放 JSON 方法参数变量。')],
    result: '将开放 JSON 方法结果写入变量。', args: `(${argumentCode('UseArguments')} ? [${argumentCode('Method')}, ${variableCode('Arguments')}] : [${argumentCode('Method')}])`, handle: 'HandleId',
  },
  {
    command: 'PlaymeshCapabilityHandle.removeEventListener', name: 'RemoveDynamicCapabilityEventListener', group: 'App SDK ❯ Dynamic capability (advanced)', label: '移除动态能力 DOM 事件监听（高级）', description: '使用 addEventListener 创建的同一 SubscriptionId 精确移除回调。',
    parameters: [handleIdParameter('能力实例 handleId。'), requiredString('EventName', '已订阅的能力事件名。'), requiredString('SubscriptionId', 'addEventListener 使用的订阅 ID。')], args: `[${argumentCode('EventName')}, ${argumentCode('SubscriptionId')}]`, handle: 'HandleId', void: true,
  },
  { command: 'PlaymeshCapabilityHandle.dispose', name: 'DisposeDynamicCapability', group: 'App SDK ❯ Dynamic capability (advanced)', label: '释放动态能力实例（高级）', description: '释放能力实例及其底层资源。', parameters: [handleIdParameter('能力实例 handleId。')], args: '[]', handle: 'HandleId', void: true },
  { command: 'PlaymeshAppMediaSession.close', name: 'CloseAppMediaSession', group: 'App SDK ❯ Media', label: '关闭媒体会话', description: '关闭媒体消费会话并释放其资源。', parameters: [handleIdParameter('媒体会话 handleId。')], args: '[]', handle: 'HandleId', void: true },
  { command: 'PlaymeshLanGame.join', name: 'JoinDiscoveredLanGame', group: 'App SDK ❯ LAN', label: '加入已发现的局域网游戏', description: '通过 discoverGames 返回的稳定句柄加入房间；必须由真实用户操作触发。', parameters: [handleIdParameter('发现结果 LanGame handleId。')], args: '[]', handle: 'HandleId', void: true },
);

// Overloads are separate editor actions so ordinary use never asks for
// unrelated target/data fields and ambiguous JSON-array states stay explicit.
const typedExecuteOverloadSpecs = [
  {
    command: 'PlaymeshBinaryChannel.send', name: 'BroadcastBinaryBytes', group: 'Main SDK ❯ Binary', label: '可靠广播字节变量', description: '从 0～255 数组变量可靠广播一帧。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredVariable('Bytes', '0～255 字节数组变量。')], args: `[{ $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.send', name: 'SendBinaryToPlayer', group: 'Main SDK ❯ Binary', label: '向单个玩家可靠发送编码二进制帧', description: '向一个玩家可靠发送 UTF-8、Base64 或十六进制帧。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredString('TargetPlayerId', '目标玩家 ID。'), requiredString('Encoding', '输入编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '对应编码的帧数据。')], args: `[${argumentCode('TargetPlayerId')}, { $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.send', name: 'SendBinaryBytesToPlayer', group: 'Main SDK ❯ Binary', label: '向单个玩家可靠发送字节变量', description: '向一个玩家可靠发送 0～255 字节数组。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredString('TargetPlayerId', '目标玩家 ID。'), requiredVariable('Bytes', '0～255 字节数组变量。')], args: `[${argumentCode('TargetPlayerId')}, { $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.send', name: 'SendBinaryToPlayers', group: 'Main SDK ❯ Binary', label: '向多个玩家可靠发送编码二进制帧', description: '用一个上行帧向目标数组中的玩家可靠扇出。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredVariable('TargetPlayerIds', '1～1024 个目标玩家 ID 数组。'), requiredString('Encoding', '输入编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '对应编码的帧数据。')], args: `[${variableCode('TargetPlayerIds')}, { $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.send', name: 'SendBinaryBytesToPlayers', group: 'Main SDK ❯ Binary', label: '向多个玩家可靠发送字节变量', description: '用一个上行帧向目标数组中的玩家可靠扇出字节变量。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredVariable('TargetPlayerIds', '1～1024 个目标玩家 ID 数组。'), requiredVariable('Bytes', '0～255 字节数组变量。')], args: `[${variableCode('TargetPlayerIds')}, { $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.sendLatest', name: 'BroadcastLatestBinaryBytes', group: 'Main SDK ❯ Binary', label: '广播最新字节变量', description: '广播可被后续帧替换的 0～255 字节数组。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredVariable('Bytes', '0～255 字节数组变量。')], args: `[{ $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.sendLatest', name: 'SendLatestBinaryToPlayer', group: 'Main SDK ❯ Binary', label: '向单个玩家发送最新编码二进制帧', description: '向一个玩家发送可被后续帧替换的编码数据。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredString('TargetPlayerId', '目标玩家 ID。'), requiredString('Encoding', '输入编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '对应编码的帧数据。')], args: `[${argumentCode('TargetPlayerId')}, { $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.sendLatest', name: 'SendLatestBinaryBytesToPlayer', group: 'Main SDK ❯ Binary', label: '向单个玩家发送最新字节变量', description: '向一个玩家发送可被后续帧替换的字节变量。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredString('TargetPlayerId', '目标玩家 ID。'), requiredVariable('Bytes', '0～255 字节数组变量。')], args: `[${argumentCode('TargetPlayerId')}, { $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.sendLatest', name: 'SendLatestBinaryToPlayers', group: 'Main SDK ❯ Binary', label: '向多个玩家发送最新编码二进制帧', description: '按每个目标分别替换尚未发送的旧帧。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredVariable('TargetPlayerIds', '1～1024 个目标玩家 ID 数组。'), requiredString('Encoding', '输入编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '对应编码的帧数据。')], args: `[${variableCode('TargetPlayerIds')}, { $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshBinaryChannel.sendLatest', name: 'SendLatestBinaryBytesToPlayers', group: 'Main SDK ❯ Binary', label: '向多个玩家发送最新字节变量', description: '按每个目标分别替换尚未发送的旧字节帧。',
    parameters: [handleIdParameter('二进制通道 handleId。'), requiredVariable('TargetPlayerIds', '1～1024 个目标玩家 ID 数组。'), requiredVariable('Bytes', '0～255 字节数组变量。')], args: `[${variableCode('TargetPlayerIds')}, { $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId', void: true,
  },
  {
    command: 'PlaymeshSyncAuthorityController.publish', name: 'PublishCurrentAuthoritySyncStateToPlayers', group: 'Main SDK ❯ Sync', label: '向指定玩家发布当前同步状态', description: '立即向指定接收者发布当前公共状态。',
    parameters: [handleIdParameter('同步控制器 handleId。'), requiredVariable('TargetPlayerIds', '目标玩家 ID 数组。')], result: '将发布快照或 null 写入变量。', args: `({ hasState: false, targetPlayerIds: ${variableCode('TargetPlayerIds')} })`, handle: 'HandleId',
  },
  {
    command: 'PlaymeshSyncAuthorityController.publish', name: 'PublishGivenAuthoritySyncState', group: 'Main SDK ❯ Sync', label: '广播指定 Authority 同步状态', description: '在同一调用中替换公共状态并向默认接收者发布。',
    parameters: [handleIdParameter('同步控制器 handleId。'), requiredVariable('State', '要替换并发布的完整状态。')], result: '将发布快照或 null 写入变量。', args: `({ hasState: true, state: ${variableCode('State')} })`, handle: 'HandleId',
  },
  {
    command: 'PlaymeshSyncAuthorityController.publish', name: 'PublishGivenAuthoritySyncStateToPlayers', group: 'Main SDK ❯ Sync', label: '向指定玩家发布指定同步状态', description: '在同一调用中替换公共状态并向指定接收者发布。',
    parameters: [handleIdParameter('同步控制器 handleId。'), requiredVariable('State', '要替换并发布的完整状态。'), requiredVariable('TargetPlayerIds', '目标玩家 ID 数组。')], result: '将发布快照或 null 写入变量。', args: `({ hasState: true, state: ${variableCode('State')}, targetPlayerIds: ${variableCode('TargetPlayerIds')} })`, handle: 'HandleId',
  },
  {
    command: 'PlaymeshStorageBucket.upload', name: 'UploadBucketByteFile', group: 'Main SDK ❯ Storage', label: '上传字节变量文件到存储桶', description: '从 0～255 字节数组创建 File 并上传。',
    parameters: [handleIdParameter('存储桶 handleId。'), requiredString('FileName', '上传文件名。'), requiredString('MimeType', '文件 MIME 类型。'), requiredVariable('Bytes', '0～255 文件字节数组变量。')], result: '将上传后的同源 URL 写入变量。', args: `[{ $file: { name: ${argumentCode('FileName')}, type: ${argumentCode('MimeType')}, encoding: "bytes", data: ${variableCode('Bytes')} } }]`, handle: 'HandleId',
  },
];

const typedSubscribeSpecs = [
  { command: 'playmesh.main.session.onStateChange', name: 'SubscribeSessionStateChange', group: 'Main SDK ❯ Session', label: '订阅会话状态变化', description: '订阅会话快照；已就绪时会立即入队。', args: '[]' },
  { command: 'playmesh.main.session.onPlayerJoin', name: 'SubscribePlayerJoin', group: 'Main SDK ❯ Session', label: '订阅玩家首次加入', description: '玩家第一次加入时把可信连接事件入队。', args: '[]' },
  { command: 'playmesh.main.session.onPlayerLeave', name: 'SubscribePlayerLeave', group: 'Main SDK ❯ Session', label: '订阅玩家连接断开', description: '玩家连接断开时把可信连接事件入队。', args: '[]' },
  { command: 'playmesh.main.session.onPlayerReconnect', name: 'SubscribePlayerReconnect', group: 'Main SDK ❯ Session', label: '订阅玩家重新连接', description: '离线玩家以相同 ID 恢复连接时入队。', args: '[]' },
  { command: 'playmesh.main.game.onMessage', name: 'SubscribeGameMessage', group: 'Main SDK ❯ Game', label: '订阅 Authority 游戏消息', description: '订阅 Authority 发给当前客户端的开放 JSON 消息。', args: '[]' },
  { command: 'playmesh.main.game.onEvent', name: 'SubscribeLegacyGameEvent', group: 'Main SDK ❯ Game', label: '订阅兼容游戏事件', description: 'onMessage 的兼容别名；回调仍只有一个开放 JSON 消息。', args: '[]' },
  { command: 'playmesh.main.sync.observe', name: 'SubscribeSyncSnapshot', group: 'Main SDK ❯ Sync', label: '订阅完整同步快照', description: '订阅完整权威快照；已有快照时立即入队。', args: '[]' },
  { command: 'playmesh.main.lifecycle.onChange', name: 'SubscribeLifecycleChange', group: 'Main SDK ❯ Lifecycle', label: '订阅全部生命周期变化', description: '订阅 ready、pause、resume、exit、closed 和 error。', args: '[]' },
  { command: 'playmesh.main.lifecycle.onPause', name: 'SubscribeLifecyclePause', group: 'Main SDK ❯ Lifecycle', label: '订阅游戏暂停', description: '仅订阅暂停生命周期事件。', args: '[]' },
  { command: 'playmesh.main.lifecycle.onResume', name: 'SubscribeLifecycleResume', group: 'Main SDK ❯ Lifecycle', label: '订阅游戏恢复', description: '仅订阅恢复生命周期事件。', args: '[]' },
  {
    command: 'playmesh.main.lifecycle.onExit', name: 'SubscribeLifecycleExit', group: 'Main SDK ❯ Lifecycle', label: '订阅游戏退出', description: '被动监听立即返回；显式启用 HandlerId 时把有限等待的异步清理桥接为请求。',
    parameters: [requiredBoolean('UseHandler', '是否启用可响应的异步退出处理器。'), optionalString('HandlerId', '异步退出请求处理器 ID。'), requiredBoolean('UseCallbackTimeout', '是否显式设置回调等待时间。'), optionalNumber('CallbackTimeoutMs', '退出回调最大等待毫秒数。', 15000)],
    args: `(() => { if (!${argumentCode('UseHandler')}) return []; const options = { handlerId: ${argumentCode('HandlerId')} }; if (${argumentCode('UseCallbackTimeout')}) options.callbackTimeoutMs = ${argumentCode('CallbackTimeoutMs')}; return [options]; })()`,
  },
  { command: 'PlaymeshBinaryChannel.onMessage', name: 'SubscribeBinaryMessage', group: 'Main SDK ❯ Binary', label: '订阅二进制消息', description: '订阅实际送达当前玩家的字节帧和可信 sender/delivery 上下文。', parameters: [handleIdParameter('二进制通道 handleId。')], args: '[]', handle: 'HandleId' },
  { command: 'playmesh.app.performance.onFps', name: 'SubscribeAppFps', group: 'App SDK ❯ Performance', label: '订阅 FPS 变化', description: '订阅当前页面 FPS；注册后立即入队当前值。', args: '[]' },
  { command: 'playmesh.app.performance.onLatency', name: 'SubscribeAppLatency', group: 'App SDK ❯ Performance', label: '订阅网络延迟变化', description: '订阅当前参与端到 Authority 的延迟毫秒数。', args: '[]' },
  { command: 'playmesh.app.device.onInput', name: 'SubscribeDeviceInput', group: 'App SDK ❯ Device environment', label: '订阅设备统一输入', description: '订阅开放结构的 App 统一输入事件。', args: '[]' },
  { command: 'playmesh.app.ui.onGameMenuOpen', name: 'SubscribeGameMenuOpen', group: 'App SDK ❯ UI', label: '订阅游戏菜单打开', description: '只在关闭到打开的真实状态变化后入队。', args: '[]' },
  { command: 'playmesh.app.ui.onGameMenuClose', name: 'SubscribeGameMenuClose', group: 'App SDK ❯ UI', label: '订阅游戏菜单关闭', description: '只在打开到关闭的真实状态变化后入队。', args: '[]' },
  { command: 'PlaymeshCapabilityHandle.on', name: 'SubscribeDynamicCapabilityEvent', group: 'App SDK ❯ Dynamic capability (advanced)', label: '订阅动态能力事件（高级）', description: '按注册表事件名订阅开放 JSON 数据。', parameters: [handleIdParameter('能力实例 handleId。'), requiredString('EventName', '注册表声明的事件名。')], args: `[${argumentCode('EventName')}]`, handle: 'HandleId' },
  { command: 'PlaymeshCapabilityHandle.addEventListener', name: 'AddDynamicCapabilityEventListener', group: 'App SDK ❯ Dynamic capability (advanced)', label: '添加动态能力 DOM 事件监听（高级）', description: '按 DOM 风格别名订阅开放 JSON 数据；SubscriptionId 用于精确移除。', parameters: [handleIdParameter('能力实例 handleId。'), requiredString('EventName', '注册表声明的事件名。')], args: `[${argumentCode('EventName')}]`, handle: 'HandleId' },
  { command: 'PlaymeshCapabilityHandle.onError', name: 'SubscribeDynamicCapabilityError', group: 'App SDK ❯ Dynamic capability (advanced)', label: '订阅动态能力错误（高级）', description: '订阅能力实例的非致命 Error，并把稳定 code 与 message 作为安全错误对象入队。', parameters: [handleIdParameter('能力实例 handleId。')], args: '[]', handle: 'HandleId' },
];

const typedHandlerSpecs = [
  {
    command: 'playmesh.main.authority.onService', name: 'RegisterAuthorityService', group: 'Main SDK ❯ Authority', label: '注册 Authority 动作处理器', description: '把游戏动作和可信 sender/session/members 上下文桥接为可响应请求。',
    parameters: [requiredBoolean('UseNamespace', '是否显式传入路由 namespace。'), optionalString('Namespace', '隔离路由 namespace。'), requiredBoolean('UseCallbackTimeout', '是否显式设置回调超时。'), optionalNumber('CallbackTimeoutMs', '请求等待毫秒数，100～60000。', 15000)],
    args: `(() => { const options = {}; if (${argumentCode('UseNamespace')}) options.namespace = ${argumentCode('Namespace')}; if (${argumentCode('UseCallbackTimeout')}) options.callbackTimeoutMs = ${argumentCode('CallbackTimeoutMs')}; return Object.keys(options).length ? [options] : []; })()`,
  },
  {
    command: 'playmesh.main.rpc.onRequest', name: 'RegisterAuthorityRpcHandler', group: 'Main SDK ❯ RPC', label: '监听 Authority RPC 路径', description: '仅 Authority 可注册；把 JSON、图片或文件请求与可信上下文桥接到请求队列，响应可同步表达为队列结果。',
    parameters: [requiredString('Path', '要监听的精确 RPC path。'), requiredBoolean('UseCallbackTimeout', '是否显式设置 GDevelop 回调等待时间。'), optionalNumber('CallbackTimeoutMs', '回调等待毫秒数，100～60000。', 10000)],
    args: `(() => { const options = {}; if (${argumentCode('UseCallbackTimeout')}) options.callbackTimeoutMs = ${argumentCode('CallbackTimeoutMs')}; return Object.keys(options).length ? [${argumentCode('Path')}, options] : [${argumentCode('Path')}]; })()`,
  },
  {
    command: 'PlaymeshBinaryChannel.onForward', name: 'RegisterBinaryForwardHandler', group: 'Main SDK ❯ Binary', label: '注册二进制 Authority 审核器', description: '把待转发字节和可信 sender/delivery/targets 上下文桥接为 pass、replace 或 reject 请求。',
    parameters: [handleIdParameter('authority 模式二进制通道 handleId。'), requiredBoolean('UseCallbackTimeout', '是否显式设置回调超时。'), optionalNumber('CallbackTimeoutMs', '请求等待毫秒数，100～60000。', 15000)],
    args: `(${argumentCode('UseCallbackTimeout')} ? [{ callbackTimeoutMs: ${argumentCode('CallbackTimeoutMs')} }] : [])`, handle: 'HandleId',
  },
];

const assertExactTypedSurface = (specs, commands, section) => {
  const values = specs.map(spec => spec.command);
  if (values.length !== commands.length || new Set(values).size !== commands.length || commands.some(command => !values.includes(command))) {
    throw new Error(`Typed ${section} wrappers must cover each declared SDK command exactly once.`);
  }
};
assertExactTypedSurface(typedExecuteSpecs, executeCommands, 'execute');
assertExactTypedSurface(typedSubscribeSpecs, subscribeCommands, 'subscribe');
assertExactTypedSurface(typedHandlerSpecs, handlerCommands, 'handler');

const makeTypedExecuteFunction = spec => eventFunction({
  name: spec.name,
  fullName: spec.label,
  description: spec.description,
  group: spec.group,
  sentence: `${spec.label}；可选操作 ID _PARAM${(spec.parameters || []).length + (spec.void ? 1 : 2)}_`,
  async: true,
  parameters: [
    ...(spec.parameters || []),
    ...(spec.void ? [] : [resultVariable(spec.result)]),
    optionalOperationId(),
  ],
  code: asyncGuard(`extension.execute(${JSON.stringify(spec.command)}, ${spec.args || '[]'}, ${argumentCode('OperationId')}, ${spec.handle ? argumentCode(spec.handle) : '""'}).then((result) => { ${spec.void ? '' : `extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null);`} return result; })`),
});

const makeTypedSubscribeFunction = spec => eventFunction({
  name: spec.name,
  fullName: spec.label,
  description: spec.description,
  group: spec.group,
  sentence: `${spec.label}，订阅 ID _PARAM1_`,
  parameters: [requiredString('SubscriptionId', '稳定订阅 ID；重复使用会先取消旧订阅。'), ...(spec.parameters || [])],
  code: extensionGuard('', `extension.subscribe(${JSON.stringify(spec.command)}, ${spec.args || '[]'}, ${argumentCode('SubscriptionId')}, ${spec.handle ? argumentCode(spec.handle) : '""'});`),
});

const makeTypedEventQueueFunctions = spec => [
  eventFunction({
    name: `Has${spec.name}Event`, fullName: `${spec.label}已有事件`, description: `检查“${spec.label}”的队列中是否有事件。`, group: spec.group, functionType: 'Condition', sentence: `${spec.label}订阅 _PARAM1_ 已有事件`,
    parameters: [requiredString('SubscriptionId', '该专用订阅动作使用的订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = false;', `eventsFunctionContext.returnValue = extension.eventCount(${argumentCode('SubscriptionId')}) > 0;`),
  }),
  eventFunction({
    name: `Pop${spec.name}Event`, fullName: `取出${spec.label}事件`, description: `取出“${spec.label}”最早事件的语义载荷，不包含队列包装字段。`, group: spec.group, sentence: `从订阅 _PARAM1_ 取出${spec.label}事件到 _PARAM2_`,
    parameters: [requiredString('SubscriptionId', '该专用订阅动作使用的订阅 ID。'), requiredVariable('Result', '接收回调语义载荷的变量。')], code: extensionGuard('', `const record = extension.popEvent(${argumentCode('SubscriptionId')}); if (record) extension.writeVariable(${argumentCode('Result')}, record.value);`),
  }),
];

const makeTypedHandlerFunction = spec => eventFunction({
  name: spec.name,
  fullName: spec.label,
  description: spec.description,
  group: spec.group,
  sentence: `${spec.label}，处理器 ID _PARAM1_`,
  parameters: [requiredString('HandlerId', '稳定处理器 ID；响应请求时使用。'), ...(spec.parameters || [])],
  code: extensionGuard('', `extension.registerHandler(${JSON.stringify(spec.command)}, ${spec.args || '[]'}, ${argumentCode('HandlerId')}, ${spec.handle ? argumentCode(spec.handle) : '""'});`),
});

const makeTypedRequestQueueFunctions = spec => [
  eventFunction({
    name: `Has${spec.name}Request`, fullName: `${spec.label}已有请求`, description: `检查“${spec.label}”的请求队列。`, group: spec.group, functionType: 'Condition', sentence: `${spec.label}处理器 _PARAM1_ 已有请求`,
    parameters: [requiredString('HandlerId', '该专用处理器使用的 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = false;', `eventsFunctionContext.returnValue = extension.requestCount(${argumentCode('HandlerId')}) > 0;`),
  }),
  eventFunction({
    name: `Pop${spec.name}Request`, fullName: `取出${spec.label}请求`, description: `取出“${spec.label}”最早请求的可信载荷和 requestId。`, group: spec.group, sentence: `从处理器 _PARAM1_ 取出${spec.label}请求到 _PARAM2_`,
    parameters: [requiredString('HandlerId', '该专用处理器使用的 ID。'), requiredVariable('Result', '接收请求记录的变量。')], code: extensionGuard('', `const record = extension.popRequest(${argumentCode('HandlerId')}); if (record) extension.writeVariable(${argumentCode('Result')}, record);`),
  }),
];

const typedExecuteFunctions = [...typedExecuteSpecs, ...typedExecuteOverloadSpecs].map(makeTypedExecuteFunction);
const typedSubscribeFunctions = typedSubscribeSpecs.flatMap(spec => [makeTypedSubscribeFunction(spec), ...makeTypedEventQueueFunctions(spec)]);
const typedHandlerFunctions = typedHandlerSpecs.flatMap(spec => [makeTypedHandlerFunction(spec), ...makeTypedRequestQueueFunctions(spec)]);

const mainExecuteCommands = executeCommands.filter(command => command.startsWith('playmesh.main.') || command.startsWith('PlaymeshBinaryChannel.') || command.startsWith('PlaymeshSyncAuthorityController.') || command.startsWith('PlaymeshStorageBucket.'));
const mainSubscribeCommands = subscribeCommands.filter(command => command.startsWith('playmesh.main.') || command.startsWith('PlaymeshBinaryChannel.'));
const appExecuteCommands = executeCommands.filter(command => !mainExecuteCommands.includes(command));
const appSubscribeCommands = subscribeCommands.filter(command => !mainSubscribeCommands.includes(command));
const mainProperties = propertyCommands.filter(property => property.startsWith('playmesh.main.') || property.startsWith('PlaymeshBinaryChannel.'));
const appProperties = propertyCommands.filter(property => !mainProperties.includes(property));

const makeAdvancedExecute = (name, label, group, commands) => eventFunction({
  name, fullName: label, description: '开放 JSON/返回句柄的高级逃生口；固定 SDK 成员请优先使用逐 API 专用动作。', group, sentence: `${label} _PARAM1_`, async: true,
  parameters: [requiredString('Command', '高级调用的固定允许列表命令。', commands), requiredVariable('Arguments', '参数数组变量；无参数时传空数组。'), requiredVariable('Result', '接收操作结果的变量。'), optionalString('HandleId', '返回对象方法需要的 handleId。'), optionalOperationId()],
  code: asyncGuard(`extension.execute(${argumentCode('Command')}, ${variableCode('Arguments')}, ${argumentCode('OperationId')}, ${argumentCode('HandleId')}).then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; })`),
});
const makeAdvancedSubscribe = (name, label, group, commands) => eventFunction({
  name, fullName: label, description: '开放 JSON 订阅的高级逃生口；固定事件请优先使用专用订阅动作。', group, sentence: `${label} _PARAM1_`,
  parameters: [requiredString('Command', '高级订阅的固定允许列表命令。', commands), requiredVariable('Arguments', '参数数组变量；无参数时传空数组。'), requiredString('SubscriptionId', '稳定订阅 ID。'), optionalString('HandleId', '返回对象订阅需要的 handleId。')],
  code: extensionGuard('', `extension.subscribe(${argumentCode('Command')}, ${variableCode('Arguments')}, ${argumentCode('SubscriptionId')}, ${argumentCode('HandleId')});`),
});
const makeAdvancedReadProperty = (name, label, group, properties) => eventFunction({
  name, fullName: label, description: '读取开放句柄或 SDK 属性的高级入口；常用属性另有专用表达式。', group, sentence: `${label} _PARAM1_`,
  parameters: [requiredString('Property', '允许读取的 SDK 属性。', properties), requiredVariable('Result', '接收属性值的变量。'), optionalString('HandleId', '句柄属性需要的 handleId。'), optionalOperationId()],
  code: extensionGuard('', `const operation = extension.readProperty(${argumentCode('Property')}, ${argumentCode('HandleId')}, ${argumentCode('OperationId')}); extension.writeVariable(${argumentCode('Result')}, operation && operation.ok ? operation.value : null);`),
});

const advancedFunctions = [
  makeAdvancedExecute('ExecuteMainSdkAdvanced', '执行 Main SDK 高级 JSON 命令', 'Main SDK ❯ Advanced JSON', mainExecuteCommands),
  makeAdvancedSubscribe('SubscribeMainSdkAdvanced', '订阅 Main SDK 高级 JSON 事件', 'Main SDK ❯ Advanced JSON', mainSubscribeCommands),
  eventFunction({ name: 'RegisterMainSdkHandlerAdvanced', fullName: '注册 Main SDK 高级 JSON 处理器', description: '开放 JSON 回调处理器的高级逃生口。', group: 'Main SDK ❯ Advanced JSON', sentence: '注册 Main SDK 高级处理器 _PARAM1_', parameters: [requiredString('Command', '允许的 Main SDK handler 命令。', handlerCommands), requiredVariable('Arguments', '处理器配置参数数组变量。'), requiredString('HandlerId', '稳定处理器 ID。'), optionalString('HandleId', '返回对象处理器需要的 handleId。')], code: extensionGuard('', `extension.registerHandler(${argumentCode('Command')}, ${variableCode('Arguments')}, ${argumentCode('HandlerId')}, ${argumentCode('HandleId')});`) }),
  makeAdvancedReadProperty('ReadMainSdkPropertyAdvanced', '读取 Main SDK 高级属性', 'Main SDK ❯ Advanced JSON', mainProperties),
  makeAdvancedExecute('ExecuteAppSdkAdvanced', '执行 App SDK 高级 JSON 命令', 'App SDK ❯ Advanced JSON', appExecuteCommands),
  makeAdvancedSubscribe('SubscribeAppSdkAdvanced', '订阅 App SDK 高级 JSON 事件', 'App SDK ❯ Advanced JSON', appSubscribeCommands),
  makeAdvancedReadProperty('ReadAppSdkPropertyAdvanced', '读取 App SDK 高级属性', 'App SDK ❯ Advanced JSON', appProperties),
];

const makePropertyStringExpression = (name, label, group, property, handle = false, path = '$') => eventFunction({
  name, fullName: label, description: `直接读取 ${property}，失败时返回空文本并记录非致命错误。`, group, functionType: 'StringExpression', expressionType: stringExpression,
  parameters: handle ? [handleIdParameter()] : [],
  code: extensionGuard('eventsFunctionContext.returnValue = "";', `const result = extension.propertyValue(${JSON.stringify(property)}, ${handle ? argumentCode('HandleId') : '""'}); if (!result.ok) eventsFunctionContext.returnValue = ""; else { const selected = extension.queryValue(result.value, ${JSON.stringify(path)}); eventsFunctionContext.returnValue = selected.exists ? extension.stringValue(selected.value) : ""; }`),
});

const propertyFunctions = [
  makePropertyStringExpression('MainSdkVersion', 'Main SDK 版本', 'Main SDK ❯ Game info', 'playmesh.main.version'),
  makePropertyStringExpression('AuthorityDefaultNamespace', 'Authority 默认 namespace', 'Main SDK ❯ Authority', 'playmesh.main.authority.defaultNamespace'),
  makePropertyStringExpression('BinaryAuthorityPlayerId', '二进制 Authority 玩家 ID', 'Main SDK ❯ Binary', 'playmesh.main.binary.authorityPlayerId'),
  makePropertyStringExpression('BinaryChannelSdkId', '二进制通道 SDK ID', 'Main SDK ❯ Binary', 'PlaymeshBinaryChannel.id', true),
  makePropertyStringExpression('BinaryChannelMode', '二进制通道模式', 'Main SDK ❯ Binary', 'PlaymeshBinaryChannel.mode', true),
  makePropertyStringExpression('AppSdkVersion', 'App SDK 版本', 'App SDK ❯ Availability', 'playmesh.app.version'),
  makePropertyStringExpression('CapabilitySdkId', '能力实例 SDK ID', 'App SDK ❯ Dynamic capability (advanced)', 'PlaymeshCapabilityHandle.id', true),
  makePropertyStringExpression('CapabilityCode', '能力实例 code', 'App SDK ❯ Dynamic capability (advanced)', 'PlaymeshCapabilityHandle.code', true),
  makePropertyStringExpression('CapabilityApiVersion', '能力实例 API 版本', 'App SDK ❯ Dynamic capability (advanced)', 'PlaymeshCapabilityHandle.apiVersion', true),
  makePropertyStringExpression('MediaSessionSdkId', '媒体会话 SDK ID', 'App SDK ❯ Media', 'PlaymeshAppMediaSession.id', true),
  makePropertyStringExpression('MediaSessionState', '媒体会话状态', 'App SDK ❯ Media', 'PlaymeshAppMediaSession.state', true),
  makePropertyStringExpression('MediaSessionSourceHandleId', '媒体会话源 handleId', 'App SDK ❯ Media', 'PlaymeshAppMediaSession.source', true, '$.handleId'),
  makePropertyStringExpression('MediaSessionStreamHandleId', '媒体流不透明 handleId', 'App SDK ❯ Media', 'PlaymeshAppMediaSession.stream', true, '$.handleId'),
  makePropertyStringExpression('LanGameInstanceId', '局域网游戏实例 ID', 'App SDK ❯ LAN', 'PlaymeshLanGame.instanceId', true),
  makePropertyStringExpression('LanGameId', '局域网游戏 ID', 'App SDK ❯ LAN', 'PlaymeshLanGame.gameId', true),
  makePropertyStringExpression('LanGameName', '局域网游戏名称', 'App SDK ❯ LAN', 'PlaymeshLanGame.name', true),
  makePropertyStringExpression('LanGameHost', '局域网游戏主机', 'App SDK ❯ LAN', 'PlaymeshLanGame.host', true),
  eventFunction({ name: 'CopyMediaSessionSource', fullName: '复制媒体会话源描述', description: '复制媒体源固定字段和安全开放字段，并保留 source handleId。', group: 'App SDK ❯ Media', sentence: '复制媒体会话 _PARAM1_ 的源描述到 _PARAM2_', parameters: [handleIdParameter('媒体会话 handleId。'), requiredVariable('Result', '接收媒体源描述的变量。')], code: extensionGuard('', `const value = extension.propertyValue("PlaymeshAppMediaSession.source", ${argumentCode('HandleId')}); if (value.ok) extension.writeVariable(${argumentCode('Result')}, value.value);`) }),
  eventFunction({ name: 'CopyMediaSessionStreamDescriptor', fullName: '复制媒体流不透明描述', description: '只复制 MediaStream 的 handleId、opaque 和 active；绝不把真实流写入变量。', group: 'App SDK ❯ Media', sentence: '复制媒体会话 _PARAM1_ 的流描述到 _PARAM2_', parameters: [handleIdParameter('媒体会话 handleId。'), requiredVariable('Result', '接收不透明流描述的变量。')], code: extensionGuard('', `const value = extension.propertyValue("PlaymeshAppMediaSession.stream", ${argumentCode('HandleId')}); if (value.ok) extension.writeVariable(${argumentCode('Result')}, value.value);`) }),
];

const makeSyncNullableCondition = (name, label, group, command) => eventFunction({
  name, fullName: label, description: `直接调用 ${command} 并判断返回值非 null。`, group, functionType: 'Condition', sentence: label,
  code: extensionGuard('eventsFunctionContext.returnValue = false;', `const result = extension.callSync(${JSON.stringify(command)}, [], ""); eventsFunctionContext.returnValue = !!(result.ok && result.value !== null && result.value !== undefined);`),
});
const makeSyncCopy = (name, label, group, command) => eventFunction({
  name, fullName: label, description: `直接调用 ${command} 并把安全结果复制到变量。`, group, sentence: `${label}到 _PARAM1_`, parameters: [requiredVariable('Result', '接收同步 SDK 值的变量。')],
  code: extensionGuard('', `const result = extension.callSync(${JSON.stringify(command)}, [], ""); extension.writeVariable(${argumentCode('Result')}, result.ok ? result.value : null);`),
});

const synchronousValueFunctions = [
  eventFunction({ name: 'IsAuthority', fullName: '当前页面是 Authority', description: '同步判断当前页面固定 Authority 身份。', group: 'Main SDK ❯ Session', functionType: 'Condition', sentence: '当前页面是 Authority', code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const result = extension.callSync("playmesh.main.session.isAuthority", [], ""); eventsFunctionContext.returnValue = !!(result.ok && result.value === true);') }),
  eventFunction({ name: 'IsAppAvailable', fullName: '当前原生 App 宿主可用', description: '同步判断当前页面是否具有原生宿主能力。', group: 'App SDK ❯ Availability', functionType: 'Condition', sentence: '当前原生 App 宿主可用', code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const result = extension.callSync("playmesh.app.isAvailable", [], ""); eventsFunctionContext.returnValue = !!(result.ok && result.value === true);') }),
  makeSyncNullableCondition('HasCurrentGameInfo', '当前游戏信息存在', 'Main SDK ❯ Game info', 'playmesh.main.gameInfo.getCurrent'),
  makeSyncCopy('CopyCurrentGameInfo', '复制当前游戏信息', 'Main SDK ❯ Game info', 'playmesh.main.gameInfo.getCurrent'),
  makeSyncNullableCondition('HasCurrentSession', '当前会话快照存在', 'Main SDK ❯ Session', 'playmesh.main.session.getCurrent'),
  makeSyncCopy('CopyCurrentSession', '复制当前会话快照', 'Main SDK ❯ Session', 'playmesh.main.session.getCurrent'),
  makeSyncNullableCondition('HasCurrentPlayer', '当前玩家存在', 'Main SDK ❯ Player', 'playmesh.main.player.getCurrent'),
  makeSyncCopy('CopyCurrentPlayer', '复制当前玩家', 'Main SDK ❯ Player', 'playmesh.main.player.getCurrent'),
  makeSyncNullableCondition('HasLatestSyncSnapshot', '最近同步快照存在', 'Main SDK ❯ Sync', 'playmesh.main.sync.getSnapshot'),
  makeSyncCopy('CopyLatestSyncSnapshot', '复制最近同步快照', 'Main SDK ❯ Sync', 'playmesh.main.sync.getSnapshot'),
  makeSyncNullableCondition('HasAppIdentity', '当前 App 身份存在', 'App SDK ❯ Identity', 'playmesh.app.identity.getCurrent'),
  makeSyncCopy('CopyAppIdentity', '复制当前 App 身份', 'App SDK ❯ Identity', 'playmesh.app.identity.getCurrent'),
  eventFunction({ name: 'AppLocale', fullName: '当前 App 显示语言', description: '同步返回当前页面 locale。', group: 'App SDK ❯ Runtime', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const result = extension.callSync("playmesh.app.runtime.getLocale", [], ""); eventsFunctionContext.returnValue = result.ok ? extension.stringValue(result.value) : "";') }),
  makeSyncNullableCondition('HasAppFps', '最近 FPS 可用', 'App SDK ❯ Performance', 'playmesh.app.performance.getFps'),
  eventFunction({ name: 'AppFps', fullName: '最近 FPS', description: '返回最近 FPS；用“最近 FPS 可用”区分不可用与 0。', group: 'App SDK ❯ Performance', functionType: 'Expression', expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'const result = extension.callSync("playmesh.app.performance.getFps", [], ""); eventsFunctionContext.returnValue = result.ok ? extension.numberValue(result.value) : 0;') }),
  makeSyncNullableCondition('HasAppLatency', '最近网络延迟可用', 'App SDK ❯ Performance', 'playmesh.app.performance.getLatency'),
  eventFunction({ name: 'AppLatency', fullName: '最近网络延迟毫秒数', description: '返回平滑 RTT；用“最近网络延迟可用”区分不可用与 0。', group: 'App SDK ❯ Performance', functionType: 'Expression', expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'const result = extension.callSync("playmesh.app.performance.getLatency", [], ""); eventsFunctionContext.returnValue = result.ok ? extension.numberValue(result.value) : 0;') }),
  makeSyncNullableCondition('HasAppLatencyDiagnostics', '延迟诊断数据存在', 'App SDK ❯ Performance', 'playmesh.app.performance.getLatencyDiagnostics'),
  makeSyncCopy('CopyAppLatencyDiagnostics', '复制延迟诊断数据', 'App SDK ❯ Performance', 'playmesh.app.performance.getLatencyDiagnostics'),
  makeSyncNullableCondition('HasDevicePlatform', '设备宿主平台存在', 'App SDK ❯ Device environment', 'playmesh.app.device.getPlatform'),
  eventFunction({ name: 'DevicePlatform', fullName: '设备宿主平台', description: '返回 android、windows 等平台文本；不存在时为空。', group: 'App SDK ❯ Device environment', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const result = extension.callSync("playmesh.app.device.getPlatform", [], ""); eventsFunctionContext.returnValue = result.ok ? extension.stringValue(result.value) : "";') }),
  makeSyncCopy('CopyCapabilityRegistry', '复制能力注册表', 'App SDK ❯ Capability registry', 'playmesh.app.capabilities.getRegistry'),
  makeSyncCopy('CopyAvailableCapabilities', '复制当前可用能力 code', 'App SDK ❯ Capability registry', 'playmesh.app.capabilities.getAvailable'),
  makeSyncCopy('CopyDeclaredCapabilities', '复制项目声明能力 code', 'App SDK ❯ Capability registry', 'playmesh.app.capabilities.getDeclared'),
];

const makeSyncPathStringExpression = (name, label, group, command, path) => eventFunction({
  name, fullName: label, description: `直接读取 ${command} 返回值的 ${path}。`, group, functionType: 'StringExpression', expressionType: stringExpression,
  code: extensionGuard('eventsFunctionContext.returnValue = "";', `const result = extension.callSync(${JSON.stringify(command)}, [], ""); const value = result.ok ? extension.queryValue(result.value, ${JSON.stringify(path)}) : { exists: false }; eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`),
});
synchronousValueFunctions.push(
  makeSyncPathStringExpression('AppIdentityUserId', '当前 App 身份用户 ID', 'App SDK ❯ Identity', 'playmesh.app.identity.getCurrent', '$.userId'),
  makeSyncPathStringExpression('AppIdentityNickname', '当前 App 身份昵称', 'App SDK ❯ Identity', 'playmesh.app.identity.getCurrent', '$.nickname'),
  makeSyncPathStringExpression('AppIdentitySource', '当前 App 身份来源', 'App SDK ❯ Identity', 'playmesh.app.identity.getCurrent', '$.source'),
  makeSyncPathStringExpression('CurrentPlayerId', '当前玩家 ID', 'Main SDK ❯ Player', 'playmesh.main.player.getCurrent', '$.id'),
  makeSyncPathStringExpression('CurrentPlayerNickname', '当前玩家昵称', 'Main SDK ❯ Player', 'playmesh.main.player.getCurrent', '$.nickname'),
  makeSyncPathStringExpression('CurrentPlayerRole', '当前玩家角色', 'Main SDK ❯ Player', 'playmesh.main.player.getCurrent', '$.role'),
  eventFunction({ name: 'CurrentPlayerConnected', fullName: '当前玩家在线连接', description: '同步判断当前玩家 connected 字段。', group: 'Main SDK ❯ Player', functionType: 'Condition', sentence: '当前玩家在线连接', code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const result = extension.callSync("playmesh.main.player.getCurrent", [], ""); const value = result.ok ? extension.queryValue(result.value, "$.connected") : { exists: false }; eventsFunctionContext.returnValue = !!(value.exists && value.value === true);') }),
  makeSyncPathStringExpression('CurrentSessionState', '当前会话状态', 'Main SDK ❯ Session', 'playmesh.main.session.getCurrent', '$.state'),
);

const eventFieldFunctions = [
  eventFunction({ name: 'SessionStateEventHasSession', fullName: '会话变化事件包含会话', description: '判断最早会话变化事件不是 null。', group: 'Main SDK ❯ Session', functionType: 'Condition', sentence: '订阅 _PARAM1_ 的会话变化事件包含会话', parameters: [requiredString('SubscriptionId', '会话变化订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = false;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value"); eventsFunctionContext.returnValue = !!(value.exists && value.value !== null);`) }),
  eventFunction({ name: 'SessionStateEventState', fullName: '会话变化事件状态', description: '返回最早会话变化事件的 lobby/running/paused/stopped。', group: 'Main SDK ❯ Session', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '会话变化订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.state"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  ...['Join', 'Leave', 'Reconnect'].flatMap(kind => {
    const subscriptionLabel = kind === 'Join' ? '加入' : kind === 'Leave' ? '断开' : '重连';
    return [
      eventFunction({ name: `Player${kind}EventPlayerId`, fullName: `玩家${subscriptionLabel}事件玩家 ID`, description: `返回最早玩家${subscriptionLabel}事件的可信玩家 ID。`, group: 'Main SDK ❯ Session', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', `玩家${subscriptionLabel}订阅 ID。`)], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.player.id"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
      eventFunction({ name: `Player${kind}EventIsCurrentPlayer`, fullName: `玩家${subscriptionLabel}事件是当前玩家`, description: `判断最早玩家${subscriptionLabel}事件是否属于当前页面玩家。`, group: 'Main SDK ❯ Session', functionType: 'Condition', sentence: `玩家${subscriptionLabel}订阅 _PARAM1_ 的事件属于当前玩家`, parameters: [requiredString('SubscriptionId', `玩家${subscriptionLabel}订阅 ID。`)], code: extensionGuard('eventsFunctionContext.returnValue = false;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.isCurrentPlayer"); eventsFunctionContext.returnValue = !!(value.exists && value.value === true);`) }),
    ];
  }),
  eventFunction({ name: 'SyncEventRevision', fullName: '同步快照事件 revision', description: '返回最早同步事件的 revision。', group: 'Main SDK ❯ Sync', functionType: 'Expression', expressionType: numberExpression, parameters: [requiredString('SubscriptionId', '同步快照订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = 0;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.revision"); eventsFunctionContext.returnValue = value.exists ? extension.numberValue(value.value) : 0;`) }),
  eventFunction({ name: 'SyncEventStateType', fullName: '同步快照事件状态类型', description: '返回最早同步事件的 stateType。', group: 'Main SDK ❯ Sync', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '同步快照订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.stateType"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'CopySyncEventState', fullName: '复制同步快照事件状态', description: '复制最早同步事件的开放 state。', group: 'Main SDK ❯ Sync', sentence: '复制同步订阅 _PARAM1_ 的状态到 _PARAM2_', parameters: [requiredString('SubscriptionId', '同步快照订阅 ID。'), requiredVariable('Result', '接收 state 的变量。')], code: extensionGuard('', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.state"); if (value.exists) extension.writeVariable(${argumentCode('Result')}, value.value);`) }),
  eventFunction({ name: 'LifecycleEventState', fullName: '生命周期事件状态', description: '返回最早生命周期事件的稳定 state。', group: 'Main SDK ❯ Lifecycle', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '生命周期订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.state"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'LifecycleEventError', fullName: '生命周期事件错误文本', description: '返回最早生命周期事件可选 error。', group: 'Main SDK ❯ Lifecycle', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '生命周期订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.error"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'BinaryEventBase64', fullName: '二进制消息 Base64 数据', description: '返回最早二进制消息的无损 Base64 数据。', group: 'Main SDK ❯ Binary', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '二进制消息订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.data.base64"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'BinaryEventSenderPlayerId', fullName: '二进制消息发送玩家 ID', description: '返回平台验证的发送玩家 ID。', group: 'Main SDK ❯ Binary', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '二进制消息订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.context.senderPlayerId"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'BinaryEventDelivery', fullName: '二进制消息投递方式', description: '返回 queued 或 latest。', group: 'Main SDK ❯ Binary', functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '二进制消息订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.context.delivery"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  ...[['Fps', 'FPS'], ['Latency', '网络延迟']].flatMap(([kind, label]) => [
    eventFunction({ name: `HasApp${kind}EventValue`, fullName: `${label}事件有数值`, description: `判断最早${label}事件不是 null。`, group: 'App SDK ❯ Performance', functionType: 'Condition', sentence: `${label}订阅 _PARAM1_ 的事件有数值`, parameters: [requiredString('SubscriptionId', `${label}订阅 ID。`)], code: extensionGuard('eventsFunctionContext.returnValue = false;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value"); eventsFunctionContext.returnValue = !!(value.exists && value.value !== null);`) }),
    eventFunction({ name: `App${kind}EventValue`, fullName: `${label}事件数值`, description: `返回最早${label}事件数值；用对应 Has 条件区分 null。`, group: 'App SDK ❯ Performance', functionType: 'Expression', expressionType: numberExpression, parameters: [requiredString('SubscriptionId', `${label}订阅 ID。`)], code: extensionGuard('eventsFunctionContext.returnValue = 0;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value"); eventsFunctionContext.returnValue = value.exists ? extension.numberValue(value.value) : 0;`) }),
  ]),
];

const typedResponseFunctions = [
  eventFunction({ name: 'RespondAuthorityResult', fullName: '响应 Authority 动作请求', description: '以一个显式目标列表和可选 message/payload 响应 Authority 请求。', group: 'Main SDK ❯ Authority', sentence: '响应 Authority 请求 _PARAM1_', parameters: [requiredString('RequestId', 'Authority 请求 ID。'), requiredVariable('TargetPlayerIds', '目标玩家 ID 数组。'), requiredBoolean('UseMessage', '是否包含推荐 message 字段。'), requiredVariable('Message', 'message 开放 JSON 值。'), requiredBoolean('UsePayload', '是否包含兼容 payload 字段。'), requiredVariable('Payload', 'payload 开放 JSON 值。')], code: extensionGuard('', `const result = { targetPlayerIds: ${variableCode('TargetPlayerIds')} }; if (${argumentCode('UseMessage')}) result.message = ${variableCode('Message')}; if (${argumentCode('UsePayload')}) result.payload = ${variableCode('Payload')}; extension.respond(${argumentCode('RequestId')}, result, "result");`) }),
  eventFunction({ name: 'RespondAuthorityRpc', fullName: '响应 Authority RPC 请求', description: '以 JSON、$binary 或 $file 变量完成 RPC handler。', group: 'Main SDK ❯ RPC', sentence: '响应 RPC 请求 _PARAM1_，返回 _PARAM2_', parameters: [requiredString('RequestId', 'RPC 请求队列中的 RequestId。'), requiredVariable('Result', 'JSON、$binary 或 $file 返回值。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, ${variableCode('Result')}, "result");`) }),
  eventFunction({ name: 'RejectAuthorityRpc', fullName: '拒绝 Authority RPC 请求', description: '让 RPC Promise 以 request_rejected 错误失败。', group: 'Main SDK ❯ RPC', sentence: '拒绝 RPC 请求 _PARAM1_，原因 _PARAM2_', parameters: [requiredString('RequestId', 'RPC 请求队列中的 RequestId。'), requiredString('Message', '拒绝原因。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, ${argumentCode('Message')}, "reject");`) }),
  eventFunction({ name: 'PassBinaryForwardRequest', fullName: '原样通过二进制审核请求', description: '以 void 结果原样通过二进制帧。', group: 'Main SDK ❯ Binary', sentence: '原样通过二进制审核请求 _PARAM1_', parameters: [requiredString('RequestId', '二进制审核请求 ID。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, null, "pass");`) }),
  eventFunction({ name: 'ReplaceBinaryForwardRequest', fullName: '以编码数据替换二进制审核帧', description: '用 UTF-8、Base64 或十六进制数据替换后通过。', group: 'Main SDK ❯ Binary', sentence: '替换二进制审核请求 _PARAM1_', parameters: [requiredString('RequestId', '二进制审核请求 ID。'), requiredString('Encoding', '替换数据编码。', ['utf8', 'base64', 'hex']), requiredString('Data', '替换帧数据。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, { $binary: { encoding: ${argumentCode('Encoding')}, data: ${argumentCode('Data')} } }, "replace");`) }),
  eventFunction({ name: 'ReplaceBinaryForwardRequestWithBytes', fullName: '以字节变量替换二进制审核帧', description: '用 0～255 数组变量替换后通过。', group: 'Main SDK ❯ Binary', sentence: '以字节变量替换二进制审核请求 _PARAM1_', parameters: [requiredString('RequestId', '二进制审核请求 ID。'), requiredVariable('Bytes', '0～255 字节数组变量。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, { $binary: { encoding: "bytes", data: ${variableCode('Bytes')} } }, "replace");`) }),
  eventFunction({ name: 'RejectBinaryForwardRequest', fullName: '拒绝二进制审核请求', description: '以错误消息拒绝转发。', group: 'Main SDK ❯ Binary', sentence: '拒绝二进制审核请求 _PARAM1_', parameters: [requiredString('RequestId', '二进制审核请求 ID。'), requiredString('Message', '拒绝原因。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, ${argumentCode('Message')}, "reject");`) }),
  eventFunction({ name: 'KeepAuthoritySyncState', fullName: '同步回调保持当前状态', description: '响应 onInput/onTick 请求而不替换当前状态。', group: 'Main SDK ❯ Sync', sentence: '同步回调请求 _PARAM1_ 保持当前状态', parameters: [requiredString('RequestId', '同步回调请求 ID。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, null, "keep");`) }),
  eventFunction({ name: 'SetNextAuthoritySyncState', fullName: '同步回调返回下一状态', description: '以变量中的完整 JSON 状态响应 onInput/onTick。', group: 'Main SDK ❯ Sync', sentence: '同步回调请求 _PARAM1_ 返回状态 _PARAM2_', parameters: [requiredString('RequestId', '同步回调请求 ID。'), requiredVariable('State', '下一完整状态变量。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, ${variableCode('State')}, "next");`) }),
  eventFunction({ name: 'CompleteLifecycleExitCleanup', fullName: '完成退出异步清理请求', description: '完成 onExit 的有限等待清理请求。', group: 'Main SDK ❯ Lifecycle', sentence: '完成退出清理请求 _PARAM1_', parameters: [requiredString('RequestId', '退出清理请求 ID。')], code: extensionGuard('', `extension.respond(${argumentCode('RequestId')}, null, "void");`) }),
];

const capabilityByCode = new Map(builtInCapabilityDescriptors.map(descriptor => [descriptor.code, descriptor]));
const requireCapability = code => {
  const descriptor = capabilityByCode.get(code);
  if (!descriptor) throw new Error(`Missing built-in capability descriptor: ${code}`);
  return descriptor;
};
const requireCapabilityMethod = (descriptor, name) => {
  const method = descriptor.methods.find(value => value.name === name);
  if (!method) throw new Error(`Missing ${descriptor.code} method: ${name}`);
  return method;
};
const requireCapabilityEvent = (descriptor, name) => {
  const event = descriptor.events.find(value => value.name === name);
  if (!event) throw new Error(`Missing ${descriptor.code} event: ${name}`);
  return event;
};
const requireSchemaProperty = (owner, schema, name) => {
  const property = schema && schema.properties && schema.properties[name];
  if (!property) throw new Error(`Missing ${owner} schema property: ${name}`);
  return property;
};

const cameraCapability = requireCapability('media.camera');
const microphoneCapability = requireCapability('media.microphone');
const midiCapability = requireCapability('device.midi');
const vibrationCapability = requireCapability('device.vibration');
const poseCapability = requireCapability('sensor.pose6d');
const expectedCapabilityCodes = ['media.camera', 'media.microphone', 'device.midi', 'device.vibration', 'sensor.pose6d'];
if (builtInCapabilityDescriptors.length !== expectedCapabilityCodes.length || expectedCapabilityCodes.some(code => !capabilityByCode.has(code))) {
  throw new Error('The built-in capability typed facade must be reviewed when the default registry changes.');
}
if (cameraCapability.methods.length || cameraCapability.events.length || midiCapability.methods.length || midiCapability.events.length) {
  throw new Error('Camera/MIDI permission declarations gained callable members; review their typed facade.');
}

const microphoneToText = requireCapabilityMethod(microphoneCapability, 'toText');
const microphoneSoundEvent = requireCapabilityEvent(microphoneCapability, 'textOnSoundLevelChange');
const microphoneResultEvent = requireCapabilityEvent(microphoneCapability, 'textOnResult');
const vibrationVibrate = requireCapabilityMethod(vibrationCapability, 'vibrate');
const vibrationCancel = requireCapabilityMethod(vibrationCapability, 'cancel');
const poseRecenter = requireCapabilityMethod(poseCapability, 'recenter');
const poseOpenVideo = requireCapabilityMethod(poseCapability, 'openVideo');
const poseCreateVideoSource = requireCapabilityMethod(poseCapability, 'createVideoSource');
const poseEvent = requireCapabilityEvent(poseCapability, 'pose');
const vibrationPresetSchema = requireSchemaProperty('device.vibration.vibrate', vibrationVibrate.argumentsSchema, 'preset');
if (!Array.isArray(vibrationPresetSchema.enum) || vibrationPresetSchema.enum.length !== 17) throw new Error('Unexpected vibration preset enum.');

const capabilityIdStem = new Map([
  [cameraCapability.code, 'Camera'],
  [microphoneCapability.code, 'Microphone'],
  [midiCapability.code, 'Midi'],
  [vibrationCapability.code, 'Vibration'],
  [poseCapability.code, 'Pose6d'],
]);
const capabilityGroup = descriptor => `App SDK ❯ ${containsHan(descriptor.name) ? descriptor.name : `${descriptor.name}（乐器接口）`}`;

const makeCapabilityStatusFunctions = descriptor => {
  const stem = capabilityIdStem.get(descriptor.code);
  return [
    eventFunction({ name: `Is${stem}CapabilityDeclared`, fullName: `项目已声明${descriptor.name}能力`, description: `判断 capabilities.json 是否声明 ${descriptor.code}@${descriptor.apiVersion}。`, group: capabilityGroup(descriptor), functionType: 'Condition', sentence: `项目已声明${descriptor.name}能力`, code: extensionGuard('eventsFunctionContext.returnValue = false;', `const result = extension.callSync("playmesh.app.capabilities.getDeclared", [], ""); eventsFunctionContext.returnValue = !!(result.ok && Array.isArray(result.value) && result.value.includes(${JSON.stringify(descriptor.code)}));`) }),
    eventFunction({ name: `Is${stem}CapabilityAvailable`, fullName: `当前宿主可用${descriptor.name}能力`, description: `判断当前宿主实际可用且项目已声明 ${descriptor.code}@${descriptor.apiVersion}。`, group: capabilityGroup(descriptor), functionType: 'Condition', sentence: `当前宿主可用${descriptor.name}能力`, code: extensionGuard('eventsFunctionContext.returnValue = false;', `const result = extension.callSync("playmesh.app.capabilities.getAvailable", [], ""); eventsFunctionContext.returnValue = !!(result.ok && Array.isArray(result.value) && result.value.includes(${JSON.stringify(descriptor.code)}));`) }),
  ];
};

// Build create functions explicitly so every branch also copies its fulfilled
// or rejected non-throwing operation into Result.
const makeCapabilityCreateFunction = (descriptor, { parameters = [], options = 'undefined', validation = 'true', warning = '' } = {}) => {
  const stem = capabilityIdStem.get(descriptor.code);
  const callArgs = options === 'undefined' ? `[${JSON.stringify(descriptor.code)}]` : `[${JSON.stringify(descriptor.code)}, ${options}]`;
  return eventFunction({
    name: `Create${stem}Capability`, fullName: `创建${descriptor.name}能力实例`, description: `${descriptor.description}${warning ? ` ${warning}` : ''} 平台：${descriptor.supportedPlatforms.join('、')}；API ${descriptor.apiVersion}。`, group: capabilityGroup(descriptor), sentence: `创建${descriptor.name}能力实例`, async: true,
    parameters: [...parameters, resultVariable('接收能力句柄描述和 handleId。'), optionalOperationId()],
    code: asyncGuard(`((${validation}) ? extension.execute("playmesh.app.capabilities.create", ${callArgs}, ${argumentCode('OperationId')}, "") : extension.rejectOperation(${argumentCode('OperationId')}, "typed_capability_argument_invalid", ${JSON.stringify(`${descriptor.name}创建参数不符合后端 schema。`)}, "playmesh.app.capabilities.create")).then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; })`),
  });
};

const poseRateSchema = requireSchemaProperty('sensor.pose6d options', poseCapability.optionsSchema, 'rateHz');
const capabilityCreateFunctions = [
  makeCapabilityCreateFunction(cameraCapability, { warning: '这是 WebView 摄像头权限/声明实例，通常无需手动创建；实际访问使用项目声明和标准 Web API，本动作不会打开摄像头。' }),
  makeCapabilityCreateFunction(microphoneCapability),
  makeCapabilityCreateFunction(midiCapability, { warning: '这是 Web MIDI 权限/声明实例，通常无需手动创建；实际访问使用项目声明和标准 Web MIDI API，本动作不会连接 MIDI 设备。' }),
  makeCapabilityCreateFunction(vibrationCapability),
  makeCapabilityCreateFunction(poseCapability, {
    parameters: [requiredBoolean('UseRateHz', '是否显式传入采样频率。'), optionalNumber('RateHz', `采样频率，${poseRateSchema.minimum}～${poseRateSchema.maximum}；默认 ${poseRateSchema.default}。`, poseRateSchema.default)],
    options: `(() => { const options = {}; if (${argumentCode('UseRateHz')}) options.rateHz = ${argumentCode('RateHz')}; return options; })()`,
    validation: `(!${argumentCode('UseRateHz')} || (Number.isInteger(${argumentCode('RateHz')}) && ${argumentCode('RateHz')} >= ${poseRateSchema.minimum} && ${argumentCode('RateHz')} <= ${poseRateSchema.maximum}))`,
  }),
];

const makeKnownCapabilityDispose = descriptor => {
  const stem = capabilityIdStem.get(descriptor.code);
  return eventFunction({ name: `Dispose${stem}Capability`, fullName: `释放${descriptor.name}能力实例`, description: `释放 ${descriptor.code} 句柄及底层资源。`, group: capabilityGroup(descriptor), sentence: `释放${descriptor.name}句柄 _PARAM1_`, async: true, parameters: [handleIdParameter(`${descriptor.name}能力 handleId。`), optionalOperationId()], code: asyncGuard(`extension.execute("PlaymeshCapabilityHandle.dispose", [], ${argumentCode('OperationId')}, ${argumentCode('HandleId')})`) });
};

const micLocaleSchema = requireSchemaProperty('media.microphone.toText', microphoneToText.argumentsSchema, 'localeId');
const micListenSchema = requireSchemaProperty('media.microphone.toText', microphoneToText.argumentsSchema, 'listenFor');
const micPauseSchema = requireSchemaProperty('media.microphone.toText', microphoneToText.argumentsSchema, 'pauseFor');
const microphoneMethodFunctions = [
  eventFunction({
    name: 'StartMicrophoneSpeechToText', fullName: '启动麦克风语音转文字', description: `${microphoneToText.description} 必须由真实用户操作触发；当前 metadata 标记 requiresUserActivation=${microphoneToText.requiresUserActivation}。`, group: capabilityGroup(microphoneCapability), sentence: '启动麦克风语音转文字', async: true,
    parameters: [handleIdParameter('麦克风能力 handleId。'), requiredString('LocaleId', `识别 locale，长度至少 ${micLocaleSchema.minLength}。`), requiredNumber('ListenFor', `监听秒数，${micListenSchema.minimum}～${micListenSchema.maximum} 的整数。`), requiredNumber('PauseFor', `静音结束秒数，${micPauseSchema.minimum}～${micPauseSchema.maximum} 的整数且不得大于 ListenFor。`), resultVariable('接收 {started:boolean}。'), optionalOperationId()],
    code: asyncGuard(`((typeof ${argumentCode('LocaleId')} === "string" && ${argumentCode('LocaleId')}.trim().length >= ${micLocaleSchema.minLength}) && Number.isInteger(${argumentCode('ListenFor')}) && ${argumentCode('ListenFor')} >= ${micListenSchema.minimum} && ${argumentCode('ListenFor')} <= ${micListenSchema.maximum} && Number.isInteger(${argumentCode('PauseFor')}) && ${argumentCode('PauseFor')} >= ${micPauseSchema.minimum} && ${argumentCode('PauseFor')} <= ${micPauseSchema.maximum} && ${argumentCode('PauseFor')} <= ${argumentCode('ListenFor')} ? extension.execute("PlaymeshCapabilityHandle.invoke", [${JSON.stringify(microphoneToText.name)}, { localeId: ${argumentCode('LocaleId')}, listenFor: ${argumentCode('ListenFor')}, pauseFor: ${argumentCode('PauseFor')} }], ${argumentCode('OperationId')}, ${argumentCode('HandleId')}) : extension.rejectOperation(${argumentCode('OperationId')}, "microphone_arguments_invalid", "localeId/listenFor/pauseFor 不符合后端约束，且 pauseFor 不能大于 listenFor。", "PlaymeshCapabilityHandle.invoke")).then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; })`),
  }),
];

const vibrationArgumentProperties = vibrationVibrate.argumentsSchema.properties;
for (const name of ['duration', 'pattern', 'repeat', 'intensities', 'amplitude', 'sharpness', 'preset']) requireSchemaProperty('device.vibration.vibrate', vibrationVibrate.argumentsSchema, name);
const vibrationMethodFunctions = [
  eventFunction({
    name: 'VibrateDevice', fullName: '触发设备震动反馈', description: vibrationVibrate.description, group: capabilityGroup(vibrationCapability), sentence: '使用震动能力句柄 _PARAM1_ 触发反馈', async: true,
    parameters: [
      handleIdParameter('震动能力 handleId。'),
      requiredBoolean('UseDuration', '是否传入 duration。'), optionalNumber('Duration', `持续毫秒，整数且至少 ${vibrationArgumentProperties.duration.minimum}；默认 ${vibrationArgumentProperties.duration.default}。`, vibrationArgumentProperties.duration.default),
      requiredBoolean('UsePattern', '是否传入 pattern。'), requiredVariable('Pattern', '非负整数毫秒数组。'),
      requiredBoolean('UseRepeat', '是否传入 repeat。'), optionalNumber('Repeat', `-1 或 pattern 的有效索引；默认 ${vibrationArgumentProperties.repeat.default}。`, vibrationArgumentProperties.repeat.default),
      requiredBoolean('UseIntensities', '是否传入 intensities。'), requiredVariable('Intensities', '0～255 强度数组；非空时长度必须等于 pattern。'),
      requiredBoolean('UseAmplitude', '是否传入 amplitude。'), optionalNumber('Amplitude', '振幅必须为 -1 或 1～255；0 虽在 descriptor 范围内，但运行时明确拒绝。', vibrationArgumentProperties.amplitude.default),
      requiredBoolean('UseSharpness', '是否传入 sharpness。'), optionalNumber('Sharpness', `锐度 ${vibrationArgumentProperties.sharpness.minimum}～${vibrationArgumentProperties.sharpness.maximum}；默认 ${vibrationArgumentProperties.sharpness.default}。`, vibrationArgumentProperties.sharpness.default),
      requiredBoolean('UsePreset', '是否传入预设。'), optionalString('Preset', '17 个后端 descriptor 预设之一。', vibrationPresetSchema.enum),
      resultVariable('接收成功时的 null。'), optionalOperationId(),
    ],
    code: asyncGuard(`(() => { const args = {}; if (${argumentCode('UseDuration')}) args.duration = ${argumentCode('Duration')}; if (${argumentCode('UsePattern')}) args.pattern = ${variableCode('Pattern')}; if (${argumentCode('UseRepeat')}) args.repeat = ${argumentCode('Repeat')}; if (${argumentCode('UseIntensities')}) args.intensities = ${variableCode('Intensities')}; if (${argumentCode('UseAmplitude')}) args.amplitude = ${argumentCode('Amplitude')}; if (${argumentCode('UseSharpness')}) args.sharpness = ${argumentCode('Sharpness')}; if (${argumentCode('UsePreset')}) args.preset = ${argumentCode('Preset')}; const amplitudeOk = !${argumentCode('UseAmplitude')} || ${argumentCode('Amplitude')} === -1 || (Number.isInteger(${argumentCode('Amplitude')}) && ${argumentCode('Amplitude')} >= 1 && ${argumentCode('Amplitude')} <= 255); const invariantOk = amplitudeOk && (!${argumentCode('UseDuration')} || (Number.isInteger(${argumentCode('Duration')}) && ${argumentCode('Duration')} >= ${vibrationArgumentProperties.duration.minimum})) && (!${argumentCode('UseSharpness')} || (${argumentCode('Sharpness')} >= ${vibrationArgumentProperties.sharpness.minimum} && ${argumentCode('Sharpness')} <= ${vibrationArgumentProperties.sharpness.maximum})); const promise = invariantOk ? extension.execute("PlaymeshCapabilityHandle.invoke", [${JSON.stringify(vibrationVibrate.name)}, args], ${argumentCode('OperationId')}, ${argumentCode('HandleId')}) : extension.rejectOperation(${argumentCode('OperationId')}, "vibration_arguments_invalid", "震动参数不符合后端约束；amplitude 只允许 -1 或 1～255。", "PlaymeshCapabilityHandle.invoke"); return promise.then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; }); })()`),
  }),
  eventFunction({ name: 'CancelDeviceVibration', fullName: '取消设备震动反馈', description: vibrationCancel.description, group: capabilityGroup(vibrationCapability), sentence: '取消震动能力句柄 _PARAM1_ 的反馈', async: true, parameters: [handleIdParameter('震动能力 handleId。'), resultVariable('接收成功时的 null。'), optionalOperationId()], code: asyncGuard(`extension.execute("PlaymeshCapabilityHandle.invoke", [${JSON.stringify(vibrationCancel.name)}, {}], ${argumentCode('OperationId')}, ${argumentCode('HandleId')}).then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; })`) }),
];

const poseVideoProperties = poseOpenVideo.argumentsSchema.properties;
for (const name of ['width', 'height', 'fps']) requireSchemaProperty('sensor.pose6d.openVideo', poseOpenVideo.argumentsSchema, name);
const makePoseVideoFunction = (method, name, label) => eventFunction({
  name, fullName: label, description: method.description, group: capabilityGroup(poseCapability), sentence: label, async: true,
  parameters: [handleIdParameter('空间位姿能力 handleId。'), requiredBoolean('UseWidth', '是否显式传入宽度。'), optionalNumber('Width', `宽度 ${poseVideoProperties.width.minimum}～${poseVideoProperties.width.maximum}。`), requiredBoolean('UseHeight', '是否显式传入高度。'), optionalNumber('Height', `高度 ${poseVideoProperties.height.minimum}～${poseVideoProperties.height.maximum}。`), requiredBoolean('UseFps', '是否显式传入帧率。'), optionalNumber('Fps', `帧率 ${poseVideoProperties.fps.minimum}～${poseVideoProperties.fps.maximum}。`), resultVariable('接收媒体源描述和 source handleId。'), optionalOperationId()],
  code: asyncGuard(`(() => { const args = {}; if (${argumentCode('UseWidth')}) args.width = ${argumentCode('Width')}; if (${argumentCode('UseHeight')}) args.height = ${argumentCode('Height')}; if (${argumentCode('UseFps')}) args.fps = ${argumentCode('Fps')}; const valid = (!${argumentCode('UseWidth')} || (Number.isInteger(${argumentCode('Width')}) && ${argumentCode('Width')} >= ${poseVideoProperties.width.minimum} && ${argumentCode('Width')} <= ${poseVideoProperties.width.maximum})) && (!${argumentCode('UseHeight')} || (Number.isInteger(${argumentCode('Height')}) && ${argumentCode('Height')} >= ${poseVideoProperties.height.minimum} && ${argumentCode('Height')} <= ${poseVideoProperties.height.maximum})) && (!${argumentCode('UseFps')} || (Number.isInteger(${argumentCode('Fps')}) && ${argumentCode('Fps')} >= ${poseVideoProperties.fps.minimum} && ${argumentCode('Fps')} <= ${poseVideoProperties.fps.maximum})); const promise = valid ? extension.execute("PlaymeshCapabilityHandle.invoke", [${JSON.stringify(method.name)}, args], ${argumentCode('OperationId')}, ${argumentCode('HandleId')}) : extension.rejectOperation(${argumentCode('OperationId')}, "pose_video_arguments_invalid", "视频源 width/height/fps 不符合后端 schema。", "PlaymeshCapabilityHandle.invoke"); return promise.then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; }); })()`),
});
const poseMethodFunctions = [
  eventFunction({ name: 'RecenterPose6d', fullName: '重置空间位姿原点', description: poseRecenter.description, group: capabilityGroup(poseCapability), sentence: '重置空间位姿句柄 _PARAM1_ 的原点', async: true, parameters: [handleIdParameter('空间位姿能力 handleId。'), resultVariable('接收成功时的 null。'), optionalOperationId()], code: asyncGuard(`extension.execute("PlaymeshCapabilityHandle.invoke", [${JSON.stringify(poseRecenter.name)}, {}], ${argumentCode('OperationId')}, ${argumentCode('HandleId')}).then((result) => { extension.writeVariable(${argumentCode('Result')}, result && result.ok ? result.value : null); return result; })`) }),
  makePoseVideoFunction(poseOpenVideo, 'OpenPose6dVideoSource', '创建空间位姿实时视频源'),
  makePoseVideoFunction(poseCreateVideoSource, 'CreatePose6dVideoSourceLegacy', '创建空间位姿视频源（兼容别名）'),
];

const knownCapabilitySubscribeSpecs = [
  { command: 'PlaymeshCapabilityHandle.on', name: 'SubscribeMicrophoneSoundLevel', group: capabilityGroup(microphoneCapability), label: '订阅麦克风声音级别', description: microphoneSoundEvent.description, parameters: [handleIdParameter('麦克风能力 handleId。')], args: `[${JSON.stringify(microphoneSoundEvent.name)}]`, handle: 'HandleId' },
  { command: 'PlaymeshCapabilityHandle.on', name: 'SubscribeMicrophoneTextResult', group: capabilityGroup(microphoneCapability), label: '订阅麦克风识别结果', description: microphoneResultEvent.description, parameters: [handleIdParameter('麦克风能力 handleId。')], args: `[${JSON.stringify(microphoneResultEvent.name)}]`, handle: 'HandleId' },
  { command: 'PlaymeshCapabilityHandle.on', name: 'SubscribePose6d', group: capabilityGroup(poseCapability), label: '订阅空间位姿', description: poseEvent.description, parameters: [handleIdParameter('空间位姿能力 handleId。')], args: `[${JSON.stringify(poseEvent.name)}]`, handle: 'HandleId' },
];
const knownCapabilitySubscribeFunctions = knownCapabilitySubscribeSpecs.flatMap(spec => [makeTypedSubscribeFunction(spec), ...makeTypedEventQueueFunctions(spec)]);

const knownCapabilityEventFunctions = [
  eventFunction({ name: 'MicrophoneSoundLevel', fullName: '麦克风事件声音级别', description: '返回最早声音级别事件的 level。', group: capabilityGroup(microphoneCapability), functionType: 'Expression', expressionType: numberExpression, parameters: [requiredString('SubscriptionId', '麦克风声音级别订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = 0;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.level"); eventsFunctionContext.returnValue = value.exists ? extension.numberValue(value.value) : 0;`) }),
  eventFunction({ name: 'MicrophoneRecognizedWords', fullName: '麦克风识别文本', description: '返回最早识别结果事件的 recognizedWords。', group: capabilityGroup(microphoneCapability), functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '麦克风识别结果订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.recognizedWords"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'MicrophoneResultIsFinal', fullName: '麦克风识别结果是最终结果', description: '判断最早识别事件的 finalResult。', group: capabilityGroup(microphoneCapability), functionType: 'Condition', sentence: '麦克风订阅 _PARAM1_ 的识别结果是最终结果', parameters: [requiredString('SubscriptionId', '麦克风识别结果订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = false;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.finalResult"); eventsFunctionContext.returnValue = !!(value.exists && value.value === true);`) }),
  eventFunction({ name: 'MicrophoneResultType', fullName: '麦克风识别结果类型', description: '返回 partial、intermediate 或 finalResult。', group: capabilityGroup(microphoneCapability), functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '麦克风识别结果订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.resultType"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'MicrophoneConfidence', fullName: '麦克风识别置信度', description: '返回最早识别事件的 confidence。', group: capabilityGroup(microphoneCapability), functionType: 'Expression', expressionType: numberExpression, parameters: [requiredString('SubscriptionId', '麦克风识别结果订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = 0;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.confidence"); eventsFunctionContext.returnValue = value.exists ? extension.numberValue(value.value) : 0;`) }),
  eventFunction({ name: 'MicrophoneHasConfidenceRating', fullName: '麦克风结果具有置信度评级', description: '判断 hasConfidenceRating。', group: capabilityGroup(microphoneCapability), functionType: 'Condition', sentence: '麦克风订阅 _PARAM1_ 的结果具有置信度评级', parameters: [requiredString('SubscriptionId', '麦克风识别结果订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = false;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.hasConfidenceRating"); eventsFunctionContext.returnValue = !!(value.exists && value.value === true);`) }),
  eventFunction({ name: 'CopyMicrophoneAlternates', fullName: '复制麦克风候选识别结果', description: '复制 alternates 数组，保留 recognizedPhrases 的 null/数组语义。', group: capabilityGroup(microphoneCapability), sentence: '复制麦克风订阅 _PARAM1_ 的候选结果到 _PARAM2_', parameters: [requiredString('SubscriptionId', '麦克风识别结果订阅 ID。'), requiredVariable('Result', '接收 alternates 数组。')], code: extensionGuard('', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.alternates"); if (value.exists) extension.writeVariable(${argumentCode('Result')}, value.value);`) }),
  eventFunction({ name: 'Pose6dCaptureTimestampNs', fullName: '空间位姿捕获时间戳文本', description: '以字符串返回 captureTimestampNs，避免超过 JavaScript 安全整数精度。', group: capabilityGroup(poseCapability), functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '空间位姿订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.captureTimestampNs"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  eventFunction({ name: 'Pose6dTrackingState', fullName: '空间位姿跟踪状态', description: '返回 tracking、paused 或 stopped。', group: capabilityGroup(poseCapability), functionType: 'StringExpression', expressionType: stringExpression, parameters: [requiredString('SubscriptionId', '空间位姿订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = "";', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.trackingState"); eventsFunctionContext.returnValue = value.exists ? extension.stringValue(value.value) : "";`) }),
  ...[['PositionX', 0], ['PositionY', 1], ['PositionZ', 2], ['RotationX', 0], ['RotationY', 1], ['RotationZ', 2], ['RotationW', 3]].map(([suffix, index]) => {
    const isRotation = String(suffix).startsWith('Rotation');
    return eventFunction({ name: `Pose6d${suffix}`, fullName: `空间位姿${isRotation ? '旋转四元数' : '位置'} ${String(suffix).slice(-1)}`, description: `返回最早 pose 事件的 ${isRotation ? 'rotation' : 'position'}[${index}]。`, group: capabilityGroup(poseCapability), functionType: 'Expression', expressionType: numberExpression, parameters: [requiredString('SubscriptionId', '空间位姿订阅 ID。')], code: extensionGuard('eventsFunctionContext.returnValue = 0;', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value.${isRotation ? 'rotation' : 'position'}[${index}]"); eventsFunctionContext.returnValue = value.exists ? extension.numberValue(value.value) : 0;`) });
  }),
  eventFunction({ name: 'CopyPose6dEvent', fullName: '复制完整空间位姿事件', description: '复制 captureTimestampNs、trackingState、position 与 rotation。', group: capabilityGroup(poseCapability), sentence: '复制空间位姿订阅 _PARAM1_ 的事件到 _PARAM2_', parameters: [requiredString('SubscriptionId', '空间位姿订阅 ID。'), requiredVariable('Result', '接收完整 pose 的变量。')], code: extensionGuard('', `const value = extension.eventAt(${argumentCode('SubscriptionId')}, "value"); if (value.exists) extension.writeVariable(${argumentCode('Result')}, value.value);`) }),
];

const capabilityFunctions = [
  ...builtInCapabilityDescriptors.flatMap(makeCapabilityStatusFunctions),
  ...capabilityCreateFunctions,
  ...builtInCapabilityDescriptors.map(makeKnownCapabilityDispose),
  ...microphoneMethodFunctions,
  ...vibrationMethodFunctions,
  ...poseMethodFunctions,
  ...knownCapabilitySubscribeFunctions,
  ...knownCapabilityEventFunctions,
];

const eventsFunctions = [
  eventFunction({
    name: 'onFirstSceneLoaded',
    fullName: '',
    private: true,
    sentence: '',
    code: runtimeCode,
  }),
  eventFunction({
    name: 'IsSdkPresent', fullName: 'Playmesh SDK is present', description: 'Checks whether the current page context exposes the Playmesh SDK. This does not cache the SDK object.', group: 'Diagnostics ❯ SDK', functionType: 'Condition', sentence: 'Playmesh SDK is present',
    code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.isSdkPresent();'),
  }),
];

const operationFunctions = [
  eventFunction({ name: 'OperationFinished', fullName: 'Playmesh operation finished', description: 'Checks whether an operation result exists.', group: 'Operations', functionType: 'Condition', sentence: 'Operation _PARAM1_ finished', parameters: [stringParam('OperationId', 'Operation ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = !!extension.getOperation(eventsFunctionContext.getArgument("OperationId"));') }),
  eventFunction({ name: 'OperationSucceeded', fullName: 'Playmesh operation succeeded', description: 'Checks whether an operation completed successfully.', group: 'Operations', functionType: 'Condition', sentence: 'Operation _PARAM1_ succeeded', parameters: [stringParam('OperationId', 'Operation ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const operation = extension.getOperation(eventsFunctionContext.getArgument("OperationId")); eventsFunctionContext.returnValue = !!(operation && operation.ok);') }),
  eventFunction({ name: 'OperationFailed', fullName: 'Playmesh operation failed', description: 'Checks whether an operation completed with a captured failure.', group: 'Operations', functionType: 'Condition', sentence: 'Operation _PARAM1_ failed', parameters: [stringParam('OperationId', 'Operation ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const operation = extension.getOperation(eventsFunctionContext.getArgument("OperationId")); eventsFunctionContext.returnValue = !!(operation && !operation.ok);') }),
  eventFunction({ name: 'OperationValueExists', fullName: 'Operation JSON path exists', description: 'Checks a JSON path in a successful operation value.', group: 'Operations', functionType: 'Condition', sentence: 'Operation _PARAM1_ value has path _PARAM2_', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path, such as $.players[0].id or /players/0/id.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")).exists;') }),
  eventFunction({ name: 'OperationValueIsNull', fullName: 'Operation value is null', description: 'Distinguishes a successful null SDK value from missing data.', group: 'Operations', functionType: 'Condition', sentence: 'Operation _PARAM1_ path _PARAM2_ is null', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const result = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = result.exists && result.value === null;') }),
  eventFunction({ name: 'OperationValueType', fullName: 'Playmesh operation value type', description: 'Returns null, undefined, handle, string, number, boolean, object, subscription, or handler for a successful operation; returns error for a failed operation.', group: 'Operations', functionType: 'StringExpression', parameters: [stringParam('OperationId', 'Operation ID.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const operation = extension.getOperation(eventsFunctionContext.getArgument("OperationId")); eventsFunctionContext.returnValue = operation ? (operation.ok ? operation.valueType : "error") : "";') }),
  eventFunction({ name: 'OperationValueEquals', fullName: 'Operation value equals JSON', description: 'Compares an operation value with a JSON value.', group: 'Operations', functionType: 'Condition', sentence: 'Operation _PARAM1_ path _PARAM2_ equals JSON _PARAM3_', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path.'), stringParam('ExpectedJson', 'Expected JSON value.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'const result = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = result.exists && extension.jsonEquals(result.value, eventsFunctionContext.getArgument("ExpectedJson"));') }),
  eventFunction({ name: 'OperationJson', fullName: 'Operation result as JSON', description: 'Returns the whole operation record.', group: 'Operations', functionType: 'StringExpression', parameters: [stringParam('OperationId', 'Operation ID.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'eventsFunctionContext.returnValue = extension.safeJson(extension.getOperation(eventsFunctionContext.getArgument("OperationId")));') }),
  eventFunction({ name: 'OperationValueJson', fullName: 'Operation value path as JSON', description: 'Returns one operation value path as JSON.', group: 'Operations', functionType: 'StringExpression', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'const result = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = extension.safeJson(result.exists ? result.value : null);') }),
  eventFunction({ name: 'OperationValueString', fullName: 'Operation value path as text', description: 'Returns a scalar as text or a structure as JSON text.', group: 'Operations', functionType: 'StringExpression', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const result = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = result.exists ? extension.stringValue(result.value) : "";') }),
  eventFunction({ name: 'OperationValueNumber', fullName: 'Operation value path as number', description: 'Returns a numeric operation value, or 0 when it is not numeric.', group: 'Operations', functionType: 'Expression', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path.')], expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'const result = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = result.exists ? extension.numberValue(result.value) : 0;') }),
  eventFunction({ name: 'CopyOperationValueToVariable', fullName: 'Copy operation value to a variable', description: 'Copies a JSON path, including structures and arrays, to a GDevelop variable.', group: 'Operations', sentence: 'Copy operation _PARAM1_ path _PARAM2_ to _PARAM3_', parameters: [stringParam('OperationId', 'Operation ID.'), stringParam('Path', 'JSON path.'), variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'const result = extension.operationValueAt(eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("Path")); if (result.exists) extension.writeVariable(eventsFunctionContext.getArgument("Variable"), result.value);') }),
  eventFunction({ name: 'ForgetOperation', fullName: 'Forget a Playmesh operation', description: 'Removes one stored operation result.', group: 'Operations', sentence: 'Forget operation _PARAM1_', parameters: [stringParam('OperationId', 'Operation ID.')], code: extensionGuard('', 'extension.forgetOperation(eventsFunctionContext.getArgument("OperationId"));') }),
  eventFunction({ name: 'LastOperationId', fullName: 'Last Playmesh operation ID', description: 'Returns the most recently stored operation ID.', group: 'Operations', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.getLastOperationId();') }),
];

const eventQueueFunctions = [
  eventFunction({ name: 'Unsubscribe', fullName: 'Unsubscribe a Playmesh event', description: 'Calls the SDK unsubscribe function, or removes the exact callback used by addEventListener.', group: 'Event subscriptions', sentence: 'Unsubscribe _PARAM1_', parameters: [stringParam('SubscriptionId', 'Subscription ID.')], code: extensionGuard('', 'extension.unsubscribe(eventsFunctionContext.getArgument("SubscriptionId"));') }),
  eventFunction({ name: 'HasSubscription', fullName: 'Playmesh subscription exists', description: 'Checks whether a subscription is active.', group: 'Event subscriptions', functionType: 'Condition', sentence: 'Subscription _PARAM1_ exists', parameters: [stringParam('SubscriptionId', 'Subscription ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.hasSubscription(eventsFunctionContext.getArgument("SubscriptionId"));') }),
  eventFunction({ name: 'HasEvent', fullName: 'Playmesh event is queued', description: 'Checks whether a subscription has a queued event.', group: 'Event subscriptions', functionType: 'Condition', sentence: 'Subscription _PARAM1_ has an event', parameters: [stringParam('SubscriptionId', 'Subscription ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.eventCount(eventsFunctionContext.getArgument("SubscriptionId")) > 0;') }),
  eventFunction({ name: 'EventValueExists', fullName: 'Queued event JSON path exists', description: 'Checks a JSON path in the oldest queued event.', group: 'Event subscriptions', functionType: 'Condition', sentence: 'Event for _PARAM1_ has path _PARAM2_', parameters: [stringParam('SubscriptionId', 'Subscription ID.'), stringParam('Path', 'JSON path.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.eventAt(eventsFunctionContext.getArgument("SubscriptionId"), eventsFunctionContext.getArgument("Path")).exists;') }),
  eventFunction({ name: 'EventCount', fullName: 'Queued Playmesh event count', description: 'Returns the bounded queue size for a subscription.', group: 'Event subscriptions', functionType: 'Expression', parameters: [stringParam('SubscriptionId', 'Subscription ID.')], expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'eventsFunctionContext.returnValue = extension.eventCount(eventsFunctionContext.getArgument("SubscriptionId"));') }),
  eventFunction({ name: 'PeekEventJson', fullName: 'Oldest queued event as JSON', description: 'Returns the oldest event without removing it.', group: 'Event subscriptions', functionType: 'StringExpression', parameters: [stringParam('SubscriptionId', 'Subscription ID.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'eventsFunctionContext.returnValue = extension.safeJson(extension.peekEvent(eventsFunctionContext.getArgument("SubscriptionId")));') }),
  eventFunction({ name: 'EventValueJson', fullName: 'Queued event path as JSON', description: 'Returns a JSON path from the oldest event.', group: 'Event subscriptions', functionType: 'StringExpression', parameters: [stringParam('SubscriptionId', 'Subscription ID.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'const result = extension.eventAt(eventsFunctionContext.getArgument("SubscriptionId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = extension.safeJson(result.exists ? result.value : null);') }),
  eventFunction({ name: 'PopEventToVariable', fullName: 'Pop a Playmesh event to a variable', description: 'Removes the oldest event and copies it to a variable.', group: 'Event subscriptions', sentence: 'Pop event for _PARAM1_ to _PARAM2_', parameters: [stringParam('SubscriptionId', 'Subscription ID.'), variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'const value = extension.popEvent(eventsFunctionContext.getArgument("SubscriptionId")); if (value !== null) extension.writeVariable(eventsFunctionContext.getArgument("Variable"), value);') }),
  eventFunction({ name: 'ClearEvents', fullName: 'Clear queued Playmesh events', description: 'Clears one subscription queue without unsubscribing.', group: 'Event subscriptions', sentence: 'Clear events for _PARAM1_', parameters: [stringParam('SubscriptionId', 'Subscription ID.')], code: extensionGuard('', 'extension.clearEvents(eventsFunctionContext.getArgument("SubscriptionId"));') }),
];

const requestFunctions = [
  eventFunction({ name: 'UnregisterHandler', fullName: 'Unregister a Playmesh request handler', description: 'Unregisters a handler and safely completes its pending requests with their default value.', group: 'Request handlers', sentence: 'Unregister handler _PARAM1_', parameters: [stringParam('HandlerId', 'Handler ID.')], code: extensionGuard('', 'extension.unregisterHandler(eventsFunctionContext.getArgument("HandlerId"));') }),
  eventFunction({ name: 'HasRequest', fullName: 'Playmesh request is queued', description: 'Checks whether a handler or sync callback has a queued request.', group: 'Request handlers', functionType: 'Condition', sentence: 'Handler _PARAM1_ has a request', parameters: [stringParam('HandlerId', 'Handler or sync callback ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.requestCount(eventsFunctionContext.getArgument("HandlerId")) > 0;') }),
  eventFunction({ name: 'RequestValueExists', fullName: 'Queued request JSON path exists', description: 'Checks a JSON path in the oldest queued request.', group: 'Request handlers', functionType: 'Condition', sentence: 'Request for _PARAM1_ has path _PARAM2_', parameters: [stringParam('HandlerId', 'Handler ID.'), stringParam('Path', 'JSON path.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.requestAt(eventsFunctionContext.getArgument("HandlerId"), eventsFunctionContext.getArgument("Path")).exists;') }),
  eventFunction({ name: 'RequestCount', fullName: 'Queued Playmesh request count', description: 'Returns the bounded queue size for a handler.', group: 'Request handlers', functionType: 'Expression', parameters: [stringParam('HandlerId', 'Handler ID.')], expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'eventsFunctionContext.returnValue = extension.requestCount(eventsFunctionContext.getArgument("HandlerId"));') }),
  eventFunction({ name: 'PeekRequestJson', fullName: 'Oldest Playmesh request as JSON', description: 'Returns the oldest callback request without removing it.', group: 'Request handlers', functionType: 'StringExpression', parameters: [stringParam('HandlerId', 'Handler ID.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'eventsFunctionContext.returnValue = extension.safeJson(extension.peekRequest(eventsFunctionContext.getArgument("HandlerId")));') }),
  eventFunction({ name: 'RequestValueJson', fullName: 'Queued request path as JSON', description: 'Returns a JSON path from the oldest request.', group: 'Request handlers', functionType: 'StringExpression', parameters: [stringParam('HandlerId', 'Handler ID.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'const result = extension.requestAt(eventsFunctionContext.getArgument("HandlerId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = extension.safeJson(result.exists ? result.value : null);') }),
  eventFunction({ name: 'PopRequestToVariable', fullName: 'Pop a Playmesh request to a variable', description: 'Removes the oldest request record from the queue. The request remains answerable by request ID.', group: 'Request handlers', sentence: 'Pop request for _PARAM1_ to _PARAM2_', parameters: [stringParam('HandlerId', 'Handler ID.'), variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'const value = extension.popRequest(eventsFunctionContext.getArgument("HandlerId")); if (value !== null) extension.writeVariable(eventsFunctionContext.getArgument("Variable"), value);') }),
  eventFunction({ name: 'RespondRequest', fullName: 'Respond to a Playmesh callback request', description: 'Answers a callback request. Modes: result/next for JSON, keep/pass/void, null, replace for binary data, or reject.', group: 'Request handlers', sentence: 'Respond to request _PARAM1_ with mode _PARAM2_ and JSON or binary _PARAM3_', parameters: [stringParam('RequestId', 'Request ID from the queued record.'), stringParam('Mode', 'result, next, keep, pass, void, null, replace, or reject.', ['result', 'next', 'keep', 'pass', 'void', 'null', 'replace', 'reject']), stringParam('ResponseJson', 'JSON response. Binary replace accepts a binary argument object.')], code: extensionGuard('', 'extension.respond(eventsFunctionContext.getArgument("RequestId"), eventsFunctionContext.getArgument("ResponseJson"), eventsFunctionContext.getArgument("Mode"));') }),
  eventFunction({ name: 'CancelRequest', fullName: 'Cancel a Playmesh callback request', description: 'Completes a pending request with its safe default: null, pass, or keep.', group: 'Request handlers', sentence: 'Cancel request _PARAM1_', parameters: [stringParam('RequestId', 'Request ID.')], code: extensionGuard('', 'extension.cancelRequest(eventsFunctionContext.getArgument("RequestId"));') }),
];

const handleFunctions = [
  eventFunction({ name: 'HasHandle', fullName: 'Playmesh handle exists', description: 'Checks whether an opaque returned-object handle is retained.', group: 'Handles', functionType: 'Condition', sentence: 'Handle _PARAM1_ exists', parameters: [stringParam('HandleId', 'Handle ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.hasHandle(eventsFunctionContext.getArgument("HandleId"));') }),
  eventFunction({ name: 'HandlePropertyExists', fullName: 'Handle descriptor JSON path exists', description: 'Checks a JSON path in a safe handle descriptor.', group: 'Handles', functionType: 'Condition', sentence: 'Handle _PARAM1_ has descriptor path _PARAM2_', parameters: [stringParam('HandleId', 'Handle ID.'), stringParam('Path', 'JSON path.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.handlePropertyAt(eventsFunctionContext.getArgument("HandleId"), eventsFunctionContext.getArgument("Path")).exists;') }),
  eventFunction({ name: 'IsOpaqueMediaStream', fullName: 'Handle is an opaque media stream', description: 'Checks that a media stream is retained as an opaque handle and never copied into GDevelop variables.', group: 'Handles', functionType: 'Condition', sentence: 'Handle _PARAM1_ is an opaque media stream', parameters: [stringParam('HandleId', 'Handle ID.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.handleType(eventsFunctionContext.getArgument("HandleId")) === "MediaStream";') }),
  eventFunction({ name: 'HandleType', fullName: 'Playmesh handle type', description: 'Returns the retained interface type.', group: 'Handles', functionType: 'StringExpression', parameters: [stringParam('HandleId', 'Handle ID.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.handleType(eventsFunctionContext.getArgument("HandleId"));') }),
  eventFunction({ name: 'LastHandleId', fullName: 'Last Playmesh handle ID', description: 'Returns the most recently created or discovered handle ID, including a generated media abort handle.', group: 'Handles', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.getLastHandleId();') }),
  eventFunction({ name: 'HandlePropertyJson', fullName: 'Handle descriptor path as JSON', description: 'Returns a safe handle descriptor path as JSON.', group: 'Handles', functionType: 'StringExpression', parameters: [stringParam('HandleId', 'Handle ID.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'const result = extension.handlePropertyAt(eventsFunctionContext.getArgument("HandleId"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = extension.safeJson(result.exists ? result.value : null);') }),
  eventFunction({ name: 'CopyHandlePropertyToVariable', fullName: 'Copy handle descriptor path to a variable', description: 'Copies safe handle metadata, never the opaque SDK object.', group: 'Handles', sentence: 'Copy handle _PARAM1_ descriptor path _PARAM2_ to _PARAM3_', parameters: [stringParam('HandleId', 'Handle ID.'), stringParam('Path', 'JSON path.'), variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'const result = extension.handlePropertyAt(eventsFunctionContext.getArgument("HandleId"), eventsFunctionContext.getArgument("Path")); if (result.exists) extension.writeVariable(eventsFunctionContext.getArgument("Variable"), result.value);') }),
  eventFunction({ name: 'ReleaseHandle', fullName: 'Release a Playmesh handle', description: 'Forgets the extension reference without calling dispose, close, or stop. Call the relevant SDK command first when cleanup is required.', group: 'Handles', sentence: 'Release handle _PARAM1_', parameters: [stringParam('HandleId', 'Handle ID.')], code: extensionGuard('', 'extension.releaseHandle(eventsFunctionContext.getArgument("HandleId"));') }),
];

const errorFunctions = [
  eventFunction({ name: 'HasError', fullName: 'Playmesh extension has an error', description: 'Checks the bounded non-fatal error queue.', group: 'Errors', functionType: 'Condition', sentence: 'Playmesh extension has an error', code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.errorCount() > 0;') }),
  eventFunction({ name: 'ErrorCount', fullName: 'Playmesh extension error count', description: 'Returns the bounded error queue size.', group: 'Errors', functionType: 'Expression', expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'eventsFunctionContext.returnValue = extension.errorCount();') }),
  eventFunction({ name: 'LastErrorJson', fullName: 'Latest Playmesh extension error as JSON', description: 'Returns the most recent captured failure.', group: 'Errors', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'eventsFunctionContext.returnValue = extension.safeJson(extension.lastError());') }),
  eventFunction({ name: 'LastErrorCode', fullName: 'Latest Playmesh extension error code', description: 'Returns the stable local error code.', group: 'Errors', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const error = extension.lastError(); eventsFunctionContext.returnValue = error ? error.code : "";') }),
  eventFunction({ name: 'LastErrorMessage', fullName: 'Latest Playmesh extension error message', description: 'Returns the bounded error message.', group: 'Errors', functionType: 'StringExpression', expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const error = extension.lastError(); eventsFunctionContext.returnValue = error ? error.message : "";') }),
  eventFunction({ name: 'PopErrorToVariable', fullName: 'Pop a Playmesh extension error to a variable', description: 'Removes the oldest error and copies it to a variable.', group: 'Errors', sentence: 'Pop oldest Playmesh error to _PARAM1_', parameters: [variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'const value = extension.popError(); if (value !== null) extension.writeVariable(eventsFunctionContext.getArgument("Variable"), value);') }),
  eventFunction({ name: 'ClearErrors', fullName: 'Clear Playmesh extension errors', description: 'Clears the bounded local error queue.', group: 'Errors', sentence: 'Clear Playmesh extension errors', code: extensionGuard('', 'extension.clearErrors();') }),
];

const jsonFunctions = [
  eventFunction({ name: 'JsonPathExists', fullName: 'JSON path exists', description: 'Checks a safe dot, bracket, or JSON Pointer path without evaluating code.', group: 'JSON paths', functionType: 'Condition', sentence: 'JSON _PARAM1_ has path _PARAM2_', parameters: [stringParam('Json', 'JSON value.'), stringParam('Path', 'JSON path.')], code: extensionGuard('eventsFunctionContext.returnValue = false;', 'eventsFunctionContext.returnValue = extension.queryJson(eventsFunctionContext.getArgument("Json"), eventsFunctionContext.getArgument("Path")).exists;') }),
  eventFunction({ name: 'JsonPathJson', fullName: 'JSON path as JSON', description: 'Returns a JSON path as JSON text.', group: 'JSON paths', functionType: 'StringExpression', parameters: [stringParam('Json', 'JSON value.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'const result = extension.queryJson(eventsFunctionContext.getArgument("Json"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = extension.safeJson(result.exists ? result.value : null);') }),
  eventFunction({ name: 'JsonPathString', fullName: 'JSON path as text', description: 'Returns a scalar as text or a structure as JSON text.', group: 'JSON paths', functionType: 'StringExpression', parameters: [stringParam('Json', 'JSON value.'), stringParam('Path', 'JSON path.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'const result = extension.queryJson(eventsFunctionContext.getArgument("Json"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = result.exists ? extension.stringValue(result.value) : "";') }),
  eventFunction({ name: 'JsonPathNumber', fullName: 'JSON path as number', description: 'Returns a numeric path, or 0 when it is not numeric.', group: 'JSON paths', functionType: 'Expression', parameters: [stringParam('Json', 'JSON value.'), stringParam('Path', 'JSON path.')], expressionType: numberExpression, code: extensionGuard('eventsFunctionContext.returnValue = 0;', 'const result = extension.queryJson(eventsFunctionContext.getArgument("Json"), eventsFunctionContext.getArgument("Path")); eventsFunctionContext.returnValue = result.exists ? extension.numberValue(result.value) : 0;') }),
  eventFunction({ name: 'CopyJsonPathToVariable', fullName: 'Copy JSON path to a variable', description: 'Copies a JSON path, including arrays and structures, to a variable.', group: 'JSON paths', sentence: 'Copy JSON _PARAM1_ path _PARAM2_ to _PARAM3_', parameters: [stringParam('Json', 'JSON value.'), stringParam('Path', 'JSON path.'), variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'const result = extension.queryJson(eventsFunctionContext.getArgument("Json"), eventsFunctionContext.getArgument("Path")); if (result.exists) extension.writeVariable(eventsFunctionContext.getArgument("Variable"), result.value);') }),
];

const binaryFunctions = [
  eventFunction({ name: 'Utf8ToBase64', fullName: 'UTF-8 text to base64', description: 'Encodes text losslessly for binary SDK arguments.', group: 'Binary and files', functionType: 'StringExpression', parameters: [stringParam('Text', 'UTF-8 text.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.bytesToBase64(extension.utf8ToBytes(eventsFunctionContext.getArgument("Text")));') }),
  eventFunction({ name: 'Base64ToUtf8', fullName: 'Base64 to UTF-8 text', description: 'Decodes a binary base64 value as UTF-8.', group: 'Binary and files', functionType: 'StringExpression', parameters: [stringParam('Base64', 'Base64 value.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.bytesToUtf8(extension.base64ToBytes(eventsFunctionContext.getArgument("Base64")));') }),
  eventFunction({ name: 'Base64ToHex', fullName: 'Base64 to hex', description: 'Converts base64 bytes to lowercase hexadecimal.', group: 'Binary and files', functionType: 'StringExpression', parameters: [stringParam('Base64', 'Base64 value.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.bytesToHex(extension.base64ToBytes(eventsFunctionContext.getArgument("Base64")));') }),
  eventFunction({ name: 'HexToBase64', fullName: 'Hex to base64', description: 'Converts hexadecimal bytes to base64.', group: 'Binary and files', functionType: 'StringExpression', parameters: [stringParam('Hex', 'Hexadecimal value.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.bytesToBase64(extension.hexToBytes(eventsFunctionContext.getArgument("Hex")));') }),
  eventFunction({ name: 'BinaryArgumentJson', fullName: 'Binary SDK argument JSON', description: 'Builds a lossless special argument for UTF-8, base64, hex, or byte-array JSON input.', group: 'Binary and files', functionType: 'StringExpression', parameters: [stringParam('Encoding', 'utf8, base64, hex, or bytes.', ['utf8', 'base64', 'hex', 'bytes']), stringParam('Data', 'Text, base64, hex, or a JSON byte array.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'eventsFunctionContext.returnValue = extension.binaryArgumentJson(eventsFunctionContext.getArgument("Encoding"), eventsFunctionContext.getArgument("Data"));') }),
  eventFunction({ name: 'VariableToBase64', fullName: 'Variable bytes to base64', description: 'Encodes a string variable as UTF-8 or an array/structure of 0-255 bytes.', group: 'Binary and files', functionType: 'StringExpression', parameters: [variableParam('Variable', 'Source variable.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "";', 'eventsFunctionContext.returnValue = extension.bytesToBase64(extension.variableBytes(eventsFunctionContext.getArgument("Variable")));') }),
  eventFunction({ name: 'Base64ToVariable', fullName: 'Base64 bytes to a variable', description: 'Copies decoded bytes as a numeric array.', group: 'Binary and files', sentence: 'Decode base64 _PARAM1_ to _PARAM2_', parameters: [stringParam('Base64', 'Base64 value.'), variableParam('Variable', 'Destination variable.')], code: extensionGuard('', 'extension.writeVariable(eventsFunctionContext.getArgument("Variable"), Array.from(extension.base64ToBytes(eventsFunctionContext.getArgument("Base64"))));') }),
  eventFunction({ name: 'FileArgumentJson', fullName: 'File SDK argument JSON', description: 'Builds a File argument from text, base64, hex, or byte-array JSON.', group: 'Binary and files', functionType: 'StringExpression', parameters: [stringParam('Name', 'File name.'), stringParam('MimeType', 'MIME type.'), stringParam('Encoding', 'text, base64, hex, or bytes.', ['text', 'base64', 'hex', 'bytes']), stringParam('Data', 'Encoded file data.')], expressionType: stringExpression, code: extensionGuard('eventsFunctionContext.returnValue = "null";', 'eventsFunctionContext.returnValue = extension.fileArgumentJson(eventsFunctionContext.getArgument("Name"), eventsFunctionContext.getArgument("MimeType"), eventsFunctionContext.getArgument("Encoding"), eventsFunctionContext.getArgument("Data"));') }),
  eventFunction({ name: 'UploadFile', fullName: 'Upload a File to a Playmesh storage bucket', description: 'Creates a File from text/base64/hex/bytes and calls PlaymeshStorageBucket.upload.', group: 'Main SDK ❯ Storage', sentence: 'Upload _PARAM2_ from _PARAM4_ to bucket handle _PARAM1_ as operation _PARAM5_', async: true, private: true, parameters: [stringParam('BucketHandleId', 'PlaymeshStorageBucket handle ID.'), stringParam('Name', 'File name.'), stringParam('MimeType', 'MIME type.'), stringParam('Encoding', 'text, base64, hex, or bytes.', ['text', 'base64', 'hex', 'bytes']), stringParam('Data', 'Encoded file data.'), stringParam('OperationId', 'Operation ID.')], code: asyncGuard('extension.execute("PlaymeshStorageBucket.upload", "[" + extension.fileArgumentJson(eventsFunctionContext.getArgument("Name"), eventsFunctionContext.getArgument("MimeType"), eventsFunctionContext.getArgument("Encoding"), eventsFunctionContext.getArgument("Data")) + "]", eventsFunctionContext.getArgument("OperationId"), eventsFunctionContext.getArgument("BucketHandleId"))') }),
];

const mediaFunctions = [
  eventFunction({ name: 'CreateAbortHandle', fullName: 'Create a media abort handle', description: 'Creates an AbortController retained as an opaque extension handle.', group: 'Media', sentence: 'Create media abort handle _PARAM1_', parameters: [stringParam('HandleId', 'Preferred handle ID, or empty to generate one.')], code: extensionGuard('', 'extension.createAbort(eventsFunctionContext.getArgument("HandleId"));') }),
  eventFunction({ name: 'AbortMediaOpen', fullName: 'Abort a media open operation', description: 'Aborts media negotiation through a retained AbortController.', group: 'Media', sentence: 'Abort media using handle _PARAM1_', parameters: [stringParam('AbortHandleId', 'AbortController handle ID.')], code: extensionGuard('', 'extension.abort(eventsFunctionContext.getArgument("AbortHandleId"));') }),
  eventFunction({ name: 'OpenMedia', fullName: 'Open a Playmesh media source', description: 'Opens a capability-issued media source. The session and stream are retained as handles; the stream is exposed only as safe opaque metadata.', group: 'App SDK ❯ Media', sentence: 'Open media source handle _PARAM1_ with abort handle _PARAM2_ as operation _PARAM3_', async: true, private: true, parameters: [stringParam('SourceHandleId', 'PlaymeshAppMediaSource handle ID.'), stringParam('AbortHandleId', 'Optional AbortController handle ID.'), stringParam('OperationId', 'Operation ID.')], code: asyncGuard('extension.execute("playmesh.app.media.open", extension.safeJson([{ $handle: eventsFunctionContext.getArgument("SourceHandleId") }, eventsFunctionContext.getArgument("AbortHandleId") ? { signal: { $abortSignal: eventsFunctionContext.getArgument("AbortHandleId") } } : {}]), eventsFunctionContext.getArgument("OperationId"), "")') }),
];

eventsFunctions.push(
  ...semanticCommandFunctions,
  ...operationFunctions,
  ...eventQueueFunctions,
  ...requestFunctions,
  ...handleFunctions,
  ...errorFunctions,
  ...jsonFunctions,
  ...binaryFunctions,
  ...mediaFunctions,
  ...typedExecuteFunctions,
  ...typedSubscribeFunctions,
  ...typedHandlerFunctions,
  ...advancedFunctions,
  ...propertyFunctions,
  ...synchronousValueFunctions,
  ...eventFieldFunctions,
  ...typedResponseFunctions,
  ...capabilityFunctions,
);

const publicEventsFunctions = eventsFunctions.filter(eventFunction => !eventFunction.private);
for (const eventFunction of publicEventsFunctions) {
  if (!containsHan(eventFunction.fullName)) throw new Error(`Public function fullName is not Chinese: ${eventFunction.name}`);
  if (!eventFunction.group || !eventFunction.group.includes(' ❯ ') || eventFunction.group.split(' ❯ ').some(segment => !containsHan(segment))) {
    throw new Error(`Public function group is not a two-level Chinese group: ${eventFunction.name}`);
  }
  if (!containsHan(eventFunction.description)) throw new Error(`Public function description is not Chinese: ${eventFunction.name}`);
  if (eventFunction.sentence && !containsHan(eventFunction.sentence)) throw new Error(`Public function sentence is not Chinese: ${eventFunction.name}`);
  for (const functionParameter of eventFunction.parameters) {
    if (!containsHan(functionParameter.description)) {
      throw new Error(`Public parameter description is not Chinese: ${eventFunction.name}.${functionParameter.name}`);
    }
  }
}

const visibleGroupRoots = new Set(publicEventsFunctions.map(eventFunction => eventFunction.group.split(' ❯ ')[0]));
if (visibleGroupRoots.size !== 6) throw new Error(`Expected 6 Chinese extension group roots, received ${visibleGroupRoots.size}.`);

const icon = `data:image/png;base64,${extensionIconBytes.toString('base64')}`;

const extension = {
  author: 'Playmesh',
  category: 'Network',
  extensionNamespace: '',
  gdevelopVersion: '>=5.6.276',
  fullName: 'Playmesh SDK（游戏与原生能力）',
  helpPath: '',
  iconUrl: icon,
  name: 'Playmesh',
  previewIconUrl: icon,
  shortDescription: '使用当前游戏页面中已存在的 Playmesh 游戏 SDK 与原生 App SDK。',
  version: '2.0.0',
  description: '面向当前 Playmesh SDK 上下文的非致命、允许列表式 GDevelop 事件桥。它公开游戏 SDK、原生 App 能力、返回对象句柄、事件、回调请求、JSON 路径、二进制值、文件与媒体；不会加载另一份 SDK，也不会自行建立传输通道。',
  tags: ['playmesh', 'sdk', 'multiplayer', 'native', 'storage', 'media'],
  authorIds: [],
  dependencies: [],
  globalVariables: [],
  sceneVariables: [],
  eventsFunctions,
  eventsBasedBehaviors: [],
  eventsBasedObjects: [],
};

const outputPath = resolve(scriptsDirectory, '..', 'extensions', 'Playmesh.json');
const generatedSource = `${JSON.stringify(extension, null, 2)}\n`;
if (process.argv.includes('--check')) {
  let existingCapabilitySnapshotSource = '';
  let hasExistingCapabilitySnapshot = true;
  try { existingCapabilitySnapshotSource = readFileSync(builtInCapabilitySnapshotPath, 'utf8'); }
  catch (_) {
    hasExistingCapabilitySnapshot = false;
    console.error(`Missing generated capability snapshot: ${builtInCapabilitySnapshotPath}`);
    process.exitCode = 1;
  }
  if (hasExistingCapabilitySnapshot && existingCapabilitySnapshotSource !== extractedBuiltInCapabilitySnapshotSource) {
    console.error(`Generated capability snapshot is stale: ${builtInCapabilitySnapshotPath}`);
    process.exitCode = 1;
  }
  let existingSource = '';
  let hasExistingSource = true;
  try { existingSource = readFileSync(outputPath, 'utf8'); }
  catch (error) {
    hasExistingSource = false;
    console.error(`Missing generated Playmesh extension: ${outputPath}`);
    process.exitCode = 1;
  }
  if (hasExistingSource && existingSource !== generatedSource) {
    console.error(`Generated Playmesh extension is stale: ${outputPath}`);
    process.exitCode = 1;
  } else if (hasExistingSource) {
    console.log(`Verified ${outputPath}`);
  }
} else {
  writeFileSync(builtInCapabilitySnapshotPath, extractedBuiltInCapabilitySnapshotSource, 'utf8');
  writeFileSync(outputPath, generatedSource, 'utf8');
  console.log(`Generated ${outputPath}`);
}
