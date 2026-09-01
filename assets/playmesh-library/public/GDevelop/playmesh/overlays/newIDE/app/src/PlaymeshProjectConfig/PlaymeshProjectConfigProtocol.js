// @flow

export const PLAYMESH_PROJECT_CONFIG_SCHEMA_VERSION = 2;
export const PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES = 16 * 1024;
export const PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS = 64;
export const PLAYMESH_PROJECT_CONFIG_MAX_TAGS = 5;
export const PLAYMESH_PROJECT_CONFIG_MAX_TAG_LENGTH = 64;

/*::
export type PlaymeshProjectGameType = 'single' | 'online';
export type PlaymeshProjectConfig = {|
  schemaVersion: 2,
  gameId: string,
  revision: number,
  gameType: PlaymeshProjectGameType,
  minPlayers: number,
  maxPlayers: number,
  tags: Array<string>,
  webRuntimeMultithreading: boolean,
  updatedAt: string,
|};
export type PlaymeshProjectConfigReadResponse =
  | {|
      requestId: string,
      status: 'ready',
      config: PlaymeshProjectConfig,
    |}
  | {|
      requestId: string,
      status: 'missing' | 'invalid',
|};
export type PlaymeshProjectConfigPutBody = {|
  schemaVersion: 2,
  gameType: PlaymeshProjectGameType,
  minPlayers: number,
  maxPlayers: number,
  tags: Array<string>,
  webRuntimeMultithreading: boolean,
  expectedRevision: number,
|};
export type PlaymeshProjectConfigErrorEnvelope = {|
  requestId: string,
  code: string,
  message: string,
  currentRevision?: number,
  gameId?: string,
|};
type MixedRecord = { +[string]: mixed };
*/

export class PlaymeshProjectConfigProtocolError extends Error {
  /*:: code: string; */

  constructor(code /*: string */, message /*: string */) {
    super(message);
    this.name = 'PlaymeshProjectConfigProtocolError';
    this.code = code;
  }
}

const fail = (
  code /*: string */ = 'invalid_response',
  message /*: string */ = 'Playmesh 项目配置响应无效。'
) /*: empty */ => {
  throw new PlaymeshProjectConfigProtocolError(code, message);
};

const asRecord = (value /*: mixed */) /*: ?MixedRecord */ =>
  value !== null && typeof value === 'object' && !Array.isArray(value)
    ? (value /*: MixedRecord */)
    : null;

const hasExactKeys = (
  record /*: MixedRecord */,
  expectedKeys /*: $ReadOnlyArray<string> */
) /*: boolean */ => {
  const actualKeys = Object.keys(record);
  return (
    actualKeys.length === expectedKeys.length &&
    actualKeys.every(key => expectedKeys.includes(key))
  );
};

const hasAllowedKeys = (
  record /*: MixedRecord */,
  allowedKeys /*: $ReadOnlyArray<string> */
) /*: boolean */ => Object.keys(record).every(key => allowedKeys.includes(key));

export const validatePlaymeshProjectConfigGameId = (
  gameId /*: mixed */
) /*: string */ => {
  if (typeof gameId !== 'string' || !/^[A-Za-z0-9._-]{1,128}$/.test(gameId)) {
    return fail('invalid_game_id', 'Playmesh 项目标识无效。');
  }
  return gameId;
};

export const validatePlaymeshProjectGameType = (
  gameType /*: mixed */
) /*: PlaymeshProjectGameType */ => {
  if (gameType !== 'single' && gameType !== 'online') {
    return fail('invalid_game_type', 'Playmesh 游戏类型无效。');
  }
  return gameType;
};

const requireRequestId = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string' || !value || value.length > 512) {
    return fail();
  }
  return value;
};

const requireRevision = (value /*: mixed */) /*: number */ => {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 1) {
    return fail();
  }
  return value;
};

const requirePlayerLimits = (
  gameType /*: PlaymeshProjectGameType */,
  minPlayersValue /*: mixed */,
  maxPlayersValue /*: mixed */
) /*: {| minPlayers: number, maxPlayers: number |} */ => {
  if (
    typeof minPlayersValue !== 'number' ||
    !Number.isSafeInteger(minPlayersValue) ||
    typeof maxPlayersValue !== 'number' ||
    !Number.isSafeInteger(maxPlayersValue) ||
    minPlayersValue < 1 ||
    maxPlayersValue < minPlayersValue ||
    maxPlayersValue > PLAYMESH_PROJECT_CONFIG_MAX_PLAYERS ||
    (gameType === 'single' &&
      (minPlayersValue !== 1 || maxPlayersValue !== 1))
  ) {
    return fail('invalid_player_limits', 'Playmesh 玩家人数配置无效。');
  }
  return { minPlayers: minPlayersValue, maxPlayers: maxPlayersValue };
};

export const normalizePlaymeshProjectTags = (
  value /*: mixed */
) /*: Array<string> */ => {
  if (!Array.isArray(value)) {
    return fail('invalid_tags', 'Playmesh 标签格式无效。');
  }
  const normalized /*: Array<string> */ = [];
  const seen /*: Set<string> */ = new Set();
  for (const rawTag of value) {
    if (typeof rawTag !== 'string') {
      return fail('invalid_tags', 'Playmesh 标签格式无效。');
    }
    const tag = rawTag.trim();
    if (!tag || tag.length > PLAYMESH_PROJECT_CONFIG_MAX_TAG_LENGTH) {
      return fail('invalid_tags', 'Playmesh 标签格式无效。');
    }
    if (!seen.has(tag)) {
      seen.add(tag);
      normalized.push(tag);
    }
  }
  if (normalized.length > PLAYMESH_PROJECT_CONFIG_MAX_TAGS) {
    return fail('invalid_tags', 'Playmesh 标签最多 5 个。');
  }
  return normalized;
};

const requireUtcTimestamp = (value /*: mixed */) /*: string */ => {
  if (typeof value !== 'string') return fail();
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?Z$/.exec(
    value
  );
  if (!match) return fail();
  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const hour = Number(match[4]);
  const minute = Number(match[5]);
  const second = Number(match[6]);
  const millisecond = Number((match[7] || '').padEnd(3, '0').slice(0, 3));
  const parsed = new Date(0);
  parsed.setUTCFullYear(year, month - 1, day);
  parsed.setUTCHours(hour, minute, second, millisecond);
  if (
    parsed.getUTCFullYear() !== year ||
    parsed.getUTCMonth() !== month - 1 ||
    parsed.getUTCDate() !== day ||
    parsed.getUTCHours() !== hour ||
    parsed.getUTCMinutes() !== minute ||
    parsed.getUTCSeconds() !== second ||
    parsed.getUTCMilliseconds() !== millisecond
  ) {
    return fail();
  }
  return value;
};

export const assertPlaymeshProjectConfig = (
  value /*: mixed */,
  expectedGameId /*: string */
) /*: PlaymeshProjectConfig */ => {
  const config = asRecord(value);
  if (
    !config ||
    !hasExactKeys(config, [
      'schemaVersion',
      'gameId',
      'revision',
      'gameType',
      'minPlayers',
      'maxPlayers',
      'tags',
      'webRuntimeMultithreading',
      'updatedAt',
    ]) ||
    config.schemaVersion !== PLAYMESH_PROJECT_CONFIG_SCHEMA_VERSION ||
    config.gameId !== expectedGameId ||
    typeof config.webRuntimeMultithreading !== 'boolean'
  ) {
    return fail();
  }
  const webRuntimeMultithreading /*: boolean */ =
    config.webRuntimeMultithreading;
  let gameType /*: PlaymeshProjectGameType */;
  try {
    gameType = validatePlaymeshProjectGameType(config.gameType);
  } catch (_) {
    return fail();
  }
  const { minPlayers, maxPlayers } = requirePlayerLimits(
    gameType,
    config.minPlayers,
    config.maxPlayers
  );
  return {
    schemaVersion: PLAYMESH_PROJECT_CONFIG_SCHEMA_VERSION,
    gameId: expectedGameId,
    revision: requireRevision(config.revision),
    gameType,
    minPlayers,
    maxPlayers,
    tags: normalizePlaymeshProjectTags(config.tags),
    webRuntimeMultithreading,
    updatedAt: requireUtcTimestamp(config.updatedAt),
  };
};

export const assertPlaymeshProjectConfigReadResponse = (
  value /*: mixed */,
  expectedGameIdValue /*: mixed */
) /*: PlaymeshProjectConfigReadResponse */ => {
  const expectedGameId = validatePlaymeshProjectConfigGameId(
    expectedGameIdValue
  );
  const response = asRecord(value);
  if (!response || typeof response.status !== 'string') return fail();
  const requestId = requireRequestId(response.requestId);
  if (response.status === 'ready') {
    if (!hasExactKeys(response, ['requestId', 'status', 'config'])) {
      return fail();
    }
    return {
      requestId,
      status: 'ready',
      config: assertPlaymeshProjectConfig(response.config, expectedGameId),
    };
  }
  if (response.status === 'missing') {
    if (!hasExactKeys(response, ['requestId', 'status'])) return fail();
    return { requestId, status: 'missing' };
  }
  if (response.status === 'invalid') {
    if (!hasExactKeys(response, ['requestId', 'status'])) return fail();
    return { requestId, status: 'invalid' };
  }
  return fail();
};

export const createPlaymeshProjectConfigPutBody = (
  {
    gameType,
    minPlayers,
    maxPlayers,
    tags,
    webRuntimeMultithreading,
    expectedRevision,
  } /*: {|
  gameType: mixed,
  minPlayers: mixed,
  maxPlayers: mixed,
  tags: mixed,
  webRuntimeMultithreading: mixed,
  expectedRevision: mixed,
|} */
) /*: PlaymeshProjectConfigPutBody */ => {
  if (
    typeof webRuntimeMultithreading !== 'boolean' ||
    typeof expectedRevision !== 'number' ||
    !Number.isSafeInteger(expectedRevision) ||
    expectedRevision < 0
  ) {
    return fail('invalid_expected_revision', 'Playmesh 配置 revision 无效。');
  }
  const normalizedGameType = validatePlaymeshProjectGameType(gameType);
  const playerLimits = requirePlayerLimits(
    normalizedGameType,
    minPlayers,
    maxPlayers
  );
  return {
    schemaVersion: PLAYMESH_PROJECT_CONFIG_SCHEMA_VERSION,
    gameType: normalizedGameType,
    minPlayers: playerLimits.minPlayers,
    maxPlayers: playerLimits.maxPlayers,
    tags: normalizePlaymeshProjectTags(tags),
    webRuntimeMultithreading,
    expectedRevision,
  };
};

export const buildPlaymeshProjectConfigUrl = (
  gameId /*: mixed */
) /*: string */ =>
  `/dev/api/gdevelop/projects/${encodeURIComponent(
    validatePlaymeshProjectConfigGameId(gameId)
  )}/config`;

export const parsePlaymeshProjectConfigErrorEnvelope = (
  value /*: mixed */
) /*: PlaymeshProjectConfigErrorEnvelope */ => {
  const response = asRecord(value);
  if (!response || !hasExactKeys(response, ['requestId', 'error'])) {
    return fail();
  }
  const error = asRecord(response.error);
  const code = error && error.code;
  const message = error && error.message;
  if (
    !error ||
    !hasAllowedKeys(error, ['code', 'message', 'currentRevision', 'gameId']) ||
    typeof code !== 'string' ||
    !code ||
    typeof message !== 'string' ||
    !message
  ) {
    return fail();
  }
  const parsed /*: PlaymeshProjectConfigErrorEnvelope */ = {
    requestId: requireRequestId(response.requestId),
    code,
    message,
  };
  const currentRevision = error.currentRevision;
  if (currentRevision !== undefined) {
    if (
      typeof currentRevision !== 'number' ||
      !Number.isSafeInteger(currentRevision) ||
      currentRevision < 0
    ) {
      return fail();
    }
    parsed.currentRevision = currentRevision;
  }
  if (error.gameId !== undefined) {
    parsed.gameId = validatePlaymeshProjectConfigGameId(error.gameId);
  }
  if (
    error.code === 'gdevelop_config_revision_conflict' &&
    parsed.currentRevision === undefined
  ) {
    return fail();
  }
  return parsed;
};

const parseContentLength = (response /*: Response */) /*: ?number */ => {
  const raw = response.headers.get('Content-Length');
  if (raw === null) return null;
  if (!/^\d+$/.test(raw)) return fail();
  const value = Number(raw);
  if (!Number.isSafeInteger(value)) return fail();
  return value;
};

const readBoundedBytes = async (
  response /*: Response */,
  maximumBytes /*: number */
) /*: Promise<Uint8Array> */ => {
  const contentLength = parseContentLength(response);
  if (contentLength != null && contentLength > maximumBytes) {
    return fail('response_too_large', 'Playmesh 项目配置响应超过 16 KiB。');
  }
  // WebView2 has shipped Response streams whose chunks are not recognised by
  // `instanceof Uint8Array` across the native/JS boundary. The Gateway owns
  // this same-origin endpoint and caps its response at 16 KiB, so read the
  // standard ArrayBuffer and enforce the limit again after materialisation.
  const bytes = new Uint8Array(await response.arrayBuffer());
  if (bytes.byteLength > maximumBytes) {
    return fail('response_too_large', 'Playmesh 项目配置响应超过 16 KiB。');
  }
  return bytes;
};

export const readPlaymeshProjectConfigJson = async (
  response /*: Response */
) /*: Promise<mixed> */ => {
  const bytes = await readBoundedBytes(
    response,
    PLAYMESH_PROJECT_CONFIG_MAX_RESPONSE_BYTES
  );
  let text /*: string */;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch (_) {
    return fail();
  }
  try {
    return JSON.parse(text);
  } catch (_) {
    return fail();
  }
};
