import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'verified_resumable_download_contract.dart';

VerifiedResumableDownloader createVerifiedResumableDownloader({
  required int maxDownloadBytes,
  required Duration connectTimeout,
  required Duration idleTimeout,
}) => IoVerifiedResumableDownloader(
  maxDownloadBytes: maxDownloadBytes,
  connectTimeout: connectTimeout,
  idleTimeout: idleTimeout,
);

class IoVerifiedResumableDownloader implements VerifiedResumableDownloader {
  IoVerifiedResumableDownloader({
    HttpClient? client,
    this.maxDownloadBytes = 4 * 1024 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
    this.reserveBytes = 64 * 1024 * 1024,
    this.availableBytes,
  }) : assert(maxDownloadBytes > 0),
       assert(connectTimeout > Duration.zero),
       assert(idleTimeout > Duration.zero),
       assert(reserveBytes >= 0),
       _client = client ?? HttpClient() {
    _client.autoUncompress = false;
  }

  @visibleForTesting
  IoVerifiedResumableDownloader.allowHttpForTesting({
    HttpClient? client,
    this.maxDownloadBytes = 4 * 1024 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
    this.reserveBytes = 0,
    this.availableBytes,
  }) : _client = client ?? HttpClient() {
    _client.autoUncompress = false;
  }

  final int maxDownloadBytes;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final int reserveBytes;
  final Future<int?> Function(String rootPath)? availableBytes;
  final HttpClient _client;
  var _closed = false;

  @override
  Future<VerifiedDownloadResult> download({
    required String downloadRootPath,
    required VerifiedDownloadSpec spec,
    bool reuseCompleted = true,
    VerifiedDownloadProgressCallback? onProgress,
    DownloadCancellationToken? cancellationToken,
  }) async {
    _validateSpec(spec);
    cancellationToken?.throwIfCancellationRequested();
    if (_closed) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.network,
        diagnostic: 'download_client_closed',
      );
    }
    final freeBytes = await availableBytes?.call(downloadRootPath);
    if (freeBytes != null && freeBytes < spec.size + reserveBytes) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.quota,
        diagnostic: 'download_insufficient_space',
      );
    }

    final root = Directory(downloadRootPath);
    await root.create(recursive: true);
    await _discardOtherArtifacts(root, spec.sha256);
    final partial = File(
      '${root.path}${Platform.pathSeparator}${spec.sha256}.partial',
    );
    final metadata = File(
      '${root.path}${Platform.pathSeparator}${spec.sha256}.json',
    );
    final completed = File(
      '${root.path}${Platform.pathSeparator}${spec.sha256}.zip',
    );
    if (!reuseCompleted && await completed.exists()) {
      await completed.delete();
    }
    if (reuseCompleted && await completed.exists()) {
      if (await _matches(completed, spec)) {
        onProgress?.call(
          VerifiedDownloadProgress(
            receivedBytes: spec.size,
            totalBytes: spec.size,
          ),
        );
        return VerifiedDownloadResult(
          filePath: completed.path,
          bytes: spec.size,
          sha256: spec.sha256,
          resumed: true,
        );
      }
      await completed.delete();
    }

    var state = await _readResumeState(metadata);
    if (!await partial.exists() ||
        state == null ||
        state.sha256 != spec.sha256 ||
        state.url != spec.endpoint.url.toString() ||
        state.size != spec.size) {
      await _discard(partial, metadata);
      state = null;
    }
    var existingBytes = await partial.exists() ? await partial.length() : 0;
    if (existingBytes > spec.size) {
      await _discard(partial, metadata);
      state = null;
      existingBytes = 0;
    }
    if (existingBytes == spec.size && existingBytes > 0) {
      if (await _matches(partial, spec)) {
        await partial.rename(completed.path);
        if (await metadata.exists()) await metadata.delete();
        return VerifiedDownloadResult(
          filePath: completed.path,
          bytes: spec.size,
          sha256: spec.sha256,
          resumed: true,
        );
      }
      await _discard(partial, metadata);
      state = null;
      existingBytes = 0;
    }

    var usedResume = false;
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        final outcome = await _transfer(
          partial: partial,
          metadata: metadata,
          spec: spec,
          state: state,
          existingBytes: existingBytes,
          onProgress: onProgress,
          cancellationToken: cancellationToken,
        );
        if (outcome.retryFresh) {
          await _discard(partial, metadata);
          state = null;
          existingBytes = 0;
          continue;
        }
        usedResume = outcome.usedResume;
        break;
      } on VerifiedDownloadException catch (error) {
        if (error.kind == VerifiedDownloadFailureKind.invalidResponse ||
            error.kind == VerifiedDownloadFailureKind.sha256Mismatch ||
            error.diagnostic == 'download_stream_exceeded_size') {
          await _discard(partial, metadata);
        }
        rethrow;
      }
    }

    if (!await partial.exists() || await partial.length() != spec.size) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.sizeMismatch,
        diagnostic: 'download_final_size_mismatch',
      );
    }
    final actualSha256 = await _sha256(partial);
    if (actualSha256 != spec.sha256) {
      await _discard(partial, metadata);
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.sha256Mismatch,
        diagnostic: 'download_sha256_mismatch',
      );
    }
    await partial.rename(completed.path);
    if (await metadata.exists()) await metadata.delete();
    onProgress?.call(
      VerifiedDownloadProgress(receivedBytes: spec.size, totalBytes: spec.size),
    );
    return VerifiedDownloadResult(
      filePath: completed.path,
      bytes: spec.size,
      sha256: actualSha256,
      resumed: usedResume,
    );
  }

  Future<_TransferOutcome> _transfer({
    required File partial,
    required File metadata,
    required VerifiedDownloadSpec spec,
    required _ResumeState? state,
    required int existingBytes,
    required VerifiedDownloadProgressCallback? onProgress,
    required DownloadCancellationToken? cancellationToken,
  }) async {
    HttpClientRequest? request;
    IOSink? output;
    try {
      request = await _client.getUrl(spec.endpoint.url).timeout(connectTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (existingBytes > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existingBytes-');
        final validator = state?.etag ?? state?.lastModified;
        if (validator != null) {
          request.headers.set(HttpHeaders.ifRangeHeader, validator);
        }
      }
      final response = await request.close().timeout(connectTimeout);
      if (existingBytes > 0 && response.statusCode == 416) {
        await _cancelResponse(response);
        return const _TransferOutcome(retryFresh: true, usedResume: false);
      }
      var append = existingBytes > 0 && response.statusCode == 206;
      if (existingBytes > 0 && response.statusCode == HttpStatus.ok) {
        append = false;
        existingBytes = 0;
      } else if (append) {
        _validateContentRange(response, existingBytes, spec.size);
      } else if (response.statusCode != HttpStatus.ok) {
        await _cancelResponse(response);
        throw VerifiedDownloadException(
          kind: VerifiedDownloadFailureKind.http,
          diagnostic: 'download_http_${response.statusCode}',
          httpStatus: response.statusCode,
        );
      }

      final expectedResponseBytes = spec.size - existingBytes;
      if (response.contentLength >= 0 &&
          response.contentLength != expectedResponseBytes) {
        await _cancelResponse(response);
        throw const VerifiedDownloadException(
          kind: VerifiedDownloadFailureKind.invalidResponse,
          diagnostic: 'download_content_length_mismatch',
        );
      }
      final nextState = _ResumeState(
        sha256: spec.sha256,
        url: spec.endpoint.url.toString(),
        size: spec.size,
        etag: response.headers.value(HttpHeaders.etagHeader),
        lastModified: response.headers.value(HttpHeaders.lastModifiedHeader),
      );
      await _writeResumeState(metadata, nextState);
      output = partial.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = existingBytes;
      onProgress?.call(
        VerifiedDownloadProgress(
          receivedBytes: received,
          totalBytes: spec.size,
        ),
      );
      await for (final chunk in response.timeout(idleTimeout)) {
        cancellationToken?.throwIfCancellationRequested();
        received += chunk.length;
        if (received > spec.size) {
          throw const VerifiedDownloadException(
            kind: VerifiedDownloadFailureKind.sizeMismatch,
            diagnostic: 'download_stream_exceeded_size',
          );
        }
        output.add(chunk);
        onProgress?.call(
          VerifiedDownloadProgress(
            receivedBytes: received,
            totalBytes: spec.size,
          ),
        );
        cancellationToken?.throwIfCancellationRequested();
      }
      await output.flush();
      await output.close();
      output = null;
      if (received != spec.size) {
        throw const VerifiedDownloadException(
          kind: VerifiedDownloadFailureKind.sizeMismatch,
          diagnostic: 'download_stream_ended_early',
        );
      }
      return _TransferOutcome(retryFresh: false, usedResume: append);
    } on VerifiedDownloadException {
      rethrow;
    } on TimeoutException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const VerifiedDownloadException(
          kind: VerifiedDownloadFailureKind.cancelled,
          diagnostic: 'download_cancelled',
        );
      }
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.timeout,
        diagnostic: 'download_timeout',
      );
    } on SocketException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const VerifiedDownloadException(
          kind: VerifiedDownloadFailureKind.cancelled,
          diagnostic: 'download_cancelled',
        );
      }
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.network,
        diagnostic: 'download_network_error',
      );
    } on HttpException {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.network,
        diagnostic: 'download_http_client_error',
      );
    } finally {
      if (output != null) {
        try {
          await output.flush();
          await output.close();
        } on Object {
          // 保留已经刷盘的部分文件，供后续经过校验的断点续传使用。
        }
      }
      if (cancellationToken?.isCancelled ?? false) request?.abort();
    }
  }

  void _validateSpec(VerifiedDownloadSpec spec) {
    if (spec.size <= 0 || spec.size > maxDownloadBytes) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.quota,
        diagnostic: 'download_size_exceeds_limit',
      );
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(spec.sha256)) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.invalidResponse,
        diagnostic: 'download_invalid_sha256',
      );
    }
  }

  void _validateContentRange(
    HttpClientResponse response,
    int expectedStart,
    int expectedTotal,
  ) {
    final value = response.headers.value(HttpHeaders.contentRangeHeader);
    final match = value == null
        ? null
        : RegExp(r'^bytes ([0-9]+)-([0-9]+)/([0-9]+)$').firstMatch(value);
    if (match == null ||
        int.tryParse(match.group(1)!) != expectedStart ||
        int.tryParse(match.group(2)!) != expectedTotal - 1 ||
        int.tryParse(match.group(3)!) != expectedTotal) {
      throw const VerifiedDownloadException(
        kind: VerifiedDownloadFailureKind.invalidResponse,
        diagnostic: 'download_invalid_content_range',
      );
    }
  }

  Future<bool> _matches(File file, VerifiedDownloadSpec spec) async =>
      await file.length() == spec.size && await _sha256(file) == spec.sha256;

  Future<String> _sha256(File file) async {
    final sink = Sha256().toSync().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final hash = await sink.hash();
    return hash.bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<_ResumeState?> _readResumeState(File file) async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map ||
          decoded.keys.toSet().difference(const {
            'sha256',
            'url',
            'size',
            'etag',
            'lastModified',
          }).isNotEmpty ||
          !decoded.keys.toSet().containsAll(const {
            'sha256',
            'url',
            'size',
            'etag',
            'lastModified',
          })) {
        return null;
      }
      final sha256 = decoded['sha256'];
      final url = decoded['url'];
      final size = decoded['size'];
      final etag = decoded['etag'];
      final lastModified = decoded['lastModified'];
      if (sha256 is! String ||
          url is! String ||
          size is! int ||
          (etag != null && etag is! String) ||
          (lastModified != null && lastModified is! String)) {
        return null;
      }
      return _ResumeState(
        sha256: sha256,
        url: url,
        size: size,
        etag: etag as String?,
        lastModified: lastModified as String?,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeResumeState(File file, _ResumeState state) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(state.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temporary.rename(file.path);
  }

  Future<void> _discardOtherArtifacts(Directory root, String sha256) async {
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (name.startsWith('$sha256.') || name == '$sha256.json.tmp') continue;
      if (name.endsWith('.partial') ||
          name.endsWith('.json') ||
          name.endsWith('.zip') ||
          name.endsWith('.json.tmp')) {
        await entity.delete();
      }
    }
  }

  Future<void> _discard(File partial, File metadata) async {
    if (await partial.exists()) await partial.delete();
    if (await metadata.exists()) await metadata.delete();
    final temporaryMetadata = File('${metadata.path}.tmp');
    if (await temporaryMetadata.exists()) await temporaryMetadata.delete();
  }

  Future<void> _cancelResponse(HttpClientResponse response) async {
    try {
      final subscription = response.listen((_) {}, onError: (_) {});
      await subscription.cancel();
    } on Object {
      // 即使取消失败，也要保留已经分类的协议错误。
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}

class _ResumeState {
  const _ResumeState({
    required this.sha256,
    required this.url,
    required this.size,
    required this.etag,
    required this.lastModified,
  });

  final String sha256;
  final String url;
  final int size;
  final String? etag;
  final String? lastModified;

  Map<String, Object?> toJson() => {
    'sha256': sha256,
    'url': url,
    'size': size,
    'etag': etag,
    'lastModified': lastModified,
  };
}

class _TransferOutcome {
  const _TransferOutcome({required this.retryFresh, required this.usedResume});

  final bool retryFresh;
  final bool usedResume;
}
