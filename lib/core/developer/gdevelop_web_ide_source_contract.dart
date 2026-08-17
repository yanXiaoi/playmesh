import 'dart:typed_data';

/// 为 Developer Gateway 提供已经安装到本机的 GDevelop Web IDE 文件。
abstract interface class GDevelopWebIdeSource {
  Future<bool> isAvailable();

  Future<Uint8List?> read(String relativePath);
}
