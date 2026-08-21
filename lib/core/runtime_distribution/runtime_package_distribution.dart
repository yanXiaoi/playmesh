import '../download/app_resource_source_catalog.dart';
import '../download/endpoint_document_contract.dart';
import '../download/named_download_endpoint.dart';
import 'runtime_package_models.dart';

const runtimePackageResourceKey = 'export';

typedef RuntimePackageAssetLoader = Future<String> Function(String assetKey);

final class RuntimePackageConfigSources {
  const RuntimePackageConfigSources(this.sources);

  final List<NamedDownloadEndpoint> sources;

  bool get configured => sources.isNotEmpty;

  factory RuntimePackageConfigSources.parse(String source) {
    final parsed = AppResourceSourceCatalog.parse(source).endpointsFor(
      runtimePackageResourceKey,
      field: 'Runtime package config sources',
    );
    return RuntimePackageConfigSources(parsed.endpoints);
  }

  Map<String, Object?> toJson() => {
    'configured': configured,
    'sources': [
      for (final source in sources)
        {'name': source.name, 'url': source.url.toString()},
    ],
  };
}

final class RuntimePackageConfigSourcesLoader {
  const RuntimePackageConfigSourcesLoader({required this.assetLoader});

  final RuntimePackageAssetLoader assetLoader;

  Future<RuntimePackageConfigSources> load() async =>
      RuntimePackageConfigSources.parse(
        await assetLoader(appResourceSourceCatalogAssetPath),
      );
}

final class RuntimePackageReleaseManifestLoader {
  const RuntimePackageReleaseManifestLoader({required this.documentLoader});

  final EndpointDocumentLoader documentLoader;

  Future<RuntimePackageReleaseManifest> load(
    NamedDownloadEndpoint selectedSource,
  ) => documentLoader.load(
    endpoint: selectedSource,
    parse: RuntimePackageReleaseManifest.parse,
  );
}
