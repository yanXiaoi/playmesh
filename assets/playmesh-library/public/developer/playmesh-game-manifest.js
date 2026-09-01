(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.PlaymeshGameManifest = api;
})(typeof window === 'object' ? window : null, function () {
  const SOURCE_ID_PREFIX = 'com.playmesh.game-';
  const ANDROID_ID_PREFIX = 'com.playmesh.game.g';
  const ID_ALPHABET = 'abcdefghijklmnopqrstuvwxyz0123456789';
  const ID_SUFFIX_LENGTH = 10;
  const GAME_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
  const NEW_PROJECT_GAME_ID_PATTERN = /^(?:[A-Za-z][A-Za-z0-9_]*\.)+[A-Za-z][A-Za-z0-9_]*$/;
  const SEMVER_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
  const HTML_ENTRY_PATTERN = /^(?:[^/?#]+\/)*[^/?#]+\.html(?:\?(?:%[0-9A-Fa-f]{2}|[^%\s#])+)?$/i;
  const JAVASCRIPT_ENTRY_PATTERN = /\.(?:js|mjs)$/i;
  const RESERVED_PATH_PATTERN = /^(?:playmesh|bucket)(?:\/|$)/i;
  const INVALID_PATH_PATTERN = /(^|\/)\.{1,2}(?:\/|\?|$)|[\\#]|^[^?]*%|^[A-Za-z][A-Za-z0-9+.-]*:/;
  const allowedOrientations = new Set(['landscape', 'portrait', 'system']);
  const allowedModes = new Set(['solo', 'multiplayer']);
  const allowedDisplayModes = new Set([
    'multi_screen',
    'single_screen_multiplayer',
  ]);

  function randomBytes(length, randomValues) {
    const values = new Uint8Array(length);
    if (typeof randomValues === 'function') {
      const supplied = randomValues(values);
      if (supplied && supplied !== values) values.set(supplied);
      return values;
    }
    const browserCrypto =
      typeof window === 'object' && window.crypto ? window.crypto : null;
    if (browserCrypto && typeof browserCrypto.getRandomValues === 'function') {
      browserCrypto.getRandomValues(values);
      return values;
    }
    for (let index = 0; index < length; index += 1) {
      values[index] = Math.floor(Math.random() * 256);
    }
    return values;
  }

  function generateGameId(options) {
    const settings = options || {};
    const profile = settings.profile || 'source';
    if (profile !== 'source' && profile !== 'android') {
      throw new TypeError('Unknown Playmesh game ID profile: ' + profile);
    }
    const suffix = Array.from(
      randomBytes(ID_SUFFIX_LENGTH, settings.randomValues),
      value => ID_ALPHABET[value % ID_ALPHABET.length]
    ).join('');
    return (profile === 'android' ? ANDROID_ID_PREFIX : SOURCE_ID_PREFIX) + suffix;
  }

  function isValidNewProjectGameId(value) {
    return (
      typeof value === 'string' &&
      value.length <= 64 &&
      NEW_PROJECT_GAME_ID_PATTERN.test(value)
    );
  }

  function normalizedString(value) {
    return typeof value === 'string' ? value.trim() : '';
  }

  function readGameManifestConfigValue(config, fieldPath) {
    if (!Array.isArray(fieldPath) || fieldPath.length === 0) return null;
    let current = config;
    for (const field of fieldPath) {
      if (
        typeof field !== 'string' ||
        field.length === 0 ||
        !current ||
        typeof current !== 'object' ||
        Array.isArray(current) ||
        !Object.prototype.hasOwnProperty.call(current, field)
      ) {
        return null;
      }
      current = current[field];
    }
    return current;
  }

  function isSafeEntry(value, kind) {
    if (typeof value !== 'string' || value !== value.trim() || !value) return false;
    if (RESERVED_PATH_PATTERN.test(value) || INVALID_PATH_PATTERN.test(value)) {
      return false;
    }
    return kind === 'html'
      ? HTML_ENTRY_PATTERN.test(value)
      : JAVASCRIPT_ENTRY_PATTERN.test(value) && !value.includes('?');
  }

  function validateGameManifest(manifest) {
    const errors = [];
    const fail = (path, message) => errors.push({ path, message });
    if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
      fail('', 'manifest must be an object');
      return { valid: false, errors };
    }

    if (typeof manifest.id !== 'string' || !GAME_ID_PATTERN.test(manifest.id)) {
      fail('id', 'must be a valid Playmesh game ID');
    }
    if (!normalizedString(manifest.name)) fail('name', 'must not be empty');
    if (manifest.author !== undefined) {
      if (typeof manifest.author !== 'string' || manifest.author.trim().length > 80) {
        fail('author', 'must be a string no longer than 80 characters');
      }
    }
    if (
      manifest.lastModifiedAt !== undefined &&
      (!Number.isSafeInteger(manifest.lastModifiedAt) || manifest.lastModifiedAt < 0)
    ) {
      fail('lastModifiedAt', 'must be a non-negative integer timestamp');
    }
    if (manifest.remarks !== undefined && typeof manifest.remarks !== 'string') {
      fail('remarks', 'must be a string');
    }
    for (const field of ['version', 'sdkVersion', 'appSdkVersion']) {
      if (typeof manifest[field] !== 'string' || !SEMVER_PATTERN.test(manifest[field])) {
        fail(field, 'must be an exact semantic version');
      }
    }
    if (!allowedOrientations.has(manifest.orientation)) {
      fail('orientation', 'must be landscape, portrait, or system');
    }
    if (
      !Array.isArray(manifest.modes) ||
      manifest.modes.length !== 1 ||
      !allowedModes.has(manifest.modes[0])
    ) {
      fail('modes', 'must contain exactly one supported mode');
    }
    if (
      !Array.isArray(manifest.displayModes) ||
      manifest.displayModes.length !== 1 ||
      !allowedDisplayModes.has(manifest.displayModes[0])
    ) {
      fail('displayModes', 'must contain exactly one supported display mode');
    }

    const mode = Array.isArray(manifest.modes) ? manifest.modes[0] : '';
    const displayMode = Array.isArray(manifest.displayModes)
      ? manifest.displayModes[0]
      : '';
    const singleScreen =
      mode === 'multiplayer' && displayMode === 'single_screen_multiplayer';
    if (
      !manifest.players ||
      typeof manifest.players !== 'object' ||
      !Number.isInteger(manifest.players.min) ||
      !Number.isInteger(manifest.players.max) ||
      manifest.players.min < 1 ||
      manifest.players.max < manifest.players.min
    ) {
      fail('players', 'must satisfy 1 <= min <= max');
    }
    if (mode === 'solo' && Number.isInteger(manifest.players?.max) && manifest.players.max > 1) {
      fail('players', 'max greater than one requires multiplayer mode');
    }

    if (!manifest.entries || typeof manifest.entries !== 'object') {
      fail('entries', 'must be an object');
    } else {
      if (!isSafeEntry(manifest.entries.game, 'html')) {
        fail('entries.game', 'must be a safe relative HTML entry');
      }
      if (singleScreen) {
        if (!isSafeEntry(manifest.entries.controller, 'html')) {
          fail('entries.controller', 'is required for single-screen multiplayer');
        }
      }
    }
    if (singleScreen) {
      if (!allowedOrientations.has(manifest.controllerOrientation)) {
        fail('controllerOrientation', 'is required for single-screen multiplayer');
      }
    } else if (manifest.controllerOrientation !== undefined) {
      fail('controllerOrientation', 'is only allowed for single-screen multiplayer');
    }
    if (mode === 'multiplayer' && !manifest.authority) {
      fail('authority.entry', 'is required for multiplayer games');
    }
    if (
      manifest.authority !== undefined &&
      (!manifest.authority ||
        typeof manifest.authority !== 'object' ||
        !isSafeEntry(manifest.authority.entry, 'javascript'))
    ) {
      fail('authority.entry', 'must be a safe relative JavaScript entry');
    }
    if (!Array.isArray(manifest.tags) || manifest.tags.length > 5) {
      fail('tags', 'must be an array with at most 5 items');
    } else if (manifest.tags.some(tag => typeof tag !== 'string')) {
      fail('tags', 'items must be strings');
    }
    return { valid: errors.length === 0, errors };
  }

  function assertGameManifest(manifest) {
    const result = validateGameManifest(manifest);
    if (!result.valid) {
      const error = new TypeError(
        result.errors.map(item => (item.path ? item.path + ': ' : '') + item.message).join('; ')
      );
      error.validationErrors = result.errors;
      throw error;
    }
    return manifest;
  }

  function buildGameManifest(input) {
    if (!input || typeof input !== 'object') {
      throw new TypeError('Playmesh manifest input must be an object');
    }
    const mode = input.mode;
    const displayMode = input.displayMode;
    const singleScreen =
      mode === 'multiplayer' && displayMode === 'single_screen_multiplayer';
    const manifest = {
      id: normalizedString(input.id),
      name: normalizedString(input.name),
      ...(input.author !== undefined ? { author: normalizedString(input.author) } : {}),
      ...(input.lastModifiedAt !== undefined
        ? { lastModifiedAt: input.lastModifiedAt }
        : {}),
      remarks: typeof input.remarks === 'string' ? input.remarks.trim() : '',
      version: normalizedString(input.version),
      sdkVersion: normalizedString(input.sdkVersion),
      appSdkVersion: normalizedString(input.appSdkVersion),
      orientation: input.orientation,
      ...(singleScreen
        ? { controllerOrientation: input.controllerOrientation }
        : {}),
      modes: [mode],
      displayModes: [displayMode],
      players: { min: input.minPlayers, max: input.maxPlayers },
      entries: {
        game: normalizedString(input.gameEntry),
        ...(singleScreen
          ? { controller: normalizedString(input.controllerEntry) }
          : {}),
      },
      tags: Array.isArray(input.tags)
        ? Array.from(new Set(input.tags.map(normalizedString).filter(Boolean)))
        : [],
      ...(mode === 'multiplayer'
        ? { authority: { entry: normalizedString(input.authorityEntry) } }
        : {}),
      ...(Object.prototype.hasOwnProperty.call(input, 'config')
        ? { config: input.config }
        : {}),
    };
    return assertGameManifest(manifest);
  }

  return Object.freeze({
    SOURCE_ID_PREFIX,
    ANDROID_ID_PREFIX,
    MAIN_MANIFEST_FILENAME: 'main.json',
    ICON_FILENAME: 'icon.png',
    generateGameId,
    isValidNewProjectGameId,
    readGameManifestConfigValue,
    buildGameManifest,
    validateGameManifest,
    assertGameManifest,
  });
});
