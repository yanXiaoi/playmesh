import 'dart:convert';

import 'package:flutter/services.dart';

import '../download/endpoint_document_contract.dart';
import '../download/named_download_endpoint.dart';

const gdevelopWebIdeConfigSourcesAssetPath = 'assets/app/GdevelopWebIDE.json';

class GDevelopWebIdeConfigSources {
  const GDevelopWebIdeConfigSources(this.sources);

  final List<NamedDownloadEndpoint> sources;

  bool get configured => sources.isNotEmpty;

  factory GDevelopWebIdeConfigSources.parse(String source) {
    final parsed = NamedDownloadEndpointList.parse(
      source,
      field: 'GDevelop Web IDE config sources',
    );
    return GDevelopWebIdeConfigSources(parsed.endpoints);
  }
}

class GDevelopWebIdeConfigSourcesLoader {
  const GDevelopWebIdeConfigSourcesLoader({this.bundle});

  final AssetBundle? bundle;

  Future<GDevelopWebIdeConfigSources> load() async {
    final source = await (bundle ?? rootBundle).loadString(
      gdevelopWebIdeConfigSourcesAssetPath,
      cache: false,
    );
    return GDevelopWebIdeConfigSources.parse(source);
  }
}

class GDevelopWebIdeReleaseManifest {
  const GDevelopWebIdeReleaseManifest({
    required this.version,
    required this.sha256,
    required this.size,
    required this.downloads,
  });

  static const int maxSafeJsonInteger = 9007199254740991;

  final String version;
  final String sha256;
  final int size;
  final List<NamedDownloadEndpoint> downloads;

  factory GDevelopWebIdeReleaseManifest.parse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on Object catch (error) {
      throw FormatException(
        'GDevelop Web IDE release manifest is not valid JSON: $error',
      );
    }
    return GDevelopWebIdeReleaseManifest.fromJson(decoded);
  }

  factory GDevelopWebIdeReleaseManifest.fromJson(Object? source) {
    final root = strictJsonObject(
      source,
      'GDevelop Web IDE release manifest',
      const {'version', 'sha256', 'size', 'downloads'},
    );
    final version = strictJsonString(root['version'], 'version');
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(version)) {
      throw const FormatException(
        'version may contain only letters, digits, dot, underscore and hyphen',
      );
    }
    final sha256 = strictJsonString(root['sha256'], 'sha256');
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sha256)) {
      throw const FormatException(
        'sha256 must contain 64 lowercase hexadecimal characters',
      );
    }
    final rawSize = root['size'];
    if (rawSize is! int || rawSize <= 0 || rawSize > maxSafeJsonInteger) {
      throw const FormatException(
        'size must be a positive JSON-safe integer byte count',
      );
    }
    final downloads = NamedDownloadEndpointList.fromJson(
      root['downloads'],
      allowEmpty: false,
      field: 'downloads',
    ).endpoints;
    return GDevelopWebIdeReleaseManifest(
      version: version,
      sha256: sha256,
      size: rawSize,
      downloads: downloads,
    );
  }
}

class GDevelopWebIdeReleaseManifestLoader {
  const GDevelopWebIdeReleaseManifestLoader({required this.documentLoader});

  final EndpointDocumentLoader documentLoader;

  Future<GDevelopWebIdeReleaseManifest> load(
    NamedDownloadEndpoint selectedSource,
  ) => documentLoader.load(
    endpoint: selectedSource,
    parse: GDevelopWebIdeReleaseManifest.parse,
  );
}
