import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/game_share_link_snapshot.dart';
import 'package:playmesh/core/game_web/share_qr_code_encoder.dart';
import 'package:qr/qr.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ShareQrCodeEncoder', () {
    test('按 M 级纠错、每模块 4 像素和四模块白色静区编码完整 URL', () async {
      final url = Uri.parse(
        'http://192.168.1.8:4040/playmesh/join'
        '#inviteToken=AbCdEf0123456789_-AbCdEf01234567',
      );
      final expectedCode = QrCode.fromData(
        data: url.toString(),
        errorCorrectLevel: QrErrorCorrectLevel.M,
      );
      final expectedImage = QrImage(expectedCode);

      final pngBytes = await ShareQrCodeEncoder().encode(url);
      expect(pngBytes.take(8), <int>[137, 80, 78, 71, 13, 10, 26, 10]);

      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(pngBytes),
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      addTearDown(() {
        image.dispose();
        codec.dispose();
      });
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(rgba, isNotNull);
      final pixels = rgba!.buffer.asUint8List(
        rgba.offsetInBytes,
        rgba.lengthInBytes,
      );
      final expectedSize = expectedCode.moduleCount * 4 + 32;
      expect(image.width, expectedSize);
      expect(image.height, expectedSize);

      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          if (x < 16 ||
              y < 16 ||
              x >= image.width - 16 ||
              y >= image.height - 16) {
            _expectRgbaPixel(
              pixels,
              width: image.width,
              x: x,
              y: y,
              dark: false,
              reason: '二维码静区必须保持纯白: ($x, $y)',
            );
          }
        }
      }
      for (var row = 0; row < expectedImage.moduleCount; row++) {
        for (var column = 0; column < expectedImage.moduleCount; column++) {
          _expectRgbaPixel(
            pixels,
            width: image.width,
            x: 16 + column * 4 + 2,
            y: 16 + row * 4 + 2,
            dark: expectedImage.isDark(row, column),
            reason: '二维码矩阵与完整 URL 不一致: ($row, $column)',
          );
        }
      }
    });

    test('仅复用完整 URL 完全相同的缓存并支持 retain/clear', () async {
      final encoder = ShareQrCodeEncoder();
      final firstUrl = Uri.parse('http://192.168.1.8/join#inviteToken=first');
      final secondUrl = Uri.parse('http://192.168.1.8/join#inviteToken=second');

      final first = await encoder.encode(firstUrl);
      final firstAgain = await encoder.encode(firstUrl);
      final second = await encoder.encode(secondUrl);
      expect(identical(first, firstAgain), isTrue);

      encoder.retain(<Uri>[secondUrl]);
      final firstAfterRetain = await encoder.encode(firstUrl);
      expect(identical(first, firstAfterRetain), isFalse);
      expect(firstAfterRetain, first);

      encoder.clear();
      final secondAfterClear = await encoder.encode(secondUrl);
      expect(identical(second, secondAfterClear), isFalse);
      expect(secondAfterClear, second);
    });

    test('URL 超过 2048 UTF-8 字节时返回稳定错误码', () async {
      final oversized = Uri.parse(
        'https://share.example.test/playmesh/join#inviteToken='
        '${List<String>.filled(maxGameShareUrlBytes, 'a').join()}',
      );

      await expectLater(
        ShareQrCodeEncoder().encode(oversized),
        throwsA(
          isA<GameShareException>()
              .having((error) => error.code, 'code', 'share_links_too_large')
              .having((error) => error.message, 'message', contains('2048')),
        ),
      );
    });
  });

  group('buildGameShareLinkSnapshot', () {
    test('LAN 去重并保持顺序，WAN 追加在末尾，二维码串行生成', () async {
      final firstLan = Uri.parse(
        'http://192.168.1.8:4040/playmesh/join#inviteToken=first',
      );
      final duplicateFirstLan = Uri.parse(firstLan.toString());
      final secondLan = Uri.parse(
        'http://10.0.0.9:4040/playmesh/join#inviteToken=second',
      );
      final wan = Uri.parse(
        'https://relay.example.test/playmesh/join#inviteToken=wan',
      );
      final encoder = _RecordingEncoder();

      final snapshot = await buildGameShareLinkSnapshot(
        generation: 29,
        lanUrls: <Uri>[firstLan, duplicateFirstLan, secondLan],
        wanUrl: wan,
        encoder: encoder,
      );

      expect(snapshot.generation, 29);
      expect(encoder.retained, <Uri>[firstLan, secondLan, wan]);
      expect(encoder.encoded, <Uri>[firstLan, secondLan, wan]);
      expect(encoder.maxActiveEncodes, 1);
      expect(snapshot.links.map((link) => link.url), <Uri>[
        firstLan,
        secondLan,
        wan,
      ]);
      expect(snapshot.links.map((link) => link.type), <GameShareLinkType>[
        GameShareLinkType.lan,
        GameShareLinkType.lan,
        GameShareLinkType.wan,
      ]);
      expect(snapshot.lanLinks.map((link) => link.url), <Uri>[
        firstLan,
        secondLan,
      ]);
      expect(snapshot.wanLink?.url, wan);
    });

    test('WAN 与 LAN 相同时只保留 LAN 记录', () async {
      final lan = Uri.parse(
        'http://192.168.1.8:4040/playmesh/join#inviteToken=same',
      );
      final encoder = _RecordingEncoder();

      final snapshot = await buildGameShareLinkSnapshot(
        generation: 1,
        lanUrls: <Uri>[lan],
        wanUrl: Uri.parse(lan.toString()),
        encoder: encoder,
      );

      expect(snapshot.links, hasLength(1));
      expect(snapshot.links.single.type, GameShareLinkType.lan);
      expect(snapshot.wanLink, isNull);
      expect(encoder.encoded, <Uri>[lan]);
    });

    test('LAN 地址超过 32 个时在编码前失败', () async {
      final encoder = _RecordingEncoder();
      final lanUrls = List<Uri>.generate(
        maxGameShareLanLinks + 1,
        (index) => Uri.parse(
          'http://192.168.1.${index + 1}:4040/playmesh/join'
          '#inviteToken=$index',
        ),
      );

      await expectLater(
        buildGameShareLinkSnapshot(
          generation: 1,
          lanUrls: lanUrls,
          wanUrl: null,
          encoder: encoder,
        ),
        throwsA(
          isA<GameShareException>().having(
            (error) => error.code,
            'code',
            'share_links_too_large',
          ),
        ),
      );
      expect(encoder.retained, isEmpty);
      expect(encoder.encoded, isEmpty);
    });

    test('桥接数组分隔符也计入 4 MiB 总负载', () async {
      final lanUrls = List<Uri>.generate(
        maxGameShareLanLinks,
        (index) => Uri.parse(
          'http://10.0.0.${index + 1}:4040/playmesh/join'
          '#inviteToken=$index',
        ),
      );
      final wanUrl = Uri.parse(
        'https://relay.example.test/playmesh/join#inviteToken=wan',
      );
      const lanPngBytes = 97000;
      final fixedItemBytes = lanUrls.fold<int>(
        2,
        (total, url) =>
            total +
            _bridgeItemJsonBytes(url, GameShareLinkType.lan, lanPngBytes),
      );
      int? wanPngBytes;
      for (var candidate = 0; candidate <= 98000; candidate++) {
        final dataUrlBytes = _pngDataUrlBytes(candidate);
        if (dataUrlBytes > maxGameShareQrDataUrlBytes) break;
        final estimatedWithoutSeparators =
            fixedItemBytes +
            _bridgeItemJsonBytes(wanUrl, GameShareLinkType.wan, candidate);
        final actualArrayBytes =
            estimatedWithoutSeparators + maxGameShareLanLinks;
        if (estimatedWithoutSeparators <= maxGameShareBridgeJsonBytes &&
            actualArrayBytes > maxGameShareBridgeJsonBytes) {
          wanPngBytes = candidate;
          break;
        }
      }
      expect(wanPngBytes, isNotNull, reason: '测试数据必须只因数组分隔符越过总负载上限');
      final encoder = _RecordingEncoder(
        byteSizes: <int>[
          ...List<int>.filled(maxGameShareLanLinks, lanPngBytes),
          wanPngBytes!,
        ],
      );

      await expectLater(
        buildGameShareLinkSnapshot(
          generation: 1,
          lanUrls: lanUrls,
          wanUrl: wanUrl,
          encoder: encoder,
        ),
        throwsA(
          isA<GameShareException>().having(
            (error) => error.code,
            'code',
            'share_links_too_large',
          ),
        ),
      );
    });

    test('序列化后的桥接负载超过 4 MiB 时失败', () async {
      final encoder = _RecordingEncoder(bytesPerQr: 100000);
      final lanUrls = List<Uri>.generate(
        maxGameShareLanLinks,
        (index) => Uri.parse(
          'http://10.0.0.${index + 1}:4040/playmesh/join'
          '#inviteToken=$index',
        ),
      );

      await expectLater(
        buildGameShareLinkSnapshot(
          generation: 1,
          lanUrls: lanUrls,
          wanUrl: Uri.parse(
            'https://relay.example.test/playmesh/join#inviteToken=wan',
          ),
          encoder: encoder,
        ),
        throwsA(
          isA<GameShareException>().having(
            (error) => error.code,
            'code',
            'share_links_too_large',
          ),
        ),
      );
    });
  });
}

int _bridgeItemJsonBytes(Uri url, GameShareLinkType type, int pngByteLength) {
  final withoutImage = utf8
      .encode(
        jsonEncode(<String, String>{
          'url': url.toString(),
          'type': type.name,
          'img': '',
        }),
      )
      .length;
  return withoutImage + _pngDataUrlBytes(pngByteLength);
}

int _pngDataUrlBytes(int pngByteLength) {
  const prefixBytes = 22; // data:image/png;base64,
  final base64Bytes = 4 * ((pngByteLength + 2) ~/ 3);
  return prefixBytes + base64Bytes;
}

void _expectRgbaPixel(
  Uint8List pixels, {
  required int width,
  required int x,
  required int y,
  required bool dark,
  required String reason,
}) {
  final offset = (y * width + x) * 4;
  final expected = dark ? 0 : 255;
  expect(pixels.sublist(offset, offset + 4), <int>[
    expected,
    expected,
    expected,
    255,
  ], reason: reason);
}

final class _RecordingEncoder extends ShareQrCodeEncoder {
  _RecordingEncoder({this.bytesPerQr = 4, this.byteSizes});

  final int bytesPerQr;
  final List<int>? byteSizes;
  final List<Uri> retained = <Uri>[];
  final List<Uri> encoded = <Uri>[];
  int _activeEncodes = 0;
  int maxActiveEncodes = 0;

  @override
  void retain(Iterable<Uri> urls) {
    retained
      ..clear()
      ..addAll(urls);
  }

  @override
  Future<List<int>> encode(Uri url) async {
    _activeEncodes += 1;
    if (_activeEncodes > maxActiveEncodes) {
      maxActiveEncodes = _activeEncodes;
    }
    encoded.add(url);
    await Future<void>.delayed(Duration.zero);
    final size = byteSizes?[encoded.length - 1] ?? bytesPerQr;
    final bytes = List<int>.filled(size, encoded.length & 0xff);
    _activeEncodes -= 1;
    return bytes;
  }
}
