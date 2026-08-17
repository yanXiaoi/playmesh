import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { writeWebIdeThirdPartyNotices } from './webide-distribution-compliance-lib.mjs';

const argumentsMap = new Map();
for (let index = 2; index < process.argv.length; index += 2) {
  argumentsMap.set(process.argv[index], process.argv[index + 1]);
}

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const repositoryRoot = path.resolve(scriptDirectory, '../../../../../..');
const defaultProfile = path.join(
  repositoryRoot,
  'work',
  'gdevelop-webide-build-cache',
  'profiles',
  'default'
);
const sourceDirectory = path.resolve(
  argumentsMap.get('--source') || path.join(defaultProfile, 'build-source')
);
const buildDirectory = path.resolve(
  argumentsMap.get('--build') || path.join(defaultProfile, 'raw-build')
);
const runtimeDirectory = path.resolve(
  argumentsMap.get('--runtime') ||
    path.join(defaultProfile, 'built-gdjs', 'Runtime')
);
const outputDirectory = path.join(repositoryRoot, 'assets', 'legal');
const outputFileName = 'gdevelop-webide-third-party-notices.md';

const result = await writeWebIdeThirdPartyNotices({
  buildDirectory,
  sourceDirectory,
  runtimeDirectory,
  baseNoticePath: path.join(
    outputDirectory,
    'gdevelop-webide-third-party-notices-base.md'
  ),
  lock: JSON.parse(
    await readFile(path.join(playmeshDirectory, 'webide-lock.json'), 'utf8')
  ),
  outputDirectory,
  outputFileName,
});

process.stdout.write(
  `Refreshed checked-in WebIDE notices at ${result.outputPath} (${result.size} bytes).\n`
);
