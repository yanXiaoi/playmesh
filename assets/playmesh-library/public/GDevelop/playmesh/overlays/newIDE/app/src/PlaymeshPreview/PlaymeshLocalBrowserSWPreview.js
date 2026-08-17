// @flow

import { ensureBrowserSWPreviewSession } from '../ExportAndShare/BrowserExporters/BrowserSWPreviewLauncher/BrowserSWPreviewIndexedDB';

const LOCAL_PREVIEW_UNAVAILABLE =
  '此环境不支持 GDevelop 本地游戏内编辑器预览。不会回退到云端预览。';

const normalizeDirectoryUrl = (value /*: string */) /*: string */ => {
  const url = new URL('.', value);
  return url.href.endsWith('/') ? url.href : `${url.href}/`;
};

export const initializePlaymeshLocalBrowserSWPreview = async ({
  serviceWorker,
  indexedDbAvailable,
  documentBaseUri,
  ensurePreviewSession,
} /*: {|
  serviceWorker: ?ServiceWorkerContainer,
  indexedDbAvailable: boolean,
  documentBaseUri: string,
  ensurePreviewSession: () => Promise<void>,
|} */) /*: Promise<void> */ => {
  if (!serviceWorker || !indexedDbAvailable) {
    throw new Error(LOCAL_PREVIEW_UNAVAILABLE);
  }

  const baseUrl = normalizeDirectoryUrl(documentBaseUri);
  const serviceWorkerUrl = new URL('service-worker.js', baseUrl).href;
  let registration;
  try {
    registration = await serviceWorker.register(serviceWorkerUrl);
    const readyRegistration = await serviceWorker.ready;
    if (
      !registration ||
      !readyRegistration ||
      !readyRegistration.active ||
      normalizeDirectoryUrl(readyRegistration.scope) !== baseUrl
    ) {
      throw new Error('本地预览 Service Worker 未在当前 WebIDE 路径激活。');
    }
    await ensurePreviewSession();
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    throw new Error(`${LOCAL_PREVIEW_UNAVAILABLE} ${reason}`);
  }
};

let initializationPromise /*: ?Promise<void> */ = null;

export const ensurePlaymeshLocalBrowserSWPreview = () /*: Promise<void> */ => {
  if (initializationPromise) return initializationPromise;

  const serviceWorker =
    typeof navigator !== 'undefined' ? navigator.serviceWorker : null;
  const documentBaseUri =
    typeof document !== 'undefined' && document.baseURI
      ? document.baseURI
      : typeof window !== 'undefined'
      ? window.location.href
      : '';
  initializationPromise = initializePlaymeshLocalBrowserSWPreview({
    serviceWorker,
    indexedDbAvailable:
      typeof window !== 'undefined' && !!window.indexedDB,
    documentBaseUri,
    ensurePreviewSession: ensureBrowserSWPreviewSession,
  }).catch(error => {
    initializationPromise = null;
    throw error;
  });
  return initializationPromise;
};
