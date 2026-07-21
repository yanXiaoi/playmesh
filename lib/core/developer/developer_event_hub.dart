import 'dart:async';

class DeveloperEventHub {
  DeveloperEventHub()
    : _controller = StreamController<Map<String, Object?>>.broadcast();

  final StreamController<Map<String, Object?>> _controller;
  final List<Map<String, Object?>> _recentLogs = [];
  int _eventSequence = 0;
  String? _runtimeProjectId;
  String? _runtimeRunId;

  static const maxRecentLogs = 500;

  Stream<Map<String, Object?>> get events => _controller.stream;

  bool get hasListeners => _controller.hasListener;
  List<Map<String, Object?>> get recentLogs => List.unmodifiable(
    _recentLogs.map((event) => Map<String, Object?>.unmodifiable(event)),
  );

  void emit(Map<String, Object?> event) {
    final normalized = <String, Object?>{
      'eventId': 'event-${++_eventSequence}',
      ...event,
    };
    if (normalized['type'] == 'runtime.log') {
      normalized.putIfAbsent('projectId', () => _runtimeProjectId);
      normalized.putIfAbsent('runId', () => _runtimeRunId);
      _recentLogs.add(normalized);
      if (_recentLogs.length > maxRecentLogs) {
        _recentLogs.removeRange(0, _recentLogs.length - maxRecentLogs);
      }
    }
    if (_controller.hasListener && !_controller.isClosed) {
      _controller.add(normalized);
    }
  }

  void beginRuntime({String? projectId, String? runId}) {
    _runtimeProjectId = projectId;
    _runtimeRunId = runId;
    clearRecentLogs();
  }

  void clearRecentLogs() => _recentLogs.clear();
}

final developerEventHub = DeveloperEventHub();
