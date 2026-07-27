import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../game_package/game_library_repository.dart';
import '../game_package/game_library_local_metadata.dart';
import '../game_package/game_package_icon.dart';
import '../game_package/game_package_transfer_service.dart';
import '../network/lan_endpoint_resolver.dart';
import '../version/semantic_version.dart';
import 'game_catalog_models.dart';
import 'game_catalog_preferences.dart';
import 'game_catalog_publisher.dart';
import 'game_catalog_server.dart';

enum GameDownloadStatus { queued, downloading, completed, stopped, failed }

class GameDownloadTask {
  GameDownloadTask({required this.id, required this.game});

  final String id;
  final OnlineCatalogGame game;
  GameDownloadStatus status = GameDownloadStatus.queued;
  double? progress;
  String? error;
  bool cancelled = false;
  bool removeWhenDone = false;
  http.Client? client;
}

class GameDownloadQueue extends ChangeNotifier {
  GameDownloadQueue(this._transfer, this._onImported, {required this._library});

  final GamePackageTransferService _transfer;
  final Future<void> Function(GameSummary game) _onImported;
  final GameLibraryRepository _library;
  final List<GameDownloadTask> _tasks = [];
  Future<void>? _processingOperation;

  List<GameDownloadTask> get tasks => List.unmodifiable(_tasks);

  void enqueue(Iterable<OnlineCatalogGame> games) {
    final existing = _tasks
        .where(
          (task) =>
              task.status == GameDownloadStatus.queued ||
              task.status == GameDownloadStatus.downloading,
        )
        .map((task) => task.game.downloadKey)
        .toSet();
    for (final game in games) {
      final key = game.downloadKey;
      if (!existing.add(key)) continue;
      _tasks.add(
        GameDownloadTask(
          id: 'download-${DateTime.now().microsecondsSinceEpoch}-${_tasks.length}',
          game: game,
        ),
      );
    }
    notifyListeners();
    _startProcessing();
  }

  void stop(String taskId) {
    final task = _find(taskId);
    if (task == null ||
        task.status == GameDownloadStatus.completed ||
        task.status == GameDownloadStatus.failed ||
        task.status == GameDownloadStatus.stopped) {
      return;
    }
    task.cancelled = true;
    task.client?.close();
    if (task.status == GameDownloadStatus.queued) {
      task.status = GameDownloadStatus.stopped;
      task.progress = null;
    }
    notifyListeners();
  }

  void delete(String taskId) {
    final task = _find(taskId);
    if (task == null) return;
    if (task.status == GameDownloadStatus.downloading) {
      task.removeWhenDone = true;
      stop(taskId);
      return;
    }
    _tasks.remove(task);
    notifyListeners();
  }

  GameDownloadTask? _find(String id) {
    for (final task in _tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  void _startProcessing() {
    if (_processingOperation != null) return;
    final operation = _process();
    _processingOperation = operation;
    operation.whenComplete(() {
      if (identical(_processingOperation, operation)) {
        _processingOperation = null;
      }
    });
  }

  Future<void> _process() async {
    while (true) {
      GameDownloadTask? next;
      for (final task in _tasks) {
        if (task.status == GameDownloadStatus.queued) {
          next = task;
          break;
        }
      }
      if (next == null) return;
      await _download(next);
    }
  }

  Future<void> close() async {
    for (final task in _tasks) {
      if (task.status == GameDownloadStatus.queued ||
          task.status == GameDownloadStatus.downloading) {
        task.cancelled = true;
        task.client?.close();
        if (task.status == GameDownloadStatus.queued) {
          task.status = GameDownloadStatus.stopped;
        }
      }
    }
    await _processingOperation;
    dispose();
  }

  Future<void> _download(GameDownloadTask task) async {
    task.status = GameDownloadStatus.downloading;
    task.progress = 0;
    notifyListeners();
    final client = http.Client();
    task.client = client;
    final temporary = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-catalog-import-${task.id}.zip',
    );
    IOSink? sink;
    try {
      if (await temporary.exists()) await temporary.delete();
      final uri = task.game.source.host.replace(
        path: '/apps/download',
        queryParameters: {
          'id': task.game.manifest.id,
          'version': task.game.manifest.version,
        },
      );
      final request = http.Request('GET', uri);
      if (task.game.source.token.isNotEmpty) {
        request.headers[HttpHeaders.authorizationHeader] =
            'Bearer ${task.game.source.token}';
      }
      final response = await client.send(request);
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('下载失败：HTTP ${response.statusCode}', uri: uri);
      }
      final total = response.contentLength;
      if (total != null &&
          (total <= 0 ||
              total > GamePackageTransferService.maxCompressedBytes)) {
        throw const FormatException('远程游戏包大小超过允许范围');
      }
      sink = temporary.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        if (task.cancelled) throw const _DownloadCancelled();
        received += chunk.length;
        if (received > GamePackageTransferService.maxCompressedBytes) {
          throw const FormatException('远程游戏包超过 64 MiB');
        }
        sink.add(chunk);
        task.progress = total == null || total == 0
            ? null
            : (received / total).clamp(0, 1);
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (task.cancelled) throw const _DownloadCancelled();
      _validateReplacement(task.game);
      final imported = await _transfer.importPackage(
        temporary,
        expectedGameId: task.game.manifest.id,
        expectedVersion: task.game.manifest.version,
        expectedPublisher: task.game.publisher.isEmpty
            ? null
            : task.game.publisher,
      );
      await _onImported(imported);
      task.status = GameDownloadStatus.completed;
      task.progress = 1;
    } on _DownloadCancelled {
      task.status = GameDownloadStatus.stopped;
      task.progress = null;
    } on Object catch (error) {
      if (task.cancelled) {
        task.status = GameDownloadStatus.stopped;
      } else {
        task.status = GameDownloadStatus.failed;
        task.error = error.toString();
      }
      task.progress = null;
    } finally {
      task.client = null;
      client.close();
      await sink?.close();
      if (await temporary.exists()) await temporary.delete();
      if (task.removeWhenDone) _tasks.remove(task);
      notifyListeners();
    }
  }

  void _validateReplacement(OnlineCatalogGame offer) {
    GameSummary? installed;
    for (final game in _library.cachedGames) {
      if (game.id == offer.manifest.id) {
        installed = game;
        break;
      }
    }
    if (installed == null) return;
    final installedPublisher = installed.author.trim();
    final offerPublisher = offer.publisher.trim();
    if (installedPublisher.isEmpty ||
        offerPublisher.isEmpty ||
        installedPublisher != offerPublisher) {
      throw const FormatException('已安装游戏与下载包的发布者不一致');
    }
    final current = SemanticVersion.parse(installed.version);
    final target = SemanticVersion.parse(offer.manifest.version);
    if (target.compareTo(current) <= 0) {
      throw FormatException('升级版本必须严格高于当前版本 ${installed.version}');
    }
  }
}

class GameCatalogController extends ChangeNotifier {
  GameCatalogController({
    required GameLibraryRepository library,
    required GamePackageTransferService transfer,
    required Future<void> Function(GameSummary game) onImported,
    required String Function() nicknameProvider,
    GameCatalogPreferences? preferences,
    GameCatalogPublisher? publisher,
    DateTime Function()? now,
  }) : _preferences = preferences ?? GameCatalogPreferences(),
       _publisher = publisher ?? GameCatalogPublisher(transfer: transfer),
       _now = now ?? DateTime.now,
       _server = GameCatalogServer(
         library,
         transfer,
         nicknameProvider: nicknameProvider,
       ),
       downloads = GameDownloadQueue(transfer, onImported, library: library);

  final GameCatalogPreferences _preferences;
  final GameCatalogPublisher _publisher;
  final DateTime Function() _now;
  final GameCatalogServer _server;
  final GameDownloadQueue downloads;
  GameCatalogShareConfig _share = const GameCatalogShareConfig();
  List<OnlineGameSource> _sources = const [];
  int _defaultPageSize = defaultOnlineGamePageSize;
  bool _initialized = false;
  Future<void>? _initializeOperation;
  Object? _shareError;

  bool get initialized => _initialized;
  GameCatalogShareConfig get share => _share;
  List<OnlineGameSource> get sources => List.unmodifiable(_sources);
  List<OnlineGameSource> get uploadCandidates =>
      List.unmodifiable(_sources.where((source) => source.canUpload));
  int get defaultPageSize => _defaultPageSize;
  Object? get shareError => _shareError;
  bool get sharing => _server.running;

  Future<void> initialize() async {
    if (_initialized) return;
    final active = _initializeOperation;
    if (active != null) return active;
    final operation = _loadPreferences();
    _initializeOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_initializeOperation, operation)) {
        _initializeOperation = null;
      }
    }
  }

  Future<void> _loadPreferences() async {
    final value = await _preferences.load();
    _share = value.share;
    _sources = value.sources;
    _defaultPageSize = value.defaultPageSize;
    _initialized = true;
    if (_share.enabled) {
      try {
        await _server.start(port: _share.port, token: _share.token);
      } on Object catch (error) {
        _shareError = error;
        _share = _share.copyWith(enabled: false);
      }
    }
    notifyListeners();
  }

  Future<void> enableSharing({required int port, required String token}) async {
    await initialize();
    _shareError = null;
    try {
      await _server.start(port: port, token: token);
      _share = GameCatalogShareConfig(
        enabled: true,
        port: port,
        token: token.trim(),
      );
      await _save();
    } on Object catch (error) {
      _shareError = error;
      rethrow;
    } finally {
      notifyListeners();
    }
  }

  Future<void> disableSharing() async {
    await _server.stop();
    _share = _share.copyWith(enabled: false);
    _shareError = null;
    await _save();
    notifyListeners();
  }

  Future<List<Uri>> sharingEndpoints() async {
    if (!sharing) return const [];
    return resolveLanEndpoints(_share.port);
  }

  Uri configurationUriFor(Uri endpoint, {String? name}) => _share.token.isEmpty
      ? catalogOrigin(endpoint)
      : catalogOrigin(
          endpoint,
        ).replace(queryParameters: {'token': _share.token});

  Future<void> setDefaultPageSize(int value) async {
    if (value < 1 || value > 100) {
      throw const FormatException('默认获取数量必须在 1 到 100 之间');
    }
    _defaultPageSize = value;
    await _save();
    notifyListeners();
  }

  Future<void> upsertSource(OnlineGameSource source) async {
    final next = [..._sources];
    final index = next.indexWhere((item) => item.id == source.id);
    if (index < 0) {
      next.add(source);
    } else {
      next[index] = source;
    }
    _sources = List.unmodifiable(next);
    await _save();
    notifyListeners();
  }

  Future<void> removeSource(String id) async {
    _sources = List.unmodifiable(_sources.where((source) => source.id != id));
    await _save();
    notifyListeners();
  }

  Future<void> setSourceEnabled(String id, bool enabled) async {
    _sources = List.unmodifiable(
      _sources.map(
        (source) =>
            source.id == id ? source.copyWith(enabled: enabled) : source,
      ),
    );
    await _save();
    notifyListeners();
  }

  Future<void> setSourceShowOnHome(String id, bool showOnHome) async {
    _sources = List.unmodifiable(
      _sources.map(
        (source) =>
            source.id == id ? source.copyWith(showOnHome: showOnHome) : source,
      ),
    );
    await _save();
    notifyListeners();
  }

  Future<OnlineGameSource> verifyAndUpsertSource(
    String rawValue, {
    String? sourceId,
  }) async {
    await initialize();
    final parsed = OnlineGameSource.fromPublicUrl(rawValue, id: sourceId);
    OnlineGameSource? existing;
    for (final source in _sources) {
      if (source.host == parsed.host) {
        existing = source;
        break;
      }
    }
    final candidate = OnlineGameSource(
      id: existing?.id ?? parsed.id,
      name: existing?.name ?? parsed.name,
      host: parsed.host,
      token: parsed.token,
      uploadKey: existing?.uploadKey ?? '',
      enabled: existing?.enabled ?? true,
      showOnHome: existing?.showOnHome ?? true,
    );
    final probe = await _probeSource(candidate);
    final declaration = probe.declaration;
    if (probe.error != null || declaration == null) {
      throw FormatException(probe.error ?? '游戏源声明无效');
    }
    final verified = candidate.copyWith(
      name: existing?.name ?? declaration.displayNameFor(candidate.host),
      declaration: declaration,
      lastValidatedAt: DateTime.now().toUtc(),
      clearLastError: true,
    );
    await upsertSource(verified);
    return verified;
  }

  Future<OnlineGameSourceProbe> refreshSourceDeclaration(String id) async {
    await initialize();
    final source = _sources.firstWhere((item) => item.id == id);
    final probe = await _probeSource(source);
    final updated = probe.declaration == null
        ? source.copyWith(
            lastValidatedAt: DateTime.now().toUtc(),
            lastError: probe.error ?? '声明无效',
          )
        : source.copyWith(
            declaration: probe.declaration,
            lastValidatedAt: DateTime.now().toUtc(),
            clearLastError: true,
          );
    await upsertSource(updated);
    return OnlineGameSourceProbe(
      source: updated,
      elapsed: probe.elapsed,
      declaration: probe.declaration,
      error: probe.error,
    );
  }

  Future<OnlineCatalogSearchResult> search({
    Map<String, int> pagesBySource = const {},
    String name = '',
    String tag = '',
    String description = '',
  }) async {
    await initialize();
    final enabled = _sources.where((source) => source.enabled).toList();
    final results = await Future.wait(
      enabled.map(
        (source) => _searchSource(
          source,
          page: pagesBySource[source.id] ?? 1,
          validateLatestOffers: true,
          name: name,
          tag: tag,
          description: description,
        ),
      ),
    );
    final games = <OnlineCatalogGame>[];
    final errors = <String, String>{};
    final sections = <SourceSectionResult>[];
    for (final result in results) {
      if ((result.error ?? result.protocolError) case final error?) {
        errors[result.source.id] = error;
      }
      games.addAll(result.games);
      sections.add(_sectionFrom(result));
    }
    return OnlineCatalogSearchResult(
      games: List.unmodifiable(games),
      errors: Map.unmodifiable(errors),
      sections: List.unmodifiable(sections),
    );
  }

  Future<OnlineCatalogSearchResult> searchAll({
    String name = '',
    String tag = '',
    String description = '',
  }) async {
    await initialize();
    final results = await Future.wait(
      _sources
          .where((source) => source.enabled)
          .map(
            (source) => _searchAllSource(
              source,
              name: name,
              tag: tag,
              description: description,
            ),
          ),
    );
    final games = <OnlineCatalogGame>[];
    final errors = <String, String>{};
    final sections = <SourceSectionResult>[];
    for (final result in results) {
      games.addAll(result.offers);
      sections.add(result);
      if (result.error case final error?) {
        errors[result.source.id] = error;
      }
    }
    return OnlineCatalogSearchResult(
      games: List.unmodifiable(games),
      errors: Map.unmodifiable(errors),
      sections: List.unmodifiable(sections),
    );
  }

  Future<HomeCatalogResult> loadHome({
    Map<String, int> pagesBySource = const {},
  }) async {
    await initialize();
    final visible = _sources
        .where((source) => source.enabled && source.showOnHome)
        .toList();
    final sections = await Future.wait(
      visible.map(
        (source) => _searchSource(
          source,
          page: pagesBySource[source.id] ?? 1,
          validateLatestOffers: false,
          name: '',
          tag: '',
          description: '',
        ),
      ),
    );
    return HomeCatalogResult(List.unmodifiable(sections.map(_sectionFrom)));
  }

  Future<SourceSectionResult> loadHomeSource(
    String sourceId, {
    int page = 1,
    String? cursor,
  }) async {
    await initialize();
    final source = _sources.firstWhere(
      (item) => item.id == sourceId && item.enabled && item.showOnHome,
    );
    final result = await _searchSource(
      source,
      page: page,
      cursor: cursor,
      validateLatestOffers: false,
      name: '',
      tag: '',
      description: '',
    );
    return SourceSectionResult(
      source: source,
      offers: result.games,
      total: result.total,
      page: result.page,
      nextCursor: result.nextCursor,
      error: result.error,
    );
  }

  Future<SourceSectionResult> searchSource(
    String sourceId, {
    int page = 1,
    String? cursor,
    String name = '',
    String tag = '',
    String description = '',
  }) async {
    await initialize();
    final source = _sources.firstWhere(
      (item) => item.id == sourceId && item.enabled,
    );
    return _sectionFrom(
      await _searchSource(
        source,
        page: page,
        cursor: cursor,
        validateLatestOffers: true,
        name: name,
        tag: tag,
        description: description,
      ),
    );
  }

  Future<List<AggregatedGameResult>> searchAggregated({
    String name = '',
    String tag = '',
    String description = '',
    Map<String, GameLibraryUsageStats> usage = const {},
  }) async {
    final result = await search(name: name, tag: tag, description: description);
    return aggregateCatalogOffers(
      result.games,
      usage: usage,
      sourceOrder: _sources.map((source) => source.id).toList(),
    );
  }

  Future<GameUpdateCheckResult> checkUpdates(
    Iterable<GameSummary> installedGames,
  ) async {
    final result = await searchAll();
    final sourceErrors = [
      for (final source in _sources)
        if (source.enabled)
          if (result.errors[source.id] case final message?)
            GameUpdateSourceError(
              sourceId: source.id,
              localSourceName: source.name,
              message: message,
            ),
    ];
    return GameUpdateCheckResult(
      candidates: findGameUpdates(
        installedGames: installedGames,
        offers: result.games,
        sourceOrder: _sources.map((source) => source.id).toList(),
      ),
      sourceErrors: List.unmodifiable(sourceErrors),
      checkedAt: _now().toUtc(),
    );
  }

  Future<GameCatalogPublishBatchResult> publishGamePackage({
    required GameSummary game,
    required Iterable<String> sourceIds,
    GameCatalogPublishEventCallback? onEvent,
  }) async {
    await initialize();
    return _publisher.publish(
      game: game,
      sourceIds: sourceIds,
      configuredSources: _sources,
      onEvent: onEvent,
    );
  }

  Future<GameCatalogPublishBatchResult> retryFailedGamePackagePublish({
    required GameSummary game,
    required GameCatalogPublishBatchResult previous,
    GameCatalogPublishEventCallback? onEvent,
  }) async {
    await initialize();
    return _publisher.retryFailures(
      game: game,
      previous: previous,
      configuredSources: _sources,
      onEvent: onEvent,
    );
  }

  Future<List<int>?> loadOfferIcon(OnlineCatalogGame offer) async {
    final uri = offer.icon;
    if (uri == null || !isSameCatalogOrigin(offer.source.host, uri)) {
      return null;
    }
    final client = http.Client();
    try {
      final request = http.Request('GET', uri);
      if (offer.source.token.isNotEmpty) {
        request.headers[HttpHeaders.authorizationHeader] =
            'Bearer ${offer.source.token}';
      }
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok ||
          (response.contentLength ?? 0) > maxGamePackageIconBytes) {
        return null;
      }
      final bytes = BytesBuilder(copy: false);
      var length = 0;
      await for (final chunk in response.stream) {
        length += chunk.length;
        if (length > maxGamePackageIconBytes) return null;
        bytes.add(chunk);
      }
      final result = bytes.takeBytes();
      if (!isSafeGamePackageIconBytes(result)) return null;
      return List.unmodifiable(result);
    } on Object {
      return null;
    } finally {
      client.close();
    }
  }

  Future<List<OnlineGameSourceProbe>> probeEnabledSources() async {
    await initialize();
    return Future.wait(
      _sources.where((source) => source.enabled).map(_probeSource),
    );
  }

  Future<_SourceSearchResult> _searchSource(
    OnlineGameSource source, {
    required int page,
    String? cursor,
    bool validateLatestOffers = true,
    required String name,
    required String tag,
    required String description,
  }) async {
    final client = http.Client();
    try {
      final uri = source.host.replace(
        path: '/apps/list',
        queryParameters: {
          'size': _defaultPageSize.toString(),
          'page': page.toString(),
          if (cursor?.trim().isNotEmpty ?? false) 'cursor': cursor!.trim(),
          if (name.trim().isNotEmpty) 's_name': name.trim(),
          if (tag.trim().isNotEmpty) 's_tag': tag.trim(),
          if (description.trim().isNotEmpty) 's_desc': description.trim(),
        },
      );
      final response = await client
          .get(
            uri,
            headers: source.token.isEmpty
                ? null
                : {HttpHeaders.authorizationHeader: 'Bearer ${source.token}'},
          )
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['data'] is! List) {
        throw const FormatException('游戏源返回格式错误');
      }
      final games = <OnlineCatalogGame>[];
      for (final raw in decoded['data']! as List) {
        if (raw is! Map) throw const FormatException('游戏条目必须是对象');
        final json = Map<String, Object?>.from(raw);
        final iconRaw = json.remove('icon');
        final catalogAuthor = json['author'] is String
            ? json['author']! as String
            : '';
        Uri? icon;
        if (iconRaw is String) {
          final candidate = Uri.tryParse(iconRaw);
          if (candidate != null &&
              candidate.isAbsolute &&
              isSameCatalogOrigin(source.host, candidate)) {
            icon = candidate;
          }
        }
        games.add(
          OnlineCatalogGame(
            manifest: GameManifest.fromJson(json),
            source: source,
            icon: icon,
            catalogAuthor: catalogAuthor,
          ),
        );
      }
      final validation = validateLatestOffers
          ? _filterSourceLatestOffers(source, games)
          : _LatestOfferPageValidation(
              games: List<OnlineCatalogGame>.unmodifiable(games),
            );
      final total = decoded['total'];
      return _SourceSearchResult(
        source: source,
        games: validation.games,
        total: total is int && total >= 0 ? total : games.length,
        page: page,
        returnedCount: games.length,
        nextCursor:
            decoded['nextCursor'] is String &&
                (decoded['nextCursor']! as String).trim().isNotEmpty
            ? (decoded['nextCursor']! as String).trim()
            : null,
        protocolError: validation.protocolError,
      );
    } on Object catch (error) {
      return _SourceSearchResult(
        source: source,
        games: const [],
        total: 0,
        page: page,
        returnedCount: 0,
        error: error.toString(),
      );
    } finally {
      client.close();
    }
  }

  Future<SourceSectionResult> _searchAllSource(
    OnlineGameSource source, {
    required String name,
    required String tag,
    required String description,
  }) async {
    final offers = <OnlineCatalogGame>[];
    final offerIndexesByGameId = <String, int>{};
    final seenCursors = <String>{};
    final protocolErrors = <String>[];
    var page = 1;
    var total = 0;
    String? requestCursor;
    while (true) {
      final result = await _searchSource(
        source,
        page: page,
        cursor: requestCursor,
        validateLatestOffers: true,
        name: name,
        tag: tag,
        description: description,
      );
      if (result.error case final error?) {
        return SourceSectionResult(
          source: source,
          offers: List.unmodifiable(offers),
          total: total,
          page: page,
          nextCursor: requestCursor,
          error: _combineSourceErrors(protocolErrors, error),
        );
      }
      if (result.protocolError case final error?) {
        protocolErrors.add(error);
      }
      total = result.total;
      final nextCursor = result.nextCursor;
      var added = 0;
      for (final offer in result.games) {
        final id = offer.manifest.id;
        final existingIndex = offerIndexesByGameId[id];
        if (existingIndex != null) {
          final existing = offers[existingIndex];
          if (SemanticVersion.parse(
                offer.manifest.version,
              ).compareTo(SemanticVersion.parse(existing.manifest.version)) >
              0) {
            offers[existingIndex] = offer;
          }
          protocolErrors.add('游戏源在不同分页重复返回 gameId：$id');
          continue;
        }
        offerIndexesByGameId[id] = offers.length;
        offers.add(offer);
        added += 1;
      }
      final cursorMode = requestCursor != null || nextCursor != null;
      final complete = cursorMode
          ? nextCursor == null
          : offers.length >= total ||
                result.returnedCount == 0 ||
                result.returnedCount < _defaultPageSize;
      if (complete) {
        return SourceSectionResult(
          source: source,
          offers: List.unmodifiable(offers),
          total: total,
          page: page,
          nextCursor: nextCursor,
          error: _combineSourceErrors(protocolErrors),
        );
      }
      if (added == 0 && nextCursor == null) {
        return SourceSectionResult(
          source: source,
          offers: List.unmodifiable(offers),
          total: total,
          page: page,
          nextCursor: nextCursor,
          error: _combineSourceErrors(
            protocolErrors,
            '游戏源分页没有新的 latest offer，已停止继续读取',
          ),
        );
      }
      if (nextCursor != null && !seenCursors.add(nextCursor)) {
        return SourceSectionResult(
          source: source,
          offers: List.unmodifiable(offers),
          total: total,
          page: page,
          nextCursor: nextCursor,
          error: _combineSourceErrors(protocolErrors, '游戏源重复返回 cursor，无法继续读取'),
        );
      }
      requestCursor = nextCursor;
      page += 1;
      if (page > 2048) {
        return SourceSectionResult(
          source: source,
          offers: List.unmodifiable(offers),
          total: total,
          page: page - 1,
          nextCursor: nextCursor,
          error: _combineSourceErrors(protocolErrors, '游戏源分页超过安全上限'),
        );
      }
    }
  }

  SourceSectionResult _sectionFrom(_SourceSearchResult result) {
    return SourceSectionResult(
      source: result.source,
      offers: result.games,
      total: result.total,
      page: result.page,
      nextCursor: result.nextCursor,
      error: result.error ?? result.protocolError,
      exhausted: result.returnedCount == 0 && result.nextCursor == null,
    );
  }

  Future<OnlineGameSourceProbe> _probeSource(OnlineGameSource source) async {
    final client = http.Client();
    final stopwatch = Stopwatch()..start();
    try {
      final response = await client
          .get(
            source.host.replace(path: '/apps/info'),
            headers: source.token.isEmpty
                ? null
                : {HttpHeaders.authorizationHeader: 'Bearer ${source.token}'},
          )
          .timeout(const Duration(seconds: 12));
      stopwatch.stop();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map) {
        throw const FormatException('游戏源声明根节点必须是对象');
      }
      return OnlineGameSourceProbe(
        source: source,
        elapsed: stopwatch.elapsed,
        declaration: GameCatalogDeclaration.fromJson(
          Map<String, Object?>.from(decoded),
        ),
      );
    } on Object catch (error) {
      stopwatch.stop();
      return OnlineGameSourceProbe(
        source: source,
        elapsed: stopwatch.elapsed,
        error: error.toString(),
      );
    } finally {
      client.close();
    }
  }

  Future<void> close() async {
    await _server.stop();
    await downloads.close();
    dispose();
  }

  Future<void> _save() => _preferences.save(
    GameCatalogPreferencesValue(
      share: _share,
      defaultPageSize: _defaultPageSize,
      sources: _sources,
    ),
  );
}

class _SourceSearchResult {
  const _SourceSearchResult({
    required this.source,
    required this.games,
    required this.total,
    required this.page,
    required this.returnedCount,
    this.nextCursor,
    this.error,
    this.protocolError,
  });

  final OnlineGameSource source;
  final List<OnlineCatalogGame> games;
  final int total;
  final int page;
  final int returnedCount;
  final String? nextCursor;
  final String? error;
  final String? protocolError;
}

class _LatestOfferPageValidation {
  const _LatestOfferPageValidation({required this.games, this.protocolError});

  final List<OnlineCatalogGame> games;
  final String? protocolError;
}

_LatestOfferPageValidation _filterSourceLatestOffers(
  OnlineGameSource source,
  List<OnlineCatalogGame> offers,
) {
  final result = <OnlineCatalogGame>[];
  final indexesByGameId = <String, int>{};
  final duplicateGameIds = <String>{};
  for (final offer in offers) {
    if (offer.source.id != source.id) {
      throw const FormatException('offer 的 sourceId 与请求源不一致');
    }
    final version = SemanticVersion.parse(offer.manifest.version);
    final id = offer.manifest.id;
    final existingIndex = indexesByGameId[id];
    if (existingIndex == null) {
      indexesByGameId[id] = result.length;
      result.add(offer);
      continue;
    }
    duplicateGameIds.add(id);
    final existing = result[existingIndex];
    if (version.compareTo(SemanticVersion.parse(existing.manifest.version)) >
        0) {
      result[existingIndex] = offer;
    }
  }
  return _LatestOfferPageValidation(
    games: List.unmodifiable(result),
    protocolError: duplicateGameIds.isEmpty
        ? null
        : '游戏源为同一 gameId 返回了多个版本：'
              '${duplicateGameIds.join(', ')}；仅保留最高语义版本',
  );
}

String? _combineSourceErrors(List<String> errors, [String? trailing]) {
  final values = <String>[...errors, ?trailing];
  if (values.isEmpty) return null;
  return values.toSet().join(' | ');
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
