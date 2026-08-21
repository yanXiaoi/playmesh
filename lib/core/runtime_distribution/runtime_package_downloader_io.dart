import 'dart:async';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'runtime_package_downloader_contract.dart';
import 'runtime_package_models.dart';

final class IoRuntimePackageDownloader implements RuntimePackageDownloader {
  IoRuntimePackageDownloader({
    HttpClient? client,
    this.maxBytes = 1024 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : assert(maxBytes > 0),
       assert(connectTimeout > Duration.zero),
       assert(idleTimeout > Duration.zero),
       _client = client ?? HttpClient() {
    _client.autoUncompress = false;
  }

  @visibleForTesting
  IoRuntimePackageDownloader.allowHttpForTesting({
    HttpClient? client,
    this.maxBytes = 1024 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 15),
    this.idleTimeout = const Duration(seconds: 30),
  }) : assert(maxBytes > 0),
       assert(connectTimeout > Duration.zero),
       assert(idleTimeout > Duration.zero),
       _client = client ?? HttpClient() {
    _client.autoUncompress = false;
  }

  final int maxBytes;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final HttpClient _client;
  var _closed = false;

  @override
  Future<RuntimePackageDownloadResult> download({
    required RuntimePackageDownloadEndpoint endpoint,
    required String downloadDirectoryPath,
    RuntimePackageDownloadProgressCallback? onProgress,
    RuntimePackageDownloadCancellationToken? cancellationToken,
  }) async {
    cancellationToken?.throwIfCancellationRequested();
    if (_closed) {
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.network,
        diagnostic: 'runtime_package_downloader_closed',
      );
    }
    final url = endpoint.url;
    if (!endpoint.downloadable || url == null) {
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.unavailable,
        diagnostic: 'runtime_package_download_unavailable',
      );
    }
    final directory = Directory(downloadDirectoryPath).absolute;
    await directory.create(recursive: true);
    final temporary = File(
      '${directory.path}${Platform.pathSeparator}.${endpoint.sha256}.download',
    );
    if (await temporary.exists()) await temporary.delete();

    HttpClientRequest? request;
    IOSink? output;
    var hashClosed = false;
    var completed = false;
    final hashSink = Sha256().toSync().newHashSink();
    final removeCancellationListener = cancellationToken
        ?.addCancellationListener(() => request?.abort());
    try {
      cancellationToken?.throwIfCancellationRequested();
      request = await _client.getUrl(url).timeout(connectTimeout);
      request.followRedirects = true;
      request.maxRedirects = 5;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(connectTimeout);
      if (response.statusCode != HttpStatus.ok) {
        await _cancelResponse(response);
        throw RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.http,
          diagnostic: 'runtime_package_download_http_${response.statusCode}',
          httpStatus: response.statusCode,
        );
      }
      final declaredLength = response.contentLength;
      if (declaredLength > maxBytes) {
        await _cancelResponse(response);
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.tooLarge,
          diagnostic: 'runtime_package_download_content_length_exceeded',
        );
      }
      final totalBytes = declaredLength >= 0 ? declaredLength : null;
      output = temporary.openWrite(mode: FileMode.write);
      var receivedBytes = 0;
      onProgress?.call(
        RuntimePackageDownloadProgress(
          receivedBytes: receivedBytes,
          totalBytes: totalBytes,
        ),
      );
      await for (final chunk in response.timeout(idleTimeout)) {
        cancellationToken?.throwIfCancellationRequested();
        receivedBytes += chunk.length;
        if (receivedBytes > maxBytes) {
          throw const RuntimePackageDownloadException(
            kind: RuntimePackageDownloadFailureKind.tooLarge,
            diagnostic: 'runtime_package_download_stream_limit_exceeded',
          );
        }
        hashSink.add(chunk);
        output.add(chunk);
        onProgress?.call(
          RuntimePackageDownloadProgress(
            receivedBytes: receivedBytes,
            totalBytes: totalBytes,
          ),
        );
      }
      cancellationToken?.throwIfCancellationRequested();
      await output.flush();
      await output.close();
      output = null;
      if (receivedBytes == 0) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.empty,
          diagnostic: 'runtime_package_download_empty',
        );
      }
      hashSink.close();
      hashClosed = true;
      final digest = await hashSink.hash();
      final sha256 = digest.bytes
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      if (sha256 != endpoint.sha256) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.sha256Mismatch,
          diagnostic: 'runtime_package_download_sha256_mismatch',
        );
      }
      completed = true;
      return RuntimePackageDownloadResult(
        temporaryFilePath: temporary.path,
        bytes: receivedBytes,
        sha256: sha256,
      );
    } on RuntimePackageDownloadException {
      rethrow;
    } on TimeoutException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.cancelled,
          diagnostic: 'runtime_package_download_cancelled',
        );
      }
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.timeout,
        diagnostic: 'runtime_package_download_timeout',
      );
    } on FileSystemException catch (error) {
      throw RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.fileSystem,
        diagnostic:
            'runtime_package_download_file_system:${error.osError?.errorCode}',
      );
    } on HandshakeException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.cancelled,
          diagnostic: 'runtime_package_download_cancelled',
        );
      }
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.network,
        diagnostic: 'runtime_package_download_tls_error',
      );
    } on TlsException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.cancelled,
          diagnostic: 'runtime_package_download_cancelled',
        );
      }
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.network,
        diagnostic: 'runtime_package_download_tls_error',
      );
    } on SocketException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.cancelled,
          diagnostic: 'runtime_package_download_cancelled',
        );
      }
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.network,
        diagnostic: 'runtime_package_download_network_error',
      );
    } on HttpException {
      if (cancellationToken?.isCancelled ?? false) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.cancelled,
          diagnostic: 'runtime_package_download_cancelled',
        );
      }
      throw const RuntimePackageDownloadException(
        kind: RuntimePackageDownloadFailureKind.network,
        diagnostic: 'runtime_package_download_http_client_error',
      );
    } on Object {
      if (cancellationToken?.isCancelled ?? false) {
        throw const RuntimePackageDownloadException(
          kind: RuntimePackageDownloadFailureKind.cancelled,
          diagnostic: 'runtime_package_download_cancelled',
        );
      }
      rethrow;
    } finally {
      removeCancellationListener?.call();
      if (output != null) {
        try {
          await output.flush();
          await output.close();
        } on Object {
          // The private temporary file is deleted below.
        }
      }
      if (!hashClosed) hashSink.close();
      if (cancellationToken?.isCancelled ?? false) request?.abort();
      if (await temporary.exists()) {
        // A successful result leaves the temporary file for the Store's atomic
        // commit. Every exceptional path deletes it here.
        if (!completed) {
          try {
            await temporary.delete();
          } on Object {
            // The next download replaces this deterministic private file.
          }
        }
      }
    }
  }

  Future<void> _cancelResponse(HttpClientResponse response) async {
    try {
      final subscription = response.listen((_) {}, onError: (_) {});
      await subscription.cancel();
    } on Object {
      // Preserve the classified protocol error.
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }
}
