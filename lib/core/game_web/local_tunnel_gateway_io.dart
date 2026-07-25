import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'local_tunnel_gateway_contract.dart';

Future<LocalTunnelGateway> startLocalTunnelGateway({
  required Uri targetBaseUri,
}) async {
  _validateTargetBaseUri(targetBaseUri);
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final gateway = _IoLocalTunnelGateway(
    server: server,
    targetHost: targetBaseUri.host,
    targetPort: targetBaseUri.port,
  );
  gateway.listen();
  return gateway;
}

Future<LocalTunnelGateway> startLocalUpgradeTunnelGateway({
  required Uri targetBaseUri,
  required String path,
  required Map<String, String> headers,
}) async {
  _validateTargetBaseUri(targetBaseUri);
  if (!path.startsWith('/') || path.contains('?') || path.contains('#')) {
    throw const FormatException('受控 Upgrade 路径必须是绝对路径');
  }
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final gateway = _IoLocalUpgradeTunnelGateway(
    server: server,
    targetBaseUri: targetBaseUri,
    path: path,
    headers: Map.unmodifiable(headers),
  );
  gateway.listen();
  return gateway;
}

class _IoLocalTunnelGateway implements LocalTunnelGateway {
  _IoLocalTunnelGateway({
    required this.server,
    required this.targetHost,
    required this.targetPort,
  });

  final ServerSocket server;
  final String targetHost;
  final int targetPort;
  final Set<Socket> _connections = {};
  StreamSubscription<Socket>? _subscription;
  bool _closed = false;

  @override
  Uri get localBaseUri =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  void listen() {
    _subscription = server.listen(
      (local) => unawaited(_forward(local)),
      onError: (_) => close(),
    );
  }

  Future<void> _forward(Socket local) async {
    if (_closed) {
      await local.close();
      return;
    }
    Socket? remote;
    try {
      remote = await Socket.connect(targetHost, targetPort);
      if (_closed) {
        await local.close();
        await remote.close();
        return;
      }
      _connections
        ..add(local)
        ..add(remote);
      final completed = Completer<void>();

      void complete() {
        if (!completed.isCompleted) completed.complete();
      }

      StreamSubscription<Uint8List> pipe(Socket source, Socket destination) {
        late final StreamSubscription<Uint8List> subscription;
        subscription = source.listen(
          (chunk) {
            subscription.pause();
            destination.add(chunk);
            unawaited(() async {
              try {
                await destination.flush();
                if (!completed.isCompleted) subscription.resume();
              } on Object {
                complete();
              }
            }());
          },
          onError: (_) => complete(),
          onDone: complete,
          cancelOnError: true,
        );
        return subscription;
      }

      final localSubscription = pipe(local, remote);
      final remoteSubscription = pipe(remote, local);
      await completed.future;
      await localSubscription.cancel();
      await remoteSubscription.cancel();
    } on Object {
      // 单条资源连接失败由 WebView 按原有网络错误处理，不扩大为网关级故障。
    } finally {
      _connections.remove(local);
      if (remote != null) _connections.remove(remote);
      local.destroy();
      remote?.destroy();
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await server.close();
    final connections = _connections.toList(growable: false);
    _connections.clear();
    for (final connection in connections) {
      connection.destroy();
    }
  }
}

class _IoLocalUpgradeTunnelGateway implements LocalTunnelGateway {
  _IoLocalUpgradeTunnelGateway({
    required this.server,
    required this.targetBaseUri,
    required this.path,
    required this.headers,
  });

  final ServerSocket server;
  final Uri targetBaseUri;
  final String path;
  final Map<String, String> headers;
  final Set<Socket> _localConnections = {};
  final Set<_BufferedSocket> _remoteConnections = {};
  StreamSubscription<Socket>? _subscription;
  bool _closed = false;

  @override
  Uri get localBaseUri =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  void listen() {
    _subscription = server.listen(
      (local) => unawaited(_forward(local)),
      onError: (_) => close(),
    );
  }

  Future<void> _forward(Socket local) async {
    if (_closed) {
      local.destroy();
      return;
    }
    _BufferedSocket? remote;
    _localConnections.add(local);
    try {
      remote = await _openUpgrade(
        targetBaseUri: targetBaseUri,
        path: path,
        headers: headers,
      );
      if (_closed) return;
      _remoteConnections.add(remote);
      await _bridgeBufferedAndPlain(remote, local);
    } on Object {
      // 单条 Core 连接失败由 SDK 按原有网络错误处理，不扩大为网关级故障。
    } finally {
      _localConnections.remove(local);
      local.destroy();
      if (remote != null) {
        _remoteConnections.remove(remote);
        await remote.close();
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await server.close();
    final locals = _localConnections.toList(growable: false);
    final remotes = _remoteConnections.toList(growable: false);
    _localConnections.clear();
    _remoteConnections.clear();
    for (final local in locals) {
      local.destroy();
    }
    for (final remote in remotes) {
      await remote.close();
    }
  }
}

class _BufferedSocket {
  _BufferedSocket(this.socket) : _iterator = StreamIterator<Uint8List>(socket);

  final Socket socket;
  final StreamIterator<Uint8List> _iterator;
  Uint8List _buffer = Uint8List(0);
  int _offset = 0;
  bool _closed = false;

  void add(List<int> bytes) => socket.add(bytes);

  Future<void> flush() => socket.flush();

  Future<Uint8List> readExact(int length) async {
    final result = Uint8List(length);
    var written = 0;
    while (written < length) {
      final chunk = await readChunk();
      if (chunk == null) {
        throw const SocketException('受控 Upgrade 连接提前关闭');
      }
      final copied = min(length - written, chunk.length);
      result.setRange(written, written + copied, chunk);
      written += copied;
      if (copied < chunk.length) {
        _offset -= chunk.length - copied;
      }
    }
    return result;
  }

  Future<Uint8List?> readChunk() async {
    if (_offset >= _buffer.length) {
      if (!await _iterator.moveNext()) return null;
      _buffer = _iterator.current;
      _offset = 0;
    }
    final result = Uint8List.sublistView(_buffer, _offset);
    _offset = _buffer.length;
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
    socket.destroy();
  }
}

Future<_BufferedSocket> _openUpgrade({
  required Uri targetBaseUri,
  required String path,
  required Map<String, String> headers,
}) async {
  final socket = await Socket.connect(targetBaseUri.host, targetBaseUri.port);
  final connection = _BufferedSocket(socket);
  try {
    final host = targetBaseUri.port == 80
        ? targetBaseUri.host
        : '${targetBaseUri.host}:${targetBaseUri.port}';
    final request = StringBuffer()
      ..write('GET $path HTTP/1.1\r\n')
      ..write('Host: $host\r\n')
      ..write('Connection: Upgrade\r\n')
      ..write('Upgrade: $playmeshCoreTunnelProtocol\r\n');
    for (final MapEntry(:key, :value) in headers.entries) {
      request.write('$key: $value\r\n');
    }
    request.write('\r\n');
    connection.add(request.toString().codeUnits);
    await connection.flush();
    final responseHeader = await _readUpgradeHeader(connection);
    if (!responseHeader.split('\r\n').first.contains(' 101 ')) {
      throw StateError('受控 Core Upgrade 失败');
    }
    return connection;
  } on Object {
    await connection.close();
    rethrow;
  }
}

Future<String> _readUpgradeHeader(_BufferedSocket connection) async {
  const maxHeaderBytes = 16 * 1024;
  final bytes = <int>[];
  while (bytes.length < maxHeaderBytes) {
    bytes.add((await connection.readExact(1)).single);
    final length = bytes.length;
    if (length >= 4 &&
        bytes[length - 4] == 13 &&
        bytes[length - 3] == 10 &&
        bytes[length - 2] == 13 &&
        bytes[length - 1] == 10) {
      return String.fromCharCodes(bytes);
    }
  }
  throw const FormatException('受控 Upgrade 响应头过大');
}

Future<void> _bridgeBufferedAndPlain(
  _BufferedSocket remote,
  Socket local,
) async {
  final completed = Completer<void>();
  var writing = Future<void>.value();
  late final StreamSubscription<Uint8List> localSubscription;

  void complete() {
    if (!completed.isCompleted) completed.complete();
  }

  localSubscription = local.listen(
    (chunk) {
      localSubscription.pause();
      remote.add(chunk);
      writing = writing
          .then((_) => remote.flush())
          .catchError((Object _) => complete())
          .whenComplete(() {
            if (!completed.isCompleted) localSubscription.resume();
          });
    },
    onError: (_) => complete(),
    onDone: complete,
    cancelOnError: true,
  );
  unawaited(() async {
    try {
      while (!completed.isCompleted) {
        final chunk = await remote.readChunk();
        if (chunk == null) {
          complete();
          return;
        }
        local.add(chunk);
        await local.flush();
      }
    } on Object {
      complete();
    }
  }());
  await completed.future;
  await localSubscription.cancel();
  await writing;
}

void _validateTargetBaseUri(Uri targetBaseUri) {
  if (targetBaseUri.scheme != 'http' ||
      targetBaseUri.host.isEmpty ||
      !targetBaseUri.hasPort) {
    throw const FormatException('透明回环网关目标必须是带端口的 HTTP 地址');
  }
}
