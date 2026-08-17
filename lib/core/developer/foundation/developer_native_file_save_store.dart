import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package_upload_spooler.dart';

final class DeveloperNativeFileSaveTransfer {
  DeveloperNativeFileSaveTransfer({
    required this.id,
    required this.filename,
    required this.mimeType,
    required this._upload,
  });

  final String id;
  final String filename;
  final String mimeType;
  final TemporaryPackageUpload _upload;

  File get file => _upload.file;
  int get length => _upload.length;

  Future<void> dispose() => _upload.dispose();
}

/// Owns raw Blob uploads until the native WebView host has streamed them to a
/// system save destination. No archive bytes are retained in Dart memory.
final class DeveloperNativeFileSaveStore {
  DeveloperNativeFileSaveStore({
    required int maxBytes,
    this.retention = const Duration(minutes: 20),
    Directory? temporaryRoot,
    Random? random,
  }) : _spooler = PackageUploadSpooler(
         maxBytes: maxBytes,
         temporaryRoot: temporaryRoot,
       ),
       _random = random ?? Random.secure();

  final Duration retention;
  final PackageUploadSpooler _spooler;
  final Random _random;
  final Map<String, DeveloperNativeFileSaveTransfer> _transfers = {};
  final Map<String, Timer> _expiryTimers = {};

  @visibleForTesting
  int get activeTransferCount => _transfers.length;

  Future<DeveloperNativeFileSaveTransfer> create({
    required Stream<List<int>> input,
    required String requestedFilename,
    required String mimeType,
    int? declaredLength,
  }) async {
    final upload = await _spooler.spool(input, declaredLength: declaredLength);
    final id = _newTransferId();
    final transfer = DeveloperNativeFileSaveTransfer(
      id: id,
      filename: sanitizeDeveloperNativeFilename(requestedFilename),
      mimeType: _sanitizeMimeType(mimeType),
      upload: upload,
    );
    _transfers[id] = transfer;
    _expiryTimers[id] = Timer(retention, () {
      unawaited(remove(id));
    });
    return transfer;
  }

  DeveloperNativeFileSaveTransfer? find(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{20,64}$').hasMatch(id)) return null;
    return _transfers[id];
  }

  Future<bool> remove(String id) async {
    _expiryTimers.remove(id)?.cancel();
    final transfer = _transfers.remove(id);
    if (transfer == null) return false;
    await transfer.dispose();
    return true;
  }

  Future<void> dispose() async {
    for (final timer in _expiryTimers.values) {
      timer.cancel();
    }
    _expiryTimers.clear();
    final transfers = _transfers.values.toList(growable: false);
    _transfers.clear();
    for (final transfer in transfers) {
      await transfer.dispose();
    }
  }

  String _newTransferId() {
    String id;
    do {
      final bytes = List<int>.generate(24, (_) => _random.nextInt(256));
      id = base64Url.encode(bytes).replaceAll('=', '');
    } while (_transfers.containsKey(id));
    return id;
  }
}

String sanitizeDeveloperNativeFilename(String value) {
  var filename = value.trim().replaceAll('\\', '/').split('/').last.trim();
  filename = filename
      .replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"/\\|?*]'), '_')
      .replaceFirst(RegExp(r'[. ]+$'), '');
  if (filename.isEmpty || filename == '.' || filename == '..') {
    return 'download.bin';
  }
  final runes = filename.runes.take(160).toList(growable: false);
  return String.fromCharCodes(runes);
}

String _sanitizeMimeType(String value) {
  final mimeType = value.trim().split(';').first.toLowerCase();
  if (RegExp(
    r'^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$',
  ).hasMatch(mimeType)) {
    return mimeType;
  }
  return 'application/octet-stream';
}
