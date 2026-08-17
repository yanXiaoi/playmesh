import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { verifyGeneratedCatalogDirectory } from './catalog-verifier-lib.mjs';

const index = process.argv.indexOf('--catalog');
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const catalog = path.resolve(
  index === -1
    ? path.join(scriptDirectory, '..', 'catalog', 'generated')
    : process.argv[index + 1] || ''
);
const result = await verifyGeneratedCatalogDirectory(catalog);
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
