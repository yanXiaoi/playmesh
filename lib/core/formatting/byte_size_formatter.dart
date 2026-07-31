String formatByteSize(num bytes) {
  if (!bytes.isFinite || bytes < 0) {
    throw ArgumentError.value(bytes, 'bytes', '字节数必须是有限非负数');
  }
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  while (true) {
    final fractionDigits = unitIndex == 0
        ? 0
        : value >= 100
        ? 0
        : value >= 10
        ? 1
        : 2;
    final fixed = value.toStringAsFixed(fractionDigits);
    final text = fixed.contains('.')
        ? fixed.replaceFirst(RegExp(r'\.?0+$'), '')
        : fixed;
    if (double.parse(text) < 1024 || unitIndex == units.length - 1) {
      return '$text ${units[unitIndex]}';
    }
    value /= 1024;
    unitIndex += 1;
  }
}

String formatByteRate(num bytesPerSecond) =>
    '${formatByteSize(bytesPerSecond)}/s';
