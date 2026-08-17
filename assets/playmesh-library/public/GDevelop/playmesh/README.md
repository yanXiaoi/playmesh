# Playmesh GDevelop integration

The authoritative design, maintenance and upgrade documentation starts at
[`docs/gdevelop/README.md`](../../../../../docs/gdevelop/README.md).
Feature work on the pinned core must follow
[`docs/gdevelop/feature-development-guide.md`](../../../../../docs/gdevelop/feature-development-guide.md);
upstream tag/commit changes follow the separate core upgrade guide.

This directory contains only Playmesh-owned integration files. Upstream
GDevelop Web IDE files are installed into the sibling `official` directory at
runtime and are deliberately excluded from the application bundle and Git.

## Layout

- `webide-lock.json` pins the upstream source tag and the Playmesh artifact.
- `source-policy-output-manifest.json` enumerates every generated file and
  patched official file, pins each official preimage Git Blob SHA, and freezes
  the canonical overlay tree and every post-policy output with SHA-256.
- `service-policy.json` documents the online features disabled in the
  Playmesh build.
- `scripts/apply-source-policy.mjs` applies version-locked source patches to a
  disposable upstream checkout before it is built.
- `overlays` contains Playmesh-owned source files copied into that disposable
  checkout by `apply-source-policy.mjs` (local project storage, resource
  handling, publishing UI, and preview/package adapters live here).
- `../../developer/playmesh-game-manifest.js` is the single maintained browser
  source for Playmesh `main.json` building, validation, and ID generation.
  `apply-source-policy.mjs` copies it into the disposable GDevelop source tree
  and verifies the copied bytes by SHA-256; no second maintained copy exists.
- `tests/test-production-build-audit.mjs` accepts only the SHA-256-pinned
  official source archive and its policy-replayed source tree. After every
  source, build and explicit AI-state check passes, it issues
  `playmesh-build-provenance.json` into the build. The currently approved B
  exception additionally requires every legacy libGD source, version, digest,
  size and decision field on the command line; it copies only `libGD.js` and
  `libGD.wasm`, verifies their runtime pairing, and records the exact
  `libGdProvenance` object without scanning or fallback.
- `scripts/prepare-webide.mjs` verifies that audited build, combines it with
  the Playmesh document-start policy and matching local GDJS Runtime in an
  atomic staging directory, then issues the schema-3
  `playmesh-integration.json`. Together both records bind the official archive,
  frozen source policy, patched source identity, audited build tree and final
  prepared tree.
  The schema-3 marker repeats and binds the exact libGD exception provenance;
  the remote-release installer rejects missing, unknown or non-B variants.
  User-selected local WebIDE archives use the separate user-provided install
  kind and are validated for safe ZIP/layout, notices, contract identity and
  host-supported execution kinds without requiring official provenance.
- `runtime/ai/tools.json` is the sole maintained AI tool contract. Preparation
  copies its exact bytes to the package path `playmesh/ai/tools.json`; install
  records the raw and canonical hashes, and the Gateway reads that installed
  file on demand for each tools request or new session snapshot. Editor pages
  never register or replace the contract at runtime.
- `scripts/package-webide-release.mjs` creates the root-layout deterministic
  ZIP, derives `GDevelop-webide-v{upstreamVersion}.zip` from the pinned tag,
  computes its SHA-256 and exact byte size, and atomically updates the strict
  `resources/GDevelop/update.json` manifest without changing mirror names. It
  validates both provenance records and recomputes the prepared tree before
  compression and inside the completed ZIP, so stale or modified prepared
  bytes cannot be repackaged accidentally.
- `runtime/host-policy.js` blocks accidental access to GDevelop commercial
  online services and hides their entry points.
- `catalog-lock.json`, `scripts/fetch-catalog-sources.mjs` and
  `scripts/generate-catalog.mjs` build the lightweight official extension and
  example catalog. Example source blobs are never acquired at build time;
  fixed-commit resources are downloaded on demand and hashed locally on first
  successful device download.
- `extensions` is reserved for optional Playmesh-owned project extensions. The
  multiplayer compatibility layer is deliberately not a project extension: it
  preserves the official `Multiplayer::MultiplayerObjectBehavior` project JSON
  and event API and replaces only its runtime transport inside Playmesh.

The upstream checkout, build tree and prepared tree must never be committed
here. Build them from the exact tag and commit in `webide-lock.json`. The final
ZIP is kept locally at `resources/GDevelop/GDevelop-webide-v{version}.zip`.
That ZIP and the strict `update.json` manifest are intentionally tracked by
Git after their SHA-256, exact ZIP byte size and unchanged download list are
verified. The local packaging flow never creates a Release, invokes a hosting
API, or runs Git stage, commit, or push.

## Windows phone testing

Build with the existing Linux dependencies in WSL. After the production build,
run `prepare-dev-webide.mjs` with `--libgd` and `--build` so a failed upstream
libGD download cannot leave zero-byte WebAssembly files. Windows can then serve
the WSL build directly through `\\wsl$\Ubuntu-24.04\...\build`; no Windows npm
installation and no copy to an NTFS staging directory are required.

## Upgrade rule

Every change that affects the prepared Web IDE must be executable from one of
the scripts in `scripts`; do not keep manual edits in an upstream checkout.
Source changes belong in `apply-source-policy.mjs` or `overlays`, and package
changes belong in `prepare-webide.mjs`. Each upstream source patch must retain
its expected Git Blob SHA and a unique source-fragment check. An upstream
upgrade must stop at the exact changed file instead of silently producing a
partially cropped build.

`apply-source-policy.mjs` records the files it actually patches and fails if
that complete set or any upstream Git Blob SHA differs from
`source-policy-output-manifest.json`. A digest may temporarily be the literal
`pending` while policy work is still changing; the script prints the observed
freeze candidates under a release-blocked warning. `verify-layout.mjs` and
`test-source-policy-output.mjs` reject every `pending` value by default. Their
`--allow-pending-output-manifest` switch is only a noisy development aid for
collecting candidates, and a run using it is never release evidence.

The source replay verifier compares canonical overlays with the disposable
checkout byte-for-byte and also compares the Playmesh-owned file set in both
directions. A stale Playmesh file left by an old overlay therefore fails even
when all current overlay files were copied successfully. The production build
audit likewise requires the explicit `--expect-ai session-bootstrap` contract;
omission is an error, so the release command cannot
silently assume the desired AI delivery state.

## Local lifecycle, history and publishing

GDevelop `packageName` is the Playmesh `gameId`; `projectUuid` remains an
independent GDevelop identity. The App Gateway owns managed project allocation,
the project index and canonical current/history evidence below
`packages/{gameId}/.playmesh/gdevelop/`. IndexedDB is only a discardable editor
cache: a create/import is visible to the editor only after the Gateway has
finalized and atomically published the workspace. Cached editing may remain
available during a temporary Gateway outage, but a canonical mutation must stay
pending rather than silently becoming authoritative in IndexedDB.

Portable create/import uses the replayable allocation transaction API. It
prepares an immutable `workspaceTarget`, declares the complete resource plan,
uploads only missing raw blobs plus the exact raw GDevelop project JSON,
finalizes the workspace and then commits the sibling staging directory. The
server derives the resource manifest in official `project.resources.resources`
order; client upload order is not evidence. Resource/project PUT requests may be
HTTP chunked. A present `Content-Length` is only an early limit check, while the
actual byte count and SHA-256 are always decisive. Autosave only updates the
current version, while an explicit save creates a history revision. A restore
verifies every resource size and SHA-256 before replacing the editor cache.

Publishing runs the pinned official browser HTML export pipeline and hands a
text/Blob file map to `PlaymeshPackageUploader.js`; it never builds a second
aggregate archive in the preferred path. The uploader uses the pinned callback
zip.js Writer with `ReadableStream` backpressure and sends the body to the
existing `/dev/api/packages/import` endpoint. If strict streaming feature
detection fails before any request, the UI may offer the official `BlobWriter`
full-memory path only after an explicit warning and confirmation. A connection
loss after any ZIP bytes were produced is treated as an unknown commit state:
there is no automatic fallback or direct retry, and the user must check the
local game library first.

## Official Multiplayer compatibility

The locked official `peerJsHelper.ts`, `multiplayertools.ts` and
`playerauthenticationtools.ts` sources negotiate a frozen private façade only
at their exact external I/O seams. In a Playmesh multiplayer session that
façade replaces PeerJS/lobby transport. A normal official export has no
Playmesh runtime and therefore keeps the official backend. If the Playmesh
runtime exists but its registry or negotiated capability is missing, malformed
or incompatible, the seam fails closed and never falls back to GDevelop cloud
services or PeerJS. The canonical
`../../developer/gdevelop-multiplayer-bridge.js` never monkey-patches `gdjs`.
It keeps the official GDevelop message manager, so custom messages, object
ownership, object/scene/game variables, heartbeats, acknowledgements and
scene/game updates retain their official calling semantics.

The bridge and control-plane sources are each maintained once at
`public/developer/gdevelop-multiplayer-bridge.js` and
`public/developer/gdevelop-authority-bootstrap.js`. `apply-source-policy.mjs`
turns those exact sources into IDE string modules. A Playmesh multiplayer
package writes both sources below `app/static/js/service/`, declares the
canonical Bootstrap as `main.json.authority.entry`, and injects exactly one
`main SDK -> bridge -> canonical Bootstrap` sequence into its copied main HTML.
An explicitly multiplayer-disabled solo package contains none of these
additions. When multiplayer enablement cannot be determined, the package may
conservatively carry the bridge/bootstrap files; the manifest remains solo and
the canonical Bootstrap stays dormant because `multiplayer !== true`.

The official `Extensions/Multiplayer/JsExtension.js` and `messageManager.ts`
are hash-checked but never patched. Generic GDevelop HTML exports, saved project
JSON and projects migrated to the official client therefore contain no
Playmesh SDK, bridge or Bootstrap reference. `PlaymeshPreviewAdapter` decorates
only a preview virtual file system; it is not a generic exporter hook. Runtime
planning keeps bundle presence, activation and presentation orthogonal:
official exports are `none/inactive/game`, solo Playmesh preview/publish is
`full/inactive/game`, online is `full/active/game`, and a diagnostic preview is
`full/inactive/diagnostic`. `connectCore` is true only for active online plans.

The canonical bootstrap owns SDK readiness, the Authority/guest gate, the
low-frequency namespace `playmesh.gdevelop.multiplayer.v1`, stable player-number
snapshots, Binary channel creation/discovery, and coordinator context updates.
The runtime bridge does not discover services or create channels. It maps
high-frequency frames and logical connection control to the attached Playmesh
Binary channel through a fixed star topology. Game SDK/go-core exposes an
incoming Authority sender as `authority`; the bridge resolves this alias to the
session's actual `authorityClientId` before validation and preserves the alias
on the GDevelop-facing connection. GDevelop close/leave is a soft leave and
does not close the underlying Playmesh Session or channel, enabling warm
re-entry. The project JSON is never rewritten with Playmesh-specific events or
objects, so the same project can still be opened by official GDevelop for
native exports.

Run the independent bridge and canonical control-plane regressions with:

```sh
node assets/playmesh-library/public/GDevelop/playmesh/tests/test-multiplayer-bridge.mjs
node tool/test_gdevelop_authority_bootstrap.mjs
```

On every pinned GDevelop upgrade, run `apply-source-policy.mjs` on a clean
checkout. Its blob hashes make the upgrade stop for review when official
Multiplayer sources change while also proving those files stayed unmodified.
