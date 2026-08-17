(function installPlaymeshGDevelopPolicy() {
  'use strict';

  if (globalThis.__PLAYMESH_GDEVELOP_POLICY__) return;

  const blockedHostSuffixes = [
    'gdevelop.io',
    'gdevelop-app.com',
    'gd.games',
    'liluo.io',
    'gdevelop-services.firebaseapp.com',
    'gdevelop-services.firebaseio.com',
    'gdevelop-services.appspot.com',
  ];

  const isBlockedUrl = value => {
    try {
      const url = new URL(String(value), globalThis.location.href);
      const hostname = url.hostname.toLowerCase();
      return blockedHostSuffixes.some(
        suffix => hostname === suffix || hostname.endsWith(`.${suffix}`)
      );
    } catch (_) {
      return false;
    }
  };

  const blockedError = value =>
    new DOMException(
      `Playmesh disabled the GDevelop online service: ${String(value)}`,
      'SecurityError'
    );

  const nativeFetch = globalThis.fetch && globalThis.fetch.bind(globalThis);
  if (nativeFetch) {
    globalThis.fetch = (input, init) => {
      const value = input && input.url ? input.url : input;
      if (isBlockedUrl(value)) return Promise.reject(blockedError(value));
      return nativeFetch(input, init);
    };
  }

  const NativeXMLHttpRequest = globalThis.XMLHttpRequest;
  if (NativeXMLHttpRequest) {
    const nativeOpen = NativeXMLHttpRequest.prototype.open;
    NativeXMLHttpRequest.prototype.open = function playmeshOpen(
      method,
      url,
      ...rest
    ) {
      if (isBlockedUrl(url)) throw blockedError(url);
      return nativeOpen.call(this, method, url, ...rest);
    };
  }

  const NativeWebSocket = globalThis.WebSocket;
  if (NativeWebSocket) {
    globalThis.WebSocket = class PlaymeshPolicyWebSocket extends NativeWebSocket {
      constructor(url, protocols) {
        if (isBlockedUrl(url)) throw blockedError(url);
        super(url, protocols);
      }
    };
  }

  const hiddenSelectors = [
    '#home-shop-tab',
    '#home-play-tab',
    '#team-view-tab',
  ];
  const hideDisabledEntries = () => {
    for (const selector of hiddenSelectors) {
      for (const element of document.querySelectorAll(selector)) {
        element.setAttribute('hidden', '');
        element.setAttribute('aria-hidden', 'true');
      }
    }
  };

  if (document.documentElement) {
    new MutationObserver(hideDisabledEntries).observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
    hideDisabledEntries();
  }

  Object.defineProperty(globalThis, '__PLAYMESH_GDEVELOP_POLICY__', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: Object.freeze({
      version: 1,
      blockedHostSuffixes: Object.freeze([...blockedHostSuffixes]),
      isBlockedUrl,
    }),
  });
})();

