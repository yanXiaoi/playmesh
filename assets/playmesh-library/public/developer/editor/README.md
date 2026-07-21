# Developer editor dependencies

This directory is the single dependency root for the Playmesh developer code editor.

- Declare third-party editor packages in `package.json` and keep `package-lock.json` in sync.
- Install packages under this directory's `node_modules/`; do not copy editor dependencies into game templates or Dart source.
- Add only the runtime subdirectories actually used by `workspace.html` to the Flutter asset list.
- The current CodeMirror bundle includes HTML, CSS and JavaScript hints plus Playmesh SDK completion context supplied by `workspace.js`.

Game-project dependencies are not installed here. Upload or extract browser-ready dependencies inside that game's `app/` directory so the game remains a self-contained `main.json + app/` package.
