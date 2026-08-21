const maxPlaymeshGameIdLength = 64;

final RegExp playmeshGameIdPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
);

/// Android-compatible application ID required by newly created source
/// projects. Existing Playmesh game IDs deliberately keep using
/// [playmeshGameIdPattern] so installed projects containing `-` remain valid.
final RegExp playmeshNewProjectGameIdPattern = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$',
);

bool isValidPlaymeshGameId(String value) =>
    value.length <= maxPlaymeshGameIdLength &&
    playmeshGameIdPattern.hasMatch(value);

bool isValidPlaymeshNewProjectGameId(String value) =>
    value.length <= maxPlaymeshGameIdLength &&
    playmeshNewProjectGameIdPattern.hasMatch(value);
