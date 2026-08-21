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
const overlayRoot = path.join(playmeshDirectory, 'overlays', 'newIDE', 'app', 'src');
const readOverlay = relativePath =>
  readFile(path.join(overlayRoot, ...relativePath.split('/')), 'utf8');

const [
  homeSource,
  createSectionSource,
  noticeSource,
  messageKeysSource,
  sourcePolicy,
  sourcePolicyManifestSource,
  zhSource,
  enSource,
] = await Promise.all([
  readOverlay('MainFrame/EditorContainers/PlaymeshHomePage/index.js'),
  readOverlay(
    'MainFrame/EditorContainers/PlaymeshHomePage/PlaymeshCreateSection.js'
  ),
  readOverlay(
    'MainFrame/EditorContainers/PlaymeshHomePage/PlaymeshDistributionNotice.js'
  ),
  readOverlay('PlaymeshLocalization/PlaymeshMessageKeys.js'),
  readFile(path.join(playmeshDirectory, 'scripts', 'apply-source-policy.mjs'), 'utf8'),
  readFile(path.join(playmeshDirectory, 'source-policy-output-manifest.json'), 'utf8'),
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

const sourcePolicyManifest = JSON.parse(sourcePolicyManifestSource);
const zh = JSON.parse(zhSource);
const en = JSON.parse(enSource);

assert.doesNotMatch(
  homeSource,
  /<PlaymeshDistributionNotice\s*\/>/,
  'The home scroll area must not render a compliance banner.'
);
assert.match(homeSource, /aboutLabel=\{playmeshT\(playmeshMessages\.homeAboutEditor\)\}/);
assert.match(homeSource, /open=\{distributionNoticeOpen\}/);
assert.match(homeSource, /onOpenAbout=\{\(\) => setDistributionNoticeOpen\(true\)\}/);

for (const marker of [
  "import RouterContext from '../../RouterContext'",
  "const initialDialog = routeArguments['initial-dialog']",
  'playmeshHomePageRouteArguments.includes(initialDialog)',
  "removeRouteArguments(['initial-dialog'])",
  '[routeArguments, removeRouteArguments]',
]) {
  assert.ok(
    homeSource.includes(marker),
    `Missing one-shot homepage route contract: ${marker}`
  );
}
assert.ok(
  homeSource.indexOf("removeRouteArguments(['initial-dialog'])") <
    homeSource.indexOf('return ('),
  'The initial homepage route must be consumed by an effect, not by a click handler.'
);

for (const marker of [
  "import { useResponsiveWindowSize } from '../../../UI/Responsive/ResponsiveWindowMeasurer'",
  'const { isMobile } = useResponsiveWindowSize()',
  "flexDirection: 'row-reverse'",
  "flexDirection: 'column'",
  'isMobile ? styles.mobileContainer : styles.desktopContainer',
]) {
  assert.ok(
    homeSource.includes(marker),
    `Missing responsive homepage-axis contract: ${marker}`
  );
}
assert.ok(
  homeSource.indexOf('<PlaymeshCreateSection') <
    homeSource.indexOf('<HomePageMenu'),
  'The mobile column must keep page content before the bottom menu.'
);

assert.doesNotMatch(createSectionSource, /onChooseProject/);
assert.equal(
  (createSectionSource.match(/playmeshMessages\.homeOpenLocalProject/g) || [])
    .length,
  1,
  'Only project cards may keep the Open local project action.'
);
for (const marker of [
  "import CircularProgress from '../../../UI/CircularProgress'",
  'const [projectListLoading, setProjectListLoading] = React.useState(true)',
  'const requestId = ++projectListRequest.current',
  'if (requestId !== projectListRequest.current) return',
  'projectListLoading && !localProjects.length',
  'playmeshMessages.homeProjectsLoading',
  'role="status"',
  'aria-live="polite"',
]) {
  assert.ok(
    createSectionSource.includes(marker),
    `Missing authoritative project loading-state contract: ${marker}`
  );
}
assert.ok(
  createSectionSource.indexOf('projectListLoading && !localProjects.length') <
    createSectionSource.indexOf('hasSuccessfulProjectList && !projectListUnavailable'),
  'Loading state must be resolved before the successful empty-project state.'
);
for (const marker of [
  "import Dialog from '../../../UI/Dialog'",
  'onRequestClose={closeDialog}',
  'fullHeight',
  'flexColumnBody',
  'forceScrollVisible',
  "maxHeight: 'min(52vh, 520px)'",
  "overflow: 'auto'",
  "userSelect: 'text'",
  'tabIndex={0}',
  'role="status"',
  'aria-live="polite"',
  "window.fetch('./THIRD_PARTY_NOTICES.md'",
  'clipboard.writeText(notices)',
  'playmeshMessages.homeUnofficialNotice',
  'src="./playmesh-logo.png"',
  "background: 'transparent'",
]) {
  assert.ok(noticeSource.includes(marker), `Missing notice dialog contract: ${marker}`);
}
assert.doesNotMatch(
  noticeSource,
  /Unofficial modified distribution based on GDevelop[\s\S]*基于 GDevelop/,
  'The dialog summary must be localized, not hard-coded bilingually.'
);
assert.doesNotMatch(noticeSource, /position:\s*'fixed'|zIndex:\s*100000/);

for (const key of [
  'homeAboutEditor',
  'homeVisualEditorName',
  'homeUnofficialNotice',
  'homeNoticesTitle',
  'homeNoticesShow',
  'homeNoticesCopy',
  'homeNoticesLoadFailed',
  'homeProjectsLoading',
]) {
  assert.match(messageKeysSource, new RegExp(`${key}:`));
}
const compactHomeActions = {
  'workspace.gdevelop_home.about_editor': ['关于', 'About'],
  'workspace.gdevelop_home.open_local_project': ['打开', 'Open'],
  'workspace.gdevelop_home.import_gdevelop_zip': ['导入', 'Import'],
  'workspace.gdevelop_home.export_source_zip': ['导出', 'Export'],
  'workspace.gdevelop_home.create_new_game': ['新建', 'New'],
  'workspace.gdevelop_home.delete_project': ['删除', 'Delete'],
};
for (const [key, [zhLabel, enLabel]] of Object.entries(compactHomeActions)) {
  assert.equal(zh[key], zhLabel, `${key} must stay compact in Chinese.`);
  assert.equal(en[key], enLabel, `${key} must stay compact in English.`);
}
assert.equal(
  zh['workspace.gdevelop_home.projects_loading'],
  '正在加载本地工程…'
);
assert.equal(
  en['workspace.gdevelop_home.projects_loading'],
  'Loading local projects…'
);
assert.ok(zh['creator.gdevelop_unofficial_notice'].includes('无隶属关系'));
assert.ok(en['creator.gdevelop_unofficial_notice'].includes('not affiliated'));
assert.equal(
  zh['workspace.gdevelop_home.unofficial_notice'],
  zh['creator.gdevelop_unofficial_notice']
);
assert.equal(
  en['workspace.gdevelop_home.unofficial_notice'],
  en['creator.gdevelop_unofficial_notice']
);
assert.equal(
  zh['workspace.gdevelop_home.notices_title'],
  zh['creator.gdevelop_notices']
);
assert.equal(
  en['workspace.gdevelop_home.notices_title'],
  en['creator.gdevelop_notices']
);

for (const marker of [
  "aboutLabel: React.Node",
  "id: 'about-playmesh-editor'",
  "InfoOutlinedIcon from '@material-ui/icons/InfoOutlined'",
  'keep the Playmesh editor notice reachable from the mobile bottom bar',
  'aboutLabel={aboutLabel}',
]) {
  assert.ok(sourcePolicy.includes(marker), `Missing menu contract: ${marker}`);
}

const homePageMenuRecords = sourcePolicyManifest.patchedOfficialFiles.filter(
  entry =>
    entry.relativePath ===
      'newIDE/app/src/MainFrame/EditorContainers/HomePage/HomePageMenu.js' ||
    entry.relativePath ===
      'newIDE/app/src/MainFrame/EditorContainers/HomePage/HomePageMenuBar.js'
);
assert.equal(homePageMenuRecords.length, 2);
const isPendingOrFrozenDigest = value =>
  value === 'pending' || /^[0-9a-f]{64}$/.test(value);
assert.ok(
  homePageMenuRecords.every(entry =>
    isPendingOrFrozenDigest(entry.postPatchSha256)
  )
);
assert.ok(isPendingOrFrozenDigest(sourcePolicyManifest.overlay.treeSha256));

const responsiveReachabilityMatrix = [
  {
    mode: 'desktop sidebar',
    reachable:
      sourcePolicy.includes('replace the desktop GDevelop about entry') &&
      sourcePolicy.includes("id: 'about-playmesh-editor'"),
  },
  {
    mode: 'medium drawer',
    reachable:
      sourcePolicy.includes('replace the GDevelop about entry') &&
      sourcePolicy.includes('aboutLabel={aboutLabel}'),
  },
  {
    mode: 'mobile bottom bar',
    reachable:
      sourcePolicy.includes('keep the Playmesh editor notice reachable from the mobile bottom bar') &&
      sourcePolicy.includes('onClick={onOpenAbout}'),
  },
  {
    mode: 'narrow dialog',
    reachable:
      noticeSource.includes('fullHeight') &&
      noticeSource.includes('forceScrollVisible'),
  },
];
assert.deepEqual(
  responsiveReachabilityMatrix.filter(item => !item.reachable),
  [],
  'The editor notice must remain reachable at every responsive branch.'
);

process.stdout.write('Playmesh home identity UI contract tests passed.\n');
