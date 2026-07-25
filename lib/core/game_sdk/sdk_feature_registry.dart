import '../capabilities/capability_runtime.dart';
import '../session/go_core_session_client.dart';
import '../storage/game_storage_service.dart';

part 'features/app/app_capability_feature.dart';
part 'features/app/app_core_feature.dart';
part 'features/app/app_device_feature.dart';
part 'features/game/game_binary_feature.dart';
part 'features/game/game_core_feature.dart';
part 'features/game/game_performance_feature.dart';
part 'features/game/game_runtime_feature.dart';
part 'features/game/game_session_feature.dart';
part 'features/game/game_storage_lifecycle_feature.dart';
part 'features/game/game_sync_feature.dart';

enum SdkSourceTarget { game, app }

/// 一个不可变的 SDK 兼容发行版。
///
/// [minimumRequestedVersion] 到 [maximumRequestedVersion] 的游戏声明都会使用
/// [bundleVersion] 对应的 Dart 源快照。未来出现不兼容升级时，保留旧发行版并新增一项，
/// 不修改旧项的范围和源文件。
final class SdkRelease {
  SdkRelease._({
    required this.target,
    required this.minimumRequestedVersion,
    required this.maximumRequestedVersion,
    required this.bundleVersion,
    required Map<String, String> files,
    required Map<String, _GameSdkCommandFeature> gameCommands,
    required Map<String, _AppSdkCommandFeature> appCommands,
  }) : _files = Map.unmodifiable(files),
       _gameCommands = Map.unmodifiable(gameCommands),
       _appCommands = Map.unmodifiable(appCommands);

  final SdkSourceTarget target;
  final String minimumRequestedVersion;
  final String maximumRequestedVersion;
  final String bundleVersion;
  final Map<String, String> _files;
  final Map<String, _GameSdkCommandFeature> _gameCommands;
  final Map<String, _AppSdkCommandFeature> _appCommands;

  bool supports(String requestedVersion) =>
      _compareSdkVersions(requestedVersion, minimumRequestedVersion) >= 0 &&
      _compareSdkVersions(requestedVersion, maximumRequestedVersion) <= 0;

  Set<String> get commandNames => Set.unmodifiable(
    target == SdkSourceTarget.game ? _gameCommands.keys : _appCommands.keys,
  );

  Map<String, String> toJson() => {
    'minimumRequestedVersion': minimumRequestedVersion,
    'maximumRequestedVersion': maximumRequestedVersion,
    'bundleVersion': bundleVersion,
  };
}

/// SDK 生成器读取的源片段。片段和对应宿主执行器位于同一个 feature 文件。
class SdkSourceFragment {
  const SdkSourceFragment({
    required this.id,
    required this.target,
    required this.order,
    required this.typeScript,
  });

  final String id;
  final SdkSourceTarget target;
  final int order;
  final String typeScript;
}

/// Dart 执行器支持的 SDK bundle 版本区间。
///
/// 调用契约未修改的执行器以 [last] 作为开放上界，无需随 SDK 升级修改。命令的参数、
/// 消息、返回值、事件或错误语义不兼容时，旧执行器保留封口区间，新版本目录注册一个
/// 不重叠的新执行器。
class SdkVersionRange {
  const SdkVersionRange(this.minimum, this.maximum);

  /// 开放版本上界。使用它的执行器会自动覆盖后续 SDK 版本。
  static const String last = 'last';

  final String minimum;
  final String maximum;

  bool supports(String version) =>
      _compareSdkVersions(version, minimum) >= 0 &&
      (maximum == last || _compareSdkVersions(version, maximum) <= 0);

  bool overlaps(SdkVersionRange other) =>
      (other.maximum == last ||
          _compareSdkVersions(minimum, other.maximum) <= 0) &&
      (maximum == last || _compareSdkVersions(other.minimum, maximum) <= 0);
}

class SdkCommandEnvelope {
  const SdkCommandEnvelope({
    required this.name,
    required this.requestId,
    required this.payload,
    required this.raw,
  });

  final String name;
  final String? requestId;
  final Map<String, Object?> payload;
  final Map<String, Object?> raw;
}

sealed class SdkCommandExecution {
  const SdkCommandExecution();
}

class SdkCommandResult extends SdkCommandExecution {
  const SdkCommandResult([this.value]);

  final Object? value;
}

class SdkCommandMessage extends SdkCommandExecution {
  const SdkCommandMessage(this.message);

  final Map<String, Object?> message;
}

class SdkCommandDeferred extends SdkCommandExecution {
  const SdkCommandDeferred();
}

abstract interface class _GameSdkCommandFeature {
  SdkSourceFragment get source;

  List<SdkVersionRange> get supportedVersions;

  Set<String> get commands;

  Future<SdkCommandExecution> execute(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  );
}

abstract interface class _AppSdkCommandFeature {
  SdkSourceFragment get source;

  List<SdkVersionRange> get supportedVersions;

  Set<String> get commands;

  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  );
}

class GameSdkCommandContext {
  GameSdkCommandContext({
    required this.ensureStorage,
    required this.emitFps,
    required this.emitLatency,
    required this.completeLifecycle,
    required this.routeRemoteStorage,
    this.connection,
    this.standalonePlayer,
  });

  final GameSessionConnection? connection;
  final Map<String, Object?>? standalonePlayer;
  final Future<GameStorageService> Function() ensureStorage;
  final void Function(double value) emitFps;
  final void Function(double? value) emitLatency;
  final bool Function(String requestId) completeLifecycle;
  final Future<void> Function(
    String command,
    String? requestId,
    Map<String, Object?> payload,
  )
  routeRemoteStorage;

  bool get isStandalone => connection == null;
}

class AppSdkCommandContext {
  AppSdkCommandContext({
    required this.bootstrap,
    required this.confirmCapabilities,
    required this.capabilityRuntime,
    required this.sendCapabilityEvent,
    required this.disposeCapability,
    required this.setFullscreen,
    required this.requestExit,
  });

  final Future<Map<String, Object?>> Function(
    Map<String, Object?> payload,
    String sdkVersion,
  )
  bootstrap;
  final Object? Function() confirmCapabilities;
  final CapabilityRuntime capabilityRuntime;
  final Future<void> Function(Map<String, Object?> message) sendCapabilityEvent;
  final Future<Object?> Function(Map<String, Object?> payload)
  disposeCapability;
  final Future<Object?> Function(Map<String, Object?> payload) setFullscreen;
  final Object? Function() requestExit;
}

/// 唯一 SDK 注册位置。新增功能时在对应 feature 文件实现并在这里注册一次。
final class SdkFeatureRegistry {
  SdkFeatureRegistry._();

  static final List<_GameSdkCommandFeature> _gameCommandFeatures = [
    _GameCoreFeature(),
    _GameSessionFeature(),
    _GameStorageLifecycleFeature(),
    _GamePerformanceFeature(),
  ];

  static final List<_AppSdkCommandFeature> _appCommandFeatures = [
    _AppCoreFeature(),
    _AppCapabilityFeature(),
    _AppDeviceFeature(),
  ];

  static final Map<String, List<_GameSdkCommandFeature>> _gameCommandIndex =
      _indexSdkCommands(
        _gameCommandFeatures,
        (feature) => feature.commands,
        (feature) => feature.supportedVersions,
        'Game SDK',
      );

  static final Map<String, List<_AppSdkCommandFeature>> _appCommandIndex =
      _indexSdkCommands(
        _appCommandFeatures,
        (feature) => feature.commands,
        (feature) => feature.supportedVersions,
        'App SDK',
      );

  static const List<SdkSourceFragment> sourceFragments = [
    gameCoreSdkSource,
    gameBinarySdkSource,
    gameSessionSdkSource,
    gameSyncSdkSource,
    gamePerformanceSdkSource,
    gameRuntimeSdkSource,
    gameStorageLifecycleSdkSource,
    appCoreSdkSource,
    appCapabilitySdkSource,
    appDeviceSdkSource,
  ];

  static final _SdkRuntimeBundle _runtimeBundle = _assembleRuntimeBundle(
    sourceFragments,
  );

  static final List<SdkRelease> _sdkReleases = _registerSdkReleases([
    SdkRelease._(
      target: SdkSourceTarget.game,
      minimumRequestedVersion: '1.0.0',
      maximumRequestedVersion: _runtimeBundle.gameVersion,
      bundleVersion: _runtimeBundle.gameVersion,
      files: _sdkFilesForTarget(_runtimeBundle.files, SdkSourceTarget.game),
      gameCommands: _sdkCommandsForVersion(
        _gameCommandIndex,
        (feature) => feature.supportedVersions,
        _runtimeBundle.gameVersion,
        'Game SDK',
      ),
      appCommands: const {},
    ),
    SdkRelease._(
      target: SdkSourceTarget.app,
      minimumRequestedVersion: '1.0.0',
      maximumRequestedVersion: _runtimeBundle.appVersion,
      bundleVersion: _runtimeBundle.appVersion,
      files: _sdkFilesForTarget(_runtimeBundle.files, SdkSourceTarget.app),
      gameCommands: const {},
      appCommands: _sdkCommandsForVersion(
        _appCommandIndex,
        (feature) => feature.supportedVersions,
        _runtimeBundle.appVersion,
        'App SDK',
      ),
    ),
  ]);

  static List<SdkRelease> get gameSdkReleases => List.unmodifiable(
    _sdkReleases.where((release) => release.target == SdkSourceTarget.game),
  );

  static List<SdkRelease> get appSdkReleases => List.unmodifiable(
    _sdkReleases.where((release) => release.target == SdkSourceTarget.app),
  );

  static String get gameSdkVersion => gameSdkReleases.last.bundleVersion;

  static String get appSdkVersion => appSdkReleases.last.bundleVersion;

  /// 把游戏声明的版本解析到一个已注册且不可变的 Game SDK 发行版。
  static String resolveGameSdkVersion([String? requestedVersion]) =>
      _resolveSdkRelease(SdkSourceTarget.game, requestedVersion).bundleVersion;

  /// 把游戏声明的版本解析到一个已注册且不可变的 App SDK 发行版。
  static String resolveAppSdkVersion([String? requestedVersion]) =>
      _resolveSdkRelease(SdkSourceTarget.app, requestedVersion).bundleVersion;

  /// 返回由当前 Dart feature 即时组装的 SDK 文件，不读取打包的旧静态资源。
  static String sdkFile(String name, {String? version}) {
    final target = _sdkTargetForFile(name);
    final release = _resolveSdkRelease(target, version);
    final source = release._files[name];
    if (source == null) throw ArgumentError.value(name, 'name', '未知 SDK 文件');
    return source;
  }

  static String? sdkFileForPublicPath(
    String relativePath, {
    String? gameVersion,
    String? appVersion,
  }) {
    const prefix = 'sdk/v1/';
    if (!relativePath.startsWith(prefix)) return null;
    final name = relativePath.substring(prefix.length);
    final target = _sdkTargetForFileOrNull(name);
    if (target == null) return null;
    return sdkFile(
      name,
      version: target == SdkSourceTarget.game ? gameVersion : appVersion,
    );
  }

  static Set<String> get gameCommandNames => gameSdkReleases.last.commandNames;

  static Set<String> get appCommandNames => appSdkReleases.last.commandNames;

  static Future<SdkCommandExecution> dispatchGame(
    GameSdkCommandContext context,
    SdkCommandEnvelope command,
  ) {
    final release = _resolveCommandSdkRelease(SdkSourceTarget.game, command);
    final feature = release._gameCommands[command.name];
    if (feature == null) {
      throw FormatException(
        '${release.bundleVersion} 未注册 Game SDK 命令: ${command.name}',
      );
    }
    return feature.execute(context, command);
  }

  static Future<Object?> dispatchApp(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) {
    final release = _resolveCommandSdkRelease(SdkSourceTarget.app, command);
    final feature = release._appCommands[command.name];
    if (feature == null) {
      throw FormatException(
        '${release.bundleVersion} 未注册 App SDK 命令：${command.name}',
      );
    }
    return feature.execute(context, command);
  }
}

String _resolveCommandSdkVersion(
  SdkSourceTarget target,
  SdkCommandEnvelope command,
) => _resolveCommandSdkRelease(target, command).bundleVersion;

SdkRelease _resolveCommandSdkRelease(
  SdkSourceTarget target,
  SdkCommandEnvelope command,
) {
  final value = command.raw['sdkVersion'];
  if (value != null && value is! String) {
    throw const FormatException('sdkVersion 必须是字符串');
  }
  return _resolveSdkRelease(target, value as String?);
}

SdkSourceTarget _sdkTargetForFile(String name) {
  final target = _sdkTargetForFileOrNull(name);
  if (target == null) throw ArgumentError.value(name, 'name', '未知 SDK 文件');
  return target;
}

SdkSourceTarget? _sdkTargetForFileOrNull(String name) {
  if (name == 'playmesh.ts' ||
      name == 'playmesh.js' ||
      name == 'playmesh.d.ts') {
    return SdkSourceTarget.game;
  }
  if (name == 'playmesh-app.ts' ||
      name == 'playmesh-app.js' ||
      name == 'playmesh-app.d.ts') {
    return SdkSourceTarget.app;
  }
  return null;
}

Map<String, String> _sdkFilesForTarget(
  Map<String, String> files,
  SdkSourceTarget target,
) {
  return {
    for (final entry in files.entries)
      if (_sdkTargetForFileOrNull(entry.key) == target) entry.key: entry.value,
  };
}

List<SdkRelease> _registerSdkReleases(Iterable<SdkRelease> releases) {
  final result = releases.toList()
    ..sort(
      (left, right) => _compareSdkVersions(
        left.minimumRequestedVersion,
        right.minimumRequestedVersion,
      ),
    );
  for (final target in SdkSourceTarget.values) {
    final targetReleases = result
        .where((release) => release.target == target)
        .toList();
    if (targetReleases.isEmpty) {
      throw StateError('$target 没有注册 SDK 发行版');
    }
    SdkRelease? previous;
    for (final release in targetReleases) {
      if (_compareSdkVersions(
            release.minimumRequestedVersion,
            release.maximumRequestedVersion,
          ) >
          0) {
        throw StateError('${release.bundleVersion} 的 SDK 兼容版本范围无效');
      }
      if (!release._files.values.any(
        (source) => source.contains(release.bundleVersion),
      )) {
        throw StateError('${release.bundleVersion} 的 SDK 源文件版本不一致');
      }
      if (release.target == SdkSourceTarget.game &&
          (release._gameCommands.isEmpty || release._appCommands.isNotEmpty)) {
        throw StateError('${release.bundleVersion} 的 Game SDK 执行器注册无效');
      }
      if (release.target == SdkSourceTarget.app &&
          (release._appCommands.isEmpty || release._gameCommands.isNotEmpty)) {
        throw StateError('${release.bundleVersion} 的 App SDK 执行器注册无效');
      }
      if (previous != null &&
          _compareSdkVersions(
                release.minimumRequestedVersion,
                previous.maximumRequestedVersion,
              ) <=
              0) {
        throw StateError(
          '$target SDK 兼容版本范围重叠：'
          '${previous.bundleVersion} / ${release.bundleVersion}',
        );
      }
      previous = release;
    }
  }
  return List.unmodifiable(result);
}

SdkRelease _resolveSdkRelease(
  SdkSourceTarget target,
  String? requestedVersion,
) {
  final releases = SdkFeatureRegistry._sdkReleases
      .where((release) => release.target == target)
      .toList();
  final requested = requestedVersion ?? releases.last.bundleVersion;
  _parseSdkVersion(requested, 'SDK 版本');
  for (final release in releases) {
    if (release.supports(requested)) return release;
  }
  final ranges = releases
      .map(
        (release) =>
            '${release.minimumRequestedVersion}-${release.maximumRequestedVersion}',
      )
      .join(', ');
  throw UnsupportedError('不支持的 $target SDK 版本 $requested；可用范围：$ranges');
}

int _compareSdkVersions(String left, String right) {
  final leftParts = _parseSdkVersion(left, 'SDK 版本');
  final rightParts = _parseSdkVersion(right, 'SDK 版本');
  for (var index = 0; index < 3; index += 1) {
    final comparison = leftParts[index].compareTo(rightParts[index]);
    if (comparison != 0) return comparison;
  }
  return 0;
}

List<int> _parseSdkVersion(String value, String field) {
  final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
  if (match == null) throw FormatException('$field 必须使用 MAJOR.MINOR.PATCH');
  return [
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  ];
}

class _SdkRuntimeBundle {
  const _SdkRuntimeBundle({
    required this.gameVersion,
    required this.appVersion,
    required this.files,
  });

  final String gameVersion;
  final String appVersion;
  final Map<String, String> files;
}

class _SdkTargetBundle {
  const _SdkTargetBundle({
    required this.version,
    required this.typeScript,
    required this.javaScript,
    required this.declaration,
  });

  final String version;
  final String typeScript;
  final String javaScript;
  final String declaration;
}

_SdkRuntimeBundle _assembleRuntimeBundle(
  Iterable<SdkSourceFragment> fragments,
) {
  final fragmentList = fragments.toList();
  final ids = <String>{};
  final orders = <String>{};
  for (final fragment in fragmentList) {
    if (!ids.add(fragment.id)) {
      throw StateError('SDK feature id 重复: ${fragment.id}');
    }
    final orderKey = '${fragment.target.name}:${fragment.order}';
    if (!orders.add(orderKey)) {
      throw StateError('SDK feature order 重复: $orderKey');
    }
    if (fragment.typeScript.trim().isEmpty) {
      throw StateError('SDK feature ${fragment.id} 没有 TypeScript 源码');
    }
  }

  String sourceFor(SdkSourceTarget target) {
    final ordered =
        fragmentList.where((fragment) => fragment.target == target).toList()
          ..sort((left, right) => left.order.compareTo(right.order));
    if (ordered.isEmpty) {
      throw StateError('$target 没有注册 SDK feature 源码');
    }
    return ordered.map((fragment) => fragment.typeScript).join();
  }

  final game = _assembleSdkTarget(
    source: sourceFor(SdkSourceTarget.game),
    declarationName: 'PLAYMESH_DECLARATION',
    versionName: 'PLAYMESH_SDK_VERSION',
    versionPlaceholder: '__PLAYMESH_SDK_VERSION__',
  );
  final app = _assembleSdkTarget(
    source: sourceFor(SdkSourceTarget.app),
    declarationName: 'PLAYMESH_APP_DECLARATION',
    versionName: 'PLAYMESH_APP_SDK_VERSION',
    versionPlaceholder: '__PLAYMESH_APP_SDK_VERSION__',
  );
  final gameDeclaration = game.declaration.replaceAll(
    '__PLAYMESH_APP_SDK_VERSION__',
    app.version,
  );
  return _SdkRuntimeBundle(
    gameVersion: game.version,
    appVersion: app.version,
    files: Map.unmodifiable({
      'playmesh.ts': game.typeScript,
      'playmesh.js': game.javaScript,
      'playmesh.d.ts': gameDeclaration,
      'playmesh-app.ts': app.typeScript,
      'playmesh-app.js': app.javaScript,
      'playmesh-app.d.ts': app.declaration,
    }),
  );
}

_SdkTargetBundle _assembleSdkTarget({
  required String source,
  required String declarationName,
  required String versionName,
  required String versionPlaceholder,
}) {
  final declarationPattern = RegExp(
    'const $declarationName = String\\.raw`([\\s\\S]*?)`;\\n+',
  );
  final declarationMatch = declarationPattern.firstMatch(source);
  if (declarationMatch == null) {
    throw StateError('SDK Dart feature 缺少 $declarationName 声明模板');
  }
  final versionPattern = RegExp(
    'const $versionName = ["\'](\\d+\\.\\d+\\.\\d+)["\'];',
  );
  final versionMatch = versionPattern.firstMatch(source);
  if (versionMatch == null) {
    throw StateError('SDK Dart feature 缺少合法的 $versionName');
  }
  final version = versionMatch.group(1)!;
  return _SdkTargetBundle(
    version: version,
    typeScript: source,
    javaScript: source.replaceFirst(declarationPattern, ''),
    declaration: declarationMatch
        .group(1)!
        .replaceAll(versionPlaceholder, version)
        .trimLeft(),
  );
}

/// 校验同一命令的多个 Dart 执行器版本声明。
///
/// Map 的每个 value 元素代表一个执行器声明的全部版本区间；任意两个执行器的区间
/// 相交都会失败，避免同一 SDK 版本出现两个解析器。
void validateSdkCommandVersionRanges(
  Map<String, List<List<SdkVersionRange>>> registrations, {
  String label = 'SDK',
}) {
  for (final entry in registrations.entries) {
    final executors = entry.value;
    for (
      var executorIndex = 0;
      executorIndex < executors.length;
      executorIndex += 1
    ) {
      final ranges = executors[executorIndex];
      if (ranges.isEmpty) {
        throw StateError('$label 命令 ${entry.key} 的执行器没有声明支持版本');
      }
      for (var left = 0; left < ranges.length; left += 1) {
        final range = ranges[left];
        _parseSdkVersion(range.minimum, 'SDK 执行器最低版本');
        if (range.maximum != SdkVersionRange.last &&
            _compareSdkVersions(range.minimum, range.maximum) > 0) {
          throw StateError(
            '$label 命令 ${entry.key} 的执行器版本范围无效: '
            '${range.minimum}-${range.maximum}',
          );
        }
        for (var right = left + 1; right < ranges.length; right += 1) {
          if (range.overlaps(ranges[right])) {
            throw StateError('$label 命令 ${entry.key} 的同一执行器版本范围重叠');
          }
        }
        for (
          var otherIndex = executorIndex + 1;
          otherIndex < executors.length;
          otherIndex += 1
        ) {
          if (executors[otherIndex].any(range.overlaps)) {
            throw StateError('$label 命令 ${entry.key} 的支持版本存在多个 Dart 执行器');
          }
        }
      }
    }
  }
}

Map<String, List<T>> _indexSdkCommands<T>(
  Iterable<T> features,
  Set<String> Function(T feature) commandsOf,
  List<SdkVersionRange> Function(T feature) versionsOf,
  String label,
) {
  final result = <String, List<T>>{};
  final registrations = <String, List<List<SdkVersionRange>>>{};
  for (final feature in features) {
    for (final command in commandsOf(feature)) {
      result.putIfAbsent(command, () => []).add(feature);
      registrations.putIfAbsent(command, () => []).add(versionsOf(feature));
    }
  }
  validateSdkCommandVersionRanges(registrations, label: label);
  final immutable = <String, List<T>>{
    for (final entry in result.entries)
      entry.key: List<T>.unmodifiable(entry.value),
  };
  return Map<String, List<T>>.unmodifiable(immutable);
}

Map<String, T> _sdkCommandsForVersion<T>(
  Map<String, List<T>> commandIndex,
  List<SdkVersionRange> Function(T feature) versionsOf,
  String bundleVersion,
  String label,
) {
  final result = <String, T>{};
  for (final entry in commandIndex.entries) {
    final matches = entry.value
        .where(
          (feature) =>
              versionsOf(feature).any((range) => range.supports(bundleVersion)),
        )
        .toList();
    if (matches.length > 1) {
      throw StateError('$label 命令 ${entry.key} 在 $bundleVersion 存在多个 Dart 执行器');
    }
    if (matches.length == 1) result[entry.key] = matches.single;
  }
  return Map.unmodifiable(result);
}

String sdkRequiredString(Map<String, Object?> payload, String key) {
  final value = payload[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}
