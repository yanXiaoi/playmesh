import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const probePath = path.resolve(
  testDirectory,
  '../../../developer/gdevelop-fps-probe.js'
);
const probeSource = await readFile(probePath, 'utf8');
const probeKey = Symbol.for('playmesh.gdevelop.fps-probe.v1');

assert.match(probeSource, /playmesh\.gdevelop\.fps-probe\.v1/);
assert.match(
  probeSource,
  /global\.playmesh\?\.app\?\.performance[\s\S]*performanceApi\.reportFrame\(\)/
);
assert.doesNotMatch(
  probeSource,
  /requestAnimationFrame|document\.|fetch\(|XMLHttpRequest|WebSocket|postMessage|PlaymeshBridge|chrome\.webview/
);

const renderState = {
  calls: 0,
  receiver: null,
  args: null,
  shouldThrow: false,
};
const renderResult = { rendered: true };
function RuntimeScene(name) {
  this.name = name;
}
const originalRender = function originalRenderForProbe(...args) {
  renderState.calls += 1;
  renderState.receiver = this;
  renderState.args = args;
  if (renderState.shouldThrow) throw new Error('render failed');
  return renderResult;
};
RuntimeScene.prototype.render = originalRender;

let reportCalls = 0;
let reportShouldThrow = false;
const warnings = [];
const eventListeners = new Map();
const context = vm.createContext({
  console: {
    warn(...args) {
      warnings.push(args);
    },
  },
  addEventListener(type, listener) {
    if (!eventListeners.has(type)) eventListeners.set(type, []);
    eventListeners.get(type).push(listener);
  },
  gdjs: { RuntimeScene },
  playmesh: {
    app: {
      performance: {
        reportFrame() {
          if (reportShouldThrow) throw new Error('report failed');
          reportCalls += 1;
        },
      },
    },
  },
});

vm.runInContext(probeSource, context, { filename: 'gdevelop-fps-probe.js' });
const probe = context[probeKey];
assert.equal(probe.version, '1.0.0');
assert.equal(Object.keys(context).includes(String(probeKey)), false);
assert.equal(eventListeners.get('pagehide').length, 1);
const firstWrapper = RuntimeScene.prototype.render;
assert.notEqual(firstWrapper, originalRender);

const scene = new RuntimeScene('Game');
assert.strictEqual(scene.render('first', 2), renderResult);
assert.strictEqual(renderState.receiver, scene);
assert.deepEqual(renderState.args, ['first', 2]);
assert.equal(renderState.calls, 1);
assert.equal(reportCalls, 1);

vm.runInContext(probeSource, context, {
  filename: 'gdevelop-fps-probe-duplicate.js',
});
assert.strictEqual(RuntimeScene.prototype.render, firstWrapper);
assert.equal(eventListeners.get('pagehide').length, 1);
scene.render('second');
assert.equal(reportCalls, 2, '重复 include 不能造成双计数');

renderState.shouldThrow = true;
assert.throws(() => scene.render('failure'), /render failed/);
assert.equal(reportCalls, 2, '原 render 失败后不能上报不存在的帧');
renderState.shouldThrow = false;

reportShouldThrow = true;
assert.strictEqual(scene.render('report-failure-1'), renderResult);
assert.strictEqual(scene.render('report-failure-2'), renderResult);
assert.equal(warnings.length, 1, 'SDK 上报异常最多提示一次');
reportShouldThrow = false;
assert.strictEqual(scene.render('report-recovered'), renderResult);
assert.equal(reportCalls, 3, 'SDK 恢复后探针应继续上报');

const savedPlaymesh = context.playmesh;
context.playmesh = null;
assert.strictEqual(scene.render('sdk-missing'), renderResult);
assert.equal(reportCalls, 3, 'SDK 缺失必须静默 no-op');
context.playmesh = savedPlaymesh;

assert.equal(probe.dispose(), true);
assert.strictEqual(RuntimeScene.prototype.render, originalRender);
scene.render('disposed');
assert.equal(reportCalls, 3);
assert.equal(probe.install(), true);
assert.notEqual(RuntimeScene.prototype.render, originalRender);

const pagehideListeners = eventListeners.get('pagehide');
pagehideListeners[0]();
assert.strictEqual(RuntimeScene.prototype.render, originalRender);
assert.equal(probe.install(), true);
const installedWrapper = RuntimeScene.prototype.render;
RuntimeScene.prototype.render = function laterWrapper(...args) {
  return Reflect.apply(installedWrapper, this, args);
};
assert.equal(
  probe.dispose(),
  false,
  '若其他包装器已接管 prototype，dispose 不得破坏其调用链'
);
assert.strictEqual(scene.render('later-wrapper'), renderResult);
assert.equal(reportCalls, 4);

const missingRuntimeContext = vm.createContext({
  console: { warn() {} },
  addEventListener() {},
});
assert.doesNotThrow(() =>
  vm.runInContext(probeSource, missingRuntimeContext, {
    filename: 'gdevelop-fps-probe-no-runtime.js',
  })
);
assert.equal(missingRuntimeContext[probeKey].install(), false);

const incompatibleProbe = Object.freeze({ version: '2.0.0' });
const incompatibleContext = vm.createContext({
  [probeKey]: incompatibleProbe,
});
assert.doesNotThrow(() =>
  vm.runInContext(probeSource, incompatibleContext, {
    filename: 'gdevelop-fps-probe-incompatible.js',
  })
);
assert.strictEqual(incompatibleContext[probeKey], incompatibleProbe);

process.stdout.write('GDevelop FPS probe contracts passed.\n');
