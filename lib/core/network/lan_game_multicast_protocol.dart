import 'dart:convert';
import 'dart:typed_data';

import 'lan_game_advertisement.dart';

const lanGameMulticastAddress = '239.255.80.77';
const lanGameMulticastPort = 53584;
const lanGameMulticastProtocolVersion = 1;
const maxLanGameMulticastDatagramBytes = 1200;
const maxLanGameMulticastAttributes = 16;
const maxLanGameMulticastAttributeKeyBytes = 32;
const maxLanGameMulticastAttributeValueBytes = 512;
const maxLanGameMulticastRecords = 256;
const maxLanGameMulticastRecordsPerSource = 32;
const lanGameMulticastAnnouncementInterval = Duration(seconds: 1);
const lanGameMulticastAnnouncementJitter = Duration(milliseconds: 100);
const lanGameMulticastRecordTtl = Duration(seconds: 4);
const lanGameMulticastInterfaceReconcileInterval = Duration(seconds: 1);

const _protocolMagic = 'playmesh.lan.game';
const maxLanGameMulticastRevision = 9007199254740991;
const _announcementKeys = <String>{
  'magic',
  'version',
  'kind',
  'instance',
  'revision',
  'gatewayPort',
  'payload',
};
const _goodbyeKeys = <String>{
  'magic',
  'version',
  'kind',
  'instance',
  'revision',
};

enum LanGameMulticastMessageKind { announcement, goodbye }

final class LanGameMulticastMessage {
  const LanGameMulticastMessage({
    required this.kind,
    required this.instanceId,
    required this.revision,
    this.gatewayPort,
    this.payload,
  });

  final LanGameMulticastMessageKind kind;
  final String instanceId;
  final int revision;
  final int? gatewayPort;
  final Map<String, String>? payload;

  Uint8List encode() {
    _validate();
    final value = <String, Object>{
      'magic': _protocolMagic,
      'version': lanGameMulticastProtocolVersion,
      'kind': kind.name,
      'instance': instanceId,
      'revision': revision,
    };
    if (kind == LanGameMulticastMessageKind.announcement) {
      value
        ..['gatewayPort'] = gatewayPort!
        ..['payload'] = payload!;
    }
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > maxLanGameMulticastDatagramBytes) {
      throw const FormatException('局域网发现数据报过大');
    }
    return Uint8List.fromList(bytes);
  }

  static LanGameMulticastMessage decode(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxLanGameMulticastDatagramBytes) {
      throw const FormatException('局域网发现数据报大小无效');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes, allowMalformed: false));
    } on Object {
      throw const FormatException('局域网发现数据报编码无效');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('局域网发现数据报字段无效');
    }
    if (decoded['magic'] != _protocolMagic ||
        decoded['version'] != lanGameMulticastProtocolVersion) {
      throw const FormatException('局域网发现数据报版本无效');
    }
    final kind = switch (decoded['kind']) {
      'announcement' => LanGameMulticastMessageKind.announcement,
      'goodbye' => LanGameMulticastMessageKind.goodbye,
      _ => throw const FormatException('局域网发现数据报类型无效'),
    };
    final expectedKeys = kind == LanGameMulticastMessageKind.announcement
        ? _announcementKeys
        : _goodbyeKeys;
    final actualKeys = decoded.keys.toSet();
    if (actualKeys.difference(expectedKeys).isNotEmpty ||
        expectedKeys.difference(actualKeys).isNotEmpty) {
      throw const FormatException('局域网发现数据报字段无效');
    }
    Map<String, String>? payload;
    if (kind == LanGameMulticastMessageKind.announcement) {
      final rawPayload = decoded['payload'];
      if (rawPayload is! Map<String, Object?>) {
        throw const FormatException('局域网发现数据报 payload 无效');
      }
      final parsed = <String, String>{};
      for (final entry in rawPayload.entries) {
        if (entry.value is! String) {
          throw const FormatException('局域网发现数据报 payload 类型无效');
        }
        parsed[entry.key] = entry.value! as String;
      }
      payload = Map.unmodifiable(parsed);
    }
    final message = LanGameMulticastMessage(
      kind: kind,
      instanceId: decoded['instance'] is String
          ? decoded['instance']! as String
          : '',
      revision: _strictInt(decoded['revision']),
      gatewayPort: kind == LanGameMulticastMessageKind.announcement
          ? _strictInt(decoded['gatewayPort'])
          : null,
      payload: payload,
    );
    message._validate();
    return message;
  }

  void _validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(instanceId)) {
      throw const FormatException('局域网发现数据报 instance 无效');
    }
    if (revision < 1 || revision > maxLanGameMulticastRevision) {
      throw const FormatException('局域网发现数据报 revision 无效');
    }
    if (kind == LanGameMulticastMessageKind.goodbye) {
      if (gatewayPort != null || payload != null) {
        throw const FormatException('局域网发现 goodbye 字段无效');
      }
      return;
    }
    final port = gatewayPort;
    final values = payload;
    if (port == null || port < 1 || port > 65535) {
      throw const FormatException('局域网发现数据报端口无效');
    }
    if (values == null ||
        values.isEmpty ||
        values.length > maxLanGameMulticastAttributes) {
      throw const FormatException('局域网发现数据报 payload 数量无效');
    }
    for (final entry in values.entries) {
      final keyBytes = utf8.encode(entry.key);
      final valueBytes = utf8.encode(entry.value);
      if (!RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').hasMatch(entry.key) ||
          keyBytes.length > maxLanGameMulticastAttributeKeyBytes ||
          valueBytes.length > maxLanGameMulticastAttributeValueBytes) {
        throw const FormatException('局域网发现数据报 payload 无效');
      }
    }
    // 在进入有界缓存前即执行同一业务 payload 契约，坏记录不能挤占合法项。
    LanGameAdvertisement.fromPayload(instanceId: instanceId, payload: values);
  }
}

int _strictInt(Object? value) => value is int && value is! bool ? value : -1;

sealed class LanGameMulticastCacheEvent {
  const LanGameMulticastCacheEvent({required this.platformId});

  final String platformId;
}

final class LanGameMulticastCacheResolved extends LanGameMulticastCacheEvent {
  const LanGameMulticastCacheResolved({
    required super.platformId,
    required this.sourceAddress,
    required this.gatewayPort,
    required this.instanceId,
    required this.revision,
    required this.payload,
  });

  final String sourceAddress;
  final String instanceId;
  final int revision;
  final int gatewayPort;
  final Map<String, String> payload;
}

final class LanGameMulticastCacheLost extends LanGameMulticastCacheEvent {
  const LanGameMulticastCacheLost(String platformId)
    : super(platformId: platformId);
}

final class LanGameMulticastCache {
  LanGameMulticastCache({
    this.recordTtl = lanGameMulticastRecordTtl,
    this.maxRecords = maxLanGameMulticastRecords,
    this.maxRecordsPerSource = maxLanGameMulticastRecordsPerSource,
  }) {
    if (recordTtl <= Duration.zero) {
      throw ArgumentError.value(recordTtl, 'recordTtl');
    }
    if (maxRecords < 1) {
      throw RangeError.range(maxRecords, 1, null, 'maxRecords');
    }
    if (maxRecordsPerSource < 1) {
      throw RangeError.range(
        maxRecordsPerSource,
        1,
        null,
        'maxRecordsPerSource',
      );
    }
  }

  final Duration recordTtl;
  final int maxRecords;
  final int maxRecordsPerSource;
  final Map<String, _CachedMulticastRecord> _records = {};

  int get length => _records.length;

  List<LanGameMulticastCacheEvent> accept({
    required List<int> datagram,
    required String sourceAddress,
    required Duration now,
  }) {
    if (!_isUsableSourceIpv4(sourceAddress)) return const [];
    final LanGameMulticastMessage message;
    try {
      message = LanGameMulticastMessage.decode(datagram);
    } on Object {
      // 坏包必须静默隔离，不能把原始包或其中的邀请凭据写入日志。
      return const [];
    }
    final platformId = '${message.instanceId}\u0000$sourceAddress';
    final existing = _records[platformId];
    if (existing != null) {
      if (message.revision < existing.revision) return const [];
      if (message.kind == LanGameMulticastMessageKind.announcement &&
          message.revision == existing.revision &&
          !_samePayload(existing, message)) {
        return const [];
      }
    }
    if (message.kind == LanGameMulticastMessageKind.goodbye) {
      if (existing == null) return const [];
      final wasPresent = existing.present;
      _records.remove(platformId);
      _records[platformId] = _CachedMulticastRecord(
        revision: message.revision,
        sourceAddress: sourceAddress,
        gatewayPort: null,
        payload: null,
        expiresAt: now + recordTtl,
        present: false,
      );
      return wasPresent
          ? <LanGameMulticastCacheEvent>[LanGameMulticastCacheLost(platformId)]
          : const [];
    }
    if (existing != null &&
        !existing.present &&
        message.revision == existing.revision) {
      return const [];
    }
    if (existing == null &&
        _records.values
                .where((record) => record.sourceAddress == sourceAddress)
                .length >=
            maxRecordsPerSource) {
      return const [];
    }
    final events = <LanGameMulticastCacheEvent>[];
    if (existing == null && _records.length >= maxRecords) {
      final evicted = _records.keys.first;
      final removed = _records.remove(evicted)!;
      if (removed.present) events.add(LanGameMulticastCacheLost(evicted));
    }
    final changed =
        existing == null ||
        !existing.present ||
        message.revision > existing.revision;
    _records.remove(platformId);
    _records[platformId] = _CachedMulticastRecord(
      revision: message.revision,
      sourceAddress: sourceAddress,
      gatewayPort: message.gatewayPort,
      payload: message.payload,
      expiresAt: now + recordTtl,
      present: true,
    );
    if (!changed) return events;
    events.add(
      LanGameMulticastCacheResolved(
        platformId: platformId,
        sourceAddress: sourceAddress,
        instanceId: message.instanceId,
        revision: message.revision,
        gatewayPort: message.gatewayPort!,
        payload: message.payload!,
      ),
    );
    return events;
  }

  List<LanGameMulticastCacheLost> expire(Duration now) {
    final lost = <LanGameMulticastCacheLost>[];
    for (final entry in _records.entries.toList(growable: false)) {
      if (entry.value.expiresAt <= now) {
        _records.remove(entry.key);
        if (entry.value.present) {
          lost.add(LanGameMulticastCacheLost(entry.key));
        }
      }
    }
    return lost;
  }

  void clear() => _records.clear();
}

final class _CachedMulticastRecord {
  const _CachedMulticastRecord({
    required this.revision,
    required this.sourceAddress,
    required this.gatewayPort,
    required this.payload,
    required this.expiresAt,
    required this.present,
  });

  final int revision;
  final String sourceAddress;
  final int? gatewayPort;
  final Map<String, String>? payload;
  final Duration expiresAt;
  final bool present;
}

bool _samePayload(
  _CachedMulticastRecord existing,
  LanGameMulticastMessage message,
) =>
    existing.gatewayPort == message.gatewayPort &&
    existing.payload != null &&
    message.payload != null &&
    _sameAttributes(existing.payload!, message.payload!);

bool _sameAttributes(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

bool _isUsableSourceIpv4(String value) {
  final parts = value.split('.');
  if (parts.length != 4) return false;
  final bytes = <int>[];
  for (final part in parts) {
    if (part.isEmpty || !RegExp(r'^\d{1,3}$').hasMatch(part)) return false;
    final byte = int.tryParse(part);
    if (byte == null || byte < 0 || byte > 255) return false;
    bytes.add(byte);
  }
  final first = bytes.first;
  return first != 0 && first != 127 && first < 224;
}
