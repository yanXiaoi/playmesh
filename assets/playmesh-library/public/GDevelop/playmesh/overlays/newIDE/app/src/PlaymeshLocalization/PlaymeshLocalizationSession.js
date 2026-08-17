// @flow

import { selectLanguageOrLocale } from '../Utils/Language';
import type { PlaymeshMessageKey } from './PlaymeshMessageKeys';

export type PlaymeshMessageArgument =
  | string
  | number
  | boolean
  | null
  | void;
export type PlaymeshMessageArguments = $ReadOnly<{
  [string]: PlaymeshMessageArgument,
}>;
export type PlaymeshLocalizationMessages = $ReadOnly<{
  [string]: string,
}>;
export type PlaymeshLocalizationSnapshot = $ReadOnly<{|
  formatVersion: string,
  localeId: string,
  messages: PlaymeshLocalizationMessages,
|}>;
export type PlaymeshLocalizationState = $ReadOnly<{|
  ready: boolean,
  loading: boolean,
  stale: boolean,
  entryAuthoritative: boolean,
  generation: number,
  language: string,
  targetLanguage: string,
  localeId: string,
  messages: PlaymeshLocalizationMessages,
|}>;
export type PreparedPlaymeshLanguage = $ReadOnly<{|
  generation: number,
  language: string,
  snapshot: ?PlaymeshLocalizationSnapshot,
  stale: boolean,
|}>;

type PlaymeshLocalizationStorage = {|
  getItem: (key: string) => ?string,
  setItem: (key: string, value: string) => void,
|};
type PlaymeshLocalizationFetchOptions = {|
  headers: { [string]: string },
  cache: 'no-store',
  credentials: 'same-origin',
  signal?: AbortSignal,
|};
type PlaymeshLocalizationFetcher = (
  url: string,
  options: PlaymeshLocalizationFetchOptions
) => Promise<Response>;
type PlaymeshLocalizationListener = (
  state: PlaymeshLocalizationState
) => void;
type PlaymeshLocalizationOptions = {|
  fetchImpl?: PlaymeshLocalizationFetcher,
  storage?: ?PlaymeshLocalizationStorage,
  endpoint?: string,
  requestTimeoutMs?: number,
  bootstrap?: mixed,
|};
type CachedPlaymeshLocalizationSnapshot = {|
  savedAt: number,
  snapshot: PlaymeshLocalizationSnapshot,
|};
type PreparedLanguageOptions = {|
  allowAny?: boolean,
|};
type MixedRecord = { +[string]: mixed };

const LOCALIZATION_ENDPOINT = '/dev/api/localization';
const LKG_STORAGE_KEY = 'playmesh-gdevelop-localization-lkg-v1';
const FORMAT_VERSION = '1.0.0';
const GDEVELOP_DEFAULT_LANGUAGE = 'en';
const PLAYMESH_MESSAGE_PREFIX = 'workspace.gdevelop_';
const ENTRY_BOOTSTRAP_NAME = '__PLAYMESH_GDEVELOP_LOCALIZATION_BOOTSTRAP__';
const DEFAULT_REQUEST_TIMEOUT_MS = 5000;

const normalizeLocaleId = (value: mixed): string =>
  typeof value === 'string' ? value.trim().replace(/_/g, '-') : '';

const normalizeGDevelopLanguage = (value: mixed): string =>
  typeof value === 'string' ? value.trim().replace(/-/g, '_') : '';

const languageOnly = (value: mixed): string =>
  normalizeLocaleId(value).split('-')[0].toLowerCase();

const asMixedRecord = (value: mixed): ?MixedRecord => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return (value: MixedRecord);
};

const filterPlaymeshMessages = (
  messages: mixed
): PlaymeshLocalizationMessages => {
  const messageRecord = asMixedRecord(messages);
  if (!messageRecord) {
    throw new Error('invalid_playmesh_localization_messages');
  }
  const result: { [string]: string } = {};
  Object.keys(messageRecord).forEach((key: string) => {
    const message = messageRecord[key];
    if (
      key.startsWith(PLAYMESH_MESSAGE_PREFIX) &&
      typeof message === 'string'
    ) {
      result[key] = message;
    }
  });
  return Object.freeze(result);
};

export const assertPlaymeshLocalizationSnapshot = (
  value: mixed
): PlaymeshLocalizationSnapshot => {
  const snapshotRecord = asMixedRecord(value);
  const localeId = snapshotRecord
    ? normalizeLocaleId(snapshotRecord.localeId)
    : '';
  if (
    !snapshotRecord ||
    snapshotRecord.formatVersion !== FORMAT_VERSION ||
    !localeId
  ) {
    throw new Error('invalid_playmesh_localization_snapshot');
  }
  return Object.freeze({
    formatVersion: FORMAT_VERSION,
    localeId,
    messages: filterPlaymeshMessages(snapshotRecord.messages),
  });
};

export const resolvePlaymeshGDevelopLanguage = (localeId: mixed): string =>
  selectLanguageOrLocale(
    normalizeGDevelopLanguage(localeId) || GDEVELOP_DEFAULT_LANGUAGE,
    GDEVELOP_DEFAULT_LANGUAGE
  );

const interpolate = (
  message: string,
  argumentsMap: ?PlaymeshMessageArguments
): string => {
  if (!argumentsMap) return message;
  return message.replace(/\{([^}]+)\}/g, (match: string, name: string) =>
    Object.keys(argumentsMap).includes(name)
      ? String(argumentsMap[name])
      : match
  );
};

const safeStorage = (
  storage: ?PlaymeshLocalizationStorage
): ?PlaymeshLocalizationStorage => {
  if (storage) return storage;
  try {
    return global.localStorage || null;
  } catch (_) {
    return null;
  }
};

const readEntryBootstrap = (): ?PlaymeshLocalizationSnapshot => {
  try {
    const value = global[ENTRY_BOOTSTRAP_NAME];
    return value ? assertPlaymeshLocalizationSnapshot(value) : null;
  } catch (_) {
    return null;
  }
};

export class PlaymeshLocalizationSession {
  _fetch: PlaymeshLocalizationFetcher;
  _storage: ?PlaymeshLocalizationStorage;
  _endpoint: string;
  _requestTimeoutMs: number;
  _listeners: Set<PlaymeshLocalizationListener>;
  _active: boolean;
  _generation: number;
  _initializePromise: ?Promise<PlaymeshLocalizationState>;
  _hasEntryAuthority: boolean;
  _state: PlaymeshLocalizationState;

  constructor({
    fetchImpl,
    storage,
    endpoint,
    requestTimeoutMs,
    bootstrap,
  }: PlaymeshLocalizationOptions = {}) {
    this._fetch =
      fetchImpl ||
      (async (
        url: string,
        options: PlaymeshLocalizationFetchOptions
      ): Promise<Response> => {
        const fetchFunction = global.fetch;
        if (typeof fetchFunction !== 'function') {
          throw new Error('playmesh_localization_fetch_unavailable');
        }
        return fetchFunction(url, options);
      });
    this._storage = safeStorage(storage);
    this._endpoint = endpoint || LOCALIZATION_ENDPOINT;
    this._requestTimeoutMs =
      Number.isFinite(requestTimeoutMs) && requestTimeoutMs > 0
        ? requestTimeoutMs
        : DEFAULT_REQUEST_TIMEOUT_MS;
    this._listeners = new Set();
    this._active = false;
    this._generation = 0;
    this._initializePromise = null;
    let entrySnapshot: ?PlaymeshLocalizationSnapshot = null;
    try {
      entrySnapshot = bootstrap
        ? assertPlaymeshLocalizationSnapshot(bootstrap)
        : readEntryBootstrap();
    } catch (_) {}
    this._hasEntryAuthority = !!entrySnapshot;
    const initialSnapshot =
      entrySnapshot || this._findCachedSnapshot('', { allowAny: true });
    const initialLocaleId =
      initialSnapshot?.localeId || GDEVELOP_DEFAULT_LANGUAGE;
    const initialLanguage = entrySnapshot
      ? resolvePlaymeshGDevelopLanguage(entrySnapshot.localeId)
      : GDEVELOP_DEFAULT_LANGUAGE;
    this._state = Object.freeze({
      ready: true,
      loading: false,
      stale: !initialSnapshot,
      entryAuthoritative: this._hasEntryAuthority,
      generation: 0,
      language: initialLanguage,
      targetLanguage: initialLanguage,
      localeId: initialLocaleId,
      messages: initialSnapshot?.messages || Object.freeze({}),
    });
    if (initialSnapshot) this._writeCache(initialSnapshot);
  }

  getState = (): PlaymeshLocalizationState => this._state;

  activate = (): void => {
    this._active = true;
    // 首屏已有 Gateway 注入时后台刷新；没有 bootstrap 时保持 GDevelop
    // 自己的偏好，待官方语言加载器按当前会话语言请求对应文案。
    if (this._hasEntryAuthority) void this.initialize();
  };

  isActive = (): boolean => this._active;

  getPromptLocale = (): string =>
    normalizeLocaleId(this._state.language) || this._state.localeId;

  subscribe = (
    listener: PlaymeshLocalizationListener
  ): (() => void) => {
    this._listeners.add(listener);
    return () => {
      this._listeners.delete(listener);
    };
  };

  _emit = (nextState: PlaymeshLocalizationState): void => {
    this._state = Object.freeze(nextState);
    this._listeners.forEach((listener: PlaymeshLocalizationListener) =>
      listener(this._state)
    );
  };

  _readCache = (): Array<CachedPlaymeshLocalizationSnapshot> => {
    if (!this._storage) return [];
    try {
      const decoded = asMixedRecord(
        (JSON.parse(this._storage.getItem(LKG_STORAGE_KEY) || 'null'): mixed)
      );
      if (
        !decoded ||
        decoded.formatVersion !== FORMAT_VERSION ||
        !Array.isArray(decoded.entries)
      ) {
        return [];
      }
      const entries: Array<CachedPlaymeshLocalizationSnapshot> = [];
      decoded.entries.forEach((entry: mixed) => {
        const entryRecord = asMixedRecord(entry);
        if (!entryRecord) return;
        try {
          const savedAtValue = entryRecord.savedAt;
          entries.push({
            savedAt:
              typeof savedAtValue === 'number' && Number.isFinite(savedAtValue)
                ? savedAtValue
                : 0,
            snapshot: assertPlaymeshLocalizationSnapshot(entryRecord.snapshot),
          });
        } catch (_) {}
      });
      return entries.sort(
        (
          left: CachedPlaymeshLocalizationSnapshot,
          right: CachedPlaymeshLocalizationSnapshot
        ) => right.savedAt - left.savedAt
      );
    } catch (_) {
      return [];
    }
  };

  _writeCache = (snapshot: PlaymeshLocalizationSnapshot): void => {
    const storage = this._storage;
    if (!storage) return;
    try {
      const normalized = snapshot.localeId.toLowerCase();
      const entries = this._readCache()
        .filter(
          (entry: CachedPlaymeshLocalizationSnapshot) =>
            entry.snapshot.localeId.toLowerCase() !== normalized
        )
        .slice(0, 7);
      entries.unshift({ savedAt: Date.now(), snapshot });
      storage.setItem(
        LKG_STORAGE_KEY,
        JSON.stringify({ formatVersion: FORMAT_VERSION, entries })
      );
    } catch (_) {}
  };

  _findCachedSnapshot = (
    requestedLocale: mixed,
    { allowAny = false }: PreparedLanguageOptions = {}
  ): ?PlaymeshLocalizationSnapshot => {
    const entries = this._readCache();
    if (!entries.length) return null;
    const normalized = normalizeLocaleId(requestedLocale).toLowerCase();
    const exact = entries.find(
      (entry: CachedPlaymeshLocalizationSnapshot) =>
        entry.snapshot.localeId.toLowerCase() === normalized
    );
    if (exact) return exact.snapshot;
    const requestedLanguage = languageOnly(requestedLocale);
    const sameLanguage = entries.find(
      (entry: CachedPlaymeshLocalizationSnapshot) =>
        languageOnly(entry.snapshot.localeId) === requestedLanguage
    );
    if (sameLanguage) return sameLanguage.snapshot;
    return allowAny ? entries[0].snapshot : null;
  };

  _requestSnapshot = async (
    requestedLocale: ?string
  ): Promise<PlaymeshLocalizationSnapshot> => {
    const url = new URL(this._endpoint, global.location?.href || 'http://localhost/');
    if (requestedLocale) url.searchParams.set('locale', requestedLocale);
    const controller =
      typeof global.AbortController === 'function'
        ? new global.AbortController()
        : null;
    const timeout = global.setTimeout?.(
      () => controller?.abort(),
      this._requestTimeoutMs
    );
    let response: Response;
    try {
      response = await this._fetch(url.pathname + url.search, {
        headers: { Accept: 'application/json' },
        cache: 'no-store',
        credentials: 'same-origin',
        ...(controller ? { signal: controller.signal } : {}),
      });
    } finally {
      if (timeout !== undefined) global.clearTimeout?.(timeout);
    }
    if (!response || !response.ok) {
      throw new Error(`playmesh_localization_http_${response?.status || 0}`);
    }
    return assertPlaymeshLocalizationSnapshot((await response.json(): mixed));
  };

  initialize = (): Promise<PlaymeshLocalizationState> => {
    if (this._initializePromise) return this._initializePromise;
    const generation = ++this._generation;
    this._emit({
      ...this._state,
      loading: true,
      generation,
    });
    const requestedLocale = this._hasEntryAuthority
      ? normalizeLocaleId(this._state.language)
      : null;
    this._initializePromise = this._requestSnapshot(requestedLocale)
      .then((snapshot: PlaymeshLocalizationSnapshot) => {
        if (generation !== this._generation) return this._state;
        this._writeCache(snapshot);
        this._emit({
          ...this._state,
          ready: true,
          loading: false,
          stale: false,
          generation,
          localeId: snapshot.localeId,
          messages: snapshot.messages,
        });
        return this._state;
      })
      .catch(() => {
        if (generation !== this._generation) return this._state;
        const cached = this._findCachedSnapshot('', { allowAny: true });
        const localeId = cached?.localeId || this._state.localeId;
        this._emit({
          ...this._state,
          ready: true,
          loading: false,
          stale: true,
          generation,
          localeId,
          messages: cached?.messages || this._state.messages,
        });
        return this._state;
      });
    return this._initializePromise;
  };

  setTargetGDevelopLanguage = (language: mixed): PlaymeshLocalizationState => {
    const normalizedLanguage = normalizeGDevelopLanguage(language);
    if (!normalizedLanguage || normalizedLanguage === this._state.targetLanguage) {
      return this._state;
    }
    this._emit({
      ...this._state,
      targetLanguage: normalizedLanguage,
    });
    return this._state;
  };

  prepareGDevelopLanguage = async (
    language: mixed
  ): Promise<?PreparedPlaymeshLanguage> => {
    const normalizedLanguage = normalizeGDevelopLanguage(language);
    if (!normalizedLanguage) return null;
    const generation = ++this._generation;
    this._emit({
      ...this._state,
      loading: true,
      generation,
      targetLanguage: normalizedLanguage,
    });
    try {
      const snapshot = await this._requestSnapshot(
        normalizeLocaleId(normalizedLanguage)
      );
      return {
        generation,
        language: normalizedLanguage,
        snapshot,
        stale: false,
      };
    } catch (_) {
      const cached = this._findCachedSnapshot(normalizedLanguage);
      return {
        generation,
        language: normalizedLanguage,
        snapshot: cached,
        stale: true,
      };
    }
  };

  commitPreparedGDevelopLanguage = (
    prepared: ?PreparedPlaymeshLanguage
  ): boolean => {
    if (!prepared || prepared.generation !== this._generation) return false;
    const snapshot = prepared.snapshot;
    if (snapshot) this._writeCache(snapshot);
    this._emit(
      snapshot
        ? {
            ...this._state,
            ready: true,
            loading: false,
            stale: prepared.stale,
            generation: prepared.generation,
            language: prepared.language,
            targetLanguage: prepared.language,
            localeId: snapshot.localeId,
            messages: snapshot.messages,
          }
        : {
            ...this._state,
            ready: true,
            loading: false,
            stale: true,
            generation: prepared.generation,
            targetLanguage: prepared.language,
          }
    );
    return true;
  };

  useGDevelopLanguage = async (
    language: mixed
  ): Promise<PlaymeshLocalizationState> => {
    const prepared = await this.prepareGDevelopLanguage(language);
    this.commitPreparedGDevelopLanguage(prepared);
    return this._state;
  };

  translate = (
    key: PlaymeshMessageKey,
    argumentsMap: ?PlaymeshMessageArguments
  ): string => {
    if (typeof key !== 'string' || !key.startsWith(PLAYMESH_MESSAGE_PREFIX)) {
      throw new Error('invalid_playmesh_gdevelop_message_key');
    }
    return interpolate(this._state.messages[key] || key, argumentsMap);
  };
}

export const playmeshLocalizationSession: PlaymeshLocalizationSession = new PlaymeshLocalizationSession();

export const activatePlaymeshLocalizationSession = (): void =>
  playmeshLocalizationSession.activate();

export const getPlaymeshInitialGDevelopLanguage = (): ?string => {
  const state = playmeshLocalizationSession.getState();
  return state.entryAuthoritative ? state.language : null;
};

export const notifyPlaymeshGDevelopLanguageChanged = (language: mixed): void => {
  playmeshLocalizationSession.setTargetGDevelopLanguage(language);
};

export const getPlaymeshPromptLocale = (): string =>
  playmeshLocalizationSession.getPromptLocale();

export const getPlaymeshMessage = (
  key: PlaymeshMessageKey,
  argumentsMap?: PlaymeshMessageArguments
): string =>
  playmeshLocalizationSession.translate(key, argumentsMap);
