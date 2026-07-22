import 'package:cross_file/cross_file.dart';
import 'package:flutter/services.dart';

export 'package:cross_file/cross_file.dart' show XFile;

/// Compatibility API for the share_plus version used by Playmesh.
class Share {
  static const MethodChannel _channel =
      MethodChannel('playmesh/harmony_capabilities');

  static Future<void> shareXFiles(
    List<XFile> files, {
    String? subject,
    String? text,
    List<String>? fileNameOverrides,
  }) async {
    if (files.isEmpty) {
      throw ArgumentError.value(files, 'files', 'must not be empty');
    }
    await _channel.invokeMethod<void>('shareFiles', <String, Object?>{
      'paths': files.map((file) => file.path).toList(),
      'mimeTypes': files.map((file) => file.mimeType ?? '').toList(),
      if (subject != null) 'subject': subject,
      if (text != null) 'text': text,
      if (fileNameOverrides != null) 'fileNameOverrides': fileNameOverrides,
    });
  }
}
