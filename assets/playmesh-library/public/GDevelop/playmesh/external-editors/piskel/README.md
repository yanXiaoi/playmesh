# Playmesh Piskel derivative

Version `5.5.228-playmesh.1` derives from GDevelop's locked Piskel editor
`5.5.228` (Piskel runtime `0.15.2-SNAPSHOT`). The official input under
`official/external-editors/piskel` stays unchanged.

The derivative adds a small, explicit translation runtime and local `en` and
`zh-CN` catalogs. GDevelop's Playmesh localization session passes the locale to
the Piskel wrapper. The inner editor receives the same locale in its URL;
document and browser languages are fallbacks only.

Static UI is translated through selector rules scoped to named Piskel template
IDs. Dynamic tools and shortcuts use their runtime IDs. Known native dialogs
and notifications use registered message keys and parameter patterns. There is
no whole-document text-node rewrite, and model/user content is never sent
through the translator.

To upgrade, replace and re-lock the official Piskel input first, review the
template/runtime identifiers, update both catalogs and this manifest, then run
the Piskel localization and clean source-policy replay tests.
