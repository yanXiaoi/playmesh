import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

final class RuntimeGoCore {
  RuntimeGoCore({this.address = '0.0.0.0:0'});

  static const _channel = MethodChannel('playmesh/go_core_host');
  static const _startTimeout = Duration(seconds: 8);

  String address;
  Process? _process;
  bool _started = false;
  bool _nativeStartAttempted = false;

  Uri get baseUri {
    if (!_started) throw StateError('Go Core 尚未启动');
    final value = Uri.parse('http://$address/');
    return value.host == '0.0.0.0' || value.host == '::'
        ? value.replace(host: '127.0.0.1')
        : value;
  }

  Future<void> start() async {
    if (_started) return;
    if (Platform.isAndroid) {
      _nativeStartAttempted = true;
      final bound = await _channel
          .invokeMethod<String>('start', {'address': address})
          .timeout(_startTimeout);
      if (bound == null) throw StateError('Android Go Core 未返回监听地址');
      address = _validateAddress(bound);
    } else if (Platform.isWindows) {
      address = await _startWindows();
    } else {
      throw UnsupportedError('Runtime 不支持 ${Platform.operatingSystem}');
    }
    _started = true;
    await _waitUntilHealthy().timeout(
      _startTimeout,
      onTimeout: () => throw StateError('Go Core 健康检查超时'),
    );
  }

  Future<String> _startWindows() async {
    final executable = File(
      '${File(Platform.resolvedExecutable).parent.path}'
      '${Platform.pathSeparator}playmesh-core.exe',
    );
    if (!await executable.exists()) {
      throw StateError('Runtime 缺少 ${executable.path}');
    }
    final process = await Process.start(executable.path, [
      '-addr',
      address,
      '-parent-pid',
      '$pid',
    ]);
    _process = process;
    final started = Completer<String>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          debugPrint(line);
          try {
            final record = jsonDecode(line);
            if (record is Map &&
                record['event'] == 'core.started' &&
                record['address'] is String &&
                !started.isCompleted) {
              started.complete(_validateAddress(record['address']! as String));
            }
          } on FormatException {
            // Go Core 的普通输出仍保留在调试日志。
          }
        });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(debugPrint);
    unawaited(
      process.exitCode.then((code) {
        if (!started.isCompleted) {
          started.completeError(StateError('Go Core 提前退出: $code'));
        }
        if (identical(_process, process)) _process = null;
      }),
    );
    return started.future.timeout(const Duration(seconds: 8));
  }

  Future<void> _waitUntilHealthy() async {
    Object? lastError;
    for (var attempt = 0; attempt < 40; attempt += 1) {
      try {
        final response = await http
            .get(baseUri.resolve('health'))
            .timeout(const Duration(milliseconds: 500));
        if (response.statusCode == HttpStatus.ok) return;
        lastError = 'HTTP ${response.statusCode}';
      } on Object catch (error) {
        lastError = error;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Go Core 健康检查失败: $lastError');
  }

  Future<void> close() async {
    if (!_started && _process == null && !_nativeStartAttempted) return;
    _started = false;
    if (Platform.isAndroid && _nativeStartAttempted) {
      await _channel
          .invokeMethod<void>('stop')
          .timeout(const Duration(seconds: 3));
      _nativeStartAttempted = false;
    }
    _process?.kill();
    _process = null;
  }
}

String _validateAddress(String address) {
  final uri = Uri.tryParse('http://$address/');
  if (uri == null || !uri.hasPort || uri.port == 0) {
    throw FormatException('Go Core 返回了无效地址: $address');
  }
  return address;
}
