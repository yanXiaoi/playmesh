import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_package/game_package_icon.dart';

void main() {
  test('接受尺寸、CRC、过滤器和解压长度都有效的 PNG', () {
    final png = _png(width: 1, height: 1, inflated: const [0, 0, 0, 0, 255]);

    expect(isSafeGamePackageIconBytes(png), isTrue);
  });

  test('拒绝解压内容超过 IHDR 声明尺寸的 PNG', () {
    final png = _png(
      width: 1,
      height: 1,
      inflated: List<int>.filled(1024 * 1024, 0),
    );

    expect(png.length, lessThan(maxGamePackageIconBytes));
    expect(isSafeGamePackageIconBytes(png), isFalse);
  });

  test('拒绝包含无效行过滤器的 PNG', () {
    final png = _png(width: 1, height: 1, inflated: const [5, 0, 0, 0, 255]);

    expect(isSafeGamePackageIconBytes(png), isFalse);
  });

  test('根目录 icon.png 被替换后使用新的图片缓存标识', () async {
    final directory = await Directory.systemTemp.createTemp(
      'playmesh-icon-provider-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}${Platform.pathSeparator}icon.png');
    await file.writeAsBytes(
      _png(width: 1, height: 1, inflated: const [0, 0, 0, 0, 255]),
      flush: true,
    );
    await file.setLastModified(DateTime.utc(2026, 7, 26, 1));
    final before = GamePackageIconImageProvider(file);

    await file.writeAsBytes(
      _png(width: 1, height: 1, inflated: const [0, 255, 0, 0, 255]),
      flush: true,
    );
    await file.setLastModified(DateTime.utc(2026, 7, 26, 2));
    final after = GamePackageIconImageProvider(file);

    expect(after, isNot(equals(before)));
    expect(after.revision, isNot(before.revision));
  });
}

Uint8List _png({
  required int width,
  required int height,
  required List<int> inflated,
}) {
  final output = BytesBuilder(copy: false)
    ..add(const [137, 80, 78, 71, 13, 10, 26, 10])
    ..add(
      _chunk('IHDR', [..._uint32(width), ..._uint32(height), 8, 6, 0, 0, 0]),
    )
    ..add(_chunk('IDAT', ZLibCodec().encode(inflated)))
    ..add(_chunk('IEND', const []));
  return output.takeBytes();
}

Uint8List _chunk(String type, List<int> data) {
  final typeBytes = ascii.encode(type);
  final output = BytesBuilder(copy: false)
    ..add(_uint32(data.length))
    ..add(typeBytes)
    ..add(data)
    ..add(_uint32(_crc32([...typeBytes, ...data])));
  return output.takeBytes();
}

List<int> _uint32(int value) => [
  (value >> 24) & 0xff,
  (value >> 16) & 0xff,
  (value >> 8) & 0xff,
  value & 0xff,
];

int _crc32(List<int> bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}
