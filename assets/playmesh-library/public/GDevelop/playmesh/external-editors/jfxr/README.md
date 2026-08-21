# Playmesh Jfxr derivative

Version `5.0.0-beta55-playmesh.1` derives from GDevelop's locked Jfxr editor
`5.0.0-beta55`. The official input under
`official/external-editors/jfxr` remains unchanged.

The derivative provides local `en` and `zh-CN` catalogs plus an explicit Jfxr
selector specification. Static labels and attributes are addressed by stable
official DOM selectors. Angular-created preset, parameter and render-status
nodes are handled only inside named UI roots. Sound names, numeric values and
serialized sound data are never translated.

The wrapper receives the committed locale from PlaymeshLocalizationSession.
The opener/parent document language and browser language are fallbacks only.
All runtime and locale assets are local; the package performs no network
request.
