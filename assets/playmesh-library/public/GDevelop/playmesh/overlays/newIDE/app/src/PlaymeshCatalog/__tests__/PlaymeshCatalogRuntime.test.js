// @flow
import { webcrypto } from 'node:crypto';
import {
  fetchCatalogArtifact,
  sha256Hex,
  validateArtifactUrl,
  validateCatalogManifest,
} from '../PlaymeshCatalogRuntime';
import type { PlaymeshCatalogLimits } from '../PlaymeshCatalogRuntime';
import * as PlaymeshCatalogCache from '../PlaymeshCatalogCache';
import { putArtifactCache, removeArtifactCache } from '../PlaymeshCatalogCache';

jest.mock('../PlaymeshCatalogCache', () => ({
  getArtifactCache: jest.fn(),
  getCatalogCache: jest.fn(),
  putArtifactCache: jest.fn(),
  putCatalogCache: jest.fn(),
  removeArtifactCache: jest.fn(),
  removeCatalogCache: jest.fn(),
}));

const getArtifactCacheMock = jest.spyOn(
  PlaymeshCatalogCache,
  'getArtifactCache'
);

const limits: PlaymeshCatalogLimits = {
  catalogFileBytes: 1024 * 1024,
  extensionBytes: 1024 * 1024,
  exampleProjectBytes: 1024 * 1024,
  exampleResourceBytes: 1024 * 1024,
  exampleTotalBytes: 4 * 1024 * 1024,
  exampleResourceCount: 16,
  licenseFileBytes: 1024 * 1024,
  licenseFileCount: 16,
  downloadConcurrency: 2,
  requestTimeoutMs: 1000,
  retryCount: 0,
};

const responseFor = (bytes: Uint8Array): Object => ({
  ok: true,
  status: 200,
  headers: {
    get: (name: string): ?string =>
      name === 'content-length' ? String(bytes.byteLength) : null,
  },
  arrayBuffer: async (): Promise<ArrayBuffer> =>
    bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
});

describe('PlaymeshCatalogRuntime', () => {
  beforeAll(() => {
    Object.defineProperty(window, 'crypto', {
      configurable: true,
      value: webcrypto,
    });
  });

  beforeEach(() => {
    jest.clearAllMocks();
    global.fetch = jest.fn();
    getArtifactCacheMock.mockResolvedValue(null);
  });

  it('accepts only the pinned engine manifest', () => {
    expect(
      validateCatalogManifest({
        schemaVersion: 1,
        catalogRevision: 'fixture',
        engine: { version: '5.6.269' },
        limits,
        features: {
          extensions: {
            path: 'extensions-index.json',
            bytes: 10,
            sha256: 'a'.repeat(64),
          },
          examples: {
            path: 'examples-index.json',
            bytes: 10,
            sha256: 'b'.repeat(64),
          },
        },
      }).catalogRevision
    ).toBe('fixture');
    expect(() =>
      validateCatalogManifest({
        schemaVersion: 1,
        catalogRevision: 'fixture',
        engine: { version: '6.0.0' },
        limits,
        features: {},
      })
    ).toThrow('不兼容');
  });

  it('rejects an artifact URL outside the exact official raw commit', () => {
    expect(() =>
      validateArtifactUrl({
        id: 'example:fixture:project',
        kind: 'example-project',
        repository: 'GDevelopApp/GDevelop-examples',
        commit: 'c'.repeat(40),
        rootTreeSha: 'e'.repeat(40),
        path: 'examples/fixture/game.json',
        url: 'https://example.invalid/game.json',
        declaredBytes: 10,
        gitBlobOid: 'd'.repeat(40),
        mediaType: 'application/json',
      })
    ).toThrow('URL 不匹配');
  });

  it('downloads, hashes and caches an exact artifact', async () => {
    const bytes = new TextEncoder().encode('{"name":"Fixture"}');
    const artifact = {
      id: 'extension:Fixture',
      kind: 'extension',
      repository: 'GDevelopApp/GDevelop-extensions',
      commit: 'c'.repeat(40),
      rootTreeSha: 'e'.repeat(40),
      path: 'extensions/reviewed/Fixture.json',
      url: `https://raw.githubusercontent.com/GDevelopApp/GDevelop-extensions/${'c'.repeat(
        40
      )}/extensions/reviewed/Fixture.json`,
      declaredBytes: bytes.byteLength,
      gitBlobOid: 'd'.repeat(40),
      mediaType: 'application/json',
    };
    global.fetch.mockResolvedValue(responseFor(bytes));
    const downloaded = await fetchCatalogArtifact({ artifact, limits });
    expect(new Uint8Array(downloaded.bytes)).toEqual(bytes);
    expect(downloaded.contentHash).toBe(await sha256Hex(bytes));
    expect(global.fetch).toHaveBeenCalledTimes(1);
    expect(putArtifactCache).toHaveBeenCalledTimes(1);
  });

  it('discards a corrupt cache using its locally stored hash', async () => {
    const expectedBytes = new TextEncoder().encode('expected');
    const corruptBytes = new TextEncoder().encode('corrupt!');
    const artifact = {
      id: 'example:fixture:resource:0',
      kind: 'example-resource',
      repository: 'GDevelopApp/GDevelop-examples',
      commit: 'c'.repeat(40),
      rootTreeSha: 'e'.repeat(40),
      path: 'examples/fixture/image.bin',
      url: `https://raw.githubusercontent.com/GDevelopApp/GDevelop-examples/${'c'.repeat(
        40
      )}/examples/fixture/image.bin`,
      declaredBytes: expectedBytes.byteLength,
      gitBlobOid: 'd'.repeat(40),
      mediaType: 'application/octet-stream',
    };
    const sourceIdentity = `${artifact.repository}@${artifact.commit}:${
      artifact.path
    }`;
    getArtifactCacheMock.mockResolvedValue({
      bytes: new Blob([corruptBytes]),
      contentHash: await sha256Hex(expectedBytes),
      sourceIdentity,
      mediaType: artifact.mediaType,
    });
    global.fetch.mockResolvedValue(responseFor(expectedBytes));
    const downloaded = await fetchCatalogArtifact({ artifact, limits });
    expect(downloaded.contentHash).toBe(await sha256Hex(expectedBytes));
    expect(removeArtifactCache).toHaveBeenCalledTimes(1);
    expect(putArtifactCache).toHaveBeenCalledTimes(1);
  });

  it('bounds offline failure to a retryable catalog error', async () => {
    const bytes = new TextEncoder().encode('fixture');
    const artifact = {
      id: 'example:fixture:resource:0',
      kind: 'example-resource',
      repository: 'GDevelopApp/GDevelop-examples',
      commit: 'c'.repeat(40),
      rootTreeSha: 'e'.repeat(40),
      path: 'examples/fixture/file.bin',
      url: `https://raw.githubusercontent.com/GDevelopApp/GDevelop-examples/${'c'.repeat(
        40
      )}/examples/fixture/file.bin`,
      declaredBytes: bytes.byteLength,
      gitBlobOid: 'd'.repeat(40),
      mediaType: 'application/octet-stream',
    };
    global.fetch.mockRejectedValue(new TypeError('offline'));
    await expect(
      fetchCatalogArtifact({ artifact, limits })
    ).rejects.toMatchObject({
      code: 'network_error',
      retryable: true,
    });
    expect(global.fetch).toHaveBeenCalledTimes(1);
  });
});
