import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/formatting/byte_size_formatter.dart';

void main() {
  test('字节大小严格按 1024 向上合并单位', () {
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(1023), '1023 B');
    expect(formatByteSize(1024), '1 KB');
    expect(formatByteSize(1024 * 1024 - 1), '1 MB');
    expect(formatByteSize(1024 * 1024), '1 MB');
    expect(formatByteSize(1024 * 1024 * 1024 - 1), '1 GB');
    expect(formatByteSize(1024 * 1024 * 1024), '1 GB');
    expect(formatByteRate(1536), '1.5 KB/s');
    expect(formatByteRate(1023.6), '1 KB/s');
  });

  test('拒绝负数和非有限字节数', () {
    expect(() => formatByteSize(-1), throwsArgumentError);
    expect(() => formatByteSize(double.infinity), throwsArgumentError);
  });
}
