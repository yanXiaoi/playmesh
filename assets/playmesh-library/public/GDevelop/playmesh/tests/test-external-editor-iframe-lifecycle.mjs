import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const args = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  args.set(process.argv[index], process.argv[index + 1]);
}
const sourceRoot = args.get('--source');
assert.ok(
  sourceRoot,
  'Usage: test-external-editor-iframe-lifecycle.mjs --source <root>'
);

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(testDirectory, '../../../../../..');
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
    existsSync(path.join(nodeModules, '@babel/core/package.json')) &&
    existsSync(path.join(nodeModules, 'jsdom/package.json'))
  );
});
assert.ok(
  dependencyPackage,
  'the fixed WebIDE dependency cache is required for the iframe lifecycle test'
);

const appRequire = createRequire(dependencyPackage);
const { transformSync } = appRequire('@babel/core');
const flowStripPlugin = appRequire('@babel/plugin-transform-flow-strip-types');
const commonJsPlugin = appRequire('@babel/plugin-transform-modules-commonjs');
const jsxPlugin = appRequire('@babel/plugin-transform-react-jsx');
const { JSDOM, VirtualConsole } = appRequire('jsdom');

const makeEsm = exports => ({ __esModule: true, ...exports });
const makeDefaultEsm = value => makeEsm({ default: value });
const jsx = (type, props, ...children) => ({
  type,
  props: {
    ...(props || {}),
    ...(children.length === 0
      ? {}
      : { children: children.length === 1 ? children[0] : children }),
  },
});

const compileCommonJsModule = ({
  source,
  filename,
  stubs = {},
  requireFunction,
  setTimeoutFunction = setTimeout,
  clearTimeoutFunction = clearTimeout,
  windowObject = globalThis.window,
  documentObject = globalThis.document,
}) => {
  const compiled = transformSync(source, {
    babelrc: false,
    configFile: false,
    filename,
    plugins: [
      [flowStripPlugin, { all: true }],
      [jsxPlugin, { pragma: '__jsx' }],
      commonJsPlugin,
    ],
    sourceType: 'module',
  }).code;
  const module = { exports: {} };
  const resolveStub = id => {
    if (!Object.prototype.hasOwnProperty.call(stubs, id)) {
      throw new Error(`Missing test module stub: ${id}`);
    }
    return stubs[id];
  };
  const evaluate = new Function(
    'require',
    'module',
    'exports',
    '__jsx',
    'setTimeout',
    'clearTimeout',
    'window',
    'document',
    compiled
  );
  evaluate(
    requireFunction === undefined ? resolveStub : requireFunction,
    module,
    module.exports,
    jsx,
    setTimeoutFunction,
    clearTimeoutFunction,
    windowObject,
    documentObject
  );
  return module.exports;
};

const readSource = relativePath => {
  const filename = path.resolve(sourceRoot, ...relativePath.split('/'));
  return Promise.all([filename, readFile(filename, 'utf8')]);
};

const [
  [embeddedHelperFilename, embeddedHelperSource],
  [externalEditorsFilename, externalEditorsSource],
  [parentInterfaceFilename, parentInterfaceSource],
  [openedDialogFilename, openedDialogSource],
] = await Promise.all([
  readSource(
    'newIDE/app/src/ResourcesList/PlaymeshEmbeddedExternalEditorWindow.js'
  ),
  readSource('newIDE/app/src/ResourcesList/BrowserResourceExternalEditors.js'),
  readSource('newIDE/app/public/external/utils/parent-editor-interface.js'),
  readSource('newIDE/app/src/UI/ExternalEditorOpenedDialog.js'),
]);

const virtualConsole = new VirtualConsole();
const dom = new JSDOM('', {
  url: 'http://127.0.0.1:16666/dev/gdevelop/',
  pretendToBeVisual: true,
  virtualConsole,
});
const parentWindow = dom.window;
const parentDocument = parentWindow.document;

const originalGlobals = {
  document: globalThis.document,
  HTMLElement: globalThis.HTMLElement,
  Event: globalThis.Event,
  chrome: globalThis.chrome,
  navigationChannel: globalThis.PlaymeshExternalNavigation,
  navigationInstalled: globalThis.__playmeshExternalNavigationInstalled,
  popupApi: globalThis.__playmeshEmbeddedExternalEditorWindowApi,
};

let nextTimerId = 1;
const scheduledTimers = new Map();
const scheduleTimeout = (callback, delay) => {
  const id = nextTimerId++;
  scheduledTimers.set(id, { callback, delay });
  return id;
};
const cancelTimeout = id => scheduledTimers.delete(id);
const runScheduledTimeout = delay => {
  const matchingTimers = Array.from(scheduledTimers.entries()).filter(
    ([, timer]) => timer.delay === delay
  );
  assert.equal(
    matchingTimers.length,
    1,
    `expected exactly one scheduled ${delay}ms timeout`
  );
  const [id, timer] = matchingTimers[0];
  scheduledTimers.delete(id);
  timer.callback();
};

try {
  globalThis.document = parentDocument;
  globalThis.HTMLElement = parentWindow.HTMLElement;
  globalThis.Event = parentWindow.Event;
  delete globalThis.chrome;
  delete globalThis.PlaymeshExternalNavigation;
  globalThis.__playmeshExternalNavigationInstalled = true;

  const embeddedHelper = compileCommonJsModule({
    source: embeddedHelperSource,
    filename: embeddedHelperFilename,
    setTimeoutFunction: scheduleTimeout,
    clearTimeoutFunction: cancelTimeout,
    windowObject: parentWindow,
    documentObject: parentDocument,
    stubs: {
      '../PlaymeshLocalization/PlaymeshLocalizationSession': makeEsm({
        getPlaymeshMessage: key => key,
      }),
      '../PlaymeshLocalization/PlaymeshMessageKeys': makeEsm({
        playmeshMessages: {
          fullscreenEnter: 'workspace.gdevelop_fullscreen.enter',
          fullscreenExit: 'workspace.gdevelop_fullscreen.exit',
          externalEditorCancel: 'workspace.gdevelop_external_editor.cancel',
          externalEditorClosePreview:
            'workspace.gdevelop_external_editor.close_preview',
        },
      }),
    },
  });

  const loadingScreenWindows = [];
  class UserCancellationError extends Error {}
  const t = (strings, ...values) =>
    strings.reduce(
      (text, part, index) => text + part + (values[index] || ''),
      ''
    );
  const externalEditorsModule = compileCommonJsModule({
    source:
      externalEditorsSource +
      `\nexport {\n` +
      `  openAndWaitForExternalEditorWindow as __testOpenAndWaitForExternalEditorWindow,\n` +
      `  immediatelyOpenLoadingWindowForExternalEditor as __testImmediatelyOpenLoadingWindowForExternalEditor,\n` +
      `};\n`,
    filename: externalEditorsFilename,
    setTimeoutFunction: scheduleTimeout,
    clearTimeoutFunction: cancelTimeout,
    windowObject: parentWindow,
    documentObject: parentDocument,
    stubs: {
      './ResourceExternalEditor': makeEsm({
        saveBlobUrlsFromExternalEditorBase64Resources: async () => [],
        freeBlobsAndUpdateMetadata: () => {},
        patchExternalEditorMetadataWithResourcesNamesIfNecessary: () => {},
        readMetadata: () => null,
      }),
      '../Utils/Analytics/EventSender': makeEsm({
        sendExternalEditorOpened: () => {},
      }),
      '@lingui/macro': makeEsm({ t }),
      './ResourceUtils': makeEsm({
        isBlobURL: () => false,
        isURL: () => false,
      }),
      '../Utils/BlobDownloader': makeEsm({
        convertBlobToDataURL: async () => '',
        downloadUrlsToBlobs: async () => [],
      }),
      '../UI/Messages/MessageBox': makeEsm({ showWarningBox: () => {} }),
      '../Utils/BrowserExternalWindowUtils': makeEsm({
        displayBlackLoadingScreenOrThrow: externalEditorWindow => {
          loadingScreenWindows.push(externalEditorWindow);
        },
      }),
      '../LoginProvider/Utils': makeEsm({ UserCancellationError }),
      '../MainFrame/ResourcesWatcher': makeEsm({
        triggerOnResourceExternallyChanged: () => {},
      }),
      '../PlaymeshLocalization/PlaymeshLocalizationSession': makeEsm({
        getPlaymeshPromptLocale: () => 'en-US',
      }),
      '../ProjectsStorage/PlaymeshLocalStorageProvider': makeDefaultEsm({
        internalName: 'PlaymeshLocal',
      }),
      './PlaymeshEmbeddedExternalEditorWindow': makeEsm(embeddedHelper),
    },
  });
  const openAndWait =
    externalEditorsModule.__testOpenAndWaitForExternalEditorWindow;
  const immediatelyOpenRaw =
    externalEditorsModule.__testImmediatelyOpenLoadingWindowForExternalEditor;
  const assignedExternalEditorLocations = new WeakMap();
  const immediatelyOpen = () => {
    const openedWindow = immediatelyOpenRaw();
    // jsdom exposes Window.location as a configurable getter without the
    // browser's navigation setter. The locked official implementation assigns
    // to `window.location`, so make only this test WindowProxy writable while
    // preserving the production source byte-for-byte.
    const locationDescriptor = Object.getOwnPropertyDescriptor(
      openedWindow,
      'location'
    );
    if (locationDescriptor && !locationDescriptor.set) {
      const locationObject = openedWindow.location;
      Object.defineProperty(openedWindow, 'location', {
        configurable: true,
        enumerable: locationDescriptor.enumerable,
        get: () => locationObject,
        set: value => {
          assignedExternalEditorLocations.set(openedWindow, String(value));
        },
      });
    }
    return openedWindow;
  };
  assert.equal(typeof openAndWait, 'function');
  assert.equal(typeof immediatelyOpenRaw, 'function');

  // The iframe must be mounted in the active dialog so it remains inside the
  // editor's stacking/focus boundary. The last connected dialog is active.
  const firstDialog = parentDocument.createElement('div');
  const activeDialog = parentDocument.createElement('div');
  firstDialog.setAttribute('role', 'dialog');
  activeDialog.setAttribute('role', 'dialog');
  parentDocument.body.append(firstDialog, activeDialog);
  let nativeOpenCount = 0;
  parentWindow.open = () => {
    nativeOpenCount += 1;
    return null;
  };
  const dialogHostedWindow = immediatelyOpen();
  const dialogHostedFrame = activeDialog.querySelector(
    '[data-playmesh-embedded-external-editor-frame]'
  );
  assert.ok(dialogHostedFrame, 'the active dialog must host the editor iframe');
  assert.equal(dialogHostedFrame.contentWindow, dialogHostedWindow);
  assert.equal(
    activeDialog.querySelector('[data-playmesh-embedded-external-editor]')
      .parentElement,
    activeDialog
  );
  assert.equal(firstDialog.children.length, 0);
  assert.equal(nativeOpenCount, 0, 'WebView mode must not call window.open');
  assert.equal(loadingScreenWindows.at(-1), dialogHostedWindow);
  assert.equal(
    embeddedHelper.closePlaymeshEmbeddedExternalEditorWindow(
      dialogHostedWindow
    ),
    true
  );
  firstDialog.remove();
  activeDialog.remove();

  // In a regular browser, retain GDevelop's native popup transport unchanged.
  delete globalThis.__playmeshExternalNavigationInstalled;
  const nativePopupFrame = parentDocument.createElement('iframe');
  parentDocument.body.appendChild(nativePopupFrame);
  const nativePopupWindow = nativePopupFrame.contentWindow;
  let nativeOpenArguments = null;
  parentWindow.open = (...openArguments) => {
    nativeOpenCount += 1;
    nativeOpenArguments = openArguments;
    return nativePopupWindow;
  };
  const returnedNativePopup = immediatelyOpen();
  assert.equal(returnedNativePopup, nativePopupWindow);
  assert.equal(nativeOpenArguments[0], 'about:blank');
  assert.match(nativeOpenArguments[1], /^GDevelopExternalEditor\d+$/);
  assert.match(nativeOpenArguments[2], /width=800,height=600/);
  assert.equal(
    embeddedHelper.closePlaymeshEmbeddedExternalEditorWindow(
      nativePopupWindow
    ),
    false,
    'the iframe helper must not take ownership of native popups'
  );
  nativePopupFrame.remove();

  // The actual dialog component is suppressed only for the embedded WebView
  // transport. An ordinary browser still receives GDevelop's official dialog.
  const Dialog = () => null;
  const openedDialogModule = compileCommonJsModule({
    source: openedDialogSource,
    filename: openedDialogFilename,
    windowObject: parentWindow,
    documentObject: parentDocument,
    stubs: {
      '@lingui/macro': makeEsm({ Trans: 'Trans' }),
      '../Utils/OptionalRequire': makeDefaultEsm(() => null),
      './Dialog': makeDefaultEsm(Dialog),
      './Text': makeDefaultEsm(() => null),
      './FlatButton': makeDefaultEsm(() => null),
      '../ResourcesList/PlaymeshEmbeddedExternalEditorWindow': makeEsm(
        embeddedHelper
      ),
    },
  });
  assert.ok(
    openedDialogModule.ExternalEditorOpenedDialog({ onClose: async () => {} }),
    'ordinary browsers must retain the official external-editor-opened dialog'
  );
  globalThis.__playmeshExternalNavigationInstalled = true;
  assert.equal(
    openedDialogModule.ExternalEditorOpenedDialog({ onClose: async () => {} }),
    null,
    'the modal focus trap must be omitted for the embedded iframe transport'
  );

  // Exercise the full official message bridge with a real iframe WindowProxy.
  // Only the test transport for postMessage is supplied because jsdom does not
  // attach a calling Window as MessageEvent.source by itself.
  parentWindow.open = () => {
    throw new Error('native popup path used in WebView mode');
  };
  const externalEditorWindow = immediatelyOpen();
  const externalEditorFrame = parentDocument.querySelector(
    '[data-playmesh-embedded-external-editor-frame]'
  );
  assert.ok(externalEditorFrame);
  assert.equal(externalEditorFrame.contentWindow, externalEditorWindow);

  const parentMessageEvents = [];
  const childMessageEvents = [];
  const parentPostTargets = [];
  const childPostTargets = [];
  parentWindow.postMessage = (data, targetOrigin) => {
    const event = new parentWindow.MessageEvent('message', {
      data,
      origin: parentWindow.location.origin,
      source: externalEditorWindow,
    });
    parentMessageEvents.push(event);
    parentPostTargets.push(targetOrigin);
    parentWindow.dispatchEvent(event);
  };
  externalEditorWindow.postMessage = (data, targetOrigin) => {
    const event = new externalEditorWindow.MessageEvent('message', {
      data,
      origin: parentWindow.location.origin,
      source: parentWindow,
    });
    childMessageEvents.push(event);
    childPostTargets.push(targetOrigin);
    externalEditorWindow.dispatchEvent(event);
  };

  // Passing undefined is intentional: the official bridge uses the browser
  // parent path only when CommonJS/Electron require is absent.
  const parentInterface = compileCommonJsModule({
    source: parentInterfaceSource,
    filename: parentInterfaceFilename,
    requireFunction: null,
    windowObject: externalEditorWindow,
    documentObject: externalEditorWindow.document,
  });
  const expectedInput = {
    name: 'Hero',
    resources: [{ name: 'hero.png', dataUrl: 'data:image/png;base64,AA==' }],
  };
  const expectedOutput = {
    baseNameForNewResources: 'Hero',
    externalEditorData: { fps: 12 },
    resources: [{ name: 'hero.png', dataUrl: 'data:image/png;base64,AQ==' }],
  };
  let receivedInput = null;
  parentInterface.onMessageFromParentEditor(
    'open-external-editor-input',
    payload => {
      receivedInput = payload;
      parentInterface.sendMessageToParentEditor(
        'save-external-editor-output',
        expectedOutput
      );
      parentInterface.closeWindow();
    }
  );
  const controller = new AbortController();
  const lifecyclePromise = openAndWait({
    externalEditorWindow,
    externalEditorName: 'piskel',
    externalEditorInput: expectedInput,
    signal: controller.signal,
  });
  assert.equal(
    assignedExternalEditorLocations.get(externalEditorWindow),
    'http://127.0.0.1:16666/dev/gdevelop/external/piskel/piskel-index.html?locale=en-US',
    'the location assignment must target the locked Piskel entry point with the committed locale'
  );

  const foreignFrame = parentDocument.createElement('iframe');
  parentDocument.body.appendChild(foreignFrame);
  parentWindow.dispatchEvent(
    new parentWindow.MessageEvent('message', {
      data: { id: 'external-editor-ready' },
      origin: parentWindow.location.origin,
      source: foreignFrame.contentWindow,
    })
  );
  assert.equal(
    childMessageEvents.length,
    0,
    'a ready message from another WindowProxy must be ignored'
  );
  foreignFrame.remove();

  parentInterface.sendMessageToParentEditor('external-editor-ready');
  const lifecycleOutput = await lifecyclePromise;
  assert.deepEqual(receivedInput, expectedInput);
  assert.deepEqual(lifecycleOutput, expectedOutput);
  assert.equal(parentMessageEvents.length, 3);
  assert.ok(
    parentMessageEvents.every(event => event.source === externalEditorWindow),
    'ready, save and close must retain the exact iframe WindowProxy as source'
  );
  assert.deepEqual(
    parentMessageEvents.map(event => event.data.id),
    [
      'external-editor-ready',
      'save-external-editor-output',
      'close',
    ]
  );
  assert.equal(parentPostTargets.every(target => target === '*'), true);
  assert.equal(childMessageEvents.length, 1);
  assert.equal(childMessageEvents[0].source, parentWindow);
  assert.equal(childMessageEvents[0].data.id, 'open-external-editor-input');
  assert.equal(childPostTargets[0], parentWindow.location.origin);
  assert.equal(
    parentDocument.querySelector(
      '[data-playmesh-embedded-external-editor]'
    ),
    null,
    'close must remove the complete embedded surface'
  );
  assert.equal(
    scheduledTimers.size,
    0,
    'the ready lifecycle must clear its startup timeout'
  );

  // A load event is not readiness. If the editor never sends the official
  // ready message, the 10 second timeout must close it and remove listeners.
  const timedOutWindow = immediatelyOpen();
  let postAfterTimeoutCount = 0;
  timedOutWindow.postMessage = () => {
    postAfterTimeoutCount += 1;
  };
  const timeoutController = new AbortController();
  const timedOutLifecycle = openAndWait({
    externalEditorWindow: timedOutWindow,
    externalEditorName: 'piskel',
    externalEditorInput: expectedInput,
    signal: timeoutController.signal,
  });
  timedOutWindow.dispatchEvent(new timedOutWindow.Event('load'));
  runScheduledTimeout(10000);
  assert.equal(await timedOutLifecycle, null);
  assert.equal(
    parentDocument.querySelector(
      '[data-playmesh-embedded-external-editor]'
    ),
    null
  );
  parentWindow.dispatchEvent(
    new parentWindow.MessageEvent('message', {
      data: { id: 'external-editor-ready' },
      origin: parentWindow.location.origin,
      source: timedOutWindow,
    })
  );
  assert.equal(
    postAfterTimeoutCount,
    0,
    'the message listener must be removed after readiness timeout cleanup'
  );
  timeoutController.abort();
  assert.equal(scheduledTimers.size, 0);

  // A spontaneous iframe unload (reload/crash/navigation) must remove the
  // owned surface as well as resolving the official editor lifecycle.
  const unloadedWindow = immediatelyOpen();
  const unloadController = new AbortController();
  const unloadedLifecycle = openAndWait({
    externalEditorWindow: unloadedWindow,
    externalEditorName: 'piskel',
    externalEditorInput: expectedInput,
    signal: unloadController.signal,
  });
  unloadedWindow.dispatchEvent(new unloadedWindow.Event('load'));
  unloadedWindow.dispatchEvent(new unloadedWindow.Event('unload'));
  assert.equal(await unloadedLifecycle, null);
  assert.equal(
    parentDocument.querySelector(
      '[data-playmesh-embedded-external-editor]'
    ),
    null,
    'a spontaneous unload must not leave the embedded overlay behind'
  );
  assert.equal(scheduledTimers.size, 0);
} finally {
  dom.window.close();
  for (const [key, value] of Object.entries({
    document: originalGlobals.document,
    HTMLElement: originalGlobals.HTMLElement,
    Event: originalGlobals.Event,
    chrome: originalGlobals.chrome,
    PlaymeshExternalNavigation: originalGlobals.navigationChannel,
    __playmeshExternalNavigationInstalled:
      originalGlobals.navigationInstalled,
    __playmeshEmbeddedExternalEditorWindowApi: originalGlobals.popupApi,
  })) {
    if (value === undefined) delete globalThis[key];
    else globalThis[key] = value;
  }
}

console.log('GDevelop external-editor iframe lifecycle contracts passed.');
