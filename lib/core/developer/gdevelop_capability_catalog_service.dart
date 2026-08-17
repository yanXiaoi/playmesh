import 'dart:convert';

import 'package:flutter/services.dart';

import 'gdevelop_catalog_artifact_service.dart';

typedef GDevelopCapabilityCatalogIndexLoader = Future<String> Function();

class GDevelopCapabilityCatalogException implements Exception {
  const GDevelopCapabilityCatalogException(
    this.code,
    this.message, {
    this.retryable = false,
  });

  final String code;
  final String message;
  final bool retryable;

  @override
  String toString() => '$code: $message';
}

class GDevelopCapabilitySearchRequest {
  const GDevelopCapabilitySearchRequest({
    this.query = '',
    this.kind,
    this.category,
    this.page = 1,
    this.pageSize = 20,
  });

  final String query;
  final String? kind;
  final String? category;
  final int page;
  final int pageSize;
}

class GDevelopCapabilitySearchResult {
  const GDevelopCapabilitySearchResult({
    required this.page,
    required this.pageSize,
    required this.total,
    required this.items,
  });

  final int page;
  final int pageSize;
  final int total;
  final List<Map<String, Object?>> items;
}

class GDevelopCapabilityDetailResult {
  const GDevelopCapabilityDetailResult({required this.capability});

  final Map<String, Object?> capability;
}

/// Read-only view over the pinned GDevelop extension catalog.
///
/// Search never reaches the network. Detail acquisition reuses the catalog
/// artifact service, so verified CAS bytes are preferred and a remote download
/// is attempted only when the immutable artifact is not installed yet.
class GDevelopCapabilityCatalogService {
  // Keep the public dependency name descriptive without exposing a mutable
  // service field as part of this catalog's API.
  // ignore: prefer_initializing_formals
  GDevelopCapabilityCatalogService({
    required GDevelopCatalogArtifactService artifacts,
    GDevelopCapabilityCatalogIndexLoader? indexLoader,
  }) : _artifactService = artifacts,
       _indexLoader =
           indexLoader ??
           (() => rootBundle.loadString(
             'assets/playmesh-library/public/GDevelop/playmesh/catalog/generated/extensions-index.json',
           ));

  static const supportedKinds = {'extension', 'behavior'};
  static const maximumPageSize = 50;

  final GDevelopCatalogArtifactService _artifactService;
  final GDevelopCapabilityCatalogIndexLoader _indexLoader;
  Future<_GDevelopCapabilityCatalog>? _catalog;

  Future<GDevelopCapabilitySearchResult> search(
    GDevelopCapabilitySearchRequest request,
  ) async {
    _validateSearch(request);
    final catalog = await _loadCatalog();
    final query = request.query.trim().toLowerCase();
    final category = request.category?.trim().toLowerCase();
    final filtered = catalog.capabilities
        .where((capability) {
          if (request.kind != null && capability.type != request.kind) {
            return false;
          }
          if (category != null &&
              category.isNotEmpty &&
              capability.category.toLowerCase() != category) {
            return false;
          }
          return query.isEmpty || capability.searchText.contains(query);
        })
        .toList(growable: false);
    final start = (request.page - 1) * request.pageSize;
    final pageItems = start >= filtered.length
        ? const <_GDevelopCapability>[]
        : filtered.sublist(
            start,
            start + request.pageSize < filtered.length
                ? start + request.pageSize
                : filtered.length,
          );
    return GDevelopCapabilitySearchResult(
      page: request.page,
      pageSize: request.pageSize,
      total: filtered.length,
      items: pageItems
          .map((capability) => capability.toSummaryJson())
          .toList(growable: false),
    );
  }

  Future<GDevelopCapabilityDetailResult?> detail({
    required String kind,
    required String stableId,
  }) async {
    _validateKind(kind);
    if (stableId.isEmpty ||
        stableId.length > 256 ||
        !RegExp(
          r'^[A-Za-z][A-Za-z0-9_]*(?:::[A-Za-z][A-Za-z0-9_]*)?$',
        ).hasMatch(stableId)) {
      throw const FormatException('GDevelop capability stableId 无效');
    }
    final catalog = await _loadCatalog();
    final capability = catalog.byIdentity['$kind:$stableId'];
    if (capability == null) return null;
    final artifactJson = catalog.artifacts[capability.ownerExtension];
    if (artifactJson == null) {
      throw const GDevelopCapabilityCatalogException(
        'capability_artifact_unavailable',
        '本地能力目录缺少对应扩展正文描述',
      );
    }
    final artifactPayload = _artifactPayload(artifactJson);
    final GDevelopCatalogArtifactResult artifact;
    try {
      artifact = await _artifactService.acquire(
        GDevelopCatalogArtifactRequest.fromJson(artifactPayload),
      );
    } on Object {
      // Do not expose download URLs, proxy addresses, paths or low-level
      // exceptions to browser callers.
      throw const GDevelopCapabilityCatalogException(
        'capability_artifact_unavailable',
        '能力详情正文当前不可用，请稍后重试',
        retryable: true,
      );
    }
    final Map<String, Object?> extension;
    try {
      final decoded = jsonDecode(await artifact.file.readAsString());
      if (decoded is! Map) throw const FormatException('扩展正文根对象无效');
      extension = Map<String, Object?>.from(decoded);
    } on Object {
      throw const GDevelopCapabilityCatalogException(
        'capability_artifact_invalid',
        '能力详情正文无法解析',
      );
    }
    return GDevelopCapabilityDetailResult(
      capability: capability.toDetailJson(
        extension: extension,
        artifact: artifactPayload,
        artifactCacheHit: artifact.cacheHit,
        catalogRevision: catalog.catalogRevision,
        engineVersion: catalog.engineVersion,
      ),
    );
  }

  Future<_GDevelopCapabilityCatalog> _loadCatalog() =>
      _catalog ??= _readCatalog();

  Future<_GDevelopCapabilityCatalog> _readCatalog() async {
    try {
      final source = await _indexLoader();
      final decoded = jsonDecode(source);
      if (decoded is! Map) throw const FormatException('扩展能力索引无效');
      return _GDevelopCapabilityCatalog.fromJson(
        Map<String, Object?>.from(decoded),
      );
    } on GDevelopCapabilityCatalogException {
      rethrow;
    } on Object {
      throw const GDevelopCapabilityCatalogException(
        'capability_catalog_unavailable',
        '本地 GDevelop 能力目录当前不可用',
        retryable: true,
      );
    }
  }

  static Map<String, Object?> _artifactPayload(Map<String, Object?> source) {
    const fields = [
      'id',
      'kind',
      'repository',
      'commit',
      'rootTreeSha',
      'path',
      'declaredBytes',
      'gitBlobOid',
      'sha256',
      'mediaType',
    ];
    return {
      for (final field in fields)
        if (source[field] != null) field: source[field],
    };
  }

  static void _validateSearch(GDevelopCapabilitySearchRequest request) {
    if (request.kind != null) _validateKind(request.kind!);
    if (request.page < 1) {
      throw const FormatException('GDevelop capability page 必须大于 0');
    }
    if (request.pageSize < 1 || request.pageSize > maximumPageSize) {
      throw FormatException(
        'GDevelop capability pageSize 必须为 1 到 $maximumPageSize',
      );
    }
  }

  static void _validateKind(String kind) {
    if (!supportedKinds.contains(kind)) {
      throw const FormatException(
        'GDevelop capability kind 仅支持 extension 或 behavior',
      );
    }
  }
}

class _GDevelopCapabilityCatalog {
  const _GDevelopCapabilityCatalog({
    required this.catalogRevision,
    required this.engineVersion,
    required this.capabilities,
    required this.byIdentity,
    required this.artifacts,
  });

  factory _GDevelopCapabilityCatalog.fromJson(Map<String, Object?> json) {
    final headers = _mapList(json['headers'], 'extension headers');
    final behavior = _map(json['behavior'], 'behavior index');
    final behaviorHeaders = _mapList(behavior['headers'], 'behavior headers');
    final artifactsSource = _map(json['artifacts'], 'artifacts');
    final artifacts = <String, Map<String, Object?>>{};
    for (final entry in artifactsSource.entries) {
      final artifact = _map(entry.value, 'artifact ${entry.key}');
      final id = _requiredString(artifact, 'id');
      if (id != entry.key || !id.startsWith('extension:')) {
        throw FormatException('扩展 artifact ID 无效：${entry.key}');
      }
      artifacts[id.substring('extension:'.length)] = artifact;
    }
    final capabilities = <_GDevelopCapability>[];
    for (final header in headers) {
      capabilities.add(_GDevelopCapability.extension(header));
    }
    for (final header in behaviorHeaders) {
      capabilities.add(_GDevelopCapability.behavior(header));
    }
    capabilities.sort((left, right) {
      final byName = left.canonicalName.toLowerCase().compareTo(
        right.canonicalName.toLowerCase(),
      );
      return byName != 0 ? byName : left.stableId.compareTo(right.stableId);
    });
    final byIdentity = <String, _GDevelopCapability>{};
    for (final capability in capabilities) {
      final identity = '${capability.type}:${capability.stableId}';
      if (byIdentity.containsKey(identity)) {
        throw FormatException('扩展能力 ID 重复：$identity');
      }
      if (!artifacts.containsKey(capability.ownerExtension)) {
        throw FormatException('扩展能力缺少 artifact：$identity');
      }
      byIdentity[identity] = capability;
    }
    final engine = _map(json['engine'], 'engine');
    return _GDevelopCapabilityCatalog(
      catalogRevision: _requiredString(json, 'catalogRevision'),
      engineVersion: _requiredString(engine, 'version'),
      capabilities: List.unmodifiable(capabilities),
      byIdentity: Map.unmodifiable(byIdentity),
      artifacts: Map.unmodifiable(artifacts),
    );
  }

  final String catalogRevision;
  final String engineVersion;
  final List<_GDevelopCapability> capabilities;
  final Map<String, _GDevelopCapability> byIdentity;
  final Map<String, Map<String, Object?>> artifacts;
}

class _GDevelopCapability {
  const _GDevelopCapability({
    required this.stableId,
    required this.type,
    required this.canonicalName,
    required this.localizedName,
    required this.canonicalSummary,
    required this.localizedSummary,
    required this.ownerExtension,
    required this.category,
    required this.tier,
    required this.tags,
    required this.header,
  });

  factory _GDevelopCapability.extension(Map<String, Object?> header) {
    final name = _requiredString(header, 'name');
    final canonicalName = _boundedText(
      _optionalString(header['fullName']) ?? name,
    );
    final canonicalSummary = _boundedText(
      _optionalString(header['shortDescription']) ??
          _optionalString(header['description']) ??
          '',
    );
    return _GDevelopCapability(
      stableId: name,
      type: 'extension',
      canonicalName: canonicalName,
      localizedName: _localizedText(header, 'fullName', canonicalName),
      canonicalSummary: canonicalSummary,
      localizedSummary: _localizedText(
        header,
        'shortDescription',
        canonicalSummary,
      ),
      ownerExtension: name,
      category: _boundedText(_optionalString(header['category']) ?? 'General'),
      tier: _optionalString(header['tier']) ?? 'community',
      tags: _stringList(header['tags']),
      header: header,
    );
  }

  factory _GDevelopCapability.behavior(Map<String, Object?> header) {
    final extensionName = _requiredString(header, 'extensionName');
    final name = _requiredString(header, 'name');
    final canonicalName = _boundedText(
      _optionalString(header['fullName']) ?? name,
    );
    final canonicalSummary = _boundedText(
      _optionalString(header['description']) ?? '',
    );
    return _GDevelopCapability(
      stableId: '$extensionName::$name',
      type: 'behavior',
      canonicalName: canonicalName,
      localizedName: _localizedText(header, 'fullName', canonicalName),
      canonicalSummary: canonicalSummary,
      localizedSummary: _localizedText(header, 'description', canonicalSummary),
      ownerExtension: extensionName,
      category: _boundedText(_optionalString(header['category']) ?? 'General'),
      tier: _optionalString(header['tier']) ?? 'community',
      tags: _stringList(header['tags']),
      header: header,
    );
  }

  final String stableId;
  final String type;
  final String canonicalName;
  final String localizedName;
  final String canonicalSummary;
  final String localizedSummary;
  final String ownerExtension;
  final String category;
  final String tier;
  final List<String> tags;
  final Map<String, Object?> header;

  String get searchText => [
    stableId,
    canonicalName,
    localizedName,
    canonicalSummary,
    localizedSummary,
    ownerExtension,
    category,
    ...tags,
  ].join('\n').toLowerCase();

  Map<String, Object?> toSummaryJson() => {
    'stableId': stableId,
    'type': type,
    'canonicalName': canonicalName,
    'localizedName': localizedName,
    'canonicalSummary': canonicalSummary,
    'localizedSummary': localizedSummary,
    'ownerExtension': ownerExtension,
    'category': category,
  };

  Map<String, Object?> toDetailJson({
    required Map<String, Object?> extension,
    required Map<String, Object?> artifact,
    required bool artifactCacheHit,
    required String catalogRevision,
    required String engineVersion,
  }) {
    final ownerDependencies = _mapListOrEmpty(extension['requiredExtensions'])
        .map((dependency) {
          final name = _optionalString(dependency['extensionName']) ?? '';
          final version = _optionalString(dependency['extensionVersion']);
          return <String, Object?>{
            'type': 'extension',
            'stableId': name,
            if (version != null && version.isNotEmpty)
              'minimumVersion': version,
          };
        })
        .where((dependency) => dependency['stableId'] != '')
        .toList(growable: true);
    Map<String, Object?>? behavior;
    if (type == 'behavior') {
      final behaviorName = stableId.substring(stableId.indexOf('::') + 2);
      for (final item in _mapListOrEmpty(extension['eventsBasedBehaviors'])) {
        if (item['name'] == behaviorName) {
          behavior = item;
          break;
        }
      }
      for (final requiredType in _stringList(
        header['allRequiredBehaviorTypes'],
      )) {
        ownerDependencies.add({'type': 'behavior', 'stableId': requiredType});
      }
    }
    final functionSource = type == 'behavior'
        ? (behavior == null ? null : behavior['eventsFunctions'])
        : extension['eventsFunctions'];
    final functions = _functionSummaries(functionSource);
    final objectType = type == 'behavior'
        ? (_optionalString(behavior == null ? null : behavior['objectType']) ??
              _optionalString(header['objectType']) ??
              '')
        : '';
    return {
      ...toSummaryJson(),
      'dependencies': ownerDependencies.toList(growable: false),
      'applicableObjectTypes': objectType.isEmpty
          ? const <String>[]
          : [_boundedText(objectType)],
      'conditions': functions.conditions,
      'actions': functions.actions,
      'expressions': functions.expressions,
      'artifact': artifact,
      'source': {
        'catalogRevision': catalogRevision,
        'engineVersion': engineVersion,
        'repository': artifact['repository'],
        'commit': artifact['commit'],
        'path': artifact['path'],
        'tier': tier,
        'cache': artifactCacheHit ? 'hit' : 'miss',
        'localizedFallback':
            localizedName == canonicalName &&
            localizedSummary == canonicalSummary,
      },
    };
  }
}

({
  List<Map<String, Object?>> conditions,
  List<Map<String, Object?>> actions,
  List<Map<String, Object?>> expressions,
})
_functionSummaries(Object? source) {
  final conditions = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  final expressions = <Map<String, Object?>>[];
  for (final function in _mapListOrEmpty(source)) {
    final type = _optionalString(function['functionType']) ?? '';
    final name = _optionalString(function['name']);
    if (name == null || name.isEmpty || function['private'] == true) continue;
    final summary = <String, Object?>{
      'name': _boundedText(name),
      'canonicalName': _boundedText(
        _optionalString(function['fullName']) ?? name,
      ),
      'summary': _boundedText(_optionalString(function['description']) ?? ''),
    };

    switch (type) {
      case 'Action':
      case 'ActionWithOperator':
        actions.add(summary);
        break;
      case 'Condition':
        conditions.add(summary);
        break;
      case 'Expression':
      case 'StringExpression':
        expressions.add(summary);
        break;
      case 'ExpressionAndCondition':
        conditions.add(summary);
        expressions.add(summary);
        break;
    }
  }
  return (
    conditions: List.unmodifiable(conditions),
    actions: List.unmodifiable(actions),
    expressions: List.unmodifiable(expressions),
  );
}

Map<String, Object?> _map(Object? value, String label) {
  if (value is! Map) throw FormatException('$label 必须是 JSON 对象');
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _mapList(Object? value, String label) {
  if (value is! List) throw FormatException('$label 必须是 JSON 数组');
  return value.map((item) => _map(item, label)).toList(growable: false);
}

List<Map<String, Object?>> _mapListOrEmpty(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((item) => Map<String, Object?>.from(item))
          .toList(growable: false)
    : const [];

String _requiredString(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value;
}

String? _optionalString(Object? value) => value is String ? value : null;

List<String> _stringList(Object? value) => value is List
    ? value.whereType<String>().map(_boundedText).toList(growable: false)
    : const [];

String _localizedText(
  Map<String, Object?> source,
  String key,
  String fallback,
) {
  final localized = source['localized'];
  if (localized is Map) {
    final value = localized[key];
    if (value is String && value.trim().isNotEmpty) return _boundedText(value);
  }
  return fallback;
}

String _boundedText(String source) {
  return source
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F]'), ' ')
      .trim();
}
