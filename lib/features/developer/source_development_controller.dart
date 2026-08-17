import 'package:flutter/foundation.dart';

import '../../core/developer/developer_channel.dart';
import '../../core/network/lan_endpoint.dart';

class SourceDevelopmentState {
  const SourceDevelopmentState({
    this.links = const [],
    this.loading = false,
    this.error,
  });

  final List<LanEndpointCandidate> links;
  final bool loading;
  final Object? error;
}

/// 源代码工作区入口；不承载 GDevelop 的可用性或 URL 语义。
class SourceDevelopmentController extends ChangeNotifier {
  SourceDevelopmentController(this.provider);

  final SourceDevelopmentProvider? provider;
  SourceDevelopmentState _state = const SourceDevelopmentState();
  int _generation = 0;
  bool _disposed = false;

  SourceDevelopmentState get state => _state;

  Future<void> synchronize(DeveloperSession? session) async {
    final generation = ++_generation;
    final activeProvider = provider;
    if (session?.enabled != true || activeProvider == null) {
      _setState(const SourceDevelopmentState());
      return;
    }
    _setState(const SourceDevelopmentState(loading: true));
    try {
      final links = await activeProvider.sourceWorkspaceLinks(session!);
      if (generation != _generation) return;
      _setState(SourceDevelopmentState(links: List.unmodifiable(links)));
    } on Object catch (error) {
      if (generation != _generation) return;
      _setState(SourceDevelopmentState(error: error));
    }
  }

  Uri inAppWorkspaceUri(Uri workspaceUri) =>
      workspaceUri.replace(host: '127.0.0.1');

  void _setState(SourceDevelopmentState state) {
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
