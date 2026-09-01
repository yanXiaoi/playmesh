/// 固定 Runtime 随包携带的 SDK Bundle 与兼容版本区间。
///
/// 公开 SDK 从兼容基线开始只允许兼容演进。Runtime 因而接受基线到当前 Bundle
/// 之间的任意严格语义版本，并把包内 SDK 统一升级为当前 Bundle；高于当前 Bundle、
/// 早于兼容基线或格式错误的版本必须拒绝。正式 Runtime 构建的 SDK 资产必须与这里一致。
abstract final class RuntimeSdkCompatibility {
  static const List<String> gameBaselineVersions = ['4.1.0'];
  static const List<String> appBaselineVersions = ['3.2.0', '3.3.0'];
  static const String gameMinimumVersion = '4.1.0';
  static const String appMinimumVersion = '3.2.0';
  static const String gameBundleVersion = '4.3.0';
  static const String appBundleVersion = '3.5.0';

  static bool supportsGameRequest(String version) => _isWithinInclusiveRange(
    version,
    minimum: gameMinimumVersion,
    maximum: gameBundleVersion,
  );

  static bool supportsAppRequest(String version) => _isWithinInclusiveRange(
    version,
    minimum: appMinimumVersion,
    maximum: appBundleVersion,
  );

  static bool _isWithinInclusiveRange(
    String version, {
    required String minimum,
    required String maximum,
  }) {
    final parsed = _parse(version);
    if (parsed == null) return false;
    return _compare(parsed, _parse(minimum)!) >= 0 &&
        _compare(parsed, _parse(maximum)!) <= 0;
  }

  static (int, int, int)? _parse(String version) {
    final match = RegExp(
      r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
    ).firstMatch(version);
    if (match == null) return null;
    return (
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  static int _compare((int, int, int) left, (int, int, int) right) {
    final major = left.$1.compareTo(right.$1);
    if (major != 0) return major;
    final minor = left.$2.compareTo(right.$2);
    if (minor != 0) return minor;
    return left.$3.compareTo(right.$3);
  }
}
