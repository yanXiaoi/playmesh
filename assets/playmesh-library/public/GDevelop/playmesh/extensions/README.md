# Playmesh extensions

Playmesh-owned GDevelop extension JSON files and their `index.json` live in
this directory. They are public Library resources, not official GDevelop
catalog artifacts, and must not be copied into the upstream source tree, the
generated official catalog, or the WebIDE ZIP.

The Developer Gateway exposes this directory at
`/playmesh/GDevelop/playmesh/extensions/`. The WebIDE loads `index.json` from
that same-origin route and then loads every listed JSON body. Adding another
local extension therefore requires only its JSON file plus one index entry;
it does not require a new WebIDE package.

Index paths are single safe `.json` filenames. Paths and resolved extension
names must be unique, and an optional index `name` must match the body `name`.
The layout and runtime loaders reject traversal, nested paths, duplicate
entries, oversized files, malformed JSON, and partial local catalogs.

The official GDevelop Multiplayer compatibility layer remains a source
overlay so projects keep the official
`Multiplayer::MultiplayerObjectBehavior` JSON and remain portable to official
GDevelop.
