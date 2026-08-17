import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  BRAND_MARKER,
  GDEVELOP_DISTRIBUTION_DISCLAIMER,
  applyPlaymeshVisualEditorBrand,
  assertWebIdeDistributionDisclaimer,
  auditPlaymeshVisualEditorBrand,
} from '../scripts/webide-distribution-compliance-lib.mjs';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(testDirectory, '..');
const repositoryRoot = path.resolve(playmeshDirectory, '../../../../..');
const temporaryRoot = await mkdtemp(
  path.join(tmpdir(), 'playmesh-webide-compliance-')
);

try {
  const completeDisclaimer = `It is ${GDEVELOP_DISTRIBUTION_DISCLAIMER.english}. ${GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese}。`;
  assert.doesNotThrow(() =>
    assertWebIdeDistributionDisclaimer({
      notices: completeDisclaimer,
      label: 'generator positive fixture',
    })
  );
  for (const [marker, replacement] of [
    [
      GDEVELOP_DISTRIBUTION_DISCLAIMER.english,
      'not affiliated with or endorsed by GDevelop Ltd',
    ],
    [
      GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese,
      '与 GDevelop Ltd 无隶属关系，也未获其背书',
    ],
  ]) {
    assert.throws(
      () =>
        assertWebIdeDistributionDisclaimer({
          notices: completeDisclaimer.replace(marker, replacement),
          label: 'generator negative fixture',
        }),
      new RegExp(`missing required marker: ${marker}`)
    );
  }

  const distributionDirectory = path.join(temporaryRoot, 'distribution');
  await mkdir(distributionDirectory, { recursive: true });
  await writeFile(
    path.join(distributionDirectory, 'index.html'),
    `<!doctype html><html><head>
<title>GDevelop 5</title>
<meta name="title" content="GDevelop game making app" />
<meta property="og:title" content="GDevelop game making app" />
<meta name="description" content="Build your own game super fast and without programming. Publish on mobile, desktop and on the web." />
<meta property="og:description" content="Build your own game super fast and without programming. Publish on mobile, desktop and on the web." />
<meta property="og:url" content="https://gdevelop.io" />
<meta property="og:image" content="./GDevelop-editor-thumbnail.png" />
<link rel="apple-touch-icon" href="./apple-touch-icon.png" />
<link rel="icon" href="./favicon-32x32.png" />
<link rel="icon" href="./favicon-16x16.png" />
<style>.logo {
  background-image: url("data:image/svg+xml,fixture");
}</style></head><body><noscript>Enable JavaScript.</noscript></body></html>\n`
  );
  await writeFile(
    path.join(distributionDirectory, 'manifest.json'),
    `${JSON.stringify({
      short_name: 'GDevelop',
      name: 'GDevelop - Create games without programming',
      screenshots: [{ src: './GDevelop-editor-thumbnail.png' }],
      icons: [{ src: './favicon-32x32.png', sizes: '32x32' }],
    })}\n`
  );
  const logoPath = path.join(
    repositoryRoot,
    'assets',
    'branding',
    'playmesh-mark.png'
  );
  const parsedWebIdeLock = JSON.parse(
    await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
  );
  await applyPlaymeshVisualEditorBrand({
    directory: distributionDirectory,
    logoPath,
    repositoryRoot,
    brandEvidence: parsedWebIdeLock.compliance.playmeshBrandAsset,
  });
  const brandedPreBuildIndex = await readFile(
    path.join(distributionDirectory, 'index.html'),
    'utf8'
  );
  const builtBrandPostimage = brandedPreBuildIndex.replace(BRAND_MARKER, '');
  await writeFile(
    path.join(distributionDirectory, 'index.html'),
    builtBrandPostimage,
    'utf8'
  );
  await applyPlaymeshVisualEditorBrand({
    directory: distributionDirectory,
    logoPath,
    repositoryRoot,
    brandEvidence: parsedWebIdeLock.compliance.playmeshBrandAsset,
  });
  const reenteredBrandPostimage = await readFile(
    path.join(distributionDirectory, 'index.html'),
    'utf8'
  );
  assert.ok(reenteredBrandPostimage.includes(BRAND_MARKER));

  for (const [label, invalidIndex] of [
    [
      'mixed official and Playmesh identity',
      builtBrandPostimage.replace(
        '<meta name="title" content="Playmesh Visual Editor" />',
        '<meta name="title" content="GDevelop game making app" />'
      ),
    ],
    [
      'unknown third product identity',
      builtBrandPostimage.replace(
        '<title>Playmesh Visual Editor</title>',
        '<title>Unknown Visual Editor</title>'
      ),
    ],
    [
      'duplicate Playmesh identity',
      builtBrandPostimage.replace(
        '<title>Playmesh Visual Editor</title>',
        '<title>Playmesh Visual Editor</title><title>Playmesh Visual Editor</title>'
      ),
    ],
  ]) {
    await writeFile(
      path.join(distributionDirectory, 'index.html'),
      invalidIndex,
      'utf8'
    );
    await assert.rejects(
      applyPlaymeshVisualEditorBrand({
        directory: distributionDirectory,
        logoPath,
        repositoryRoot,
        brandEvidence: parsedWebIdeLock.compliance.playmeshBrandAsset,
      }),
      undefined,
      label
    );
  }
  await writeFile(
    path.join(distributionDirectory, 'index.html'),
    reenteredBrandPostimage,
    'utf8'
  );
  await auditPlaymeshVisualEditorBrand({ directory: distributionDirectory });

  const brandedIndex = await readFile(
    path.join(distributionDirectory, 'index.html'),
    'utf8'
  );
  assert.match(brandedIndex, /<title>Playmesh Visual Editor<\/title>/);
  assert.ok(brandedIndex.includes(BRAND_MARKER));
  assert.match(brandedIndex, /基于 GDevelop 开源技术的非官方修改版/);
  assert.doesNotMatch(brandedIndex, /<title>GDevelop/);
  assert.doesNotMatch(brandedIndex, /content="https:\/\/gdevelop\.io"/);
  assert.doesNotMatch(brandedIndex, /GDevelop-editor-thumbnail\.png/);

  const brandedManifest = JSON.parse(
    await readFile(path.join(distributionDirectory, 'manifest.json'), 'utf8')
  );
  assert.equal(brandedManifest.name, 'Playmesh Visual Editor');
  assert.equal(brandedManifest.short_name, 'Playmesh Editor');
  assert.equal(brandedManifest.icons[0].src, './playmesh-logo.png');
  assert.equal(Object.hasOwn(brandedManifest, 'screenshots'), false);
  await readFile(path.join(distributionDirectory, 'playmesh-logo.png'));

  const [
    settingsSource,
    launcherSource,
    webIdeNoticeSource,
    en,
    zh,
    lockText,
    fullNotices,
  ] =
    await Promise.all([
      readFile(
        path.join(repositoryRoot, 'lib', 'features', 'settings', 'settings_page.dart'),
        'utf8'
      ),
      readFile(
        path.join(repositoryRoot, 'lib', 'features', 'developer', 'game_creation_page.dart'),
        'utf8'
      ),
      readFile(
        path.join(
          playmeshDirectory,
          'overlays',
          'newIDE',
          'app',
          'src',
          'MainFrame',
          'EditorContainers',
          'PlaymeshHomePage',
          'PlaymeshDistributionNotice.js'
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
      readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8'),
      readFile(
        path.join(
          repositoryRoot,
          'assets',
          'legal',
          'gdevelop-webide-third-party-notices.md'
        ),
        'utf8'
      ),
    ]);
  for (const forbiddenSettingsContract of [
    'settings.open_source_notices',
    'showGDevelopDistributionNotices',
    'gdevelop_notices_dialog.dart',
    'THIRD_PARTY_NOTICES',
  ]) {
    assert.doesNotMatch(settingsSource, new RegExp(forbiddenSettingsContract));
    assert.doesNotMatch(en, new RegExp(forbiddenSettingsContract));
    assert.doesNotMatch(zh, new RegExp(forbiddenSettingsContract));
  }
  const noticesDialogSource = await readFile(
    path.join(
      repositoryRoot,
      'lib',
      'features',
      'developer',
      'gdevelop_notices_dialog.dart'
    ),
    'utf8'
  );
  const pubspec = await readFile(path.join(repositoryRoot, 'pubspec.yaml'), 'utf8');
  assert.doesNotMatch(noticesDialogSource, /rootBundle|assets\/legal/);
  assert.match(noticesDialogSource, /GDevelopWebIdeInstalledNotices/);
  assert.doesNotMatch(pubspec, /^\s*- assets\/legal\/$/m);
  const pipelineSource = await readFile(
    path.join(playmeshDirectory, 'scripts', 'webide-pipeline.mjs'),
    'utf8'
  );
  const releaseCheckSource = pipelineSource.slice(
    pipelineSource.indexOf('if (parsed.command === "release-check")')
  );
  assert.doesNotMatch(releaseCheckSource, /--allow-pending-downloads/);
  assert.match(
    pipelineSource,
    /publishFormalArtifacts[\s\S]*\? \[\][\s\S]*--allow-pending-downloads/
  );
  const productionWorkflow = await readFile(
    path.join(repositoryRoot, '.github', 'workflows', 'build-gdevelop-webide.yml'),
    'utf8'
  );
  assert.doesNotMatch(productionWorkflow, /--allow-pending-downloads/);
  for (const argumentName of [
    '--libgd-kind',
    '--libgd-source',
    '--libgd-upstream-version',
    '--libgd-js-sha256',
    '--libgd-js-size',
    '--libgd-wasm-sha256',
    '--libgd-wasm-size',
    '--libgd-user-decision',
  ]) {
    assert.match(productionWorkflow, new RegExp(argumentName));
  }
  assert.match(launcherSource, /creator\.gdevelop_notices/);
  assert.match(launcherSource, /showGDevelopDistributionNotices/);
  assert.match(webIdeNoticeSource, /\.\/THIRD_PARTY_NOTICES\.md/);
  assert.match(
    webIdeNoticeSource,
    /playmeshMessages\.homeUnofficialNotice/,
    'WebIDE notice must use the localized Playmesh message instead of embedding a second disclaimer copy'
  );
  for (const source of [en, fullNotices]) {
    assert.ok(source.includes(GDEVELOP_DISTRIBUTION_DISCLAIMER.english));
  }
  for (const source of [zh, fullNotices]) {
    assert.ok(source.includes(GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese));
  }
  assert.ok(fullNotices.length > 20000);
  for (const requiredNoticeEvidence of [
    'GDevelop upstream Extensions/LICENSE.md',
    'Firebase runtime LICENSE.md',
    'WebIDE Firebase 9.0.0-beta.2 package Apache-2.0 evidence',
    'DialogueTree bundled bondage.js LICENSE',
    'BBText pixi-multistyle-text byte and license evidence',
    'GDJS runtime legal material',
    'Webpack-emitted attribution',
    'exact upstream code revision is unknown',
    'Playmesh logo build provenance',
  ]) {
    assert.match(fullNotices, new RegExp(requiredNoticeEvidence));
  }
  assert.doesNotMatch(fullNotices, /\bpending\b/i);

  const parsedLock = JSON.parse(lockText);
  assert.deepEqual(parsedLock.compliance.monaco, {
    declaredVersion: '0.14.3',
    loaderReportedVersion: '0.14.6',
    loaderSha256:
      '0c272c30972d036de6dec5e9d51ac358c11be58b4eef0fba4c85151f30e72ba6',
  });

  process.stdout.write(
    'WebIDE distribution compliance contracts passed: product identity is ' +
      'Playmesh-scoped, notices are offline in visual-development surfaces, ' +
      'Settings/About has no GDevelop notice entry, and Monaco evidence is frozen.\n'
  );
} finally {
  await rm(temporaryRoot, { recursive: true, force: true });
}
