import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'game_share_link_snapshot.dart';

const maxGameShareUrlBytes = 2048;
const maxGameShareQrDataUrlBytes = 128 * 1024;
const maxGameShareBridgeJsonBytes = 4 * 1024 * 1024;
const maxGameShareLanLinks = 32;

class ShareQrCodeEncoder {
  final Map<String, List<int>> _cache = {};

  Future<List<int>> encode(Uri url) async {
    final value = url.toString();
    if (utf8.encode(value).length > maxGameShareUrlBytes) {
      throw const GameShareException('share_links_too_large', '分享链接超过 2048 字节');
    }
    final cached = _cache[value];
    if (cached != null) return cached;

    try {
      final qr = QrCode.fromData(
        data: value,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      );
      final moduleSize = qr.moduleCount * 4;
      final imageSize = moduleSize + 32;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        Rect.fromLTWH(0, 0, imageSize.toDouble(), imageSize.toDouble()),
        Paint()..color = Colors.white,
      );
      canvas.save();
      canvas.translate(16, 16);
      QrPainter.withQr(
        qr: qr,
        gapless: true,
        eyeStyle: const QrEyeStyle(
          eyeShape: QrEyeShape.square,
          color: Colors.black,
        ),
        dataModuleStyle: const QrDataModuleStyle(
          dataModuleShape: QrDataModuleShape.square,
          color: Colors.black,
        ),
      ).paint(canvas, Size.square(moduleSize.toDouble()));
      canvas.restore();
      final picture = recorder.endRecording();
      final image = await picture.toImage(imageSize, imageSize);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) {
        throw StateError('PNG 编码器没有返回数据');
      }
      final bytes = List<int>.unmodifiable(data.buffer.asUint8List());
      final dataUrlBytes = utf8
          .encode('data:image/png;base64,${base64Encode(bytes)}')
          .length;
      if (dataUrlBytes > maxGameShareQrDataUrlBytes) {
        throw const GameShareException(
          'share_links_too_large',
          '分享二维码超过 128 KiB',
        );
      }
      _cache[value] = bytes;
      return bytes;
    } on GameShareException {
      rethrow;
    } on Object {
      throw const GameShareException('qr_generation_failed', '分享二维码生成失败');
    }
  }

  void retain(Iterable<Uri> urls) {
    final retained = urls.map((url) => url.toString()).toSet();
    _cache.removeWhere((url, _) => !retained.contains(url));
  }

  void clear() => _cache.clear();
}

Future<GameShareLinkSnapshot> buildGameShareLinkSnapshot({
  required int generation,
  required Iterable<Uri> lanUrls,
  required Uri? wanUrl,
  required ShareQrCodeEncoder encoder,
}) async {
  final uniqueLan = <String, Uri>{};
  for (final url in lanUrls) {
    uniqueLan.putIfAbsent(url.toString(), () => url);
  }
  if (uniqueLan.length > maxGameShareLanLinks) {
    throw const GameShareException('share_links_too_large', '可分享的局域网地址超过 32 个');
  }
  final ordered = <(Uri, GameShareLinkType)>[
    for (final url in uniqueLan.values) (url, GameShareLinkType.lan),
    if (wanUrl != null && !uniqueLan.containsKey(wanUrl.toString()))
      (wanUrl, GameShareLinkType.wan),
  ];
  encoder.retain(ordered.map((entry) => entry.$1));
  final links = <GameShareLink>[];
  var estimatedJsonBytes = 2;
  for (final entry in ordered) {
    final bytes = await encoder.encode(entry.$1);
    final dataUrl = 'data:image/png;base64,${base64Encode(bytes)}';
    if (links.isNotEmpty) estimatedJsonBytes += 1;
    estimatedJsonBytes += utf8
        .encode(
          jsonEncode({
            'url': entry.$1.toString(),
            'type': entry.$2.name,
            'img': dataUrl,
          }),
        )
        .length;
    if (estimatedJsonBytes > maxGameShareBridgeJsonBytes) {
      throw const GameShareException('share_links_too_large', '分享链接负载超过 4 MiB');
    }
    links.add(GameShareLink(url: entry.$1, type: entry.$2, pngBytes: bytes));
  }
  return GameShareLinkSnapshot(generation: generation, links: links);
}
