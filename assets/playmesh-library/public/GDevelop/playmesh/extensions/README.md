# Playmesh extensions

Playmesh-owned GDevelop extension JSON files belong in this directory. They
must not be copied into the upstream GDevelop source tree.

The official GDevelop Multiplayer project API does not live here. Its Playmesh
compatibility layer is a source overlay so projects keep the official
`Multiplayer::MultiplayerObjectBehavior` JSON and can still be opened and
exported by official GDevelop. A future optional extension may expose native
Playmesh-only session or binary-channel authoring APIs, but it is not required
for official Multiplayer compatibility.

Web IDE download readiness is described by the verified local
`resources/GDevelop/update.json` manifest and stays independent from whether
this optional extensions directory is empty.
