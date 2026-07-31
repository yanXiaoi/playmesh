const playmeshDevelopmentCredentialHeader = 'X-Playmesh-Development-Credential';

/// 游戏 Web 资源来源的引擎无关描述。
///
/// 第三方工程适配器只在 CLI 中把预览或构建输出映射为开发资源来源，App 网关不按
/// 工程类型建立分支。
abstract interface class GameWebResourceSource {
  /// 安装资源需要在 App 网关验证包内路径；临时开发资源必须把 URI 不透明地交给 CLI。
  bool get validateRequestPaths;

  T resolveWith<T>(GameWebResourceSourceResolver<T> resolver);
}

/// 平台资源 Provider 支持的公共来源操作。
///
/// App 只区分正式安装包和通用开发传输。工程引擎适配止于 Developer CLI 边界；
/// 新增引擎不能增加 App 来源类型或 Resolver 操作。
abstract interface class GameWebResourceSourceResolver<T> {
  T installed({required String packageRootPath});

  T development({
    required Uri sourceUri,
    required Map<String, String> requestHeaders,
    required DateTime expiresAt,
  });
}

final class InstalledGameWebResourceSource implements GameWebResourceSource {
  const InstalledGameWebResourceSource({required this.packageRootPath});

  final String packageRootPath;

  @override
  bool get validateRequestPaths => true;

  @override
  T resolveWith<T>(GameWebResourceSourceResolver<T> resolver) =>
      resolver.installed(packageRootPath: packageRootPath);
}

final class DevelopmentGameWebResourceSource implements GameWebResourceSource {
  const DevelopmentGameWebResourceSource({
    required this.baseUri,
    required this.credential,
    required this.expiresAt,
  });

  final Uri baseUri;
  final String credential;
  final DateTime expiresAt;

  @override
  bool get validateRequestPaths => false;

  @override
  T resolveWith<T>(GameWebResourceSourceResolver<T> resolver) =>
      resolver.development(
        sourceUri: baseUri,
        requestHeaders: {playmeshDevelopmentCredentialHeader: credential},
        expiresAt: expiresAt,
      );
}

const playmeshDevelopmentRestartControlPath = '.playmesh-development/restart';
