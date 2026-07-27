import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/profile/avatar_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('头像在完整解码前拒绝超大源尺寸', () async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xff087f6d), ui.BlendMode.src);
    final image = await recorder.endRecording().toImage(
      AvatarImage.maxSourceDimension + 1,
      1,
    );
    final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(encoded, isNotNull);

    await expectLater(
      AvatarImage.normalize(
        Uint8List.fromList(
          encoded!.buffer.asUint8List(
            encoded.offsetInBytes,
            encoded.lengthInBytes,
          ),
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          '头像源图片尺寸过大',
        ),
      ),
    );
  });
}
