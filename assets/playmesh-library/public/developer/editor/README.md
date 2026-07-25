# Developer editor dependencies

This directory is the single dependency root for the Playmesh developer code editor.

- Declare third-party editor packages in `package.json` and keep `package-lock.json` in sync.
- Install packages under this directory's `node_modules/`; do not copy editor dependencies into game templates or Dart source.
- Add only the runtime subdirectories actually used by `workspace.html` to the Flutter asset list.
- Run `npm ci --ignore-scripts` in this directory after checkout or whenever the lock file changes. `node_modules/` is intentionally not committed.
- The current CodeMirror bundle includes HTML, CSS and JavaScript hints, MergeView side-by-side diffs and Playmesh SDK completion context supplied by `workspace.js`. MergeView uses the locked `diff-match-patch` package.

Game-project dependencies are not installed here. Upload or extract browser-ready dependencies inside that game's `app/` directory so the game remains a self-contained `main.json + app/` package.
