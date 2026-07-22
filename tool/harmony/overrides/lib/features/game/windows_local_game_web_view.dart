// Harmony uses dart:io, so the normal conditional export would select the
// Windows implementation and pull in a Flutter 3.44-only package. This build
// overlay keeps the Windows-only implementation out of the Harmony snapshot.
export 'windows_local_game_web_view_stub.dart';
