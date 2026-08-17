import 'package:flutter/foundation.dart';

import 'endpoint_probe_contract.dart';
import 'named_download_endpoint.dart';

class EndpointPickerController extends ChangeNotifier {
  EndpointPickerController({
    required Iterable<NamedDownloadEndpoint> endpoints,
    required this.probeService,
    this.allowUnreachableSelection = false,
  }) : endpoints = List.unmodifiable(endpoints);

  final List<NamedDownloadEndpoint> endpoints;
  final bool allowUnreachableSelection;
  final EndpointProbeService probeService;
  final Map<String, EndpointProbeResult> _results = {};

  NamedDownloadEndpoint? _selected;
  int _probeGeneration = 0;
  var _disposed = false;

  NamedDownloadEndpoint? get selected => _selected;

  bool get isProbing => _results.values.any(
    (result) => result.state == EndpointProbeState.probing,
  );

  EndpointProbeResult? resultFor(NamedDownloadEndpoint endpoint) =>
      _results[normalizedEndpointProbeCacheKey(endpoint.url)];

  bool canSelect(NamedDownloadEndpoint endpoint) {
    final state = resultFor(endpoint)?.state;
    if (state == EndpointProbeState.reachable ||
        state == EndpointProbeState.unsupported) {
      return true;
    }
    return allowUnreachableSelection &&
        state != null &&
        state != EndpointProbeState.probing;
  }

  bool select(NamedDownloadEndpoint endpoint) {
    final owned = endpoints.any(
      (candidate) =>
          normalizedEndpointProbeCacheKey(candidate.url) ==
          normalizedEndpointProbeCacheKey(endpoint.url),
    );
    if (!owned || !canSelect(endpoint)) return false;
    if (identical(_selected, endpoint)) return true;
    _selected = endpoint;
    notifyListeners();
    return true;
  }

  void clearSelection() {
    if (_selected == null) return;
    _selected = null;
    notifyListeners();
  }

  Future<void> probeAll() => _runProbe(refresh: false);

  Future<void> refresh() => _runProbe(refresh: true);

  Future<void> _runProbe({required bool refresh}) async {
    final generation = ++_probeGeneration;
    await probeService.probeAll(
      endpoints.map((endpoint) => endpoint.url),
      refresh: refresh,
      onUpdate: (result) {
        if (_disposed || generation != _probeGeneration) return;
        final key = normalizedEndpointProbeCacheKey(result.url);
        if (!endpoints.any(
          (endpoint) => normalizedEndpointProbeCacheKey(endpoint.url) == key,
        )) {
          return;
        }
        _results[key] = result;
        final selected = _selected;
        if (selected != null &&
            normalizedEndpointProbeCacheKey(selected.url) == key &&
            !canSelect(selected)) {
          _selected = null;
        }
        notifyListeners();
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _probeGeneration += 1;
    super.dispose();
  }
}
