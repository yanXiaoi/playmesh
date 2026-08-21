const maxPlaymeshGameIdLength = 64;

final RegExp playmeshGameIdPattern = RegExp(
  r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$',
);

bool isValidPlaymeshGameId(String value) =>
    value.length <= maxPlaymeshGameIdLength &&
    playmeshGameIdPattern.hasMatch(value);
