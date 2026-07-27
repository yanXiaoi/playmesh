import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

const gamePackageIconName = 'icon.png';
const maxGamePackageIconBytes = 2 * 1024 * 1024;
const maxGamePackageIconPixels = 4 * 1024 * 1024;
const _maxDecodedIconBytes = 32 * 1024 * 1024;

/// A file-backed image provider whose cache identity follows the actual icon
/// file revision. Package upgrades keep the required root path `icon.png`, so a
/// plain [FileImage] would otherwise return pixels cached for the old file.
@immutable
final class GamePackageIconImageProvider
    extends ImageProvider<GamePackageIconImageProvider> {
  GamePackageIconImageProvider(this.file, {this.scale = 1})
    : revision = _fileRevision(file);

  final File file;
  final double scale;
  final String revision;

  @override
  Future<GamePackageIconImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    GamePackageIconImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _loadAsync(key, decode),
    scale: key.scale,
    debugLabel: key.file.path,
    informationCollector: () => <DiagnosticsNode>[
      ErrorDescription('Path: ${key.file.path}'),
      ErrorDescription('Revision: ${key.revision}'),
    ],
  );

  Future<ui.Codec> _loadAsync(
    GamePackageIconImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final length = await key.file.length();
    if (length == 0) {
      PaintingBinding.instance.imageCache.evict(key);
      throw StateError('${key.file.path} is empty and cannot be decoded');
    }
    return decode(await ui.ImmutableBuffer.fromFilePath(key.file.path));
  }

  @override
  bool operator ==(Object other) =>
      other is GamePackageIconImageProvider &&
      other.file.path == file.path &&
      other.scale == scale &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(file.path, scale, revision);

  @override
  String toString() =>
      'GamePackageIconImageProvider("${file.path}", revision: $revision)';
}

String _fileRevision(File file) {
  try {
    final stat = file.statSync();
    return '${stat.type}:${stat.size}:'
        '${stat.modified.microsecondsSinceEpoch}:'
        '${stat.changed.microsecondsSinceEpoch}';
  } on FileSystemException {
    return 'unavailable';
  }
}

Future<bool> isSafeGamePackageIcon(File file) async {
  if (!await file.exists()) return false;
  final length = await file.length();
  if (length < 45 || length > maxGamePackageIconBytes) return false;
  return isSafeGamePackageIconBytes(
    await file.readAsBytes(),
    totalLength: length,
  );
}

bool isSafeGamePackageIconSync(File file) {
  if (!file.existsSync()) return false;
  final length = file.lengthSync();
  if (length < 45 || length > maxGamePackageIconBytes) return false;
  return isSafeGamePackageIconBytes(
    file.readAsBytesSync(),
    totalLength: length,
  );
}

bool isSafeGamePackageIconBytes(List<int> bytes, {int? totalLength}) {
  final length = totalLength ?? bytes.length;
  if (length != bytes.length ||
      length < 45 ||
      length > maxGamePackageIconBytes) {
    return false;
  }
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  for (var index = 0; index < signature.length; index += 1) {
    if (bytes[index] != signature[index]) return false;
  }
  var offset = 8;
  var sawHeader = false;
  var sawData = false;
  var sawEnd = false;
  var width = 0;
  var height = 0;
  var bitsPerPixel = 0;
  final compressed = BytesBuilder(copy: false);
  while (offset + 12 <= bytes.length) {
    final chunkLength = _uint32(bytes, offset);
    final dataStart = offset + 8;
    final dataEnd = dataStart + chunkLength;
    final chunkEnd = dataEnd + 4;
    if (chunkLength < 0 || chunkEnd > bytes.length) return false;
    final type = String.fromCharCodes(bytes.sublist(offset + 4, dataStart));
    if (_crc32(bytes, offset + 4, dataEnd) != _uint32(bytes, dataEnd)) {
      return false;
    }
    if (!sawHeader) {
      if (type != 'IHDR' || chunkLength != 13) return false;
      width = _uint32(bytes, dataStart);
      height = _uint32(bytes, dataStart + 4);
      final bitDepth = bytes[dataStart + 8];
      final colorType = bytes[dataStart + 9];
      if (width < 1 ||
          height < 1 ||
          width > 8192 ||
          height > 8192 ||
          width * height > maxGamePackageIconPixels ||
          bytes[dataStart + 10] != 0 ||
          bytes[dataStart + 11] != 0 ||
          bytes[dataStart + 12] != 0) {
        return false;
      }
      final channels = switch (colorType) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        _ => 0,
      };
      final validDepths = switch (colorType) {
        0 => const {1, 2, 4, 8, 16},
        2 || 4 || 6 => const {8, 16},
        3 => const {1, 2, 4, 8},
        _ => const <int>{},
      };
      if (channels == 0 || !validDepths.contains(bitDepth)) return false;
      bitsPerPixel = channels * bitDepth;
      sawHeader = true;
    } else if (type == 'IDAT') {
      if (sawEnd) return false;
      sawData = true;
      compressed.add(bytes.sublist(dataStart, dataEnd));
    } else if (type == 'IEND') {
      if (chunkLength != 0 || !sawData) return false;
      sawEnd = true;
      offset = chunkEnd;
      break;
    }
    offset = chunkEnd;
  }
  if (!sawHeader || !sawData || !sawEnd || offset != bytes.length) {
    return false;
  }
  final rowBytes = ((width * bitsPerPixel + 7) ~/ 8) + 1;
  final expected = rowBytes * height;
  if (expected > _maxDecodedIconBytes) return false;
  try {
    final output = _PngInflateSink(expected: expected, rowBytes: rowBytes);
    final decoder = ZLibCodec().decoder.startChunkedConversion(output);
    decoder.add(compressed.takeBytes());
    decoder.close();
    if (!output.isComplete) return false;
  } on Object {
    return false;
  }
  return true;
}

int _uint32(List<int> bytes, int offset) => ByteData.sublistView(
  Uint8List.fromList(bytes.sublist(offset, offset + 4)),
).getUint32(0);

int _crc32(List<int> bytes, int start, int end) {
  var crc = 0xffffffff;
  for (var index = start; index < end; index += 1) {
    crc ^= bytes[index];
    for (var bit = 0; bit < 8; bit += 1) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

final class _PngInflateSink extends ByteConversionSink {
  _PngInflateSink({required this.expected, required this.rowBytes});

  final int expected;
  final int rowBytes;
  int _length = 0;
  bool _closed = false;

  bool get isComplete => _closed && _length == expected;

  @override
  void add(List<int> chunk) {
    if (_closed || _length + chunk.length > expected) {
      throw const FormatException('PNG 解压数据超过声明尺寸');
    }
    for (var index = 0; index < chunk.length; index += 1) {
      if ((_length + index) % rowBytes == 0 && chunk[index] > 4) {
        throw const FormatException('PNG 行过滤器无效');
      }
    }
    _length += chunk.length;
  }

  @override
  void close() {
    _closed = true;
    if (_length != expected) {
      throw const FormatException('PNG 解压数据与声明尺寸不一致');
    }
  }
}
