import 'dart:convert';

import 'named_download_endpoint.dart';

const appResourceSourceCatalogAssetPath = 'assets/app/App.json';

/// App 内置的资源清单渠道目录。
///
/// 目录不维护资源键白名单。消费者只投影自己请求的资源键，因此后续新增资源不会要求
/// 已有消费者同步升级，也不会因为某个渠道缺少无关资源而淘汰该渠道。
final class AppResourceSourceCatalog {
  AppResourceSourceCatalog._(this._channels);

  final List<Object?> _channels;

  factory AppResourceSourceCatalog.parse(String source) {
    Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on Object catch (error) {
      throw FormatException(
        'App resource source catalog is not valid JSON: $error',
      );
    }
    if (decoded is! List) {
      throw const FormatException(
        'App resource source catalog must be an array',
      );
    }
    return AppResourceSourceCatalog._(List<Object?>.unmodifiable(decoded));
  }

  NamedDownloadEndpointList endpointsFor(
    String resource, {
    bool allowEmpty = true,
    String? field,
  }) {
    final projected = <Object?>[];
    for (final channel in _channels) {
      if (channel is! Map || !channel.containsKey(resource)) continue;
      projected.add(<String, Object?>{
        'name': channel['name'],
        'url': channel[resource],
      });
    }
    return NamedDownloadEndpointList.fromJson(
      projected,
      allowEmpty: allowEmpty,
      field: field ?? '$resource resource sources',
    );
  }
}
