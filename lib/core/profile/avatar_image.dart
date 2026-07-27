import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';

class AvatarImageData {
  const AvatarImageData({required this.pngBytes, required this.sha256});

  final Uint8List pngBytes;
  final String sha256;
}

final class AvatarImage {
  AvatarImage._();

  static const dimension = 256;
  static const maxBytes = 512 * 1024;
  static const maxSourceBytes = 8 * 1024 * 1024;
  static const maxSourceDimension = 4096;
  static const maxSourcePixels = 16 * 1024 * 1024;
  static const relativePath = 'profile/avatar.png';

  static Future<AvatarImageData> normalize(Uint8List source) async {
    if (source.isEmpty || source.length > maxSourceBytes) {
      throw const FormatException('头像源文件大小必须在 1 B 至 8 MiB 之间');
    }
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    ui.Image? cropped;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(source);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final sourcePixels = descriptor.width * descriptor.height;
      if (descriptor.width < 1 ||
          descriptor.height < 1 ||
          descriptor.width > maxSourceDimension ||
          descriptor.height > maxSourceDimension ||
          sourcePixels > maxSourcePixels) {
        throw const FormatException('头像源图片尺寸过大');
      }
      codec = await descriptor.instantiateCodec();
      final frame = await codec.getNextFrame();
      image = frame.image;
      final side = image.width < image.height ? image.width : image.height;
      final left = (image.width - side) / 2;
      final top = (image.height - side) / 2;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(left, top, side.toDouble(), side.toDouble()),
        ui.Rect.fromLTWH(0, 0, dimension.toDouble(), dimension.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      cropped = await recorder.endRecording().toImage(dimension, dimension);
      final encoded = await cropped.toByteData(format: ui.ImageByteFormat.png);
      if (encoded == null) throw const FormatException('头像 PNG 编码失败');
      final bytes = encoded.buffer.asUint8List(
        encoded.offsetInBytes,
        encoded.lengthInBytes,
      );
      return validate(Uint8List.fromList(bytes));
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('头像图片无法解码');
    } finally {
      cropped?.dispose();
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  static Future<AvatarImageData> validate(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('头像 PNG 不能超过 512 KiB');
    }
    if (!_hasPngSignature(bytes) ||
        _readUint32(bytes, 16) != dimension ||
        _readUint32(bytes, 20) != dimension) {
      throw const FormatException('头像必须是 256 x 256 PNG');
    }
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      codec = await ui.instantiateImageCodec(bytes);
      decoded = (await codec.getNextFrame()).image;
      if (decoded.width != dimension || decoded.height != dimension) {
        throw const FormatException('头像必须是 256 x 256 PNG');
      }
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('头像 PNG 数据损坏');
    } finally {
      decoded?.dispose();
      codec?.dispose();
    }
    final digest = await Sha256().hash(bytes);
    return AvatarImageData(
      pngBytes: bytes,
      sha256: digest.bytes
          .map((value) => value.toRadixString(16).padLeft(2, '0'))
          .join(),
    );
  }

  static bool _hasPngSignature(Uint8List bytes) {
    const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < 24) return false;
    for (var index = 0; index < signature.length; index += 1) {
      if (bytes[index] != signature[index]) return false;
    }
    return true;
  }

  static int _readUint32(Uint8List bytes, int offset) {
    if (offset + 4 > bytes.length) return -1;
    return ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
  }
}
