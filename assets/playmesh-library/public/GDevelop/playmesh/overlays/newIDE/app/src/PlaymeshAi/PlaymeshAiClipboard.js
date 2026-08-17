// @flow

/*::
export type PlaymeshClipboard = {|
  writeText: string => Promise<void>,
|};
export type PlaymeshClipboardReader = {|
  readText: () => Promise<string>,
|};
export type PlaymeshClipboardFallbackReader = () => Promise<string>;
export type PlaymeshClipboardReadResult =
  | {| ok: true, value: string |}
  | {| ok: false |};
export type PlaymeshLegacyCopy = string => boolean;
*/

/**
 * Keep the same browser/WebView clipboard contract as the source workspace:
 * use the asynchronous Clipboard API first, then a short-lived textarea for
 * engines that expose no clipboard permission surface (notably WebView2).
 *
 * The textarea is synchronously cleared and removed. Callers must never log
 * the copied value because Agent prompts contain the root Developer Token.
 */
export const copyPlaymeshTextWithLegacySelection = (
  value /*: string */
) /*: boolean */ => {
  const documentImplementation = global.document;
  if (
    !documentImplementation ||
    !documentImplementation.body ||
    typeof documentImplementation.createElement !== 'function' ||
    typeof documentImplementation.execCommand !== 'function'
  ) {
    return false;
  }
  const input = documentImplementation.createElement('textarea');
  input.value = value;
  input.setAttribute('aria-hidden', 'true');
  input.setAttribute('readonly', '');
  input.style.position = 'fixed';
  input.style.left = '-10000px';
  input.style.top = '0';
  input.style.opacity = '0';
  documentImplementation.body.appendChild(input);
  let copied = false;
  try {
    input.focus();
    input.select();
    if (typeof input.setSelectionRange === 'function') {
      input.setSelectionRange(0, value.length);
    }
    copied = documentImplementation.execCommand('copy') === true;
  } catch (_) {
    copied = false;
  } finally {
    // Clear the token-bearing prompt before removing the temporary DOM node.
    input.value = '';
    input.remove();
  }
  return copied;
};

export const copyPlaymeshText = async ({
  value,
  clipboard = global.navigator && global.navigator.clipboard,
  legacyCopy = copyPlaymeshTextWithLegacySelection,
} /*: {|
  value: string,
  clipboard?: ?PlaymeshClipboard,
  legacyCopy?: PlaymeshLegacyCopy,
|} */) /*: Promise<boolean> */ => {
  if (clipboard && typeof clipboard.writeText === 'function') {
    try {
      await clipboard.writeText(value);
      return true;
    } catch (_) {
      // WebViews can expose navigator.clipboard but reject every write. The
      // legacy selection path is intentionally still attempted.
    }
  }
  return legacyCopy(value);
};

/**
 * Clipboard reads intentionally have no hidden DOM fallback: browsers do not
 * expose a safe equivalent to execCommand('paste'). A rejected permission is
 * returned as a typed result so callers can clear stale input and avoid
 * accidentally submitting it.
 */
export const readPlaymeshText = async ({
  clipboard = global.navigator && global.navigator.clipboard,
  fallbackRead,
} /*: {|
  clipboard?: ?PlaymeshClipboardReader,
  fallbackRead?: PlaymeshClipboardFallbackReader,
|} */) /*: Promise<PlaymeshClipboardReadResult> */ => {
  if (clipboard && typeof clipboard.readText === 'function') {
    try {
      const value = await clipboard.readText();
      if (typeof value === 'string') return { ok: true, value };
    } catch (_) {
      // App WebViews can expose navigator.clipboard while rejecting reads.
      // Fall through to the authenticated local App bridge when supplied.
    }
  }
  if (fallbackRead) {
    try {
      const value = await fallbackRead();
      if (typeof value === 'string') return { ok: true, value };
    } catch (_) {
      // The caller reports one controlled clipboard diagnostic. Clipboard
      // contents are intentionally never attached to it.
    }
  }
  return { ok: false };
};

export default copyPlaymeshText;
