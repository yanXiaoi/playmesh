import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
const sourceArgumentIndex = process.argv.indexOf('--source');
assert.notEqual(
  sourceArgumentIndex,
  process.argv.length - 1,
  'Usage: test-yarn-external-editor-cold-start.mjs [--source <root>]'
);
const sourceRoot = path.resolve(
  sourceArgumentIndex === -1
    ? path.join(
        repositoryRoot,
        'work/gdevelop-webide-build-cache/profiles/default/build-source'
      )
    : process.argv[sourceArgumentIndex + 1] || ''
);
const dependencyCacheRoot = path.resolve(
  repositoryRoot,
  'work/gdevelop-webide-build-cache/cache/deps'
);
const dependencyCaches = existsSync(dependencyCacheRoot)
  ? await readdir(dependencyCacheRoot)
  : [];
const dependencyPackageCandidates = [
  path.resolve(sourceRoot, 'newIDE/app/package.json'),
  path.resolve(
    repositoryRoot,
    'work/gdevelop-webide-build-cache/profiles/default/build-source/newIDE/app/package.json'
  ),
  ...dependencyCaches.map(entry =>
    path.join(dependencyCacheRoot, entry, 'package.json')
  ),
];
const dependencyPackage = dependencyPackageCandidates.find(candidate => {
  const nodeModules = path.join(path.dirname(candidate), 'node_modules');
  return (
    existsSync(candidate) &&
    existsSync(path.join(nodeModules, 'jsdom/package.json')) &&
    existsSync(path.join(nodeModules, '@babel/parser/package.json'))
  );
});
assert.ok(
  dependencyPackage,
  'the fixed WebIDE dependency cache is required for the Yarn cold-start test'
);

const appRequire = createRequire(dependencyPackage);
const { JSDOM, ResourceLoader, VirtualConsole } = appRequire('jsdom');
const babelParser = appRequire('@babel/parser');
const yarnRoot = path.resolve(
  sourceRoot,
  'newIDE/app/public/external/yarn/yarn-editor'
);
const externalRoot = path.resolve(
  sourceRoot,
  'newIDE/app/public/external'
);
assert.ok(
  existsSync(path.join(yarnRoot, 'index.html')),
  'the clean-replayed Yarn editor is required for the cold-start test'
);

const yarnBundlePath = path.join(
  yarnRoot,
  'js/main.80b352588636fbc67c02.js'
);
babelParser.parse(await readFile(yarnBundlePath, 'utf8'), {
  sourceType: 'script',
});

class LocalYarnResourceLoader extends ResourceLoader {
  fetch(url) {
    const parsedUrl = new URL(url);
    const prefix = '/external/';
    if (!parsedUrl.pathname.startsWith(prefix)) return null;
    const relativePath = decodeURIComponent(parsedUrl.pathname.slice(prefix.length));
    const filePath = path.resolve(externalRoot, ...relativePath.split('/'));
    if (!filePath.startsWith(`${externalRoot}${path.sep}`)) return null;
    const request = readFile(filePath);
    request.abort = () => {};
    return request;
  }
}

const virtualConsole = new VirtualConsole();
const runtimeErrors = [];
virtualConsole.on('jsdomError', error => runtimeErrors.push(error));
virtualConsole.on('error', (...values) => {
  runtimeErrors.push(new Error(values.map(String).join(' ')));
});

let readyEvent = null;
const dom = await JSDOM.fromFile(path.join(yarnRoot, 'index.html'), {
  beforeParse(window) {
    window.addEventListener('yarnReady', event => {
      readyEvent = event;
    });
    window.HTMLCanvasElement.prototype.getContext = () => ({
      beginPath() {},
      clearRect() {},
      closePath() {},
      drawImage() {},
      fill() {},
      fillRect() {},
      lineTo() {},
      measureText: () => ({ width: 0 }),
      moveTo() {},
      restore() {},
      save() {},
      scale() {},
      setTransform() {},
      stroke() {},
      translate() {},
    });
    window.matchMedia = () => ({
      matches: false,
      addListener() {},
      removeListener() {},
    });
    window.WebKitCSSMatrix = class WebKitCSSMatrix {
      constructor() {
        this.m41 = 0;
        this.m42 = 0;
      }
    };
  },
  pretendToBeVisual: true,
  resources: new LocalYarnResourceLoader(),
  runScripts: 'dangerously',
  url: 'http://127.0.0.1/external/yarn/yarn-editor/index.html?locale=zh-CN',
  virtualConsole,
});

try {
  const deadline = Date.now() + 10000;
  while (!readyEvent && runtimeErrors.length === 0 && Date.now() < deadline) {
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal(
    runtimeErrors.length,
    0,
    runtimeErrors[0] ? `Yarn cold start failed: ${runtimeErrors[0].stack}` : ''
  );
  assert.ok(readyEvent, 'Yarn must dispatch yarnReady during a cold start');
  assert.ok(readyEvent.app, 'yarnReady must expose the official Yarn app');
  assert.ok(readyEvent.data, 'yarnReady must expose the official Yarn data API');
  assert.equal(dom.window.PlaymeshYarnI18n.locale, 'zh-CN');
} finally {
  dom.window.close();
}

console.log('GDevelop Yarn external-editor cold-start contract passed.');
