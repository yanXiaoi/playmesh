// @flow

// Blob URLs used by a live gdProject must remain stable for as long as the
// page can still hold GDevelop/Pixi consumers. Persisted project JSON never
// contains these URLs: this registry only materializes App-owned resource
// blobs for the current WebIDE document.

type StoredResource = {
  logicalUrl: string,
  blob: Blob,
  contentHash?: string,
  ...,
};

type RegistryOptions = {|
  createObjectURL: Blob => string,
  revokeObjectURL: string => void,
|};

export type PlaymeshResourceObjectUrlRegistry = {|
  acquire: StoredResource => string,
  dispose: () => void,
|};

const contentKey = (resource: StoredResource): ?string => {
  const hash = resource.contentHash;
  if (typeof hash !== 'string' || !/^[a-f0-9]{64}$/.test(hash)) return null;
  // GDevelop permits distinct resource entries to reference identical bytes.
  // They must retain distinct object URLs so PlaymeshProjectSerializer can map
  // each URL back to its own logicalId instead of collapsing aliases during a
  // save/history/AI snapshot round trip. The same logical resource still gets
  // a stable URL for the lifetime of the document.
  return `${resource.logicalUrl}\n${hash}\n${resource.blob.type || ''}`;
};

export const createPlaymeshResourceObjectUrlRegistry = ({
  createObjectURL,
  revokeObjectURL,
}: RegistryOptions): PlaymeshResourceObjectUrlRegistry => {
  const objectUrlByContent = new Map<string, string>();
  const ownedObjectUrls = new Set<string>();

  const acquire = (resource: StoredResource): string => {
    const key = contentKey(resource);
    if (key) {
      const existing = objectUrlByContent.get(key);
      if (existing) return existing;
    }

    const objectUrl = createObjectURL(resource.blob);
    ownedObjectUrls.add(objectUrl);
    if (key) objectUrlByContent.set(key, objectUrl);
    return objectUrl;
  };

  // Explicit disposal is reserved for document teardown. Project close,
  // save, preview and editor-tab changes cannot prove that Pixi has released
  // every asynchronous consumer, so they intentionally do not call this.
  const dispose = (): void => {
    ownedObjectUrls.forEach(objectUrl => revokeObjectURL(objectUrl));
    ownedObjectUrls.clear();
    objectUrlByContent.clear();
  };

  return { acquire, dispose };
};

export const playmeshResourceObjectUrlRegistry /*: PlaymeshResourceObjectUrlRegistry */ = createPlaymeshResourceObjectUrlRegistry(
  {
    createObjectURL: blob => URL.createObjectURL(blob),
    revokeObjectURL: objectUrl => URL.revokeObjectURL(objectUrl),
  }
);
