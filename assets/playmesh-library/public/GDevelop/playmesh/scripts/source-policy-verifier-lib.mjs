import { createHash } from 'node:crypto';
import { lstat, readFile, readdir } from 'node:fs/promises';
import path from 'node:path';

export const PENDING_DIGEST = 'pending';

const sha256Pattern = /^[a-f0-9]{64}$/;
const gitBlobShaPattern = /^[a-f0-9]{40}$/;
const compareText = (left, right) => (left < right ? -1 : left > right ? 1 : 0);

const withoutClauseComments = source =>
  source
    .replace(/\/\*[\s\S]*?\*\//g, ' ')
    .replace(/\/\/[^\r\n]*/g, ' ')
    .trim();

const splitTopLevelCommaSeparated = source => {
  const entries = [];
  let start = 0;
  let parenthesisDepth = 0;
  let bracketDepth = 0;
  let braceDepth = 0;
  for (let index = 0; index < source.length; index += 1) {
    switch (source[index]) {
      case '(':
        parenthesisDepth += 1;
        break;
      case ')':
        parenthesisDepth -= 1;
        break;
      case '[':
        bracketDepth += 1;
        break;
      case ']':
        bracketDepth -= 1;
        break;
      case '{':
        braceDepth += 1;
        break;
      case '}':
        braceDepth -= 1;
        break;
      case ',':
        if (parenthesisDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
          entries.push(source.slice(start, index));
          start = index + 1;
        }
        break;
      default:
        break;
    }
    if (parenthesisDepth < 0 || bracketDepth < 0 || braceDepth < 0) {
      throw new Error('Static module clause has unbalanced delimiters');
    }
  }
  if (parenthesisDepth !== 0 || bracketDepth !== 0 || braceDepth !== 0) {
    throw new Error('Static module clause has unbalanced delimiters');
  }
  entries.push(source.slice(start));
  return entries;
};

const parseNamedImportEntry = entry => {
  const tokens = withoutClauseComments(entry).match(/[A-Za-z_$][\w$]*/g) || [];
  if (tokens.length === 0) return null;

  let importKind = 'value';
  let nameIndex = 0;
  // `type as local` imports the value literally named `type`. Flow's inline
  // modifier always has another identifier before an optional `as` alias.
  if (
    (tokens[0] === 'type' || tokens[0] === 'typeof') &&
    tokens.length >= 2 &&
    tokens[1] !== 'as'
  ) {
    importKind = tokens[0];
    nameIndex = 1;
  }
  const importedName = tokens[nameIndex];
  const trailingTokens = tokens.slice(nameIndex + 1);
  let localName = importedName;
  if (trailingTokens.length > 0) {
    if (trailingTokens.length !== 2 || trailingTokens[0] !== 'as') {
      throw new Error(
        `Unsupported named import entry: ${JSON.stringify(entry)}`
      );
    }
    localName = trailingTokens[1];
  }
  return { importedName, localName, importKind };
};

const parseNamedImportBlock = source => {
  const trimmed = withoutClauseComments(source);
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
    throw new Error(`Invalid named import block: ${JSON.stringify(source)}`);
  }
  return splitTopLevelCommaSeparated(trimmed.slice(1, -1))
    .map(parseNamedImportEntry)
    .filter(Boolean);
};

/**
 * Parse the binding clause between `import` and `from` without conflating
 * Flow declaration modifiers with JavaScript default bindings.
 */
export const parseStaticImportClause = source => {
  if (typeof source !== 'string' || !source.trim()) {
    throw new Error('Static import clause must be a non-empty string');
  }
  let clause = withoutClauseComments(source);
  let declarationKind = 'value';
  const declarationKindMatch = clause.match(
    /^(type|typeof)\s+(?=\{|\*|[A-Za-z_$])/
  );
  if (declarationKindMatch) {
    declarationKind = declarationKindMatch[1];
    clause = clause.slice(declarationKindMatch[0].length).trim();
  }

  let defaultImport = null;
  let namespaceImport = null;
  let namedImports = [];
  if (clause.startsWith('{')) {
    namedImports = parseNamedImportBlock(clause);
  } else if (clause.startsWith('*')) {
    const namespaceMatch = clause.match(/^\*\s+as\s+([A-Za-z_$][\w$]*)$/);
    if (!namespaceMatch) {
      throw new Error(`Invalid namespace import: ${JSON.stringify(source)}`);
    }
    namespaceImport = namespaceMatch[1];
  } else {
    const defaultMatch = clause.match(/^([A-Za-z_$][\w$]*)([\s\S]*)$/);
    if (!defaultMatch) {
      throw new Error(`Invalid default import: ${JSON.stringify(source)}`);
    }
    defaultImport = defaultMatch[1];
    const remainder = defaultMatch[2].trim();
    if (remainder) {
      if (!remainder.startsWith(',')) {
        throw new Error(`Invalid mixed import: ${JSON.stringify(source)}`);
      }
      const secondaryClause = remainder.slice(1).trim();
      if (secondaryClause.startsWith('{')) {
        namedImports = parseNamedImportBlock(secondaryClause);
      } else {
        const namespaceMatch = secondaryClause.match(
          /^\*\s+as\s+([A-Za-z_$][\w$]*)$/
        );
        if (!namespaceMatch) {
          throw new Error(`Invalid mixed import: ${JSON.stringify(source)}`);
        }
        namespaceImport = namespaceMatch[1];
      }
    }
  }

  return {
    declarationKind,
    defaultImport,
    namespaceImport,
    namedImports,
  };
};

const maskJavaScriptTrivia = source => {
  const output = [...source];
  const mask = index => {
    if (output[index] !== '\n' && output[index] !== '\r') output[index] = ' ';
  };
  let index = 0;
  while (index < source.length) {
    const character = source[index];
    const nextCharacter = source[index + 1];
    if (character === '/' && nextCharacter === '/') {
      while (index < source.length && source[index] !== '\n') {
        mask(index);
        index += 1;
      }
      continue;
    }
    if (character === '/' && nextCharacter === '*') {
      const isFlowComment = source.startsWith('/*::', index);
      const end = source.indexOf('*/', index + 2);
      const endExclusive = end === -1 ? source.length : end + 2;
      if (isFlowComment) {
        for (let marker = index; marker < index + 4; marker += 1) mask(marker);
        if (end !== -1) {
          mask(end);
          mask(end + 1);
        }
      } else {
        while (index < endExclusive) {
          mask(index);
          index += 1;
        }
        continue;
      }
      index = endExclusive;
      continue;
    }
    if (character === "'" || character === '"' || character === '`') {
      const quote = character;
      mask(index);
      index += 1;
      while (index < source.length) {
        const quotedCharacter = source[index];
        mask(index);
        index += 1;
        if (quotedCharacter === '\\' && index < source.length) {
          mask(index);
          index += 1;
          continue;
        }
        if (quotedCharacter === quote) break;
      }
      continue;
    }
    index += 1;
  }
  return output.join('');
};

const findMatchingBrace = (source, openingIndex) => {
  let depth = 0;
  for (let index = openingIndex; index < source.length; index += 1) {
    if (source[index] === '{') depth += 1;
    else if (source[index] === '}') {
      depth -= 1;
      if (depth === 0) return index;
    }
  }
  throw new Error('Static module export object has an unmatched opening brace');
};

const addExportListEntries = ({ source, namedExports, setDefaultExport }) => {
  for (const entry of splitTopLevelCommaSeparated(source)) {
    const tokens =
      withoutClauseComments(entry).match(/[A-Za-z_$][\w$]*/g) || [];
    if (tokens.length === 0) continue;
    let nameIndex = 0;
    if (
      (tokens[0] === 'type' || tokens[0] === 'typeof') &&
      tokens.length >= 2 &&
      tokens[1] !== 'as'
    ) {
      nameIndex = 1;
    }
    const localName = tokens[nameIndex];
    const trailingTokens = tokens.slice(nameIndex + 1);
    let exportedName = localName;
    if (trailingTokens.length > 0) {
      if (trailingTokens.length !== 2 || trailingTokens[0] !== 'as') {
        throw new Error(
          `Unsupported export list entry: ${JSON.stringify(entry)}`
        );
      }
      exportedName = trailingTokens[1];
    }
    if (exportedName === 'default') setDefaultExport();
    else namedExports.add(exportedName);
  }
};

const addCommonJsObjectExports = ({ source, namedExports }) => {
  for (const entry of splitTopLevelCommaSeparated(source)) {
    const normalized = entry.trim();
    if (!normalized || normalized.startsWith('...') || normalized[0] === '[') {
      continue;
    }
    const propertyMatch = normalized.match(
      /^(?:(?:get|set|async)\s+)?([A-Za-z_$][\w$]*)(?:\s*:|\s*\(|\s*=|\s*$)/
    );
    if (propertyMatch) namedExports.add(propertyMatch[1]);
  }
};

/** Collect statically provable ES-module and CommonJS exports. */
export const collectStaticModuleExports = source => {
  if (typeof source !== 'string') {
    throw new Error('Static module source must be a string');
  }
  const maskedSource = maskJavaScriptTrivia(source);
  const namedExports = new Set();
  let hasDefaultExport = false;
  let usesCommonJs = false;
  const setDefaultExport = () => {
    hasDefaultExport = true;
  };

  const declarationPattern = /(?:^|[;}\r\n])\s*export\s+(?:(?:declare|async)\s+)*(?:(?:opaque\s+)?type|interface|enum|const|let|var|function|class)\s+([A-Za-z_$][\w$]*)/g;
  for (const match of maskedSource.matchAll(declarationPattern)) {
    namedExports.add(match[1]);
  }
  if (
    /(?:^|[;}\r\n])\s*export\s+default(?:\s|\{|\(|[A-Za-z_$])/m.test(
      maskedSource
    )
  ) {
    hasDefaultExport = true;
  }

  const exportListPattern = /(?:^|[;}\r\n])\s*export\s+(?:(?:type|typeof)\s+)?\{/g;
  for (const match of maskedSource.matchAll(exportListPattern)) {
    const openingBrace = maskedSource.indexOf('{', match.index);
    const closingBrace = findMatchingBrace(maskedSource, openingBrace);
    addExportListEntries({
      source: maskedSource.slice(openingBrace + 1, closingBrace),
      namedExports,
      setDefaultExport,
    });
  }

  const commonJsObjectPattern = /\bmodule\s*\.\s*exports\s*=\s*\{/g;
  for (const match of maskedSource.matchAll(commonJsObjectPattern)) {
    usesCommonJs = true;
    hasDefaultExport = true;
    const openingBrace = maskedSource.indexOf('{', match.index);
    const closingBrace = findMatchingBrace(maskedSource, openingBrace);
    addCommonJsObjectExports({
      source: maskedSource.slice(openingBrace + 1, closingBrace),
      namedExports,
    });
  }
  if (/\bmodule\s*\.\s*exports\s*=/.test(maskedSource)) {
    usesCommonJs = true;
    hasDefaultExport = true;
  }
  const commonJsPropertyPattern = /\b(?:(?:module\s*\.\s*)?exports)\s*\.\s*([A-Za-z_$][\w$]*)\s*=/g;
  for (const match of maskedSource.matchAll(commonJsPropertyPattern)) {
    usesCommonJs = true;
    namedExports.add(match[1]);
  }

  return {
    hasDefaultExport,
    namedExports: [...namedExports].sort(compareText),
    usesCommonJs,
  };
};

/** Compare one static import clause with one resolved module's export surface. */
export const verifyStaticModuleImportContract = ({
  importClause,
  moduleSource,
}) => {
  const parsedImport = parseStaticImportClause(importClause);
  const moduleExports = collectStaticModuleExports(moduleSource);
  const namedExports = new Set(moduleExports.namedExports);
  return {
    parsedImport,
    moduleExports,
    missingDefault:
      parsedImport.defaultImport !== null && !moduleExports.hasDefaultExport,
    missingNamed: parsedImport.namedImports
      .map(binding => binding.importedName)
      .filter(name => !namedExports.has(name)),
  };
};

export const sha256Bytes = bytes =>
  createHash('sha256')
    .update(bytes)
    .digest('hex');

export const normalizePolicyRelativePath = (value, label = 'relativePath') => {
  if (typeof value !== 'string' || !value) {
    throw new Error(`${label} must be a non-empty POSIX relative path`);
  }
  if (
    value.includes('\\') ||
    value.startsWith('/') ||
    /^[A-Za-z]:/.test(value) ||
    path.posix.normalize(value) !== value ||
    value
      .split('/')
      .some(segment => !segment || segment === '.' || segment === '..')
  ) {
    throw new Error(
      `${label} is unsafe or non-canonical: ${JSON.stringify(value)}`
    );
  }
  return value;
};

const assertDigest = (value, label) => {
  if (value !== PENDING_DIGEST && !sha256Pattern.test(value || '')) {
    throw new Error(`${label} must be "pending" or a lowercase SHA-256 digest`);
  }
};

const validateOutputEntries = ({ entries, label, requireUpstreamSha }) => {
  if (!Array.isArray(entries) || entries.length === 0) {
    throw new Error(`${label} must be a non-empty array`);
  }
  const seenPaths = new Set();
  return entries.map((entry, index) => {
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new Error(`${label}[${index}] must be an object`);
    }
    const relativePath = normalizePolicyRelativePath(
      entry.relativePath,
      `${label}[${index}].relativePath`
    );
    if (seenPaths.has(relativePath)) {
      throw new Error(`${label} contains duplicate path: ${relativePath}`);
    }
    seenPaths.add(relativePath);
    if (
      requireUpstreamSha &&
      !gitBlobShaPattern.test(entry.upstreamGitBlobSha || '')
    ) {
      throw new Error(
        `${label}[${index}].upstreamGitBlobSha must be a lowercase Git blob SHA-1`
      );
    }
    assertDigest(entry.postPatchSha256, `${label}[${index}].postPatchSha256`);
    return {
      relativePath,
      ...(requireUpstreamSha
        ? { upstreamGitBlobSha: entry.upstreamGitBlobSha }
        : {}),
      postPatchSha256: entry.postPatchSha256,
    };
  });
};

export const validateSourcePolicyOutputManifest = manifest => {
  if (!manifest || typeof manifest !== 'object' || Array.isArray(manifest)) {
    throw new Error('Source-policy output manifest must be an object');
  }
  if (manifest.schemaVersion !== 1) {
    throw new Error(
      `Unsupported source-policy output manifest schema: ${
        manifest.schemaVersion
      }`
    );
  }
  if (!/^v\d+\.\d+\.\d+$/.test(manifest.upstream?.tag || '')) {
    throw new Error(
      'Source-policy output manifest has an invalid upstream tag'
    );
  }
  if (!gitBlobShaPattern.test(manifest.upstream?.commit || '')) {
    throw new Error(
      'Source-policy output manifest has an invalid upstream commit'
    );
  }
  assertDigest(manifest.overlay?.treeSha256, 'overlay.treeSha256');

  const generatedFiles = validateOutputEntries({
    entries: manifest.generatedFiles,
    label: 'generatedFiles',
    requireUpstreamSha: false,
  });
  const patchedOfficialFiles = validateOutputEntries({
    entries: manifest.patchedOfficialFiles,
    label: 'patchedOfficialFiles',
    requireUpstreamSha: true,
  });
  const allPaths = new Set();
  for (const entry of [...generatedFiles, ...patchedOfficialFiles]) {
    if (allPaths.has(entry.relativePath)) {
      throw new Error(
        `Source-policy output manifest reuses output path: ${
          entry.relativePath
        }`
      );
    }
    allPaths.add(entry.relativePath);
  }

  return {
    schemaVersion: 1,
    upstream: {
      tag: manifest.upstream.tag,
      commit: manifest.upstream.commit,
    },
    overlay: { treeSha256: manifest.overlay.treeSha256 },
    generatedFiles,
    patchedOfficialFiles,
  };
};

export const loadSourcePolicyOutputManifest = async manifestPath =>
  validateSourcePolicyOutputManifest(
    JSON.parse(await readFile(manifestPath, 'utf8'))
  );

const walkDirectory = async (
  rootDirectory,
  currentDirectory = rootDirectory
) => {
  const output = [];
  const entries = await readdir(currentDirectory, { withFileTypes: true });
  entries.sort((left, right) => compareText(left.name, right.name));
  for (const entry of entries) {
    const entryPath = path.join(currentDirectory, entry.name);
    const relativePath = path
      .relative(rootDirectory, entryPath)
      .split(path.sep)
      .join('/');
    if (entry.isSymbolicLink()) {
      output.push({ relativePath, type: 'symlink', absolutePath: entryPath });
    } else if (entry.isDirectory()) {
      output.push(...(await walkDirectory(rootDirectory, entryPath)));
    } else if (entry.isFile()) {
      output.push({ relativePath, type: 'file', absolutePath: entryPath });
    } else {
      output.push({ relativePath, type: 'other', absolutePath: entryPath });
    }
  }
  return output;
};

export const listRegularFiles = async directory => {
  const entries = await walkDirectory(directory);
  const unsupported = entries.filter(entry => entry.type !== 'file');
  if (unsupported.length > 0) {
    throw new Error(
      `Directory contains non-regular entries:\n${unsupported
        .map(entry => `- ${entry.relativePath} (${entry.type})`)
        .join('\n')}`
    );
  }
  return entries;
};

const uint64 = value => {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64BE(BigInt(value));
  return bytes;
};

export const computeDirectoryTreeDigest = async directory => {
  const files = await listRegularFiles(directory);
  const hash = createHash('sha256');
  hash.update('playmesh-source-policy-tree-v1\0', 'utf8');
  const summaries = [];
  for (const file of files) {
    // 路径与内容都使用定长前缀分帧，避免拼接歧义并保持跨平台摘要一致。
    const relativePathBytes = Buffer.from(file.relativePath, 'utf8');
    const bytes = await readFile(file.absolutePath);
    hash.update(uint64(relativePathBytes.byteLength));
    hash.update(relativePathBytes);
    hash.update(uint64(bytes.byteLength));
    hash.update(bytes);
    summaries.push({
      relativePath: file.relativePath,
      bytes: bytes.byteLength,
      sha256: sha256Bytes(bytes),
    });
  }
  return { sha256: hash.digest('hex'), files: summaries };
};

const outputEntryMap = (entries, label) => {
  if (!Array.isArray(entries))
    throw new Error(`${label} records must be an array`);
  const output = new Map();
  for (const entry of entries) {
    const relativePath = normalizePolicyRelativePath(
      entry?.relativePath,
      `${label} record path`
    );
    if (output.has(relativePath)) {
      throw new Error(
        `${label} records contain duplicate path: ${relativePath}`
      );
    }
    output.set(relativePath, entry);
  }
  return output;
};

const formatPathList = paths => paths.map(item => `- ${item}`).join('\n');

export const verifyOverlayTreeDigest = async ({
  manifest,
  overlayDirectory,
  allowPending = false,
}) => {
  const tree = await computeDirectoryTreeDigest(overlayDirectory);
  if (manifest.overlay.treeSha256 === PENDING_DIGEST) {
    if (!allowPending) {
      throw new Error(
        `overlay.treeSha256 is pending; freeze it as ${
          tree.sha256
        } before release`
      );
    }
    return {
      ...tree,
      warnings: [
        `PENDING OUTPUT MANIFEST: overlay.treeSha256 must be frozen as ${
          tree.sha256
        }`,
      ],
    };
  }
  if (manifest.overlay.treeSha256 !== tree.sha256) {
    throw new Error(
      `Overlay tree digest mismatch. Expected ${
        manifest.overlay.treeSha256
      }, got ${tree.sha256}`
    );
  }
  return { ...tree, warnings: [] };
};

export const verifyOutputManifestFreezeState = ({
  manifest,
  allowPending = false,
}) => {
  const pendingLabels = [];
  if (manifest.overlay.treeSha256 === PENDING_DIGEST) {
    pendingLabels.push('overlay.treeSha256');
  }
  for (const entry of manifest.generatedFiles) {
    if (entry.postPatchSha256 === PENDING_DIGEST) {
      pendingLabels.push(`${entry.relativePath} postPatchSha256`);
    }
  }
  for (const entry of manifest.patchedOfficialFiles) {
    if (entry.postPatchSha256 === PENDING_DIGEST) {
      pendingLabels.push(`${entry.relativePath} postPatchSha256`);
    }
  }
  if (pendingLabels.length > 0 && !allowPending) {
    throw new Error(
      `Source-policy output manifest is not frozen:\n${formatPathList(
        pendingLabels
      )}`
    );
  }
  return {
    pendingLabels,
    warnings: pendingLabels.map(
      label => `PENDING OUTPUT MANIFEST: ${label} is not frozen`
    ),
  };
};

const isPlaymeshOwnedPath = relativePath =>
  relativePath.split('/').some(segment => /playmesh/i.test(segment));

const deriveOwnershipScanRoots = expectedPaths => {
  const roots = new Set();
  for (const relativePath of expectedPaths) {
    const segments = relativePath.split('/');
    // 从首个 Playmesh 标记的父目录扫描，才能发现已从 canonical 树删除的旧目录。
    const firstOwnedSegment = segments.findIndex(segment =>
      /playmesh/i.test(segment)
    );
    if (firstOwnedSegment === -1) {
      throw new Error(
        `Playmesh-owned output path lacks a Playmesh marker: ${relativePath}`
      );
    }
    const prefix = segments.slice(0, firstOwnedSegment).join('/');
    roots.add(prefix || '.');
  }
  const ordered = [...roots].sort((left, right) => {
    const depthDifference = left.split('/').length - right.split('/').length;
    return depthDifference || compareText(left, right);
  });
  return ordered.filter(
    candidate =>
      !ordered.some(
        parent =>
          parent !== candidate &&
          (parent === '.' || candidate.startsWith(`${parent}/`))
      )
  );
};

export const verifyBidirectionalOverlayOutput = async ({
  overlayDirectory,
  sourceRoot,
  generatedFiles,
}) => {
  const overlayFiles = await listRegularFiles(overlayDirectory);
  const overlayPaths = overlayFiles.map(file => file.relativePath);
  const generatedPaths = generatedFiles.map(entry =>
    normalizePolicyRelativePath(
      entry.relativePath,
      'generatedFiles.relativePath'
    )
  );
  const allRecordedPaths = [...overlayPaths, ...generatedPaths].sort(compareText);
  const expectedPlaymeshOwnedPaths = [
    ...overlayPaths,
    ...generatedPaths.filter(isPlaymeshOwnedPath),
  ].sort(compareText);
  const duplicatePaths = allRecordedPaths.filter(
    (item, index) => index > 0 && item === allRecordedPaths[index - 1]
  );
  if (duplicatePaths.length > 0) {
    throw new Error(
      `Overlay and generated output paths overlap:\n${formatPathList(
        duplicatePaths
      )}`
    );
  }

  const contentErrors = [];
  for (const overlayFile of overlayFiles) {
    const targetPath = path.join(
      sourceRoot,
      ...overlayFile.relativePath.split('/')
    );
    try {
      const targetStat = await lstat(targetPath);
      if (!targetStat.isFile() || targetStat.isSymbolicLink()) {
        contentErrors.push(
          `${overlayFile.relativePath}: target is not a regular file`
        );
        continue;
      }
      const [canonicalBytes, targetBytes] = await Promise.all([
        readFile(overlayFile.absolutePath),
        readFile(targetPath),
      ]);
      if (!canonicalBytes.equals(targetBytes)) {
        contentErrors.push(`${overlayFile.relativePath}: target bytes differ`);
      }
    } catch (error) {
      if (error?.code === 'ENOENT') {
        contentErrors.push(`${overlayFile.relativePath}: target is missing`);
      } else {
        throw error;
      }
    }
  }
  if (contentErrors.length > 0) {
    throw new Error(
      `Overlay output mismatch:\n${formatPathList(contentErrors)}`
    );
  }

  const actualOwnedPaths = new Set();
  const unsupportedOwnedPaths = [];
  // Generated files under a Playmesh-owned path participate in stale-file
  // detection. Generated official source paths are verified by their recorded
  // digest but must not be reclassified as Playmesh-owned.
  for (const scanRoot of deriveOwnershipScanRoots(expectedPlaymeshOwnedPaths)) {
    const absoluteScanRoot =
      scanRoot === '.'
        ? sourceRoot
        : path.join(sourceRoot, ...scanRoot.split('/'));
    const entries = await walkDirectory(absoluteScanRoot);
    for (const entry of entries) {
      const sourceRelativePath =
        scanRoot === '.'
          ? entry.relativePath
          : `${scanRoot}/${entry.relativePath}`;
      if (!isPlaymeshOwnedPath(sourceRelativePath)) continue;
      if (entry.type !== 'file') {
        unsupportedOwnedPaths.push(`${sourceRelativePath} (${entry.type})`);
      } else {
        actualOwnedPaths.add(sourceRelativePath);
      }
    }
  }

  const expectedOwnedPaths = new Set(expectedPlaymeshOwnedPaths);
  const missing = [...expectedOwnedPaths]
    .filter(item => !actualOwnedPaths.has(item))
    .sort();
  const extra = [...actualOwnedPaths]
    .filter(item => !expectedOwnedPaths.has(item))
    .sort();
  if (
    missing.length > 0 ||
    extra.length > 0 ||
    unsupportedOwnedPaths.length > 0
  ) {
    const sections = [];
    if (missing.length > 0) {
      sections.push(
        `Missing Playmesh-owned files:\n${formatPathList(missing)}`
      );
    }
    if (extra.length > 0) {
      sections.push(
        `Unexpected stale Playmesh-owned files:\n${formatPathList(extra)}`
      );
    }
    if (unsupportedOwnedPaths.length > 0) {
      sections.push(
        `Non-regular Playmesh-owned entries:\n${formatPathList(
          unsupportedOwnedPaths.sort()
        )}`
      );
    }
    throw new Error(sections.join('\n'));
  }

  return {
    overlayFiles: overlayPaths,
    generatedFiles: generatedPaths,
    ownedFiles: [...actualOwnedPaths].sort(),
  };
};

const compareRecordSets = ({ expectedEntries, actualEntries, label }) => {
  const expected = outputEntryMap(expectedEntries, `Expected ${label}`);
  const actual = outputEntryMap(actualEntries, `Observed ${label}`);
  const missing = [...expected.keys()].filter(item => !actual.has(item)).sort();
  const extra = [...actual.keys()].filter(item => !expected.has(item)).sort();
  if (missing.length > 0 || extra.length > 0) {
    throw new Error(
      `${label} set differs from the output manifest.` +
        `${
          missing.length ? `\nMissing records:\n${formatPathList(missing)}` : ''
        }` +
        `${
          extra.length ? `\nUnexpected records:\n${formatPathList(extra)}` : ''
        }`
    );
  }
  return { expected, actual };
};

export const verifyRecordedSourcePolicyOutputs = ({
  manifest,
  patchedOfficialFiles,
  generatedFiles,
  allowPending = false,
}) => {
  const warnings = [];
  const groups = [
    {
      label: 'Patched official files',
      expectedEntries: manifest.patchedOfficialFiles,
      actualEntries: patchedOfficialFiles,
      requireUpstreamSha: true,
    },
    {
      label: 'Generated files',
      expectedEntries: manifest.generatedFiles,
      actualEntries: generatedFiles,
      requireUpstreamSha: false,
    },
  ];
  for (const group of groups) {
    const { expected, actual } = compareRecordSets(group);
    for (const [relativePath, expectedEntry] of expected) {
      const actualEntry = actual.get(relativePath);
      if (
        group.requireUpstreamSha &&
        actualEntry.upstreamGitBlobSha !== expectedEntry.upstreamGitBlobSha
      ) {
        throw new Error(
          `${relativePath} upstream Git blob SHA differs from the output manifest. ` +
            `Expected ${expectedEntry.upstreamGitBlobSha}, got ${
              actualEntry.upstreamGitBlobSha
            }`
        );
      }
      if (!sha256Pattern.test(actualEntry.postPatchSha256 || '')) {
        throw new Error(
          `${relativePath} has an invalid observed post-patch SHA-256`
        );
      }
      if (expectedEntry.postPatchSha256 === PENDING_DIGEST) {
        if (!allowPending) {
          throw new Error(
            `${relativePath} postPatchSha256 is pending; freeze it as ${
              actualEntry.postPatchSha256
            } before release`
          );
        }
        warnings.push(
          `PENDING OUTPUT MANIFEST: ${relativePath} postPatchSha256 must be frozen as ${
            actualEntry.postPatchSha256
          }`
        );
      } else if (
        actualEntry.postPatchSha256 !== expectedEntry.postPatchSha256
      ) {
        throw new Error(
          `${relativePath} post-patch digest mismatch. Expected ${
            expectedEntry.postPatchSha256
          }, got ${actualEntry.postPatchSha256}`
        );
      }
    }
  }
  return { warnings };
};

export const collectOutputRecordsFromSourceTree = async ({
  manifest,
  sourceRoot,
}) => {
  const collect = async entries =>
    Promise.all(
      entries.map(async entry => {
        const filePath = path.join(
          sourceRoot,
          ...entry.relativePath.split('/')
        );
        const fileStat = await lstat(filePath);
        if (!fileStat.isFile() || fileStat.isSymbolicLink()) {
          throw new Error(`${entry.relativePath} is not a regular output file`);
        }
        return {
          relativePath: entry.relativePath,
          ...('upstreamGitBlobSha' in entry
            ? { upstreamGitBlobSha: entry.upstreamGitBlobSha }
            : {}),
          postPatchSha256: sha256Bytes(await readFile(filePath)),
        };
      })
    );
  return {
    patchedOfficialFiles: await collect(manifest.patchedOfficialFiles),
    generatedFiles: await collect(manifest.generatedFiles),
  };
};

export const assertManifestMatchesWebIdeLock = ({ manifest, lock }) => {
  if (
    manifest.upstream.tag !== lock.upstream?.tag ||
    manifest.upstream.commit !== lock.upstream?.commit
  ) {
    throw new Error(
      'Source-policy output manifest upstream identity differs from webide-lock.json'
    );
  }
};

export const parseExpectedAiState = argv => {
  const indexes = argv.reduce((output, value, index) => {
    if (value === '--expect-ai') output.push(index);
    return output;
  }, []);
  const value = indexes.length === 1 ? argv[indexes[0] + 1] || null : null;
  if (indexes.length !== 1 || value !== 'session-bootstrap') {
    throw new Error('Required exactly once: --expect-ai session-bootstrap');
  }
  return value;
};

export const verifyExpectedAiFeatureState = ({
  featureFlagsSource,
  expectedAiState,
}) => {
  if (expectedAiState !== 'session-bootstrap') {
    throw new Error(`Invalid expected AI state: ${expectedAiState}`);
  }
  if (/\bisPlaymeshAiEnabled\s*=/.test(featureFlagsSource)) {
    throw new Error(
      'Production AI policy must not contain a build-time boolean assignment'
    );
  }
  for (const contract of [
    /__PLAYMESH_GDEVELOP_AI_FEATURE_POLICY__/,
    /FEATURE_POLICY_FORMAT_VERSION/,
    /EVENTS_PATH_TEMPLATE/,
    /return policyRecord\.enabled === true/,
    /export default getIsPlaymeshAiEnabled/,
  ]) {
    if (!contract.test(featureFlagsSource)) {
      throw new Error(
        'Production AI policy is missing the Developer Mode session-bootstrap contract'
      );
    }
  }
  if (!/return false/.test(featureFlagsSource)) {
    throw new Error(
      'Production AI session-bootstrap policy must fail closed when absent or malformed'
    );
  }
  return 'session-bootstrap';
};
