**English** | [简体中文](README.zh-CN.md)

# Playmesh

> **The app is the server: build it, open it, play it, and share it.**

Playmesh is a LAN-first, cross-platform HTML game platform with optional public relay support. When a creator starts a game, the Playmesh App hosts the game, multiplayer session, and Authority. A separate game server is not required for LAN play. Friends can scan a QR code or open a shared link and join immediately in a regular browser without installing the App first.

Browser joining is designed for low-friction access and does not expose Playmesh App native hardware capabilities. Standard Web API availability still depends on the browser, operating system, and user permission. For the complete capability set, or for play across different networks, both sides use the Playmesh App. Internet play requires a reachable public relay server. The relay only pairs endpoints and forwards end-to-end encrypted bytes; game rules and Authority remain on the creator's App.

| Scenario | Join method | Capability boundary |
| --- | --- | --- |
| Same LAN; only the creator has the App | Friends join in a browser through a QR code or link | No installation required; Playmesh native hardware capabilities are unavailable |
| Both sides have the App | Join directly on the LAN, or through a public relay across networks | Games may use declared App platform capabilities; internet mode depends on a public relay |

Games program only against the stable Game SDK. The same game code does not distinguish a LAN browser, LAN App, or public-relay App. Page loading, connection selection, identity, and transport security are platform responsibilities.

Playmesh also integrates AI throughout game development. It generates complete ChatAI and AgentAI project prompts from the current project, runtime mode, capability declarations, and SDK. A regular chat AI can assist through structured instructions, while an Agent with local tool access can directly read and change files, validate the project, run it, and diagnose logs.

Playmesh is developed in the open under the MIT License. Pull requests are welcome. Please read the [contribution guide](CONTRIBUTING.md) before submitting substantial changes, especially changes to public SDKs, generated artifacts, multiplayer authority, packaging, or release workflows.

## What can it run?

Annual-party mini games, browser-based single-player and multiplayer games, small tools, and other HTML-based experiences.

## Core capabilities

- Import, export, and manage Playmesh game packages whose root contains `main.json`.
- **The app is the server:** the creator's App hosts the game, session, and Authority; LAN play needs no additional game server.
- **Install-free browser joining:** friends join a LAN game immediately from a QR code or link.
- **Two-App internet multiplayer:** Apps on different networks establish an end-to-end encrypted connection through an independently deployable Go Server relay.
- Authority, state synchronization, lifecycle, storage, performance, and device-capability plugins for HTML/CSS/JavaScript games.
- **Built-in AI development loop:** complete project prompts for ChatAI and AgentAI, plus editing, diffs, local history, validation, real execution, logs, a Chat Console, and an Agent API.
- A Go-based [`playmesh-cli`](dev-cli/README.md) for initializing or restoring projects in external IDEs, proxying development resources, production builds and runs, independent log following, and unified adapters for JavaScript, TypeScript, and Cocos Creator 3.x.
- Android, Android TV, and Windows release builds. Desktop packages include Go Core and the Developer CLI.

## Architecture overview

```text
Flutter App
  ├─ Game library, installation, and developer workspace
  ├─ GamePage / GameLauncher / WebView
  ├─ GameWebResourceSource
  │    ├─ Installed: installed package app/
  │    └─ Development: temporary CLI development proxy
  ├─ Game SDK / App Bridge SDK
  ├─ Go Core: sessions, players, Authority, credentials, and routing
  └─ Native host: WebView and platform-capability plugins

External Developer CLI
  └─ adapter.Adapter -> Developer Gateway -> Development resource source

Optional Go Server
  ├─ Catalog / game-package sharing, upload, and distribution
  └─ Public Relay / end-to-end encrypted byte forwarding
```

The normal game path is Home/Game Library -> `GamePage` -> `InstalledGameWebResourceSource` -> local resource gateway -> WebView -> SDK/Bridge. The external development path first uses a CLI Adapter to create a temporary resource mapping and development session, then joins the same WebView and SDK/Bridge through `DevelopmentGameWebResourceSource`. The App distinguishes only installed production resources from temporary development resources. A future engine such as Godot adds a CLI `adapter.Adapter` implementation and registry entry without changing the App. Host/joining roles, browser/App clients, and LAN/public-relay transports are orthogonal to these resource states.

See [Technical Architecture](docs/01-architecture.md) for complete boundaries and [Engineering Standards](docs/06-engineering-standards.md) for repository rules. Detailed documents under `docs/` are maintained in Chinese.

## Project documentation and evolution

`docs/` preserves the project's path from inception through phased implementation and versioned maintenance. Phase documents record facts at that time, version notes record increments after phased development ended, and verification records state only the levels actually covered.

| Content | Entry |
| --- | --- |
| Goals, product boundaries, and current capabilities | [Project Context](docs/00-context.md) |
| Technical layers, runtimes, and security boundaries | [Technical Architecture](docs/01-architecture.md) |
| Planning from inception through each phase | [Implementation Roadmap](docs/02-roadmap.md) |
| Current follow-up work and manual acceptance items | [Next Steps](docs/05-next-steps.md) |
| Archived facts for phases one through six | [Phase Status](docs/status/) |
| Releases and the next-version log | [Version Notes](docs/version/README.md) |
| Current implementation locations | [Local Implementation](docs/implementation/README.md) |
| Automated verification, build artifacts, and known boundaries | [Verification Records](docs/verification/) |

## Run locally

```powershell
flutter pub get
flutter run
```

See [Development Environment](docs/04-dev-env.md) for the fixed toolchain, common commands, and release workflow.

## Game development

Start with the [game-development documentation index](docs/game/README.md), then choose a workflow:

| Workflow | Entry | Best for |
| --- | --- | --- |
| ChatAI | [ChatAI workflow](docs/game/chat-ai-development.md) | A regular chat AI that reads and changes a project through the workspace Chat Console |
| AgentAI | [AgentAI workflow](docs/game/agent-ai-development.md) | An Agent with local HTTP tools that directly develops, validates, runs, and diagnoses |
| AI overview | [AI game development](docs/game/ai-development.md) | Comparing both workflows and understanding their shared safety boundaries |
| IDEA / CLI | [IDEA and CLI development](docs/game/idea-cli-development.md) | Editing a local copy in an external IDE and publishing it to a target App |
| Web workspace | [Web developer channel](docs/game/web-dev-channel.md) | Editing, validating, running, and viewing logs in the App or a LAN browser |
| Shared contract | [Game development guide](docs/game/development-guide.md) | Runtime modes, Player/Authority roles, lifecycle, and storage |
| Package format | [Game package and main.json](docs/game/package-format.md) | Directories, manifests, capability declarations, and publication boundaries |
| SDK API | [Game SDK / App Bridge SDK](docs/game/sdk-v1.md) | Public APIs, types, role restrictions, and error semantics |
| Device capabilities | [Game capability guide](docs/game/capability-plugins.md) | Standard Web APIs and declarations for sensitive or cross-platform capabilities |

### AI development

Playmesh does not provide one generic system prompt. It dynamically assembles the project type, page roles, project tree, public SDK declarations, capability context, and Developer Operation contract. AI development therefore uses the same project, validator, runtime, logs, and local history as manual development.

- **ChatAI** requires no local tool permission. Give the generated chat prompt to an AI, paste its JSON instruction into the workspace Chat Console, and return the structured result to the AI for the next step. See [ChatAI workflow](docs/game/chat-ai-development.md).
- **AgentAI** uses the generated Agent prompt and Developer Gateway to read projects, apply atomic file changes, validate, start or restart games, and inspect logs directly. See [AgentAI workflow](docs/game/agent-ai-development.md).

Both workflows use the same Developer Operation API. Dangerous operations such as deletion and WebView JavaScript execution pause for developer approval in the workspace.

Playmesh translates only App-owned UI. The only global object available to a game is `window.playmesh`, whose root public members are exactly `ready`, `main`, and `app`. `window.playmeshApp` does not exist, and `playmesh.main` / `playmesh.app` expose no internal `__*` bridge members. Games first await root `playmesh.ready`; it reuses the `playmesh.main.ready` chain, which waits for `playmesh.app.ready`, and resolves to `{main, app}`. Game/App declaration files are fixed as `playmesh-main.d.ts` and `playmesh-app.d.ts`; legacy Game declaration files are not retained.

A game reads the current display locale through `playmesh.app.runtime.getLocale()`. It does not receive the App dictionary; the game package owns and switches its own content translations.

AI prompt templates are organized by locale under `assets/playmesh-library/public/developer/prompts/{locale}/`. Available locales, the default, and fallback behavior come from the global localization manifest; dynamic prompt UI wording comes from the matching global `app.json`. Adding a prompt language requires resource and manifest changes only, with no language-specific Dart or JavaScript branch.

### IDEA / CLI development

Copy the complete workspace URL shown by the App:

```powershell
playmesh-cli to "http://<app-ip>:16666/dev/<workspace-id>/workspace?token=<token>"
mkdir my-game
cd my-game
playmesh-cli init
npm run dev
```

`init` offers a numeric JavaScript or TypeScript choice and generates IDEA-runnable npm scripts for `build/dev/run/logs/update`. `dev` proxies local development resources into the real App; `run` performs a production build and complete upload. `playmesh-cli get <project-id>` can restore an App build as a JavaScript 2.0 project; `playmesh-cli convert` converts a locally copied Developer API `main.json + app/` package into the same project layout. TypeScript and Cocos source must still be preserved in source control. See [Developer CLI](dev-cli/README.md) for commands, Cocos Creator 3.x integration, destructive directory changes, and publication boundaries.

CLI 2.0 projects isolate publication output in `playmesh/package/` and SDK files in `playmesh/sdk/`. Uploads include required `main.json`, optional `capabilities.json`, optional safe root `icon.png`, and required `app/`; SDK files are never uploaded. The manifest must explicitly declare `entries.game`; single-screen multiplayer also requires `entries.controller`, and multiplayer requires `authority.entry`. Missing entries never fall back to template paths.

## Platform development

Platform maintainers start with the [platform-development documentation index](docs/platform/README.md):

| Topic | Document | Core constraint |
| --- | --- | --- |
| Capability plugins | [Capability development](docs/platform/capability-development.md) | One definition for descriptors, instance lifecycle, platform adapters, self-tests, and registration |
| SDK | [SDK development](docs/platform/sdk-development.md) | TypeScript, declarations, host executors, exact releases, and version executors stay single-sourced |
| Developer Workspace | [Workspace development](docs/platform/developer-workspace-development.md) | Operation Definitions drive routing, docs, permissions, approvals, and AI catalogs |
| Go Server | [Go Server development](docs/platform/go-server-development.md) | Package sources and public relay share a lightweight host while APIs, storage, authentication, and protocol versions remain separate |

The built-in Developer Workspace and platform-injected game WebView UI are App surfaces. Flutter, workspace, and platform Web UI strings come from the current locale's `app.json`. The host exposes only a read-only `locale + messages` projection and updates open pages when the App language changes; Web code keeps no separate dictionary.

When adding a platform domain, create a dedicated convention document in `docs/platform/`, then update the platform index and this README. Game-author documentation describes only public capabilities and must not expose loopback proxies, relay keys, internal Bridges, or Core frame formats.

## Repository layout

```text
lib/                         Flutter App and platform runtime
  core/                      SDK, capabilities, gateways, storage, sessions, developer services
  features/                  Pages and product features
go-core/                     Local sessions, JSON/Binary WebSocket, and routing
go-server/                   Package sharing, upload, Catalog distribution, and public relay
dev-cli/                     Go Developer CLI
assets/playmesh-library/     Generated SDK, Developer Workspace, and default game templates
docs/game/                   Game-author documentation (Chinese)
docs/gdevelop/               GDevelop feature, replay, integration, and core-upgrade conventions (Chinese)
docs/platform/               Platform maintenance and extension conventions (Chinese)
docs/implementation/         Current implementation locations (Chinese)
docs/status/                 Phase-one through phase-six archive (Chinese)
docs/version/                Release notes after phased development (Chinese)
docs/verification/           Automated/platform verification records (Chinese)
tool/                        SDK generation, Core builds, and release scripts
```

## Go Server

`go-server/` is an optional independent service. It is not Go Core and not an authoritative game server. It can be deployed as a small public or team game source for package sharing, upload, and download, and as a temporary tunnel for cross-network App multiplayer. Local and LAN play do not depend on it.

Sensitive credentials come from `go-server/.env`. Non-sensitive runtime settings are managed by the admin form and atomically persisted to `go-server/server.json`. External App port `16668` hosts the public portal, upload, Catalog, approved downloads, and Relay. Port `16669` is a separate admin listener that serves only the hidden `PLAYMESH_ADMIN_PATH`. Each uses an independent Gin Engine, so admin pages, scripts, login, and APIs are never registered on the external port.

See:

- [Go Server deployment and API](go-server/README.md)
- [Go Server development](docs/platform/go-server-development.md)
- [Online game sources and Catalog API](docs/catalog-api.md)
- [LAN and public multiplayer relay](docs/remote-game-relay.md)

Public relay for testing: http://8.137.106.103:16668

## Build and release

The unified build entry supports `android`, `windows`, and `all`:

```powershell
.\tool\build_release.ps1 -Target all
```

It generates the SDK, rebuilds target-platform Go Core, validates packaged entry points, and outputs SHA-256 hashes before the platform build.

After committing all changes on `master`, the current `MAJOR.MINOR.PATCH+BUILD` from `pubspec.yaml` can be built and released to GitHub and Gitee together:

```powershell
# Install and sign in to GitHub CLI the first time
winget install --id GitHub.cli
gh auth login

# Temporary use: inject a Gitee project token into this process only
$env:GITEE_ACCESS_TOKEN = '<private token with project permission>'

# Build Android and Windows, then publish v{VERSION}-build{BUILD}
.\tool\publish_github_release.ps1

# Publish only one platform
.\tool\publish_github_release.ps1 -Target android
.\tool\publish_github_release.ps1 -Target windows

# If GitHub succeeded and Gitee failed, retry Gitee without rebuilding
.\tool\publish_gitee_release.ps1 -Target all
```

The script requires a clean worktree on `master`. It pushes `origin/master`, invokes the unified release build, creates `SHA256SUMS.txt`, links the matching `docs/version/<version>.md` from the release body, creates same-named releases on both platforms, and uploads the same artifacts. The Gitee repository is fixed as `yanxao/playmesh`. Publication waits for the mirror to contain the commit; repeated runs reuse the release and skip attachments with matching names.

The token may instead be stored once in the Git-ignored `release/tools/gitee-token.txt`. Use `-SkipBuild` for existing artifacts. If GitHub already succeeded, run `publish_gitee_release.ps1` separately. `-Draft` creates a GitHub-only draft and does not sync to Gitee; use `-SkipGitee` only when a GitHub-only release is intentional. Android requires production signing by default. Allowing a Debug signature also requires `-Draft` or `-Prerelease` so it cannot be published accidentally as a production release.

See:

- [Development environment and unified release](docs/04-dev-env.md)
- [Version notes](docs/version/README.md)
- [Verification records](docs/verification/)

A successful build does not replace Android device testing, multi-device multiplayer testing, Windows WebView2 testing, or production-signing acceptance. Release conclusions must distinguish automated verification, artifact inspection, and remaining manual work.

## Contributing

Issues, documentation improvements, bug fixes, tests, and focused feature pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development rules and verification expectations.

## License

Playmesh, the Developer CLI, and Go Server are licensed under the [MIT License](LICENSE). A game does not become MIT-licensed merely because it was created with Playmesh or uses Playmesh public APIs; game creators choose the license for their own original code and assets.

Third-party components and assets remain under their respective licenses and notices. In particular, bundled GDevelop-derived and other third-party material must retain the license information shipped with those components. The MIT License does not grant rights to the Playmesh name, logos, or other trademarks.
