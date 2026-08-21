import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const moduleUrl = new URL(
  '../overlays/newIDE/app/src/ResourcesList/PlaymeshEmbeddedExternalEditorWindow.js',
  import.meta.url
);
const source = await readFile(moduleUrl, 'utf8');
const localizationMockProperty =
  '__playmeshEmbeddedExternalEditorLocalizationTest';
const originalLocalizationMockDescriptor = Object.getOwnPropertyDescriptor(
  globalThis,
  localizationMockProperty
);
const localizedHostLabels = new Map([
  [
    'workspace.gdevelop_external_editor.cancel',
    'Cancel test external editor',
  ],
  [
    'workspace.gdevelop_external_editor.close_preview',
    'Close test preview',
  ],
]);
globalThis[localizationMockProperty] = key =>
  localizedHostLabels.get(key) || key;
const executableSource = source
  .replace(
    "import { getPlaymeshMessage } from '../PlaymeshLocalization/PlaymeshLocalizationSession';",
    `const getPlaymeshMessage = key => globalThis.${localizationMockProperty}(key);`
  )
  .replace(
    "import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';",
    `const playmeshMessages = { externalEditorCancel: 'workspace.gdevelop_external_editor.cancel', externalEditorClosePreview: 'workspace.gdevelop_external_editor.close_preview' };`
  );
const module = await import(
  `data:text/javascript;base64,${Buffer.from(executableSource).toString(
    'base64'
  )}`
);

class FakeEvent {
  constructor(type) {
    this.type = type;
  }
}

class FakeEventTarget {
  constructor() {
    this.listeners = new Map();
  }

  addEventListener(type, listener) {
    const listeners = this.listeners.get(type) || new Set();
    listeners.add(listener);
    this.listeners.set(type, listeners);
  }

  removeEventListener(type, listener) {
    const listeners = this.listeners.get(type);
    if (listeners) listeners.delete(listener);
  }

  dispatchEvent(event) {
    for (const listener of this.listeners.get(event.type) || []) {
      listener.call(this, event);
    }
  }
}

class FakeWindow extends FakeEventTarget {
  constructor(document) {
    super();
    this.document = document;
    this.Event = FakeEvent;
  }
}

class FakeElement extends FakeEventTarget {
  constructor(tagName, ownerDocument) {
    super();
    this.tagName = tagName.toUpperCase();
    this.ownerDocument = ownerDocument;
    this.attributes = new Map();
    this.children = [];
    this.parentElement = null;
    this.style = {};
    this.hidden = false;
    this.isConnected = false;
    this.focusCount = 0;
    this.removed = false;
  }

  appendChild(child) {
    child.parentElement = this;
    child.setConnected(this.isConnected);
    this.children.push(child);
    return child;
  }

  setConnected(isConnected) {
    this.isConnected = isConnected;
    for (const child of this.children) child.setConnected(isConnected);
  }

  setAttribute(name, value) {
    this.attributes.set(name, String(value));
  }

  getAttribute(name) {
    return this.attributes.get(name) || null;
  }

  closest(selector) {
    if (selector !== '[role="dialog"]') return null;
    let element = this;
    while (element) {
      if (element.getAttribute('role') === 'dialog') return element;
      element = element.parentElement;
    }
    return null;
  }

  focus() {
    this.focusCount += 1;
    if (this.ownerDocument) this.ownerDocument.activeElement = this;
  }

  click() {
    this.dispatchEvent(new FakeEvent('click'));
  }

  remove() {
    this.removed = true;
    this.setConnected(false);
    if (this.parentElement) {
      const index = this.parentElement.children.indexOf(this);
      if (index !== -1) this.parentElement.children.splice(index, 1);
      this.parentElement = null;
    }
  }
}

class FakeContentDocument {
  constructor() {
    this.documentElement = { clientWidth: 320, clientHeight: 320 };
    this.body = { innerHTML: '' };
    this.title = '';
  }
}

class FakeFrame extends FakeElement {
  constructor(ownerDocument) {
    super('iframe', ownerDocument);
    this.contentWindow = new FakeWindow(new FakeContentDocument());
    if (ownerDocument.lockIframeWindowMethods) {
      Object.defineProperty(this.contentWindow, 'close', {
        configurable: false,
        value: () => {},
        writable: false,
      });
    }
  }
}

class FakeDocument extends FakeEventTarget {
  constructor() {
    super();
    this.body = new FakeElement('body', this);
    this.body.setConnected(true);
    this.documentElement = new FakeElement('html', this);
    this.documentElement.setConnected(true);
    this.activeElement = this.body;
    this.fullscreenElement = null;
    this.lockIframeWindowMethods = false;
  }

  createElement(tagName) {
    return tagName === 'iframe'
      ? new FakeFrame(this)
      : new FakeElement(tagName, this);
  }

  querySelectorAll(selector) {
    assert.equal(selector, '[role="dialog"]');
    const matches = [];
    const visit = element => {
      if (element.getAttribute('role') === 'dialog') matches.push(element);
      for (const child of element.children) visit(child);
    };
    visit(this.body);
    return matches;
  }
}

class FakeResizeObserver {
  static instances = [];

  constructor(callback) {
    this.callback = callback;
    this.observed = null;
    this.disconnected = false;
    FakeResizeObserver.instances.push(this);
  }

  observe(element) {
    this.observed = element;
  }

  disconnect() {
    this.disconnected = true;
  }
}

const findByAttribute = (root, name, value) => {
  if (root.attributes && root.attributes.get(name) === value) return root;
  for (const child of root.children || []) {
    const match = findByAttribute(child, name, value);
    if (match) return match;
  }
  return null;
};

const originalGlobals = {
  document: globalThis.document,
  Event: globalThis.Event,
  ResizeObserver: globalThis.ResizeObserver,
  chrome: globalThis.chrome,
  navigationInstalled: globalThis.__playmeshExternalNavigationInstalled,
  navigationChannel: globalThis.PlaymeshExternalNavigation,
  popupApiDescriptor: Object.getOwnPropertyDescriptor(
    globalThis,
    '__playmeshEmbeddedExternalEditorWindowApi'
  ),
};

try {
  const document = new FakeDocument();
  globalThis.document = document;
  globalThis.Event = FakeEvent;
  globalThis.ResizeObserver = FakeResizeObserver;
  delete globalThis.chrome;
  delete globalThis.PlaymeshExternalNavigation;
  delete globalThis.__playmeshExternalNavigationInstalled;

  assert.equal(
    module.openPlaymeshEmbeddedExternalEditorWindow({ targetId: 'regular' }),
    null,
    'regular browsers must keep the native GDevelop popup path'
  );
  assert.equal(document.body.children.length, 0);
  assert.equal(
    globalThis.__playmeshEmbeddedExternalEditorWindowApi,
    undefined,
    'the nested iframe API must not be exposed by a regular browser path'
  );

  const activeDialog = document.createElement('div');
  activeDialog.setAttribute('role', 'dialog');
  document.body.appendChild(activeDialog);
  const trigger = document.createElement('button');
  activeDialog.appendChild(trigger);
  trigger.focus();

  const laterDialog = document.createElement('div');
  laterDialog.setAttribute('role', 'dialog');
  document.body.appendChild(laterDialog);

  globalThis.__playmeshExternalNavigationInstalled = true;
  const externalEditorWindow =
    module.openPlaymeshEmbeddedExternalEditorWindow({
      targetId: 'GDevelopExternalEditor0',
    });
  assert.ok(externalEditorWindow);
  assert.equal(
    activeDialog.children.length,
    2,
    'the surface must stay inside the actively focused MUI dialog'
  );
  assert.equal(laterDialog.children.length, 0);
  const overlay = findByAttribute(
    activeDialog,
    'data-playmesh-embedded-external-editor',
    'GDevelopExternalEditor0'
  );
  assert.ok(overlay);
  const frame = findByAttribute(
    overlay,
    'data-playmesh-embedded-external-editor-frame',
    'GDevelopExternalEditor0'
  );
  const closeButton = findByAttribute(
    overlay,
    'data-playmesh-embedded-editor-close',
    'true'
  );
  const controlRail = findByAttribute(
    overlay,
    'data-playmesh-embedded-editor-control-rail',
    'true'
  );
  assert.equal(externalEditorWindow, frame.contentWindow);
  assert.equal(frame.src, 'about:blank');
  assert.equal(frame.attributes.has('sandbox'), false);
  assert.equal(frame.style.position, 'absolute');
  assert.equal(frame.style.inset, '0');
  assert.equal(frame.style.width, '100%');
  assert.equal(frame.style.height, '100%');
  assert.equal(overlay.style.position, 'fixed');
  assert.equal(overlay.style.inset, '0');
  assert.equal(overlay.style.zIndex, '2147483647');
  assert.equal(frame.focusCount, 1);
  assert.equal(closeButton.title, 'Cancel test external editor');
  assert.equal(controlRail.children.length, 1);
  assert.equal(controlRail.children[0], closeButton);
  assert.equal(controlRail.style.top, '48px');
  assert.equal(controlRail.style.gridTemplateColumns, '44px');
  assert.equal(controlRail.style.width, '44px');
  assert.equal(controlRail.style.height, '44px');
  assert.equal(controlRail.style.pointerEvents, 'none');
  assert.equal(
    findByAttribute(
      overlay,
      'data-playmesh-embedded-editor-fullscreen',
      'true'
    ),
    null,
    'the embedded editor is already full-size and must not expose a fullscreen control'
  );
  assert.equal(closeButton.style.visibility, undefined);
  assert.equal(
    module.isPlaymeshEmbeddedExternalEditorWindow(externalEditorWindow),
    true
  );
  assert.equal(
    module.markPlaymeshEmbeddedExternalEditorReady(externalEditorWindow),
    true
  );
  assert.equal(
    closeButton.style.visibility,
    undefined,
    'the host Cancel control must remain visible after editor readiness'
  );
  assert.equal(closeButton.style.pointerEvents, 'auto');
  assert.notEqual(closeButton.tabIndex, -1);
  assert.equal(closeButton.getAttribute('aria-hidden'), null);
  assert.equal(controlRail.children.length, 1);
  assert.equal(controlRail.children[0], closeButton);

  const popupApi = globalThis.__playmeshEmbeddedExternalEditorWindowApi;
  assert.equal(typeof popupApi.openPopup, 'function');
  const piskelDocument = new FakeDocument();
  const piskelDialog = piskelDocument.createElement('div');
  piskelDialog.setAttribute('role', 'dialog');
  piskelDocument.body.appendChild(piskelDialog);
  const piskelTrigger = piskelDocument.createElement('button');
  piskelDialog.appendChild(piskelTrigger);
  piskelTrigger.focus();
  const piskelWindow = new FakeWindow(piskelDocument);
  piskelWindow.ResizeObserver = FakeResizeObserver;

  assert.equal(
    popupApi.openPopup({
      ownerWindow: piskelWindow,
      url: 'https://example.invalid/',
    }),
    null,
    'only the two local about:blank Piskel popup calls may use the iframe adapter'
  );
  const popupWindow = popupApi.openPopup({
    ownerWindow: piskelWindow,
    url: 'about:blank',
    target: 'preview',
    features: 'width=320,height=320',
  });
  assert.ok(popupWindow);
  const popupOverlay = findByAttribute(
    piskelDialog,
    'data-playmesh-embedded-popup',
    'true'
  );
  const popupFrame = findByAttribute(
    popupOverlay,
    'data-playmesh-embedded-popup-frame',
    'true'
  );
  const popupCloseButton = findByAttribute(
    popupOverlay,
    'data-playmesh-embedded-editor-close',
    'true'
  );
  const popupControlRail = findByAttribute(
    popupOverlay,
    'data-playmesh-embedded-editor-control-rail',
    'true'
  );
  const popupPanel = popupFrame.parentElement;
  assert.equal(popupWindow, popupFrame.contentWindow);
  assert.ok(popupWindow.document, 'the adapter must return a real iframe Window');
  assert.equal(popupFrame.attributes.has('sandbox'), false);
  assert.equal(popupFrame.name, 'preview');
  assert.equal(popupPanel.style.width, '320px');
  assert.equal(popupPanel.style.height, '320px');
  assert.equal(popupPanel.style.resize, 'both');
  assert.equal(popupCloseButton.title, 'Close test preview');
  assert.equal(popupControlRail.children.length, 1);
  assert.equal(popupControlRail.children[0], popupCloseButton);
  assert.equal(
    findByAttribute(
      popupOverlay,
      'data-playmesh-embedded-editor-fullscreen',
      'true'
    ),
    null
  );

  let resizeCount = 0;
  let unloadCount = 0;
  popupWindow.addEventListener('resize', () => resizeCount++);
  popupWindow.addEventListener('unload', () => unloadCount++);
  piskelWindow.dispatchEvent(new FakeEvent('resize'));
  assert.equal(resizeCount, 1);
  popupWindow.focus();
  assert.equal(popupFrame.focusCount, 2);
  popupCloseButton.click();
  assert.equal(unloadCount, 1);
  assert.equal(popupOverlay.removed, true);
  assert.equal(popupPanel.style.width, '320px');
  assert.equal(popupPanel.style.height, '320px');
  assert.equal(popupPanel.style.resize, 'both');
  assert.equal(piskelTrigger.focusCount, 2);
  assert.equal(FakeResizeObserver.instances.at(-1).disconnected, true);
  popupWindow.close();
  assert.equal(unloadCount, 1, 'nested popup close must be idempotent');

  piskelDocument.lockIframeWindowMethods = true;
  assert.equal(
    popupApi.openPopup({
      ownerWindow: piskelWindow,
      url: 'about:blank',
    }),
    null,
    'a WebView that forbids WindowProxy method overrides must fall back without leaving an overlay'
  );
  assert.equal(
    findByAttribute(piskelDialog, 'data-playmesh-embedded-popup', 'true'),
    null
  );
  piskelDocument.lockIframeWindowMethods = false;

  const popupClosedWithOuterWindow = popupApi.openPopup({
    ownerWindow: piskelWindow,
    url: 'about:blank',
  });
  const popupClosedWithOuterOverlay = findByAttribute(
    piskelDialog,
    'data-playmesh-embedded-popup',
    'true'
  );
  let popupClosedWithOuterUnloadCount = 0;
  popupClosedWithOuterWindow.addEventListener(
    'unload',
    () => popupClosedWithOuterUnloadCount++
  );

  let outerUnloadCount = 0;
  externalEditorWindow.addEventListener('unload', () => outerUnloadCount++);
  assert.equal(
    module.closePlaymeshEmbeddedExternalEditorWindow(externalEditorWindow),
    true
  );
  assert.equal(overlay.removed, true);
  assert.equal(outerUnloadCount, 1);
  assert.equal(popupClosedWithOuterOverlay.removed, true);
  assert.equal(popupClosedWithOuterUnloadCount, 1);
  assert.equal(trigger.focusCount, 2);
  assert.equal(
    module.isPlaymeshEmbeddedExternalEditorWindow(externalEditorWindow),
    false
  );
  assert.equal(
    module.closePlaymeshEmbeddedExternalEditorWindow(externalEditorWindow),
    false,
    'closing an embedded surface must be idempotent'
  );

  localizedHostLabels.delete('workspace.gdevelop_external_editor.cancel');
  document.documentElement.lang = 'zh-CN';
  const queuedWindow = module.openPlaymeshEmbeddedExternalEditorWindow({
    targetId: 'GDevelopExternalEditor1',
  });
  const queuedOverlay = findByAttribute(
    activeDialog,
    'data-playmesh-embedded-external-editor',
    'GDevelopExternalEditor1'
  );
  const queuedCloseButton = findByAttribute(
    queuedOverlay,
    'data-playmesh-embedded-editor-close',
    'true'
  );
  assert.equal(
    queuedCloseButton.title,
    '取消外部编辑器',
    'unresolved host localization must use the current document language'
  );
  assert.equal(
    findByAttribute(
      queuedOverlay,
      'data-playmesh-embedded-editor-fullscreen',
      'true'
    ),
    null
  );
  queuedCloseButton.click();
  let queuedCloseCount = 0;
  module.setPlaymeshEmbeddedExternalEditorCloseRequestHandler(
    queuedWindow,
    () => {
      queuedCloseCount += 1;
      module.closePlaymeshEmbeddedExternalEditorWindow(queuedWindow);
    }
  );
  await Promise.resolve();
  assert.equal(queuedCloseCount, 1);
  assert.equal(queuedOverlay.removed, true);
} finally {
  for (const [key, value] of Object.entries({
    document: originalGlobals.document,
    Event: originalGlobals.Event,
    ResizeObserver: originalGlobals.ResizeObserver,
    chrome: originalGlobals.chrome,
    __playmeshExternalNavigationInstalled:
      originalGlobals.navigationInstalled,
    PlaymeshExternalNavigation: originalGlobals.navigationChannel,
  })) {
    if (value === undefined) delete globalThis[key];
    else globalThis[key] = value;
  }
  delete globalThis.__playmeshEmbeddedExternalEditorWindowApi;
  if (originalGlobals.popupApiDescriptor) {
    Object.defineProperty(
      globalThis,
      '__playmeshEmbeddedExternalEditorWindowApi',
      originalGlobals.popupApiDescriptor
    );
  }
  delete globalThis[localizationMockProperty];
  if (originalLocalizationMockDescriptor) {
    Object.defineProperty(
      globalThis,
      localizationMockProperty,
      originalLocalizationMockDescriptor
    );
  }
}

console.log('Embedded GDevelop external-editor window contracts passed.');
