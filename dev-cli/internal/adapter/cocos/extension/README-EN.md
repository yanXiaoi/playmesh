# Playmesh for Cocos Creator

**Author:** Playmesh
**Release date:** 2026-07-30
**Requires:** Cocos Creator >= 3.0.0 and < 4.0.0
**Platforms:** Windows and macOS

## Overview

Playmesh is a project extension installed by `playmesh-cli init cocos`. It
connects Cocos Creator 3.8 Web Mobile and Web Desktop builds to the Playmesh
App.

- Adds Playmesh publishing and run-after-build options to Web builds.
- Stages build output in the isolated directory configured by
  `playmesh-cli.json`.
- Injects the Playmesh Game SDK and can upload and run the build in the
  physical App.
- Adds project settings, build, run-latest, live-log, and update actions under
  **Extensions -> Playmesh**.
- The project settings panel edits the game name, version, notes, tags,
  runtime shape, capability declarations, and Cocos integration options.
- Author is not configurable; every development launch refreshes the current
  base metadata.
- Clicking Creator browser preview automatically runs
  `playmesh-cli dev <full current preview page URL>` through a short-lived,
  single-use token, preserving platform and build-task subpaths.
- Uses an available system port by default; set
  `integration.previewBridgePort` to require a fixed port.
- The ordinary browser only performs the authenticated handoff; the game
  renders only inside the Playmesh App WebView.

For first use, refresh the Cocos Extension Manager and enable Playmesh under
Installed Extensions.

> Cocos Creator 3.8 has no public API for adding custom entries to the
> publishing-platform or preview-device dropdown. Playmesh appears in the Web
> Mobile/Web Desktop build options instead.
