import { execFile } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const execFileAsync = promisify(execFile);

const parseArguments = argv => {
  const values = new Map();
  for (let index = 2; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key || !key.startsWith('--') || !value) {
      throw new Error(`无效参数：${key || '<empty>'}`);
    }
    values.set(key, value);
  }
  return values;
};

const argumentsMap = parseArguments(process.argv);
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const playmeshDirectory = path.resolve(scriptDirectory, '..');
const lock = JSON.parse(
  await readFile(path.join(playmeshDirectory, 'catalog-lock.json'), 'utf8')
);
const cacheDirectory = path.resolve(
  argumentsMap.get('--cache') || path.join(playmeshDirectory, '..', '..', '..', '..', '..', 'work', 'gdevelop-catalog-git-source')
);
const onlySource = argumentsMap.get('--only');
const proxy = argumentsMap.get('--proxy') || '';
if (onlySource && !['extensions', 'examples'].includes(onlySource)) {
  throw new Error('--only 只接受 extensions 或 examples。');
}

const assertSafeCache = cache => {
  const parsed = path.parse(cache);
  if (cache === parsed.root || cache === playmeshDirectory) {
    throw new Error(`拒绝使用不安全的缓存目录：${cache}`);
  }
};
assertSafeCache(cacheDirectory);
await mkdir(cacheDirectory, { recursive: true });

const run = async (executable, args, options = {}) => {
  const result = await execFileAsync(executable, args, {
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
    ...options,
  });
  return { stdout: result.stdout.trim(), stderr: result.stderr.trim() };
};

const gitProxyArguments = proxy ? ['-c', `http.proxy=${proxy}`] : [];
const runGit = (args, options) => run('git', [...gitProxyArguments, ...args], options);

// Catalog 的 size/SHA-256 必须对应官方 Git blob 的原始字节。Windows 的
// system core.autocrlf=true 会在 checkout 时把 LF 改成 CRLF，导致工作树大小和
// raw.githubusercontent.com 返回内容不一致。每个受控缓存仓库都覆盖全局配置，
// 并在同一 commit 上强制重写稀疏工作树；不能在生成器中放宽字节校验。
const configureByteExactCheckout = async repositoryPath => {
  await runGit(['-C', repositoryPath, 'config', 'core.autocrlf', 'false']);
  await runGit(['-C', repositoryPath, 'config', 'core.eol', 'lf']);
  await runGit(['-C', repositoryPath, 'config', 'core.safecrlf', 'true']);
};

const normalizeRemote = value => String(value || '').replace(/\/$/, '');

const fetchExtensions = async () => {
  const source = lock.sources.extensions;
  const repositoryPath = path.join(cacheDirectory, 'extensions-git-source');
  try {
    const origin = (await runGit(['-C', repositoryPath, 'remote', 'get-url', 'origin'])).stdout;
    if (normalizeRemote(origin) !== normalizeRemote(source.remote)) {
      throw new Error('已存在的扩展缓存 origin 不匹配官方仓库。');
    }
  } catch (error) {
    if (!String(error.message || error).includes('origin 不匹配')) {
      await rm(repositoryPath, { recursive: true, force: true });
      await runGit([
        'clone',
        '--filter=blob:none',
        '--no-checkout',
        '--single-branch',
        '--branch',
        source.branch,
        source.remote,
        repositoryPath,
      ]);
    } else {
      throw error;
    }
  }

  await configureByteExactCheckout(repositoryPath);
  await runGit([
    '-C',
    repositoryPath,
    'fetch',
    '--filter=blob:none',
    'origin',
    source.commit,
  ]);
  await runGit(['-C', repositoryPath, 'sparse-checkout', 'init', '--no-cone']);
  await runGit([
    '-C',
    repositoryPath,
    'sparse-checkout',
    'set',
    '--no-cone',
    '/extensions/reviewed/*.json',
    '/extensions/community/*.json',
    '/extensions/views.json',
    '/LICENSE',
  ]);
  await runGit([
    '-C',
    repositoryPath,
    'checkout',
    '--force',
    '--detach',
    source.commit,
  ]);
  const head = (await runGit(['-C', repositoryPath, 'rev-parse', 'HEAD'])).stdout;
  const rootTreeSha = (
    await runGit(['-C', repositoryPath, 'rev-parse', 'HEAD^{tree}'])
  ).stdout;
  if (head !== source.commit || rootTreeSha !== source.rootTreeSha) {
    throw new Error('扩展源码未匹配锁定 commit/root tree。');
  }
  const status = (await runGit(['-C', repositoryPath, 'status', '--porcelain'])).stdout;
  if (status) throw new Error('扩展稀疏 checkout 不是干净工作树。');
  const verification = {
    schemaVersion: 2,
    strategy: 'required-json-sparse-checkout',
    repository: source.repository,
    remote: source.remote,
    commit: head,
    rootTreeSha,
    repositoryPath,
  };
  await writeFile(
    path.join(cacheDirectory, 'extensions-source-verification.json'),
    `${JSON.stringify(verification, null, 2)}\n`,
    'utf8'
  );
  return verification;
};

const runCurlJson = async url => {
  const temporaryPath = path.join(
    cacheDirectory,
    `.catalog-metadata-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.json`
  );
  const args = [
    '--fail',
    '--location',
    '--silent',
    '--show-error',
    '--header',
    'Accept: application/vnd.github+json',
    '--header',
    'X-GitHub-Api-Version: 2022-11-28',
    '--output',
    temporaryPath,
  ];
  if (proxy) args.push('--proxy', proxy);
  args.push(url);
  try {
    await run(process.platform === 'win32' ? 'curl.exe' : 'curl', args);
    return JSON.parse(await readFile(temporaryPath, 'utf8'));
  } finally {
    await rm(temporaryPath, { force: true });
  }
};

const fetchExamplesMetadata = async () => {
  const source = lock.sources.examples;
  const repositoryPath = path.join(cacheDirectory, 'examples-git-source');
  try {
    const origin = (await runGit(['-C', repositoryPath, 'remote', 'get-url', 'origin'])).stdout;
    if (normalizeRemote(origin) !== normalizeRemote(source.remote)) {
      throw new Error('已存在的示例缓存 origin 不匹配官方仓库。');
    }
  } catch (error) {
    if (!String(error.message || error).includes('origin 不匹配')) {
      await rm(repositoryPath, { recursive: true, force: true });
      await runGit([
        'clone',
        '--filter=blob:none',
        '--no-checkout',
        '--single-branch',
        '--branch',
        source.branch,
        source.remote,
        repositoryPath,
      ]);
    } else {
      throw error;
    }
  }
  await configureByteExactCheckout(repositoryPath);
  await runGit([
    '-C',
    repositoryPath,
    'fetch',
    '--filter=blob:none',
    'origin',
    source.commit,
  ]);
  await runGit(['-C', repositoryPath, 'sparse-checkout', 'init', '--cone']);
  await runGit(['-C', repositoryPath, 'sparse-checkout', 'set', 'examples']);
  await runGit([
    '-C',
    repositoryPath,
    'checkout',
    '--force',
    '--detach',
    source.commit,
  ]);
  const checkoutHead = (await runGit(['-C', repositoryPath, 'rev-parse', 'HEAD'])).stdout;
  const checkoutTree = (
    await runGit(['-C', repositoryPath, 'rev-parse', 'HEAD^{tree}'])
  ).stdout;
  if (checkoutHead !== source.commit || checkoutTree !== source.rootTreeSha) {
    throw new Error('示例源码未匹配锁定 commit/root tree。');
  }
  const checkoutStatus = (
    await runGit(['-C', repositoryPath, 'status', '--porcelain'])
  ).stdout;
  if (checkoutStatus) throw new Error('示例稀疏 checkout 不是干净工作树。');
  const treeOutput = (
    await runGit(['-C', repositoryPath, 'ls-tree', '-r', '-l', '-z', 'HEAD'])
  ).stdout;
  const treeEntries = treeOutput
    .split('\0')
    .filter(Boolean)
    .map(record => {
      const match = record.match(
        /^(\d+)\s+(blob)\s+([a-f0-9]{40})\s+(\d+)\t([\s\S]+)$/
      );
      if (!match) throw new Error('示例本地 Git tree 记录无效。');
      return {
        mode: match[1],
        type: match[2],
        sha: match[3],
        size: Number(match[4]),
        path: match[5],
      };
    });
  const tree = {
    sha: source.rootTreeSha,
    truncated: false,
    tree: treeEntries,
  };
  const treePath = path.join(cacheDirectory, 'examples-tree.json');
  await writeFile(treePath, `${JSON.stringify(tree, null, 2)}\n`, 'utf8');
  const verification = {
    schemaVersion: 2,
    strategy: 'exact-commit-sparse-checkout-and-local-tree',
    repository: source.repository,
    remote: source.remote,
    commit: source.commit,
    rootTreeSha: source.rootTreeSha,
    treeEntryCount: tree.tree.length,
    treePath,
    repositoryPath,
  };
  await writeFile(
    path.join(cacheDirectory, 'examples-source-verification.json'),
    `${JSON.stringify(verification, null, 2)}\n`,
    'utf8'
  );
  return verification;
};

const sources = onlySource ? [onlySource] : ['extensions', 'examples'];
const results = [];
for (const sourceName of sources) {
  results.push(
    sourceName === 'extensions'
      ? await fetchExtensions()
      : await fetchExamplesMetadata()
  );
}
process.stdout.write(`${JSON.stringify({ cacheDirectory, results }, null, 2)}\n`);
