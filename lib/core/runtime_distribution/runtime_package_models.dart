import 'dart:convert';

import '../download/named_download_endpoint.dart';

enum RuntimePackageTarget {
  androidX86(
    id: 'android-x86_64',
    platform: 'android',
    architecture: 'x86_64',
    manifestPlatform: 'android',
    manifestVariant: 'x86',
    fileName: 'playmesh-runtime-x86.apk',
  ),
  androidArm(
    id: 'android-arm64',
    platform: 'android',
    architecture: 'arm64-v8a',
    manifestPlatform: 'android',
    manifestVariant: 'arm',
    fileName: 'playmesh-runtime-arm.apk',
  ),
  windowsX64(
    id: 'windows-x64',
    platform: 'windows',
    architecture: 'x86_64',
    manifestPlatform: 'windows',
    manifestVariant: null,
    fileName: 'playmesh-runtime-win.zip',
  );

  const RuntimePackageTarget({
    required this.id,
    required this.platform,
    required this.architecture,
    required this.manifestPlatform,
    required this.manifestVariant,
    required this.fileName,
  });

  final String id;
  final String platform;
  final String architecture;
  final String manifestPlatform;
  final String? manifestVariant;
  final String fileName;

  static RuntimePackageTarget parse(String value) => values.firstWhere(
    (target) => target.id == value,
    orElse: () =>
        throw FormatException('Unknown Runtime package target: $value'),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'platform': platform,
    'architecture': architecture,
    'fileName': fileName,
  };
}

final class RuntimePackageDownloadEndpoint {
  const RuntimePackageDownloadEndpoint({
    required this.name,
    required this.urlValue,
    required this.sha256,
  });

  final String name;
  final String urlValue;
  final String sha256;

  Uri? get url => urlValue.isEmpty ? null : Uri.parse(urlValue);

  bool get downloadable => urlValue.isNotEmpty && sha256.isNotEmpty;

  Map<String, Object?> toJson() => {'name': name, 'url': urlValue};

  @override
  bool operator ==(Object other) =>
      other is RuntimePackageDownloadEndpoint &&
      name == other.name &&
      urlValue == other.urlValue &&
      sha256 == other.sha256;

  @override
  int get hashCode => Object.hash(name, urlValue, sha256);
}

final class RuntimePackageReleaseManifest {
  RuntimePackageReleaseManifest._({
    required this.version,
    required Map<RuntimePackageTarget, _RuntimePackageVariant> variants,
  }) : _sha256 = Map<RuntimePackageTarget, String>.unmodifiable({
         for (final entry in variants.entries) entry.key: entry.value.sha256,
       }),
       _downloads =
           Map<
             RuntimePackageTarget,
             List<RuntimePackageDownloadEndpoint>
           >.unmodifiable({
             for (final entry in variants.entries)
               entry.key: List<RuntimePackageDownloadEndpoint>.unmodifiable(
                 entry.value.downloads,
               ),
           });

  static const int maxDownloadEndpoints = 16;

  final String version;
  final Map<RuntimePackageTarget, String> _sha256;
  final Map<RuntimePackageTarget, List<RuntimePackageDownloadEndpoint>>
  _downloads;

  factory RuntimePackageReleaseManifest.parse(String source) {
    final decoded = decodeStrictJson(source, 'Runtime package manifest');
    return RuntimePackageReleaseManifest.fromJson(decoded);
  }

  factory RuntimePackageReleaseManifest.fromJson(Object? source) {
    final root = strictJsonObject(source, 'Runtime package manifest', const {
      'version',
      'platform',
    });
    final version = strictJsonString(root['version'], 'version');
    if (version.length > 128 ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]*$').hasMatch(version)) {
      throw const FormatException('Runtime package version is invalid');
    }

    final platforms = strictJsonObject(root['platform'], 'platform', const {
      'android',
      'windows',
    });
    final android = strictJsonObject(
      platforms['android'],
      'platform.android',
      const {'x86', 'arm'},
    );

    return RuntimePackageReleaseManifest._(
      version: version,
      variants: {
        RuntimePackageTarget.androidX86: _parseVariant(
          android['x86'],
          'platform.android.x86',
        ),
        RuntimePackageTarget.androidArm: _parseVariant(
          android['arm'],
          'platform.android.arm',
        ),
        RuntimePackageTarget.windowsX64: _parseVariant(
          platforms['windows'],
          'platform.windows',
        ),
      },
    );
  }

  String sha256For(RuntimePackageTarget target) => _sha256[target] ?? '';

  List<RuntimePackageDownloadEndpoint> downloadsFor(
    RuntimePackageTarget target,
  ) => _downloads[target] ?? const [];

  bool canDownload(RuntimePackageTarget target) =>
      downloadsFor(target).any((endpoint) => endpoint.downloadable);

  Map<String, Object?> toJson() => {
    'version': version,
    'platform': {
      'android': {
        'x86': _variantToJson(RuntimePackageTarget.androidX86),
        'arm': _variantToJson(RuntimePackageTarget.androidArm),
      },
      'windows': _variantToJson(RuntimePackageTarget.windowsX64),
    },
  };

  Map<String, Object?> _variantToJson(RuntimePackageTarget target) => {
    'sha256': sha256For(target),
    'downloads': [
      for (final endpoint in downloadsFor(target)) endpoint.toJson(),
    ],
  };

  static _RuntimePackageVariant _parseVariant(Object? source, String field) {
    final variant = strictJsonObject(source, field, const {
      'sha256',
      'downloads',
    });
    final sha256 = strictJsonString(variant['sha256'], '$field.sha256');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw FormatException(
        '$field.sha256 must contain 64 lowercase hexadecimal characters',
      );
    }

    final sourceDownloads = variant['downloads'];
    if (sourceDownloads is! List) {
      throw FormatException('$field.downloads must be an array');
    }
    if (sourceDownloads.length > maxDownloadEndpoints) {
      throw FormatException(
        '$field.downloads exceeds the endpoint count limit',
      );
    }

    final downloads = <RuntimePackageDownloadEndpoint>[];
    final normalizedNames = <String>{};
    final normalizedUrls = <String>{};
    for (var index = 0; index < sourceDownloads.length; index += 1) {
      final itemField = '$field.downloads[$index]';
      final item = strictJsonObject(sourceDownloads[index], itemField, const {
        'name',
        'url',
      });
      final name = strictJsonString(item['name'], '$itemField.name');
      if (name.length > 80 ||
          name.contains(RegExp(r'[\u0000-\u001f\u007f]')) ||
          !normalizedNames.add(name.toLowerCase())) {
        throw FormatException('$itemField.name is unsafe or duplicated');
      }

      final rawUrl = item['url'];
      if (rawUrl is! String || rawUrl != rawUrl.trim()) {
        throw FormatException('$itemField.url must be a trimmed string');
      }
      if (rawUrl.isNotEmpty) {
        Uri.parse(rawUrl);
        if (!normalizedUrls.add(rawUrl)) {
          throw FormatException('$itemField.url is duplicated');
        }
      }

      downloads.add(
        RuntimePackageDownloadEndpoint(
          name: name,
          urlValue: rawUrl,
          sha256: sha256,
        ),
      );
    }
    return _RuntimePackageVariant(sha256: sha256, downloads: downloads);
  }
}

final class _RuntimePackageVariant {
  const _RuntimePackageVariant({required this.sha256, required this.downloads});

  final String sha256;
  final List<RuntimePackageDownloadEndpoint> downloads;
}

Object? decodeStrictJson(String source, String field) {
  try {
    return jsonDecode(source);
  } on FormatException catch (error) {
    throw FormatException('$field is not valid JSON: ${error.message}');
  } on Object catch (error) {
    throw FormatException('$field is not valid JSON: $error');
  }
}
