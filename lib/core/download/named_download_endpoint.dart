import 'dart:convert';

class NamedDownloadEndpoint {
  const NamedDownloadEndpoint({required this.name, required this.url});

  final String name;
  final Uri url;
}

class NamedDownloadEndpointList {
  const NamedDownloadEndpointList(this.endpoints);

  static const int maxEndpoints = 16;

  final List<NamedDownloadEndpoint> endpoints;

  bool get isEmpty => endpoints.isEmpty;
  bool get isNotEmpty => endpoints.isNotEmpty;

  factory NamedDownloadEndpointList.parse(
    String source, {
    bool allowEmpty = true,
    String field = 'endpoints',
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on Object catch (error) {
      throw FormatException('$field is not valid JSON: $error');
    }
    return NamedDownloadEndpointList.fromJson(
      decoded,
      allowEmpty: allowEmpty,
      field: field,
    );
  }

  factory NamedDownloadEndpointList.fromJson(
    Object? source, {
    bool allowEmpty = true,
    String field = 'endpoints',
  }) {
    if (source is! List) throw FormatException('$field must be an array');
    if (!allowEmpty && source.isEmpty) {
      throw FormatException('$field must contain at least one endpoint');
    }
    if (source.length > maxEndpoints) {
      throw FormatException('$field exceeds the endpoint count limit');
    }

    final endpoints = <NamedDownloadEndpoint>[];
    final normalizedNames = <String>{};
    final normalizedUrls = <String>{};
    for (var index = 0; index < source.length; index += 1) {
      final item = strictJsonObject(source[index], '$field[$index]', const {
        'name',
        'url',
      });
      final name = strictJsonString(item['name'], '$field[$index].name');
      if (name.length > 80 ||
          name.contains(RegExp(r'[\u0000-\u001f\u007f]')) ||
          !normalizedNames.add(name.toLowerCase())) {
        throw FormatException('$field[$index].name is unsafe or duplicated');
      }
      final url = strictCanonicalHttpsUri(item['url'], '$field[$index].url');
      if (!normalizedUrls.add(url.toString())) {
        throw FormatException('$field[$index].url is duplicated');
      }
      endpoints.add(NamedDownloadEndpoint(name: name, url: url));
    }
    return NamedDownloadEndpointList(List.unmodifiable(endpoints));
  }
}

Map<String, Object?> strictJsonObject(
  Object? source,
  String field,
  Set<String> expectedKeys,
) {
  if (source is! Map) throw FormatException('$field must be an object');
  final result = <String, Object?>{};
  for (final entry in source.entries) {
    if (entry.key is! String) {
      throw FormatException('$field contains a non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  final actualKeys = result.keys.toSet();
  if (actualKeys.length != expectedKeys.length ||
      !actualKeys.containsAll(expectedKeys)) {
    final missing = expectedKeys.difference(actualKeys).toList()..sort();
    final unknown = actualKeys.difference(expectedKeys).toList()..sort();
    throw FormatException(
      '$field fields differ; missing=${missing.join(',')} '
      'unknown=${unknown.join(',')}',
    );
  }
  return result;
}

String strictJsonString(Object? source, String field) {
  if (source is! String || source.trim().isEmpty || source != source.trim()) {
    throw FormatException('$field must be a non-empty trimmed string');
  }
  return source;
}

Uri strictCanonicalHttpsUri(Object? source, String field) {
  final value = strictJsonString(source, field);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.toString() != value) {
    throw FormatException(
      '$field must be a canonical HTTPS URL without credentials or fragment',
    );
  }
  return uri;
}
