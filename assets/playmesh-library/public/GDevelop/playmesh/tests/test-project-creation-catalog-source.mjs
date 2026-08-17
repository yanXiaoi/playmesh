import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshRoot = path.resolve(testDirectory, '..');
const overlayRoot = path.join(playmeshRoot, 'overlays/newIDE/app/src');
const readOverlay = relativePath =>
  readFile(path.join(overlayRoot, relativePath), 'utf8');

const [
  catalog,
  catalogSource,
  exampleImporter,
  catalogCss,
  zhLocale,
  enLocale,
  createSection,
  commercialProviders,
  sourcePolicy,
] = await Promise.all([
  readOverlay('ProjectCreation/PlaymeshNewProjectCatalog.js'),
  readOverlay('PlaymeshCatalog/PlaymeshCatalogSource.js'),
  readOverlay('PlaymeshCatalog/PlaymeshExampleImporter.js'),
  readOverlay('ProjectCreation/PlaymeshNewProjectCatalog.module.css'),
  readFile(
    path.resolve(playmeshRoot, '../../../../playmesh-localization/locales/zh-CN/app.json'),
    'utf8'
  ),
  readFile(
    path.resolve(playmeshRoot, '../../../../playmesh-localization/locales/en-US/app.json'),
    'utf8'
  ),
  readOverlay(
    'MainFrame/EditorContainers/PlaymeshHomePage/PlaymeshCreateSection.js'
  ),
  readOverlay('MainFrame/PlaymeshDisabledCommercialProviders.js'),
  readFile(path.join(playmeshRoot, 'scripts/apply-source-policy.mjs'), 'utf8'),
]);

assert.match(catalog, /loadPlaymeshExamplesIndex/);
assert.match(catalog, /importPlaymeshExample/);
assert.match(catalog, /header\.preview \? header\.preview\.url/);
assert.match(catalog, /loading="lazy"/);
assert.match(catalog, /onError=\{\(\) => setFailedUrl\(previewUrl\)\}/);
assert.match(catalog, /thumbnailFallback/);
assert.match(catalog, /usePlaymeshLocalization/);
assert.match(catalog, /localeId makes the presentation follow a temporary GDevelop language/);
assert.match(catalog, /translateOfficialText\(i18n, header\.name\)/);
assert.match(catalog, /GENERATED_SHORT_DESCRIPTION/);
assert.doesNotMatch(catalog, /translate\.google|microsofttranslator|online translation/i);
assert.match(catalog, /normalizePlaymeshExampleImportError/);
assert.match(catalog, /reportPlaymeshExampleImportFailure/);
assert.match(catalog, /presentPlaymeshExternalDownloadFailure/);
assert.match(catalog, /showErrorBox/);
assert.match(catalog, /playmesh-example-import-error/);
for (const field of ['stage', 'operation', 'status', 'code', 'requestId']) {
  assert.match(catalog, new RegExp(`importFailure\\.error\\.${field}`));
}
assert.match(catalog, /onImportingChange\(true\)/);
assert.match(catalog, /onOpenProject\(\{/);
assert.match(catalog, /examplesContributors/);
assert.match(catalog, /examplesCopyright/);
assert.match(catalog, /examplesRightsNotice/);
assert.match(catalog, /examplesCatalogNotice/);
assert.match(catalog, /inspectPlaymeshExampleLicense/);
assert.match(catalog, /licenseAcknowledged/);
assert.match(catalog, /licenseEvidenceKey/);
assert.match(catalog, /type="checkbox"/);
assert.match(catalogSource, /'open' \| 'non-open' \| 'unknown' \| 'conflict'/);
assert.match(catalogSource, /detectExplicitRestrictions/);
assert.match(catalogSource, /detectDefaultOpenLicense/);
assert.match(catalogSource, /evidenceKey/);
assert.doesNotMatch(catalogSource, /暂不支持直接导入/);
assert.match(exampleImporter, /license_acknowledgement_required/);
assert.match(exampleImporter, /licenseEvidenceKey !== exampleManifest\.license\.evidenceKey/);
assert.match(catalogCss, /@media \(max-width: 560px\)/);
assert.match(catalogCss, /focus-visible/);
for (const locale of [zhLocale, enLocale]) {
  for (const key of [
    'workspace.gdevelop_examples.catalog_notice',
    'workspace.gdevelop_examples.copyright',
    'workspace.gdevelop_examples.license_non_open',
    'workspace.gdevelop_examples.license_unknown',
    'workspace.gdevelop_examples.license_conflict',
    'workspace.gdevelop_examples.acknowledge_notice',
  ]) {
    assert.ok(JSON.parse(locale)[key], `Missing localized example notice: ${key}`);
  }
}

assert.doesNotMatch(createSection, /PlaymeshOfficialExamplesDialog/);
assert.doesNotMatch(createSection, /homeOfficialExamples/);
assert.match(sourcePolicy, /PlaymeshNewProjectCatalog/);
assert.match(sourcePolicy, /<EmptyAndStartingPointProjects/);
assert.match(sourcePolicy, /replace online templates with the resilient App-backed official catalog/);
assert.doesNotMatch(
  sourcePolicy,
  /open new project creation directly on the blank local project setup/
);
assert.match(sourcePolicy, /onOpenPlaymeshProject/);

assert.doesNotMatch(
  commercialProviders,
  /listMarketingPlans|listProductLicenses|listListedCreditsPackages|useEffect/
);
assert.match(commercialProviders, /marketingPlans: \[\]/);
assert.match(commercialProviders, /assetPackLicenses: \[\]/);
assert.match(commercialProviders, /gameTemplateLicenses: \[\]/);
assert.match(commercialProviders, /creditsPackageListingDatas: \[\]/);
assert.match(commercialProviders, /\{children\}/g);
assert.match(
  sourcePolicy,
  /disable unsupported commerce requests at the root Provider boundary/
);
assert.match(sourcePolicy, /silence the disabled Playmesh object store prefetch info/);
assert.match(sourcePolicy, /silence the expected empty Playmesh object store result/);
assert.match(sourcePolicy, /silence expected object\/search indexing timing info while preserving errors/);

process.stdout.write(
  'GDevelop integrated project creation catalog and disabled commerce Provider contracts passed.\n'
);
