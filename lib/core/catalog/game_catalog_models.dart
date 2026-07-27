import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../game_package/game_library_local_metadata.dart';
import '../version/semantic_version.dart';

const defaultGameCatalogPort = 16668;
const defaultOnlineGamePageSize = 5;
const gameCatalogApiVersion = '2.0.0';

class GameRelayDeclaration {
  const GameRelayDeclaration({
    required this.protocolVersion,
    required this.transport,
    required this.publicBaseUrl,
    required this.hostPath,
    required this.clientPath,
    required this.maxConnectionsPerTunnel,
  });

  factory GameRelayDeclaration.fromJson(Map<String, Object?> json) =>
      GameRelayDeclaration(
        protocolVersion: _strictVersion(json, 'protocolVersion'),
        transport: _requiredString(json, 'transport'),
        publicBaseUrl: _requiredHttpOrigin(json, 'publicBaseUrl'),
        hostPath: _requiredAbsolutePath(json, 'hostPath'),
        clientPath: _requiredAbsolutePath(json, 'clientPath'),
        maxConnectionsPerTunnel: _requiredPositiveInt(
          json,
          'maxConnectionsPerTunnel',
        ),
      );

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

class GameCatalogUserUploadDeclaration {
  const GameCatalogUserUploadDeclaration({
    required this.supported,
    this.protocolVersion,
    this.path,
    this.maxUploadBytes,
  });

  factory GameCatalogUserUploadDeclaration.fromJson(Map<String, Object?> json) {
    final supported = json['supported'] == true;
    final protocolVersion = _optionalString(json, 'protocolVersion');
    final path = _optionalString(json, 'path');
    final maxUploadBytes = json['maxUploadBytes'];
    if (supported) {
      if (protocolVersion == null ||
          path == null ||
          maxUploadBytes is! int ||
          maxUploadBytes < 1) {
        throw const FormatException('支持用户上传时必须声明协议版本、路径和大小限制');
      }
      SemanticVersion.parse(protocolVersion);
      if (!path.startsWith('/') || path.startsWith('//')) {
        throw const FormatException('用户上传 path 必须是绝对路径');
      }
    } else if (json.containsKey('protocolVersion') ||
        json.containsKey('path') ||
        json.containsKey('maxUploadBytes')) {
      throw const FormatException('不支持用户上传时不得声明上传协议字段');
    }
    return GameCatalogUserUploadDeclaration(
      supported: supported,
      protocolVersion: protocolVersion,
      path: path,
      maxUploadBytes: maxUploadBytes as int?,
    );
  }

  final bool supported;
  final String? protocolVersion;
  final String? path;
  final int? maxUploadBytes;

  Map<String, Object?> toJson() => {
    'supported': supported,
    if (protocolVersion != null) 'protocolVersion': protocolVersion,
    if (path != null) 'path': path,
    if (maxUploadBytes != null) 'maxUploadBytes': maxUploadBytes,
  };
}

class GameCatalogDeclaration {
  const GameCatalogDeclaration({
    required this.catalogApiVersion,
    required this.supportsGameRelay,
    this.userUpload = const GameCatalogUserUploadDeclaration(supported: false),
    this.name,
    this.author,
    this.homepage,
    this.relay,
  });

  factory GameCatalogDeclaration.fromJson(Map<String, Object?> json) {
    final apiVersion = _strictVersion(json, 'catalogApiVersion');
    if (apiVersion != gameCatalogApiVersion) {
      throw FormatException(
        '只支持 Catalog $gameCatalogApiVersion，源返回 $apiVersion',
      );
    }
    final supportsGameRelay = json['supportsGameRelay'] == true;
    final relayRaw = json['relay'];
    final relay = relayRaw is Map
        ? GameRelayDeclaration.fromJson(Map<String, Object?>.from(relayRaw))
        : null;
    if (supportsGameRelay != (relay != null)) {
      throw const FormatException('supportsGameRelay 与 relay 声明不一致');
    }
    final uploadRaw = json['userUpload'];
    if (uploadRaw is! Map) {
      throw const FormatException('Catalog 2.0 必须声明 userUpload');
    }
    return GameCatalogDeclaration(
      catalogApiVersion: apiVersion,
      name: _optionalString(json, 'name'),
      author: _optionalString(json, 'author'),
      homepage: _optionalHttpUri(json, 'homepage'),
      supportsGameRelay: supportsGameRelay,
      relay: relay,
      userUpload: GameCatalogUserUploadDeclaration.fromJson(
        Map<String, Object?>.from(uploadRaw),
      ),
    );
  }

  final String catalogApiVersion;
  final String? name;
  final String? author;
  final Uri? homepage;
  final bool supportsGameRelay;
  final GameRelayDeclaration? relay;
  final GameCatalogUserUploadDeclaration userUpload;

  String displayNameFor(Uri host) => name ?? formatCatalogHost(host);

  Map<String, Object?> toJson() => {
    'catalogApiVersion': catalogApiVersion,
    if (name != null) 'name': name,
    if (author != null) 'author': author,
    if (homepage != null) 'homepage': homepage.toString(),
    'supportsGameRelay': supportsGameRelay,
    if (relay != null) 'relay': relay!.toJson(),
    'userUpload': userUpload.toJson(),
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

  GameCatalogShareConfig copyWith({bool? enabled, int? port, String? token}) =>
      GameCatalogShareConfig(
        enabled: enabled ?? this.enabled,
        port: port ?? this.port,
        token: token ?? this.token,
      );

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
    this.uploadKey = '',
    this.enabled = true,
    this.showOnHome = true,
    this.declaration,
    this.lastValidatedAt,
    this.lastError,
  });

  final String id;
  final String name;
  final Uri host;
  final String token;
  final String uploadKey;
  final bool enabled;
  final bool showOnHome;
  final GameCatalogDeclaration? declaration;
  final DateTime? lastValidatedAt;
  final String? lastError;

  bool get canUpload =>
      enabled &&
      declaration?.userUpload.supported == true &&
      uploadKey.trim().isNotEmpty;

  OnlineGameSource copyWith({
    String? name,
    Uri? host,
    String? token,
    String? uploadKey,
    bool? enabled,
    bool? showOnHome,
    GameCatalogDeclaration? declaration,
    DateTime? lastValidatedAt,
    String? lastError,
    bool clearLastError = false,
  }) => OnlineGameSource(
    id: id,
    name: name ?? this.name,
    host: host ?? this.host,
    token: token ?? this.token,
    uploadKey: uploadKey ?? this.uploadKey,
    enabled: enabled ?? this.enabled,
    showOnHome: showOnHome ?? this.showOnHome,
    declaration: declaration ?? this.declaration,
    lastValidatedAt: lastValidatedAt ?? this.lastValidatedAt,
    lastError: clearLastError ? null : lastError ?? this.lastError,
  );

  Uri get publicUrl {
    final origin = catalogOrigin(host);
    return token.isEmpty
        ? origin
        : origin.replace(queryParameters: {'token': token});
  }

  Uri get configurationUri => publicUrl;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'host': host.toString(),
    'token': token,
    'uploadKey': uploadKey,
    'enabled': enabled,
    'showOnHome': showOnHome,
    if (declaration != null)
      'declarationCache': {
        ...declaration!.toJson(),
        'supportsUserUpload': declaration!.userUpload.supported,
        if (lastValidatedAt != null)
          'verifiedAt': lastValidatedAt!.millisecondsSinceEpoch,
      },
    if (lastError != null) 'lastError': lastError,
  };

  factory OnlineGameSource.fromJson(Map<String, Object?> json) {
    final declarationRaw = json['declarationCache'];
    final declarationJson = declarationRaw is Map
        ? Map<String, Object?>.from(declarationRaw)
        : null;
    final validatedAt = declarationJson?.remove('verifiedAt');
    declarationJson?.remove('supportsUserUpload');
    return OnlineGameSource(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      host: normalizeCatalogHost(_requiredString(json, 'host')),
      token: json['token'] is String ? json['token']! as String : '',
      uploadKey: json['uploadKey'] is String
          ? json['uploadKey']! as String
          : '',
      enabled: json['enabled'] != false,
      showOnHome: json['showOnHome'] != false,
      declaration: declarationJson != null
          ? GameCatalogDeclaration.fromJson(declarationJson)
          : null,
      lastValidatedAt: validatedAt is int && validatedAt >= 0
          ? DateTime.fromMillisecondsSinceEpoch(validatedAt, isUtc: true)
          : null,
      lastError: json['lastError'] is String
          ? json['lastError']! as String
          : null,
    );
  }

  static OnlineGameSource fromPublicUrl(String raw, {String? id}) {
    final parsed = parseCatalogPublicUrl(raw);
    return OnlineGameSource(
      id: id ?? 'source-${DateTime.now().microsecondsSinceEpoch}',
      name: formatCatalogHost(parsed.host),
      host: parsed.host,
      token: parsed.token,
    );
  }

  static OnlineGameSource fromConfigurationUri(String raw, {String? id}) =>
      fromPublicUrl(raw, id: id);
}

class ParsedCatalogPublicUrl {
  const ParsedCatalogPublicUrl({required this.host, required this.token});

  final Uri host;
  final String token;
}

ParsedCatalogPublicUrl parseCatalogPublicUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('游戏源链接必须是有效的 HTTP/HTTPS publicURL');
  }
  if (uri.queryParametersAll.keys.any((key) => key != 'token') ||
      (uri.queryParametersAll['token']?.length ?? 0) > 1) {
    throw const FormatException('游戏源链接只允许一个可选 token 参数');
  }
  return ParsedCatalogPublicUrl(
    host: catalogOrigin(uri),
    token: uri.queryParameters['token'] ?? '',
  );
}

class CatalogGameOffer {
  const CatalogGameOffer({
    required this.manifest,
    required this.source,
    this.icon,
    this.catalogAuthor,
  });

  final GameManifest manifest;
  final OnlineGameSource source;
  final Uri? icon;
  final String? catalogAuthor;

  String get publisher =>
      (catalogAuthor == null ? manifest.author : catalogAuthor!).trim();
  String get publisherKey => publisher.isEmpty ? source.id : publisher;
  String get downloadKey => '${source.id}:${manifest.id}:${manifest.version}';
}

class OnlineCatalogGame extends CatalogGameOffer {
  const OnlineCatalogGame({
    required super.manifest,
    required super.source,
    super.icon,
    super.catalogAuthor,
  });
}

class OnlineCatalogSearchResult {
  const OnlineCatalogSearchResult({
    required this.games,
    required this.errors,
    required this.sections,
  });

  final List<OnlineCatalogGame> games;
  final Map<String, String> errors;
  final List<SourceSectionResult> sections;
}

class SourceSectionResult {
  const SourceSectionResult({
    required this.source,
    required this.offers,
    required this.total,
    required this.page,
    this.nextCursor,
    this.error,
    this.exhausted = false,
  });

  final OnlineGameSource source;
  final List<OnlineCatalogGame> offers;
  final int total;
  final int page;
  final String? nextCursor;
  final String? error;
  final bool exhausted;

  bool get hasMore =>
      !exhausted &&
      (offers.length < total || (nextCursor?.trim().isNotEmpty ?? false));
}

class HomeCatalogResult {
  const HomeCatalogResult(this.sections);
  final List<SourceSectionResult> sections;
}

class AggregatedVersion {
  const AggregatedVersion({required this.version, required this.offers});
  final String version;
  final List<OnlineCatalogGame> offers;
}

class AggregatedGameResult {
  const AggregatedGameResult({
    required this.gameId,
    required this.publisher,
    required this.publisherKey,
    required this.groupKey,
    required this.heat,
    required this.lastOpenedAt,
    required this.representative,
    required this.versions,
  });

  final String gameId;
  final String publisher;
  final String publisherKey;
  final String groupKey;
  final int heat;
  final DateTime? lastOpenedAt;
  final OnlineCatalogGame representative;
  final List<AggregatedVersion> versions;
}

List<AggregatedGameResult> aggregateCatalogOffers(
  Iterable<OnlineCatalogGame> offers, {
  Map<String, GameLibraryUsageStats> usage = const {},
  List<String> sourceOrder = const [],
}) {
  final sourceRanks = {
    for (var index = 0; index < sourceOrder.length; index += 1)
      sourceOrder[index]: index,
  };
  final grouped = <String, List<OnlineCatalogGame>>{};
  for (final offer in offers) {
    SemanticVersion.parse(offer.manifest.version);
    final publisher = offer.publisher;
    final publisherKey = publisher.isEmpty ? offer.source.id : publisher;
    final key = '${offer.manifest.id}\n$publisherKey';
    grouped.putIfAbsent(key, () => []).add(offer);
  }
  final results = <AggregatedGameResult>[];
  for (final entry in grouped.entries) {
    final items = entry.value;
    items.sort((left, right) {
      final byVersion = SemanticVersion.parse(
        right.manifest.version,
      ).compareTo(SemanticVersion.parse(left.manifest.version));
      if (byVersion != 0) return byVersion;
      return (sourceRanks[left.source.id] ?? 1 << 30).compareTo(
        sourceRanks[right.source.id] ?? 1 << 30,
      );
    });
    final representative = items.first;
    final versionGroups = <String, List<OnlineCatalogGame>>{};
    for (final item in items) {
      versionGroups.putIfAbsent(item.manifest.version, () => []).add(item);
    }
    final versions =
        versionGroups.entries
            .map(
              (item) => AggregatedVersion(
                version: item.key,
                offers: List.unmodifiable(item.value),
              ),
            )
            .toList()
          ..sort(
            (left, right) => SemanticVersion.parse(
              right.version,
            ).compareTo(SemanticVersion.parse(left.version)),
          );
    final stats = usage[representative.manifest.id];
    results.add(
      AggregatedGameResult(
        gameId: representative.manifest.id,
        publisher: representative.publisher,
        publisherKey: representative.publisherKey,
        groupKey: entry.key,
        heat: stats?.launchCount ?? 0,
        lastOpenedAt: stats?.lastOpenedAt,
        representative: representative,
        versions: List.unmodifiable(versions),
      ),
    );
  }
  results.sort(_compareAggregated);
  return List.unmodifiable(results);
}

int _compareAggregated(AggregatedGameResult left, AggregatedGameResult right) {
  var result = right.heat.compareTo(left.heat);
  if (result != 0) return result;
  final leftOpened = left.lastOpenedAt;
  final rightOpened = right.lastOpenedAt;
  if (leftOpened != null || rightOpened != null) {
    if (leftOpened == null) return 1;
    if (rightOpened == null) return -1;
    result = rightOpened.compareTo(leftOpened);
    if (result != 0) return result;
  }
  result = SemanticVersion.parse(
    right.representative.manifest.version,
  ).compareTo(SemanticVersion.parse(left.representative.manifest.version));
  if (result != 0) return result;
  result = left.representative.manifest.name.compareTo(
    right.representative.manifest.name,
  );
  return result != 0 ? result : left.groupKey.compareTo(right.groupKey);
}

class GameUpdateSource {
  const GameUpdateSource({
    required this.sourceId,
    required this.localSourceName,
    required this.host,
    required this.offer,
  });
  final String sourceId;
  final String localSourceName;
  final Uri host;
  final OnlineCatalogGame offer;
}

class GameUpdateVersion {
  const GameUpdateVersion({required this.targetVersion, required this.sources});
  final String targetVersion;
  final List<GameUpdateSource> sources;
}

class GameUpdateCandidate {
  const GameUpdateCandidate({
    required this.gameId,
    required this.publisher,
    required this.installedVersion,
    required this.versions,
  });
  final String gameId;
  final String publisher;
  final String installedVersion;
  final List<GameUpdateVersion> versions;
}

class GameUpdateSourceError {
  const GameUpdateSourceError({
    required this.sourceId,
    required this.localSourceName,
    required this.message,
  });

  final String sourceId;
  final String localSourceName;

  /// Raw source/client diagnostic. This value is never an i18n key.
  final String message;
}

class GameUpdateCheckResult {
  const GameUpdateCheckResult({
    required this.candidates,
    required this.sourceErrors,
    required this.checkedAt,
  });

  final List<GameUpdateCandidate> candidates;
  final List<GameUpdateSourceError> sourceErrors;
  final DateTime checkedAt;
}

List<GameUpdateCandidate> findGameUpdates({
  required Iterable<GameSummary> installedGames,
  required Iterable<OnlineCatalogGame> offers,
  List<String> sourceOrder = const [],
}) {
  final ranks = {
    for (var index = 0; index < sourceOrder.length; index += 1)
      sourceOrder[index]: index,
  };
  final results = <GameUpdateCandidate>[];
  for (final installed in installedGames) {
    final publisher = installed.author.trim();
    final current = SemanticVersion.tryParse(installed.version);
    if (publisher.isEmpty || current == null) continue;
    final matches = offers.where((offer) {
      final version = SemanticVersion.tryParse(offer.manifest.version);
      return offer.manifest.id == installed.id &&
          offer.publisher == publisher &&
          version != null &&
          version.compareTo(current) > 0;
    });
    final groups = <String, List<GameUpdateSource>>{};
    for (final offer in matches) {
      groups
          .putIfAbsent(offer.manifest.version, () => [])
          .add(
            GameUpdateSource(
              sourceId: offer.source.id,
              localSourceName: offer.source.name,
              host: offer.source.host,
              offer: offer,
            ),
          );
    }
    if (groups.isEmpty) continue;
    final versions =
        groups.entries.map((entry) {
          entry.value.sort(
            (left, right) => (ranks[left.sourceId] ?? 1 << 30).compareTo(
              ranks[right.sourceId] ?? 1 << 30,
            ),
          );
          return GameUpdateVersion(
            targetVersion: entry.key,
            sources: List.unmodifiable(entry.value),
          );
        }).toList()..sort(
          (left, right) => SemanticVersion.parse(
            right.targetVersion,
          ).compareTo(SemanticVersion.parse(left.targetVersion)),
        );
    results.add(
      GameUpdateCandidate(
        gameId: installed.id,
        publisher: publisher,
        installedVersion: installed.version,
        versions: List.unmodifiable(versions),
      ),
    );
  }
  return List.unmodifiable(results);
}

Uri normalizeCatalogHost(String raw) {
  final value = raw.trim();
  final parsed = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (parsed == null ||
      !{'http', 'https'}.contains(parsed.scheme) ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty ||
      (parsed.path.isNotEmpty && parsed.path != '/')) {
    throw const FormatException('host 必须是 HTTP/HTTPS origin');
  }
  return catalogOrigin(parsed);
}

Uri catalogOrigin(Uri uri) => Uri.parse('${uri.scheme}://${uri.authority}');

String formatCatalogHost(Uri host) {
  final defaultPort =
      (host.scheme == 'http' && (!host.hasPort || host.port == 80)) ||
      (host.scheme == 'https' && (!host.hasPort || host.port == 443));
  return defaultPort ? host.host : '${host.host}:${host.port}';
}

bool isSameCatalogOrigin(Uri host, Uri candidate) =>
    host.scheme == candidate.scheme &&
    host.host == candidate.host &&
    host.port == candidate.port;

String _strictVersion(Map<String, Object?> json, String field) {
  final value = _requiredString(json, field);
  SemanticVersion.parse(value);
  return value;
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
  return normalizeCatalogHost(value);
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
