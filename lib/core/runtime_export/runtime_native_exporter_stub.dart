import 'runtime_native_exporter_contract.dart';

RuntimeNativeExporter createRuntimeNativeExporter() =>
    const _UnsupportedRuntimeNativeExporter();

final class _UnsupportedRuntimeNativeExporter implements RuntimeNativeExporter {
  const _UnsupportedRuntimeNativeExporter();

  @override
  Future<RuntimeNativeExportReport> exportAndroid(
    RuntimeAndroidNativeExportRequest request,
  ) => Future.error(UnsupportedError('当前平台不支持 Android Runtime 导出'));

  @override
  Future<RuntimeNativeExportReport> exportWindows(
    RuntimeWindowsNativeExportRequest request,
  ) => Future.error(UnsupportedError('当前平台不支持 Windows Runtime 导出'));
}
