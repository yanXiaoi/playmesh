/// `main.json.config` 中启用 Web Runtime 多线程的字段路径。
const gameWebRuntimeMultithreadingConfigPath = <String>[
  'webRuntime',
  'multithreading',
];

/// 从可选的 `main.json.config` 中读取指定字段。
///
/// `config` 是平台不校验内容的扩展数据；任一级对象或字段不存在时返回 `null`。
/// 生产代码不得自行对 `config` 做 Map 索引，应统一通过此方法读取其内部字段。
Object? readGameManifestConfigValue(
  Object? config,
  Iterable<String> fieldPath,
) {
  Object? current = config;
  var hasField = false;
  for (final field in fieldPath) {
    hasField = true;
    if (current is! Map || !current.containsKey(field)) return null;
    current = current[field];
  }
  return hasField ? current : null;
}
