import 'runtime_native_exporter_contract.dart';
import 'runtime_native_exporter_stub.dart'
    if (dart.library.io) 'runtime_native_exporter_io.dart'
    as platform;

export 'runtime_native_exporter_contract.dart';

RuntimeNativeExporter createRuntimeNativeExporter() =>
    platform.createRuntimeNativeExporter();
