import 'runtime_package_manager_contract.dart';
import 'runtime_package_manager_stub.dart'
    if (dart.library.io) 'runtime_package_manager_io.dart'
    as platform;

export 'runtime_package_distribution.dart';
export 'runtime_package_downloader_contract.dart';
export 'runtime_package_manager_contract.dart';
export 'runtime_package_models.dart';
export 'runtime_package_store_contract.dart';

RuntimePackageManager createRuntimePackageManager() =>
    platform.createRuntimePackageManager();
