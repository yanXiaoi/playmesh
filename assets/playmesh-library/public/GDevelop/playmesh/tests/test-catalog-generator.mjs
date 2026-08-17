import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  compareVersions,
  generateExamplesIndexFromTree,
  generateExtensionsIndex,
  isEngineVersionCompatible,
} from '../scripts/catalog-generator-lib.mjs';

const sourceAcquisition = await readFile(
  new URL('../scripts/fetch-catalog-sources.mjs', import.meta.url),
  'utf8'
);
assert.match(sourceAcquisition, /config', 'core\.autocrlf', 'false'/);
assert.match(sourceAcquisition, /config', 'core\.eol', 'lf'/);
assert.match(
  sourceAcquisition,
  /'checkout',[\s\S]*?'--force',[\s\S]*?'--detach'/
);

const extensionCommit = 'de361fba046e0670a8414cbc657dd53788dbfc48';
const extensionTree = 'a153f751e377ea04c05aedafc47eadbf092f3291';
const exampleCommit = 'c55c87d88ac48de01653844dc484c253adecd9c7';
const exampleTree = 'cee1e71d82ca53c49fc8efa7a8392a832cc4bfed';
const lock = {
  catalogRevision: 'fixture-1',
  engine: { version: '5.6.269', tag: 'v5.6.269', commit: 'a'.repeat(40) },
  sources: {
    extensions: {
      repository: 'GDevelopApp/GDevelop-extensions',
      commit: extensionCommit,
      rootTreeSha: extensionTree,
      license: 'MIT',
      licenseUrl: 'https://example.invalid/extensions-license',
    },
    examples: {
      repository: 'GDevelopApp/GDevelop-examples',
      commit: exampleCommit,
      rootTreeSha: exampleTree,
      license: 'MIT unless an example directory states otherwise',
      licenseUrl: 'https://example.invalid/examples-license',
    },
  },
  limits: {
    exampleProjectBytes: 1024,
    exampleResourceBytes: 2048,
    exampleTotalBytes: 4096,
  },
};

const createExtension = ({ name, requiredExtensions = [], behavior = false }) => ({
  name,
  fullName: `${name} full name`,
  shortDescription: `${name} short description`,
  description: `${name} description`,
  version: '1.2.0',
  gdevelopVersion: '>=5.5.222',
  tags: ['fixture'],
  category: 'General',
  authorIds: [],
  eventsFunctions: [],
  eventsBasedObjects: [],
  eventsBasedBehaviors: behavior
    ? [
        {
          name: 'FixtureBehavior',
          fullName: 'Fixture behavior',
          description: 'Fixture behavior description',
          objectType: '',
          propertyDescriptors: [],
          eventsFunctions: [],
        },
      ]
    : [],
  requiredExtensions,
});

const writeJson = (filePath, value) =>
  writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');

const temporaryRoot = await mkdtemp(path.join(os.tmpdir(), 'playmesh-catalog-test-'));
try {
  assert.equal(compareVersions('5.6.269', '5.6.268'), 1);
  assert.equal(isEngineVersionCompatible('5.6.269', '>=5.5.222'), true);
  assert.equal(isEngineVersionCompatible('5.6.269', '>=6.0.0'), false);
  assert.equal(isEngineVersionCompatible('5.6.269', 'not-a-range'), false);

  const extensionRoot = path.join(temporaryRoot, 'extensions-source');
  await mkdir(path.join(extensionRoot, 'extensions', 'reviewed'), {
    recursive: true,
  });
  await mkdir(path.join(extensionRoot, 'extensions', 'community'), {
    recursive: true,
  });
  const alphaPath = path.join(
    extensionRoot,
    'extensions',
    'reviewed',
    'Alpha.json'
  );
  await writeJson(alphaPath, createExtension({ name: 'Alpha', behavior: true }));
  await writeJson(
    path.join(extensionRoot, 'extensions', 'community', 'Beta.json'),
    createExtension({
      name: 'Beta',
      requiredExtensions: [
        { extensionName: 'Alpha', extensionVersion: '1.0.0' },
      ],
    })
  );
  await writeJson(path.join(extensionRoot, 'extensions', 'views.json'), {
    default: {
      firstExtensionIds: ['Alpha'],
      firstBehaviorIds: [
        { extensionName: 'Alpha', behaviorName: 'FixtureBehavior' },
      ],
      firstObjectIds: [],
      secondObjectIds: [],
    },
  });
  const extensionIndex = await generateExtensionsIndex({ root: extensionRoot, lock });
  assert.equal(extensionIndex.headers.length, 2);
  assert.equal(extensionIndex.behavior.headers.length, 1);
  assert.equal(extensionIndex.headers[1].name, 'Beta');
  const alphaArtifact = extensionIndex.artifacts['extension:Alpha'];
  assert.equal(alphaArtifact.rootTreeSha, extensionTree);
  assert.equal(
    alphaArtifact.declaredBytes,
    (await readFile(alphaPath)).byteLength
  );
  assert.match(alphaArtifact.sha256, /^[a-f0-9]{64}$/);
  assert.equal('bytes' in alphaArtifact, false);
  assert.equal(
    alphaArtifact.url,
    `https://raw.githubusercontent.com/GDevelopApp/GDevelop-extensions/${extensionCommit}/extensions/reviewed/Alpha.json`
  );

  const blob = (treePath, size, shaCharacter) => ({
    path: treePath,
    mode: '100644',
    type: 'blob',
    sha: shaCharacter.repeat(40),
    size,
  });
  const tree = {
    sha: exampleTree,
    truncated: false,
    tree: [
      blob('examples/good-example/good-example.json', 120, '1'),
      blob('examples/good-example/assets/image.png', 3, '2'),
      blob('examples/good-example/README.md', 40, '3'),
      blob('examples/good-example/license.txt', 140, '4'),
      blob('examples/good-example/assets/IGNORED.md', 0, '8'),
      blob('examples/ambiguous/a.json', 20, '5'),
      blob('examples/ambiguous/b.json', 20, '6'),
      blob('examples/too-large/too-large.json', 2048, '7'),
    ],
  };
  const contentSha256ByPath = new Map(
    tree.tree.map(entry => [entry.path, entry.sha[0].repeat(64)])
  );
  const first = generateExamplesIndexFromTree({
    tree,
    lock,
    contentSha256ByPath,
  });
  const second = generateExamplesIndexFromTree({
    tree,
    lock,
    contentSha256ByPath,
  });
  assert.deepEqual(first, second);
  assert.equal(first.index.schemaVersion, 2);
  assert.equal(first.index.headers.length, 1);
  assert.deepEqual(
    first.index.unavailable,
    [
      {
        slug: 'ambiguous',
        reason: 'noncanonical-project-filename',
        projectPaths: [
          'examples/ambiguous/a.json',
          'examples/ambiguous/b.json',
        ],
      },
      { slug: 'too-large', reason: 'project-too-large' },
    ]
  );
  const header = first.index.headers[0];
  assert.equal(header.id, 'good-example');
  assert.equal(header.root, 'examples/good-example');
  assert.equal(header.category, 'official-examples');
  assert.equal(header.project.declaredBytes, 120);
  assert.equal(header.project.gitBlobOid, '1'.repeat(40));
  assert.equal(header.project.sha256, '1'.repeat(64));
  assert.equal(header.files.length, 4);
  assert.equal(
    header.files.some(file => file.relativePath.endsWith('IGNORED.md')),
    false
  );
  assert.equal(header.license.status, 'runtime-validation-required');
  assert.equal(header.license.documents.length, 2);
  assert.ok(
    header.license.documents.every(
      document => /^[a-f0-9]{64}$/.test(document.sha256) && !('artifact' in document)
    )
  );
  assert.equal(
    header.project.url,
    `https://raw.githubusercontent.com/GDevelopApp/GDevelop-examples/${exampleCommit}/examples/good-example/good-example.json`
  );
  assert.throws(
    () =>
      generateExamplesIndexFromTree({
        tree: { ...tree, truncated: true },
        lock,
        contentSha256ByPath,
      }),
    /被截断/
  );
  assert.throws(
    () => generateExamplesIndexFromTree({ tree, lock, contentSha256ByPath: new Map() }),
    /缺少固定 SHA-256/
  );
} finally {
  await rm(temporaryRoot, { recursive: true, force: true });
}

process.stdout.write('GDevelop lightweight catalog generator tests passed.\n');
