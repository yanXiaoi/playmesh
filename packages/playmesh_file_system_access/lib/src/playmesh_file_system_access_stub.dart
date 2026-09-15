class PlaymeshFileSystemAccessException implements Exception {
  const PlaymeshFileSystemAccessException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

class PlaymeshFileSystemAccessHost {
  PlaymeshFileSystemAccessHost();

  Future<Object?> execute(String command, Map<String, Object?> payload) {
    throw const PlaymeshFileSystemAccessException(
      'not_supported',
      '当前平台不支持原生文件系统访问',
    );
  }

  Future<void> resetDocument() async {}

  Future<void> close() async {}
}
