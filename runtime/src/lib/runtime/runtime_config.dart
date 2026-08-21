import 'dart:convert';

import 'package:flutter/services.dart';

const runtimeConfigAsset = 'assets/runtime/runtime-config.json';
const runtimePackageKeyIdMaxLength = 1024;

final class RuntimeConfig {
  const RuntimeConfig({
    required this.gameAsset,
    required this.packageCodec,
    required this.packageKeyId,
  });

  factory RuntimeConfig.fromJson(Map<String, Object?> json) {
    if (json['schemaVersion'] != 1) {
      throw const FormatException('runtime-config.json 版本不受支持');
    }
    final package = json['package'] is Map
        ? Map<String, Object?>.from(json['package']! as Map)
        : const <String, Object?>{};
    final gameAsset = (package['asset'] ?? json['gameAsset']) as String?;
    if (gameAsset == null ||
        !gameAsset.startsWith('assets/runtime/') ||
        gameAsset.contains('\\') ||
        gameAsset
            .split('/')
            .any(
              (segment) => segment.isEmpty || segment == '.' || segment == '..',
            )) {
      throw const FormatException('Runtime 游戏包资源路径无效');
    }
    final codec = package['codec'] as String? ?? 'plain-zip';
    if (codec != 'plain-zip' && codec != 'aes-gcm-v1') {
      throw FormatException('Runtime 游戏包编码不受支持: $codec');
    }
    final keyId = package['keyId'];
    if (codec == 'aes-gcm-v1' && (keyId is! String || keyId.isEmpty)) {
      throw const FormatException('加密 Runtime 游戏包必须声明 package.keyId');
    }
    if (keyId is String && keyId.length > runtimePackageKeyIdMaxLength) {
      throw const FormatException('Runtime 游戏包 package.keyId 过长');
    }
    if (codec == 'plain-zip' && keyId != null) {
      throw const FormatException('未加密 Runtime 游戏包不能声明 package.keyId');
    }
    return RuntimeConfig(
      gameAsset: gameAsset,
      packageCodec: codec,
      packageKeyId: keyId as String?,
    );
  }

  static Future<RuntimeConfig> load() async {
    final source = await rootBundle.loadString(runtimeConfigAsset);
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const FormatException('runtime-config.json 根节点必须是对象');
    }
    return RuntimeConfig.fromJson(Map<String, Object?>.from(decoded));
  }

  final String gameAsset;
  final String packageCodec;
  final String? packageKeyId;
}

Uri parseRuntimeRelayServer(String value) {
  final uri = Uri.tryParse(value.trim());
  const allowedParameters = {'token'};
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.queryParametersAll.keys.any(
        (key) => !allowedParameters.contains(key),
      ) ||
      (uri.queryParametersAll['token']?.length ?? 0) > 1) {
    throw const FormatException('Runtime 中转地址必须是有效的 HTTP/HTTPS publicURL');
  }
  return uri;
}

abstract interface class RuntimeEncryptedPackageHost {
  Future<Uint8List> decrypt(String keyId);
}

/// Decrypts the one fixed Runtime game asset through the platform host. The
/// encrypted bytes and private key never cross from native code into Dart.
final class PlatformRuntimeEncryptedPackageHost
    implements RuntimeEncryptedPackageHost {
  const PlatformRuntimeEncryptedPackageHost();

  static const _channel = MethodChannel('playmesh/runtime_key');

  @override
  Future<Uint8List> decrypt(String keyId) async {
    if (keyId.isEmpty || keyId.length > runtimePackageKeyIdMaxLength) {
      throw const FormatException('Runtime 游戏包 package.keyId 无效');
    }
    final clear = await _channel.invokeMethod<Uint8List>(
      'decryptRuntimePackage',
      {'keyId': keyId},
    );
    if (clear == null || clear.isEmpty) {
      throw StateError('原生 Runtime 未返回解密后的游戏包');
    }
    return clear;
  }
}

final class RuntimePackageDecoder {
  const RuntimePackageDecoder({
    this.encryptedPackageHost = const PlatformRuntimeEncryptedPackageHost(),
  });

  final RuntimeEncryptedPackageHost encryptedPackageHost;

  Future<Uint8List> decode(RuntimeConfig config, [Uint8List? input]) async {
    if (config.packageCodec == 'plain-zip') {
      if (input == null || input.isEmpty) {
        throw const FormatException('未加密 Runtime 游戏包为空');
      }
      return input;
    }
    final keyId = config.packageKeyId;
    if (keyId == null || keyId.isEmpty) {
      throw const FormatException('加密游戏包缺少 package.keyId');
    }
    return encryptedPackageHost.decrypt(keyId);
  }
}
