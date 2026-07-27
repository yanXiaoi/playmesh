import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/platform/incoming_file_service.dart';

void main() {
  test('按扩展名或 MIME 类型识别外部游戏包与 HTML', () {
    const archive = IncomingFile(
      path: '/cache/game.playmesh',
      name: 'game.playmesh',
      mimeType: 'application/octet-stream',
    );
    const html = IncomingFile(
      path: '/cache/page-without-extension',
      name: 'page-without-extension',
      mimeType: 'text/html',
    );

    expect(archive.isArchive, isTrue);
    expect(archive.isHtml, isFalse);
    expect(html.isHtml, isTrue);
    expect(html.isArchive, isFalse);
  });

  test('拒绝缺少路径或文件名的原生消息', () {
    expect(
      () => IncomingFile.fromMap(const {'name': 'game.zip'}),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'incoming_file_payload_incomplete',
        ),
      ),
    );
  });
}
