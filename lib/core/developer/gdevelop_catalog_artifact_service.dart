import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../library/playmesh_library_root.dart';

typedef GDevelopCatalogArtifactFetcher =
    Future<void> Function(Uri uri, File target, int maximumBytes, Uri? proxy);

class GDevelopCatalogArtifactException implements Exception {
  const GDevelopCatalogArtifactException(
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

class GDevelopCatalogArtifactRequest {
  const GDevelopCatalogArtifactRequest({
    required this.id,
    required this.kind,
    required this.repository,
    required this.commit,
    required this.rootTreeSha,
    required this.path,
    required this.declaredBytes,
    required this.sha256,
    required this.mediaType,
    this.gitBlobOid,
  });

  factory GDevelopCatalogArtifactRequest.fromJson(Map<String, Object?> json) {
    const requiredKeys = {
      'id',
      'kind',
      'repository',
      'commit',
      'rootTreeSha',
      'path',
      'declaredBytes',
      'sha256',
      'mediaType',
    };
    const allowedKeys = {...requiredKeys, 'gitBlobOid'};
    if (!json.keys.toSet().containsAll(requiredKeys) ||
        json.keys.any((key) => !allowedKeys.contains(key))) {
      throw const FormatException('目录 artifact 字段不完整或含未知字段');
    }
    String string(String key) {
      final value = json[key];
      if (value is! String || value.isEmpty) {
        throw FormatException('目录 artifact $key 无效');
      }
      return value;
    }

    final declaredBytes = json['declaredBytes'];
    if (declaredBytes is! int || declaredBytes < 1) {
      throw const FormatException('目录 artifact declaredBytes 无效');
    }
    final gitBlobOid = json['gitBlobOid'];
    if (gitBlobOid != null &&
        (gitBlobOid is! String ||
            !RegExp(r'^[a-f0-9]{40}$').hasMatch(gitBlobOid))) {
      throw const FormatException('目录 artifact gitBlobOid 无效');
    }
    return GDevelopCatalogArtifactRequest(
      id: string('id'),
      kind: string('kind'),
      repository: string('repository'),
      commit: string('commit'),
      rootTreeSha: string('rootTreeSha'),
      path: string('path'),
      declaredBytes: declaredBytes,
      gitBlobOid: gitBlobOid as String?,
      sha256: string('sha256'),
      mediaType: string('mediaType'),
    );
  }

  final String id;
  final String kind;
  final String repository;
  final String commit;
  final String rootTreeSha;
  final String path;
  final int declaredBytes;
  final String? gitBlobOid;
  final String sha256;
  final String mediaType;

  String get sourceIdentity => '$repository@$commit:$path';
}

class GDevelopCatalogArtifactResult {
  const GDevelopCatalogArtifactResult({
    required this.file,
    required this.size,
    required this.sha256,
    required this.mediaType,
    required this.cacheHit,
  });

  final File file;
  final int size;
  final String sha256;
  final String mediaType;
  final bool cacheHit;
}

class GDevelopCatalogArtifactService {
  GDevelopCatalogArtifactService({
    Future<Directory> Function()? rootResolver,
    Future<String> Function()? lockLoader,
    Future<String> Function(String name)? catalogIndexLoader,
    GDevelopCatalogArtifactFetcher? fetcher,
    this.proxy,
  }) : _rootResolver = rootResolver ?? _defaultRoot,
       _lockLoader =
           lockLoader ??
           (() => rootBundle.loadString(
             'assets/playmesh-library/public/GDevelop/playmesh/catalog-lock.json',
           )),
       _catalogIndexLoader =
           catalogIndexLoader ??
           ((name) => rootBundle.loadString(
             'assets/playmesh-library/public/GDevelop/playmesh/catalog/generated/$name',
           )),
       _fetcher = fetcher ?? _fetchToFile;

  final Future<Directory> Function() _rootResolver;
  final Future<String> Function() _lockLoader;
  final Future<String> Function(String name) _catalogIndexLoader;
  final GDevelopCatalogArtifactFetcher _fetcher;
  final Uri? proxy;
  final Map<String, Future<GDevelopCatalogArtifactResult>> _inflight = {};
  Future<_GDevelopCatalogPolicy>? _policy;

  static Future<Directory> _defaultRoot() async {
    final library = await PlaymeshLibraryRoot.resolve();
    return Directory(
      '${library.path}${Platform.pathSeparator}GDevelop'
      '${Platform.pathSeparator}catalog-cache',
    );
  }

  Future<GDevelopCatalogArtifactResult> acquire(
    GDevelopCatalogArtifactRequest request,
  ) {
    final key = '${request.sourceIdentity}:${request.sha256}';
    return _inflight.putIfAbsent(
      key,
      () => _acquire(request).whenComplete(() {
        // Do not return the removed Future from this callback. It is the same
        // Future that is currently completing, so returning it creates a
        // self-referential completion cycle and leaves every acquire hanging.
        _inflight.remove(key);
      }),
    );
  }

  Future<GDevelopCatalogArtifactResult> _acquire(
    GDevelopCatalogArtifactRequest request,
  ) async {
    final policy = await (_policy ??= _loadPolicy());
    policy.validate(request);
    final root = await _rootResolver();
    final cas = Directory('${root.path}${Platform.pathSeparator}cas');
    final lkg = Directory('${root.path}${Platform.pathSeparator}lkg');
    final staging = Directory('${root.path}${Platform.pathSeparator}staging');
    await Future.wait([
      cas.create(recursive: true),
      lkg.create(recursive: true),
      staging.create(recursive: true),
    ]);
    final casFile = File(
      '${cas.path}${Platform.pathSeparator}${request.sha256}',
    );
    final lkgKey = sha256
        .convert(utf8.encode(request.sourceIdentity))
        .toString();
    final lkgFile = File('${lkg.path}${Platform.pathSeparator}$lkgKey.json');
    if (await _isExpectedFile(casFile, request)) {
      await _writeLkg(lkgFile, request);
      return GDevelopCatalogArtifactResult(
        file: casFile,
        size: request.declaredBytes,
        sha256: request.sha256,
        mediaType: request.mediaType,
        cacheHit: true,
      );
    }
    if (await casFile.exists()) await casFile.delete();

    final temporary = File(
      '${staging.path}${Platform.pathSeparator}'
      '${request.sha256}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      final uri = Uri.https(
        'raw.githubusercontent.com',
        '/${request.repository}/${request.commit}/${request.path}',
      );
      await _fetcher(uri, temporary, policy.maximumBytes(request), proxy);
      if (!await _isExpectedFile(temporary, request)) {
        throw const GDevelopCatalogArtifactException(
          'artifact_integrity_mismatch',
          '官方目录正文大小或 SHA-256 不匹配',
        );
      }
      if (await casFile.exists()) await casFile.delete();
      await temporary.rename(casFile.path);
      await _writeLkg(lkgFile, request);
      return GDevelopCatalogArtifactResult(
        file: casFile,
        size: request.declaredBytes,
        sha256: request.sha256,
        mediaType: request.mediaType,
        cacheHit: false,
      );
    } on GDevelopCatalogArtifactException {
      rethrow;
    } on Object catch (error) {
      throw GDevelopCatalogArtifactException(
        'artifact_download_failed',
        '官方目录正文下载失败：$error',
        retryable: true,
      );
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<_GDevelopCatalogPolicy> _loadPolicy() async {
    final inputs = await Future.wait([
      _lockLoader(),
      _catalogIndexLoader('extensions-index.json'),
      _catalogIndexLoader('examples-index.json'),
    ]);
    final decoded = jsonDecode(inputs[0]);
    if (decoded is! Map) throw const FormatException('catalog-lock 根对象无效');
    return _GDevelopCatalogPolicy.fromJson(
      Map<String, Object?>.from(decoded),
      extensionsIndex: jsonDecode(inputs[1]),
      examplesIndex: jsonDecode(inputs[2]),
    );
  }

  static Future<bool> _isExpectedFile(
    File file,
    GDevelopCatalogArtifactRequest request,
  ) async {
    if (!await file.exists() || await file.length() != request.declaredBytes) {
      return false;
    }
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == request.sha256;
  }

  static Future<void> _writeLkg(
    File target,
    GDevelopCatalogArtifactRequest request,
  ) async {
    final temporary = File('${target.path}.${request.sha256}.tmp');
    await temporary.writeAsString(
      '${jsonEncode({'schemaVersion': 1, 'sourceIdentity': request.sourceIdentity, 'sha256': request.sha256, 'size': request.declaredBytes, 'updatedAt': DateTime.now().toUtc().toIso8601String()})}\n',
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  static Future<void> _fetchToFile(
    Uri uri,
    File target,
    int maximumBytes,
    Uri? proxy,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 30);
    if (proxy != null) {
      if (proxy.scheme != 'http' || proxy.host.isEmpty || proxy.port < 1) {
        throw const FormatException('目录代理必须是带端口的 HTTP 地址');
      }
      client.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
    }
    try {
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException('HTTP ${response.statusCode}', uri: uri);
      }
      if (response.contentLength > maximumBytes) {
        throw const GDevelopCatalogArtifactException(
          'artifact_too_large',
          '官方目录正文超过受控大小',
        );
      }
      final sink = target.openWrite(mode: FileMode.writeOnly);
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (received > maximumBytes) {
            throw const GDevelopCatalogArtifactException(
              'artifact_too_large',
              '官方目录正文超过受控大小',
            );
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } finally {
      client.close(force: true);
    }
  }
}

class _GDevelopCatalogPolicy {
  const _GDevelopCatalogPolicy({
    required this.sources,
    required this.maximumByKind,
    required this.artifacts,
  });

  factory _GDevelopCatalogPolicy.fromJson(
    Map<String, Object?> json, {
    required Object? extensionsIndex,
    required Object? examplesIndex,
  }) {
    final sources = json['sources'];
    final limits = json['limits'];
    if (sources is! Map || limits is! Map) {
      throw const FormatException('catalog-lock sources/limits 无效');
    }
    final result = <String, ({String commit, String rootTreeSha})>{};
    for (final name in ['extensions', 'examples']) {
      final source = sources[name];
      if (source is! Map) throw FormatException('catalog-lock $name 无效');
      final repository = source['repository'];
      final commit = source['commit'];
      final rootTreeSha = source['rootTreeSha'];
      if (repository is! String ||
          commit is! String ||
          rootTreeSha is! String) {
        throw FormatException('catalog-lock $name 来源无效');
      }
      result[repository] = (commit: commit, rootTreeSha: rootTreeSha);
    }
    int limit(String name) {
      final value = limits[name];
      if (value is! int || value < 1) {
        throw FormatException('catalog-lock $name 无效');
      }
      return value;
    }

    final artifacts = <String, _GDevelopCatalogExpectedArtifact>{};
    void addArtifact({
      required String repository,
      required String commit,
      required String rootTreeSha,
      required String path,
      required int size,
      required String sha256,
      required String mediaType,
      String? gitBlobOid,
      required Set<String> kinds,
    }) {
      final identity = '$repository@$commit:$path';
      final artifact = _GDevelopCatalogExpectedArtifact(
        repository: repository,
        commit: commit,
        rootTreeSha: rootTreeSha,
        path: path,
        size: size,
        sha256: sha256,
        mediaType: mediaType,
        gitBlobOid: gitBlobOid,
        kinds: kinds,
      );
      final previous = artifacts[identity];
      if (previous != null && !previous.sameBytes(artifact)) {
        throw FormatException('目录索引 artifact 冲突：$path');
      }
      artifacts[identity] = previous == null
          ? artifact
          : previous.withKinds({...previous.kinds, ...kinds});
    }

    final extensionRecord = _jsonMap(extensionsIndex, '扩展索引');
    final extensionArtifacts = _jsonMap(
      extensionRecord['artifacts'],
      '扩展 artifact 索引',
    );
    for (final value in extensionArtifacts.values) {
      final artifact = _jsonMap(value, '扩展 artifact');
      addArtifact(
        repository: artifact['repository'] as String,
        commit: artifact['commit'] as String,
        rootTreeSha: artifact['rootTreeSha'] as String,
        path: artifact['path'] as String,
        size: artifact['declaredBytes'] as int,
        sha256: artifact['sha256'] as String,
        mediaType: artifact['mediaType'] as String,
        gitBlobOid: artifact['gitBlobOid'] as String?,
        kinds: const {'extension'},
      );
    }

    final examplesRecord = _jsonMap(examplesIndex, '示例索引');
    final exampleSource = _jsonMap(examplesRecord['source'], '示例索引来源');
    final headers = examplesRecord['headers'];
    if (headers is! List) throw const FormatException('示例 header 索引无效');
    for (final value in headers) {
      final header = _jsonMap(value, '示例 header');
      final project = _jsonMap(header['project'], '示例 project artifact');
      addArtifact(
        repository: project['repository'] as String,
        commit: project['commit'] as String,
        rootTreeSha: project['rootTreeSha'] as String,
        path: project['path'] as String,
        size: project['declaredBytes'] as int,
        sha256: project['sha256'] as String,
        mediaType: project['mediaType'] as String,
        gitBlobOid: project['gitBlobOid'] as String?,
        kinds: const {'example-project'},
      );
      final root = header['root'];
      final files = header['files'];
      if (root is! String || files is! List) {
        throw const FormatException('示例文件索引无效');
      }
      for (final fileValue in files) {
        final file = _jsonMap(fileValue, '示例文件');
        final relativePath = file['relativePath'];
        if (relativePath is! String) {
          throw const FormatException('示例文件路径无效');
        }
        addArtifact(
          repository: exampleSource['repository'] as String,
          commit: exampleSource['commit'] as String,
          rootTreeSha: exampleSource['rootTreeSha'] as String,
          path: '$root/$relativePath',
          size: file['declaredBytes'] as int,
          sha256: file['sha256'] as String,
          mediaType: file['mediaType'] as String,
          gitBlobOid: file['gitBlobOid'] as String?,
          kinds: const {
            'example-resource',
            'example-license',
            'example-preview',
          },
        );
      }
    }
    return _GDevelopCatalogPolicy(
      sources: result,
      maximumByKind: {
        'extension': limit('extensionBytes'),
        'example-project': limit('exampleProjectBytes'),
        'example-resource': limit('exampleResourceBytes'),
        'example-license': limit('licenseFileBytes'),
        'example-preview': limit('exampleResourceBytes'),
      },
      artifacts: artifacts,
    );
  }

  final Map<String, ({String commit, String rootTreeSha})> sources;
  final Map<String, int> maximumByKind;
  final Map<String, _GDevelopCatalogExpectedArtifact> artifacts;

  int maximumBytes(GDevelopCatalogArtifactRequest request) =>
      maximumByKind[request.kind] ?? 0;

  void validate(GDevelopCatalogArtifactRequest request) {
    final source = sources[request.repository];
    final maximum = maximumByKind[request.kind];
    final expected = artifacts[request.sourceIdentity];
    final segments = request.path.split('/');
    final pathAllowed = request.repository.endsWith('GDevelop-extensions')
        ? request.kind == 'extension' &&
              (request.path.startsWith('extensions/reviewed/') ||
                  request.path.startsWith('extensions/community/'))
        : request.kind.startsWith('example-') &&
              request.path.startsWith('examples/');
    if (source == null ||
        source.commit != request.commit ||
        source.rootTreeSha != request.rootTreeSha ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(request.commit) ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(request.rootTreeSha) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(request.sha256) ||
        request.id.length > 512 ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        ) ||
        request.path.contains(r'\') ||
        !pathAllowed ||
        maximum == null ||
        request.declaredBytes > maximum ||
        expected == null ||
        !expected.matches(request)) {
      throw const FormatException('目录 artifact 不匹配本地固定清单策略');
    }
  }
}

Map<String, Object?> _jsonMap(Object? value, String label) {
  if (value is! Map) throw FormatException('$label 必须是 JSON 对象');
  return Map<String, Object?>.from(value);
}

class _GDevelopCatalogExpectedArtifact {
  const _GDevelopCatalogExpectedArtifact({
    required this.repository,
    required this.commit,
    required this.rootTreeSha,
    required this.path,
    required this.size,
    required this.sha256,
    required this.mediaType,
    required this.gitBlobOid,
    required this.kinds,
  });

  final String repository;
  final String commit;
  final String rootTreeSha;
  final String path;
  final int size;
  final String sha256;
  final String mediaType;
  final String? gitBlobOid;
  final Set<String> kinds;

  bool sameBytes(_GDevelopCatalogExpectedArtifact other) =>
      repository == other.repository &&
      commit == other.commit &&
      rootTreeSha == other.rootTreeSha &&
      path == other.path &&
      size == other.size &&
      sha256 == other.sha256 &&
      mediaType == other.mediaType &&
      gitBlobOid == other.gitBlobOid;

  _GDevelopCatalogExpectedArtifact withKinds(Set<String> value) =>
      _GDevelopCatalogExpectedArtifact(
        repository: repository,
        commit: commit,
        rootTreeSha: rootTreeSha,
        path: path,
        size: size,
        sha256: sha256,
        mediaType: mediaType,
        gitBlobOid: gitBlobOid,
        kinds: value,
      );

  bool matches(GDevelopCatalogArtifactRequest request) =>
      kinds.contains(request.kind) &&
      repository == request.repository &&
      commit == request.commit &&
      rootTreeSha == request.rootTreeSha &&
      path == request.path &&
      size == request.declaredBytes &&
      sha256 == request.sha256 &&
      mediaType == request.mediaType &&
      gitBlobOid == request.gitBlobOid;
}
