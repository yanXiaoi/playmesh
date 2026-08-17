import 'dart:async';
import 'dart:io';

class PackageUploadTooLarge implements Exception {
  const PackageUploadTooLarge(this.limit);

  final int limit;
}

class PackageUploadEmpty implements Exception {
  const PackageUploadEmpty();
}

class TemporaryPackageUpload {
  const TemporaryPackageUpload(
    this._temporaryDirectory, {
    required this.file,
    required this.length,
  });

  final File file;
  final int length;
  final Directory _temporaryDirectory;

  Future<void> dispose() async {
    if (await _temporaryDirectory.exists()) {
      await _temporaryDirectory.delete(recursive: true);
    }
  }
}

/// 将上传流直接落盘；内存中只保留当前网络 chunk。
class PackageUploadSpooler {
  const PackageUploadSpooler({
    required this.maxBytes,
    this.inactivityTimeout = const Duration(seconds: 30),
    this.temporaryRoot,
  });

  final int maxBytes;
  final Duration inactivityTimeout;
  final Directory? temporaryRoot;

  Future<TemporaryPackageUpload> spool(
    Stream<List<int>> input, {
    int? declaredLength,
  }) async {
    if (declaredLength == 0) throw const PackageUploadEmpty();
    if (declaredLength != null && declaredLength > maxBytes) {
      throw PackageUploadTooLarge(maxBytes);
    }
    final directory = await (temporaryRoot ?? Directory.systemTemp).createTemp(
      'playmesh-package-upload-',
    );
    final file = File(
      '${directory.path}${Platform.pathSeparator}package.playmesh.zip',
    );
    RandomAccessFile? output;
    var length = 0;
    try {
      output = await file.open(mode: FileMode.writeOnly);
      await for (final chunk in input.timeout(inactivityTimeout)) {
        if (chunk.isEmpty) continue;
        final nextLength = length + chunk.length;
        if (nextLength > maxBytes) throw PackageUploadTooLarge(maxBytes);
        await output.writeFrom(chunk);
        length = nextLength;
      }
      if (length == 0) throw const PackageUploadEmpty();
      await output.flush();
      await output.close();
      output = null;
      return TemporaryPackageUpload(directory, file: file, length: length);
    } on Object {
      if (output != null) {
        try {
          await output.close();
        } on Object {
          // 保留上传流原始错误。
        }
      }
      if (await directory.exists()) await directory.delete(recursive: true);
      rethrow;
    }
  }
}
