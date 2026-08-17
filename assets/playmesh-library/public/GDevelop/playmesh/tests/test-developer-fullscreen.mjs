import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(
  playmeshDirectory,
  '..',
  '..',
  '..',
  '..',
  '..'
);
const overlayRoot = path.join(
  playmeshDirectory,
  'overlays',
  'newIDE',
  'app',
  'src'
);

const [buttonSource, integrationSource, sourcePolicy, workspaceSource, deviceSource, zhSource, enSource] =
  await Promise.all([
    readFile(
      path.join(
        overlayRoot,
        'PlaymeshFullscreen',
        'PlaymeshDeveloperFullscreenButton.js'
      ),
      'utf8'
    ),
    readFile(
      path.join(overlayRoot, 'PlaymeshAi', 'PlaymeshAiIntegration.js'),
      'utf8'
    ),
    readFile(path.join(playmeshDirectory, 'scripts', 'apply-source-policy.mjs'), 'utf8'),
    readFile(
      path.join(
        repositoryRoot,
        'lib',
        'features',
        'developer',
        'developer_workspace_page.dart'
      ),
      'utf8'
    ),
    readFile(
      path.join(
        repositoryRoot,
        'lib',
        'core',
        'platform',
        'app_device_service.dart'
      ),
      'utf8'
    ),
    readFile(
      path.join(
        repositoryRoot,
        'assets',
        'playmesh-localization',
        'locales',
        'zh-CN',
        'app.json'
      ),
      'utf8'
    ),
    readFile(
      path.join(
        repositoryRoot,
        'assets',
        'playmesh-localization',
        'locales',
        'en-US',
        'app.json'
      ),
      'utf8'
    ),
  ]);

for (const marker of [
  '__playmeshDeveloperFullscreen',
  'document.fullscreenElement',
  'document.exitFullscreen()',
  'const documentElement = document.documentElement',
  'documentElement.requestFullscreen()',
  'playmeshdeveloperfullscreenchange',
  'playmeshMessages.fullscreenEnter',
  'playmeshMessages.fullscreenExit',
  'id="playmesh-developer-fullscreen-toggle"',
]) {
  assert.ok(buttonSource.includes(marker), `Missing fullscreen UI contract: ${marker}`);
}
assert.match(integrationSource, /PlaymeshDeveloperFullscreenButton/);
assert.match(integrationSource, /isRightMostPane \? \([\s\S]*?<PlaymeshDeveloperFullscreenButton/);
assert.match(sourcePolicy, /<PlaymeshAiTitlebarActions/);

for (const marker of [
  'widget.deviceService.isFullscreen()',
  'widget.deviceService.setFullscreen(enabled)',
  'appBar: _fullscreen',
  'canPop: !_fullscreen',
  'playmeshDeveloperFullscreenScript',
]) {
  assert.ok(workspaceSource.includes(marker), `Missing native host contract: ${marker}`);
}
assert.match(deviceSource, /Future<bool> isFullscreen\(\)/);
assert.match(deviceSource, /windowManager\.isFullScreen\(\)/);
assert.match(deviceSource, /FullScreen\.isFullScreenForced/);

const zh = JSON.parse(zhSource);
const en = JSON.parse(enSource);
assert.equal(zh['workspace.gdevelop_fullscreen.enter'], '进入全屏');
assert.equal(zh['workspace.gdevelop_fullscreen.exit'], '退出全屏');
assert.equal(en['workspace.gdevelop_fullscreen.enter'], 'Enter fullscreen');
assert.equal(en['workspace.gdevelop_fullscreen.exit'], 'Exit fullscreen');

process.stdout.write('Playmesh developer fullscreen contracts passed.\n');
