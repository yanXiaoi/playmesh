import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart' hide XFile;

import '../game_package/game_package_share_files.dart';
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
typedef DeveloperNativeBackupFileDelete = Future<void> Function(File file);

enum DeveloperNativeShareDisposition { accepted, cancelled, unavailable }

DeveloperNativeFileSaveService createDeveloperNativeFileSaveService() =>
    DeveloperNativeFileSaveServiceIo();

final class DeveloperNativeFileSaveServiceIo
    implements DeveloperNativeFileSaveService {
  DeveloperNativeFileSaveServiceIo({
    DeveloperNativeSaveLocationPicker? saveLocationPicker,
    DeveloperNativeShareFile? shareFile,
    DeveloperNativeTemporaryDirectory? temporaryDirectory,
    DeveloperNativeBackupFileDelete? backupFileDelete,
    HttpClient Function()? httpClientFactory,
    DateTime Function()? clock,
    bool? shareOnMobile,
  }) : _saveLocationPicker = saveLocationPicker ?? _defaultSaveLocationPicker,
       _shareFile = shareFile ?? _defaultShareFile,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _backupFileDelete = backupFileDelete ?? _defaultBackupFileDelete,
       _httpClientFactory = httpClientFactory ?? HttpClient.new,
       _clock = clock ?? DateTime.now,
       _useMobileShare =
           shareOnMobile ?? (Platform.isAndroid || Platform.isIOS);

  final DeveloperNativeSaveLocationPicker _saveLocationPicker;
  final DeveloperNativeShareFile _shareFile;
  final DeveloperNativeTemporaryDirectory _temporaryDirectory;
  final DeveloperNativeBackupFileDelete _backupFileDelete;
  final HttpClient Function() _httpClientFactory;
  final DateTime Function() _clock;
  final bool _useMobileShare;

  @override
  Future<DeveloperNativeFileSaveResult> save({
    required DeveloperNativeFileSaveMessage message,
    required Uri workspaceUri,
    Rect? sharePositionOrigin,
  }) async {
    final staged = message.kind == DeveloperNativeFileSaveMessageKind.ready;
    final installationPackage =
        message.kind == DeveloperNativeFileSaveMessageKind.download &&
        message.downloadPath != null &&
        parseDeveloperInstallationPackageDownloadPath(message.downloadPath!) !=
            null;
    if ((!staged &&
            message.kind != DeveloperNativeFileSaveMessageKind.download) ||
        message.downloadPath == null ||
        message.mimeType == null ||
        ((staged || installationPackage) &&
            (message.filename == null || message.size == null))) {
      throw const FormatException('原生保存消息不是可下载消息');
    }
    final transferUri = workspaceUri.resolve(message.downloadPath!);
    if (staged) {
      _validateTransferUri(workspaceUri, transferUri);
    } else if (installationPackage) {
      _validateInstallationPackageUri(workspaceUri, transferUri);
    } else {
      _validateProjectPackageUri(workspaceUri, transferUri);
    }
    final token = workspaceUri.queryParameters['token']?.trim() ?? '';
    if (token.isEmpty) throw const FormatException('开发者会话 Token 缺失');
    final filename = staged || installationPackage
        ? message.filename!
        : await _projectPackageFilename(
            workspaceUri: workspaceUri,
            transferUri: transferUri,
            token: token,
          );

    try {
      if (_useMobileShare) {
        return await _shareOnMobile(
          message: message,
          filename: filename,
          transferUri: transferUri,
          token: token,
          sharePositionOrigin: sharePositionOrigin,
        );
      }
      return await _saveOnDesktop(
        message: message,
        filename: filename,
        transferUri: transferUri,
        token: token,
      );
    } finally {
      if (staged || installationPackage) {
        await _release(transferUri, token);
      }
    }
  }

  Future<DeveloperNativeFileSaveResult> _saveOnDesktop({
    required DeveloperNativeFileSaveMessage message,
    required String filename,
    required Uri transferUri,
    required String token,
  }) async {
    final extension = _filenameExtension(filename);
    final location = await _saveLocationPicker(filename, [
      XTypeGroup(label: 'File', extensions: [extension]),
    ]);
    if (location == null) {
      return const DeveloperNativeFileSaveResult(
        DeveloperNativeFileSaveOutcome.cancelled,
      );
    }

    final destination = File(location.path);
    final partial = File(
      '${destination.path}.playmesh-part-'
      '${message.transferId ?? message.requestId}',
    );
    File? backup;
    try {
      await _download(
        transferUri,
        token,
        partial,
        expectedLength: message.size,
      );
      if (await destination.exists()) {
        backup = File(
          '${destination.path}.playmesh-backup-'
          '${message.transferId ?? message.requestId}',
        );
        if (await backup.exists()) await backup.delete();
        await destination.rename(backup.path);
      }
      await partial.rename(destination.path);
    } on Object {
      if (await partial.exists()) await partial.delete();
      if (backup != null &&
          !await destination.exists() &&
          await backup.exists()) {
        await backup.rename(destination.path);
      }
      rethrow;
    }
    if (backup != null) await _cleanupCommittedBackup(backup);
    return DeveloperNativeFileSaveResult(
      DeveloperNativeFileSaveOutcome.saved,
      path: destination.path,
    );
  }

  Future<DeveloperNativeFileSaveResult> _shareOnMobile({
    required DeveloperNativeFileSaveMessage message,
    required String filename,
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
    final operationDirectory = await root.createTemp('save-');
    final extension = _filenameExtension(filename);
    final destination = File(
      '${operationDirectory.path}${Platform.pathSeparator}payload.$extension',
    );
    try {
      await _download(
        transferUri,
        token,
        destination,
        expectedLength: message.size,
      );
      final disposition = await _shareFile(
        destination,
        filename,
        message.mimeType!,
        sharePositionOrigin,
      );
      if (disposition == DeveloperNativeShareDisposition.cancelled) {
        await _deleteDirectoryBestEffort(operationDirectory);
        return const DeveloperNativeFileSaveResult(
          DeveloperNativeFileSaveOutcome.cancelled,
        );
      }
      // 接收方可能在分享调用返回后才打开内容 URI，因此短暂保留文件，
      // 并在下一次导出时移除过期文件。
      return DeveloperNativeFileSaveResult(
        DeveloperNativeFileSaveOutcome.shared,
        path: destination.path,
      );
    } on Object {
      await _deleteDirectoryBestEffort(operationDirectory);
      rethrow;
    }
  }

  Future<void> _cleanupCommittedBackup(File backup) async {
    for (var attempt = 0; attempt < 2; attempt += 1) {
      try {
        if (!await backup.exists()) return;
        await _backupFileDelete(backup);
        return;
      } on Object {
        if (attempt == 0) await Future<void>.delayed(Duration.zero);
      }
    }
  }

  Future<String> _projectPackageFilename({
    required Uri workspaceUri,
    required Uri transferUri,
    required String token,
  }) async {
    final packageUri = parseDeveloperProjectPackageDownloadPath(
      transferUri.path,
    );
    if (packageUri == null) {
      throw const FormatException('项目包下载地址无效');
    }
    final projectId = packageUri.pathSegments[3];
    final projectsUri = workspaceUri.resolve('/dev/api/projects');
    final client = _httpClientFactory();
    try {
      final request = await client.getUrl(projectsUri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw HttpException(
          '读取项目导出文件名失败（HTTP ${response.statusCode}）',
          uri: projectsUri,
        );
      }
      final decoded = jsonDecode(await utf8.decoder.bind(response).join());
      if (decoded is! Map || decoded['projects'] is! List) {
        throw const FormatException('项目列表响应格式无效');
      }
      Map<Object?, Object?>? selected;
      for (final candidate in decoded['projects'] as List) {
        if (candidate is Map && candidate['id'] == projectId) {
          selected = candidate.cast<Object?, Object?>();
          break;
        }
      }
      if (selected == null) throw const FormatException('项目列表中不存在待导出项目');
      final name = selected['name']?.toString() ?? '';
      final version = selected['version']?.toString() ?? '';
      return gamePackageFileName(name: name, version: version);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _download(
    Uri transferUri,
    String token,
    File destination, {
    required int? expectedLength,
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
      if (expectedLength != null &&
          response.contentLength >= 0 &&
          response.contentLength != expectedLength) {
        await response.drain<void>();
        throw const FormatException('原生保存文件长度与暂存回执不一致');
      }
      final verifiedLength =
          expectedLength ??
          (response.contentLength >= 0 ? response.contentLength : null);
      output = await destination.open(mode: FileMode.writeOnly);
      var received = 0;
      await for (final chunk in response) {
        received += chunk.length;
        if (verifiedLength != null && received > verifiedLength) {
          throw const FormatException('原生保存下载超过暂存回执长度');
        }
        await output.writeFrom(chunk);
      }
      if (verifiedLength != null && received != verifiedLength) {
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
          // 保留原始传输错误。
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
      // Gateway TTL 与会话关闭仍是最终清理兜底。
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _cleanupStaleMobileFiles(Directory root) async {
    final cutoff = _clock().subtract(const Duration(days: 1));
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! File && entity is! Directory) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete(recursive: entity is Directory);
        }
      } on Object {
        // 尽力清理：接收方此时仍可能持有内容 URI。
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

Future<void> _defaultBackupFileDelete(File file) => file.delete();

Future<void> _deleteDirectoryBestEffort(Directory directory) async {
  try {
    if (await directory.exists()) await directory.delete(recursive: true);
  } on Object {
    // 后续过期清理仍会处理未能立即移除的移动端临时目录。
  }
}

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

void _validateProjectPackageUri(Uri workspaceUri, Uri packageUri) {
  if (packageUri.scheme != workspaceUri.scheme ||
      packageUri.host != workspaceUri.host ||
      packageUri.port != workspaceUri.port ||
      parseDeveloperProjectPackageDownloadPath(packageUri.path) == null ||
      packageUri.hasQuery ||
      packageUri.hasFragment) {
    throw const FormatException('项目包下载地址不属于当前开发者网关');
  }
}

void _validateInstallationPackageUri(Uri workspaceUri, Uri packageUri) {
  if (packageUri.scheme != workspaceUri.scheme ||
      packageUri.host != workspaceUri.host ||
      packageUri.port != workspaceUri.port ||
      parseDeveloperInstallationPackageDownloadPath(packageUri.path) == null ||
      packageUri.hasQuery ||
      packageUri.hasFragment) {
    throw const FormatException('安装包下载地址不属于当前开发者网关');
  }
}
