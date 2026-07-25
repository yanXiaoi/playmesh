import '../../models/game_manifest.dart';

const defaultGameCatalogPort = 16668;
const defaultOnlineGamePageSize = 5;
const gameCatalogApiVersion = '1.4.0';

class GameRelayDeclaration {
  const GameRelayDeclaration({
    required this.protocolVersion,
    required this.transport,
    required this.publicBaseUrl,
    required this.hostPath,
    required this.clientPath,
    required this.maxConnectionsPerTunnel,
  });

  factory GameRelayDeclaration.fromJson(Map<String, Object?> json) {
    return GameRelayDeclaration(
      protocolVersion: _requiredString(json, 'protocolVersion'),
      transport: _requiredString(json, 'transport'),
      publicBaseUrl: _requiredHttpOrigin(json, 'publicBaseUrl'),
      hostPath: _requiredAbsolutePath(json, 'hostPath'),
      clientPath: _requiredAbsolutePath(json, 'clientPath'),
      maxConnectionsPerTunnel: _requiredPositiveInt(
        json,
        'maxConnectionsPerTunnel',
      ),
    );
  }

  final String protocolVersion;
  final String transport;
  final Uri publicBaseUrl;
  final String hostPath;
  final String clientPath;
  final int maxConnectionsPerTunnel;

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'transport': transport,
    'publicBaseUrl': publicBaseUrl.toString(),
    'hostPath': hostPath,
    'clientPath': clientPath,
    'maxConnectionsPerTunnel': maxConnectionsPerTunnel,
  };
}

class GameCatalogDeclaration {
  const GameCatalogDeclaration({
    required this.catalogApiVersion,
    required this.supportsGameRelay,
    this.name,
    this.author,
    this.homepage,
    this.relay,
  });

  factory GameCatalogDeclaration.fromJson(Map<String, Object?> json) {
    final supportsGameRelay = json['supportsGameRelay'] == true;
    final relayRaw = json['relay'];
    final relay = relayRaw is Map
        ? GameRelayDeclaration.fromJson(Map<String, Object?>.from(relayRaw))
        : null;
    if (supportsGameRelay && relay == null) {
      throw const FormatException('支持游戏中转的游戏源必须声明 relay');
    }
    if (!supportsGameRelay && relay != null) {
      throw const FormatException('不支持游戏中转的游戏源不能声明 relay');
    }
    return GameCatalogDeclaration(
      catalogApiVersion: _requiredString(json, 'catalogApiVersion'),
      name: _optionalString(json, 'name'),
      author: _optionalString(json, 'author'),
      homepage: _optionalHttpUri(json, 'homepage'),
      supportsGameRelay: supportsGameRelay,
      relay: relay,
    );
  }

  final String catalogApiVersion;
  final String? name;
  final String? author;
  final Uri? homepage;
  final bool supportsGameRelay;
  final GameRelayDeclaration? relay;

  String displayNameFor(Uri host) => name ?? formatCatalogHost(host);

  Map<String, Object?> toJson() => {
    'catalogApiVersion': catalogApiVersion,
    if (name != null) 'name': name,
    if (author != null) 'author': author,
    if (homepage != null) 'homepage': homepage.toString(),
    'supportsGameRelay': supportsGameRelay,
    if (relay != null) 'relay': relay!.toJson(),
  };
}

class OnlineGameSourceProbe {
  const OnlineGameSourceProbe({
    required this.source,
    required this.elapsed,
    this.declaration,
    this.error,
  });

  final OnlineGameSource source;
  final Duration elapsed;
  final GameCatalogDeclaration? declaration;
  final String? error;

  bool get supportsGameRelay =>
      error == null && declaration?.supportsGameRelay == true;
}

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

String formatCatalogHost(Uri host) {
  final defaultPort =
      (host.scheme == 'http' && (!host.hasPort || host.port == 80)) ||
      (host.scheme == 'https' && (!host.hasPort || host.port == 443));
  return defaultPort ? host.host : '${host.host}:${host.port}';
}

String _requiredAbsolutePath(Map<String, Object?> json, String field) {
  final value = _requiredString(json, field);
  if (!value.startsWith('/') || value.startsWith('//')) {
    throw FormatException('$field 必须是绝对路径');
  }
  return value;
}

String? _optionalString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field 必须是非空字符串或省略');
  }
  return value.trim();
}

Uri? _optionalHttpUri(Map<String, Object?> json, String field) {
  final value = _optionalString(json, field);
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty) {
    throw FormatException('$field 必须是有效的 HTTP/HTTPS 地址');
  }
  return uri;
}

Uri _requiredHttpOrigin(Map<String, Object?> json, String field) {
  final value = _requiredString(json, field);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.query.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw FormatException('$field 必须是只包含协议、主机和端口的 HTTP/HTTPS 地址');
  }
  return uri.replace(path: '', query: null, fragment: null);
}

String _requiredString(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$field 必须是非空字符串');
  }
  return value.trim();
}

int _requiredPositiveInt(Map<String, Object?> json, String field) {
  final value = json[field];
  if (value is! int || value < 1) {
    throw FormatException('$field 必须是正整数');
  }
  return value;
}
