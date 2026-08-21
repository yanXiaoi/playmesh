(function (root) {
  'use strict';

  var api = root.PlaymeshExternalEditorI18n;
  if (!api) throw new Error('missing_playmesh_external_editor_i18n');

  var translator = api.createTranslator({
    editor: 'jfxr',
    explicitLocale: api.readExplicitLocale(root.location),
    supportedLocales: ['en', 'zh-CN'],
    defaultLocale: 'en',
    aliases: {
      zh_CN: 'zh-CN',
      'zh-Hans': 'zh-CN',
      'zh-Hans-CN': 'zh-CN',
      'zh-SG': 'zh-CN'
    }
  });

  var staticRootSelectors = [
    '.errorbar-warning',
    '.titlepane',
    '.playbackpane',
    '.filespane > .toolbar',
    '.filespane > .statusbar',
    '.parameters > .parameters-column > h2',
    '.statusbar-right'
  ];
  var dynamicRootSelectors = [
    '.playbackpane',
    '.presets',
    '.parameters',
    '.paramdescription',
    '.filespane > .statusbar'
  ];
  var neverTranslateSelectors = [
    '.history',
    '.soundname',
    'input[type="text"]',
    'input[type="range"]',
    'textarea',
    '[contenteditable="true"]'
  ];
  var translatedAttributes = ['title', 'placeholder', 'aria-label'];

  var matchesAny = function (element, selectors) {
    if (!element || element.nodeType !== 1) return false;
    return selectors.some(function (selector) {
      return element.matches(selector) || !!element.closest(selector);
    });
  };

  var isNeverTranslated = function (node) {
    var element = node && (node.nodeType === 1 ? node : node.parentElement);
    return matchesAny(element, neverTranslateSelectors);
  };

  var translateTextValue = function (source) {
    var translated = translator.translateSource(source);
    if (translated !== source) return translated;

    if (source.slice(-1) === '|') {
      var withoutSeparator = source.slice(0, -1).trim();
      var translatedWithoutSeparator = translator.translateSource(
        withoutSeparator
      );
      if (translatedWithoutSeparator !== withoutSeparator) {
        return translatedWithoutSeparator + ' |';
      }
    }

    if (source.slice(0, 2) === ': ') {
      var description = source.slice(2);
      var translatedDescription = translator.translateSource(description);
      if (translatedDescription !== description) {
        return ': ' + translatedDescription;
      }
    }

    var renderTimeMatch = source.match(/^Render time:\s*(.+?)\s*ms$/);
    if (renderTimeMatch) {
      return translator.t('status.renderTime', {
        value: renderTimeMatch[1]
      });
    }
    return source;
  };

  var translateTextNode = function (node) {
    if (!node || node.nodeType !== 3 || isNeverTranslated(node)) return;
    var source = node.nodeValue || '';
    var leading = source.match(/^\s*/)[0];
    var trailing = source.match(/\s*$/)[0];
    var body = source.slice(leading.length, source.length - trailing.length);
    if (!body) return;
    var translated = translateTextValue(body);
    if (translated !== body) node.nodeValue = leading + translated + trailing;
  };

  var translateAttributes = function (element) {
    if (!element || element.nodeType !== 1 || isNeverTranslated(element)) {
      return;
    }
    translatedAttributes.forEach(function (attribute) {
      if (!element.hasAttribute(attribute)) return;
      var source = element.getAttribute(attribute);
      var translated = translateTextValue(source);
      if (translated !== source) element.setAttribute(attribute, translated);
    });
  };

  var translateTree = function (node) {
    if (!node || isNeverTranslated(node)) return;
    var document = node.ownerDocument || node;
    if (node.nodeType === 3) {
      translateTextNode(node);
      return;
    }
    if (node.nodeType !== 1 && node.nodeType !== 9) return;
    if (node.nodeType === 1) translateAttributes(node);
    if (node.querySelectorAll) {
      Array.prototype.forEach.call(node.querySelectorAll('*'), function (
        element
      ) {
        translateAttributes(element);
      });
    }
    var nodeFilter = document.defaultView.NodeFilter;
    var walker = document.createTreeWalker(node, nodeFilter.SHOW_TEXT);
    while (walker.nextNode()) translateTextNode(walker.currentNode);
  };

  var translateSelectedRoots = function (document, selectors) {
    selectors.forEach(function (selector) {
      Array.prototype.forEach.call(
        document.querySelectorAll(selector),
        translateTree
      );
    });
  };

  var isInDynamicRoot = function (node) {
    var element = node && (node.nodeType === 1 ? node : node.parentElement);
    return matchesAny(element, dynamicRootSelectors);
  };

  var installDynamicObserver = function (document) {
    if (!document.body || !document.defaultView.MutationObserver) return null;
    var observer = new document.defaultView.MutationObserver(function (
      mutations
    ) {
      mutations.forEach(function (mutation) {
        if (mutation.type === 'characterData') {
          if (isInDynamicRoot(mutation.target)) translateTextNode(mutation.target);
          return;
        }
        if (mutation.type === 'attributes') {
          if (isInDynamicRoot(mutation.target)) {
            translateAttributes(mutation.target);
          }
          return;
        }
        Array.prototype.forEach.call(mutation.addedNodes, function (addedNode) {
          if (isInDynamicRoot(addedNode)) {
            translateTree(addedNode);
            return;
          }
          if (!addedNode.querySelectorAll) return;
          dynamicRootSelectors.forEach(function (selector) {
            Array.prototype.forEach.call(
              addedNode.querySelectorAll(selector),
              translateTree
            );
          });
        });
      });
    });
    observer.observe(document.body, {
      attributes: true,
      attributeFilter: translatedAttributes,
      characterData: true,
      childList: true,
      subtree: true
    });
    return observer;
  };

  var translateEditorDocument = function (document) {
    document.documentElement.setAttribute('lang', translator.locale);
    translateSelectedRoots(document, staticRootSelectors);
    translateSelectedRoots(document, dynamicRootSelectors);
  };

  var translateWrapperDocument = function (document) {
    document.documentElement.setAttribute('lang', translator.locale);
    var header = document.getElementById('external-editor-header');
    if (header) translateTree(header);
  };

  translateEditorDocument(root.document);
  var observer = installDynamicObserver(root.document);

  root.PlaymeshJfxrI18n = Object.freeze({
    locale: translator.locale,
    t: translator.t,
    translateEditorDocument: translateEditorDocument,
    translateWrapperDocument: translateWrapperDocument,
    disconnect: function () {
      if (observer) observer.disconnect();
    },
    selectors: Object.freeze({
      staticRoots: Object.freeze(staticRootSelectors.slice()),
      dynamicRoots: Object.freeze(dynamicRootSelectors.slice()),
      neverTranslate: Object.freeze(neverTranslateSelectors.slice())
    })
  });
})(typeof globalThis === 'object' ? globalThis : window);
