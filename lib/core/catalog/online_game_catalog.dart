import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';
import '../game_package/game_library_repository.dart';
import '../game_package/game_package_transfer_service.dart';
import '../network/lan_endpoint_resolver.dart';
import 'game_catalog_models.dart';
import 'game_catalog_preferences.dart';
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
  GameDownloadQueue(this._transfer, this._onImported);

  final GamePackageTransferService _transfer;
  final Future<void> Function(GameSummary game) _onImported;
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
        .map((task) => '${task.game.source.id}:${task.game.manifest.id}')
        .toSet();
    for (final game in games) {
      final key = '${game.source.id}:${game.manifest.id}';
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
      'playmesh-catalog-import.playmesh.zip',
    );
    IOSink? sink;
    try {
      if (await temporary.exists()) await temporary.delete();
      final uri = task.game.source.host.replace(
        path: '/apps/download',
        queryParameters: {'id': task.game.manifest.id},
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
      final imported = await _transfer.importPackage(temporary);
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
}

class GameCatalogController extends ChangeNotifier {
  GameCatalogController({
    required GameLibraryRepository library,
    required GamePackageTransferService transfer,
    required Future<void> Function(GameSummary game) onImported,
    GameCatalogPreferences? preferences,
  }) : _preferences = preferences ?? GameCatalogPreferences(),
       _server = GameCatalogServer(library, transfer),
       downloads = GameDownloadQueue(transfer, onImported);

  final GameCatalogPreferences _preferences;
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

  Uri configurationUriFor(Uri endpoint, {String? name}) => Uri(
    scheme: 'playmesh',
    host: 'catalog-source',
    queryParameters: {
      'host': endpoint.toString(),
      if (_share.token.isNotEmpty) 'token': _share.token,
      'name': name ?? endpoint.host,
    },
  );

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

  Future<OnlineCatalogSearchResult> search({
    int page = 1,
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
          page: page,
          name: name,
          tag: tag,
          description: description,
        ),
      ),
    );
    final unique = <String, OnlineCatalogGame>{};
    final errors = <String, String>{};
    for (final result in results) {
      if (result.error case final error?) {
        errors[result.source.id] = error;
      }
      for (final game in result.games) {
        unique.putIfAbsent(game.manifest.id, () => game);
      }
    }
    return OnlineCatalogSearchResult(
      games: List.unmodifiable(unique.values),
      errors: Map.unmodifiable(errors),
    );
  }

  Future<_SourceSearchResult> _searchSource(
    OnlineGameSource source, {
    required int page,
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
        games.add(
          OnlineCatalogGame(
            manifest: GameManifest.fromJson(Map<String, Object?>.from(raw)),
            source: source,
          ),
        );
      }
      return _SourceSearchResult(source: source, games: games);
    } on Object catch (error) {
      return _SourceSearchResult(
        source: source,
        games: const [],
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
    this.error,
  });

  final OnlineGameSource source;
  final List<OnlineCatalogGame> games;
  final String? error;
}

class _DownloadCancelled implements Exception {
  const _DownloadCancelled();
}
