const unsafeSchemePattern = /^(?:javascript|data|vbscript|file):/i;
const allowedExternalHosts = new Set(['raw.githubusercontent.com']);

export const getSafePlaymeshExtensionSourceUrl = ({
  value,
  baseUrl,
}) => {
  if (
    typeof value !== 'string' ||
    !value ||
    /[\u0000-\u001f\u007f]/.test(value) ||
    unsafeSchemePattern.test(value.trim())
  ) {
    return null;
  }
  let parsed;
  let base;
  try {
    base = new URL(baseUrl);
    parsed = new URL(value, base);
  } catch (_) {
    return null;
  }
  if (parsed.username || parsed.password) return null;
  if (parsed.origin === base.origin && /^https?:$/.test(parsed.protocol)) {
    return {
      kind: 'internal',
      url: parsed.href,
      provider: 'Playmesh App',
      revision: '',
      displayUrl: value,
    };
  }
  if (
    parsed.protocol !== 'https:' ||
    !allowedExternalHosts.has(parsed.hostname) ||
    parsed.port
  ) {
    return null;
  }
  return {
    kind: 'external',
    url: parsed.href,
    provider: parsed.hostname,
    displayUrl: parsed.href,
  };
};
