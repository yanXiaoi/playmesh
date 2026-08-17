import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const sourcePath = path.resolve(
  testDirectory,
  '../overlays/newIDE/app/src/PlaymeshCatalog/PlaymeshCatalogSource.js'
);
let moduleSource = await readFile(sourcePath, 'utf8');

const removeFlowTypeDeclarations = value => {
  let result = value;
  const declaration = /^(?:export\s+)?type\s+[A-Za-z_$][A-Za-z0-9_$]*/m;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    let quote = null;
    let escaped = false;
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = match.index;
    for (; end < result.length; end++) {
      const character = result[end];
      if (quote) {
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === "'" || character === '"') {
        quote = character;
        continue;
      }
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        character === ';' &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        end++;
        break;
      }
    }
    result = result.slice(0, match.index) + result.slice(end);
  }
};

const removeFlowVariableAnnotations = value => {
  const declaration =
    /\b(?:const|let|var)\s+[A-Za-z_$][A-Za-z0-9_$]*\s*:/g;
  let result = value;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    const colon = result.indexOf(':', match.index);
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = colon + 1;
    for (; end < result.length; end++) {
      const character = result[end];
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        (character === '=' || character === ';') &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        break;
      }
    }
    result = result.slice(0, colon) + result.slice(end);
    declaration.lastIndex = colon;
  }
};

const removeFlowDestructuredParameterAnnotations = value => {
  const declaration = /\(\s*\{/g;
  let result = value;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    const openingBrace = result.indexOf('{', match.index);
    let destructuringDepth = 1;
    let closingBrace = openingBrace + 1;
    for (; closingBrace < result.length; closingBrace++) {
      if (result[closingBrace] === '{') destructuringDepth++;
      else if (result[closingBrace] === '}') {
        destructuringDepth--;
        if (destructuringDepth === 0) break;
      }
    }
    let colon = closingBrace + 1;
    while (/\s/.test(result[colon] || '')) colon++;
    if (result[colon] !== ':') {
      declaration.lastIndex = closingBrace + 1;
      continue;
    }
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = colon + 1;
    for (; end < result.length; end++) {
      const character = result[end];
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') {
        if (
          braces === 0 &&
          brackets === 0 &&
          parentheses === 0 &&
          angles === 0
        ) {
          break;
        }
        parentheses--;
      } else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=' && angles > 0) {
        angles--;
      } else if (
        (character === '=' || character === ',') &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        break;
      }
    }
    result = result.slice(0, colon) + result.slice(end);
    declaration.lastIndex = colon;
  }
};

const removeFlowReturnAnnotations = value => {
  const declaration = /\)\s*:\s*(?=[?'"{[(A-Za-z_$])/g;
  let result = value;
  while (true) {
    const match = declaration.exec(result);
    if (!match) return result;
    const colon = result.indexOf(':', match.index);
    let quote = null;
    let escaped = false;
    let braces = 0;
    let brackets = 0;
    let parentheses = 0;
    let angles = 0;
    let end = colon + 1;
    let foundArrow = false;
    for (; end < result.length; end++) {
      const character = result[end];
      if (quote) {
        if (escaped) escaped = false;
        else if (character === '\\') escaped = true;
        else if (character === quote) quote = null;
        continue;
      }
      if (character === "'" || character === '"') {
        quote = character;
        continue;
      }
      if (
        character === '=' &&
        result[end + 1] === '>' &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        foundArrow = true;
        break;
      }
      if (character === '{') braces++;
      else if (character === '}') braces--;
      else if (character === '[') brackets++;
      else if (character === ']') brackets--;
      else if (character === '(') parentheses++;
      else if (character === ')') parentheses--;
      else if (character === '<') angles++;
      else if (character === '>' && result[end - 1] !== '=') {
        if (angles > 0) angles--;
      } else if (
        character === ';' &&
        braces === 0 &&
        brackets === 0 &&
        parentheses === 0 &&
        angles === 0
      ) {
        break;
      }
    }
    if (!foundArrow) {
      declaration.lastIndex = colon + 1;
      continue;
    }
    result = result.slice(0, colon) + result.slice(end);
    declaration.lastIndex = colon;
  }
};

const stripFlowParameterList = value => {
  let result = '';
  let cursor = 0;
  let braces = 0;
  let brackets = 0;
  let parentheses = 0;
  let angles = 0;
  let quote = null;
  let escaped = false;
  let inDefaultValue = false;
  for (let index = 0; index < value.length; index++) {
    const character = value[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = null;
      continue;
    }
    if (character === "'" || character === '"' || character === '`') {
      quote = character;
      continue;
    }
    if (character === '{') braces++;
    else if (character === '}') braces--;
    else if (character === '[') brackets++;
    else if (character === ']') brackets--;
    else if (character === '(') parentheses++;
    else if (character === ')') parentheses--;
    else if (character === '<') angles++;
    else if (character === '>' && value[index - 1] !== '=' && angles > 0) {
      angles--;
    } else if (
      character === ',' &&
      braces === 0 &&
      brackets === 0 &&
      parentheses === 0 &&
      angles === 0
    ) {
      inDefaultValue = false;
    } else if (
      character === '=' &&
      value[index + 1] !== '>' &&
      braces === 0 &&
      brackets === 0 &&
      parentheses === 0 &&
      angles === 0
    ) {
      inDefaultValue = true;
    } else if (
      character === ':' &&
      !inDefaultValue &&
      braces === 0 &&
      brackets === 0 &&
      parentheses === 0 &&
      angles === 0
    ) {
      let annotationBraces = 0;
      let annotationBrackets = 0;
      let annotationParentheses = 0;
      let annotationAngles = 0;
      let annotationQuote = null;
      let annotationEscaped = false;
      let end = index + 1;
      for (; end < value.length; end++) {
        const annotationCharacter = value[end];
        if (annotationQuote) {
          if (annotationEscaped) annotationEscaped = false;
          else if (annotationCharacter === '\\') annotationEscaped = true;
          else if (annotationCharacter === annotationQuote) {
            annotationQuote = null;
          }
          continue;
        }
        if (
          annotationCharacter === "'" ||
          annotationCharacter === '"' ||
          annotationCharacter === '`'
        ) {
          annotationQuote = annotationCharacter;
          continue;
        }
        if (annotationCharacter === '{') annotationBraces++;
        else if (annotationCharacter === '}') annotationBraces--;
        else if (annotationCharacter === '[') annotationBrackets++;
        else if (annotationCharacter === ']') annotationBrackets--;
        else if (annotationCharacter === '(') annotationParentheses++;
        else if (annotationCharacter === ')') annotationParentheses--;
        else if (annotationCharacter === '<') annotationAngles++;
        else if (
          annotationCharacter === '>' &&
          value[end - 1] !== '=' &&
          annotationAngles > 0
        ) {
          annotationAngles--;
        } else if (
          (annotationCharacter === ',' || annotationCharacter === '=') &&
          annotationBraces === 0 &&
          annotationBrackets === 0 &&
          annotationParentheses === 0 &&
          annotationAngles === 0
        ) {
          break;
        }
      }
      let annotationStart = index;
      let previous = index - 1;
      while (/\s/.test(value[previous] || '')) previous--;
      if (value[previous] === '?') annotationStart = previous;
      result += value.slice(cursor, annotationStart);
      cursor = end;
      index = end - 1;
      if (value[end] === '=') inDefaultValue = true;
    }
  }
  return result + value.slice(cursor);
};

const removeFlowArrowParameterAnnotations = value => {
  const stack = [];
  const openingForClosing = new Map();
  const arrows = [];
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let index = 0; index < value.length; index++) {
    const character = value[index];
    const nextCharacter = value[index + 1];
    if (lineComment) {
      if (character === '\n') lineComment = false;
      continue;
    }
    if (blockComment) {
      if (character === '*' && nextCharacter === '/') {
        blockComment = false;
        index++;
      }
      continue;
    }
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = null;
      continue;
    }
    if (character === '/' && nextCharacter === '/') {
      lineComment = true;
      index++;
      continue;
    }
    if (character === '/' && nextCharacter === '*') {
      blockComment = true;
      index++;
      continue;
    }
    if (character === "'" || character === '"' || character === '`') {
      quote = character;
      continue;
    }
    if (character === '(') stack.push(index);
    else if (character === ')') {
      const opening = stack.pop();
      if (opening !== undefined) openingForClosing.set(index, opening);
    } else if (character === '=' && nextCharacter === '>') {
      arrows.push(index);
      index++;
    }
  }
  const ranges = arrows
    .map(arrow => {
      let closing = arrow - 1;
      while (/\s/.test(value[closing] || '')) closing--;
      if (value[closing] !== ')') return null;
      const opening = openingForClosing.get(closing);
      return opening === undefined ? null : { opening, closing };
    })
    .filter(Boolean)
    .sort((left, right) => right.opening - left.opening);
  let result = value;
  for (const { opening, closing } of ranges) {
    const parameters = result.slice(opening + 1, closing);
    const strippedParameters = stripFlowParameterList(parameters);
    result =
      result.slice(0, opening + 1) +
      strippedParameters +
      result.slice(closing);
  }
  return result;
};

const stripCatalogFlowTypes = value => {
  let result = value
    .replace(/^\/\/ @flow\s*/, '')
    .replace(/import type[\s\S]*?;\s*/g, '');
  result = removeFlowTypeDeclarations(result);
  result = removeFlowVariableAnnotations(result);
  result = removeFlowReturnAnnotations(result);
  result = removeFlowArrowParameterAnnotations(result);
  return result
    .replace(
      /\(([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*\??[A-Z$][A-Za-z0-9_$]*(?:<[^>]+>)?\)/g,
      '($1)'
    )
    .replace(/\bnew (Promise|Map|Set)<[^>]+>/g, 'new $1');
};

moduleSource = stripCatalogFlowTypes(moduleSource);
const remainingFlowType = moduleSource.match(
  /import type|export type|^type\s|new (?:Promise|Map|Set)<|:\s*(?:mixed|string|number|boolean|void|Promise<|Array<|Set<|Map<)/m
);
if (remainingFlowType) {
  throw new Error(
    moduleSource.slice(
      Math.max(0, remainingFlowType.index - 80),
      remainingFlowType.index + 160
    )
  );
}

class PlaymeshCatalogError extends Error {
  constructor(code, message, retryable = false) {
    super(message);
    this.code = code;
    this.retryable = retryable;
  }
}

const ensureSafeRelativePath = value => {
  if (typeof value !== 'string' || !value || value.startsWith('/')) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录文件路径无效。');
  }
  const segments = value.split('/');
  if (segments.some(segment => !segment || segment === '.' || segment === '..')) {
    throw new PlaymeshCatalogError('invalid_manifest', '目录文件路径越界。');
  }
  return value;
};

const sha256Hex = async bytes => {
  const digest = await webcrypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)]
    .map(value => value.toString(16).padStart(2, '0'))
    .join('');
};

const examplesCommit = 'c'.repeat(40);
const examplesTree = 'd'.repeat(40);
const extensionCommit = 'e'.repeat(40);
const extensionTree = 'f'.repeat(40);
const examplesSource = {
  repository: 'GDevelopApp/GDevelop-examples',
  commit: examplesCommit,
  rootTreeSha: examplesTree,
};
const artifact = ({ relativePath, kind = 'example-resource', size = 3 }) => ({
  id: `${kind}:${relativePath}`,
  kind,
  repository: examplesSource.repository,
  commit: examplesSource.commit,
  rootTreeSha: examplesSource.rootTreeSha,
  path: `examples/fixture/${relativePath}`,
  url: `https://raw.githubusercontent.com/${examplesSource.repository}/${examplesSource.commit}/examples/fixture/${relativePath}`,
  declaredBytes: size,
  gitBlobOid: '1'.repeat(40),
  sha256: '2'.repeat(64),
  mediaType:
    kind === 'example-project'
      ? 'application/json'
      : relativePath.endsWith('.md') || relativePath.endsWith('.txt')
      ? 'text/plain'
      : 'image/png',
});

const state = {
  project: null,
  projectBytes: null,
  licenseBytes: null,
  fetchedKinds: [],
};

const projectArtifact = artifact({
  relativePath: 'fixture.json',
  kind: 'example-project',
  size: 1,
});
const imageArtifact = artifact({ relativePath: 'assets/image.png', size: 3 });
const unusedArtifact = artifact({ relativePath: 'assets/unused.png', size: 4 });
const licenseArtifact = artifact({
  relativePath: 'license.txt',
  kind: 'example-license',
  size: 18,
});
const compactFile = sourceArtifact => ({
  relativePath: sourceArtifact.path.slice('examples/fixture/'.length),
  declaredBytes: sourceArtifact.declaredBytes,
  gitBlobOid: sourceArtifact.gitBlobOid,
  sha256: sourceArtifact.sha256,
  mediaType: sourceArtifact.mediaType,
});
const header = {
  id: 'fixture',
  slug: 'fixture',
  root: 'examples/fixture',
  category: 'official-examples',
  name: 'Fixture',
  shortDescription: 'Fixture',
  description: 'Fixture example',
  tags: [],
  authors: ['GDevelop community'],
  engine: { version: '5.6.276' },
  gdevelopVersion: '5.6.276',
  project: projectArtifact,
  files: [
    compactFile(projectArtifact),
    compactFile(imageArtifact),
    compactFile(unusedArtifact),
    compactFile(licenseArtifact),
  ],
  license: {
    status: 'runtime-validation-required',
    defaultName: 'MIT',
    defaultSourceUrl: 'https://example.invalid/LICENSE',
    documents: [compactFile(licenseArtifact)],
  },
  preview: null,
  codeSizeLevel: 'small',
  declaredFileCount: 4,
  declaredRepositoryBytes:
    projectArtifact.declaredBytes +
    imageArtifact.declaredBytes +
    unusedArtifact.declaredBytes +
    licenseArtifact.declaredBytes,
};
const manifest = {
  schemaVersion: 1,
  catalogRevision: 'fixture-1',
  engine: { version: '5.6.276' },
  sources: {
    extensions: {
      repository: 'GDevelopApp/GDevelop-extensions',
      commit: extensionCommit,
      rootTreeSha: extensionTree,
    },
    examples: examplesSource,
  },
  limits: {
    catalogFileBytes: 1024 * 1024,
    extensionBytes: 1024 * 1024,
    exampleProjectBytes: 1024 * 1024,
    exampleResourceBytes: 1024 * 1024,
    exampleTotalBytes: 1024 * 1024,
    exampleResourceCount: 10,
    licenseFileBytes: 1024,
    licenseFileCount: 4,
    downloadConcurrency: 2,
    requestTimeoutMs: 1000,
    retryCount: 0,
  },
  features: {
    extensions: {
      path: 'extensions-manifest.v1.json',
      bytes: 1,
      sha256: '2'.repeat(64),
    },
    examples: {
      path: 'examples-manifest.v1.json',
      bytes: 1,
      sha256: '3'.repeat(64),
    },
  },
};
const index = {
  schemaVersion: 2,
  catalogRevision: manifest.catalogRevision,
  engine: manifest.engine,
  source: examplesSource,
  headers: [header],
};

const runtimeMocks = {
  PlaymeshCatalogError,
  ensureSafeRelativePath,
  validateArtifactUrl: value => value,
  validateCatalogFeatureManifest: ({ value }) => value,
  loadRootCatalogManifest: async () => manifest,
  loadCatalogJson: async ({ descriptor }) => {
    if (descriptor.path === 'examples-manifest.v1.json') {
      return {
        schemaVersion: 1,
        kind: 'examples',
        catalogRevision: manifest.catalogRevision,
        engine: manifest.engine,
        source: examplesSource,
        index: {
          path: 'examples-index.json',
          bytes: 1,
          sha256: '4'.repeat(64),
        },
      };
    }
    if (descriptor.path === 'examples-index.json') return index;
    throw new Error(`Unexpected descriptor: ${descriptor.path}`);
  },
  parseCatalogJsonArtifact: async ({ artifact: requestedArtifact }) => {
    state.fetchedKinds.push(requestedArtifact.kind);
    return {
      bytes: state.projectBytes,
      contentHash: await sha256Hex(state.projectBytes),
      mediaType: 'application/json',
      value: state.project,
    };
  },
  fetchCatalogArtifact: async ({ artifact: requestedArtifact }) => {
    state.fetchedKinds.push(requestedArtifact.kind);
    const bytes = state.licenseBytes;
    return {
      bytes,
      contentHash: await sha256Hex(bytes),
      mediaType: requestedArtifact.mediaType,
    };
  },
};

globalThis.__playmeshCatalogSourceMocks = runtimeMocks;
moduleSource = moduleSource.replace(
  /import \{[\s\S]*?\} from '\.\/PlaymeshCatalogRuntime';/,
  `const {
  PlaymeshCatalogError,
  ensureSafeRelativePath,
  fetchCatalogArtifact,
  loadCatalogJson,
  loadRootCatalogManifest,
  parseCatalogJsonArtifact,
  validateCatalogFeatureManifest,
  validateArtifactUrl,
} = globalThis.__playmeshCatalogSourceMocks;`
);
const catalogSource = await import(
  `data:text/javascript;base64,${Buffer.from(moduleSource, 'utf8').toString('base64')}`
);

globalThis.document = { baseURI: 'http://127.0.0.1:8768/' };
globalThis.window = { crypto: webcrypto };

const encodeBuffer = value => {
  const view = new TextEncoder().encode(value);
  return view.buffer.slice(view.byteOffset, view.byteOffset + view.byteLength);
};
const installProject = resourceFiles => {
  state.project = {
    gdVersion: { major: 5, minor: 6 },
    properties: { name: 'Fixture', extensions: [] },
    resources: {
      resources: resourceFiles.map((file, index) => ({
        name: `Resource${index}`,
        file,
        kind: 'image',
      })),
    },
    layouts: [],
  };
  state.projectBytes = encodeBuffer(JSON.stringify(state.project));
  projectArtifact.declaredBytes = state.projectBytes.byteLength;
  header.files[0].declaredBytes = state.projectBytes.byteLength;
  state.licenseBytes = encodeBuffer('MIT License\nFixture');
  licenseArtifact.declaredBytes = state.licenseBytes.byteLength;
  header.files.find(file => file.relativePath === 'license.txt').declaredBytes =
    state.licenseBytes.byteLength;
  header.license.documents[0].declaredBytes = state.licenseBytes.byteLength;
  state.fetchedKinds = [];
};

const reset = () => catalogSource.resetPlaymeshCatalogForRetry();

installProject(['assets/image.png', 'data:image/png;base64,AA==']);
let inspection = await catalogSource.inspectPlaymeshExampleLicense({ header });
assert.equal(inspection.status, 'open');
assert.deepEqual(state.fetchedKinds, ['example-license']);
state.fetchedKinds = [];
let result = await catalogSource.getPlaymeshExampleManifest({ header });
assert.equal(result.exampleManifest.resources.length, 1);
assert.equal(result.exampleManifest.resources[0].file, 'assets/image.png');
assert.equal(result.exampleManifest.resources[0].artifact.path, imageArtifact.path);
assert.deepEqual(state.fetchedKinds, ['example-project', 'example-license']);
assert.equal(
  result.exampleManifest.resources.some(resource => resource.file === 'assets/unused.png'),
  false
);
assert.equal(result.exampleManifest.license.name, 'MIT');
assert.equal(result.exampleManifest.license.status, 'open');
assert.match(result.exampleManifest.license.evidenceKey, /^fixture\|open\|MIT\|/);

installProject(['https://example.invalid/image.png']);
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'external_resource'
);

installProject(['../secret.png']);
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'invalid_manifest'
);

installProject(['assets/missing.png']);
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'missing_resource'
);

installProject(['assets/image.png']);
state.licenseBytes = encodeBuffer('Credits: third-party art, terms unspecified.');
licenseArtifact.declaredBytes = state.licenseBytes.byteLength;
header.files.find(file => file.relativePath === 'license.txt').declaredBytes =
  state.licenseBytes.byteLength;
header.license.documents[0].declaredBytes = state.licenseBytes.byteLength;
reset();
result = await catalogSource.getPlaymeshExampleManifest({ header });
assert.equal(result.exampleManifest.license.status, 'unknown');

installProject(['assets/image.png']);
state.licenseBytes = encodeBuffer(
  'All rights reserved. Redistribution is prohibited.'
);
licenseArtifact.declaredBytes = state.licenseBytes.byteLength;
header.files.find(file => file.relativePath === 'license.txt').declaredBytes =
  state.licenseBytes.byteLength;
header.license.documents[0].declaredBytes = state.licenseBytes.byteLength;
reset();
result = await catalogSource.getPlaymeshExampleManifest({ header });
assert.equal(result.exampleManifest.license.status, 'non-open');

installProject(['assets/image.png']);
state.licenseBytes = encodeBuffer(
  'MIT License. All rights reserved. Redistribution is prohibited.'
);
licenseArtifact.declaredBytes = state.licenseBytes.byteLength;
header.files.find(file => file.relativePath === 'license.txt').declaredBytes =
  state.licenseBytes.byteLength;
header.license.documents[0].declaredBytes = state.licenseBytes.byteLength;
reset();
result = await catalogSource.getPlaymeshExampleManifest({ header });
assert.equal(result.exampleManifest.license.status, 'conflict');

installProject(['assets/image.png']);
state.licenseBytes = encodeBuffer('MIT License. Copyright holder. All rights reserved.');
licenseArtifact.declaredBytes = state.licenseBytes.byteLength;
header.files.find(file => file.relativePath === 'license.txt').declaredBytes =
  state.licenseBytes.byteLength;
header.license.documents[0].declaredBytes = state.licenseBytes.byteLength;
reset();
result = await catalogSource.getPlaymeshExampleManifest({ header });
assert.equal(
  result.exampleManifest.license.status,
  'open',
  'copyright reservation alone must not override an explicit open licence'
);
assert.deepEqual(result.exampleManifest.license.documents[0].copyrightNotices, [
  'MIT License. Copyright holder. All rights reserved.',
]);

installProject(['assets/image.png']);
state.licenseBytes = encodeBuffer('Creative Commons CC-BY-NC-4.0');
licenseArtifact.declaredBytes = state.licenseBytes.byteLength;
header.files.find(file => file.relativePath === 'license.txt').declaredBytes =
  state.licenseBytes.byteLength;
header.license.documents[0].declaredBytes = state.licenseBytes.byteLength;
reset();
result = await catalogSource.getPlaymeshExampleManifest({ header });
assert.equal(result.exampleManifest.license.status, 'non-open');

installProject(['assets/image.png']);
manifest.limits.exampleResourceCount = 0;
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'too_many_resources'
);
manifest.limits.exampleResourceCount = 10;

manifest.limits.exampleTotalBytes = state.projectBytes.byteLength + 2;
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'too_large'
);
manifest.limits.exampleTotalBytes = 1024 * 1024;

manifest.limits.licenseFileCount = 0;
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'license_too_large'
);
manifest.limits.licenseFileCount = 4;

manifest.limits.licenseFileBytes = state.licenseBytes.byteLength - 1;
reset();
await assert.rejects(
  catalogSource.getPlaymeshExampleManifest({ header }),
  error => error.code === 'license_too_large'
);
manifest.limits.licenseFileBytes = 1024;

process.stdout.write(
  'GDevelop catalog project-reference/license/limit tests passed.\n'
);
