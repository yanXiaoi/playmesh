import 'package:flutter/material.dart';

enum WebViewDownloadStatus {
  queued,
  choosing,
  downloading,
  completed,
  cancelled,
  failed,
}

class WebViewDownloadTask {
  WebViewDownloadTask({
    required this.id,
    required this.name,
    this.source,
    this.totalBytes,
  }) : startedAt = DateTime.now();

  final String id;
  String name;
  final String? source;
  final DateTime startedAt;
  DateTime? finishedAt;
  String? destination;
  String? error;
  int receivedBytes = 0;
  int? totalBytes;
  WebViewDownloadStatus status = WebViewDownloadStatus.queued;
  bool get isActive => const [
    WebViewDownloadStatus.queued,
    WebViewDownloadStatus.choosing,
    WebViewDownloadStatus.downloading,
  ].contains(status);
  double? get progress => totalBytes != null && totalBytes! > 0
      ? (receivedBytes / totalBytes!).clamp(0, 1)
      : null;
}

class WebViewDownloadQueue extends ChangeNotifier {
  // Process memory only. Reopening a game reuses its history; another game ID
  // receives a separate queue. No storage, SDK or game-page projection exists.
  static final Map<String, WebViewDownloadQueue> _games = {};
  static WebViewDownloadQueue forGame(String gameId) =>
      _games.putIfAbsent(gameId, WebViewDownloadQueue.new);
  final Map<String, WebViewDownloadTask> _tasks = {};
  bool _closed = false;
  List<WebViewDownloadTask> get tasks =>
      _tasks.values.toList(growable: false).reversed.toList(growable: false);
  int get activeCount => _tasks.values.where((task) => task.isActive).length;
  WebViewDownloadTask? operator [](String id) => _tasks[id];
  void add(WebViewDownloadTask task) {
    if (_closed) return;
    _tasks[task.id] = task;
    notifyListeners();
  }

  void changed() {
    if (!_closed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
  }
}

/// Flutter overlay above the WebView texture/platform view, never game DOM.
class WebViewDownloadOverlay extends StatefulWidget {
  const WebViewDownloadOverlay({
    super.key,
    required this.queue,
    required this.child,
  });
  final WebViewDownloadQueue queue;
  final Widget child;

  @override
  State<WebViewDownloadOverlay> createState() => _WebViewDownloadOverlayState();
}

class _WebViewDownloadOverlayState extends State<WebViewDownloadOverlay> {
  int? _hiddenTaskCount;

  @override
  void didUpdateWidget(WebViewDownloadOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.queue != widget.queue) _hiddenTaskCount = null;
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      widget.child,
      Positioned(
        top: 12,
        right: 12,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: widget.queue,
            builder: (context, _) {
              final queue = widget.queue;
              final taskCount = queue.tasks.length;
              // Queues retain all tasks in memory. Progress and completion must
              // not undo dismissal; only adding a new task reveals the entry.
              if (taskCount == 0 || taskCount == _hiddenTaskCount) {
                return const SizedBox.shrink();
              }
              return Material(
                elevation: 5,
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                shape: const StadiumBorder(),
                clipBehavior: Clip.antiAlias,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: _text(context, '下载', 'Downloads'),
                      child: InkWell(
                        key: const ValueKey('webview-downloads-button'),
                        onTap: () => showDialog<void>(
                          context: context,
                          builder: (_) => _DownloadDialog(queue: queue),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 15,
                            vertical: 13,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                queue.activeCount > 0
                                    ? Icons.downloading_rounded
                                    : Icons.download_done_rounded,
                                size: 22,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${queue.activeCount > 0 ? queue.activeCount : queue.tasks.length}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('webview-downloads-hide-button'),
                      tooltip: _text(
                        context,
                        '隐藏下载图标（下载继续）',
                        'Hide downloads (downloads continue)',
                      ),
                      onPressed: () =>
                          setState(() => _hiddenTaskCount = taskCount),
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const Icon(Icons.close_rounded, size: 20),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ],
  );
}

class _DownloadDialog extends StatefulWidget {
  const _DownloadDialog({required this.queue});
  final WebViewDownloadQueue queue;
  @override
  State<_DownloadDialog> createState() => _DownloadDialogState();
}

class _DownloadDialogState extends State<_DownloadDialog> {
  String? selected;
  int filter = 0;
  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    clipBehavior: Clip.antiAlias,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620, maxHeight: 600),
      child: SizedBox(
        width: 620,
        child: ListenableBuilder(
          listenable: widget.queue,
          builder: (context, _) {
            final task = selected == null ? null : widget.queue[selected!];
            final tasks = widget.queue.tasks
                .where(
                  (task) =>
                      filter == 0 ||
                      (filter == 1
                          ? task.isActive
                          : task.status == WebViewDownloadStatus.completed),
                )
                .toList();
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                  child: Row(
                    children: [
                      if (task != null)
                        IconButton(
                          tooltip: _text(
                            context,
                            '返回下载列表',
                            'Back to downloads',
                          ),
                          onPressed: () => setState(() => selected = null),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                      Expanded(
                        child: Text(
                          task == null
                              ? _text(context, '下载', 'Downloads')
                              : _text(context, '任务详情', 'Download details'),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: _text(context, '关闭', 'Close'),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                ),
                if (task == null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final entry in [
                            (_text(context, '全部', 'All'), 0),
                            (_text(context, '下载中', 'Active'), 1),
                            (_text(context, '已完成', 'Completed'), 2),
                          ])
                            ChoiceChip(
                              label: Text(entry.$1),
                              selected: filter == entry.$2,
                              onSelected: (_) =>
                                  setState(() => filter = entry.$2),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: tasks.isEmpty
                        ? Center(
                            child: Text(
                              _text(context, '暂无下载任务', 'No downloads here'),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: tasks.length,
                            separatorBuilder: (_, _) =>
                                const Divider(indent: 72, height: 1),
                            itemBuilder: (context, index) {
                              final task = tasks[index];
                              return ListTile(
                                key: ValueKey('download-task-${task.id}'),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 8,
                                ),
                                leading: Icon(
                                  _statusIcon(task.status),
                                  color:
                                      task.status ==
                                          WebViewDownloadStatus.failed
                                      ? Theme.of(context).colorScheme.error
                                      : Theme.of(context).colorScheme.primary,
                                ),
                                title: Text(
                                  task.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 5),
                                    Text(
                                      '${_status(context, task.status)} · ${_size(task.receivedBytes)}${task.totalBytes == null ? '' : ' / ${_size(task.totalBytes!)}'}',
                                      style: const TextStyle(
                                        fontFeatures: [
                                          FontFeature.tabularFigures(),
                                        ],
                                      ),
                                    ),
                                    if (task.status ==
                                        WebViewDownloadStatus.downloading)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 9),
                                        child: LinearProgressIndicator(
                                          value: task.progress,
                                        ),
                                      ),
                                  ],
                                ),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                ),
                                onTap: () => setState(() => selected = task.id),
                              );
                            },
                          ),
                  ),
                ] else
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            task.name,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 20),
                          Text(
                            _status(context, task.status),
                            style: TextStyle(
                              color: task.status == WebViewDownloadStatus.failed
                                  ? Theme.of(context).colorScheme.error
                                  : Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (task.status == WebViewDownloadStatus.downloading)
                            LinearProgressIndicator(value: task.progress),
                          const SizedBox(height: 20),
                          _detail(
                            _text(context, '已下载', 'Transferred'),
                            '${_size(task.receivedBytes)}${task.progress == null ? '' : '  (${(task.progress! * 100).toStringAsFixed(0)}%)'}',
                          ),
                          _detail(
                            _text(context, '文件大小', 'File size'),
                            task.totalBytes == null
                                ? _text(context, '未知', 'Unknown')
                                : _size(task.totalBytes!),
                          ),
                          _detail(
                            _text(context, '保存位置', 'Saved to'),
                            task.destination ??
                                _text(context, '等待选择', 'Waiting for selection'),
                          ),
                          _detail(
                            _text(context, '来源', 'Source'),
                            _displaySource(task.source, context),
                          ),
                          _detail(
                            _text(context, '创建时间', 'Created'),
                            _date(task.startedAt),
                          ),
                          if (task.finishedAt != null)
                            _detail(
                              _text(context, '结束时间', 'Finished'),
                              _date(task.finishedAt!),
                            ),
                          if (task.error != null)
                            _detail(
                              _text(context, '失败原因', 'Error'),
                              task.error!,
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    ),
  );

  Widget _detail(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 4),
        SelectableText(value),
      ],
    ),
  );
}

String _text(BuildContext context, String zh, String en) =>
    Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
String _status(BuildContext context, WebViewDownloadStatus status) =>
    switch (status) {
      WebViewDownloadStatus.queued => _text(context, '等待下载', 'Queued'),
      WebViewDownloadStatus.choosing => _text(
        context,
        '选择保存位置',
        'Choosing location',
      ),
      WebViewDownloadStatus.downloading => _text(context, '下载中', 'Downloading'),
      WebViewDownloadStatus.completed => _text(context, '已完成', 'Completed'),
      WebViewDownloadStatus.cancelled => _text(context, '已取消', 'Cancelled'),
      WebViewDownloadStatus.failed => _text(context, '下载失败', 'Failed'),
    };
IconData _statusIcon(WebViewDownloadStatus status) => switch (status) {
  WebViewDownloadStatus.completed => Icons.task_alt_rounded,
  WebViewDownloadStatus.failed => Icons.error_outline_rounded,
  WebViewDownloadStatus.cancelled => Icons.cancel_outlined,
  WebViewDownloadStatus.queued ||
  WebViewDownloadStatus.choosing => Icons.schedule_rounded,
  WebViewDownloadStatus.downloading => Icons.downloading_rounded,
};
String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}

String _date(DateTime date) => date.toLocal().toString().split('.').first;
String _displaySource(String? source, BuildContext context) {
  final uri = source == null ? null : Uri.tryParse(source);
  if (uri == null || uri.scheme == 'blob' || uri.scheme == 'data') {
    return _text(context, '网页生成的文件', 'Generated by this page');
  }
  // Signed URL queries, fragments and userinfo are never shown in task details.
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}
