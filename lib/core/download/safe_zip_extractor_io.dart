import 'dart:io';

import 'package:archive/archive_io.dart';

import 'safe_zip_extractor_contract.dart';
import 'verified_resumable_download_contract.dart';

SafeZipExtractor createSafeZipExtractor({
  required SafeZipExtractionPolicy policy,
}) => IoSafeZipExtractor(policy: policy);

class IoSafeZipExtractor implements SafeZipExtractor {
  const IoSafeZipExtractor({this.policy = const SafeZipExtractionPolicy()});

  final SafeZipExtractionPolicy policy;

  @override
  Future<SafeZipExtractionResult> extract({
    required String archivePath,
    required String destinationPath,
    DownloadCancellationToken? cancellationToken,
  }) async {
    final archiveFile = File(archivePath);
    if (!await archiveFile.exists() || await archiveFile.length() <= 0) {
      throw const SafeZipExtractionException('zip_missing_or_empty');
    }
    final destination = Directory(destinationPath);
    if (await destination.exists() && !(await destination.list().isEmpty)) {
      throw const SafeZipExtractionException('zip_destination_not_empty');
    }
    await destination.create(recursive: true);

    final input = InputFileStream(archiveFile.path);
    try {
      final decoder = ZipDecoder();
      final archive = decoder.decodeBuffer(input);
      if (archive.length != decoder.directory.fileHeaders.length) {
        throw const SafeZipExtractionException('zip_directory_mismatch');
      }
      final planned = <({ArchiveFile entry, String path})>[];
      final allPaths = <String, bool>{};
      final caseInsensitivePaths = <String>{};
      var declaredBytes = 0;

      for (var index = 0; index < archive.length; index += 1) {
        cancellationToken?.throwIfCancellationRequested();
        final entry = archive[index];
        final rawName = decoder.directory.fileHeaders[index].filename;
        if (rawName.contains('\\')) {
          throw const SafeZipExtractionException('zip_backslash_path');
        }
        if (entry.isSymbolicLink) {
          throw const SafeZipExtractionException('zip_symbolic_link');
        }
        final normalized = _normalizePath(rawName);
        final isDirectory = rawName.endsWith('/');
        final key = normalized.toLowerCase();
        if (!caseInsensitivePaths.add(key)) {
          throw const SafeZipExtractionException('zip_duplicate_path');
        }
        allPaths[normalized] = !isDirectory && entry.isFile;
        if (isDirectory || !entry.isFile) continue;
        if (planned.length >= policy.maxFileCount) {
          throw const SafeZipExtractionException('zip_file_count_exceeded');
        }
        if (entry.size < 0 || entry.size > policy.maxSingleFileBytes) {
          throw const SafeZipExtractionException('zip_single_file_exceeded');
        }
        declaredBytes += entry.size;
        if (declaredBytes > policy.maxExpandedBytes) {
          throw const SafeZipExtractionException('zip_expanded_size_exceeded');
        }
        planned.add((entry: entry, path: normalized));
      }
      _validateFileDirectoryCollisions(allPaths);

      var actualBytes = 0;
      for (final item in planned) {
        cancellationToken?.throwIfCancellationRequested();
        final outputFile = File(
          [
            destination.path,
            ...item.path.split('/'),
          ].join(Platform.pathSeparator),
        );
        await outputFile.parent.create(recursive: true);
        final delegate = OutputFileStream(outputFile.path);
        final remaining = policy.maxExpandedBytes - actualBytes;
        final output = _BoundedArchiveOutput(
          delegate,
          maxBytes: item.entry.size < remaining ? item.entry.size : remaining,
        );
        try {
          item.entry.writeContent(output);
          await output.close();
        } on Object {
          await output.close();
          rethrow;
        }
        if (output.length != item.entry.size) {
          throw const SafeZipExtractionException('zip_entry_size_mismatch');
        }
        actualBytes += output.length;
        if (actualBytes > policy.maxExpandedBytes) {
          throw const SafeZipExtractionException('zip_expanded_size_exceeded');
        }
        final expectedCrc = item.entry.crc32;
        if (expectedCrc != null &&
            await _fileCrc32(outputFile) != expectedCrc) {
          throw const SafeZipExtractionException('zip_crc_mismatch');
        }
        item.entry.clear();
      }
      return SafeZipExtractionResult(
        fileCount: planned.length,
        expandedBytes: actualBytes,
        relativePaths: List.unmodifiable(planned.map((item) => item.path)),
      );
    } on SafeZipExtractionException {
      rethrow;
    } on VerifiedDownloadException {
      rethrow;
    } on Object {
      throw const SafeZipExtractionException('zip_invalid_archive');
    } finally {
      await input.close();
    }
  }

  String _normalizePath(String raw) {
    if (raw.isEmpty ||
        raw.startsWith('/') ||
        RegExp(r'^[A-Za-z]:').hasMatch(raw) ||
        raw.contains(RegExp(r'[\u0000-\u001f\u007f]'))) {
      throw const SafeZipExtractionException('zip_absolute_or_control_path');
    }
    final withoutSlash = raw.endsWith('/')
        ? raw.substring(0, raw.length - 1)
        : raw;
    if (withoutSlash.isEmpty) {
      throw const SafeZipExtractionException('zip_empty_path');
    }
    final parts = withoutSlash.split('/');
    if (parts.any(
      (part) =>
          part.isEmpty ||
          part == '.' ||
          part == '..' ||
          part.contains(RegExp(r'[<>:"|?*]')) ||
          _isWindowsReservedName(part),
    )) {
      throw const SafeZipExtractionException('zip_traversal_or_unsafe_path');
    }
    return parts.join('/');
  }

  bool _isWindowsReservedName(String segment) => RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$',
    caseSensitive: false,
  ).hasMatch(segment);

  void _validateFileDirectoryCollisions(Map<String, bool> paths) {
    final files = {
      for (final entry in paths.entries)
        if (entry.value) entry.key.toLowerCase(),
    };
    for (final path in paths.keys) {
      final parts = path.toLowerCase().split('/');
      for (var index = 1; index < parts.length; index += 1) {
        if (files.contains(parts.take(index).join('/'))) {
          throw const SafeZipExtractionException(
            'zip_file_directory_collision',
          );
        }
      }
    }
  }

  Future<int> _fileCrc32(File file) async {
    final crc = Crc32();
    await for (final chunk in file.openRead()) {
      crc.add(chunk);
    }
    return crc.hash;
  }
}

class _BoundedArchiveOutput extends OutputStreamBase {
  _BoundedArchiveOutput(this.delegate, {required this.maxBytes});

  final OutputFileStream delegate;
  final int maxBytes;

  @override
  int get length => delegate.length;

  void _reserve(int bytes) {
    if (bytes < 0 || length + bytes > maxBytes) {
      throw const SafeZipExtractionException('zip_actual_entry_exceeded');
    }
  }

  @override
  void flush() => delegate.flush();

  Future<void> close() => delegate.close();

  @override
  void writeByte(int value) {
    _reserve(1);
    delegate.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    final count = len ?? bytes.length;
    _reserve(count);
    delegate.writeBytes(bytes, count);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    const chunkSize = 1024 * 1024;
    while (!stream.isEOS) {
      final count = stream.length < chunkSize ? stream.length : chunkSize;
      final bytes = stream.readBytes(count).toUint8List();
      writeBytes(bytes);
    }
  }

  @override
  void writeUint16(int value) {
    writeByte(value & 0xff);
    writeByte((value >> 8) & 0xff);
  }

  @override
  void writeUint32(int value) {
    for (var shift = 0; shift < 32; shift += 8) {
      writeByte((value >> shift) & 0xff);
    }
  }

  @override
  void writeUint64(int value) {
    for (var shift = 0; shift < 64; shift += 8) {
      writeByte((value >> shift) & 0xff);
    }
  }
}
