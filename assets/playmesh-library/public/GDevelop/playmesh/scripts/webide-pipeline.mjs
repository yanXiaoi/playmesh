#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { execFile as execFileCallback } from "node:child_process";
import {
  copyFile,
  cp,
  mkdir,
  readdir,
  readFile,
  rename,
  rm,
  stat,
  symlink,
  writeFile
} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";

import {
  PIPELINE_PREREQUISITES,
  PIPELINE_STEPS,
  acquireProjectLock,
  canonicalPath,
  cleanupPipelineTransientEntries,
  commandGatePolicy,
  computeTreeDigest,
  copyTreeWithoutDependencies,
  createInFlightOperationDeduplicator,
  createReceipt,
  createStatusReport,
  dependencyCacheKey,
  dependencyNodeSearchPath,
  digestRecord,
  ensureWithin,
  explainReceipt,
  extractZipSafely,
  lstatOrNull,
  nodeOptionsWithHeapLimit,
  parsePipelineArguments,
  readReceipt,
  resolvePipelineReceiptInputs,
  removeIfExists,
  resolveNpmCliInvocation,
  replaceDirectoryAtomically,
  runProcess,
  selectPipelineSteps,
  sha256File,
  stableJson,
  synchronizeDirectoryByContent,
  validateDependencyCache,
  validateLibGdPair,
  writeJsonAtomically
} from "./webide-pipeline-lib.mjs";

const execFile = promisify(execFileCallback);
const scriptPath = fileURLToPath(import.meta.url);
const scriptDirectory = path.dirname(scriptPath);
const playmeshDirectory = path.resolve(scriptDirectory, "..");
const repositoryRoot = path.resolve(scriptDirectory, "../../../../../..");
const repositoryWorkRoot = path.join(repositoryRoot, "work");
const defaultWorkRoot = path.join(
  repositoryWorkRoot,
  "gdevelop-webide-build-cache"
);
const lockPath = path.join(playmeshDirectory, "webide-lock.json");
const manifestPath = path.join(
  playmeshDirectory,
  "source-policy-output-manifest.json"
);
const overlayPath = path.join(playmeshDirectory, "overlays");
const applyPolicyPath = path.join(scriptDirectory, "apply-source-policy.mjs");
const preparePath = path.join(scriptDirectory, "prepare-webide.mjs");
const prepareDevelopmentPath = path.join(
  scriptDirectory,
  "prepare-dev-webide.mjs"
);
const packagePath = path.join(scriptDirectory, "package-webide-release.mjs");
const auditPath = path.join(
  playmeshDirectory,
  "tests",
  "test-production-build-audit.mjs"
);
const releaseDirectory = path.join(repositoryRoot, "resources", "GDevelop");
const updateManifestPath = path.join(releaseDirectory, "update.json");
// Invoke npm through the CLI shipped beside the exact Windows Node executable
// running this pipeline, so the dependency cache always has one toolchain identity.
const npmCliPath = resolveNpmCliInvocation(process.execPath).cliPath;
const sourceTreeExclusions = new Set([
  "newIDE/app/node_modules",
  "GDJS/node_modules"
]);

const sourceContractTests = Object.freeze([
  ["test-source-policy-output.mjs", ["--source", "{source}"]],
  ["test-source-policy-module-contracts.mjs", ["--source", "{source}"]],
  ["test-multiplayer-runtime-seams.mjs", ["--source", "{source}"]],
  ["test-zero-cloud-resource-source.mjs", ["--source", "{source}"]],
  ["test-browser-persistence-boundary.mjs", ["--source", "{source}"]],
  ["test-official-runtime-ui-contracts.mjs", ["--source", "{source}"]],
  ["test-builtin-extension-localization-source.mjs", ["--source", "{source}"]],
  ["test-gdevelop-storage-runtime.mjs", ["--source", "{source}"]],
  ["test-storage-lifecycle-source.mjs", ["--source", "{source}"]],
  ["test-catalog-official-parser-contract.mjs", ["--source", "{source}"]],
  ["test-behavior-install-catalog-contract.mjs", ["--source", "{source}"]],
  ["test-preview-runtime-artifacts.mjs", ["--source", "{source}"]],
  ["test-native-file-save-source.mjs", ["--source", "{source}"]],
  ["test-pixi-blob-scene-reload-source.mjs", ["--source", "{source}"]],
  ["test-editor-mosaic-nested-visibility.mjs", ["--source", "{source}"]],
  ["test-download-project-archive.mjs", []],
  ["test-catalog-packaging-contract.mjs", []]
]);

const localContractTests = Object.freeze([
  ["test-gdevelop-fps-probe.mjs", []],
  ["test-runtime-injection-boundary.mjs", []],
  ["test-ai-client.mjs", []],
  ["test-ai-ui-boundaries.mjs", []],
  ["test-ai-live-wrapper-callbacks.mjs", []],
  ["test-event-instruction-tools.mjs", []],
  ["test-project-symbol-tools.mjs", []],
  ["test-catalog-generator.mjs", []],
  ["test-catalog-runtime.mjs", []],
  ["test-catalog-source.mjs", []],
  ["test-developer-fullscreen.mjs", []],
  ["test-example-importer.mjs", []],
  ["test-game-manifest.mjs", []],
  ["test-gateway-preview.mjs", []],
  ["test-lan-sha256-fallback.mjs", []],
  ["test-local-browser-sw-preview.mjs", []],
  ["test-history-client.mjs", []],
  ["test-history-diff-summary.mjs", []],
  ["test-history-restore-client.mjs", []],
  ["test-history-restore-coordinator.mjs", []],
  ["test-history-restore-journal.mjs", []],
  ["test-history-restore-materializer.mjs", []],
  ["test-history-restore-protocol.mjs", []],
  ["test-localization-session.mjs", []],
  ["test-managed-project-storage-controller.mjs", []],
  ["test-multiplayer-bridge.mjs", []],
  ["test-portable-import-allocation-client.mjs", []],
  ["test-portable-project-format-reader.mjs", []],
  ["test-portable-project-import-controller.mjs", []],
  ["test-portable-project-importer.mjs", []],
  ["test-pixi-blob-resource-asset.mjs", []],
  ["test-project-config.mjs", []],
  ["test-project-lifecycle.mjs", []],
  ["test-project-rekey-client.mjs", []],
  ["test-project-rekey-controller.mjs", []],
  ["test-project-rekey-coordinator.mjs", []],
  ["test-project-rekey-journal.mjs", []],
  ["test-project-rekey-protocol.mjs", []],
  ["test-project-save-resource-cache.mjs", []],
  ["test-publish-controller.mjs", []],
  ["test-publish-uploader.mjs", []],
  ["test-webide-distribution-compliance.mjs", []],
  ["test-release-verifiers.mjs", []]
]);

const replayContractTests = Object.freeze([
  ["test-source-policy-clean-replay.mjs", ["--zip", "{archive}"]]
]);

const rootContractTests = Object.freeze([
  ["tool/test_gdevelop_authority_bootstrap.mjs", []],
  ["tool/test_gdevelop_multiplayer_e2e.mjs", []],
  ["tool/test_gdevelop_multiplayer_e2e_cleanup.mjs", []]
]);

const contractTests = Object.freeze([
  ...sourceContractTests.map(test => ["playmesh", ...test]),
  ...localContractTests.map(test => ["playmesh", ...test]),
  ...replayContractTests.map(test => ["playmesh", ...test]),
  ...rootContractTests.map(test => ["repository", ...test])
]);

const usage = `Usage:
  node ${path.basename(
    scriptPath
  )} <command> --zip <absolute official ZIP> [options]

Commands:
  status extract deps patch libgd flow test build audit prepare package verify
  dev-package all release-check

Options:
  --profile default                Stable receipts/worktree (fixed: default)
  --from <step> --to <step>        Limit all/release-check explicit range
  --json                           Machine-readable status/output
  --force-deps-refresh             Rebuild only the exact dependency cache key
  --keep-worktree-on-failure       Preserve failed staging directories
  --adopt-successful-build         Adopt a verified completed build after receipt failure
  --libgd-seed <absolute dir>      Verified seed containing libGD.js/wasm
  --libgd-pin <identity>           Exact official libGD pin (required on import)
  --libgd-revision <identity>      Exact revision identity (defaults to pin)
  --libgd-url-identity <identity>  Exact source URL identity
  --libgd-source-kind <kind>       official-exact-commit-artifact or legacy exception
  --node-heap-mb <integer>         Production build Node heap (default: 8192)
`;

const failUsage = error => {
  process.stderr.write(`${error.message}\n\n${usage}`);
  process.exitCode = 2;
};

const hashManyFiles = async files => {
  const records = [];
  for (const filePath of files) {
    records.push({
      path: path.relative(repositoryRoot, filePath).replaceAll("\\", "/"),
      sha256: await sha256File(filePath)
    });
  }
  return digestRecord(records);
};

const outputSetDigest = values => digestRecord(values);

const linkDependencies = async ({
  appRoot,
  dependencyRoot,
  isolated = false
}) => {
  const linkPath = path.join(appRoot, "node_modules");
  const existing = await lstatOrNull(linkPath);
  if (existing) await rm(linkPath, { recursive: true, force: true });
  if (isolated) {
    const sharedModules = path.join(dependencyRoot, "node_modules");
    await mkdir(linkPath, { recursive: true });
    const entries = await readdir(sharedModules, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.name === "libGD.js-for-tests-only") continue;
      await symlink(
        path.join(sharedModules, entry.name),
        path.join(linkPath, entry.name),
        entry.isDirectory() ? "dir" : "file"
      );
    }
    return;
  }
  await symlink(
    path.join(dependencyRoot, "node_modules"),
    linkPath,
    process.platform === "win32" ? "junction" : "dir"
  );
};

const materializeLibGdTestModule = async ({ appRoot, libGdRoot }) => {
  const destination = path.join(
    appRoot,
    "node_modules",
    "libGD.js-for-tests-only"
  );
  await mkdir(destination, { recursive: true });
  await copyFile(
    path.join(libGdRoot, "libGD.js"),
    path.join(destination, "index.js")
  );
  await copyFile(
    path.join(libGdRoot, "libGD.wasm"),
    path.join(destination, "libGD.wasm")
  );
};

const main = async () => {
  let parsed;
  try {
    parsed = parsePipelineArguments(process.argv.slice(2));
  } catch (error) {
    failUsage(error);
    return;
  }

  const { command, options } = parsed;
  const profile = options.get("--profile");
  const buildNodeHeapMb = Number(options.get("--node-heap-mb") || 8192);
  if (!Number.isSafeInteger(buildNodeHeapMb) || buildNodeHeapMb < 4096) {
    failUsage(
      new TypeError("--node-heap-mb must be an integer of at least 4096")
    );
    return;
  }
  const sourceArchive = await canonicalPath(options.get("--zip"));
  const workRoot = ensureWithin(
    repositoryWorkRoot,
    defaultWorkRoot,
    "work root"
  );
  const profileRoot = ensureWithin(
    workRoot,
    path.join(workRoot, "profiles", profile),
    "profile root"
  );
  const sharedCacheRoot = ensureWithin(
    workRoot,
    path.join(workRoot, "cache"),
    "cache root"
  );
  const receiptsRoot = path.join(profileRoot, "receipts");
  const logsRoot = path.join(profileRoot, "logs");
  const upstreamRoot = path.join(profileRoot, "upstream");
  const sourceRoot = path.join(profileRoot, "source");
  const flowSourceRoot = path.join(profileRoot, "flow-source");
  const buildSourceRoot = path.join(profileRoot, "build-source");
  const rawBuildRoot = path.join(profileRoot, "raw-build");
  const builtGdjsRoot = path.join(profileRoot, "built-gdjs");
  const auditedBuildRoot = path.join(profileRoot, "audited-build");
  const preparedRoot = path.join(profileRoot, "prepared");
  // Every durable package (formal or fast) lives under repository-relative
  // resources/GDevelop. release-check is the sole isolated dry run.
  const publishFormalArtifacts = command !== "release-check";
  const pipelineReleaseDirectory = publishFormalArtifacts
    ? releaseDirectory
    : path.join(profileRoot, "release-output");
  const pipelineUpdateManifestPath = publishFormalArtifacts
    ? updateManifestPath
    : path.join(profileRoot, "release-update.json");
  const libGdConfigPath = path.join(profileRoot, "libgd-config.json");
  const projectLockPath = path.join(profileRoot, ".pipeline.lock");
  const failedStaging = new Set();
  const keepFailedWorktree = options.has("--keep-worktree-on-failure");

  const cleanupTransientProfileEntries = async phase => {
    if (keepFailedWorktree && phase === "finish" && failedStaging.size > 0)
      return;
    try {
      const result = await cleanupPipelineTransientEntries({
        root: profileRoot,
        names: ["release-check", "release-output", "release-update.json"],
        prefixes: [
          ".staging-",
          ".prepared.staging-",
          ".prepared.backup-",
          "upstream.backup-",
          "source.backup-",
          "raw-build.backup-",
          "built-gdjs.backup-",
          "audited-build.backup-",
          "release-output.backup-"
        ]
      });
      if (result.removed.length > 0) {
        process.stdout.write(
          `[cleanup:${phase}] removed ${result.removed.length} transient entr${
            result.removed.length === 1 ? "y" : "ies"
          }; incremental caches preserved\n`
        );
      }
      for (const failure of result.failures) {
        process.stderr.write(
          `[cleanup:${phase}] warning: could not remove ${failure.name}: ${
            failure.message
          }\n`
        );
      }
    } catch (error) {
      process.stderr.write(
        `[cleanup:${phase}] warning: transient cleanup could not start: ${
          error instanceof Error ? error.message : String(error)
        }\n`
      );
    }
  };

  await mkdir(profileRoot, { recursive: true });
  const releaseLock = await acquireProjectLock({
    lockPath: projectLockPath,
    profile,
    command
  });
  const abortController = new AbortController();
  let interrupted = false;
  const interrupt = () => {
    interrupted = true;
    abortController.abort();
  };
  process.once("SIGINT", interrupt);
  process.once("SIGTERM", interrupt);
  try {
    if (!keepFailedWorktree) await cleanupTransientProfileEntries("start");
    const webIdeLock = JSON.parse(await readFile(lockPath, "utf8"));
    const version = webIdeLock.upstream.tag.replace(/^v/, "");
    const expectedArchiveRoot = `GDevelop-${version}`;
    const archiveMetadata = await stat(sourceArchive);
    if (!archiveMetadata.isFile()) throw new Error("--zip must name a file");
    const archiveSha256 = await sha256File(sourceArchive);
    if (archiveSha256 !== webIdeLock.upstream.sourceArchiveSha256) {
      throw new Error(
        `Official ZIP SHA-256 mismatch: expected ${
          webIdeLock.upstream.sourceArchiveSha256
        }, got ${archiveSha256}`
      );
    }
    if (!/^[0-9a-f]{40}$/.test(webIdeLock.upstream.commit)) {
      throw new Error(
        "webide-lock upstream commit must be an exact 40-character hash"
      );
    }

    const npmVersion = (await execFile(process.execPath, [
      npmCliPath,
      "--version"
    ])).stdout.trim();
    let osReleaseIdentity = null;
    try {
      osReleaseIdentity = await readFile("/etc/os-release", "utf8");
    } catch {}
    const toolVersions = Object.freeze({
      node: process.version,
      nodeAbi: process.versions.modules,
      npm: npmVersion,
      platform: process.platform,
      arch: process.arch,
      osType: os.type(),
      osRelease: os.release(),
      wslOsReleaseSha256: osReleaseIdentity
        ? createHash("sha256")
            .update(osReleaseIdentity)
            .digest("hex")
        : null
    });
    const pipelineToolDigest = await hashManyFiles([
      scriptPath,
      path.join(scriptDirectory, "webide-pipeline-lib.mjs")
    ]);
    const lockDigest = await sha256File(lockPath);

    const receiptPath = step => path.join(receiptsRoot, `${step}.json`);
    const receiptFor = step => readReceipt(receiptPath(step));
    const sourceTreeDigest = root =>
      computeTreeDigest({ root, excludeRelativePaths: sourceTreeExclusions });

    let libGdConfig = null;
    try {
      libGdConfig = JSON.parse(await readFile(libGdConfigPath, "utf8"));
    } catch (error) {
      if (!error || error.code !== "ENOENT") throw error;
    }

    const importLibGdConfiguration = async () => {
      const seedOption = options.get("--libgd-seed");
      const pin = options.get("--libgd-pin");
      if (!seedOption && !pin) return libGdConfig;
      if (!seedOption || !pin) {
        throw new Error(
          "--libgd-seed and --libgd-pin must be provided together"
        );
      }
      if (!path.isAbsolute(seedOption)) {
        throw new Error("--libgd-seed must be an absolute path");
      }
      const seed = await canonicalPath(seedOption);
      const pair = await validateLibGdPair(seed);
      const kind =
        options.get("--libgd-source-kind") ||
        "approved-legacy-prepared-exception";
      if (
        kind !== "approved-legacy-prepared-exception" &&
        kind !== "official-exact-commit-artifact"
      ) {
        throw new Error("Unsupported --libgd-source-kind");
      }
      const urlIdentity = options.get("--libgd-url-identity");
      if (kind === "official-exact-commit-artifact" && !urlIdentity) {
        throw new Error(
          "official-exact-commit-artifact requires --libgd-url-identity"
        );
      }
      const revision = options.get("--libgd-revision") || pin;
      if (kind === "official-exact-commit-artifact") {
        const officialSourceMatch = urlIdentity.match(
          /^https:\/\/s3\.amazonaws\.com\/gdevelop-gdevelop\.js\/master\/commit\/([a-f0-9]{40})$/
        );
        if (!officialSourceMatch || officialSourceMatch[1] !== revision) {
          throw new Error(
            "official libGD URL must bind the exact --libgd-revision commit"
          );
        }
      }
      const identity = Object.freeze({
        schemaVersion: 2,
        kind,
        pin,
        revision,
        urlIdentity:
          urlIdentity || "approved-explicit-b-seed",
        userDecision:
          kind === "official-exact-commit-artifact" ? "not-required" : "B",
        files: pair.files,
        pairing: pair.pairing
      });
      const key = digestRecord(identity);
      libGdConfig = Object.freeze({
        ...identity,
        key,
        cachePath: path.join(sharedCacheRoot, "libgd", key),
        importedFrom: seed
      });
      return libGdConfig;
    };
    await importLibGdConfiguration();

    const getDependencyDescriptor = async dependencySourceRoot => {
      const lockFile = path.join(dependencySourceRoot, "package-lock.json");
      const packageFile = path.join(dependencySourceRoot, "package.json");
      const cacheIdentity = Object.freeze({
        packageLockSha256: await sha256File(lockFile),
        node: toolVersions.node,
        nodeAbi: toolVersions.nodeAbi,
        npm: toolVersions.npm,
        platform: toolVersions.platform,
        arch: toolVersions.arch,
        osType: toolVersions.osType,
        osRelease: toolVersions.osRelease,
        wslOsReleaseSha256: toolVersions.wslOsReleaseSha256
      });
      return Object.freeze({
        cacheIdentity,
        packageJsonSha256: await sha256File(packageFile)
      });
    };

    const getDependencyDescriptors = async () => {
      const [app, gdjs] = await Promise.all([
        getDependencyDescriptor(path.join(upstreamRoot, "newIDE", "app")),
        getDependencyDescriptor(path.join(upstreamRoot, "GDJS"))
      ]);
      return Object.freeze({ app, gdjs });
    };

    const dependencyCachePath = (depsInput, scope) =>
      path.join(
        sharedCacheRoot,
        "deps",
        scope === "app"
          ? depsInput.cacheKeys.app
          : `gdjs-${depsInput.cacheKeys.gdjs}`
      );

    const inputFor = async step => {
      const receiptInputs = step =>
        resolvePipelineReceiptInputs({ step, receiptFor });
      const common = { pipelineToolDigest, lockDigest, toolVersions };
      switch (step) {
        case "extract":
          return {
            ...common,
            archive: {
              sha256: archiveSha256,
              size: archiveMetadata.size,
              tag: webIdeLock.upstream.tag,
              commit: webIdeLock.upstream.commit,
              sourceArchive: webIdeLock.upstream.sourceArchive
            }
          };
        case "deps": {
          const dependencies = await getDependencyDescriptors();
          return {
            pipelineToolDigest,
            toolVersions,
            dependencies: {
              app: dependencies.app.cacheIdentity,
              gdjs: dependencies.gdjs.cacheIdentity
            },
            packageJsonSha256: {
              app: dependencies.app.packageJsonSha256,
              gdjs: dependencies.gdjs.packageJsonSha256
            },
            cacheKeys: {
              app: dependencyCacheKey(dependencies.app.cacheIdentity),
              gdjs: dependencyCacheKey(dependencies.gdjs.cacheIdentity)
            }
          };
        }
        case "patch":
          return {
            ...common,
            ...(await receiptInputs("patch")),
            patchToolsSha256: await hashManyFiles([
              applyPolicyPath,
              path.join(scriptDirectory, "source-policy-verifier-lib.mjs")
            ]),
            manifestSha256: await sha256File(manifestPath),
            overlayTreeSha256: (await computeTreeDigest({
              root: overlayPath,
              rejectSymlinks: true
            })).sha256,
            canonicalBrowserSourcesSha256: await hashManyFiles([
              path.join(
                repositoryRoot,
                "assets/playmesh-library/public/developer/playmesh-game-manifest.js"
              ),
              path.join(
                repositoryRoot,
                "assets/playmesh-library/public/developer/gdevelop-authority-bootstrap.js"
              ),
              path.join(
                repositoryRoot,
                "assets/playmesh-library/public/developer/gdevelop-multiplayer-bridge.js"
              )
            ])
          };
        case "libgd":
          return {
            pipelineToolDigest,
            toolVersions,
            metadata: libGdConfig
              ? {
                  schemaVersion: libGdConfig.schemaVersion,
                  kind: libGdConfig.kind,
                  pin: libGdConfig.pin,
                  revision: libGdConfig.revision,
                  urlIdentity: libGdConfig.urlIdentity,
                  userDecision: libGdConfig.userDecision,
                  files: libGdConfig.files,
                  pairing: libGdConfig.pairing,
                  key: libGdConfig.key
                }
              : null
          };
        case "flow":
          return {
            ...common,
            ...(await receiptInputs("flow")),
            flowConfigSha256: await sha256File(
              path.join(sourceRoot, "newIDE", "app", ".flowconfig")
            )
          };
        case "test":
          return {
            ...common,
            ...(await receiptInputs("test")),
            contractsSha256: await hashManyFiles(
              contractTests.map(([scope, name]) =>
                scope === "repository"
                  ? path.join(repositoryRoot, name)
                  : path.join(playmeshDirectory, "tests", name)
              )
            ),
            archiveSha256
          };
        case "build":
          return {
            ...common,
            ...(await receiptInputs("build")),
            nodeHeapMb: buildNodeHeapMb,
            developmentPreparationSha256: await hashManyFiles([
              prepareDevelopmentPath,
              path.join(playmeshDirectory, "runtime", "host-policy.js"),
              path.join(playmeshDirectory, "runtime", "host-policy.css")
            ]),
            catalogTreeSha256: (await computeTreeDigest({
              root: path.join(playmeshDirectory, "catalog", "generated"),
              rejectSymlinks: true
            })).sha256
          };
        case "audit":
          return {
            ...common,
            ...(await receiptInputs("audit")),
            auditToolsSha256: await hashManyFiles([
              auditPath,
              path.join(scriptDirectory, "source-policy-verifier-lib.mjs"),
              path.join(scriptDirectory, "webide-provenance.mjs")
            ]),
            manifestSha256: await sha256File(manifestPath)
          };
        case "prepare":
          return {
            ...common,
            ...(await receiptInputs("prepare")),
            prepareToolsSha256: await hashManyFiles([
              preparePath,
              path.join(scriptDirectory, "webide-provenance.mjs")
            ]),
            manifestSha256: await sha256File(manifestPath)
          };
        case "package":
          return {
            ...common,
            fastChain: await receiptInputs("package"),
            packageToolsSha256: await hashManyFiles([
              packagePath,
              path.join(scriptDirectory, "webide-provenance.mjs")
            ]),
            downloads: JSON.parse(await readFile(updateManifestPath, "utf8"))
              .downloads
          };
        case "verify":
          return {
            ...common,
            ...(await receiptInputs("verify")),
            packageToolsSha256: await hashManyFiles([
              packagePath,
              path.join(scriptDirectory, "webide-provenance.mjs")
            ])
          };
        default:
          throw new Error(`Unknown pipeline step: ${step}`);
      }
    };

    const libGdOutput = async () => {
      if (!libGdConfig) return null;
      try {
        const pair = await validateLibGdPair(libGdConfig.cachePath);
        const metadata = JSON.parse(
          await readFile(
            path.join(libGdConfig.cachePath, "pair-metadata.json"),
            "utf8"
          )
        );
        const expected = {
          schemaVersion: libGdConfig.schemaVersion,
          kind: libGdConfig.kind,
          pin: libGdConfig.pin,
          revision: libGdConfig.revision,
          urlIdentity: libGdConfig.urlIdentity,
          userDecision: libGdConfig.userDecision,
          files: libGdConfig.files,
          pairing: libGdConfig.pairing,
          key: libGdConfig.key
        };
        if (stableJson(metadata) !== stableJson(expected)) return null;
        return digestRecord({ pair, metadata });
      } catch {
        return null;
      }
    };
    const dependencyOutput = async () => {
      try {
        const input = await inputFor("deps");
        const [app, gdjs] = await Promise.all([
          validateDependencyCache(dependencyCachePath(input, "app"), {
            scope: "app"
          }),
          validateDependencyCache(dependencyCachePath(input, "gdjs"), {
            scope: "gdjs"
          })
        ]);
        return app && gdjs ? digestRecord({ app, gdjs }) : null;
      } catch {
        return null;
      }
    };
    const fileSetOutput = async files => {
      try {
        const records = [];
        for (const filePath of files) {
          const metadata = await stat(filePath);
          if (!metadata.isFile()) return null;
          records.push({
            path: path.basename(filePath),
            size: metadata.size,
            sha256: await sha256File(filePath)
          });
        }
        return outputSetDigest(records);
      } catch {
        return null;
      }
    };
    const outputFor = async step => {
      try {
        switch (step) {
          case "extract":
            return (await sourceTreeDigest(upstreamRoot)).sha256;
          case "deps":
            return dependencyOutput();
          case "patch":
            return (await sourceTreeDigest(sourceRoot)).sha256;
          case "libgd":
            return libGdOutput();
          case "flow":
            return fileSetOutput([path.join(logsRoot, `${step}.log`)]);
          case "test":
            return (await computeTreeDigest({
              root: path.join(logsRoot, "test"),
              rejectSymlinks: true
            })).sha256;
          case "build":
            return outputSetDigest([
              (await computeTreeDigest({
                root: rawBuildRoot,
                rejectSymlinks: true
              })).sha256,
              (await computeTreeDigest({
                root: builtGdjsRoot,
                rejectSymlinks: true
              })).sha256
            ]);
          case "audit":
            return (await computeTreeDigest({
              root: auditedBuildRoot,
              rejectSymlinks: true
            })).sha256;
          case "prepare":
            return (await computeTreeDigest({
              root: preparedRoot,
              rejectSymlinks: true
            })).sha256;
          case "package":
          case "verify":
            return fileSetOutput([
              path.join(
                pipelineReleaseDirectory,
                webIdeLock.distribution.assetName
              ),
              pipelineUpdateManifestPath
            ]);
          default:
            return null;
        }
      } catch {
        return null;
      }
    };

    const statusFor = async step => {
      let input;
      try {
        input = await inputFor(step);
      } catch (error) {
        return {
          step,
          valid: false,
          reason: `input unavailable: ${error.message}`
        };
      }
      const inputDigest = digestRecord(input);
      const receipt = await receiptFor(step);
      const outputDigest = await outputFor(step);
      return {
        step,
        ...explainReceipt({ receipt, step, inputDigest, outputDigest }),
        inputDigest,
        outputTreeDigest: outputDigest,
        completedAt: receipt?.completedAt || null
      };
    };

    const prerequisites = PIPELINE_PREREQUISITES;

    const runStep = async step => {
      if (interrupted) throw new Error("Pipeline interrupted");
      const input = await inputFor(step);
      const inputDigest = digestRecord(input);
      const logPath = path.join(logsRoot, `${step}.log`);
      const makeStaging = async label => {
        const staging = path.join(
          profileRoot,
          `.staging-${label}-${randomUUID()}`
        );
        ensureWithin(profileRoot, staging, "staging directory");
        failedStaging.add(staging);
        await mkdir(staging, { recursive: true });
        return staging;
      };
      switch (step) {
        case "extract": {
          const staging = await makeStaging("extract");
          await extractZipSafely({
            archivePath: sourceArchive,
            destination: staging,
            expectedRoot: expectedArchiveRoot
          });
          for (const required of [
            "newIDE/app/package.json",
            "newIDE/app/package-lock.json",
            "GDJS/Runtime"
          ]) {
            const metadata = await stat(
              path.join(staging, ...required.split("/"))
            );
            if (!metadata)
              throw new Error(`Extracted layout is missing ${required}`);
          }
          await replaceDirectoryAtomically({ staging, target: upstreamRoot });
          failedStaging.delete(staging);
          break;
        }
        case "deps": {
          const forceRefresh = options.has("--force-deps-refresh");
          for (const dependency of [
            {
              scope: "app",
              sourceRoot: path.join(upstreamRoot, "newIDE", "app")
            },
            { scope: "gdjs", sourceRoot: path.join(upstreamRoot, "GDJS") }
          ]) {
            const dependencyRoot = dependencyCachePath(input, dependency.scope);
            const cacheKey = input.cacheKeys[dependency.scope];
            const releaseCacheLock = await acquireProjectLock({
              lockPath: path.join(
                sharedCacheRoot,
                "locks",
                `deps-${dependency.scope}-${cacheKey}.lock`
              ),
              profile,
              command: `deps-${dependency.scope}-cache`
            });
            try {
              if (
                forceRefresh ||
                !(await validateDependencyCache(dependencyRoot, {
                  scope: dependency.scope
                }))
              ) {
                const staging = path.join(
                  sharedCacheRoot,
                  "deps",
                  `.staging-${dependency.scope}-${cacheKey}-${randomUUID()}`
                );
                ensureWithin(
                  path.join(sharedCacheRoot, "deps"),
                  staging,
                  "deps staging"
                );
                failedStaging.add(staging);
                await mkdir(staging, { recursive: true });
                await copyFile(
                  path.join(dependency.sourceRoot, "package.json"),
                  path.join(staging, "package.json")
                );
                await copyFile(
                  path.join(dependency.sourceRoot, "package-lock.json"),
                  path.join(staging, "package-lock.json")
                );
                await runProcess({
                  command: process.execPath,
                  args: [
                    npmCliPath,
                    "ci",
                    "--ignore-scripts",
                    "--no-audit",
                    "--fund=false"
                  ],
                  cwd: staging,
                  signal: abortController.signal,
                  logPath
                });
                if (
                  !(await validateDependencyCache(staging, {
                    scope: dependency.scope
                  }))
                ) {
                  throw new Error(
                    `${
                      dependency.scope
                    } dependency cache validation failed after npm ci`
                  );
                }
                await replaceDirectoryAtomically({
                  staging,
                  target: dependencyRoot
                });
                failedStaging.delete(staging);
              }
            } finally {
              await releaseCacheLock();
            }
          }
          break;
        }
        case "patch": {
          const staging = await makeStaging("patch");
          await rm(staging, { recursive: true, force: true });
          await copyTreeWithoutDependencies({
            source: upstreamRoot,
            destination: staging
          });
          await runProcess({
            command: process.execPath,
            args: [applyPolicyPath, "--source", staging],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath
          });
          await replaceDirectoryAtomically({ staging, target: sourceRoot });
          failedStaging.delete(staging);
          break;
        }
        case "libgd": {
          if (!libGdConfig) {
            throw new Error(
              "libgd requires an earlier explicit --libgd-seed/--libgd-pin import"
            );
          }
          const releaseCacheLock = await acquireProjectLock({
            lockPath: path.join(
              sharedCacheRoot,
              "locks",
              `libgd-${libGdConfig.key}.lock`
            ),
            profile,
            command: "libgd-cache"
          });
          try {
            const existing = await libGdOutput();
            if (!existing) {
              if (!libGdConfig.importedFrom) {
                throw new Error(
                  "libGD cache is damaged and no verified seed is available"
                );
              }
              const staging = path.join(
                sharedCacheRoot,
                "libgd",
                `.staging-${libGdConfig.key}-${randomUUID()}`
              );
              ensureWithin(
                path.join(sharedCacheRoot, "libgd"),
                staging,
                "libGD staging"
              );
              failedStaging.add(staging);
              await mkdir(staging, { recursive: true });
              for (const fileName of ["libGD.js", "libGD.wasm"]) {
                await copyFile(
                  path.join(libGdConfig.importedFrom, fileName),
                  path.join(staging, fileName)
                );
              }
              const actual = await validateLibGdPair(staging);
              if (stableJson(actual.files) !== stableJson(libGdConfig.files)) {
                throw new Error(
                  "Explicit libGD seed bytes changed during import"
                );
              }
              await writeJsonAtomically(
                path.join(staging, "pair-metadata.json"),
                {
                  ...libGdConfig,
                  cachePath: undefined,
                  importedFrom: undefined
                }
              );
              await replaceDirectoryAtomically({
                staging,
                target: libGdConfig.cachePath
              });
              failedStaging.delete(staging);
            }
          } finally {
            await releaseCacheLock();
          }
          await writeJsonAtomically(libGdConfigPath, libGdConfig);
          break;
        }
        case "flow":
          await synchronizeDirectoryByContent({
            source: sourceRoot,
            destination: flowSourceRoot,
            excludeRelativePaths: sourceTreeExclusions
          });
          await linkDependencies({
            appRoot: path.join(flowSourceRoot, "newIDE", "app"),
            dependencyRoot: dependencyCachePath(await inputFor("deps"), "app"),
            // Windows Flow does not resolve packages through a junction used
            // as the node_modules root. Link each top-level dependency instead
            // while keeping the shared cache immutable.
            isolated: process.platform === "win32"
          });
          if (!libGdConfig) throw new Error("libGD provenance is unavailable");
          await materializeLibGdTestModule({
            appRoot: path.join(flowSourceRoot, "newIDE", "app"),
            libGdRoot: libGdConfig.cachePath
          });
          await runProcess({
            command: process.execPath,
            args: [npmCliPath, "run", "make-version-metadata"],
            cwd: path.join(flowSourceRoot, "newIDE", "app"),
            env: {
              PLAYMESH_GDEVELOP_SOURCE_COMMIT: webIdeLock.upstream.commit
            },
            signal: abortController.signal,
            logPath
          });
          await runProcess({
            command: process.execPath,
            args: [npmCliPath, "run", "flow", "--", "--show-all-errors"],
            cwd: path.join(flowSourceRoot, "newIDE", "app"),
            signal: abortController.signal,
            logPath
          });
          break;
        case "test":
          await rm(path.join(logsRoot, "test"), {
            recursive: true,
            force: true
          });
          await mkdir(path.join(logsRoot, "test"), { recursive: true });
          for (const [scope, testName, rawArguments] of contractTests) {
            const testArguments = rawArguments.map(value =>
              value === "{source}"
                ? sourceRoot
                : value === "{archive}"
                ? sourceArchive
                : value
            );
            await runProcess({
              command: process.execPath,
              args: [
                scope === "repository"
                  ? path.join(repositoryRoot, testName)
                  : path.join(playmeshDirectory, "tests", testName),
                ...testArguments
              ],
              cwd: repositoryRoot,
              signal: abortController.signal,
              logPath: path.join(
                logsRoot,
                "test",
                `${testName.replaceAll("/", "__")}.log`
              )
            });
          }
          break;
        case "build": {
          if (options.has("--adopt-successful-build")) {
            const buildLog = await readFile(logPath, "utf8");
            if (
              !buildLog.includes("The build folder is ready to be deployed.") ||
              buildLog.includes("FATAL ERROR: Reached heap limit")
            ) {
              throw new Error(
                "Existing build cannot be adopted without a successful production build log"
              );
            }
            for (const required of [
              path.join(rawBuildRoot, "index.html"),
              path.join(rawBuildRoot, "asset-manifest.json"),
              path.join(
                buildSourceRoot,
                "newIDE",
                "app",
                "build",
                "index.html"
              ),
              path.join(builtGdjsRoot, "package.json"),
              path.join(builtGdjsRoot, "Runtime")
            ]) {
              await stat(required);
            }
            if (!libGdConfig)
              throw new Error("libGD provenance is unavailable");
            const importedLibGd = await validateLibGdPair(rawBuildRoot);
            if (
              stableJson(importedLibGd.files) !== stableJson(libGdConfig.files)
            ) {
              throw new Error("Existing build contains a different libGD pair");
            }
            await rm(path.join(builtGdjsRoot, "node_modules"), {
              recursive: true,
              force: true
            });
            break;
          }
          const buildSync = await synchronizeDirectoryByContent({
            source: sourceRoot,
            destination: buildSourceRoot,
            excludeRelativePaths: new Set([
              ...sourceTreeExclusions,
              "newIDE/app/build"
            ])
          });
          process.stdout.write(
            `[sync] build worktree: ${buildSync.copied} copied, ` +
              `${buildSync.unchanged} unchanged, ${buildSync.removed} removed\n`
          );
          const depsInput = await inputFor("deps");
          const dependencyRoot = dependencyCachePath(depsInput, "app");
          const gdjsDependencyRoot = dependencyCachePath(depsInput, "gdjs");
          const generatedGdjsRoot = path.join(
            buildSourceRoot,
            "newIDE",
            "app",
            "resources",
            "GDJS"
          );
          await linkDependencies({
            appRoot: path.join(buildSourceRoot, "newIDE", "app"),
            dependencyRoot
          });
          await linkDependencies({
            appRoot: path.join(buildSourceRoot, "GDJS"),
            dependencyRoot: gdjsDependencyRoot
          });
          if (!libGdConfig) throw new Error("libGD provenance is unavailable");
          const localLibGdSeed = path.join(
            buildSourceRoot,
            "Binaries",
            "embuild",
            "GDevelop.js"
          );
          await mkdir(localLibGdSeed, { recursive: true });
          for (const fileName of ["libGD.js", "libGD.wasm"]) {
            await copyFile(
              path.join(libGdConfig.cachePath, fileName),
              path.join(localLibGdSeed, fileName)
            );
          }
          await runProcess({
            command: process.execPath,
            args: [npmCliPath, "run", "build"],
            cwd: path.join(buildSourceRoot, "GDJS"),
            env: {
              NODE_PATH: dependencyNodeSearchPath({
                dependencyRoot: gdjsDependencyRoot,
                inheritedNodePath: process.env.NODE_PATH
              })
            },
            signal: abortController.signal,
            logPath: path.join(logsRoot, "build-gdjs.log")
          });
          await stat(
            path.join(generatedGdjsRoot, "Runtime", "libs", "jshashtable.js")
          );
          await runProcess({
            command: process.execPath,
            args: [
              prepareDevelopmentPath,
              "--source",
              buildSourceRoot,
              "--gdjs",
              generatedGdjsRoot,
              "--libgd",
              libGdConfig.cachePath
            ],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath: path.join(logsRoot, "build-prepare-input.log")
          });
          await runProcess({
            command: process.execPath,
            args: [npmCliPath, "run", "build"],
            cwd: path.join(buildSourceRoot, "newIDE", "app"),
            // GDevelop's official import-resources script launches helpers
            // located under GDevelop.js and GDJS. Their module resolution does
            // not climb through newIDE/app/node_modules, so expose the same
            // exact dependency cache to those helpers without installing a
            // second copy in the source tree.
            env: {
              NODE_PATH: dependencyNodeSearchPath({
                dependencyRoot,
                inheritedNodePath: process.env.NODE_PATH
              }),
              PLAYMESH_GDEVELOP_SOURCE_COMMIT: webIdeLock.upstream.commit,
              NODE_OPTIONS: nodeOptionsWithHeapLimit({
                inheritedNodeOptions: process.env.NODE_OPTIONS,
                maxOldSpaceSizeMb: buildNodeHeapMb
              })
            },
            signal: abortController.signal,
            logPath
          });
          const importedLibGd = await validateLibGdPair(
            path.join(buildSourceRoot, "newIDE", "app", "public")
          );
          if (
            stableJson(importedLibGd.files) !== stableJson(libGdConfig.files)
          ) {
            throw new Error("Official build imported a different libGD pair");
          }
          await runProcess({
            command: process.execPath,
            args: [
              prepareDevelopmentPath,
              "--source",
              buildSourceRoot,
              "--gdjs",
              generatedGdjsRoot,
              "--libgd",
              libGdConfig.cachePath,
              "--build",
              path.join(buildSourceRoot, "newIDE", "app", "build")
            ],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath: path.join(logsRoot, "build-prepare-output.log")
          });
          const stagingBuild = await makeStaging("raw-build");
          await rm(stagingBuild, { recursive: true, force: true });
          await cp(
            path.join(buildSourceRoot, "newIDE", "app", "build"),
            stagingBuild,
            {
              recursive: true,
              force: false
            }
          );
          const stagingGdjs = await makeStaging("gdjs");
          await rm(stagingGdjs, { recursive: true, force: true });
          await mkdir(stagingGdjs, { recursive: true });
          await copyFile(
            path.join(buildSourceRoot, "GDJS", "package.json"),
            path.join(stagingGdjs, "package.json")
          );
          await cp(
            path.join(generatedGdjsRoot, "Runtime"),
            path.join(stagingGdjs, "Runtime"),
            {
              recursive: true,
              force: false
            }
          );
          // The isolated GDJS build links its dependency cache into node_modules.
          // Dependencies are build inputs, not auditable runtime source output.
          await rm(path.join(stagingGdjs, "node_modules"), {
            recursive: true,
            force: true
          });
          await replaceDirectoryAtomically({
            staging: stagingBuild,
            target: rawBuildRoot
          });
          failedStaging.delete(stagingBuild);
          await replaceDirectoryAtomically({
            staging: stagingGdjs,
            target: builtGdjsRoot
          });
          failedStaging.delete(stagingGdjs);
          break;
        }
        case "audit": {
          if (!libGdConfig) throw new Error("libGD provenance is unavailable");
          const staging = await makeStaging("audit");
          await rm(staging, { recursive: true, force: true });
          await cp(rawBuildRoot, staging, { recursive: true, force: false });
          const libGd = await validateLibGdPair(libGdConfig.cachePath);
          await runProcess({
            command: process.execPath,
            args: [
              auditPath,
              "--build",
              staging,
              "--lock",
              lockPath,
              "--source",
              sourceRoot,
              "--source-archive",
              sourceArchive,
              "--source-policy-manifest",
              manifestPath,
              "--overlay",
              overlayPath,
              "--libgd-kind",
              libGdConfig.kind,
              "--libgd-source",
              libGdConfig.kind === "official-exact-commit-artifact"
                ? libGdConfig.urlIdentity
                : await canonicalPath(libGdConfig.cachePath),
              "--libgd-upstream-version",
              version,
              "--libgd-js-sha256",
              libGd.files["libGD.js"].sha256,
              "--libgd-js-size",
              String(libGd.files["libGD.js"].size),
              "--libgd-wasm-sha256",
              libGd.files["libGD.wasm"].sha256,
              "--libgd-wasm-size",
              String(libGd.files["libGD.wasm"].size),
              "--libgd-user-decision",
              libGdConfig.userDecision,
              "--expect-ai",
              "session-bootstrap"
            ],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath
          });
          await replaceDirectoryAtomically({
            staging,
            target: auditedBuildRoot
          });
          failedStaging.delete(staging);
          break;
        }
        case "prepare":
          await runProcess({
            command: process.execPath,
            args: [
              preparePath,
              "--input",
              auditedBuildRoot,
              "--gdjs",
              builtGdjsRoot,
              "--source",
              buildSourceRoot,
              "--output",
              preparedRoot,
              "--lock",
              lockPath,
              "--source-policy-manifest",
              manifestPath
            ],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath
          });
          break;
        case "package":
          if (!publishFormalArtifacts) {
            await removeIfExists(pipelineReleaseDirectory);
            await mkdir(pipelineReleaseDirectory, { recursive: true });
            await copyFile(updateManifestPath, pipelineUpdateManifestPath);
          }
          await runProcess({
            command: process.execPath,
            args: [
              packagePath,
              "--action",
              "package",
              "--prepared",
              preparedRoot,
              "--lock",
              lockPath,
              "--source-policy-manifest",
              manifestPath,
              "--manifest",
              pipelineUpdateManifestPath,
              "--release-directory",
              pipelineReleaseDirectory
            ],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath
          });
          break;
        case "verify":
          await runProcess({
            command: process.execPath,
            args: [
              packagePath,
              "--action",
              "verify",
              "--lock",
              lockPath,
              "--source-policy-manifest",
              manifestPath,
              "--manifest",
              pipelineUpdateManifestPath,
              "--release-directory",
              pipelineReleaseDirectory,
              ...(publishFormalArtifacts
                ? []
                : ["--allow-pending-downloads", "true"])
            ],
            cwd: repositoryRoot,
            signal: abortController.signal,
            logPath
          });
          break;
        default:
          throw new Error(`Unsupported step: ${step}`);
      }
      if (interrupted)
        throw new Error("Pipeline interrupted before receipt commit");
      const outputTreeDigest = await outputFor(step);
      if (!outputTreeDigest)
        throw new Error(`${step} produced no valid output evidence`);
      await writeJsonAtomically(
        receiptPath(step),
        createReceipt({
          step,
          inputDigest,
          input,
          toolVersions,
          outputTreeDigest
        })
      );
    };

    const ensureStepOnce = async (step, automatic) => {
      const current = await statusFor(step);
      if (
        current.valid &&
        !(step === "deps" && options.has("--force-deps-refresh"))
      ) {
        process.stdout.write(`[hit] ${step}\n`);
        return;
      }
      for (const prerequisite of prerequisites[step]) {
        const status = await statusFor(prerequisite);
        if (!status.valid) {
          if (!automatic) {
            throw new Error(
              `${step} requires valid ${prerequisite}: ${
                status.reason
              }. Run ${prerequisite} or all.`
            );
          }
          await ensureStep(prerequisite, true);
        }
      }
      process.stdout.write(`[run] ${step}: ${current.reason}\n`);
      await runStep(step);
    };
    const shareEnsureStep = createInFlightOperationDeduplicator();
    const ensureStep = (step, automatic) =>
      shareEnsureStep(step, () => ensureStepOnce(step, automatic));

    const printStatus = async () => {
      const statuses = [];
      for (const step of PIPELINE_STEPS) statuses.push(await statusFor(step));
      const value = createStatusReport({
        profile,
        sourceArchive,
        archiveSha256,
        workRoot,
        steps: statuses
      });
      if (options.has("--json")) {
        process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
      } else {
        for (const status of statuses) {
          process.stdout.write(
            `${status.valid ? "HIT " : "MISS"} ${status.step.padEnd(8)} ${
              status.reason
            }\n`
          );
        }
      }
    };

    if (command === "status") {
      await printStatus();
      return;
    }

    if (command === "dev-package") {
      // A development package still has to satisfy the App install contract.
      // Skip Flow and the full test suite, but keep the inexpensive build audit
      // and provenance preparation so the ZIP contains the schema 3 source
      // marker and can be installed through the same atomic installer as a
      // release package.
      await ensureStep("prepare", true);
      await runProcess({
        command: process.execPath,
        args: [
          packagePath,
          "--action",
          "package",
          "--prepared",
          preparedRoot,
          "--lock",
          lockPath,
          "--source-policy-manifest",
          manifestPath,
          "--manifest",
          updateManifestPath,
          "--release-directory",
          releaseDirectory
        ],
        cwd: repositoryRoot,
        signal: abortController.signal,
        logPath: path.join(logsRoot, "dev-package.log")
      });
      process.stdout.write(
        "dev-package PASS (Flow and full tests skipped; install provenance preserved)\n"
      );
      return;
    }

    const selected = selectPipelineSteps({
      command,
      from: options.get("--from"),
      to: options.get("--to")
    });
    const automatic = command === "all" || command === "release-check";
    const gatePolicy = commandGatePolicy(command);
    const fullAutomaticRun =
      automatic && !options.has("--from") && !options.has("--to");
    if (fullAutomaticRun) {
      await ensureStep("extract", true);
      await Promise.all(
        ["deps", "patch", "libgd"].map(step => ensureStep(step, true))
      );
      await Promise.all(
        ["flow", "test", "build"].map(step => ensureStep(step, true))
      );
      for (const step of selected) {
        if (
          ![
            "extract",
            "deps",
            "patch",
            "libgd",
            "flow",
            "test",
            "build"
          ].includes(step)
        ) {
          await ensureStep(step, true);
        }
      }
    } else {
      if (
        gatePolicy.requiresQualityGates &&
        selected.some(step => step === "package" || step === "verify")
      ) {
        await Promise.all([ensureStep("flow", true), ensureStep("test", true)]);
      }
      for (const step of selected) await ensureStep(step, automatic);
    }

    if (command === "release-check") {
      for (const mandatory of ["flow", "test", "build", "audit", "prepare"]) {
        await ensureStep(mandatory, true);
      }
      const checkRoot = path.join(profileRoot, "release-check");
      const checkRelease = path.join(checkRoot, "release");
      const checkManifest = path.join(checkRoot, "update.json");
      await removeIfExists(checkRoot);
      await mkdir(checkRelease, { recursive: true });
      await copyFile(updateManifestPath, checkManifest);
      await runProcess({
        command: process.execPath,
        args: [
          packagePath,
          "--action",
          "package",
          "--prepared",
          preparedRoot,
          "--lock",
          lockPath,
          "--source-policy-manifest",
          manifestPath,
          "--manifest",
          checkManifest,
          "--release-directory",
          checkRelease
        ],
        cwd: repositoryRoot,
        signal: abortController.signal,
        logPath: path.join(logsRoot, "release-check-package.log")
      });
      await runProcess({
        command: process.execPath,
        args: [
          packagePath,
          "--action",
          "verify",
          "--lock",
          lockPath,
          "--source-policy-manifest",
          manifestPath,
          "--manifest",
          checkManifest,
          "--release-directory",
          checkRelease
        ],
        cwd: repositoryRoot,
        signal: abortController.signal,
        logPath: path.join(logsRoot, "release-check-verify.log")
      });
      process.stdout.write(
        "release-check PASS (resources/GDevelop unchanged)\n"
      );
    }
  } catch (error) {
    if (!keepFailedWorktree) {
      for (const staging of failedStaging) {
        try {
          await removeIfExists(staging);
        } catch (cleanupError) {
          process.stderr.write(
            `[cleanup:failure] warning: could not remove ${staging}: ${
              cleanupError instanceof Error
                ? cleanupError.message
                : String(cleanupError)
            }\n`
          );
        }
      }
    } else if (failedStaging.size > 0) {
      process.stderr.write(
        `Preserved failed staging:\n${[...failedStaging].join("\n")}\n`
      );
    }
    throw error;
  } finally {
    process.removeListener("SIGINT", interrupt);
    process.removeListener("SIGTERM", interrupt);
    await cleanupTransientProfileEntries("finish");
    await releaseLock();
  }
};

if (
  process.argv[1] &&
  pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url
) {
  main().catch(error => {
    process.stderr.write(`${error.stack || error}\n`);
    process.exitCode = interruptedExitCode(error);
  });
}

const interruptedExitCode = error =>
  /abort|interrupted|SIGINT/i.test(String(error && (error.message || error)))
    ? 130
    : 1;
