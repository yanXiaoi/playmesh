/* global globalThis */

import { getPlaymeshMessage } from '../PlaymeshLocalization/PlaymeshLocalizationSession';
import { playmeshMessages } from '../PlaymeshLocalization/PlaymeshMessageKeys';

const embeddedExternalEditorSurfaces = new WeakMap();
const embeddedPopupSurfaces = new Set();
const embeddedPopupApiProperty =
  '__playmeshEmbeddedExternalEditorWindowApi';

const getLocalizedHostLabel = (
  ownerDocument,
  messageKey,
  { englishFallback, chineseFallback }
) => {
  const localizedLabel = getPlaymeshMessage(messageKey);
  if (localizedLabel !== messageKey) return localizedLabel;
  const documentLanguage = String(
    (ownerDocument.documentElement && ownerDocument.documentElement.lang) || ''
  ).toLowerCase();
  return documentLanguage.startsWith('zh')
    ? chineseFallback
    : englishFallback;
};

export const shouldUsePlaymeshEmbeddedExternalEditorWindow = () =>
  globalThis.__playmeshExternalNavigationInstalled === true ||
  !!(
    globalThis.PlaymeshExternalNavigation &&
    typeof globalThis.PlaymeshExternalNavigation.postMessage === 'function'
  ) ||
  !!(
    globalThis.chrome &&
    globalThis.chrome.webview &&
    typeof globalThis.chrome.webview.postMessage === 'function'
  );

const getCurrentDialogOrDocumentHost = ownerDocument => {
  const activeElement = ownerDocument.activeElement;
  const activeDialog =
    activeElement && typeof activeElement.closest === 'function'
      ? activeElement.closest('[role="dialog"]')
      : null;
  if (activeDialog && activeDialog.isConnected !== false) return activeDialog;

  const dialogs = ownerDocument.querySelectorAll
    ? ownerDocument.querySelectorAll('[role="dialog"]')
    : [];
  for (let index = dialogs.length - 1; index >= 0; index--) {
    const dialog = dialogs[index];
    if (
      dialog.isConnected !== false &&
      dialog.hidden !== true &&
      (!dialog.getAttribute || dialog.getAttribute('aria-hidden') !== 'true')
    ) {
      return dialog;
    }
  }
  return ownerDocument.body || ownerDocument.documentElement;
};

const getPreviouslyFocusedElement = ownerDocument => {
  const activeElement = ownerDocument.activeElement;
  return activeElement && typeof activeElement.focus === 'function'
    ? activeElement
    : null;
};

const restoreFocus = previouslyFocusedElement => {
  if (
    previouslyFocusedElement &&
    previouslyFocusedElement.isConnected !== false
  ) {
    previouslyFocusedElement.focus();
  }
};

const createControlRail = ownerDocument => {
  const controlRail = ownerDocument.createElement('div');
  controlRail.setAttribute(
    'data-playmesh-embedded-editor-control-rail',
    'true'
  );
  Object.assign(controlRail.style, {
    position: 'absolute',
    top: '48px',
    right: '8px',
    display: 'grid',
    gridTemplateColumns: '44px',
    width: '44px',
    height: '44px',
    direction: 'ltr',
    pointerEvents: 'none',
    zIndex: '2',
  });
  return controlRail;
};

const applyControlButtonStyles = button => {
  Object.assign(button.style, {
    width: '44px',
    height: '44px',
    border: '1px solid rgba(255, 255, 255, 0.72)',
    borderRadius: '6px',
    padding: '0',
    backgroundColor: 'rgba(24, 24, 29, 0.92)',
    color: '#ffffff',
    fontFamily: 'sans-serif',
    cursor: 'pointer',
    pointerEvents: 'auto',
    touchAction: 'manipulation',
    WebkitTapHighlightColor: 'transparent',
  });
};

const createCloseButton = ({ ownerDocument, label, onClick }) => {
  const closeButton = ownerDocument.createElement('button');
  closeButton.type = 'button';
  closeButton.textContent = '×';
  closeButton.title = label;
  closeButton.setAttribute('aria-label', label);
  closeButton.setAttribute('data-playmesh-embedded-editor-close', 'true');
  applyControlButtonStyles(closeButton);
  Object.assign(closeButton.style, {
    fontSize: '28px',
    lineHeight: '30px',
  });
  closeButton.addEventListener('click', onClick);
  return closeButton;
};

const dispatchWindowEvent = (targetWindow, eventName) => {
  try {
    const EventConstructor = targetWindow.Event || globalThis.Event;
    if (EventConstructor && typeof targetWindow.dispatchEvent === 'function') {
      targetWindow.dispatchEvent(new EventConstructor(eventName));
    }
  } catch (error) {
    console.warn(
      `Unable to dispatch the embedded editor ${eventName} event.`,
      error
    );
  }
};

const parsePopupDimension = (features, name, fallback) => {
  const match = String(features || '').match(
    new RegExp(`(?:^|,)\\s*${name}\\s*=\\s*(\\d+)`, 'i')
  );
  if (!match) return fallback;
  const value = Number(match[1]);
  return Number.isFinite(value) && value > 0 ? value : fallback;
};

const isAboutBlankUrl = url =>
  String(url === undefined || url === null ? '' : url)
    .trim()
    .toLowerCase() === 'about:blank';

const installWindowMethod = (targetWindow, methodName, method) => {
  try {
    Object.defineProperty(targetWindow, methodName, {
      configurable: true,
      value: method,
    });
  } catch {
    try {
      targetWindow[methodName] = method;
    } catch {
      return false;
    }
  }
  return targetWindow[methodName] === method;
};

const openPlaymeshEmbeddedPopupWindow = ({
  ownerWindow,
  url,
  target,
  features,
}) => {
  if (
    !shouldUsePlaymeshEmbeddedExternalEditorWindow() ||
    !isAboutBlankUrl(url) ||
    !ownerWindow ||
    !ownerWindow.document
  ) {
    return null;
  }

  const ownerDocument = ownerWindow.document;
  const host = getCurrentDialogOrDocumentHost(ownerDocument);
  if (!host) return null;

  const overlay = ownerDocument.createElement('div');
  overlay.setAttribute('data-playmesh-embedded-popup', 'true');
  Object.assign(overlay.style, {
    position: 'fixed',
    inset: '0',
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    padding: '16px',
    boxSizing: 'border-box',
    backgroundColor: 'rgba(0, 0, 0, 0.62)',
    zIndex: '2147483647',
  });

  const width = parsePopupDimension(features, 'width', 800);
  const height = parsePopupDimension(features, 'height', 600);
  const panel = ownerDocument.createElement('div');
  Object.assign(panel.style, {
    position: 'relative',
    width: `${width}px`,
    height: `${height}px`,
    maxWidth: '100%',
    maxHeight: '100%',
    minWidth: '160px',
    minHeight: '160px',
    overflow: 'hidden',
    resize: 'both',
    backgroundColor: '#000000',
    boxShadow: '0 8px 32px rgba(0, 0, 0, 0.55)',
  });

  const frame = ownerDocument.createElement('iframe');
  frame.name = target || '';
  frame.title = 'Piskel preview';
  frame.src = 'about:blank';
  frame.tabIndex = 0;
  frame.setAttribute('data-playmesh-embedded-popup-frame', 'true');
  Object.assign(frame.style, {
    width: '100%',
    height: '100%',
    border: '0',
    margin: '0',
    padding: '0',
    backgroundColor: '#000000',
  });

  const previouslyFocusedElement = getPreviouslyFocusedElement(ownerDocument);
  panel.appendChild(frame);
  overlay.appendChild(panel);
  host.appendChild(overlay);

  const popupWindow = frame.contentWindow;
  if (!popupWindow) {
    overlay.remove();
    return null;
  }

  let resizeObserver = null;
  let closed = false;
  const surface = {
    close: null,
    ownerWindow,
    popupWindow,
  };
  const dispatchResize = () => dispatchWindowEvent(popupWindow, 'resize');
  const closePopup = () => {
    if (closed) return;
    closed = true;
    if (resizeObserver) resizeObserver.disconnect();
    if (typeof ownerWindow.removeEventListener === 'function') {
      ownerWindow.removeEventListener('resize', dispatchResize);
    }
    embeddedPopupSurfaces.delete(surface);
    dispatchWindowEvent(popupWindow, 'unload');
    overlay.remove();
    restoreFocus(previouslyFocusedElement);
  };
  const focusPopup = () => {
    frame.focus();
  };
  const closeButton = createCloseButton({
    ownerDocument,
    label: getLocalizedHostLabel(
      ownerDocument,
      playmeshMessages.externalEditorClosePreview,
      {
        englishFallback: 'Close preview',
        chineseFallback: '关闭预览',
      }
    ),
    onClick: closePopup,
  });
  const controlRail = createControlRail(ownerDocument);
  controlRail.appendChild(closeButton);
  overlay.appendChild(controlRail);

  surface.close = closePopup;
  if (
    !installWindowMethod(popupWindow, 'close', closePopup) ||
    !installWindowMethod(popupWindow, 'focus', focusPopup)
  ) {
    closePopup();
    return null;
  }
  embeddedPopupSurfaces.add(surface);

  const ResizeObserverConstructor =
    ownerWindow.ResizeObserver || globalThis.ResizeObserver;
  if (typeof ResizeObserverConstructor === 'function') {
    resizeObserver = new ResizeObserverConstructor(dispatchResize);
    resizeObserver.observe(panel);
  }
  if (typeof ownerWindow.addEventListener === 'function') {
    ownerWindow.addEventListener('resize', dispatchResize);
  }

  frame.focus();
  return popupWindow;
};

const embeddedPopupApi = Object.freeze({
  openPopup: openPlaymeshEmbeddedPopupWindow,
});

const exposeEmbeddedPopupApi = () => {
  if (globalThis[embeddedPopupApiProperty] === embeddedPopupApi) return;
  Object.defineProperty(globalThis, embeddedPopupApiProperty, {
    configurable: true,
    value: embeddedPopupApi,
  });
};

/**
 * Creates the browser external-editor surface inside the Playmesh WebView.
 * Regular browsers keep using GDevelop's native popup window unchanged.
 */
export const openPlaymeshEmbeddedExternalEditorWindow = ({ targetId }) => {
  if (!shouldUsePlaymeshEmbeddedExternalEditorWindow()) return null;

  const host = getCurrentDialogOrDocumentHost(document);
  if (!host) return null;

  exposeEmbeddedPopupApi();

  const overlay = document.createElement('div');
  overlay.setAttribute('data-playmesh-embedded-external-editor', targetId);
  Object.assign(overlay.style, {
    position: 'fixed',
    inset: '0',
    backgroundColor: '#000000',
    zIndex: '2147483647',
  });

  const frame = document.createElement('iframe');
  frame.name = targetId;
  frame.title = 'GDevelop external editor';
  frame.src = 'about:blank';
  frame.tabIndex = 0;
  frame.setAttribute('data-playmesh-embedded-external-editor-frame', targetId);
  Object.assign(frame.style, {
    position: 'absolute',
    inset: '0',
    width: '100%',
    height: '100%',
    border: '0',
    margin: '0',
    padding: '0',
    backgroundColor: '#000000',
  });

  const previouslyFocusedElement = getPreviouslyFocusedElement(document);
  overlay.appendChild(frame);
  host.appendChild(overlay);

  const externalEditorWindow = frame.contentWindow;
  if (!externalEditorWindow) {
    overlay.remove();
    return null;
  }

  const surface = {
    closeRequestHandler: null,
    closeRequested: false,
    closeButton: null,
    externalEditorWindow,
    frame,
    overlay,
    previouslyFocusedElement,
  };
  const requestClose = () => {
    if (surface.closeRequestHandler) {
      surface.closeRequestHandler();
    } else {
      surface.closeRequested = true;
    }
  };
  const closeButton = createCloseButton({
    ownerDocument: document,
    label: getLocalizedHostLabel(
      document,
      playmeshMessages.externalEditorCancel,
      {
        englishFallback: 'Cancel external editor',
        chineseFallback: '取消外部编辑器',
      }
    ),
    onClick: requestClose,
  });
  const controlRail = createControlRail(document);
  controlRail.appendChild(closeButton);
  overlay.appendChild(controlRail);
  surface.closeButton = closeButton;

  embeddedExternalEditorSurfaces.set(externalEditorWindow, surface);
  frame.addEventListener('load', () => frame.focus());
  frame.focus();
  return externalEditorWindow;
};

export const isPlaymeshEmbeddedExternalEditorWindow = externalEditorWindow =>
  embeddedExternalEditorSurfaces.has(externalEditorWindow);

/**
 * Confirms that the embedded surface still exists after the official editor
 * announces readiness. The host Cancel control remains available throughout
 * the editor lifecycle, including if input initialization later fails.
 */
export const markPlaymeshEmbeddedExternalEditorReady = externalEditorWindow => {
  const surface = embeddedExternalEditorSurfaces.get(externalEditorWindow);
  if (!surface || !surface.closeButton) return false;
  return true;
};

/**
 * Connects the host close button to GDevelop's official editor cancellation
 * lifecycle. The returned function removes only the supplied handler.
 */
export const setPlaymeshEmbeddedExternalEditorCloseRequestHandler = (
  externalEditorWindow,
  closeRequestHandler
) => {
  const surface = embeddedExternalEditorSurfaces.get(externalEditorWindow);
  if (!surface) return () => {};

  surface.closeRequestHandler = closeRequestHandler;
  if (surface.closeRequested) {
    surface.closeRequested = false;
    Promise.resolve().then(() => {
      if (
        embeddedExternalEditorSurfaces.get(externalEditorWindow) === surface &&
        surface.closeRequestHandler === closeRequestHandler
      ) {
        closeRequestHandler();
      }
    });
  }
  return () => {
    if (surface.closeRequestHandler === closeRequestHandler) {
      surface.closeRequestHandler = null;
    }
  };
};

/**
 * Closes an embedded editor surface. Returns false for a normal popup so the
 * caller can retain GDevelop's native Window.close() behavior.
 */
export const closePlaymeshEmbeddedExternalEditorWindow = externalEditorWindow => {
  const surface = embeddedExternalEditorSurfaces.get(externalEditorWindow);
  if (!surface) return false;

  embeddedExternalEditorSurfaces.delete(externalEditorWindow);
  surface.closeRequestHandler = null;
  for (const popupSurface of Array.from(embeddedPopupSurfaces)) {
    popupSurface.close();
  }
  dispatchWindowEvent(externalEditorWindow, 'unload');
  surface.overlay.remove();
  restoreFocus(surface.previouslyFocusedElement);
  return true;
};
