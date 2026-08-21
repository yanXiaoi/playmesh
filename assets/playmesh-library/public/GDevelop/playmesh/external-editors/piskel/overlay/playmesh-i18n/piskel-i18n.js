(function (root) {
  'use strict';

  var shared = root.PlaymeshExternalEditorI18n;
  if (!shared) throw new Error('missing_playmesh_external_editor_i18n');
  if (root.PlaymeshPiskelI18n) return;

  var translator = shared.createTranslator({
    editor: 'piskel',
    explicitLocale: shared.readExplicitLocale(root.location),
    supportedLocales: ['en', 'zh-CN'],
    defaultLocale: 'en',
    aliases: {
      zh: 'zh-CN',
      'zh-Hans': 'zh-CN',
      'zh-Hans-CN': 'zh-CN',
    },
  });

  var t = translator.t;
  var rule = function (selector, target, key) {
    return { selector: selector, target: target, key: key };
  };

  var visibleRules = [
    rule('.pen-size-container', 'title', 'toolbar.penSize'),
    rule('.palette-wrapper .tool-color-picker:nth-of-type(1)', 'data-initial-title', 'toolbar.primaryColor'),
    rule('.palette-wrapper .tool-color-picker:nth-of-type(2)', 'data-initial-title', 'toolbar.secondaryColor'),
    rule('.swap-colors-button', 'title', 'toolbar.swapColors'),
    rule('.full-size-button', 'text', 'preview.full'),
    rule('.toggle-grid-button', 'title', 'preview.toggleGrid'),
    rule('.open-popup-preview-button', 'title', 'preview.openPopup'),
    rule('.layers-title', 'directText', 'panel.layers'),
    rule('.layers-button[data-action="up"]', 'title', 'layers.moveUp'),
    rule('.layers-button[data-action="down"]', 'title', 'layers.moveDown'),
    rule('.layers-button[data-action="edit"]', 'title', 'layers.editName'),
    rule('.layers-button[data-action="merge"]', 'title', 'layers.mergeDown'),
    rule('.layers-button[data-action="delete"]', 'title', 'layers.delete'),
    rule('.transformations-title', 'directText', 'panel.transform'),
    rule('.transformations-show-more-link', 'title', 'transform.moreTools'),
    rule('.palettes-title', 'text', 'panel.palettes'),
    rule('.create-palette-button', 'title', 'palette.create'),
    rule('.edit-palette-button', 'title', 'palette.manage'),
    rule('[data-setting="user"]', 'title', 'settings.preferencesTooltip'),
    rule('[data-setting="resize"]', 'title', 'settings.resizeTooltip'),
    rule('[data-setting="save"]', 'title', 'settings.saveTooltip'),
    rule('[data-setting="export"]', 'title', 'settings.exportTooltip'),
    rule('[data-setting="import"]', 'title', 'settings.importTooltip'),
    rule('.cheatsheet-link', 'title', 'cheatsheet.title'),
    rule('.performance-link', 'title', 'performance.detected'),
  ];

  var commonBackNextRules = [
    rule('.import-back-button', 'text', 'common.back'),
    rule('.import-next-button', 'text', 'common.next'),
  ];

  var templateRules = {
    'palettes-list-no-colors-partial': [
      rule('.palettes-list-no-colors', 'text', 'palette.noColors'),
    ],
    'templates/dialogs/browse-backups.html': [
      rule('.dialog-head', 'directText', 'backups.title'),
    ],
    'backups-select-session': [
      rule('.browse-backups-disclaimer-content', 'html', 'backups.disclaimer'),
    ],
    'session-list-empty': [
      rule('.session-list-empty', 'text', 'backups.noSession'),
    ],
    'session-list-error': [
      rule('.session-list-error', 'text', 'backups.sessionError'),
    ],
    'session-list-item': [
      rule('.session-details-info:nth-of-type(2)', 'text', 'backups.sessionRecorded'),
      rule('.session-details-info:nth-of-type(3)', 'text', 'backups.savedCount'),
      rule('[data-action="delete"]', 'text', 'common.delete'),
      rule('[data-action="view"]', 'text', 'common.view'),
    ],
    'backups-session-details': [
      rule('.back-button', 'text', 'common.back'),
    ],
    'snapshot-list-empty': [
      rule('.snapshot-list-empty', 'text', 'backups.noSnapshot'),
    ],
    'snapshot-list-error': [
      rule('.snapshot-list-error', 'text', 'backups.snapshotError'),
    ],
    'snapshot-list-item': [
      rule('.snapshot-details-info:nth-of-type(2)', 'text', 'backups.snapshotRecorded'),
      rule('.snapshot-details-info:nth-of-type(3)', 'text', 'backups.snapshotInfo'),
      rule('[data-action="load"]', 'text', 'common.load'),
    ],
    'templates/dialogs/browse-local.html': [
      rule('.dialog-head', 'directText', 'local.title'),
      rule('.local-piskel-list-head .local-piskel-name', 'text', 'common.name'),
      rule('.local-piskel-list-head .local-piskel-save-date', 'text', 'common.date'),
      rule('.local-piskel-list-head td:nth-child(3)', 'text', 'common.actions'),
    ],
    'local-storage-item-template': [
      rule('.local-piskel-load-button', 'text', 'common.load'),
      rule('.local-piskel-delete-button', 'text', 'common.delete'),
    ],
    'templates/dialogs/cheatsheet.html': [
      rule('.dialog-title', 'text', 'cheatsheet.title'),
      rule('.cheatsheet-tool-shortcuts', 'previousTitle', 'cheatsheet.tools'),
      rule('.cheatsheet-misc-shortcuts', 'previousTitle', 'cheatsheet.misc'),
      rule('.cheatsheet-selection-shortcuts', 'previousTitle', 'cheatsheet.selection'),
      rule('.cheatsheet-color-shortcuts', 'previousTitle', 'cheatsheet.color'),
      rule('.cheatsheet-storage-shortcuts', 'previousTitle', 'cheatsheet.storage'),
      rule('.cheatsheet-helptext b', 'text', 'cheatsheet.customize'),
      rule('.cheatsheet-restore-defaults', 'text', 'cheatsheet.restore'),
    ],
    'templates/dialogs/create-palette.html': [
      rule('.dialog-title', 'text', 'palette.createTitle'),
      rule('.create-palette-name-label', 'text', 'common.name'),
      rule('.create-palette-name-input', 'placeholder', 'palette.namePlaceholder'),
      rule('.create-palette-import-button', 'text', 'palette.importFile'),
      rule('.create-palette-import-button', 'title', 'palette.importFileTooltip'),
      rule('.create-palette-download-button', 'text', 'palette.downloadFile'),
      rule('.create-palette-download-button', 'title', 'palette.downloadFileTooltip'),
      rule('.create-palette-cancel', 'text', 'common.cancel'),
      rule('.create-palette-delete', 'text', 'common.delete'),
      rule('.create-palette-submit', 'text', 'common.save'),
    ],
    'templates/dialogs/import.html': [
      rule('.dialog-head', 'directText', 'import.title'),
    ],
    'import-image-import': commonBackNextRules.concat([
      rule('.import-section:first-child .dialog-section-title', 'text', 'common.nameColon'),
      rule('input[value="single"]', 'parentDirectText', 'import.singleImage'),
      rule('input[name="resize-width"]', 'previousText', 'import.resizeTo'),
      rule('.import-section-title', 'text', 'import.smoothResize'),
      rule('input[value="sheet"]', 'parentDirectText', 'import.spritesheet'),
      rule('input[name="frame-size-x"]', 'previousText', 'import.frameSize'),
      rule('input[name="frame-offset-x"]', 'previousText', 'import.offset'),
    ]),
    'import-select-mode': commonBackNextRules.concat([
      rule('.import-mode-title', 'text', 'import.modeQuestion'),
      rule('.import-mode-section:first-of-type .import-mode-section-description', 'text', 'import.combineDescription'),
      rule('.import-mode-merge-button', 'text', 'import.combine'),
      rule('.import-mode-section:nth-of-type(2) .import-mode-section-description', 'text', 'import.replaceDescription'),
      rule('.import-mode-replace-button', 'text', 'import.replace'),
    ]),
    'import-meta-content': [
      rule('.import-name .import-meta-label', 'text', 'common.name'),
      rule('.import-dimensions .import-meta-label', 'text', 'import.dimensions'),
      rule('.import-frames .import-meta-label', 'text', 'import.frames'),
      rule('.import-layers .import-meta-label', 'text', 'panel.layers'),
    ],
    'import-adjust-size': commonBackNextRules,
    'import-resize-bigger-partial': [
      rule('.import-resize-section:first-child', 'text', 'import.imageBigger'),
      rule('#resize-option-expand', 'parentDirectText', 'import.expandCanvas'),
      rule('#resize-option-keep', 'parentDirectText', 'import.keepCanvas'),
    ],
    'import-resize-smaller-partial': [
      rule('.import-resize-section', 'text', 'import.imageSmaller'),
    ],
    'import-insert-location': [
      rule('.import-step-content > div:first-child', 'text', 'import.selectInsertionFrame'),
      rule('.insert-mode-option-label', 'text', 'import.insertFrames'),
      rule('#insert-mode-add', 'parentDirectText', 'import.asNewFrames'),
      rule('#insert-mode-insert', 'parentDirectText', 'import.inExistingFrames'),
      rule('.import-back-button', 'text', 'common.back'),
      rule('.import-next-button', 'text', 'common.import'),
    ],
    'templates/dialogs/performance-info.html': [
      rule('.dialog-head', 'directText', 'performance.title'),
      rule('.dialog-performance-info-body', 'html', 'performance.body'),
    ],
    'templates/dialogs/unsupported-browser.html': [
      rule('.dialog-head', 'directText', 'unsupported.title'),
      rule('.dialog-content > p:first-child', 'html', 'unsupported.currentBrowser'),
      rule('.dialog-content > p:nth-of-type(2)', 'text', 'unsupported.testedFor'),
      rule('.dialog-content > p:last-child', 'text', 'unsupported.warning'),
    ],
    'templates/settings/preferences.html': [
      rule('.settings-title', 'text', 'preferences.title'),
      rule('[data-tab-id="misc"]', 'text', 'preferences.misc'),
      rule('[data-tab-id="grid"]', 'text', 'preferences.grid'),
      rule('[data-tab-id="tile"]', 'text', 'preferences.tileMode'),
      rule('.settings-version-info span', 'title', 'preferences.releaseNotes'),
    ],
    'templates/settings/preferences/grid.html': [
      rule('.settings-item:first-child label', 'directText', 'preferences.enableGrid'),
      rule('.settings-item-grid-size label', 'text', 'preferences.gridSize'),
      rule('.settings-item-grid-spacing label', 'text', 'preferences.gridSpacing'),
      rule('.settings-item-grid-color label', 'text', 'preferences.gridColor'),
    ],
    'templates/settings/preferences/misc.html': [
      rule('.settings-item:nth-child(1) label', 'text', 'preferences.background'),
      rule('.light-picker-background', 'title', 'preferences.lightHighContrast'),
      rule('.medium-picker-background', 'title', 'preferences.mediumHighContrast'),
      rule('.lowcont-medium-picker-background', 'title', 'preferences.mediumLowContrast'),
      rule('.lowcont-dark-picker-background', 'title', 'preferences.darkLowContrast'),
      rule('.settings-item:nth-child(2) label', 'text', 'preferences.layerOpacity'),
      rule('.settings-item:nth-child(3) label', 'text', 'preferences.maximumFps'),
      rule('.settings-item:nth-child(4) label', 'text', 'preferences.colorFormat'),
    ],
    'templates/settings/preferences/tile.html': [
      rule('.settings-item:first-child label', 'directText', 'preferences.enableTileMode'),
      rule('.settings-item:nth-child(2) label', 'text', 'preferences.maskOpacity'),
    ],
    'templates/settings/resize.html': [
      rule('.settings-title:first-child', 'text', 'resize.title'),
      rule('input[name="resize-width"]', 'previousText', 'common.width'),
      rule('input[name="resize-height"]', 'previousText', 'common.height'),
      rule('.resize-ratio-checkbox', 'parentDirectText', 'resize.maintainRatio'),
      rule('.resize-content-checkbox', 'parentDirectText', 'resize.resizeContent'),
      rule('.resize-anchor-container', 'previousText', 'resize.anchor'),
      rule('.resize-button', 'value', 'resize.title'),
      rule('.settings-section-resize > .settings-title:nth-child(3)', 'text', 'resize.defaultSize'),
      rule('input[name="default-width"]', 'previousText', 'common.width'),
      rule('input[name="default-height"]', 'previousText', 'common.height'),
      rule('.default-size-button', 'value', 'resize.setDefault'),
    ],
    'templates/settings/save.html': [
      rule('.settings-title', 'text', 'save.spriteInformation'),
      rule('label[for="save-name"]', 'text', 'common.titleColon'),
      rule('.settings-form-section:nth-child(1) label', 'text', 'common.titleColon'),
      rule('.settings-form-section:nth-child(2) label', 'text', 'common.descriptionColon'),
      rule('.save-public-section label', 'directText', 'save.public'),
    ],
    'save-localstorage-partial': [
      rule('.settings-title', 'text', 'save.browserTitle'),
      rule('#save-localstorage-button', 'value', 'save.browserButton'),
      rule('.save-status', 'text', 'save.browserStatus'),
    ],
    'save-desktop-partial': [
      rule('.settings-title', 'text', 'save.fileTitle'),
      rule('#save-desktop-button', 'value', 'common.save'),
      rule('#save-desktop-as-new-button', 'value', 'save.asNew'),
      rule('.save-status', 'text', 'save.fileStatus'),
    ],
    'save-file-download-partial': [
      rule('.settings-title', 'text', 'save.offlineFileTitle'),
      rule('#save-file-download-button', 'value', 'save.piskelButton'),
      rule('.save-status', 'text', 'save.downloadStatus'),
    ],
    'templates/settings/import.html': [
      rule('.settings-section-import > .settings-title:nth-child(1)', 'text', 'settingsImport.browserTitle'),
      rule('.settings-section-import > .settings-item:nth-child(2) > span', 'html', 'settingsImport.browserDescription'),
      rule('.browse-local-button', 'text', 'settingsImport.browseLocal'),
      rule('.settings-section-import > .settings-title:nth-child(3)', 'text', 'settingsImport.piskelTitle'),
      rule('.settings-section-import > .settings-item:nth-child(4) > span', 'html', 'settingsImport.piskelDescription'),
      rule('.open-piskel-button', 'text', 'settingsImport.browsePiskel'),
      rule('.settings-section-import > .settings-title:nth-child(5)', 'text', 'settingsImport.pictureTitle'),
      rule('.settings-section-import > .settings-item:nth-child(6) > div:first-child', 'html', 'settingsImport.pictureFormats'),
      rule('.file-input-button', 'text', 'settingsImport.browseImages'),
      rule('.settings-section-import > .settings-title:nth-child(7)', 'text', 'settingsImport.recoverTitle'),
      rule('.settings-section-import > .settings-item:nth-child(8)', 'directText', 'settingsImport.recoverDescription'),
      rule('.browse-backups-button', 'text', 'backups.title'),
    ],
    'templates/settings/export.html': [
      rule('.settings-title', 'text', 'export.title'),
      rule('.export-scale', 'title', 'export.scaleTooltip'),
      rule('label[for="scale-input"]', 'text', 'export.scale'),
      rule('.resize-label:first-of-type', 'text', 'common.resolution'),
      rule('[data-tab-id="misc"]', 'text', 'export.others'),
    ],
    'templates/settings/export/png.html': [
      rule('.export-panel-header', 'text', 'export.pngDescription'),
      rule('.png-export-layout-section .highlight', 'text', 'export.layoutOptions'),
      rule('label[for="png-export-columns"]', 'text', 'export.columns'),
      rule('#png-export-columns', 'previousText', 'export.columns'),
      rule('#png-export-rows', 'previousText', 'export.rows'),
      rule('.export-panel-section:nth-of-type(3) .highlight', 'text', 'export.spritesheetFile'),
      rule('.png-download-button', 'text', 'common.download'),
      rule('.export-panel-section:nth-of-type(4) .highlight', 'text', 'export.dataUri'),
      rule('.datauri-open-button', 'text', 'common.open'),
      rule('.export-panel-section:nth-of-type(4) .export-info', 'text', 'export.dataUriDescription'),
      rule('.export-panel-section:nth-of-type(5) .highlight', 'text', 'export.pixi'),
      rule('label[for="png-pixi-inline-image"]', 'text', 'export.inlineDataUri'),
      rule('.png-pixi-download-button', 'text', 'common.download'),
      rule('.export-panel-section:nth-of-type(5) .export-info', 'text', 'export.pixiDescription'),
      rule('.export-panel-section:nth-of-type(6) .highlight', 'text', 'export.selectedFrame'),
      rule('.selected-frame-download-button', 'text', 'common.download'),
      rule('.export-panel-section:nth-of-type(6) .export-info', 'text', 'export.selectedFrameDescription'),
    ],
    'templates/settings/export/gif.html': [
      rule('.export-panel-header', 'text', 'export.gifDescription'),
      rule('.gif-export-warning-message', 'text', 'export.gifColorWarning'),
      rule('label[for="gif-repeat-checkbox"]', 'text', 'export.loop'),
      rule('label[for="gif-repeat-checkbox"]', 'title', 'export.loopTooltip'),
      rule('.gif-download-button', 'text', 'common.download'),
      rule('.gif-download-button + .export-info', 'text', 'export.gifDownloadDescription'),
    ],
    'templates/settings/export/zip.html': [
      rule('.export-panel-header', 'text', 'export.zipDescription'),
      rule('label[for="zip-prefix-name"]', 'text', 'common.prefix'),
      rule('.zip-prefix-name', 'previousText', 'common.prefix'),
      rule('.zip-prefix-name', 'placeholder', 'export.prefixPlaceholder'),
      rule('label[for="zip-split-layers"]', 'text', 'export.splitLayers'),
      rule('label[for="zip-use-layer-names"]', 'text', 'export.layerNames'),
      rule('.zip-generate-button', 'text', 'export.downloadZip'),
    ],
    'templates/settings/export/misc.html': [
      rule('.export-panel-header', 'text', 'export.miscDescription'),
      rule('.highlight', 'text', 'export.cFile'),
      rule('.export-info', 'text', 'export.cFileDescription'),
      rule('.c-download-button', 'text', 'export.downloadC'),
    ],
  };

  var replaceDirectText = function (element, value) {
    for (var index = 0; index < element.childNodes.length; index += 1) {
      var node = element.childNodes[index];
      if (node.nodeType === 3 && node.nodeValue.trim()) {
        node.nodeValue = node.nodeValue.replace(node.nodeValue.trim(), value);
        return;
      }
    }
  };

  var applyRule = function (container, currentRule) {
    var elements = container.querySelectorAll(currentRule.selector);
    Array.prototype.forEach.call(elements, function (element) {
      var value = t(currentRule.key);
      if (currentRule.target === 'text') element.textContent = value;
      else if (currentRule.target === 'html') element.innerHTML = value;
      else if (currentRule.target === 'directText') replaceDirectText(element, value);
      else if (currentRule.target === 'parentDirectText') replaceDirectText(element.parentElement, value);
      else if (currentRule.target === 'previousText' && element.previousElementSibling) {
        element.previousElementSibling.textContent = value;
      } else if (currentRule.target === 'previousTitle' && element.previousElementSibling) {
        element.previousElementSibling.textContent = value;
      } else {
        element.setAttribute(currentRule.target, value);
      }
    });
  };

  var applyRules = function (container, rules) {
    (rules || []).forEach(function (currentRule) {
      applyRule(container, currentRule);
    });
  };

  var translateTemplate = function (templateId, markup) {
    var rules = templateRules[templateId];
    if (!rules || typeof markup !== 'string') return markup;
    var container = root.document.createElement('div');
    container.innerHTML = markup;
    applyRules(container, rules);
    return container.innerHTML;
  };

  var runtimePatterns = [
    [/^Are you sure you want to delete palette (.*)$/, 'confirm.deletePalette', ['name']],
    [/^There is already a piskel saved as (.*)\. Overwrite \?$/, 'confirm.overwriteNamed', ['name']],
    [/^Palette (.*) successfully saved !$/, 'notification.paletteSaved', ['name']],
    [/^Key cannot be remapped \((.*)\)$/, 'notification.keyCannotRemap', ['key']],
    [/^Shortcut key removed for (.*)$/, 'notification.shortcutRemoved', ['id']],
    [/^Piskel file import failed \((.*)\)$/, 'notification.piskelImportFailed', ['reason']],
    [/^Could not import palette : (.*)$/, 'notification.paletteImportFailed', ['reason']],
    [/^Saving failed : (.*)$/, 'notification.saveFailedReason', ['reason']],
    [/^<div class="import-resize-warning">\s*Imported content will be cropped!<\/div>Select crop anchor:$/, 'import.croppedAnchor', []],
  ];

  var translateKnownRuntimeMessage = function (message) {
    if (typeof message !== 'string') return message;
    var translated = translator.translateSource(message);
    if (translated !== message) return translated;
    for (var index = 0; index < runtimePatterns.length; index += 1) {
      var match = message.match(runtimePatterns[index][0]);
      if (!match) continue;
      var values = {};
      runtimePatterns[index][2].forEach(function (name, valueIndex) {
        values[name] = match[valueIndex + 1];
      });
      return t(runtimePatterns[index][1], values);
    }
    return message;
  };

  var translateDescriptors = function (descriptors) {
    return (descriptors || []).map(function (descriptor) {
      var translated = {};
      Object.keys(descriptor).forEach(function (key) {
        translated[key] = descriptor[key];
      });
      if (typeof translated.description === 'string') {
        translated.description = translateKnownRuntimeMessage(translated.description);
      }
      return translated;
    });
  };

  var wrapMethod = function (owner, methodName, wrapper) {
    if (!owner || typeof owner[methodName] !== 'function') return;
    var original = owner[methodName];
    owner[methodName] = wrapper(original);
  };

  var installNativeDialogTranslation = function () {
    ['alert', 'confirm', 'prompt'].forEach(function (methodName) {
      if (typeof root[methodName] !== 'function') return;
      var original = root[methodName].bind(root);
      root[methodName] = function (message) {
        var args = Array.prototype.slice.call(arguments);
        args[0] = translateKnownRuntimeMessage(message);
        return original.apply(root, args);
      };
    });
  };

  var installPiskelRuntimeTranslation = function (pskl) {
    var originalTemplateGet = pskl.utils.Template.get;
    pskl.utils.Template.get = function (templateId) {
      return translateTemplate(templateId, originalTemplateGet.apply(this, arguments));
    };

    wrapMethod(pskl.utils.TooltipFormatter, 'format', function (original) {
      return function (helpText, shortcut, descriptors) {
        return original.call(
          this,
          translateKnownRuntimeMessage(helpText),
          shortcut,
          translateDescriptors(descriptors)
        );
      };
    });

    wrapMethod(pskl.service.keyboard.Shortcut.prototype, 'getDescription', function (original) {
      return function () {
        var key = 'shortcut.' + this.getId();
        return translator.has(key) ? t(key) : original.call(this);
      };
    });

    wrapMethod(pskl.tools.ToolIconBuilder.prototype, 'getTooltipText', function (original) {
      return function (tool) {
        var key =
          tool.toolId === 'tool-colorswap' &&
          tool.getHelpText() ===
            "Apply the currently selected palette's colors to a frame via their index numbers"
            ? 'tool.transform-palette-apply'
            : 'tool.' + tool.toolId;
        if (!translator.has(key)) return original.call(this, tool);
        return pskl.utils.TooltipFormatter.format(
          t(key),
          tool.shortcut,
          translateDescriptors(tool.tooltipDescriptors)
        );
      };
    });

    wrapMethod(pskl.controller.dialogs.AbstractDialogController.prototype, 'setTitle', function (original) {
      return function (title) {
        return original.call(this, translateKnownRuntimeMessage(title));
      };
    });

    wrapMethod(pskl.controller.NotificationController.prototype, 'displayMessage_', function (original) {
      return function (event, messageInfo) {
        var translatedInfo = {};
        Object.keys(messageInfo || {}).forEach(function (key) {
          translatedInfo[key] = messageInfo[key];
        });
        translatedInfo.content = translateKnownRuntimeMessage(translatedInfo.content);
        return original.call(this, event, translatedInfo);
      };
    });

    var cheatsheet = pskl.controller.dialogs.CheatsheetController;
    if (cheatsheet) {
      cheatsheet.prototype.getHelptextTitle_ = function () {
        return t('cheatsheet.helpTooltip');
      };
    }

    var beforeUnload = pskl.service.BeforeUnloadService;
    if (beforeUnload) {
      wrapMethod(beforeUnload.prototype, 'onBeforeUnload', function (original) {
        return function (event) {
          var result = original.call(this, event);
          var translated = translateKnownRuntimeMessage(result);
          if (event && translated) event.returnValue = translated;
          return translated;
        };
      });
    }

    if (root.Constants && translator.has('confirm.replaceAnimation')) {
      root.Constants.CONFIRM_OVERWRITE = t('confirm.replaceAnimation');
    }
  };

  var applyBoundedDynamicRules = function () {
    var close = root.document.querySelector('#user-message .close');
    if (close) close.setAttribute('title', t('notification.close'));
    Array.prototype.forEach.call(
      root.document.querySelectorAll('.cheatsheet-key[title]'),
      function (element) {
        element.setAttribute(
          'title',
          translateKnownRuntimeMessage(element.getAttribute('title'))
        );
      }
    );
    var anchorInfo = root.document.querySelector('.import-resize-anchor-info');
    if (anchorInfo) {
      var translatedHtml = translateKnownRuntimeMessage(anchorInfo.innerHTML);
      if (translatedHtml !== anchorInfo.innerHTML) anchorInfo.innerHTML = translatedHtml;
    }
  };

  var startBoundedObserver = function () {
    if (typeof root.MutationObserver !== 'function') return;
    var observer = new root.MutationObserver(applyBoundedDynamicRules);
    observer.observe(root.document.body, { childList: true, subtree: true });
  };

  var beforePiskelInit = function (pskl) {
    root.document.documentElement.setAttribute('lang', translator.locale);
    applyRules(root.document, visibleRules);
    installNativeDialogTranslation();
    installPiskelRuntimeTranslation(pskl);
  };

  var afterPiskelInit = function () {
    applyBoundedDynamicRules();
    startBoundedObserver();
  };

  root.PlaymeshPiskelI18n = Object.freeze({
    afterPiskelInit: afterPiskelInit,
    beforePiskelInit: beforePiskelInit,
    locale: translator.locale,
    t: t,
    translateKnownRuntimeMessage: translateKnownRuntimeMessage,
    translateTemplate: translateTemplate,
  });
})(typeof globalThis === 'object' ? globalThis : window);
