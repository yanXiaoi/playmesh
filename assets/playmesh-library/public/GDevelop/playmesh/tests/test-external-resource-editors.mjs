import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import vm from 'node:vm';

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}
const sourceRoot = args.get('--source');
assert.ok(sourceRoot, 'Usage: test-external-resource-editors.mjs --source <root>');

const readSource = relativePath =>
  readFile(path.resolve(sourceRoot, ...relativePath.split('/')), 'utf8');

const [
  browserApp,
  externalEditors,
  browserResourceFetcher,
  localResourceFetcher,
  serializer,
  embeddedExternalEditorWindow,
  externalEditorOpenedDialog,
  parentEditorInterface,
  piskelIndex,
  piskelMain,
  piskelBundle,
  piskelGifWorker,
  jfxrIndex,
  jfxrMain,
  jfxrBundle,
  yarnIndex,
  yarnMain,
  yarnBundle,
  sharedExternalEditorI18n,
  jfxrEnglishCatalog,
  jfxrChineseCatalog,
  jfxrI18nInstaller,
  yarnEnglishCatalog,
  yarnChineseCatalog,
  yarnI18nInstaller,
] = await Promise.all([
  readSource('newIDE/app/src/BrowserApp.js'),
  readSource('newIDE/app/src/ResourcesList/BrowserResourceExternalEditors.js'),
  readSource(
    'newIDE/app/src/ProjectsStorage/ResourceFetcher/BrowserResourceFetcher.js'
  ),
  readSource(
    'newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshLocalResourceFetcher.js'
  ),
  readSource(
    'newIDE/app/src/ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectSerializer.js'
  ),
  readSource(
    'newIDE/app/src/ResourcesList/PlaymeshEmbeddedExternalEditorWindow.js'
  ),
  readSource('newIDE/app/src/UI/ExternalEditorOpenedDialog.js'),
  readSource('newIDE/app/public/external/utils/parent-editor-interface.js'),
  readSource('newIDE/app/public/external/piskel/piskel-editor/index.html'),
  readSource('newIDE/app/public/external/piskel/piskel-main.js'),
  readSource(
    'newIDE/app/public/external/piskel/piskel-editor/js/piskel-packaged-2025-04-07-05-19.js'
  ),
  readSource(
    'newIDE/app/public/external/piskel/piskel-editor/js/lib/gif/gif.ie.worker.js'
  ),
  readSource('newIDE/app/public/external/jfxr/jfxr-editor/index.html'),
  readSource('newIDE/app/public/external/jfxr/jfxr-main.js'),
  readSource(
    'newIDE/app/public/external/jfxr/jfxr-editor/419d227b2992f0e1b41a.js'
  ),
  readSource('newIDE/app/public/external/yarn/yarn-editor/index.html'),
  readSource('newIDE/app/public/external/yarn/yarn-main.js'),
  readSource(
    'newIDE/app/public/external/yarn/yarn-editor/js/main.80b352588636fbc67c02.js'
  ),
  readSource(
    'newIDE/app/public/external/playmesh-i18n/playmesh-external-editor-i18n.js'
  ),
  readSource(
    'newIDE/app/public/external/jfxr/jfxr-editor/playmesh-i18n/locales/en.js'
  ),
  readSource(
    'newIDE/app/public/external/jfxr/jfxr-editor/playmesh-i18n/locales/zh-CN.js'
  ),
  readSource(
    'newIDE/app/public/external/jfxr/jfxr-editor/playmesh-i18n/install.js'
  ),
  readSource(
    'newIDE/app/public/external/yarn/yarn-editor/playmesh-i18n/locales/en.js'
  ),
  readSource(
    'newIDE/app/public/external/yarn/yarn-editor/playmesh-i18n/locales/zh-CN.js'
  ),
  readSource(
    'newIDE/app/public/external/yarn/yarn-editor/playmesh-i18n/install.js'
  ),
]);

assert.doesNotThrow(
  () =>
    new vm.Script(yarnBundle, {
      filename: 'external/yarn/yarn-editor/js/main.80b352588636fbc67c02.js',
    }),
  'the source-policy output must remain valid JavaScript for Node/V8'
);

assert.match(
  browserApp,
  /import browserResourceExternalEditors from '\.\/ResourcesList\/BrowserResourceExternalEditors';/
);
assert.match(
  browserApp,
  /resourceExternalEditors=\{browserResourceExternalEditors\}/
);

const officialEditorNames = ['piskel-app', 'jfxr-app', 'yarn-app'];
let previousIndex = -1;
for (const name of officialEditorNames) {
  const index = externalEditors.indexOf(`name: '${name}'`);
  assert.ok(index > previousIndex, `${name} must retain its official order`);
  previousIndex = index;
}
assert.equal(
  [...externalEditors.matchAll(/name: '(?:piskel|jfxr|yarn)-app'/g)].length,
  3,
  'the official browser external-editor registry must contain exactly three tools'
);
assert.match(externalEditors, /window\.open\(\s*'about:blank'/);
assert.match(
  externalEditors,
  /openPlaymeshEmbeddedExternalEditorWindow\(\{ targetId \}\) \|\|\s*window\.open/
);
assert.equal(
  [...externalEditors.matchAll(/closeExternalEditorWindow\(externalEditorWindow\);/g)]
    .length,
  4,
  'editor close, abort, readiness timeout and the embedded host close control must all close the surface'
);
assert.match(
  externalEditors,
  /isPlaymeshEmbeddedExternalEditorWindow\(\s*externalEditorWindow\s*\)\s*\? externalEditorReady\s*: externalEditorLoaded/
);
assert.match(externalEditors, /readinessTimeoutId = setTimeout/);
assert.match(externalEditors, /clearTimeout\(readinessTimeoutId\)/);
assert.match(
  externalEditors,
  /cleanupExternalEditorListeners\(\);\s*closePlaymeshEmbeddedExternalEditorWindow\(externalEditorWindow\);\s*resolve\(externalEditorOutput\);/,
  'a native iframe unload must remove the embedded surface before resolving'
);
assert.match(
  externalEditors,
  /markPlaymeshEmbeddedExternalEditorReady\(externalEditorWindow\)/
);
assert.match(
  externalEditors,
  /setPlaymeshEmbeddedExternalEditorCloseRequestHandler\(\s*externalEditorWindow,\s*onEmbeddedCloseRequest/
);
assert.match(
  externalEditors,
  /closePlaymeshEmbeddedExternalEditorWindow\(externalEditorWindow\);\s*throw error;/,
  'resource preparation failures must remove only an embedded surface'
);
assert.match(
  externalEditors,
  /try \{\s*displayBlackLoadingScreenOrThrow\(externalEditorWindow\);\s*\} catch \(error\) \{\s*closePlaymeshEmbeddedExternalEditorWindow\(externalEditorWindow\);\s*throw error;/,
  'synchronous loading-screen failures must remove only an embedded surface'
);
assert.match(externalEditors, /const width = 800;/);
assert.match(externalEditors, /const height = 600;/);
assert.match(externalEditors, /getPlaymeshPromptLocale/);
assert.match(
  externalEditors,
  /externalEditorUrl\.searchParams\.set\('locale', getPlaymeshPromptLocale\(\)\)/
);
assert.doesNotMatch(externalEditors, /Unsupported blob URL for a resource/);
assert.equal(
  [...externalEditors.matchAll(/PlaymeshLocalStorageProvider\.internalName/g)]
    .length,
  3,
  'all three official editors must use the Playmesh local storage seam'
);
const officialEditLifecycle = externalEditors.slice(
  externalEditors.indexOf('const editWithBrowserExternalEditor'),
  externalEditors.indexOf('const editors:')
);
assert.ok(
  officialEditLifecycle.indexOf(
    'saveBlobUrlsFromExternalEditorBase64Resources'
  ) < officialEditLifecycle.indexOf('onFetchNewlyAddedResources') &&
    officialEditLifecycle.indexOf('onFetchNewlyAddedResources') <
      officialEditLifecycle.indexOf('freeBlobsAndUpdateMetadata'),
  'official save, materialize and temporary-blob cleanup ordering must remain intact'
);

assert.match(
  browserResourceFetcher,
  /\[PlaymeshLocalStorageProvider\.internalName\]: fetchPlaymeshLocalResources/
);
assert.match(localResourceFetcher, /downloadUrlsToBlobs/);
assert.match(localResourceFetcher, /adoptPlaymeshLocalResourceBlob/);
assert.match(
  localResourceFetcher,
  /playmeshResourceObjectUrlRegistry\.owns\(url\)/
);
assert.doesNotMatch(
  localResourceFetcher,
  /getPlaymeshLogicalResourceUrl\(url\)/
);
assert.doesNotMatch(localResourceFetcher, /sha256|contentHash/);
assert.match(serializer, /playmeshResourceObjectUrlRegistry\.acquire/);
assert.match(serializer, /resource\.setFile\(objectUrl\)/);

assert.match(
  embeddedExternalEditorWindow,
  /__playmeshExternalNavigationInstalled === true/
);
assert.match(
  embeddedExternalEditorWindow,
  /activeElement\.closest\('\[role="dialog"\]'\)/
);
assert.match(
  embeddedExternalEditorWindow,
  /embeddedExternalEditorSurfaces\.set\(externalEditorWindow/
);
assert.match(
  embeddedExternalEditorWindow,
  /surface\.overlay\.remove\(\)/
);
assert.match(
  embeddedExternalEditorWindow,
  /data-playmesh-embedded-editor-close/
);
assert.match(
  embeddedExternalEditorWindow,
  /import \{ getPlaymeshMessage \} from '\.\.\/PlaymeshLocalization\/PlaymeshLocalizationSession';/
);
assert.match(
  embeddedExternalEditorWindow,
  /import \{ playmeshMessages \} from '\.\.\/PlaymeshLocalization\/PlaymeshMessageKeys';/
);
assert.match(
  embeddedExternalEditorWindow,
  /data-playmesh-embedded-editor-control-rail/
);
assert.match(
  embeddedExternalEditorWindow,
  /gridTemplateColumns: '44px'/,
  'the remaining host escape must retain a mobile-safe 44px touch target'
);
assert.doesNotMatch(
  embeddedExternalEditorWindow,
  /data-playmesh-embedded-editor-fullscreen/,
  'full-size embedded editors must not duplicate a fullscreen control'
);
assert.doesNotMatch(
  embeddedExternalEditorWindow,
  /requestFullscreen/,
  'the iframe host must not invoke the browser fullscreen API'
);
assert.doesNotMatch(
  embeddedExternalEditorWindow,
  /exitFullscreen/,
  'the iframe host must not own browser fullscreen state'
);
assert.match(
  embeddedExternalEditorWindow,
  /getPlaymeshMessage\(messageKey\)/
);
assert.match(
  embeddedExternalEditorWindow,
  /playmeshMessages\.externalEditorCancel/
);
assert.match(
  embeddedExternalEditorWindow,
  /playmeshMessages\.externalEditorClosePreview/
);
assert.match(
  embeddedExternalEditorWindow,
  /localizedLabel !== messageKey/
);
assert.match(
  embeddedExternalEditorWindow,
  /position: 'fixed',\s*inset: '0',\s*backgroundColor: '#000000'/,
  'the external editor surface must fill the available host area immediately'
);
assert.match(embeddedExternalEditorWindow, /width: '100%',\s*height: '100%'/);
assert.match(embeddedExternalEditorWindow, /touchAction: 'manipulation'/);
assert.doesNotMatch(
  embeddedExternalEditorWindow,
  /surface\.closeButton\.style\.visibility = 'hidden'/,
  'the host Cancel control must remain available after editor readiness'
);
assert.doesNotMatch(
  embeddedExternalEditorWindow,
  /surface\.closeButton\.setAttribute\('aria-hidden', 'true'\)/,
  'the host Cancel control must remain reachable after editor readiness'
);
assert.doesNotMatch(
  embeddedExternalEditorWindow,
  /__playmeshDeveloperFullscreen/,
  'tool surfaces must not toggle the whole IDE native fullscreen bridge'
);
assert.match(
  embeddedExternalEditorWindow,
  /__playmeshEmbeddedExternalEditorWindowApi/
);
assert.match(embeddedExternalEditorWindow, /isAboutBlankUrl\(url\)/);
assert.match(
  embeddedExternalEditorWindow,
  /installWindowMethod\(popupWindow, 'close', closePopup\)/
);
assert.match(embeddedExternalEditorWindow, /dispatchResize/);
assert.match(
  embeddedExternalEditorWindow,
  /dispatchWindowEvent\(popupWindow, 'unload'\)/
);
assert.doesNotMatch(embeddedExternalEditorWindow, /setAttribute\('sandbox'/);
assert.match(
  externalEditorOpenedDialog,
  /shouldUsePlaymeshEmbeddedExternalEditorWindow\(\)/
);
assert.match(
  parentEditorInterface,
  /window\.opener \|\| \(window\.parent && window\.parent !== window\)/
);
assert.match(
  parentEditorInterface,
  /const parentEditorWindow = window\.opener \|\| window\.parent;/
);

const assertOfflineCsp = (html, label) => {
  assert.match(
    html,
    /Content-Security-Policy[^>]+connect-src 'self' data: blob:/,
    `${label} must block cross-origin background services`
  );
  assert.match(
    html,
    /script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:/,
    `${label} must allow the locked local editor runtime to evaluate its bundled templates`
  );
};
assertOfflineCsp(piskelIndex, 'Piskel');
assertOfflineCsp(jfxrIndex, 'Jfxr');
assertOfflineCsp(yarnIndex, 'Yarn');

for (const [indexHtml, editor] of [
  [jfxrIndex, 'jfxr'],
  [yarnIndex, 'yarn'],
]) {
  assert.match(
    indexHtml,
    /\.\.\/\.\.\/playmesh-i18n\/playmesh-external-editor-i18n\.js/
  );
  assert.match(indexHtml, /playmesh-i18n\/locales\/en\.js/);
  assert.match(indexHtml, /playmesh-i18n\/locales\/zh-CN\.js/);
  assert.match(indexHtml, /playmesh-i18n\/install\.js/);
  assert.match(
    editor === 'jfxr' ? jfxrI18nInstaller : yarnI18nInstaller,
    new RegExp(`editor: '${editor}'`)
  );
}
assert.match(sharedExternalEditorI18n, /createTranslator/);
assert.match(sharedExternalEditorI18n, /readExplicitLocale/);
assert.match(jfxrEnglishCatalog, /editor: 'jfxr'[\s\S]*locale: 'en'/);
assert.match(jfxrChineseCatalog, /editor: 'jfxr'[\s\S]*locale: 'zh-CN'/);
assert.match(yarnEnglishCatalog, /editor: 'yarn'[\s\S]*locale: 'en'/);
assert.match(yarnChineseCatalog, /editor: 'yarn'[\s\S]*locale: 'zh-CN'/);

// Piskel keeps local import/export/editor capabilities, while the embedded
// gallery and public GIF-upload actions are not exposed.
assert.match(piskelIndex, /gif-download-button/);
assert.match(piskelIndex, /file-upload-input/);
assert.match(
  piskelIndex,
  /localWorkerOptions\.workerScript = 'js\/lib\/gif\/gif\.ie\.worker\.js'/,
  'Piskel GIF export must use its locked same-origin worker in embedded WebViews'
);
assert.match(
  piskelIndex,
  /if \(typeof playmeshNativeBlobSaver === 'function'\) \{[\s\S]*localWorkerOptions\.workerScript/,
  'the static GIF worker override must be scoped to the native Playmesh host'
);
assert.match(piskelMain, /gifUploadRow\.style\.display = 'none'/);
assert.match(piskelMain, /gifUploadPanel\.style\.display = 'none'/);
assert.match(piskelMain, /galleryItem\.style\.display = 'none'/);
assert.match(
  piskelMain,
  /hostWindow && hostWindow\.__playmeshSaveBlobDownload/,
  'Piskel downloads must reuse the native Blob save hook already installed on the workspace'
);
assert.match(
  piskelMain,
  /fileUtils\.downloadAsFile = \(content, filename\) => \{[\s\S]*nativeBlobSaver\(\{ url, filename \}\)/,
  'all Piskel file exports must cross the native WebView save seam'
);
assert.match(
  piskelMain,
  /parentEditorWindow\.__playmeshEmbeddedExternalEditorWindowApi/
);
assert.match(
  piskelMain,
  /String\(url === undefined \|\| url === null \? '' : url\)[\s\S]*=== 'about:blank'/
);
assert.match(
  piskelMain,
  /embeddedPopupApi\.openPopup\(\{\s*ownerWindow: piskelWindow,/
);
assert.match(piskelMain, /return nativeOpen\(url, target, features\)/);
assert.ok(
  piskelMain.indexOf(
    'installPlaymeshPiskelDownloadAdapter(editorFrameEl.contentWindow);'
  ) < piskelMain.indexOf("sendMessageToParentEditor('external-editor-ready');"),
  'Piskel must install its native download adapter before announcing readiness'
);
assert.ok(
  piskelMain.indexOf(
    'installPlaymeshEmbeddedPopupAdapter(editorFrameEl.contentWindow);'
  ) < piskelMain.indexOf("sendMessageToParentEditor('external-editor-ready');"),
  'Piskel must install its local popup adapter before announcing readiness'
);
assert.equal(
  [...piskelBundle.matchAll(/window\.open\('about:blank'/g)].length,
  2,
  'the locked Piskel bundle has exactly the two local popup calls covered by the adapter'
);
assert.equal(
  [...piskelBundle.matchAll(/pskl\.utils\.FileUtils\.downloadAsFile\(/g)]
    .length,
  7,
  'the single FileUtils adapter must cover every locked Piskel GIF, PNG, ZIP, C, palette and project download call'
);

const piskelGifAdapterStart = piskelIndex.indexOf(
  'var playmeshNativeBlobSaver = null;'
);
const piskelGifAdapterEnd = piskelIndex.indexOf(
  '    pskl.app.init();',
  piskelGifAdapterStart
);
assert.ok(
  piskelGifAdapterStart >= 0 && piskelGifAdapterEnd > piskelGifAdapterStart,
  'the native GIF worker adapter must be independently executable'
);
const piskelGifAdapterSource = piskelIndex.slice(
  piskelGifAdapterStart,
  piskelGifAdapterEnd
);
const BrowserGifEncoder = function(options) {
  this.options = options;
};
const browserGifWindow = { top: {}, GIF: BrowserGifEncoder };
vm.runInNewContext(piskelGifAdapterSource, { window: browserGifWindow });
assert.equal(
  browserGifWindow.GIF,
  BrowserGifEncoder,
  'ordinary browsers must retain Piskel\'s official blob-worker constructor'
);
const NativeGifEncoder = function(options) {
  this.options = options;
};
const nativeGifWindow = {
  top: { __playmeshSaveBlobDownload() {} },
  GIF: NativeGifEncoder,
};
vm.runInNewContext(piskelGifAdapterSource, { window: nativeGifWindow });
const nativeGif = new nativeGifWindow.GIF({ workers: 5, quality: 1 });
assert.equal(nativeGif.options.workers, 5);
assert.equal(nativeGif.options.quality, 1);
assert.equal(
  nativeGif.options.workerScript,
  'js/lib/gif/gif.ie.worker.js',
  'the native host must only replace the worker transport, not Piskel encoder options'
);

const piskelDownloadAdapterStart = piskelMain.indexOf(
  'const getPlaymeshNativeBlobSaver ='
);
const piskelDownloadAdapterEnd = piskelMain.indexOf(
  'const installPlaymeshEmbeddedPopupAdapter ='
);
assert.ok(
  piskelDownloadAdapterStart >= 0 &&
    piskelDownloadAdapterEnd > piskelDownloadAdapterStart,
  'the Piskel download adapter must be independently executable'
);
const piskelDownloadAdapterSource = piskelMain.slice(
  piskelDownloadAdapterStart,
  piskelDownloadAdapterEnd
);
const nativeDownloads = [];
const revokedUrls = [];
let completeNativeSave;
const nativeSaveCompletion = new Promise(resolve => {
  completeNativeSave = resolve;
});
const hostWindow = {
  __playmeshSaveBlobDownload: download => {
    nativeDownloads.push(download);
    return nativeSaveCompletion;
  },
};
const wrapperWindow = { top: hostWindow };
const originalDownloadCalls = [];
const fileUtils = {
  downloadAsFile: (...args) => originalDownloadCalls.push(args),
};
const piskelWindow = {
  pskl: { utils: { FileUtils: fileUtils } },
  URL: {
    createObjectURL: () => 'blob:http://127.0.0.1/piskel-export',
    revokeObjectURL: url => revokedUrls.push(url),
  },
};
const installPiskelDownloadAdapter = vm.runInNewContext(
  `(() => {
    const window = playmeshWindow;
    ${piskelDownloadAdapterSource}
    return installPlaymeshPiskelDownloadAdapter;
  })()`,
  { playmeshWindow: wrapperWindow }
);
installPiskelDownloadAdapter(piskelWindow);
installPiskelDownloadAdapter(piskelWindow);
const exportedBlob = { type: 'image/png', size: 4 };
fileUtils.downloadAsFile(exportedBlob, 'sprite.png');
assert.equal(nativeDownloads.length, 1);
assert.equal(
  nativeDownloads[0].url,
  'blob:http://127.0.0.1/piskel-export'
);
assert.equal(nativeDownloads[0].filename, 'sprite.png');
assert.equal(originalDownloadCalls.length, 0);
assert.deepEqual(
  revokedUrls,
  [],
  'the Blob URL must stay valid until the native host finishes reading it'
);
completeNativeSave();
await nativeSaveCompletion;
await new Promise(resolve => setTimeout(resolve, 0));
assert.deepEqual(revokedUrls, ['blob:http://127.0.0.1/piskel-export']);

const legacyRevocations = [];
const legacyTimers = [];
const legacyFileUtils = { downloadAsFile: () => {} };
const installLegacyPiskelDownloadAdapter = vm.runInNewContext(
  `(() => {
    const window = playmeshWindow;
    ${piskelDownloadAdapterSource}
    return installPlaymeshPiskelDownloadAdapter;
  })()`,
  {
    playmeshWindow: {
      top: { __playmeshSaveBlobDownload() {} },
    },
  }
);
installLegacyPiskelDownloadAdapter({
  pskl: { utils: { FileUtils: legacyFileUtils } },
  URL: {
    createObjectURL: () => 'blob:legacy-piskel-export',
    revokeObjectURL: url => legacyRevocations.push(url),
  },
  setTimeout: (callback, delay) => legacyTimers.push({ callback, delay }),
});
legacyFileUtils.downloadAsFile(exportedBlob, 'legacy-sprite.png');
assert.deepEqual(legacyRevocations, []);
assert.equal(legacyTimers.length, 1);
assert.equal(legacyTimers[0].delay, 60000);
legacyTimers[0].callback();
assert.deepEqual(legacyRevocations, ['blob:legacy-piskel-export']);

const browserFileUtils = { downloadAsFile: () => {} };
const browserPiskelWindow = {
  pskl: { utils: { FileUtils: browserFileUtils } },
  URL: { createObjectURL: () => 'blob:browser' },
};
const installBrowserPiskelDownloadAdapter = vm.runInNewContext(
  `(() => {
    const window = playmeshWindow;
    ${piskelDownloadAdapterSource}
    return installPlaymeshPiskelDownloadAdapter;
  })()`,
  { playmeshWindow: { top: {} } }
);
const officialBrowserDownload = browserFileUtils.downloadAsFile;
installBrowserPiskelDownloadAdapter(browserPiskelWindow);
assert.equal(
  browserFileUtils.downloadAsFile,
  officialBrowserDownload,
  'ordinary browsers must retain Piskel\'s official anchor download path'
);

const workerReplies = [];
const workerGlobal = {
  postMessage: message => workerReplies.push(message),
};
workerGlobal.self = workerGlobal;
vm.runInNewContext(piskelGifWorker, workerGlobal);
workerGlobal.onmessage({
  data: {
    index: 0,
    last: true,
    width: 1,
    height: 1,
    delay: 100,
    transparent: null,
    repeat: 0,
    quality: 1,
    preserveColors: true,
    canTransfer: false,
    data: new Uint8Array([255, 0, 0, 255]),
  },
});
assert.equal(workerReplies.length, 1);
const workerReply = workerReplies[0];
const gifBytes = [];
workerReply.data.forEach((page, pageIndex) => {
  const length =
    pageIndex === workerReply.data.length - 1
      ? workerReply.cursor
      : workerReply.pageSize;
  for (let index = 0; index < length; index++) gifBytes.push(page[index]);
});
assert.equal(
  String.fromCharCode(...gifBytes.slice(0, 6)),
  'GIF89a',
  'the locked local Piskel worker must produce an animated GIF payload'
);
assert.equal(gifBytes.at(-1), 0x3b, 'the generated GIF must contain its trailer');

// Jfxr keeps its local synthesis/WAV bridge and has no active analytics/font
// bootstrap in the final source.
assert.match(jfxrMain, /jfxr\.synth\.run\(\)/);
assert.match(jfxrMain, /audio\/wav/);
assert.doesNotMatch(jfxrIndex, /fonts\.googleapis\.com/);
assert.doesNotMatch(jfxrIndex, /GoogleAnalyticsObject|ga\('send','pageview'/);
assert.doesNotMatch(jfxrMain, /contentWindow\.ga\(/);
assert.doesNotMatch(jfxrIndex + jfxrMain + jfxrBundle, /window\.open\(/);
assert.ok(
  jfxrMain.indexOf('const externalEditorHeader = createExternalEditorHeader') <
    jfxrMain.lastIndexOf(
      'loadExistingSound(externalEditorInput.externalEditorData)'
    ),
  'Jfxr must create its official cancel control before parsing project metadata'
);
assert.match(jfxrMain, /jfxrEditorUrl\.searchParams\.set\('locale'/);
assert.match(jfxrMain, /playmeshJfxrI18n\.translateWrapperDocument\(document\)/);
assert.match(jfxrI18nInstaller, /explicitLocale: api\.readExplicitLocale\(root\.location\)/);
assert.match(jfxrI18nInstaller, /'\.soundname'/);
assert.match(jfxrI18nInstaller, /'\.history'/);

// Yarn keeps its local JSON conversion but removes the three network-backed
// surfaces present in the upstream editor.
assert.match(yarnIndex, /pwaTryShare/);
assert.doesNotMatch(yarnIndex, /platform\.twitter\.com\/widgets\.js/);
assert.doesNotMatch(yarnIndex, /id="gistTryOpen"|Gist token/);
assert.doesNotMatch(yarnBundle, /api\.forismatic\.com/);
assert.doesNotMatch(
  yarnBundle,
  /raw\.githubusercontent\.com\/wooorm\/dictionaries/
);
assert.doesNotMatch(yarnBundle, /twttr\.widgets\.createTweet/);
assert.doesNotMatch(yarnIndex + yarnBundle, /window\.open\(/);
assert.match(yarnMain, /yarnEditorUrl\.searchParams\.set\('locale'/);
assert.match(yarnMain, /playmeshYarnI18n\.translateWrapperDocument\(document\)/);
assert.match(yarnI18nInstaller, /explicitLocale: api\.readExplicitLocale\(root\.location\)/);
assert.match(yarnI18nInstaller, /'#language'/);
assert.match(yarnI18nInstaller, /'\.nodes'/);
assert.match(yarnI18nInstaller, /'#editorTitle'/);
assert.match(yarnI18nInstaller, /'#editorTags'/);
assert.doesNotMatch(yarnI18nInstaller, /language\.value\s*=/);
assert.doesNotMatch(yarnI18nInstaller, /app\.settings\.(?:language|playtestStyle)\s*=/);
assert.match(yarnI18nInstaller, /languageId\.split\('-'\)\[0\]\.toLowerCase\(\) === 'en'/);

// Speech recognition and speech synthesis are browser/platform capabilities,
// not GDevelop online services. Their official behavior and controls stay intact.
assert.match(yarnIndex, /onclick="app\.speakText\(\)" title="Hear text"/);
assert.match(yarnIndex, /id="toglTranscribing"/);
assert.match(yarnBundle, /spoken\.say\(/);
assert.match(yarnBundle, /spoken\.listen\(/);
assert.match(yarnBundle, /toggleTranscribing/);
assert.doesNotMatch(
  yarnI18nInstaller,
  /SpeechRecognition|webkitSpeechRecognition|speechSynthesis|localService/
);

console.log('GDevelop external resource editor contracts passed.');
