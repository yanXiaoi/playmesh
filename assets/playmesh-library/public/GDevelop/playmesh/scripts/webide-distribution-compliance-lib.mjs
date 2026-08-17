import { createHash } from 'node:crypto';
import { cp, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

const NOTICE_ENTRY = 'THIRD_PARTY_NOTICES.md';
const BRAND_ICON_ENTRY = 'playmesh-logo.png';
const BRAND_MARKER = '<!-- PLAYMESH_VISUAL_EDITOR_IDENTITY -->';
const BRAND_PIXEL_CONTRACT = 'playmesh-transparent-mark-v1';
const GDEVELOP_DISTRIBUTION_DISCLAIMER = Object.freeze({
  english: 'not affiliated with, sponsored by, or endorsed by GDevelop Ltd',
  chinese: '与 GDevelop Ltd 无隶属关系、无赞助关系，也未获其背书',
});

const assertPlaymeshTransparentPngHeader = (bytes, label) => {
  const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  if (
    bytes.length < 33 ||
    !bytes.subarray(0, 8).equals(pngSignature) ||
    bytes.toString('ascii', 12, 16) !== 'IHDR' ||
    bytes.readUInt32BE(16) !== 1024 ||
    bytes.readUInt32BE(20) !== 1024 ||
    ![4, 6].includes(bytes[25])
  ) {
    throw new Error(`${label} must be a 1024x1024 PNG with an alpha channel`);
  }
};

const sentenceCase = value => value[0].toUpperCase() + value.slice(1);

export const assertWebIdeDistributionDisclaimer = ({
  notices,
  label,
  requiredLanguages = Object.keys(GDEVELOP_DISTRIBUTION_DISCLAIMER),
}) => {
  for (const language of requiredLanguages) {
    const marker = GDEVELOP_DISTRIBUTION_DISCLAIMER[language];
    if (!marker) {
      throw new Error(`${label} requested an unknown disclaimer language: ${language}`);
    }
    if (!notices.includes(marker)) {
      throw new Error(`${label} is missing required marker: ${marker}`);
    }
  }
};

const sha256Text = value =>
  createHash('sha256').update(Buffer.from(value, 'utf8')).digest('hex');
const sha256Bytes = value => createHash('sha256').update(value).digest('hex');

const readRequiredText = async (filePath, label) => {
  let value;
  try {
    value = await readFile(filePath, 'utf8');
  } catch (error) {
    throw new Error(`${label} is missing: ${filePath}`, { cause: error });
  }
  if (!value.trim()) throw new Error(`${label} is empty: ${filePath}`);
  return value.replace(/\r\n/g, '\n').trimEnd();
};

const replaceExactlyOnce = (source, pattern, replacement, label) => {
  const matches = source.match(new RegExp(pattern.source, pattern.flags + 'g'));
  if (!matches || matches.length !== 1) {
    throw new Error(`${label} expected exactly once, found ${matches?.length || 0}`);
  }
  return source.replace(pattern, replacement);
};

const countMatches = (source, pattern) =>
  source.match(new RegExp(pattern.source, pattern.flags + 'g'))?.length || 0;

const assertExactlyOnce = (source, pattern, label) => {
  const count = countMatches(source, pattern);
  if (count !== 1) {
    throw new Error(`${label} expected exactly once, found ${count}`);
  }
};

const assertPlaymeshBrandPostimage = html => {
  for (const [label, pattern] of [
    ['Playmesh title metadata', /<meta name="title" content="Playmesh Visual Editor"\s*\/>/],
    ['Playmesh OpenGraph title', /<meta property="og:title" content="Playmesh Visual Editor"\s*\/>/],
    [
      'Playmesh description metadata',
      /<meta name="description"\s+content="Unofficial Playmesh visual editor based on GDevelop open-source technology\."\s*\/>/,
    ],
    [
      'Playmesh OpenGraph description',
      /<meta property="og:description"\s+content="Unofficial Playmesh visual editor based on GDevelop open-source technology\."\s*\/>/,
    ],
    [
      'Playmesh social product image',
      /<meta property="og:image" content="\.\/playmesh-logo\.png"\s*\/>/,
    ],
    ['Playmesh loading logo', /background-image:\s*url\("\.\/playmesh-logo\.png"\);/],
    [
      'Playmesh loading logo size',
      /background-size:\s*min\(42vw,\s*220px\) auto;/,
    ],
  ]) {
    assertExactlyOnce(html, pattern, label);
  }
  const productUrlCount = countMatches(
    html,
    /<meta property="og:url"[^>]*>/
  );
  if (productUrlCount !== 0) {
    throw new Error(
      `Playmesh product URL postimage expected no og:url metadata, found ${productUrlCount}`
    );
  }
  for (const phrase of [
    'Unofficial modified distribution based on GDevelop open-source technology.',
    `${sentenceCase(GDEVELOP_DISTRIBUTION_DISCLAIMER.english)}.`,
    `基于 GDevelop 开源技术的非官方修改版，${GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese}。`,
  ]) {
    if (!html.includes(phrase)) {
      throw new Error(`Playmesh noscript product identity postimage is missing: ${phrase}`);
    }
  }
};

const walkFiles = async directory => {
  const output = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const entryPath = path.join(directory, entry.name);
    if (entry.isDirectory()) output.push(...(await walkFiles(entryPath)));
    else if (entry.isFile()) output.push(entryPath);
  }
  return output;
};

const relativeSlash = (root, filePath) =>
  path.relative(root, filePath).split(path.sep).join('/');

const packageVersion = (lock, name) =>
  lock.packages?.[`node_modules/${name}`]?.version || '';

const assertPackageVersion = (lock, name, expected) => {
  const actual = packageVersion(lock, name);
  if (actual !== expected) {
    throw new Error(
      `Third-party notice identity changed for ${name}: expected ${expected}, got ${actual || 'missing'}`
    );
  }
};

export const applyPlaymeshVisualEditorBrand = async ({
  directory,
  logoPath,
  repositoryRoot,
  brandEvidence,
}) => {
  if (
    !repositoryRoot ||
    !brandEvidence ||
    brandEvidence.rightsEvidence !== 'not-asserted-by-build-system' ||
    !/^[a-f0-9]{64}$/.test(brandEvidence.sourceSha256 || '')
  ) {
    throw new Error('Playmesh brand asset provenance is missing or makes an unsupported rights claim');
  }
  const evidencedLogoPath = path.resolve(repositoryRoot, brandEvidence.sourcePath || '');
  if (path.resolve(logoPath) !== evidencedLogoPath) {
    throw new Error('Playmesh brand asset path does not match webide-lock evidence');
  }
  const logoBytes = await readFile(evidencedLogoPath);
  if (sha256Bytes(logoBytes) !== brandEvidence.sourceSha256) {
    throw new Error('Playmesh brand source asset bytes changed; ownership is not inferred by this check');
  }
  if (
    brandEvidence.pixelContract !== undefined &&
    brandEvidence.pixelContract !== BRAND_PIXEL_CONTRACT
  ) {
    throw new Error('Playmesh brand source has an unsupported pixel contract');
  }
  if (brandEvidence.pixelContract === BRAND_PIXEL_CONTRACT) {
    assertPlaymeshTransparentPngHeader(logoBytes, 'Playmesh brand source');
  }
  const indexPath = path.join(directory, 'index.html');
  const manifestPath = path.join(directory, 'manifest.json');
  let html = await readRequiredText(indexPath, 'WebIDE index');
  const officialTitlePattern = /<title>GDevelop 5<\/title>/;
  const playmeshTitlePattern = /<title>Playmesh Visual Editor<\/title>/;
  const officialTitleCount = countMatches(html, officialTitlePattern);
  const playmeshTitleCount = countMatches(html, playmeshTitlePattern);
  const brandMarkerCount = countMatches(
    html,
    /<!-- PLAYMESH_VISUAL_EDITOR_IDENTITY -->/
  );

  if (
    officialTitleCount === 1 &&
    playmeshTitleCount === 0 &&
    brandMarkerCount === 0
  ) {
    html = replaceExactlyOnce(
      html,
      officialTitlePattern,
      `${BRAND_MARKER}\n    <title>Playmesh Visual Editor</title>`,
      'official product title'
    );
    html = replaceExactlyOnce(
      html,
      /<meta name="title" content="GDevelop game making app"\s*\/>/,
      '<meta name="title" content="Playmesh Visual Editor" />',
      'official title metadata'
    );
    html = replaceExactlyOnce(
      html,
      /<meta property="og:title" content="GDevelop game making app"\s*\/>/,
      '<meta property="og:title" content="Playmesh Visual Editor" />',
      'official OpenGraph title'
    );
    html = replaceExactlyOnce(
      html,
      /<meta name="description"\s+content="Build your own game super fast and without programming\. Publish on mobile, desktop and on the web\."\s*\/>/,
      '<meta name="description" content="Unofficial Playmesh visual editor based on GDevelop open-source technology." />',
      'official description metadata'
    );
    html = replaceExactlyOnce(
      html,
      /<meta property="og:description"\s+content="Build your own game super fast and without programming\. Publish on mobile, desktop and on the web\."\s*\/>/,
      '<meta property="og:description" content="Unofficial Playmesh visual editor based on GDevelop open-source technology." />',
      'official OpenGraph description'
    );
    html = replaceExactlyOnce(
      html,
      /\s*<meta property="og:url" content="https:\/\/gdevelop\.io"\s*\/>/,
      '',
      'official product URL metadata'
    );
    html = replaceExactlyOnce(
      html,
      /<meta property="og:image" content="[^\"]*GDevelop-editor-thumbnail\.png"\s*\/>/,
      '<meta property="og:image" content="./playmesh-logo.png" />',
      'official social product image'
    );
    html = html
      .replace(/href="[^\"]*apple-touch-icon\.png"/, 'href="./playmesh-logo.png"')
      .replace(/href="[^\"]*favicon-32x32\.png"/, 'href="./playmesh-logo.png"')
      .replace(/href="[^\"]*favicon-16x16\.png"/, 'href="./playmesh-logo.png"');
    html = replaceExactlyOnce(
      html,
      /\s*background-image: url\("data:image\/svg\+xml,[^\"]+"\);/,
      '\n        background-image: url("./playmesh-logo.png");\n        background-size: min(42vw, 220px) auto;',
      'official loading logo'
    );
    html = replaceExactlyOnce(
      html,
      /<noscript>[\s\S]*?<\/noscript>/,
      `<noscript>
      <div style="font-family: sans-serif; padding: 15px;">
        <p><strong>Playmesh Visual Editor / Playmesh 可视化编辑器</strong></p>
        <p>Unofficial modified distribution based on GDevelop open-source technology. ${sentenceCase(GDEVELOP_DISTRIBUTION_DISCLAIMER.english)}.</p>
        <p>基于 GDevelop 开源技术的非官方修改版，${GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese}。</p>
      </div>
    </noscript>`,
      'official noscript product identity'
    );
  } else if (
    officialTitleCount === 0 &&
    playmeshTitleCount === 1 &&
    brandMarkerCount <= 1
  ) {
    assertPlaymeshBrandPostimage(html);
    if (brandMarkerCount === 0) {
      html = replaceExactlyOnce(
        html,
        playmeshTitlePattern,
        `${BRAND_MARKER}\n    <title>Playmesh Visual Editor</title>`,
        'Playmesh product title postimage'
      );
    }
  } else {
    throw new Error(
      'WebIDE product identity must be exactly one official preimage or one ' +
        `Playmesh postimage (official titles: ${officialTitleCount}, ` +
        `Playmesh titles: ${playmeshTitleCount}, markers: ${brandMarkerCount})`
    );
  }

  const forbiddenIdentity = [
    '<title>GDevelop',
    'content="https://gdevelop.io"',
    'GDevelop-editor-thumbnail.png',
    "viewBox='0 0 708 563'",
  ];
  for (const value of forbiddenIdentity) {
    if (html.includes(value)) {
      throw new Error(`Official GDevelop product identity remained in index.html: ${value}`);
    }
  }
  if (!html.includes('Playmesh Visual Editor') || !html.includes(BRAND_MARKER)) {
    throw new Error('Playmesh visual editor identity is missing from index.html');
  }
  await writeFile(indexPath, `${html.trimEnd()}\n`, 'utf8');

  const manifest = JSON.parse(
    await readRequiredText(manifestPath, 'WebIDE PWA manifest')
  );
  manifest.short_name = 'Playmesh Editor';
  manifest.name = 'Playmesh Visual Editor';
  manifest.description =
    'Unofficial Playmesh visual editor based on GDevelop open-source technology.';
  manifest.icons = [
    { src: './playmesh-logo.png', sizes: '1024x1024', type: 'image/png' },
  ];
  delete manifest.screenshots;
  if (JSON.stringify(manifest).includes('GDevelop-editor-thumbnail')) {
    throw new Error('Official GDevelop product image remained in manifest.json');
  }
  await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  const copiedLogoPath = path.join(directory, BRAND_ICON_ENTRY);
  await cp(logoPath, copiedLogoPath);
  if (sha256Bytes(await readFile(copiedLogoPath)) !== brandEvidence.sourceSha256) {
    throw new Error('Copied Playmesh brand asset does not match its repository source');
  }
};

export const auditPlaymeshVisualEditorBrand = async ({ directory }) => {
  const shellFiles = [
    path.join(directory, 'index.html'),
    path.join(directory, 'manifest.json'),
  ];
  const javascriptFiles = (await walkFiles(directory)).filter(filePath =>
    /(?:^|[\\/])static[\\/]js[\\/].+\.js$/.test(filePath)
  );
  const prohibited = [
    ['official HTML title', /<title>\s*GDevelop\b/i],
    ['official product metadata', /GDevelop game making app/i],
    ['official product thumbnail', /GDevelop-editor-thumbnail\.png/i],
    ['official application menu identity', /(?:label:|label=)\s*(?:i18n\._\(t)?[`'"]GDevelop 5[`'"]/],
  ];
  for (const filePath of [...shellFiles, ...javascriptFiles]) {
    const value = await readRequiredText(filePath, 'brand-audited build UI');
    for (const [label, pattern] of prohibited) {
      if (pattern.test(value)) {
        throw new Error(`${label} remained in build-visible UI: ${relativeSlash(directory, filePath)}`);
      }
    }
  }
  const index = await readRequiredText(shellFiles[0], 'WebIDE index');
  if (
    !index.includes('Playmesh Visual Editor') ||
    !index.includes('Unofficial modified distribution based on GDevelop') ||
    !index.includes(`${sentenceCase(GDEVELOP_DISTRIBUTION_DISCLAIMER.english)}.`) ||
    !index.includes(`${GDEVELOP_DISTRIBUTION_DISCLAIMER.chinese}。`)
  ) {
    throw new Error('Build-visible product identity or non-affiliation statement is incomplete');
  }
};

export const generateWebIdeThirdPartyNotices = async ({
  buildDirectory,
  sourceDirectory,
  runtimeDirectory,
  baseNoticePath,
  lock,
}) => {
  const baseNotice = await readRequiredText(baseNoticePath, 'WebIDE notice base');
  assertWebIdeDistributionDisclaimer({
    notices: baseNotice,
    label: 'WebIDE notice base',
  });
  const expectedVersion = lock?.upstream?.tag?.replace(/^v/, '');
  const expectedCommit = lock?.upstream?.commit;
  if (
    !expectedVersion ||
    !expectedCommit ||
    !baseNotice.includes(`GDevelop ${expectedVersion}`) ||
    !baseNotice.includes(expectedCommit) ||
    /\bpending\b/i.test(baseNotice)
  ) {
    throw new Error('WebIDE notice base is stale, incomplete, or pending');
  }

  const appDirectory = path.join(sourceDirectory, 'newIDE', 'app');
  const repositoryRoot = path.resolve(path.dirname(baseNoticePath), '..', '..');
  const brandEvidence = lock?.compliance?.playmeshBrandAsset;
  if (
    !brandEvidence ||
    brandEvidence.rightsEvidence !== 'not-asserted-by-build-system' ||
    !/^[a-f0-9]{64}$/.test(brandEvidence.sourceSha256 || '')
  ) {
    throw new Error('Playmesh brand asset evidence is missing or invalid');
  }
  const brandSourcePath = path.resolve(repositoryRoot, brandEvidence.sourcePath || '');
  const brandSourceBytes = await readFile(brandSourcePath);
  if (sha256Bytes(brandSourceBytes) !== brandEvidence.sourceSha256) {
    throw new Error('Playmesh brand asset source hash changed');
  }
  if (
    brandEvidence.pixelContract !== undefined &&
    brandEvidence.pixelContract !== BRAND_PIXEL_CONTRACT
  ) {
    throw new Error('Playmesh brand source has an unsupported pixel contract');
  }
  if (brandEvidence.pixelContract === BRAND_PIXEL_CONTRACT) {
    assertPlaymeshTransparentPngHeader(brandSourceBytes, 'Playmesh brand source');
  }
  const lockJson = JSON.parse(
    await readRequiredText(path.join(appDirectory, 'package-lock.json'), 'npm lock')
  );
  const monacoEvidence = lock?.compliance?.monaco;
  if (
    !monacoEvidence ||
    Object.keys(monacoEvidence).sort().join(',') !==
      'declaredVersion,loaderReportedVersion,loaderSha256' ||
    !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(
      monacoEvidence.declaredVersion || ''
    ) ||
    !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(
      monacoEvidence.loaderReportedVersion || ''
    ) ||
    !/^[a-f0-9]{64}$/.test(monacoEvidence.loaderSha256 || '')
  ) {
    throw new Error('webide-lock Monaco compliance evidence is missing or invalid');
  }
  for (const [name, version] of [
    ['monaco-editor', monacoEvidence.declaredVersion],
    ['react', '18.2.0'],
    ['react-dom', '18.2.0'],
    ['scheduler', '0.23.2'],
    ['react-is', '16.13.1'],
    ['firebase', '9.0.0-beta.2'],
  ]) {
    assertPackageVersion(lockJson, name, version);
  }

  const loaderPath = path.join(
    buildDirectory,
    'external',
    'monaco-editor-min',
    'vs',
    'loader.js'
  );
  let loaderBytes;
  try {
    loaderBytes = await readFile(loaderPath);
  } catch (error) {
    throw new Error(`Monaco AMD loader is missing: ${loaderPath}`, {
      cause: error,
    });
  }
  if (loaderBytes.byteLength === 0) {
    throw new Error(`Monaco AMD loader is empty: ${loaderPath}`);
  }
  const loader = loaderBytes.toString('utf8');
  const loaderSha256 = createHash('sha256').update(loaderBytes).digest('hex');
  if (
    !new RegExp(
      `Version:\\s*${monacoEvidence.loaderReportedVersion.replaceAll('.', '\\.')}\\b`
    ).test(loader) ||
    loaderSha256 !== monacoEvidence.loaderSha256
  ) {
    throw new Error(
      'Monaco AMD loader evidence changed; review the declared version, ' +
        'loader-reported version, distributed-file hash and license provenance before release'
    );
  }

  const sections = [];
  const seenMaterialSha256 = new Set();
  const addSection = async (label, filePath, root) => {
    const text = await readRequiredText(filePath, label);
    const sha256 = sha256Text(text);
    if (seenMaterialSha256.has(sha256)) return;
    seenMaterialSha256.add(sha256);
    sections.push({
      label,
      source: relativeSlash(root, filePath),
      sha256,
      text,
    });
  };

  for (const relativePath of [
    'LICENSE.md',
    'Core/LICENSE.md',
    'GDJS/LICENSE.md',
    'Extensions/LICENSE.md',
    'newIDE/LICENSE.md',
  ]) {
    await addSection(
      `GDevelop upstream ${relativePath}`,
      path.join(sourceDirectory, ...relativePath.split('/')),
      sourceDirectory
    );
  }
  for (const [name, filenames] of [
    ['monaco-editor', ['LICENSE', 'ThirdPartyNotices.txt']],
    ['react', ['LICENSE']],
    ['react-dom', ['LICENSE']],
    ['scheduler', ['LICENSE']],
    ['react-is', ['LICENSE']],
  ]) {
    for (const filename of filenames) {
      const filePath = path.join(appDirectory, 'node_modules', name, filename);
      await addSection(`${name} ${filename}`, filePath, sourceDirectory);
    }
  }
  const firebaseWebIdeEvidence = lock?.compliance?.firebaseWebIde;
  const firebaseLockRecord = lockJson.packages?.['node_modules/firebase'];
  const firebasePackageJsonPath = path.join(
    appDirectory,
    'node_modules',
    'firebase',
    'package.json'
  );
  const firebasePackageJsonBytes = await readFile(firebasePackageJsonPath);
  const firebasePackageJson = JSON.parse(firebasePackageJsonBytes.toString('utf8'));
  if (
    !firebaseWebIdeEvidence ||
    firebaseWebIdeEvidence.version !== '9.0.0-beta.2' ||
    firebaseWebIdeEvidence.license !== 'Apache-2.0' ||
    firebaseWebIdeEvidence.repository !== 'https://github.com/firebase/firebase-js-sdk.git' ||
    !/^[a-f0-9]{40}$/.test(firebaseWebIdeEvidence.dependencyCommit || '') ||
    !String(firebaseLockRecord?.dependencies?.['@firebase/app'] || '').endsWith(
      firebaseWebIdeEvidence.dependencyCommit.slice(0, 9)
    ) ||
    firebaseLockRecord?.integrity !== firebaseWebIdeEvidence.packageIntegrity ||
    sha256Bytes(firebasePackageJsonBytes) !== firebaseWebIdeEvidence.packageJsonSha256 ||
    firebasePackageJson.version !== firebaseWebIdeEvidence.version ||
    firebasePackageJson.license !== firebaseWebIdeEvidence.license
  ) {
    throw new Error('WebIDE Firebase 9.0.0-beta.2 package/license evidence changed');
  }
  await addSection(
    'WebIDE Firebase 9.0.0-beta.2 package Apache-2.0 evidence',
    firebasePackageJsonPath,
    sourceDirectory
  );
  for (const filename of ['LICENSE.md', 'NOTICE.txt']) {
    const filePath = path.join(
      sourceDirectory,
      'Extensions',
      'Firebase',
      'A_firebasejs',
      filename
    );
    await addSection(`Firebase runtime ${filename}`, filePath, sourceDirectory);
  }
  for (const [label, relativePath] of [
    [
      'DialogueTree bundled bondage.js LICENSE',
      'Extensions/DialogueTree/bondage.js/LICENSE.md',
    ],
    [
      'DialogueTree bundled bondage.js version evidence',
      'Extensions/DialogueTree/bondage.js/version.txt',
    ],
  ]) {
    const filePath = path.join(sourceDirectory, ...relativePath.split('/'));
    await addSection(label, filePath, sourceDirectory);
  }

  const bbTextEvidence = lock?.compliance?.bbTextPixiMultistyleText;
  const expectedBbTextKeys = [
    'exactUpstreamCodeRevision',
    'licenseCommit',
    'licensePath',
    'licenseSourceUrl',
    'repository',
    'upstreamLicenseSha256',
    'vendoredFiles',
    'vendoredLicenseSha256',
  ];
  if (
    !bbTextEvidence ||
    Object.keys(bbTextEvidence).sort().join(',') !== expectedBbTextKeys.join(',') ||
    bbTextEvidence.exactUpstreamCodeRevision !== 'unknown' ||
    !/^[a-f0-9]{40}$/.test(bbTextEvidence.licenseCommit || '') ||
    !/^[a-f0-9]{64}$/.test(bbTextEvidence.upstreamLicenseSha256 || '') ||
    !/^[a-f0-9]{64}$/.test(bbTextEvidence.vendoredLicenseSha256 || '')
  ) {
    throw new Error('BBText pixi-multistyle-text compliance evidence is missing or overclaims provenance');
  }
  if (
    bbTextEvidence.repository !== 'https://github.com/tleunen/pixi-multistyle-text.git' ||
    bbTextEvidence.licenseSourceUrl !==
      `https://raw.githubusercontent.com/tleunen/pixi-multistyle-text/${bbTextEvidence.licenseCommit}/LICENSE.md`
  ) {
    throw new Error('BBText pixi-multistyle-text license source is not pinned to the attributed upstream');
  }
  const expectedVendoredPaths = [
    'Extensions/BBText/pixi-multistyle-text/README.md',
    'Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.d.ts',
    'Extensions/BBText/pixi-multistyle-text/dist/pixi-multistyle-text.umd.js',
  ];
  if (
    Object.keys(bbTextEvidence.vendoredFiles || {}).sort().join(',') !==
    expectedVendoredPaths.sort().join(',')
  ) {
    throw new Error('BBText pixi-multistyle-text vendored byte inventory is incomplete');
  }
  for (const relativePath of expectedVendoredPaths) {
    const filePath = path.join(sourceDirectory, ...relativePath.split('/'));
    const bytes = await readFile(filePath);
    if (sha256Bytes(bytes) !== bbTextEvidence.vendoredFiles[relativePath]) {
      throw new Error(`BBText pixi-multistyle-text vendored bytes changed: ${relativePath}`);
    }
  }
  const bbTextReadme = await readRequiredText(
    path.join(sourceDirectory, ...expectedVendoredPaths[0].split('/')),
    'BBText pixi-multistyle-text attribution README'
  );
  if (!bbTextReadme.includes('tleunen/pixi-multistyle-text') || !/MIT/i.test(bbTextReadme)) {
    throw new Error('BBText README no longer attributes the pinned upstream repository and MIT license');
  }
  const bbTextLicensePath = path.resolve(repositoryRoot, bbTextEvidence.licensePath);
  const bbTextLicenseBytes = await readFile(bbTextLicensePath);
  if (
    sha256Bytes(bbTextLicenseBytes) !== bbTextEvidence.vendoredLicenseSha256 ||
    !bbTextLicenseBytes.toString('utf8').includes('Copyright (c) 2014 Tommy Leunen')
  ) {
    throw new Error('Pinned BBText pixi-multistyle-text license text changed or conflicts with attribution');
  }
  await addSection(
    'BBText bundled pixi-multistyle-text README attribution evidence',
    path.join(sourceDirectory, ...expectedVendoredPaths[0].split('/')),
    sourceDirectory
  );
  await addSection(
    'BBText pixi-multistyle-text MIT license text pinned separately',
    bbTextLicensePath,
    repositoryRoot
  );

  const runtimeLegalFiles = (await walkFiles(runtimeDirectory))
    .filter(filePath => /(?:^|[._-])(license|licence|notice)(?:[._-]|$)/i.test(path.basename(filePath)))
    .sort((left, right) => left.localeCompare(right, 'en'));
  if (runtimeLegalFiles.length < 3) {
    throw new Error('GDJS runtime legal-material inventory is unexpectedly incomplete');
  }
  for (const filePath of runtimeLegalFiles) {
    await addSection('GDJS runtime legal material', filePath, runtimeDirectory);
  }

  const webpackLicenseFiles = (await walkFiles(buildDirectory))
    .filter(filePath => filePath.endsWith('.LICENSE.txt'))
    .sort((left, right) => left.localeCompare(right, 'en'));
  if (webpackLicenseFiles.length < 5) {
    throw new Error('Webpack license asset inventory is unexpectedly incomplete');
  }
  for (const filePath of webpackLicenseFiles) {
    await addSection('Webpack-emitted attribution', filePath, buildDirectory);
  }

  const renderedSections = sections
    .map(
      ({ label, source, sha256, text }) =>
        `\n\n---\n\n## Verbatim material: ${label}\n\n` +
        `Source in locked build input: \`${source}\`  \n` +
        `Normalized-text SHA-256: \`${sha256}\`\n\n${text}`
    )
    .join('');
  const monacoEvidenceSection = [
    '## Monaco version evidence (no guessed single version)',
    '',
    `- npm lock identity: \`${monacoEvidence.declaredVersion}\`.`,
    `- distributed AMD loader reports: \`${monacoEvidence.loaderReportedVersion}\`.`,
    `- distributed \`external/monaco-editor-min/vs/loader.js\` SHA-256: \`${loaderSha256}\`.`,
    '- The matching package-local `LICENSE` and `ThirdPartyNotices.txt` are copied verbatim below.',
    '- This evidence conflict is recorded explicitly; the distribution does not claim one Monaco semantic version.',
  ].join('\n');
  const bbTextEvidenceSection = [
    '## BBText pixi-multistyle-text byte and license evidence',
    '',
    ...expectedVendoredPaths.map(relativePath =>
      `- vendored \`${relativePath}\` SHA-256: \`${bbTextEvidence.vendoredFiles[relativePath]}\`.`
    ),
    `- attribution repository: \`${bbTextEvidence.repository}\`.`,
    `- license text source pinned to commit: \`${bbTextEvidence.licenseCommit}\`.`,
    `- upstream license source SHA-256: \`${bbTextEvidence.upstreamLicenseSha256}\`; repository copy SHA-256: \`${bbTextEvidence.vendoredLicenseSha256}\`.`,
    '- The vendored derivative exact upstream code revision is unknown. The pinned commit identifies the separately preserved license text only; no byte equivalence is claimed.',
  ].join('\n');
  const brandEvidenceSection = [
    '## Playmesh logo build provenance (no rights conclusion)',
    '',
    `- repository source: \`${brandEvidence.sourcePath}\`.`,
    `- source and distributed-copy SHA-256: \`${brandEvidence.sourceSha256}\`.`,
    `- pixel contract: \`${brandEvidence.pixelContract || 'not-recorded'}\`.`,
    '- The build system records byte provenance only; it does not assert copyright or trademark ownership.',
  ].join('\n');
  const firebaseEvidenceSection = [
    '## Separate Firebase evidence chains',
    '',
    `- WebIDE npm package: \`${firebaseWebIdeEvidence.version}\`, lock integrity \`${firebaseWebIdeEvidence.packageIntegrity}\`, dependency commit \`${firebaseWebIdeEvidence.dependencyCommit}\`, package metadata SHA-256 \`${firebaseWebIdeEvidence.packageJsonSha256}\`, license declaration \`${firebaseWebIdeEvidence.license}\`.`,
    '- GDJS runtime package: `8.3.3` per the separately collected `Extensions/Firebase/A_firebasejs/NOTICE.txt`; its `LICENSE.md` and NOTICE are collected below.',
    '- Both components use Apache-2.0, but their version and material evidence are intentionally kept separate.',
  ].join('\n');
  const output =
    `${baseNotice}\n\n${monacoEvidenceSection}\n\n${bbTextEvidenceSection}\n\n` +
    `${brandEvidenceSection}\n\n${firebaseEvidenceSection}\n\n` +
    `## Mechanically collected verbatim materials${renderedSections}\n`;
  if (/\bpending\b/i.test(output)) {
    throw new Error('Generated WebIDE notices contain a pending marker');
  }
  assertWebIdeDistributionDisclaimer({
    notices: output,
    label: 'Generated WebIDE notices',
  });
  return output;
};

export const writeWebIdeThirdPartyNotices = async options => {
  const output = await generateWebIdeThirdPartyNotices(options);
  const outputPath = path.join(
    options.outputDirectory,
    options.outputFileName || NOTICE_ENTRY
  );
  await writeFile(outputPath, output, 'utf8');
  const metadata = await stat(outputPath);
  if (metadata.size < 20000) {
    throw new Error('Generated WebIDE notices are unexpectedly small');
  }
  return { outputPath, size: metadata.size };
};

export {
  BRAND_ICON_ENTRY,
  BRAND_MARKER,
  GDEVELOP_DISTRIBUTION_DISCLAIMER,
  NOTICE_ENTRY,
};
