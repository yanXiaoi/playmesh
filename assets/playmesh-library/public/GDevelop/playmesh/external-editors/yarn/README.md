# Playmesh Yarn derivative

Version `5.0.134-playmesh.1` derives from GDevelop's locked Yarn import
`5.0.134` (Yarn Editor `0.4.116`). The official input under
`official/external-editors/yarn` remains unchanged.

The derivative provides local `en` and `zh-CN` catalogs plus an explicit Yarn
selector specification. The UI locale is supplied independently from Yarn's
existing `Story language` setting: translating the label never reads, writes or
changes `app.settings.language`, speech-recognition language or option values.

Only the locked English Hunspell dictionary is distributed. The Chinese UI
catalog does not claim Chinese spellcheck support; the settings copy identifies
the local English-only dictionary. Story titles, bodies, tags, playtest text and
all other user content are excluded from translation.

The wrapper receives the committed locale from PlaymeshLocalizationSession.
All runtime, catalog and dictionary assets are local; the derivative does not
restore Yarn's remote dictionary fallback or any other network service.

Yarn's existing `SpeechRecognition` and `speechSynthesis` controls are retained
unchanged. They are browser/platform capabilities rather than GDevelop services;
their availability and any platform-side speech processing are determined by the
hosting WebView, not by this derivative package.
