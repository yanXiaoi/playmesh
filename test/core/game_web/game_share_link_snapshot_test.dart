import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_share_link_snapshot.dart';

void main() {
  group('GameShareLink', () {
    test('防御性复制二维码字节并暴露只读视图', () {
      final sourceBytes = <int>[1, 2, 3];
      final link = GameShareLink(
        url: Uri.parse('http://192.168.1.8:4040/playmesh/join#inviteToken=lan'),
        type: GameShareLinkType.lan,
        pngBytes: sourceBytes,
      );

      sourceBytes
        ..first = 9
        ..add(4);

      expect(link.pngBytes, <int>[1, 2, 3]);
      expect(() => link.pngBytes.add(4), throwsUnsupportedError);
      expect(() => link.pngBytes[0] = 9, throwsUnsupportedError);
    });
  });

  group('GameShareLinkSnapshot', () {
    test('防御性复制链接并按类型提供稳定的只读派生视图', () {
      final firstLan = _link('192.168.1.8', GameShareLinkType.lan, 1);
      final wan = _link('relay.example.test', GameShareLinkType.wan, 2);
      final secondLan = _link('10.0.0.9', GameShareLinkType.lan, 3);
      final sourceLinks = <GameShareLink>[firstLan, wan, secondLan];

      final snapshot = GameShareLinkSnapshot(
        generation: 17,
        links: sourceLinks,
      );
      sourceLinks.clear();

      expect(snapshot.generation, 17);
      expect(snapshot.links, <GameShareLink>[firstLan, wan, secondLan]);
      expect(snapshot.lanLinks, <GameShareLink>[firstLan, secondLan]);
      expect(snapshot.wanLink, same(wan));
      expect(() => snapshot.links.clear(), throwsUnsupportedError);
      expect(() => snapshot.lanLinks.add(firstLan), throwsUnsupportedError);
    });

    test('empty 保留 generation 且没有 LAN/WAN 链接', () {
      final snapshot = GameShareLinkSnapshot.empty(23);

      expect(snapshot.generation, 23);
      expect(snapshot.links, isEmpty);
      expect(snapshot.lanLinks, isEmpty);
      expect(snapshot.wanLink, isNull);
    });
  });

  test('GameShareException 稳定暴露机器码与用户消息', () {
    const exception = GameShareException('share_links_too_large', '分享链接过大');

    expect(exception.code, 'share_links_too_large');
    expect(exception.message, '分享链接过大');
    expect(exception.toString(), '分享链接过大');
  });
}

GameShareLink _link(String host, GameShareLinkType type, int byte) {
  return GameShareLink(
    url: Uri(
      scheme: 'http',
      host: host,
      port: 4040,
      path: '/playmesh/join',
      fragment: 'inviteToken=$byte',
    ),
    type: type,
    pngBytes: <int>[byte],
  );
}
