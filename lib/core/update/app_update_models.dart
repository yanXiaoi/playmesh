import 'dart:convert';

import '../download/endpoint_probe_contract.dart';
import '../download/named_download_endpoint.dart';
import '../version/semantic_version.dart';

const Set<String> supportedAppUpdatePlatforms = {
  'android',
  'ios',
  'linux',
  'macos',
  'web',
  'windows',
};

final class AppUpdateManifest {
  const AppUpdateManifest({
    required this.version,
    required this.releaseNotes,
    required this.platforms,
  });

  static const int maxReleaseNotesLength = 20000;

  final SemanticVersion version;
  final String releaseNotes;
  final Map<String, NamedDownloadEndpointList> platforms;

  factory AppUpdateManifest.parse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on Object catch (error) {
      throw FormatException('app update manifest is not valid JSON: $error');
    }
    return AppUpdateManifest.fromJson(decoded);
  }

  factory AppUpdateManifest.fromJson(Object? source) {
    if (source is! Map) {
      throw const FormatException('app update manifest must be an object');
    }
    final object = <String, Object?>{};
    for (final entry in source.entries) {
      if (entry.key is! String) {
        throw const FormatException(
          'app update manifest contains a non-string key',
        );
      }
      object[entry.key as String] = entry.value;
    }

    const requiredKeys = {'version', 'releaseNotes'};
    final unknownKeys = object.keys.toSet().difference({
      ...requiredKeys,
      ...supportedAppUpdatePlatforms,
    });
    final missingKeys = requiredKeys.difference(object.keys.toSet());
    if (missingKeys.isNotEmpty || unknownKeys.isNotEmpty) {
      throw FormatException(
        'app update manifest fields differ; '
        'missing=${missingKeys.join(',')} unknown=${unknownKeys.join(',')}',
      );
    }

    final version = SemanticVersion.parse(
      strictJsonString(object['version'], 'version'),
    );
    final releaseNotes = strictJsonString(
      object['releaseNotes'],
      'releaseNotes',
    );
    if (releaseNotes.length > maxReleaseNotesLength ||
        releaseNotes.contains(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
        )) {
      throw const FormatException('releaseNotes is too long or unsafe');
    }

    final platforms = <String, NamedDownloadEndpointList>{};
    for (final platform in supportedAppUpdatePlatforms) {
      final value = object[platform];
      if (value == null) continue;
      final platformObject = strictJsonObject(value, platform, const {
        'downloads',
      });
      platforms[platform] = NamedDownloadEndpointList.fromJson(
        platformObject['downloads'],
        field: '$platform.downloads',
      );
    }
    if (platforms.isEmpty) {
      throw const FormatException(
        'app update manifest must declare at least one platform',
      );
    }

    return AppUpdateManifest(
      version: version,
      releaseNotes: releaseNotes,
      platforms: Map.unmodifiable(platforms),
    );
  }
}

enum AppUpdateVersionState { available, current, ahead }

final class AppUpdateDownload {
  const AppUpdateDownload({required this.endpoint, required this.probe});

  final NamedDownloadEndpoint endpoint;
  final EndpointProbeResult probe;
}

final class AppUpdateCheckResult {
  const AppUpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.source,
    required this.platform,
    required this.platformAvailable,
    required this.downloads,
    required this.sourceCount,
    required this.successfulSourceCount,
  });

  final SemanticVersion currentVersion;
  final SemanticVersion latestVersion;
  final String releaseNotes;
  final NamedDownloadEndpoint source;
  final String platform;
  final bool platformAvailable;
  final List<AppUpdateDownload> downloads;
  final int sourceCount;
  final int successfulSourceCount;

  AppUpdateVersionState get versionState {
    final comparison = latestVersion.compareTo(currentVersion);
    if (comparison > 0) return AppUpdateVersionState.available;
    if (comparison < 0) return AppUpdateVersionState.ahead;
    return AppUpdateVersionState.current;
  }
}

enum AppUpdateCheckFailureKind {
  invalidConfiguration,
  noAvailableManifest,
  closed,
}

final class AppUpdateCheckException implements Exception {
  const AppUpdateCheckException({required this.kind, required this.diagnostic});

  final AppUpdateCheckFailureKind kind;
  final String diagnostic;

  @override
  String toString() => 'AppUpdateCheckException($diagnostic)';
}
