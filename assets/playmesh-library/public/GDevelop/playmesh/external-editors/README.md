# Playmesh local external-editor derivatives

This directory contains the versioned, local-only derivative layers applied to
the locked GDevelop external-editor inputs in `../../official/external-editors`.
The official trees remain byte-for-byte source evidence; they are never edited
in place.

Each package owns a manifest and an `overlay/` tree. The source policy verifies
the declared official baseline, verifies the derivative assets, copies the
official tree, and only then applies the local overlay. A version upgrade is an
explicit change to both the locked official input and the derivative manifest.

The entire directory is included in the WebIDE patch receipt input digest, so a
locale or runtime change invalidates an otherwise reusable patched-source cache.
