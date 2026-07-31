import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/game_summary.dart';
import '../game_package/game_package_share_files.dart';
import '../game_package/game_package_transfer_service.dart';
import '../version/semantic_version.dart';
import 'game_catalog_models.dart';

enum GameCatalogPublishStatus {
  waiting('waiting'),
  uploading('uploading'),
  enteredReview('entered_review'),
  unknownSource('unknown_source'),
  sourceNotEligible('source_not_eligible'),
  invalidUploadKey('invalid_upload_key'),
  rateLimited('rate_limited'),
  gameOwnershipConflict('game_ownership_conflict'),
  packageValidationFailed('package_validation_failed'),
  versionAlreadyExists('version_already_exists'),
  versionMustIncrease('version_must_increase'),
  packageTooLarge('package_too_large'),
  networkFailed('network_failed');

  const GameCatalogPublishStatus(this.wireValue);

  final String wireValue;

  bool get isSuccess => this == GameCatalogPublishStatus.enteredReview;
  bool get isTerminal =>
      this != GameCatalogPublishStatus.waiting &&
      this != GameCatalogPublishStatus.uploading;
}

class GameCatalogPublishSourceResult {
  const GameCatalogPublishSourceResult({
    required this.sourceId,
    required this.status,
    this.sourceName,
    this.detail,
    this.retryAfter,
    this.currentHighestVersion,
  });

  final String sourceId;
  final String? sourceName;
  final GameCatalogPublishStatus status;
  final String? detail;
  final String? retryAfter;
  final String? currentHighestVersion;

  bool get succeeded => status.isSuccess;
  bool get canRetry => status.isTerminal && !succeeded;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    if (sourceName != null) 'sourceName': sourceName,
    'status': status.wireValue,
    if (detail != null) 'detail': detail,
    if (retryAfter != null) 'retryAfter': retryAfter,
    if (currentHighestVersion != null)
      'currentHighestVersion': currentHighestVersion,
  };

  @override
  String toString() => jsonEncode(toJson());
}

class GameCatalogPublishBatchResult {
  const GameCatalogPublishBatchResult({
    required this.gameId,
    required this.version,
    required this.sources,
  });

  final String gameId;
  final String version;
  final List<GameCatalogPublishSourceResult> sources;

  List<String> get failedSourceIds => List.unmodifiable(
    sources.where((result) => result.canRetry).map((result) => result.sourceId),
  );

  Map<String, Object?> toJson() => {
    'gameId': gameId,
    'version': version,
    'sources': sources.map((result) => result.toJson()).toList(),
  };

  @override
  String toString() => jsonEncode(toJson());
}

typedef GameCatalogPublishEventCallback =
    void Function(GameCatalogPublishSourceResult event);
typedef GameCatalogPublishClientFactory = http.Client Function();

class GameCatalogPublisher {
  GameCatalogPublisher({
    required this._transfer,
    GamePackageShareFiles? shareFiles,
    GameCatalogPublishClientFactory? clientFactory,
  }) : _shareFiles = shareFiles ?? GamePackageShareFiles(),
       _clientFactory = clientFactory ?? http.Client.new;

  static const requestTimeout = Duration(seconds: 30);
  static const maxResponseBytes = 64 * 1024;

  final GamePackageTransferService _transfer;
  final GamePackageShareFiles _shareFiles;
  final GameCatalogPublishClientFactory _clientFactory;

  Future<GameCatalogPublishBatchResult> publish({
    required GameSummary game,
    required Iterable<String> sourceIds,
    required Iterable<OnlineGameSource> configuredSources,
    GameCatalogPublishEventCallback? onEvent,
  }) async {
    SemanticVersion.parse(game.version);
    final ids = <String>[];
    final seen = <String>{};
    for (final raw in sourceIds) {
      final id = raw.trim();
      if (id.isNotEmpty && seen.add(id)) ids.add(id);
    }
    final configured = {
      for (final source in configuredSources) source.id: source,
    };
    final results = <String, GameCatalogPublishSourceResult>{};
    final eligible = <OnlineGameSource>[];
    for (final id in ids) {
      final source = configured[id];
      if (source == null) {
        final result = GameCatalogPublishSourceResult(
          sourceId: id,
          status: GameCatalogPublishStatus.unknownSource,
        );
        results[id] = result;
        _emit(onEvent, result);
        continue;
      }
      if (!source.canUpload) {
        final result = GameCatalogPublishSourceResult(
          sourceId: id,
          sourceName: source.name,
          status: GameCatalogPublishStatus.sourceNotEligible,
        );
        results[id] = result;
        _emit(onEvent, result);
        continue;
      }
      final waiting = GameCatalogPublishSourceResult(
        sourceId: id,
        sourceName: source.name,
        status: GameCatalogPublishStatus.waiting,
      );
      results[id] = waiting;
      eligible.add(source);
      _emit(onEvent, waiting);
    }
    if (eligible.isEmpty) {
      return _batch(game, ids, results);
    }

    late final File package;
    try {
      package = await _createPackage(game);
    } on Object {
      for (final source in eligible) {
        final failed = GameCatalogPublishSourceResult(
          sourceId: source.id,
          sourceName: source.name,
          status: GameCatalogPublishStatus.packageValidationFailed,
        );
        results[source.id] = failed;
        _emit(onEvent, failed);
      }
      return _batch(game, ids, results);
    }

    try {
      final packageLength = await package.length();
      await Future.wait(
        eligible.map((source) async {
          final maximum = source.declaration!.userUpload.maxUploadBytes!;
          if (packageLength > maximum) {
            final tooLarge = GameCatalogPublishSourceResult(
              sourceId: source.id,
              sourceName: source.name,
              status: GameCatalogPublishStatus.packageTooLarge,
            );
            results[source.id] = tooLarge;
            _emit(onEvent, tooLarge);
            return;
          }
          final uploading = GameCatalogPublishSourceResult(
            sourceId: source.id,
            sourceName: source.name,
            status: GameCatalogPublishStatus.uploading,
          );
          results[source.id] = uploading;
          _emit(onEvent, uploading);
          final finalResult = await _upload(
            source: source,
            package: package,
            packageLength: packageLength,
            uploadFileName: gamePackageShareFileName(game),
          );
          results[source.id] = finalResult;
          _emit(onEvent, finalResult);
        }),
      );
      return _batch(game, ids, results);
    } finally {
      await _shareFiles.complete(package, deleteNow: true);
    }
  }

  Future<GameCatalogPublishBatchResult> retryFailures({
    required GameSummary game,
    required GameCatalogPublishBatchResult previous,
    required Iterable<OnlineGameSource> configuredSources,
    GameCatalogPublishEventCallback? onEvent,
  }) {
    if (previous.gameId != game.id || previous.version != game.version) {
      throw ArgumentError('重试结果与当前游戏包不匹配');
    }
    return publish(
      game: game,
      sourceIds: previous.failedSourceIds,
      configuredSources: configuredSources,
      onEvent: onEvent,
    );
  }

  Future<File> _createPackage(GameSummary game) async {
    final package = await _shareFiles.create(game);
    try {
      return await _transfer.exportPackage(game, package, validate: false);
    } on Object {
      await _shareFiles.complete(package, deleteNow: true);
      rethrow;
    }
  }

  Future<GameCatalogPublishSourceResult> _upload({
    required OnlineGameSource source,
    required File package,
    required int packageLength,
    required String uploadFileName,
  }) async {
    http.Client? client;
    try {
      final activeClient = _clientFactory();
      client = activeClient;
      return await _send(
        client: activeClient,
        source: source,
        package: package,
        packageLength: packageLength,
        uploadFileName: uploadFileName,
      ).timeout(requestTimeout);
    } on Object {
      return GameCatalogPublishSourceResult(
        sourceId: source.id,
        sourceName: source.name,
        status: GameCatalogPublishStatus.networkFailed,
      );
    } finally {
      client?.close();
    }
  }

  Future<GameCatalogPublishSourceResult> _send({
    required http.Client client,
    required OnlineGameSource source,
    required File package,
    required int packageLength,
    required String uploadFileName,
  }) async {
    final declaration = source.declaration!.userUpload;
    final uri = source.host.replace(path: declaration.path);
    final request = http.MultipartRequest('POST', uri);
    request.headers[HttpHeaders.authorizationHeader] =
        'UploadKey ${source.uploadKey}';
    request.files.add(
      http.MultipartFile(
        'package',
        package.openRead(),
        packageLength,
        filename: uploadFileName,
      ),
    );
    final response = await client.send(request);
    final payload = await _readResponseJson(response);
    return _mapResponse(source, response, payload);
  }

  GameCatalogPublishSourceResult _mapResponse(
    OnlineGameSource source,
    http.StreamedResponse response,
    Map<String, Object?> payload,
  ) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      return _result(source, GameCatalogPublishStatus.enteredReview);
    }
    if (status == HttpStatus.unauthorized || status == HttpStatus.forbidden) {
      return _result(source, GameCatalogPublishStatus.invalidUploadKey);
    }
    if (status == HttpStatus.tooManyRequests) {
      return _result(
        source,
        GameCatalogPublishStatus.rateLimited,
        retryAfter: _safeRetryAfter(response.headers['retry-after']),
      );
    }
    if (status == HttpStatus.requestEntityTooLarge) {
      return _result(source, GameCatalogPublishStatus.packageTooLarge);
    }
    final code = payload['code'];
    if (status == HttpStatus.conflict && code is String) {
      switch (code) {
        case 'game_ownership_conflict':
          return _result(
            source,
            GameCatalogPublishStatus.gameOwnershipConflict,
          );
        case 'version_already_exists':
          return _result(
            source,
            GameCatalogPublishStatus.versionAlreadyExists,
            currentHighestVersion: _safeVersion(
              payload['currentHighestVersion'],
            ),
          );
        case 'version_must_increase':
          return _result(
            source,
            GameCatalogPublishStatus.versionMustIncrease,
            currentHighestVersion: _safeVersion(
              payload['currentHighestVersion'],
            ),
          );
      }
    }
    if (status == HttpStatus.badRequest ||
        status == HttpStatus.unprocessableEntity ||
        (status >= 400 && status < 500)) {
      return _result(
        source,
        GameCatalogPublishStatus.packageValidationFailed,
        detail: _safeResponseDetail(source, payload['message']),
      );
    }
    return _result(source, GameCatalogPublishStatus.networkFailed);
  }

  Future<Map<String, Object?>> _readResponseJson(
    http.StreamedResponse response,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxResponseBytes) return const {};
      bytes.addAll(chunk);
    }
    if (bytes.isEmpty) return const {};
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map ? Map<String, Object?>.from(decoded) : const {};
    } on Object {
      return const {};
    }
  }

  GameCatalogPublishSourceResult _result(
    OnlineGameSource source,
    GameCatalogPublishStatus status, {
    String? detail,
    String? retryAfter,
    String? currentHighestVersion,
  }) => GameCatalogPublishSourceResult(
    sourceId: source.id,
    sourceName: source.name,
    status: status,
    detail: detail,
    retryAfter: retryAfter,
    currentHighestVersion: currentHighestVersion,
  );

  GameCatalogPublishBatchResult _batch(
    GameSummary game,
    List<String> ids,
    Map<String, GameCatalogPublishSourceResult> results,
  ) => GameCatalogPublishBatchResult(
    gameId: game.id,
    version: game.version,
    sources: List.unmodifiable([for (final id in ids) ?results[id]]),
  );

  void _emit(
    GameCatalogPublishEventCallback? callback,
    GameCatalogPublishSourceResult result,
  ) {
    if (callback == null) return;
    try {
      callback(result);
    } on Object {
      // 观察者不能中断上传或暴露其凭据。
    }
  }

  String? _safeVersion(Object? value) {
    if (value is! String || SemanticVersion.tryParse(value) == null) {
      return null;
    }
    return value;
  }

  String? _safeResponseDetail(OnlineGameSource source, Object? value) {
    if (value is! String) return null;
    var normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty) return null;
    for (final secret in [source.uploadKey, source.token]) {
      if (secret.isNotEmpty) {
        normalized = normalized.replaceAll(secret, '[redacted]');
      }
    }
    const maximumLength = 2048;
    if (normalized.length > maximumLength) {
      normalized = '${normalized.substring(0, maximumLength)}…';
    }
    return normalized;
  }

  String? _safeRetryAfter(String? value) {
    final normalized = value?.trim();
    if (normalized == null ||
        normalized.isEmpty ||
        normalized.length > 128 ||
        !RegExp(r'^[A-Za-z0-9,: -]+$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }
}
