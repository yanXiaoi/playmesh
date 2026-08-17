import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const sourceFlagIndex = process.argv.indexOf('--source');
if (sourceFlagIndex < 0 || !process.argv[sourceFlagIndex + 1]) {
  throw new Error(
    'Usage: node test-native-file-save-source.mjs --source <patched GDevelop root>'
  );
}

const sourceRoot = path.resolve(process.argv[sourceFlagIndex + 1]);
const holderPath = path.join(
  sourceRoot,
  'newIDE',
  'app',
  'src',
  'Utils',
  'BlobDownloadUrlHolder.js'
);
const source = await readFile(holderPath, 'utf8');

const hookIndex = source.indexOf('__playmeshSaveBlobDownload');
const hookCallIndex = source.indexOf('nativeBlobSaver({ url, filename })');
const webViewGuardIndex = source.indexOf('chrome.webview');
const visibleFailureIndex = source.indexOf('window.alert(message)');
const anchorIndex = source.indexOf("document.createElement('a')");
const clickIndex = source.indexOf('a.click()');

assert.ok(
  hookIndex >= 0,
  'patched Blob holder must detect the native host hook'
);
assert.ok(
  hookCallIndex > hookIndex,
  'the generated Blob URL and dynamic filename must be handed to the host'
);
assert.ok(
  webViewGuardIndex > hookCallIndex && visibleFailureIndex > webViewGuardIndex,
  'a WebView host without the injected hook must fail visibly'
);
assert.ok(
  anchorIndex > visibleFailureIndex && clickIndex > anchorIndex,
  'the ordinary-browser anchor download must remain as the fallback'
);
assert.match(
  source,
  /if \(typeof nativeBlobSaver === 'function'\) \{[\s\S]*?return;[\s\S]*?\}/,
  'native handoff must return before WebView tries the blob anchor'
);
assert.match(
  source,
  /chromeWebView[\s\S]*?native_file_save_bridge_missing[\s\S]*?window\.alert\(message\)[\s\S]*?return;/,
  'the old-host guard must not silently continue into the WebView2 download path'
);

process.stdout.write('Native file save source contract passed.\n');
