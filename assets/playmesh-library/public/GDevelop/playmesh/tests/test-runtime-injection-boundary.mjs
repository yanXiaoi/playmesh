import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const runtimePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshRuntime/PlaymeshMultiplayerRuntimeInjection.js'
);
const sourceExportSectionPath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/MainFrame/EditorContainers/PlaymeshHomePage/PlaymeshCreateSection.js'
);
const runtimeSource = await readFile(runtimePath, 'utf8');
const runtime = await import(
  `data:text/javascript;base64,${Buffer.from(runtimeSource).toString('base64')}`
);

const officialGdjsTag = '<script src="gdjs-evtsext__events.js"></script>';
const runtimeGameBootstrap =
  '<script>var game = new gdjs.RuntimeGame(gdjs.projectData, {});</script>';
const cleanHtml = `<!doctype html><html><head>${officialGdjsTag}</head><body>Game${runtimeGameBootstrap}</body></html>`;
const scriptTags = runtime.getPlaymeshMultiplayerRuntimeScriptTags();
const sdkTag = runtime.getPlaymeshSdkPlaceholderTag();
const assertRuntimeOrder = html => {
  scriptTags.forEach(tag => assert.equal(html.split(tag).length - 1, 1));
  assert.ok(html.indexOf(officialGdjsTag) < html.indexOf(scriptTags[0]));
  for (let index = 1; index < scriptTags.length; index++) {
    assert.ok(html.indexOf(scriptTags[index - 1]) < html.indexOf(scriptTags[index]));
  }
  assert.ok(html.indexOf(scriptTags.at(-1)) < html.indexOf('</head>'));
  assert.ok(html.indexOf(scriptTags.at(-1)) < html.indexOf(runtimeGameBootstrap));
};

assert.equal(runtime.shouldInjectPlaymeshMultiplayerRuntime('enabled'), true);
assert.equal(runtime.shouldInjectPlaymeshMultiplayerRuntime('unknown'), true);
assert.equal(runtime.shouldInjectPlaymeshMultiplayerRuntime('disabled'), true);
assert.throws(
  () => runtime.shouldInjectPlaymeshMultiplayerRuntime('maybe'),
  /未知的 GDevelop 多人启用状态/
);

assert.equal(/playmesh/i.test(cleanHtml), false, '普通官方导出必须保持零引用');
const sdkHtml = runtime.ensureSdkPlaceholder({ html: cleanHtml });
assert.equal(sdkHtml.split(sdkTag).length - 1, 1);
scriptTags
  .filter(tag => tag !== sdkTag)
  .forEach(tag => assert.equal(sdkHtml.includes(tag), false));
assert.ok(sdkHtml.indexOf(officialGdjsTag) < sdkHtml.indexOf(sdkTag));
assert.ok(sdkHtml.indexOf(sdkTag) < sdkHtml.indexOf('</head>'));
assert.ok(sdkHtml.indexOf(sdkTag) < sdkHtml.indexOf(runtimeGameBootstrap));

const disabledHtml = runtime.injectMultiplayerCompatibility({
  html: sdkHtml,
  activation: 'disabled',
});
assertRuntimeOrder(disabledHtml);


for (const activation of ['enabled', 'unknown', 'disabled']) {
  const injected = runtime.injectMultiplayerCompatibility({
    html: runtime.ensureSdkPlaceholder({ html: cleanHtml }),
    activation,
  });
  assertRuntimeOrder(injected);
  assert.equal(
    runtime.injectMultiplayerCompatibility({
      html: runtime.ensureSdkPlaceholder({ html: injected }),
      activation,
    }),
    injected,
    `${activation} 重复注入必须幂等`
  );
}

assert.throws(
  () =>
    runtime.injectMultiplayerCompatibility({
      html: cleanHtml,
      activation: 'enabled',
    }),
  /必须先.*Main SDK/
);
assert.throws(
  () =>
    runtime.ensureSdkPlaceholder({
      html: `<head>${sdkTag}${sdkTag}</head><body></body>`,
    }),
  /不能重复加载/
);
assert.throws(
  () =>
    runtime.injectMultiplayerCompatibility({
      html: `<head>${sdkTag}${scriptTags[1]}</head><body></body>`,
      activation: 'enabled',
    }),
  /只包含部分/
);
assert.throws(
  () =>
    runtime.injectMultiplayerCompatibility({
      html: `<head>${scriptTags[3]}${scriptTags[2]}${scriptTags[1]}${scriptTags[0]}</head><body></body>`,
      activation: 'enabled',
    }),
  /必须按 main SDK、FPS probe、GDevelop bridge、canonical Bootstrap 顺序/
);
assert.throws(
  () =>
    runtime.ensureSdkPlaceholder({
      html: `<head></head><body>${sdkTag}</body>`,
    }),
  /首个 RuntimeGame 创建前/
);

const hostedHtml = runtime
  .injectMultiplayerCompatibility({
    html: runtime.ensureSdkPlaceholder({ html: cleanHtml }),
    activation: 'unknown',
  })
  .replace(
    sdkTag,
    '<script>window.__PLAYMESH_BROWSER__={mode:"multiplayer"};</script>' +
      '<script src="/playmesh/sdk/v1/playmesh-app.js"></script>' +
      sdkTag
  );
const hostedOrder = [
  'window.__PLAYMESH_BROWSER__',
  '/playmesh/sdk/v1/playmesh-app.js',
  '/playmesh/sdk/v1/playmesh-main.js',
  'static/js/service/playmesh-gdevelop-fps-probe.js',
  'static/js/service/playmesh-multiplayer-bridge.js',
  'static/js/service/index.js',
  'new gdjs.RuntimeGame',
].map(marker => hostedHtml.indexOf(marker));
hostedOrder.forEach(index => assert.ok(index >= 0));
for (let index = 1; index < hostedOrder.length; index++) {
  assert.ok(
    hostedOrder[index - 1] < hostedOrder[index],
    'LAN config、App SDK、Main SDK、bridge、canonical 必须在首场景前同步定序'
  );
}

const projectJson = JSON.stringify({
  name: 'Official project',
  extensionProperties: [{ extension: 'Multiplayer' }],
  layouts: [],
});
const makeProject = () => ({ marker: 'project-object' });
globalThis.global.gd = {
  UsedExtensionsFinder: {
    scanProject: () => ({
      getUsedExtensions: () => ({
        toNewVectorString: () => ({ toJSArray: () => ['Multiplayer'] }),
      }),
    }),
  },
};
assert.equal(
  runtime.detectGDevelopMultiplayerActivation(makeProject()),
  'enabled'
);
globalThis.global.gd.UsedExtensionsFinder.scanProject = () => ({
  getUsedExtensions: () => ({
    toNewVectorString: () => ({ toJSArray: () => ['BuiltinObject'] }),
  }),
});
assert.equal(
  runtime.detectGDevelopMultiplayerActivation(makeProject()),
  'disabled'
);
globalThis.global.gd.UsedExtensionsFinder.scanProject = () => {
  throw new Error('scan failed');
};
assert.equal(
  runtime.detectGDevelopMultiplayerActivation(makeProject()),
  'unknown',
  '检测异常必须保守返回 unknown'
);
assert.equal(
  projectJson,
  JSON.stringify({
    name: 'Official project',
    extensionProperties: [{ extension: 'Multiplayer' }],
    layouts: [],
  }),
  '检测和注入不得改写工程 JSON'
);
assert.equal(/playmesh/i.test(projectJson), false);

const localSdkAsset = await readFile(
  path.resolve(
    testDirectory,
    '../../../sdk/v1/playmesh-main.js'
  ),
  'utf8'
);
assert.match(localSdkAsset, /playmesh/);

const sourceExportSection = await readFile(sourceExportSectionPath, 'utf8');
assert.match(sourceExportSection, /DownloadFileSaveAsDialog/);
assert.doesNotMatch(sourceExportSection, /createPlaymeshPackageFileMap/);
assert.doesNotMatch(sourceExportSection, /injectMultiplayerCompatibility/);
assert.doesNotMatch(sourceExportSection, /gdevelop-fps-probe|GDevelopFpsProbe/);

const sourcePolicy = await readFile(
  path.resolve(testDirectory, '../scripts/apply-source-policy.mjs'),
  'utf8'
);
assert.equal(
  sourcePolicy.includes(
    ".addIncludeFile('Extensions/Multiplayer/playmeshMultiplayerBridge.js')"
  ),
  false
);
assert.equal(
  sourcePolicy.includes('const playmeshBridge = (gdjs as any)'),
  false
);
for (const officialPath of [
  'Extensions/Multiplayer/JsExtension.js',
  'Extensions/Multiplayer/messageManager.ts',
]) {
  assert.ok(sourcePolicy.includes(`relativePath: '${officialPath}'`));
}
assert.ok(sourcePolicy.includes('assertOfficialSourceFile'));

process.stdout.write('GDevelop Playmesh runtime injection boundary tests passed.\n');
