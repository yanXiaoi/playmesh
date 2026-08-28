import 'dart:convert';

import 'package:playmesh_database/playmesh_database.dart';

import '../capabilities/capability_runtime.dart';
import '../app_media/app_media_runtime.dart';
import '../diagnostics/playmesh_error_diagnostic.dart';
import '../game_web/game_share_link_snapshot.dart';
import '../session/go_core_session_client.dart';
import '../storage/app_local_bucket_store.dart';

part 'features/app/app_capability_feature.dart';
part 'features/app/app_core_feature.dart';
part 'features/app/app_device_feature.dart';
part 'features/app/app_lan_feature.dart';
part 'features/app/app_media_feature.dart';
part 'features/app/app_media_webrtc_feature.dart';
part 'features/app/app_performance_feature.dart';
part 'features/app/app_storage_feature.dart';
part 'features/app/app_ui_feature.dart';
part 'features/app/app_webrtc_feature.dart';
part 'features/game/game_binary_feature.dart';
part 'features/game/game_database_feature.dart';
part 'features/game/game_authority_feature.dart';
part 'features/game/game_core_feature.dart';
part 'features/game/game_performance_feature.dart';
part 'features/game/game_rpc_feature.dart';
part 'features/game/game_runtime_feature.dart';
part 'features/game/game_session_feature.dart';
part 'features/game/game_storage_lifecycle_feature.dart';
part 'features/game/game_sync_feature.dart';
part 'features/game/game_webrtc_feature.dart';

enum SdkSourceTarget { game, app }

/// 一个不可变的 SDK 兼容发行版。
///
/// [supportedRequestedVersions] 中的游戏声明都会使用 [bundleVersion] 对应的 Dart
/// 源快照。SDK 保留明确版本号，但兼容集合只能追加；增量发行统一由最新兼容 Bundle
/// 承接，不建立破坏旧调用端的发行边界。
final class SdkRelease {
  SdkRelease._({
    required this.target,
    required List<String> supportedRequestedVersions,
    required this.minimumRequestedVersion,
    required this.maximumRequestedVersion,
    required this.bundleVersion,
    required Map<String, String> files,
    required Map<String, _GameSdkCommandFeature> gameCommands,
    required Map<String, _AppSdkCommandFeature> appCommands,
  }) : supportedRequestedVersions = List.unmodifiable(
         supportedRequestedVersions,
       ),
       _files = Map.unmodifiable(files),
       _gameCommands = Map.unmodifiable(gameCommands),
       _appCommands = Map.unmodifiable(appCommands);

  final SdkSourceTarget target;
  final List<String> supportedRequestedVersions;
  final String minimumRequestedVersion;
  final String maximumRequestedVersion;
  final String bundleVersion;
  final Map<String, String> _files;
  final Map<String, _GameSdkCommandFeature> _gameCommands;
  final Map<String, _AppSdkCommandFeature> _appCommands;

  bool supports(String requestedVersion) =>
      supportedRequestedVersions.contains(requestedVersion);

  Set<String> get commandNames => Set.unmodifiable(
    target == SdkSourceTarget.game ? _gameCommands.keys : _appCommands.keys,
  );

  Map<String, Object> toJson() => {
    'minimumRequestedVersion': minimumRequestedVersion,
    'maximumRequestedVersion': maximumRequestedVersion,
    'bundleVersion': bundleVersion,
    'supportedRequestedVersions': supportedRequestedVersions,
  };
}

/// SDK 生成器读取的源片段。片段和对应宿主执行器位于同一个 feature 文件。
class SdkSourceFragment {
  const SdkSourceFragment({
    required this.id,
    required this.target,
    required this.order,
    required this.typeScript,
    this.declaration = '',
  });

  final String id;
  final SdkSourceTarget target;
  final int order;
  final String typeScript;
  final String declaration;
}

/// Dart 执行器支持的 SDK bundle 版本区间。
///
/// 调用契约未修改的执行器以 [last] 作为开放上界，无需随 SDK 升级修改。允许按 Bundle
/// 版本替换内部执行器实现，但每个公开命令必须始终存在开放上界的兼容执行器，且不得改变
/// 参数、消息、返回值、事件或错误语义。
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

class SdkCommandException implements Exception, PlaymeshDiagnosticError {
  const SdkCommandException(
    this.code,
    this.message, {
    this.cause,
    this.causeStackTrace,
    this.context = const {},
  });

  @override
  final String code;
  @override
  final String message;

  @override
  final Object? cause;

  @override
  final StackTrace? causeStackTrace;

  @override
  final Map<String, String> context;

  @override
  String toString() => formatPlaymeshDiagnosticError(this);
}

/// App 命令的公开结果，以及必须在 Bridge 成功回包后才执行的宿主动作。
final class AppSdkCommandResponse {
  const AppSdkCommandResponse({this.result, this.afterResponse});

  final Object? result;
  final Future<void> Function()? afterResponse;
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
    required this.completeLifecycle,
    this.gameInfo = const <String, Object?>{},
    this.connection,
    this.standalonePlayer,
    this.updateNickname,
    this.ensureDatabase,
  });

  final GameSessionConnection? connection;
  final Map<String, Object?>? standalonePlayer;
  final Map<String, Object?> gameInfo;
  final bool Function(String requestId) completeLifecycle;
  final Future<Map<String, Object?>> Function(String nickname)? updateNickname;
  final Future<PlaymeshDatabase> Function()? ensureDatabase;

  bool get isStandalone => connection == null;
  bool get isAuthority => connection?.isAuthority ?? true;
}

class AppSdkCommandContext {
  AppSdkCommandContext({
    required this.bootstrap,
    required this.configureRuntimeGame,
    required this.confirmCapabilities,
    required this.capabilityRuntime,
    required this.mediaRuntime,
    required this.sendCapabilityEvent,
    required this.disposeCapability,
    required this.setFullscreen,
    required this.openSharePanel,
    required this.consumeUserActivation,
    required this.lanHost,
    required this.takeOverInput,
    required this.requestExit,
    required this.syncAvatar,
    required this.updateNickname,
    required this.localBucketStore,
  });

  final Future<Map<String, Object?>> Function(
    Map<String, Object?> payload,
    String sdkVersion,
  )
  bootstrap;
  final Future<Map<String, Object?>> Function(Map<String, Object?> payload)
  configureRuntimeGame;
  final Object? Function() confirmCapabilities;
  final CapabilityRuntime capabilityRuntime;
  final AppMediaRuntime mediaRuntime;
  final Future<void> Function(Map<String, Object?> message) sendCapabilityEvent;
  final Future<Object?> Function(Map<String, Object?> payload)
  disposeCapability;
  final Future<Object?> Function(Map<String, Object?> payload) setFullscreen;
  final Future<Object?> Function() openSharePanel;
  final bool Function() consumeUserActivation;
  final AppLanHost? lanHost;
  final Object? Function() takeOverInput;
  final Object? Function() requestExit;
  final Future<Object?> Function(Map<String, Object?> payload) syncAvatar;
  final Future<Object?> Function(Map<String, Object?> payload) updateNickname;
  final AppLocalBucketStore? localBucketStore;
}

/// 唯一 SDK 注册位置。新增功能时在对应 feature 文件实现并在这里注册一次。
final class SdkFeatureRegistry {
  SdkFeatureRegistry._();

  /// 本兼容政策生效时已经公开的 Game 请求版本。该列表不可修改或删除。
  static const List<String> gameSdkCompatibilityBaselineVersions = ['4.1.0'];

  /// 本兼容政策生效时已经公开的 App 请求版本。该列表不可修改或删除。
  static const List<String> appSdkCompatibilityBaselineVersions = [
    '3.2.0',
    '3.3.0',
  ];

  /// 已公开并永久保留的 Game SDK 请求版本。新版本只能追加到末尾。
  static const List<String> gameSdkSupportedRequestVersions = [
    '4.1.0',
    '4.2.0',
    '4.3.0',
  ];

  /// 已公开并永久保留的 App SDK 请求版本。新版本只能追加到末尾。
  static const List<String> appSdkSupportedRequestVersions = [
    '3.2.0',
    '3.3.0',
    '3.4.0',
    '3.5.0',
  ];

  static final List<_GameSdkCommandFeature> _gameCommandFeatures = [
    _GameCoreFeature(),
    _GameSessionFeature(),
    _GameWebRTCFeature(),
    _GameDatabaseFeature(),
    _GameStorageLifecycleFeature(),
    _GamePerformanceTransportFeature(),
  ];

  static final List<_AppSdkCommandFeature> _appCommandFeatures = [
    _AppCoreFeature(),
    _AppStorageFeature(),
    _AppCapabilityFeature(),
    _AppMediaFeature(),
    _AppUiFeature(),
    _AppLanFeature(),
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
    gameWebRTCSdkSource,
    gameSyncSdkSource,
    gameAuthoritySdkSource,
    gameRpcSdkSource,
    gamePerformanceSdkSource,
    gameRuntimeSdkSource,
    gameDatabaseSdkSource,
    gameStorageLifecycleSdkSource,
    appCoreSdkSource,
    appStorageSdkSource,
    appCapabilitySdkSource,
    appMediaSdkSource,
    appMediaWebRtcSdkSource,
    appPerformanceSdkSource,
    appUiSdkSource,
    appWebRTCSdkSource,
    appLanSdkSource,
    appDeviceSdkSource,
  ];

  static final _SdkRuntimeBundle _runtimeBundle = _assembleRuntimeBundle(
    sourceFragments,
  );

  static final List<SdkRelease> _sdkReleases = _registerSdkReleases([
    SdkRelease._(
      target: SdkSourceTarget.game,
      supportedRequestedVersions: gameSdkSupportedRequestVersions,
      minimumRequestedVersion: gameSdkSupportedRequestVersions.first,
      maximumRequestedVersion: gameSdkSupportedRequestVersions.last,
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
      // App SDK 只做兼容新增，全部已发布请求版本共享当前 Bundle。
      supportedRequestedVersions: appSdkSupportedRequestVersions,
      minimumRequestedVersion: appSdkSupportedRequestVersions.first,
      maximumRequestedVersion: appSdkSupportedRequestVersions.last,
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
    // raw TypeScript 只用于注册表组装和正式生成，不能成为运行时公开资源。
    final target = _publicSdkTargetForFileOrNull(name);
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
      name == 'playmesh-main.js' ||
      name == 'playmesh-main.d.ts') {
    return SdkSourceTarget.game;
  }
  if (name == 'playmesh-app.ts' ||
      name == 'playmesh-app.js' ||
      name == 'playmesh-app.d.ts') {
    return SdkSourceTarget.app;
  }
  return null;
}

SdkSourceTarget? _publicSdkTargetForFileOrNull(String name) {
  if (name == 'playmesh-main.js' || name == 'playmesh-main.d.ts') {
    return SdkSourceTarget.game;
  }
  if (name == 'playmesh-app.js' || name == 'playmesh-app.d.ts') {
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
    if (targetReleases.length != 1) {
      throw StateError('$target 只能注册一个覆盖全部历史请求版本的兼容 SDK 发行版');
    }
    final compatibilityBaseline = switch (target) {
      SdkSourceTarget.game =>
        SdkFeatureRegistry.gameSdkCompatibilityBaselineVersions,
      SdkSourceTarget.app =>
        SdkFeatureRegistry.appSdkCompatibilityBaselineVersions,
    };
    SdkRelease? previous;
    for (final release in targetReleases) {
      final supported = release.supportedRequestedVersions;
      if (supported.isEmpty || supported.toSet().length != supported.length) {
        throw StateError('${release.bundleVersion} 的 SDK 兼容版本集合无效');
      }
      if (supported.length < compatibilityBaseline.length ||
          compatibilityBaseline.indexed.any(
            (entry) => supported[entry.$1] != entry.$2,
          )) {
        throw StateError(
          '${release.bundleVersion} 不能移除或改写 SDK 兼容基线 '
          '${compatibilityBaseline.join(', ')}',
        );
      }
      for (var index = 0; index < supported.length; index += 1) {
        _parseSdkVersion(supported[index], 'SDK 兼容请求版本');
        if (index > 0 &&
            _compareSdkVersions(supported[index - 1], supported[index]) >= 0) {
          throw StateError('${release.bundleVersion} 的 SDK 兼容版本必须严格递增');
        }
      }
      if (_compareSdkVersions(
            release.minimumRequestedVersion,
            release.maximumRequestedVersion,
          ) >
          0) {
        throw StateError('${release.bundleVersion} 的 SDK 兼容版本范围无效');
      }
      if (release.minimumRequestedVersion != supported.first ||
          release.maximumRequestedVersion != supported.last ||
          release.bundleVersion != supported.last) {
        throw StateError('${release.bundleVersion} 的 SDK 版本化兼容元数据不一致');
      }
      final baselineMajor = _parseSdkVersion(supported.first, 'SDK 兼容基线').first;
      if (supported.any(
        (version) =>
            _parseSdkVersion(version, 'SDK 兼容请求版本').first != baselineMajor,
      )) {
        throw StateError('${release.bundleVersion} 不能跨 MAJOR 建立破坏性 SDK 发行');
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
  final versions = releases
      .expand((release) => release.supportedRequestedVersions)
      .join(', ');
  throw UnsupportedError('不支持的 $target SDK 版本 $requested；可用版本：$versions');
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

  final declarationFragments =
      fragmentList
          .where((fragment) => fragment.declaration.trim().isNotEmpty)
          .toList()
        ..sort((left, right) {
          final targetComparison = left.target.index.compareTo(
            right.target.index,
          );
          return targetComparison != 0
              ? targetComparison
              : left.order.compareTo(right.order);
        });

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
  const appVersionPlaceholder = '__PLAYMESH_APP_SDK_VERSION__';
  final gameTypeScript = game.typeScript.replaceAll(
    appVersionPlaceholder,
    app.version,
  );
  final gameJavaScript = game.javaScript.replaceAll(
    appVersionPlaceholder,
    app.version,
  );
  final gameDeclaration =
      _appendSdkDeclarationFragments(
            game.declaration,
            declarationFragments.map((fragment) => fragment.declaration),
          )
          .replaceAll('__PLAYMESH_SDK_VERSION__', game.version)
          .replaceAll(appVersionPlaceholder, app.version);
  for (final entry in {
    'playmesh.ts': gameTypeScript,
    'playmesh-main.js': gameJavaScript,
    'playmesh-main.d.ts': gameDeclaration,
  }.entries) {
    if (entry.value.contains(appVersionPlaceholder)) {
      throw StateError(
        '${entry.key} still contains the App SDK version placeholder',
      );
    }
  }
  return _SdkRuntimeBundle(
    gameVersion: game.version,
    appVersion: app.version,
    files: Map.unmodifiable({
      'playmesh.ts': gameTypeScript,
      'playmesh-main.js': gameJavaScript,
      'playmesh-main.d.ts': gameDeclaration,
      'playmesh-app.ts': app.typeScript,
      'playmesh-app.js': app.javaScript,
      'playmesh-app.d.ts': app.declaration,
    }),
  );
}

String _appendSdkDeclarationFragments(String base, Iterable<String> fragments) {
  final sections = <String>[
    base.trim(),
    ...fragments
        .map((fragment) => fragment.trim())
        .where((fragment) => fragment.isNotEmpty),
  ];
  return '${sections.join('\n\n')}\n';
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
    if (!executors
        .expand((ranges) => ranges)
        .any((range) => range.maximum == SdkVersionRange.last)) {
      throw StateError('$label 命令 ${entry.key} 缺少面向后续版本的兼容执行器');
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
