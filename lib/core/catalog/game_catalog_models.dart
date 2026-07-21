import '../../models/game_manifest.dart';

const defaultGameCatalogPort = 16668;
const defaultOnlineGamePageSize = 5;
const gameCatalogApiVersion = '1.1.0';

class GameCatalogShareConfig {
  const GameCatalogShareConfig({
    this.enabled = false,
    this.port = defaultGameCatalogPort,
    this.token = '',
  });

  final bool enabled;
  final int port;
  final String token;

  GameCatalogShareConfig copyWith({bool? enabled, int? port, String? token}) {
    return GameCatalogShareConfig(
      enabled: enabled ?? this.enabled,
      port: port ?? this.port,
      token: token ?? this.token,
    );
  }

  Map<String, Object?> toJson() => {
    'enabled': enabled,
    'port': port,
    'token': token,
  };

  factory GameCatalogShareConfig.fromJson(Map<String, Object?> json) {
    final port = json['port'];
    return GameCatalogShareConfig(
      enabled: json['enabled'] == true,
      port: port is int && port >= 1 && port <= 65535
          ? port
          : defaultGameCatalogPort,
      token: json['token'] is String ? json['token']! as String : '',
    );
  }
}

class OnlineGameSource {
  const OnlineGameSource({
    required this.id,
    required this.name,
    required this.host,
    this.token = '',
    this.enabled = true,
  });

  final String id;
  final String name;
  final Uri host;
  final String token;
  final bool enabled;

  OnlineGameSource copyWith({
    String? name,
    Uri? host,
    String? token,
    bool? enabled,
  }) {
    return OnlineGameSource(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      token: token ?? this.token,
      enabled: enabled ?? this.enabled,
    );
  }

  Uri get configurationUri => Uri(
    scheme: 'playmesh',
    host: 'catalog-source',
    queryParameters: {
      'host': host.toString(),
      if (token.isNotEmpty) 'token': token,
      'name': name,
    },
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host.toString(),
    'token': token,
    'enabled': enabled,
  };

  factory OnlineGameSource.fromJson(Map<String, Object?> json) {
    return OnlineGameSource(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      host: normalizeCatalogHost(_requiredString(json, 'host')),
      token: json['token'] is String ? json['token']! as String : '',
      enabled: json['enabled'] != false,
    );
  }

  static OnlineGameSource fromConfigurationUri(String raw, {String? id}) {
    final uri = Uri.parse(raw.trim());
    if (uri.scheme != 'playmesh' || uri.host != 'catalog-source') {
      throw const FormatException('二维码不是 Playmesh 在线游戏源');
    }
    final host = uri.queryParameters['host'];
    if (host == null || host.isEmpty) {
      throw const FormatException('在线游戏源缺少 host');
    }
    final normalized = normalizeCatalogHost(host);
    return OnlineGameSource(
      id: id ?? 'source-${DateTime.now().microsecondsSinceEpoch}',
      name: uri.queryParameters['name']?.trim().isNotEmpty == true
          ? uri.queryParameters['name']!.trim()
          : normalized.host,
      host: normalized,
      token: uri.queryParameters['token'] ?? '',
    );
  }
}

class OnlineCatalogGame {
  const OnlineCatalogGame({required this.manifest, required this.source});

  final GameManifest manifest;
  final OnlineGameSource source;
}

class OnlineCatalogSearchResult {
  const OnlineCatalogSearchResult({required this.games, required this.errors});

  final List<OnlineCatalogGame> games;
  final Map<String, String> errors;
}

Uri normalizeCatalogHost(String raw) {
  final value = raw.trim();
  final parsed = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty) {
    throw const FormatException('host 必须是有效的 HTTP/HTTPS 地址');
  }
  final path = parsed.path == '/' ? '' : parsed.path;
  if (path.isNotEmpty) {
    throw const FormatException('host 只能包含协议、主机和端口');
  }
  return parsed.replace(path: '', query: null, fragment: null);
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field 必须是非空字符串');
  }
  return value.trim();
}
