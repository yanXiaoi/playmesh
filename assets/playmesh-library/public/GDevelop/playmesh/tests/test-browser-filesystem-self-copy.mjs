import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';

const sourceArgumentIndex = process.argv.indexOf('--source');
if (sourceArgumentIndex === -1 || !process.argv[sourceArgumentIndex + 1]) {
  throw new Error(
    'Usage: node test-browser-filesystem-self-copy.mjs --source <patched GDevelop root>'
  );
}

const sourceRoot = path.resolve(process.argv[sourceArgumentIndex + 1]);
const appRoot = path.join(sourceRoot, 'newIDE', 'app');
const sourcePath = path.join(
  appRoot,
  'src',
  'ExportAndShare',
  'BrowserExporters',
  'BrowserFileSystem.js'
);
const appRequire = createRequire(path.join(appRoot, 'package.json'));
const babel = appRequire('@babel/core');
const presetFlow = appRequire('@babel/preset-flow');

const source = (await readFile(sourcePath, 'utf8')).replace(
  `import path from 'path-browserify';`,
  `import path from 'node:path';`
);
const transformed = babel.transformSync(source, {
  babelrc: false,
  configFile: false,
  filename: sourcePath,
  presets: [[presetFlow, { all: true }]],
  sourceType: 'module',
});
assert.ok(transformed && transformed.code, 'Flow transform returned no code');

globalThis.gd = {
  VectorString: class VectorString {
    push_back() {}
  },
};
const moduleUrl = `data:text/javascript;base64,${Buffer.from(
  transformed.code,
  'utf8'
).toString('base64')}`;
const { default: BrowserFileSystem } = await import(moduleUrl);

const browserFileSystem = new BrowserFileSystem({ textFiles: [] });
browserFileSystem.writeToFile('/export/code0.js', 'generated code');
browserFileSystem.writeToFile('/export/data.js', 'generated data');

const errors = [];
const originalConsoleError = console.error;
console.error = (...args) => errors.push(args.join(' '));
try {
  assert.equal(
    browserFileSystem.copyFile(
      '/export//code0.js',
      '/export//code0.js'
    ),
    true,
    'an existing generated script copied to its normalized self must be a no-op'
  );
  assert.equal(
    browserFileSystem.copyFile('/export//data.js', '/export/data.js'),
    true,
    'equivalent normalized paths must be treated as the same entity'
  );
  assert.equal(browserFileSystem.readFile('/export/code0.js'), 'generated code');
  assert.equal(browserFileSystem.readFile('/export/data.js'), 'generated data');
  assert.deepEqual(errors, [], 'existing self-copies must not emit errors');

  assert.equal(
    browserFileSystem.copyFile('/export/missing.js', '/export/missing.js'),
    false,
    'a missing self-copy must not be hidden by the no-op guard'
  );
  assert.match(errors.pop() || '', /File not found in copyFile/);

  assert.equal(
    browserFileSystem.copyFile('/export/missing.js', '/export/copied.js'),
    false,
    'a missing source copied elsewhere must retain the official failure'
  );
  assert.match(errors.pop() || '', /File not found in copyFile/);

  assert.equal(
    browserFileSystem.copyFile('/export/code0.js', '/export/copied-code0.js'),
    true,
    'ordinary copies must keep working'
  );
  assert.equal(
    browserFileSystem.readFile('/export/copied-code0.js'),
    'generated code'
  );
} finally {
  console.error = originalConsoleError;
}

process.stdout.write('BrowserFileSystem self-copy contracts passed.\n');
