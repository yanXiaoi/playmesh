import 'dart:ui';

import 'developer_native_file_save.dart';
import 'developer_native_file_save_service_contract.dart';

DeveloperNativeFileSaveService createDeveloperNativeFileSaveService() =>
    const _UnsupportedDeveloperNativeFileSaveService();

final class _UnsupportedDeveloperNativeFileSaveService
    implements DeveloperNativeFileSaveService {
  const _UnsupportedDeveloperNativeFileSaveService();

  @override
  Future<DeveloperNativeFileSaveResult> save({
    required DeveloperNativeFileSaveMessage message,
    required Uri workspaceUri,
    Rect? sharePositionOrigin,
  }) {
    throw UnsupportedError('当前平台不支持 App 原生文件保存');
  }
}
