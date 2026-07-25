const goCoreProtocolVersion = '1.2.0';

class GoCoreStatus {
  const GoCoreStatus({
    required this.requestId,
    required this.status,
    required this.coreVersion,
    required this.timestamp,
    required this.startedAt,
  });

  final String requestId;
  final String status;
  final String coreVersion;
  final DateTime timestamp;
  final DateTime startedAt;

  factory GoCoreStatus.fromJson(Map<String, Object?> json) {
    final type = _requireString(json, 'type');
    if (type != 'core.health') {
      throw FormatException('不支持的响应类型: $type');
    }

    final protocolVersion = _requireString(json, 'protocolVersion');
    if (protocolVersion != goCoreProtocolVersion) {
      throw FormatException('不兼容的协议版本: $protocolVersion');
    }

    final data = _requireMap(json, 'data');
    final status = _requireString(data, 'status');
    if (status != 'online') {
      throw FormatException('未知的 Core 状态: $status');
    }

    return GoCoreStatus(
      requestId: _requireString(json, 'requestId'),
      status: status,
      coreVersion: _requireString(data, 'coreVersion'),
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        _requireInt(json, 'timestamp'),
        isUtc: true,
      ),
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        _requireInt(data, 'startedAt'),
        isUtc: true,
      ),
    );
  }
}

enum GoCoreAvailability { online, offline, error }

class GoCoreStatusResult {
  const GoCoreStatusResult({
    required this.availability,
    required this.message,
    this.status,
    this.requestId,
  });

  final GoCoreAvailability availability;
  final String message;
  final GoCoreStatus? status;
  final String? requestId;

  factory GoCoreStatusResult.online(GoCoreStatus status) {
    return GoCoreStatusResult(
      availability: GoCoreAvailability.online,
      message: 'Go Core 连接正常',
      status: status,
      requestId: status.requestId,
    );
  }

  factory GoCoreStatusResult.offline({
    required String message,
    required String requestId,
  }) {
    return GoCoreStatusResult(
      availability: GoCoreAvailability.offline,
      message: message,
      requestId: requestId,
    );
  }

  factory GoCoreStatusResult.error({
    required String message,
    required String requestId,
  }) {
    return GoCoreStatusResult(
      availability: GoCoreAvailability.error,
      message: message,
      requestId: requestId,
    );
  }
}

Map<String, Object?> _requireMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is Map<String, Object?>) {
    return value;
  }
  if (value is Map) {
    return Map<String, Object?>.from(value);
  }
  throw FormatException('字段 $key 必须是对象');
}

String _requireString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) {
    return value;
  }
  throw FormatException('字段 $key 必须是非空字符串');
}

int _requireInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) {
    return value;
  }
  throw FormatException('字段 $key 必须是整数');
}
