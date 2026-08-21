(function (root) {
  'use strict';

  if (root.PlaymeshExternalEditorI18n) return;

  var catalogsByEditor = Object.create(null);

  var normalizeLocaleId = function (value) {
    if (typeof value !== 'string') return '';
    var normalized = value.trim().replace(/_/g, '-');
    if (!normalized) return '';
    var parts = normalized.split('-').filter(Boolean);
    if (!parts.length) return '';
    return parts
      .map(function (part, index) {
        if (index === 0) return part.toLowerCase();
        if (part.length === 2 || /^\d{3}$/.test(part)) {
          return part.toUpperCase();
        }
        if (part.length === 4) {
          return part.charAt(0).toUpperCase() + part.slice(1).toLowerCase();
        }
        return part.toLowerCase();
      })
      .join('-');
  };

  var readExplicitLocale = function (locationLike) {
    var search =
      locationLike && typeof locationLike.search === 'string'
        ? locationLike.search
        : '';
    if (!search) return '';
    try {
      var parameters = new root.URLSearchParams(search);
      return normalizeLocaleId(parameters.get('locale') || '');
    } catch (_) {
      var match = search.match(/(?:^|[?&])locale=([^&]*)/);
      if (!match) return '';
      try {
        return normalizeLocaleId(decodeURIComponent(match[1].replace(/\+/g, ' ')));
      } catch (_) {
        return normalizeLocaleId(match[1]);
      }
    }
  };

  var registerCatalog = function (catalog) {
    if (!catalog || typeof catalog !== 'object') {
      throw new Error('invalid_external_editor_catalog');
    }
    var editor =
      typeof catalog.editor === 'string' ? catalog.editor.trim() : '';
    var locale = normalizeLocaleId(catalog.locale);
    var messages = catalog.messages;
    if (
      !editor ||
      !locale ||
      !messages ||
      typeof messages !== 'object' ||
      Array.isArray(messages)
    ) {
      throw new Error('invalid_external_editor_catalog');
    }
    var normalizedMessages = Object.create(null);
    Object.keys(messages).forEach(function (key) {
      if (typeof messages[key] !== 'string') {
        throw new Error('invalid_external_editor_message');
      }
      normalizedMessages[key] = messages[key];
    });
    if (!catalogsByEditor[editor]) {
      catalogsByEditor[editor] = Object.create(null);
    }
    catalogsByEditor[editor][locale] = Object.freeze(normalizedMessages);
  };

  var normalizeAliases = function (aliases) {
    var output = Object.create(null);
    Object.keys(aliases || {}).forEach(function (candidate) {
      var normalizedCandidate = normalizeLocaleId(candidate);
      var normalizedTarget = normalizeLocaleId(aliases[candidate]);
      if (normalizedCandidate && normalizedTarget) {
        output[normalizedCandidate.toLowerCase()] = normalizedTarget;
      }
    });
    return output;
  };

  var resolveSupportedLocale = function (candidate, supported, aliases) {
    var normalized = normalizeLocaleId(candidate);
    if (!normalized) return '';
    var aliased = aliases[normalized.toLowerCase()] || normalized;
    for (var index = 0; index < supported.length; index += 1) {
      if (supported[index].toLowerCase() === aliased.toLowerCase()) {
        return supported[index];
      }
    }
    var language = aliased.split('-')[0].toLowerCase();
    for (var supportedIndex = 0; supportedIndex < supported.length; supportedIndex += 1) {
      if (supported[supportedIndex].toLowerCase() === language) {
        return supported[supportedIndex];
      }
    }
    return '';
  };

  var resolveLocale = function (options) {
    var supported = (options.supportedLocales || [])
      .map(normalizeLocaleId)
      .filter(Boolean);
    var fallback =
      resolveSupportedLocale(
        options.defaultLocale,
        supported,
        Object.create(null)
      ) || supported[0];
    if (!fallback) throw new Error('missing_external_editor_locale');
    var aliases = normalizeAliases(options.aliases);
    var documentLanguage = '';
    try {
      documentLanguage =
        options.documentLanguage ||
        (root.document && root.document.documentElement
          ? root.document.documentElement.getAttribute('lang')
          : '');
    } catch (_) {}
    var browserLanguages = options.browserLanguages;
    if (!Array.isArray(browserLanguages)) {
      try {
        browserLanguages =
          (root.navigator && root.navigator.languages) ||
          [root.navigator && root.navigator.language];
      } catch (_) {
        browserLanguages = [];
      }
    }
    var candidates = [options.explicitLocale, documentLanguage].concat(
      browserLanguages || []
    );
    for (var index = 0; index < candidates.length; index += 1) {
      var resolved = resolveSupportedLocale(candidates[index], supported, aliases);
      if (resolved) return resolved;
    }
    return fallback;
  };

  var interpolate = function (message, values) {
    if (!values) return message;
    return message.replace(/\{([^}]+)\}/g, function (match, name) {
      return Object.prototype.hasOwnProperty.call(values, name)
        ? String(values[name])
        : match;
    });
  };

  var createTranslator = function (options) {
    if (!options || typeof options.editor !== 'string') {
      throw new Error('invalid_external_editor_translator');
    }
    var editorCatalogs = catalogsByEditor[options.editor] || Object.create(null);
    var locale = resolveLocale(options);
    var defaultLocale = normalizeLocaleId(options.defaultLocale);
    var messages = editorCatalogs[locale] || Object.create(null);
    var fallbackMessages =
      editorCatalogs[defaultLocale] || Object.create(null);
    var sourceKeys = Object.create(null);
    Object.keys(fallbackMessages).forEach(function (key) {
      var source = fallbackMessages[key];
      if (!Object.prototype.hasOwnProperty.call(sourceKeys, source)) {
        sourceKeys[source] = key;
      }
    });
    var has = function (key) {
      return (
        Object.prototype.hasOwnProperty.call(messages, key) ||
        Object.prototype.hasOwnProperty.call(fallbackMessages, key)
      );
    };
    var t = function (key, values) {
      var message = Object.prototype.hasOwnProperty.call(messages, key)
        ? messages[key]
        : fallbackMessages[key];
      return typeof message === 'string' ? interpolate(message, values) : key;
    };
    var translateSource = function (source, values) {
      if (typeof source !== 'string') return source;
      var key = sourceKeys[source];
      return key ? t(key, values) : source;
    };
    return Object.freeze({
      locale: locale,
      has: has,
      t: t,
      translateSource: translateSource,
    });
  };

  root.PlaymeshExternalEditorI18n = Object.freeze({
    createTranslator: createTranslator,
    normalizeLocaleId: normalizeLocaleId,
    readExplicitLocale: readExplicitLocale,
    registerCatalog: registerCatalog,
    resolveLocale: resolveLocale,
  });
})(typeof globalThis === 'object' ? globalThis : window);
