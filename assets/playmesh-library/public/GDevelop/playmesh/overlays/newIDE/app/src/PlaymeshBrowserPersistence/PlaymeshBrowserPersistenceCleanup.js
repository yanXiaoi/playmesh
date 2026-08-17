// @flow

const LEGACY_DATABASE_NAMES = [
  'gdevelop-cloud-project-autosave',
];

const LEGACY_LOCAL_STORAGE_KEYS = [
  'gd-user-uuid',
  'gd-local-stats-program-opening',
];

type PlaymeshBrowserPersistencePolicy = {|
  +durableProjectSource: string,
  +indexedDbInNormalRuntime: string,
  +allowedBrowserPersistence: $ReadOnlyArray<string>,
|};

export const PLAYMESH_BROWSER_PERSISTENCE_POLICY /*: PlaymeshBrowserPersistencePolicy */ = Object.freeze({
  durableProjectSource: 'app-gateway',
  indexedDbInNormalRuntime: 'forbidden',
  allowedBrowserPersistence: Object.freeze([
    'disposable-ui-preferences',
    'session-transaction-receipts',
    'disposable-localization-cache',
  ]),
});

let cleanupPromise: ?Promise<void> = null;

const deleteLegacyDatabase = (databaseName: string): Promise<void> => {
  if (typeof window === 'undefined' || !window.indexedDB) {
    return Promise.resolve();
  }

  return new Promise(resolve => {
    try {
      const request = window.indexedDB.deleteDatabase(databaseName);
      request.onsuccess = () => resolve();
      request.onerror = () => {
        console.warn(
          `[Playmesh] Unable to delete legacy browser database ${databaseName}.`,
          request.error
        );
        resolve();
      };
      request.onblocked = () => {
        console.warn(
          `[Playmesh] Deleting legacy browser database ${databaseName} is blocked by another tab.`
        );
        resolve();
      };
    } catch (error) {
      console.warn(
        `[Playmesh] Unable to request deletion of legacy browser database ${databaseName}.`,
        error
      );
      resolve();
    }
  });
};

const removeLegacyLocalStorageValues = () => {
  if (typeof window === 'undefined' || !window.localStorage) return;
  for (const key of LEGACY_LOCAL_STORAGE_KEYS) {
    try {
      window.localStorage.removeItem(key);
    } catch (error) {
      // Storage can be disabled by browser policy. These legacy values are not
      // required for editor startup, so cleanup remains best effort.
    }
  }
};

/**
 * Removes browser-owned durable project/preview remnants from older WebIDE
 * builds. The App Gateway remains the only durable project source; browser
 * storage is reserved for disposable UI preferences and session receipts.
 */
export const cleanupPlaymeshLegacyBrowserPersistence = (): Promise<void> => {
  if (cleanupPromise) return cleanupPromise;

  cleanupPromise = (async () => {
    removeLegacyLocalStorageValues();
    await Promise.all(LEGACY_DATABASE_NAMES.map(deleteLegacyDatabase));
  })();
  return cleanupPromise;
};
