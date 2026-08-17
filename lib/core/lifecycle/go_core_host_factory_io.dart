import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'go_core_host_contract.dart';

GoCoreHost createBundledGoCoreHost({required String address}) {
  if (Platform.isAndroid) {
    return _MobileGoCoreHost(address);
  }
  if (Platform.isWindows) {
    return _WindowsGoCoreHost(address);
  }
  return _UnsupportedIoGoCoreHost(address);
}

class _MobileGoCoreHost implements GoCoreHost {
  _MobileGoCoreHost(this._address);

  static const _channel = MethodChannel('playmesh/go_core_host');

  String _address;
  bool _started = false;

  @override
  Uri get endpoint => _localEndpoint(_address);

  @override
  Future<void> start() async {
    if (_started) {
      return;
    }

    try {
      final boundAddress = await _channel.invokeMethod<String>('start', {
        'address': _address,
      });
      if (boundAddress == null || boundAddress.isEmpty) {
        throw const FormatException('原生层未返回监听地址');
      }
      _validateBoundAddress(boundAddress);
      _address = boundAddress;
      _started = true;
    } on PlatformException catch (error) {
      throw GoCoreHostException(
        code: error.code,
        userMessage: '无法启动移动端内置 Go Core。',
        diagnostic: error.message ?? 'unknown platform error',
        cause: error,
      );
    } on Object catch (error) {
      throw GoCoreHostException(
        code: '${Platform.operatingSystem}_core_start_failed',
        userMessage: '无法启动移动端内置 Go Core。',
        diagnostic: error.toString(),
        cause: error,
      );
    }
  }

  @override
  Future<void> stop() async {
    if (!_started) {
      return;
    }

    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      throw GoCoreHostException(
        code: error.code,
        userMessage: '无法停止移动端内置 Go Core。',
        diagnostic: error.message ?? 'unknown platform error',
        cause: error,
      );
    } finally {
      _started = false;
    }
  }
}

class _WindowsGoCoreHost implements GoCoreHost {
  _WindowsGoCoreHost(this._address);

  String _address;
  Process? _process;
  bool _closed = false;

  @override
  Uri get endpoint => _localEndpoint(_address);

  @override
  Future<void> start() async {
    if (_closed) {
      throw const GoCoreHostException(
        code: 'core_host_closed',
        userMessage: '内置 Go Core 已关闭。',
        diagnostic: 'start called after stop',
      );
    }
    if (_process != null) {
      return;
    }

    final executableDirectory = File(Platform.resolvedExecutable).parent;
    final coreExecutable = File(
      '${executableDirectory.path}${Platform.pathSeparator}playmesh-core.exe',
    );
    if (!coreExecutable.existsSync()) {
      throw GoCoreHostException(
        code: 'bundled_core_missing',
        userMessage: '应用缺少内置 Go Core，请重新安装。',
        diagnostic: 'missing ${coreExecutable.path}',
      );
    }

    try {
      final process = await Process.start(coreExecutable.path, [
        '-addr',
        _address,
        '-parent-pid',
        '$pid',
      ], mode: ProcessStartMode.normal);
      if (_closed) {
        process.kill();
        throw const GoCoreHostException(
          code: 'core_start_cancelled',
          userMessage: '内置 Go Core 启动已取消。',
          diagnostic: 'host stopped while process was starting',
        );
      }
      _process = process;
      final addressCompleter = Completer<String>();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            debugPrint(line);
            final boundAddress = _readStartedAddress(line);
            if (boundAddress != null && !addressCompleter.isCompleted) {
              addressCompleter.complete(boundAddress);
            }
          });
      process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => debugPrint(line));
      unawaited(
        process.exitCode.then((exitCode) {
          if (!addressCompleter.isCompleted) {
            addressCompleter.completeError(
              GoCoreHostException(
                code: 'core_process_exited',
                userMessage: '内置 Go Core 启动失败。',
                diagnostic: 'exitCode=$exitCode',
              ),
            );
          }
          if (identical(_process, process)) {
            _process = null;
          }
          debugPrint(
            jsonEncode({
              'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
              'level': exitCode == 0 ? 'info' : 'error',
              'component': 'go-core-host',
              'event': 'core.process_exited',
              'exitCode': exitCode,
            }),
          );
        }),
      );
      final boundAddress = await addressCompleter.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw const GoCoreHostException(
          code: 'core_start_timeout',
          userMessage: '等待内置 Go Core 启动超时。',
          diagnostic: 'missing core.started event',
        ),
      );
      _validateBoundAddress(boundAddress);
      _address = boundAddress;
    } on GoCoreHostException {
      _process?.kill();
      _process = null;
      rethrow;
    } on Object catch (error) {
      _process?.kill();
      _process = null;
      throw GoCoreHostException(
        code: 'core_process_start_failed',
        userMessage: '无法启动内置 Go Core。',
        diagnostic: error.toString(),
        cause: error,
      );
    }
  }

  @override
  Future<void> stop() {
    _closed = true;
    final process = _process;
    _process = null;
    if (process != null) {
      // Windows 会直接终止进程；退出码仅用于异步日志，不能阻塞应用退出。
      process.kill();
    }
    return Future<void>.value();
  }
}

class _UnsupportedIoGoCoreHost implements GoCoreHost {
  const _UnsupportedIoGoCoreHost(this.address);

  final String address;

  @override
  Uri get endpoint => Uri.parse('http://$address/health');

  @override
  Future<void> start() {
    throw GoCoreHostException(
      code: 'unsupported_platform',
      userMessage: '当前平台暂不支持内置 Go Core。',
      diagnostic: 'unsupported ${Platform.operatingSystem}',
    );
  }

  @override
  Future<void> stop() async {}
}

String? _readStartedAddress(String line) {
  try {
    final record = jsonDecode(line);
    if (record is Map &&
        record['event'] == 'core.started' &&
        record['address'] is String) {
      return record['address'] as String;
    }
  } on FormatException {
    // 子进程的非 JSON 输出仍会保留在调试日志中。
  }
  return null;
}

void _validateBoundAddress(String address) {
  final endpoint = Uri.tryParse('http://$address/health');
  if (endpoint == null || !endpoint.hasPort || endpoint.port == 0) {
    throw FormatException('无效的 Go Core 监听地址: $address');
  }
}

Uri _localEndpoint(String address) {
  final endpoint = Uri.parse('http://$address/health');
  if (endpoint.host == '0.0.0.0' || endpoint.host == '::') {
    return endpoint.replace(host: '127.0.0.1');
  }
  return endpoint;
}
