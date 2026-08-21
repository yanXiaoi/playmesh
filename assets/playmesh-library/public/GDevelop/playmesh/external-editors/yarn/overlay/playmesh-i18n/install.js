(function (root) {
  'use strict';

  var api = root.PlaymeshExternalEditorI18n;
  if (!api) throw new Error('missing_playmesh_external_editor_i18n');

  var translator = api.createTranslator({
    editor: 'yarn',
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
    '.app-search > form.menu',
    '.app-menu',
    '.app-sort',
    '.app-zoom',
    '.app-undo-redo',
    '.app-add-node',
    '#node-editor .bbcode-toolbar',
    '#node-editor .add-link > .menu > #add-link-title',
    '#node-editor .add-link > .menu > #linkHelperMenuFilter',
    '#node-editor .editor-counter',
    '#node-editor .toggle-toolbar',
    '#settings-dialog .settings-form',
    '#addPwa'
  ];
  var dynamicRootSelectors = [
    '.app-search',
    '#settings-dialog .settings-form',
    '.swal2-title',
    '.swal2-html-container',
    '.swal2-actions'
  ];
  var neverTranslateSelectors = [
    '.nodes',
    '.node',
    '#editorTitle',
    '#editorTags',
    '#node-editor .editor-container',
    '#node-editor .editor-play',
    '#node-editor .editor-preview',
    '.story-playtest-bubble',
    '.story-playtest-answer',
    '#commandDebugLabel',
    '.file-name',
    '#language',
    '.add-link .dropdown',
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

    var closeUnsavedMatch = source.match(
      /^Are you sure you want to close\s*\n([\s\S]*?)\nAny unsaved progress will be lost\.\.\.$/
    );
    if (closeUnsavedMatch) {
      return translator.t('dialog.closeUnsaved', {
        name: closeUnsavedMatch[1]
      });
    }
    var closeMatch = source.match(
      /^Are you sure you want to close\s+([\s\S]+?)\s*$/
    );
    if (closeMatch) {
      return translator.t('dialog.closeNamed', { name: closeMatch[1] });
    }
    var saveErrorMatch = source.match(/^Error Saving Data to\s+([\s\S]+)$/);
    if (saveErrorMatch) {
      return translator.t('dialog.saveError', { target: saveErrorMatch[1] });
    }
    var openFolderMatch = source.match(
      /^openFolder not yet implemented e: ([\s\S]*?) foldername: ([\s\S]*)$/
    );
    if (openFolderMatch) {
      return translator.t('dialog.openFolderUnavailable', {
        error: openFolderMatch[1],
        folder: openFolderMatch[2]
      });
    }
    return source;
  };

  var installDialogAdapters = function () {
    if (root.__playmeshYarnDialogI18nInstalled) return function () {};
    var nativeAlert =
      typeof root.alert === 'function' ? root.alert.bind(root) : null;
    var nativeConfirm =
      typeof root.confirm === 'function' ? root.confirm.bind(root) : null;
    var localizedAlert = nativeAlert
      ? function (message) {
          return nativeAlert(translateTextValue(String(message)));
        }
      : null;
    var localizedConfirm = nativeConfirm
      ? function (message) {
          return nativeConfirm(translateTextValue(String(message)));
        }
      : null;
    if (localizedAlert) root.alert = localizedAlert;
    if (localizedConfirm) root.confirm = localizedConfirm;
    root.__playmeshYarnDialogI18nInstalled = true;
    return function () {
      if (localizedAlert && root.alert === localizedAlert) {
        root.alert = nativeAlert;
      }
      if (localizedConfirm && root.confirm === localizedConfirm) {
        root.confirm = nativeConfirm;
      }
      root.__playmeshYarnDialogI18nInstalled = false;
    };
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

  var syncSpellcheckAvailability = function (document) {
    var language = document.getElementById('language');
    if (!language) return;
    var languageId = String(language.value || '').replace(/_/g, '-');
    var hasLocalDictionary =
      languageId.split('-')[0].toLowerCase() === 'en';
    ['spellcheck', 'toglSpellCheck'].forEach(function (id) {
      var control = document.getElementById(id);
      if (!control) return;
      var shouldBeDisabled = !hasLocalDictionary;
      if (control.disabled !== shouldBeDisabled) {
        control.disabled = shouldBeDisabled;
      }
      var availability = hasLocalDictionary ? 'true' : 'false';
      if (
        control.getAttribute('data-playmesh-local-dictionary-available') !==
        availability
      ) {
        control.setAttribute(
          'data-playmesh-local-dictionary-available',
          availability
        );
      }
      var title = hasLocalDictionary
        ? translator.t('title.spellcheck')
        : translator.t('settings.spellcheckUnavailable');
      if (control.getAttribute('title') !== title) {
        control.setAttribute('title', title);
      }
    });
    if (!language.__playmeshSpellcheckListenerInstalled) {
      language.__playmeshSpellcheckListenerInstalled = true;
      language.addEventListener('change', function () {
        syncSpellcheckAvailability(document);
      });
    }
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
      syncSpellcheckAvailability(document);
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
    syncSpellcheckAvailability(document);
  };

  var translateWrapperDocument = function (document) {
    document.documentElement.setAttribute('lang', translator.locale);
    var header = document.getElementById('external-editor-header');
    if (header) translateTree(header);
  };

  translateEditorDocument(root.document);
  var restoreDialogAdapters = installDialogAdapters();
  var observer = installDynamicObserver(root.document);
  root.addEventListener(
    'DOMContentLoaded',
    function () {
      translateEditorDocument(root.document);
    },
    { once: true }
  );

  root.PlaymeshYarnI18n = Object.freeze({
    locale: translator.locale,
    t: translator.t,
    translateEditorDocument: translateEditorDocument,
    translateWrapperDocument: translateWrapperDocument,
    syncSpellcheckAvailability: syncSpellcheckAvailability,
    disconnect: function () {
      if (observer) observer.disconnect();
      restoreDialogAdapters();
    },
    selectors: Object.freeze({
      staticRoots: Object.freeze(staticRootSelectors.slice()),
      dynamicRoots: Object.freeze(dynamicRootSelectors.slice()),
      neverTranslate: Object.freeze(neverTranslateSelectors.slice())
    })
  });
})(typeof globalThis === 'object' ? globalThis : window);
