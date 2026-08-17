// @flow

/*::
export type PlaymeshConfigDiagnosticFile = {|
  filePath: string,
  text: string,
|};
export type PlaymeshConfigDiagnosticResult = {|
  filePath: string,
  text: string,
  files: [PlaymeshConfigDiagnosticFile],
|};
*/

const normalizeEntryPath = (value /*: mixed */) /*: string */ => {
  if (
    typeof value !== 'string' ||
    !value ||
    value.startsWith('/') ||
    value.includes('\\') ||
    value.includes('?') ||
    value.includes('#')
  ) {
    throw new Error('Playmesh 诊断入口路径无效。');
  }
  const segments = value.split('/');
  if (
    segments.some(segment => !segment || segment === '.' || segment === '..') ||
    !/\.html?$/i.test(value)
  ) {
    throw new Error('Playmesh 诊断入口路径无效。');
  }
  return value;
};

const normalizeLocale = (value /*: mixed */) /*: string */ =>
  typeof value === 'string' &&
  /^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$/.test(value)
    ? value
    : 'und';

const escapeHtml = (value /*: string */) /*: string */ =>
  value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');

export const createPlaymeshConfigDiagnosticFile = (
  {
    entryPath,
    locale,
    message,
  } /*: {|
  entryPath: mixed,
  locale: mixed,
  message: mixed,
|} */
) /*: PlaymeshConfigDiagnosticResult */ => {
  const filePath = normalizeEntryPath(entryPath);
  if (typeof message !== 'string' || !message.trim()) {
    throw new Error('Playmesh 诊断文案不能为空。');
  }
  const safeMessage = escapeHtml(message.trim());
  const safeLocale = normalizeLocale(locale);
  const text = `<!doctype html>
<html lang="${safeLocale}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${safeMessage}</title>
  <style>
    html,body{height:100%;margin:0}body{display:grid;place-items:center;background:#202225;color:#f4f4f4;font:16px/1.6 system-ui,sans-serif}main{max-width:40rem;padding:2rem;text-align:center}
  </style>
</head>
<body><main role="alert">${safeMessage}</main></body>
</html>`;
  const file = { filePath, text };
  return { filePath, text, files: [file] };
};
