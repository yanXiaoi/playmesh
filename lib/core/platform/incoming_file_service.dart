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
      throw const FormatException('Android 外部文件信息不完整');
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
            final message = arguments is Map ? arguments['message'] : arguments;
            onError(StateError(message?.toString() ?? '无法接收外部文件'));
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
    if (value is! Map) throw const FormatException('无法解析 Android 外部文件');
    return IncomingFile.fromMap(value);
  }
}
