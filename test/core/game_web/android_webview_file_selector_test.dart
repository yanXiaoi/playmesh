import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/game_web/android_webview_file_selector.dart';

void main() {
  test('把网页 accept 类型转换为系统文件选择过滤条件', () {
    final groups = AndroidWebViewFileSelector.acceptedTypeGroups([
      '.png',
      'image/jpeg',
      '.PNG',
    ]);

    expect(groups, hasLength(1));
    expect(groups.single.extensions, ['png']);
    expect(groups.single.mimeTypes, ['image/jpeg']);
  });

  test('网页未限制类型或允许任意类型时不添加过滤条件', () {
    expect(AndroidWebViewFileSelector.acceptedTypeGroups(const []), isEmpty);
    expect(
      AndroidWebViewFileSelector.acceptedTypeGroups(['image/png', '*/*']),
      isEmpty,
    );
  });
}
