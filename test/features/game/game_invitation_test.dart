import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/features/game/join_game_page.dart';

void main() {
  test('分享二维码可以解析为 App 加入信息', () {
    final invitation = GameInvitation.parse(
      'http://192.168.1.9:16667/join/A1B2C3?token=share-token&'
      'playmeshCorePort=54321&playmeshJoinCode=A1B2C3',
    );

    expect(invitation.endpoint, Uri.parse('http://192.168.1.9:54321'));
    expect(invitation.joinCode, 'A1B2C3');
    expect(
      invitation.entryUri,
      Uri.parse(
        'http://192.168.1.9:16667/join/A1B2C3?token=share-token&'
        'playmeshCorePort=54321&playmeshJoinCode=A1B2C3',
      ),
    );
  });

  test('拒绝缺少 Core 端口的普通网页二维码', () {
    expect(
      () => GameInvitation.parse(
        'http://192.168.1.9:16667/join/A1B2C3?token=share-token',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
