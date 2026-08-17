import 'package:flutter/foundation.dart';

import '../../core/developer/developer_channel.dart';

enum DeveloperPortError { notInteger, outOfRange }

class DeveloperPortException implements Exception {
  const DeveloperPortException(this.error);

  final DeveloperPortError error;
}

class DeveloperSessionState {
  const DeveloperSessionState({
    this.session,
    this.port = defaultDeveloperPort,
    this.token = '',
    this.loading = false,
    this.targetEnabled,
    this.error,
  });

  final DeveloperSession? session;
  final int port;
  final String token;
  final bool loading;
  final bool? targetEnabled;
  final Object? error;

  bool get enabled => session?.enabled ?? false;

  DeveloperSessionState copyWith({
    DeveloperSession? session,
    bool clearSession = false,
    int? port,
    String? token,
    bool? loading,
    bool? targetEnabled,
    bool clearTargetEnabled = false,
    Object? error,
    bool clearError = false,
  }) {
    return DeveloperSessionState(
      session: clearSession ? null : (session ?? this.session),
      port: port ?? this.port,
      token: token ?? this.token,
      loading: loading ?? this.loading,
      targetEnabled: clearTargetEnabled
          ? null
          : (targetEnabled ?? this.targetEnabled),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// 只管理开发者网关的共享生命周期、端口与 Token。
///
/// 编辑器链接、打开方式、项目语义由各入口控制器独立管理。
class DeveloperSessionController extends ChangeNotifier {
  DeveloperSessionController(this.provider)
    : _state = DeveloperSessionState(loading: provider != null);

  final DeveloperSessionProvider? provider;
  DeveloperSessionState _state;
  bool _disposed = false;

  DeveloperSessionState get state => _state;

  Future<void> initialize() async {
    final activeProvider = provider;
    if (activeProvider == null) return;
    try {
      var port = _state.port;
      var token = _state.token;
      if (activeProvider
          case final DeveloperWorkspacePreferenceProvider preferences) {
        final preference = await preferences.loadDeveloperWorkspacePreference();
        port = preference.port;
        token = preference.token;
      }
      final session = await activeProvider.developerModeStatus();
      _setState(
        _state.copyWith(
          session: session.enabled ? session : null,
          clearSession: !session.enabled,
          port: session.port ?? port,
          token: session.token ?? token,
          loading: false,
          clearError: true,
        ),
      );
    } on Object catch (error) {
      _setState(_state.copyWith(loading: false, error: error));
    }
  }

  Future<void> enable({required String portText, required String token}) async {
    final activeProvider = provider;
    if (activeProvider == null) return;
    final port = int.tryParse(portText.trim());
    if (port == null) {
      _setState(
        _state.copyWith(
          error: const DeveloperPortException(DeveloperPortError.notInteger),
        ),
      );
      return;
    }
    if (port < 1 || port > 65535) {
      _setState(
        _state.copyWith(
          error: const DeveloperPortException(DeveloperPortError.outOfRange),
        ),
      );
      return;
    }
    _setState(
      _state.copyWith(
        port: port,
        token: token.trim(),
        loading: true,
        targetEnabled: true,
        clearError: true,
      ),
    );
    try {
      final session = await activeProvider.enableDeveloperMode(
        port: port,
        token: token.trim(),
      );
      _setState(
        _state.copyWith(
          session: session,
          port: session.port ?? port,
          token: session.token ?? token.trim(),
          loading: false,
          clearTargetEnabled: true,
        ),
      );
    } on Object catch (error) {
      _setState(
        _state.copyWith(loading: false, clearTargetEnabled: true, error: error),
      );
    }
  }

  Future<void> disable() async {
    final activeProvider = provider;
    if (activeProvider == null) return;
    _setState(
      _state.copyWith(loading: true, targetEnabled: false, clearError: true),
    );
    try {
      await activeProvider.disableDeveloperMode();
      _setState(
        _state.copyWith(
          clearSession: true,
          loading: false,
          clearTargetEnabled: true,
        ),
      );
    } on Object catch (error) {
      _setState(
        _state.copyWith(loading: false, clearTargetEnabled: true, error: error),
      );
    }
  }

  void _setState(DeveloperSessionState state) {
    if (_disposed) return;
    _state = state;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
