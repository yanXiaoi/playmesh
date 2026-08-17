// @flow

type MixedRecord = { +[string]: mixed };

export type PlaymeshExternalDownloadFailure = {|
  targetUrl: string,
  stage: string,
  status: number,
  code: string,
  reason: string,
  requestId: string,
  operation: string,
|};

const recordOf = (value: mixed): ?MixedRecord =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value: any)
    : null;

const boundedField = (value: mixed, fallback: string): string => {
  if (typeof value !== 'string' || !value) return fallback;
  const normalized = value.replace(/[^A-Za-z0-9._:-]/g, '_');
  return normalized.slice(0, 160) || fallback;
};

export const sanitizePlaymeshExternalUrl = (value: mixed): string => {
  if (typeof value !== 'string' || !value) return '';
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return '';
    url.username = '';
    url.password = '';
    // Preserve ordinary query parameters because they are part of the
    // actionable download target. Remove only credential-bearing parameters,
    // case-insensitively, including the standard signed URL variants.
    for (const key of [...url.searchParams.keys()]) {
      const normalizedKey = key.toLowerCase().replace(/-/g, '_');
      if (
        /^(?:token|access_token|auth|authorization|signature|sig|key|api_key|apikey|client_secret|secret|password)$/.test(
          normalizedKey
        ) ||
        /^x_(?:amz|goog)_(?:signature|credential|security_token)$/.test(
          normalizedKey
        )
      ) {
        url.searchParams.delete(key);
      }
    }
    url.hash = '';
    return url.toString().slice(0, 768);
  } catch (_) {
    return '';
  }
};

export const normalizePlaymeshExternalDownloadFailure = ({
  rawError,
  targetUrl = '',
  stage = 'external_download',
  operation = 'gdevelop.catalog.artifact.acquire',
}: {|
  rawError: mixed,
  targetUrl?: mixed,
  stage?: string,
  operation?: string,
|}): PlaymeshExternalDownloadFailure => {
  const raw = recordOf(rawError);
  const details = raw && recordOf(raw.details);
  const status =
    raw && Number.isSafeInteger(raw.status) && Number(raw.status) >= 0
      ? Number(raw.status)
      : details &&
        Number.isSafeInteger(details.status) &&
        Number(details.status) >= 0
      ? Number(details.status)
      : 0;
  const code = boundedField(raw && raw.code, 'external_download_failed');
  return {
    targetUrl: sanitizePlaymeshExternalUrl(
      (raw && raw.targetUrl) || (details && details.targetUrl) || targetUrl
    ),
    stage: boundedField(
      (raw && raw.stage) || (details && details.stage),
      stage
    ),
    status,
    code,
    reason: boundedField(
      (raw && raw.reason) || (details && details.reason),
      status > 0 ? `http_${status}` : code
    ),
    requestId: boundedField(
      (raw && raw.requestId) || (details && details.requestId),
      'unavailable'
    ),
    operation: boundedField(
      (raw && raw.operation) || (details && details.operation),
      operation
    ),
  };
};

export const formatPlaymeshExternalDownloadFailure = (
  intro: string,
  failure: PlaymeshExternalDownloadFailure
): string =>
  [
    intro,
    `URL: ${failure.targetUrl || 'unavailable'}`,
    `stage=${failure.stage} status=${failure.status || 0} reason=${
      failure.reason
    } code=${failure.code} requestId=${failure.requestId} operation=${
      failure.operation
    }`,
  ].join('\n');

export const logPlaymeshExternalDownloadFailure = (
  failure: PlaymeshExternalDownloadFailure
): void => {
  console.error(
    '[PlayMesh External Download] ' +
      `target=${failure.targetUrl || 'unavailable'} ` +
      `stage=${failure.stage} status=${failure.status || 0} ` +
      `reason=${failure.reason} code=${failure.code} ` +
      `requestId=${failure.requestId} operation=${failure.operation}`
  );
};
