import 'app_media_adapter.dart';

/// 终端媒体协议的唯一注册表。公共运行时只通过本类发现和选择适配器。
final class AppMediaAdapterRegistry {
  AppMediaAdapterRegistry(Iterable<AppMediaAdapter> adapters)
    : adapters = List<AppMediaAdapter>.unmodifiable(adapters) {
    final protocols = <String>{};
    for (final adapter in this.adapters) {
      if (adapter.protocol.isEmpty) {
        throw ArgumentError('媒体适配器协议不能为空');
      }
      if (!protocols.add(adapter.protocol)) {
        throw ArgumentError('媒体适配器协议不能重复：${adapter.protocol}');
      }
    }
  }

  final List<AppMediaAdapter> adapters;

  List<String> get availableProtocols => List<String>.unmodifiable(
    adapters
        .where((adapter) => adapter.isAvailable)
        .map((adapter) => adapter.protocol),
  );

  AppMediaAdapter? select({required String producer, required String kind}) {
    final matches =
        adapters
            .where(
              (adapter) =>
                  adapter.isAvailable &&
                  adapter.supportsProducer(producer, kind),
            )
            .toList(growable: false)
          ..sort((left, right) => right.priority.compareTo(left.priority));
    return matches.isEmpty ? null : matches.first;
  }

  AppMediaAdapter? adapter(String protocol) {
    for (final adapter in adapters) {
      if (adapter.protocol == protocol) return adapter;
    }
    return null;
  }
}
