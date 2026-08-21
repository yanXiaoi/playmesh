import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'runtime_native_exporter_contract.dart';

RuntimeNativeExporter createRuntimeNativeExporter() =>
    IoRuntimeNativeExporter();

typedef RuntimeExportProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

final class IoRuntimeNativeExporter implements RuntimeNativeExporter {
  IoRuntimeNativeExporter({
    MethodChannel? androidChannel,
    this._windowsExecutablePath,
    RuntimeExportProcessStarter? processStarter,
    this.operationTimeout = const Duration(minutes: 5),
  }) : _androidChannel =
           androidChannel ?? const MethodChannel('playmesh/runtime_export'),
       _processStarter = processStarter ?? _startProcess;

  final MethodChannel _androidChannel;
  final String? _windowsExecutablePath;
  final RuntimeExportProcessStarter _processStarter;
  final Duration operationTimeout;

  @override
  Future<RuntimeNativeExportReport> exportAndroid(
    RuntimeAndroidNativeExportRequest request,
  ) => _invoke('exportAndroid', 'export-android', request.toJson());

  @override
  Future<RuntimeNativeExportReport> exportWindows(
    RuntimeWindowsNativeExportRequest request,
  ) => _invoke('exportWindows', 'export-windows', request.toJson());

  Future<RuntimeNativeExportReport> _invoke(
    String androidMethod,
    String windowsCommand,
    Map<String, Object?> request,
  ) async {
    final requestJson = jsonEncode(request);
    if (Platform.isAndroid) {
      final response = await _androidChannel.invokeMethod<String>(
        androidMethod,
        {'requestJson': requestJson},
      );
      if (response == null) {
        throw StateError('Android Runtime 导出器没有返回结果');
      }
      return _parseReport(response);
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('当前平台不支持 Runtime 安装包导出');
    }

    final executable =
        _windowsExecutablePath ??
        '${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}playmesh-apksign.exe';
    final requestFile = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-runtime-export-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await requestFile.writeAsString(requestJson, flush: true);
    try {
      final process = await _processStarter(executable, [
        windowsCommand,
        '-request-file',
        requestFile.path,
      ]);
      final stdoutOperation = utf8.decoder.bind(process.stdout).join();
      final stderrOperation = utf8.decoder.bind(process.stderr).join();
      int exitCode;
      try {
        exitCode = await process.exitCode.timeout(operationTimeout);
      } on TimeoutException {
        process.kill();
        throw TimeoutException('Runtime 原生导出器执行超时', operationTimeout);
      }
      final stdoutText = await stdoutOperation;
      final stderrText = await stderrOperation;
      if (exitCode != 0) {
        final diagnostic = stderrText.trim();
        throw ProcessException(
          executable,
          [windowsCommand, '-request-file', '<redacted>'],
          diagnostic.length > 2048 ? diagnostic.substring(0, 2048) : diagnostic,
          exitCode,
        );
      }
      return _parseReport(stdoutText.trim());
    } finally {
      if (await requestFile.exists()) await requestFile.delete();
    }
  }

  RuntimeNativeExportReport _parseReport(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('原生导出结果必须是对象');
    final outputPath = decoded['outputPath'];
    final sizeBytes = decoded['sizeBytes'];
    if (outputPath is! String ||
        outputPath.isEmpty ||
        sizeBytes is! int ||
        sizeBytes <= 0) {
      throw const FormatException('原生导出结果缺少有效输出路径或文件长度');
    }
    String? optionalString(String key) {
      final value = decoded[key];
      if (value == null) return null;
      if (value is! String || value.isEmpty) {
        throw FormatException('原生导出结果 $key 无效');
      }
      return value;
    }

    return RuntimeNativeExportReport(
      outputPath: outputPath,
      sizeBytes: sizeBytes,
      sha256: optionalString('sha256'),
      applicationId: optionalString('applicationId'),
      certificateSha256: optionalString('certificateSha256'),
    );
  }

  static Future<Process> _startProcess(
    String executable,
    List<String> arguments,
  ) => Process.start(executable, arguments, runInShell: false);
}
