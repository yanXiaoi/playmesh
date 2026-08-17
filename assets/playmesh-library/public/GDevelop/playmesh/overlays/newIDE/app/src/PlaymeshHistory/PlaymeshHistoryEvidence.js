// @flow

import type {
  StoredProject,
  StoredProjectResource,
} from '../ProjectsStorage/PlaymeshLocalStorageProvider/PlaymeshProjectStore';
import {
  assertPlaymeshHistoryRestoreBrowserEvidence,
  assertPlaymeshHistoryRestoreResource,
} from './PlaymeshHistoryRestoreProtocol';
import {
  sha256Blob,
  sha256Hex,
} from '../PlaymeshCrypto/PlaymeshSha256';
import type {
  PlaymeshHistoryRestoreBrowserEvidence,
  PlaymeshHistoryRestoreJsonObject,
  PlaymeshHistoryRestoreJsonValue,
  PlaymeshHistoryRestoreResource,
} from './PlaymeshHistoryRestoreProtocol';

/*::
type MixedRecord = { +[string]: mixed };
*/

export class PlaymeshHistoryEvidenceError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshHistoryEvidenceError';
    this.code = code;
  }
}

const fail = (code /*: string */, message /*: string */) /*: empty */ => {
  throw new PlaymeshHistoryEvidenceError(code, message);
};

const asRecord = (value /*: mixed */) /*: ?MixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: MixedRecord */)
    : null;

const canonicalize = (
  value /*: mixed */
) /*: PlaymeshHistoryRestoreJsonValue */ => {
  if (
    value === null ||
    typeof value === 'string' ||
    typeof value === 'boolean'
  ) {
    return value;
  }
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) {
      return fail('invalid_project_json', 'Playmesh 项目 JSON 无效。');
    }
    return value;
  }
  if (Array.isArray(value)) return value.map(canonicalize);
  const record = asRecord(value);
  if (!record) {
    return fail('invalid_project_json', 'Playmesh 项目 JSON 无效。');
  }
  const result /*: PlaymeshHistoryRestoreJsonObject */ = {};
  Object.keys(record)
    .sort()
    .forEach(key => {
      result[key] = canonicalize(record[key]);
    });
  return result;
};

export const encodePlaymeshHistoryCanonicalJson = (
  value /*: mixed */
) /*: Uint8Array */ => {
  const json = JSON.stringify(canonicalize(value));
  if (typeof json !== 'string') {
    return fail('invalid_project_json', 'Playmesh 项目 JSON 无效。');
  }
  return new TextEncoder().encode(json);
};

export const hashPlaymeshHistoryBytes = async (
  bytes /*: ArrayBuffer */
) /*: Promise<string> */ => sha256Hex(bytes);

export const hashPlaymeshHistoryBlob = async (
  blob /*: Blob */
) /*: Promise<string> */ => sha256Blob(blob);

export const hashPlaymeshHistoryJson = async (
  value /*: mixed */
) /*: Promise<string> */ =>
  hashPlaymeshHistoryBytes(encodePlaymeshHistoryCanonicalJson(value).buffer);

export const createPlaymeshHistoryResourceDto = async (
  resource /*: StoredProjectResource */
) /*: Promise<PlaymeshHistoryRestoreResource> */ => {
  const actualHash = await hashPlaymeshHistoryBlob(resource.blob);
  if (resource.contentHash && resource.contentHash !== actualHash) {
    return fail(
      'resource_corrupt',
      `Playmesh 本地资源校验失败：${resource.logicalUrl}`
    );
  }
  const value /*: {|
    logicalId: string,
    name?: string,
    contentHash: string,
    mime: string,
    size: number,
    metadata?: Object,
  |} */ = {
    logicalId: resource.logicalUrl,
    contentHash: actualHash,
    mime: resource.blob.type || 'application/octet-stream',
    size: resource.blob.size,
  };
  if (resource.name !== undefined) value.name = resource.name;
  if (resource.metadata !== undefined) value.metadata = resource.metadata;
  return assertPlaymeshHistoryRestoreResource(value);
};

export const computePlaymeshHistoryBrowserEvidence = async (
  project /*: StoredProject */
) /*: Promise<PlaymeshHistoryRestoreBrowserEvidence> */ => {
  let projectJson /*: mixed */;
  try {
    projectJson = JSON.parse(project.projectJson);
  } catch (_) {
    return fail('invalid_project_json', 'Playmesh 项目 JSON 无效。');
  }
  const resources = [];
  for (const resource of project.resources) {
    resources.push(await createPlaymeshHistoryResourceDto(resource));
  }
  resources.sort((left, right) =>
    left.logicalId < right.logicalId
      ? -1
      : left.logicalId > right.logicalId
      ? 1
      : 0
  );
  return assertPlaymeshHistoryRestoreBrowserEvidence({
    projectJsonHash: await hashPlaymeshHistoryJson(projectJson),
    resourceManifestHash: await hashPlaymeshHistoryJson(resources),
  });
};

export const assertPlaymeshHistoryBrowserEvidenceMatches = (
  actualValue /*: PlaymeshHistoryRestoreBrowserEvidence */,
  expectedValue /*: PlaymeshHistoryRestoreBrowserEvidence */
) /*: void */ => {
  const actual = assertPlaymeshHistoryRestoreBrowserEvidence(actualValue);
  const expected = assertPlaymeshHistoryRestoreBrowserEvidence(expectedValue);
  if (
    actual.projectJsonHash !== expected.projectJsonHash ||
    actual.resourceManifestHash !== expected.resourceManifestHash
  ) {
    return fail(
      'browser_evidence_mismatch',
      'Playmesh 浏览器恢复结果与目标 evidence 不一致。'
    );
  }
};
