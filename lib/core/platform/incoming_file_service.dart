import 'package:flutter/services.dart';

class IncomingFile {
  const IncomingFile({required this.path, required this.name, this.mimeType});

  final String path;
  final String name;
  final String? mimeType;

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot < 0 ? '' : name.substring(dot).toLowerCase();
  }

  bool get isArchive =>
      extension == '.zip' ||
      extension == '.playmesh' ||
      mimeType == 'application/zip' ||
      mimeType == 'application/x-zip-compressed' ||
      mimeType == 'application/vnd.playmesh.game+zip';

  bool get isHtml =>
      extension == '.html' || extension == '.htm' || mimeType == 'text/html';

  factory IncomingFile.fromMap(Map<Object?, Object?> map) {
    final path = map['path'];
    final name = map['name'];
    if (path is! String || path.isEmpty || name is! String || name.isEmpty) {
      throw const FormatException('incoming_file_payload_incomplete');
    }
    return IncomingFile(
      path: path,
      name: name,
      mimeType: map['mimeType'] as String?,
    );
  }
}

class IncomingFileService {
  IncomingFileService();

  static const _channel = MethodChannel('playmesh/open_file');

  Future<void> initialize({
    required Future<void> Function(IncomingFile file) onFile,
    required void Function(Object error) onError,
  }) async {
    _channel.setMethodCallHandler((call) async {
      try {
        switch (call.method) {
          case 'fileOpened':
            await onFile(_decode(call.arguments));
          case 'fileOpenFailed':
            final arguments = call.arguments;
            final code = arguments is Map
                ? arguments['code']?.toString()
                : null;
            final diagnostic = arguments is Map
                ? arguments['diagnostic']?.toString()
                : arguments?.toString();
            onError(
              StateError(
                diagnostic == null || diagnostic.isEmpty
                    ? (code ?? 'incoming_file_receive_failed')
                    : '${code ?? 'incoming_file_receive_failed'}: $diagnostic',
              ),
            );
        }
      } on Object catch (error) {
        onError(error);
      }
    });
    try {
      final initial = await _channel.invokeMethod<Object?>('getInitialFile');
      if (initial != null) await onFile(_decode(initial));
    } on MissingPluginException {
      // Non-Android and widget-test environments do not provide this channel.
    } on Object catch (error) {
      onError(error);
    }
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
  }

  IncomingFile _decode(Object? value) {
    if (value is! Map) {
      throw const FormatException('incoming_file_payload_invalid');
    }
    return IncomingFile.fromMap(value);
  }
}
