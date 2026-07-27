part of '../../sdk_feature_registry.dart';

const appUiSdkSource = SdkSourceFragment(
  id: 'app.ui',
  target: SdkSourceTarget.app,
  order: 25,
  typeScript: r'''
  let appUiReturnFocus = null;
  let appUiFocusCapturePending = false;

  function appUiError(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
  }

  function captureAppUiReturnFocus() {
    const documentObject = global.document;
    const activeElement = documentObject?.activeElement;
    appUiReturnFocus =
      activeElement &&
      activeElement !== documentObject?.body &&
      activeElement !== documentObject?.documentElement &&
      activeElement.isConnected !== false &&
      typeof activeElement.focus === "function"
        ? activeElement
        : null;
    appUiFocusCapturePending = true;
  }

  function clearAppUiReturnFocus() {
    appUiReturnFocus = null;
    appUiFocusCapturePending = false;
  }

  function restoreAppUiReturnFocus() {
    if (!appUiFocusCapturePending) return;
    appUiFocusCapturePending = false;
    const documentObject = global.document;
    const returnFocus = appUiReturnFocus;
    appUiReturnFocus = null;
    if (
      returnFocus &&
      returnFocus.isConnected !== false &&
      typeof returnFocus.focus === "function"
    ) {
      try {
        returnFocus.focus({ preventScroll: true });
        if (documentObject?.activeElement === returnFocus) return;
      } catch (_) {
        // Fall through to the game document.
      }
    }
    const gameDocumentTarget =
      documentObject?.body || documentObject?.documentElement;
    if (!gameDocumentTarget || typeof gameDocumentTarget.focus !== "function") {
      return;
    }
    const previousTabIndex = gameDocumentTarget.getAttribute?.("tabindex");
    try {
      if (gameDocumentTarget.tabIndex < 0) {
        gameDocumentTarget.setAttribute?.("tabindex", "-1");
      }
      gameDocumentTarget.focus({ preventScroll: true });
    } catch (_) {
      // The host has already hidden the platform UI; no further fallback exists.
    } finally {
      if (previousTabIndex == null) {
        gameDocumentTarget.removeAttribute?.("tabindex");
      } else {
        gameDocumentTarget.setAttribute?.("tabindex", previousTabIndex);
      }
    }
  }

  function openAppSharePanel() {
    if (!global.navigator?.userActivation?.isActive) {
      return Promise.reject(appUiError(
        "user_activation_required",
        "打开分享界面需要当前用户操作",
      ));
    }
    captureAppUiReturnFocus();
    return request("app.ui.openSharePanel", { userActivation: true })
      .catch((error) => {
        clearAppUiReturnFocus();
        throw error;
      });
  }

  function showAppToolDock() {
    captureAppUiReturnFocus();
    return request("app.ui.toolDock.show").catch((error) => {
      clearAppUiReturnFocus();
      throw error;
    });
  }

  function hideAppToolDock() {
    return request("app.ui.toolDock.hide").then((result) => {
      restoreAppUiReturnFocus();
      return result;
    });
  }
''',
);

final class _AppUiFeature implements _AppSdkCommandFeature {
  @override
  SdkSourceFragment get source => appUiSdkSource;

  @override
  List<SdkVersionRange> get supportedVersions => const [
    SdkVersionRange('1.0.0', SdkVersionRange.last),
  ];

  @override
  Set<String> get commands => const {
    'app.ui.openSharePanel',
    'app.ui.toolDock.show',
    'app.ui.toolDock.hide',
  };

  @override
  Future<Object?> execute(
    AppSdkCommandContext context,
    SdkCommandEnvelope command,
  ) {
    switch (command.name) {
      case 'app.ui.openSharePanel':
        if (command.payload['userActivation'] != true) {
          throw const SdkCommandException(
            'user_activation_required',
            '打开分享界面需要当前用户操作',
          );
        }
        return context.openSharePanel();
      case 'app.ui.toolDock.show':
        return context.setToolDockVisible(true);
      case 'app.ui.toolDock.hide':
        return context.setToolDockVisible(false);
    }
    throw StateError('未注册的 App 平台 UI 命令: ${command.name}');
  }
}
