import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' hide XFile;

import 'developer_native_file_save.dart';
import 'developer_native_file_save_service_contract.dart';

typedef DeveloperNativeSaveLocationPicker =
    Future<FileSaveLocation?> Function(
      String suggestedName,
      List<XTypeGroup> acceptedTypeGroups,
    );
typedef DeveloperNativeShareFile =
    Future<DeveloperNativeShareDisposition> Function(
      File file,
      String filename,
      String mimeType,
      Rect? sharePositionOrigin,
    );
typedef DeveloperNativeTemporaryDirectory = Future<Directory> Function();

enum DeveloperNativeShareDisposition { accepted, cancelled, unavailable }

DeveloperNativeFileSaveService createDeveloperNativeFileSaveService() =>
    DeveloperNativeFileSaveServiceIo();

final class DeveloperNativeFileSaveServiceIo
    implements DeveloperNativeFileSaveService {
  DeveloperNativeFileSaveServiceIo({
    DeveloperNativeSaveLocationPicker? saveLocationPicker,
    DeveloperNativeShareFile? shareFile,
    DeveloperNativeTemporaryDirectory? temporaryDirectory,
    HttpClient Function()? httpClientFactory,
    DateTime Function()? clock,
  }) : _saveLocationPicker = saveLocationPicker ?? _defaultSaveLocationPicker,
       _shareFile = shareFile ?? _defaultShareFile,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _clock = clock ?? DateTime.now;

  final DeveloperNativeSaveLocationPicker _saveLocationPicker;
  final DeveloperNativeShareFile _shareFile;
  final DeveloperNativeTemporaryDirectory _temporaryDirectory;
  final HttpClient Function() _httpClientFactory;
  final DateTime Function() _clock;

  @override
  Future<DeveloperNativeFileSaveResult> save({
    required DeveloperNativeFileSaveMessage message,
    required Uri workspaceUri,
    Rect? sharePositionOrigin,
  }) async {
    if (message.kind != DeveloperNativeFileSaveMessageKind.ready ||
        message.downloadPath == null ||
        message.filename == null ||
        message.mimeType == null ||
        message.size == null) {
      throw const FormatException('原生保存消息不是可下载的 ready 消息');
    }
    final transferUri = workspaceUri.resolve(message.downloadPath!);
    _validateTransferUri(workspaceUri, transferUri);
    final token = workspaceUri.queryParameters['token']?.trim() ?? '';
    if (token.isEmpty) throw const FormatException('开发者会话 Token 缺失');

    try {
      if (Platform.isAndroid || Platform.isIOS) {
        return await _shareOnMobile(
          message: message,
          transferUri: transferUri,
          token: token,
          sharePositionOrigin: sharePositionOrigin,
        );
      }
      return await _saveOnDesktop(
        message: message,
        transferUri: transferUri,
        token: token,
      );
    } finally {
      await _release(transferUri, token);
    }
  }

  Future<DeveloperNativeFileSaveResult> _saveOnDesktop({
    required DeveloperNativeFileSaveMessage message,
    required Uri transferUri,
    required String token,
  }) async {
    final extension = _filenameExtension(message.filename!);
    final location = await _saveLocationPicker(message.filename!, [
      XTypeGroup(label: 'File', extensions: [extension]),
    ]);
    if (location == null) {
      return const DeveloperNativeFileSaveResult(
        DeveloperNativeFileSaveOutcome.cancelled,
      );
    }

    final destination = File(location.path);
    final partial = File(
      '${destination.path}.playmesh-part-${message.transferId}',
    );
    try {
      await _download(
        transferUri,
        token,
        partial,
        expectedLength: message.size!,
      );
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
      return DeveloperNativeFileSaveResult(
        DeveloperNativeFileSaveOutcome.saved,
        path: destination.path,
      );
    } on Object {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  Future<DeveloperNativeFileSaveResult> _shareOnMobile({
    required DeveloperNativeFileSaveMessage message,
    required Uri transferUri,
    required String token,
    required Rect? sharePositionOrigin,
  }) async {
    final root = Directory(
      '${(await _temporaryDirectory()).path}${Platform.pathSeparator}'
      'playmesh-native-file-saves',
    );
    await root.create(recursive: true);
    await _cleanupStaleMobileFiles(root);
    final destination = File(
      '${root.path}${Platform.pathSeparator}'
      '${message.transferId}-${message.filename}',
    );
    try {
      await _download(
        transferUri,
        token,
        destination,
        expectedLength: message.size!,
      );
      final disposition = await _shareFile(
        destination,
        message.filename!,
        message.mimeType!,
        sharePositionOrigin,
      );
      if (disposition == DeveloperNativeShareDisposition.cancelled) {
        if (await destination.exists()) await destination.delete();
        return const DeveloperNativeFileSaveResult(
          DeveloperNativeFileSaveOutcome.cancelled,
        );
      }
      // The receiver can open the content URI after the share call returns.
      // Retain it briefly; the next export removes stale files.
      return DeveloperNativeFileSaveResult(
        DeveloperNativeFileSaveOutcome.shared,
        path: destination.path,
      );
    } on Object {
      if (await destination.exists()) await destination.delete();
      rethrow;
    }
  }

  Future<void> _download(
    Uri transferUri,
    String token,
    File destination, {
    required int expectedLength,
  }) async {
    final client = _httpClientFactory();
    RandomAccessFile? output;
    try {
      final request = await client.getUrl(transferUri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          '原生保存下载失败（HTTP ${response.statusCode}）',
          uri: transferUri,
        );
      }
      if (response.contentLength >= 0 &&
          response.contentLength != expectedLength) {
        await response.drain<void>();
        throw const FormatException('原生保存文件长度与暂存回执不一致');
      }
      output = await destination.open(mode: FileMode.writeOnly);
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (received > expectedLength) {
          throw const FormatException('原生保存下载超过暂存回执长度');
        }
        await output.writeFrom(chunk);
      }
      if (received != expectedLength) {
        throw const FormatException('原生保存下载未完整接收');
      }
      await output.flush();
      await output.close();
      output = null;
    } finally {
      if (output != null) {
        try {
          await output.close();
        } on Object {
          // Preserve the original transfer error.
        }
      }
      client.close(force: true);
    }
  }

  Future<void> _release(Uri transferUri, String token) async {
    final client = _httpClientFactory();
    try {
      final request = await client.deleteUrl(transferUri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      await response.drain<void>();
    } on Object {
      // Gateway TTL and session shutdown are the final cleanup backstops.
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _cleanupStaleMobileFiles(Directory root) async {
    final cutoff = _clock().subtract(const Duration(days: 1));
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File) continue;
      try {
        if ((await entity.lastModified()).isBefore(cutoff)) {
          await entity.delete();
        }
      } on Object {
        // Best effort: a receiving app can still have the content URI open.
      }
    }
  }
}

Future<FileSaveLocation?> _defaultSaveLocationPicker(
  String suggestedName,
  List<XTypeGroup> acceptedTypeGroups,
) => getSaveLocation(
  suggestedName: suggestedName,
  acceptedTypeGroups: acceptedTypeGroups,
);

Future<DeveloperNativeShareDisposition> _defaultShareFile(
  File file,
  String filename,
  String mimeType,
  Rect? sharePositionOrigin,
) async {
  final result = await SharePlus.instance.share(
    ShareParams(
      files: [XFile(file.path, mimeType: mimeType)],
      fileNameOverrides: [filename],
      sharePositionOrigin: sharePositionOrigin,
    ),
  );
  return switch (result.status) {
    ShareResultStatus.success => DeveloperNativeShareDisposition.accepted,
    ShareResultStatus.dismissed => DeveloperNativeShareDisposition.cancelled,
    ShareResultStatus.unavailable =>
      DeveloperNativeShareDisposition.unavailable,
  };
}

String _filenameExtension(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot > 0 && dot < filename.length - 1) {
    final extension = filename.substring(dot + 1).toLowerCase();
    if (RegExp(r'^[a-z0-9]{1,16}$').hasMatch(extension)) return extension;
  }
  return 'bin';
}

void _validateTransferUri(Uri workspaceUri, Uri transferUri) {
  if (transferUri.scheme != workspaceUri.scheme ||
      transferUri.host != workspaceUri.host ||
      transferUri.port != workspaceUri.port ||
      !transferUri.path.startsWith('/dev/api/gdevelop/native-file-saves/') ||
      transferUri.hasQuery ||
      transferUri.hasFragment) {
    throw const FormatException('原生保存下载地址不属于当前开发者网关');
  }
}
