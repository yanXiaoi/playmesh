final class SemanticVersion implements Comparable<SemanticVersion> {
  const SemanticVersion(this.major, this.minor, this.patch);

  static final RegExp _pattern = RegExp(
    r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
  );

  final int major;
  final int minor;
  final int patch;

  static SemanticVersion parse(String value) {
    final match = _pattern.firstMatch(value);
    if (match == null) {
      throw FormatException('版本必须是严格的 MAJOR.MINOR.PATCH：$value');
    }
    return SemanticVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  static SemanticVersion? tryParse(String value) {
    try {
      return parse(value);
    } on FormatException {
      return null;
    }
  }

  @override
  int compareTo(SemanticVersion other) {
    var result = major.compareTo(other.major);
    if (result != 0) return result;
    result = minor.compareTo(other.minor);
    return result != 0 ? result : patch.compareTo(other.patch);
  }

  bool operator <(SemanticVersion other) => compareTo(other) < 0;
  bool operator <=(SemanticVersion other) => compareTo(other) <= 0;
  bool operator >(SemanticVersion other) => compareTo(other) > 0;
  bool operator >=(SemanticVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is SemanticVersion &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}
