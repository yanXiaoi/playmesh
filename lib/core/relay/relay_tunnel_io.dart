import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;

import '../game_web/game_web_gateway_contract.dart';
import 'relay_tunnel_contract.dart';

const _protocolMagic = <int>[0x50, 0x4d, 0x52, 0x31];
const _inviteTokenVersion = 4;
const _inviteTokenParameter = playmeshGameInvitationTokenParameter;
const _invitePathPrefix = 'j';
const _saltLength = 16;
const _macLength = 16;
const _maxPlaintextRecordBytes = 32 * 1024;
const _maxUpgradeHeaderBytes = 16 * 1024;
const _clientToHostDirection = 0x434c4e54;
const _hostToClientDirection = 0x484f5354;
const _warmHostConnectionCount = 4;

Future<RelayHostSession> startRelayHostSession({
  required Uri serverBaseUri,
  required String sourceToken,
  required String hostPath,
  required String clientPath,
  required Uri authorityWebBaseUri,
  required Uri authorityCoreBaseUri,
  required Uri authorityEntryUri,
  required int maxConnectionsPerTunnel,
}) async {
  _validateServerBase(serverBaseUri);
  _validateRelayPath(hostPath, 'hostPath');
  _validateRelayPath(clientPath, 'clientPath');
  final authorityEntry = _parseAuthorityEntryUri(authorityEntryUri);
  if (maxConnectionsPerTunnel < 1) {
    throw const FormatException('中转服务器声明的单隧道连接上限必须是正整数');
  }
  final credentials = await _createTunnel(
    serverBaseUri: serverBaseUri,
    sourceToken: sourceToken,
    hostPath: hostPath,
  );
  final sharedSecret = _randomBytes(32);
  final session = _IoRelayHostSession(
    serverBaseUri: serverBaseUri,
    sourceToken: sourceToken,
    hostPath: hostPath,
    clientPath: clientPath,
    credentials: credentials,
    sharedSecret: sharedSecret,
    authorityWebBaseUri: authorityWebBaseUri,
    authorityCoreBaseUri: authorityCoreBaseUri,
    authorityEntryPath: authorityEntry.path,
    shareToken: authorityEntry.shareToken,
    maxConnectionsPerTunnel: maxConnectionsPerTunnel,
  );
  session.start();
  return session;
}

Future<RelayClientGateway> startRelayClientGateway({
  required Uri invitationUri,
  required RelayTarget target,
}) async {
  final configuration = _RelayClientConfiguration.fromInvitation(invitationUri);
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final gateway = _IoRelayClientGateway(
    server: server,
    configuration: configuration,
    target: target,
  );
  gateway.start();
  return gateway;
}

class _RelayCredentials {
  const _RelayCredentials({
    required this.tunnelId,
    required this.hostLease,
    required this.joinCapability,
    required this.expiresAt,
  });

  factory _RelayCredentials.fromJson(Map<String, Object?> json) {
    return _RelayCredentials(
      tunnelId: _requiredString(json, 'tunnelId'),
      hostLease: _requiredString(json, 'hostLease'),
      joinCapability: _requiredString(json, 'joinCapability'),
      expiresAt: DateTime.parse(_requiredString(json, 'expiresAt')).toUtc(),
    );
  }

  final String tunnelId;
  final String hostLease;
  final String joinCapability;
  final DateTime expiresAt;
}

class _RelayClientConfiguration {
  const _RelayClientConfiguration({
    required this.serverBaseUri,
    required this.clientPath,
    required this.tunnelId,
    required this.joinCapability,
    required this.sharedSecret,
    required this.authorityEntryPath,
    required this.shareToken,
  });

  factory _RelayClientConfiguration.fromInvitation(Uri invitationUri) {
    final segments = invitationUri.pathSegments;
    if (segments.length != 2 ||
        segments.first != _invitePathPrefix ||
        segments.last.trim().isEmpty ||
        invitationUri.hasQuery) {
      throw const FormatException('公共中转邀请路径无效');
    }
    final fragment = parsePlaymeshInvitationFragment(invitationUri.fragment);
    if (fragment.length != 1 ||
        fragment[_inviteTokenParameter]?.trim().isNotEmpty != true) {
      throw const FormatException('公共中转邀请缺少 inviteToken');
    }
    final payload = _decodeInviteToken(fragment[_inviteTokenParameter]!);
    _validateRelayPath(payload.clientPath, 'clientPath');
    final serverBase = Uri(
      scheme: invitationUri.scheme,
      host: invitationUri.host,
      port: invitationUri.hasPort ? invitationUri.port : null,
    );
    _validateServerBase(serverBase);
    return _RelayClientConfiguration(
      serverBaseUri: serverBase,
      clientPath: payload.clientPath,
      tunnelId: segments.last,
      joinCapability: payload.joinCapability,
      sharedSecret: payload.sharedSecret,
      authorityEntryPath: payload.authorityEntryPath,
      shareToken: payload.shareToken,
    );
  }

  final Uri serverBaseUri;
  final String clientPath;
  final String tunnelId;
  final String joinCapability;
  final Uint8List sharedSecret;
  final String authorityEntryPath;
  final String shareToken;
}

class _InviteTokenPayload {
  const _InviteTokenPayload({
    required this.clientPath,
    required this.joinCapability,
    required this.authorityEntryPath,
    required this.shareToken,
    required this.sharedSecret,
  });

  final String clientPath;
  final String joinCapability;
  final String authorityEntryPath;
  final String shareToken;
  final Uint8List sharedSecret;
}

class _IoRelayHostSession implements RelayHostSession {
  _IoRelayHostSession({
    required this.serverBaseUri,
    required this.sourceToken,
    required this.hostPath,
    required this.clientPath,
    required this.credentials,
    required this.sharedSecret,
    required this.authorityWebBaseUri,
    required this.authorityCoreBaseUri,
    required this.authorityEntryPath,
    required this.shareToken,
    required this.maxConnectionsPerTunnel,
  });

  final Uri serverBaseUri;
  final String sourceToken;
  final String hostPath;
  final String clientPath;
  final _RelayCredentials credentials;
  final Uint8List sharedSecret;
  final Uri authorityWebBaseUri;
  final Uri authorityCoreBaseUri;
  final String authorityEntryPath;
  final String shareToken;
  final int maxConnectionsPerTunnel;
  final StreamController<RelayConnectionStatus> _statuses =
      StreamController<RelayConnectionStatus>.broadcast(sync: true);
  final Set<_BufferedConnection> _connections = {};
  final Set<Future<void>> _slotOperations = {};
  bool _closed = false;
  int _connectingCount = 0;
  int _idleCount = 0;
  int _activeCount = 0;
  int _retryCount = 0;
  int _connectionCount = 0;
  RelayConnectionStatus _status = RelayConnectionStatus.connecting;

  @override
  Uri get joinUri => serverBaseUri.replace(
    path: '/$_invitePathPrefix/${credentials.tunnelId}',
    fragment: Uri(
      queryParameters: {
        _inviteTokenParameter: _encodeInviteToken(
          _InviteTokenPayload(
            clientPath: clientPath,
            joinCapability: credentials.joinCapability,
            authorityEntryPath: authorityEntryPath,
            shareToken: shareToken,
            sharedSecret: sharedSecret,
          ),
        ),
      },
    ).query,
  );

  @override
  RelayConnectionStatus get status => _status;

  @override
  Stream<RelayConnectionStatus> get statuses => _statuses.stream;

  @override
  int get connectionCount => _connectionCount;

  @override
  DateTime get expiresAt => credentials.expiresAt;

  void start() => _ensureWarmConnections();

  void _ensureWarmConnections() {
    if (_closed) return;
    if (!DateTime.now().toUtc().isBefore(credentials.expiresAt)) {
      _setStatus(RelayConnectionStatus.disconnected);
      return;
    }
    final warmTarget = min(_warmHostConnectionCount, maxConnectionsPerTunnel);
    final missingWarm = warmTarget - (_connectingCount + _idleCount);
    final availableCapacity =
        maxConnectionsPerTunnel -
        (_connectingCount + _idleCount + _activeCount);
    final additions = min(missingWarm, availableCapacity);
    for (var index = 0; index < additions; index += 1) {
      _connectingCount += 1;
      late final Future<void> operation;
      operation = _openHostSlot().whenComplete(() {
        _slotOperations.remove(operation);
      });
      _slotOperations.add(operation);
    }
  }

  Future<void> _openHostSlot() async {
    var state = _HostSlotState.connecting;
    _BufferedConnection? connection;
    var failed = false;
    try {
      connection = await _openRelayUpgrade(
        serverBaseUri: serverBaseUri,
        path: hostPath,
        queryParameters: {'tunnelId': credentials.tunnelId},
        headers: {
          if (sourceToken.trim().isNotEmpty)
            HttpHeaders.authorizationHeader: 'Bearer ${sourceToken.trim()}',
          'X-Playmesh-Host-Lease': credentials.hostLease,
        },
      );
      if (_closed) return;
      _connectingCount -= 1;
      _idleCount += 1;
      state = _HostSlotState.idle;
      _connections.add(connection);
      _syncConnectionCount();
      _retryCount = 0;
      _setStatus(RelayConnectionStatus.connected);

      final header = await connection.readExact(
        _protocolMagic.length + _saltLength,
      );
      if (_closed) return;
      _idleCount -= 1;
      _activeCount += 1;
      state = _HostSlotState.active;
      // 待机连接一旦被配对，立即补回热连接；活跃连接结束后本槽位自然退出。
      _ensureWarmConnections();
      await _serveHostConnection(connection, header);
    } on Object {
      failed = true;
      if (!_closed) {
        _retryCount += 1;
        await Future<void>.delayed(
          Duration(milliseconds: min(3000, 150 * (1 << min(_retryCount, 4)))),
        );
      }
    } finally {
      switch (state) {
        case _HostSlotState.connecting:
          _connectingCount -= 1;
          break;
        case _HostSlotState.idle:
          _idleCount -= 1;
          break;
        case _HostSlotState.active:
          _activeCount -= 1;
          break;
      }
      if (connection != null) {
        _connections.remove(connection);
        _syncConnectionCount();
        await connection.close();
      }
      if (!_closed) {
        if (failed && _connections.isEmpty) {
          _setStatus(RelayConnectionStatus.retrying);
        }
        _ensureWarmConnections();
      }
    }
  }

  Future<void> _serveHostConnection(
    _BufferedConnection relay,
    Uint8List header,
  ) async {
    if (!_equalBytes(
      header.sublist(0, _protocolMagic.length),
      _protocolMagic,
    )) {
      throw const FormatException('公共中转加密通道协议不匹配');
    }
    final salt = header.sublist(_protocolMagic.length);
    final keys = await _deriveDirectionalKeys(sharedSecret, salt);
    final reader = _EncryptedRecordReader(
      relay,
      secretKey: keys.clientToHost,
      direction: _clientToHostDirection,
    );
    final writer = _EncryptedRecordWriter(
      relay,
      secretKey: keys.hostToClient,
      direction: _hostToClientDirection,
    );
    final handshake = await reader.read();
    if (handshake.length != 1) {
      throw const FormatException('公共中转目标握手无效');
    }
    final target = switch (handshake.single) {
      1 => authorityWebBaseUri,
      2 => authorityCoreBaseUri,
      _ => throw const FormatException('公共中转目标类型无效'),
    };
    final authority = await Socket.connect(target.host, target.port);
    try {
      await _bridgeEncryptedAndPlain(
        encryptedReader: reader,
        encryptedWriter: writer,
        plain: authority,
      );
    } finally {
      authority.destroy();
    }
  }

  void _setStatus(RelayConnectionStatus value) {
    if (_status == value) return;
    _status = value;
    if (!_statuses.isClosed) _statuses.add(value);
  }

  void _syncConnectionCount() {
    _connectionCount = _connections.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _setStatus(RelayConnectionStatus.disconnected);
    final connections = _connections.toList(growable: false);
    _connections.clear();
    _connectionCount = 0;
    for (final connection in connections) {
      await connection.close();
    }
    await Future.wait(_slotOperations.toList(growable: false));
    try {
      await _deleteTunnel(
        serverBaseUri: serverBaseUri,
        sourceToken: sourceToken,
        hostPath: hostPath,
        credentials: credentials,
      );
    } on Object {
      // 隧道凭证有有效期，断线时删除失败不阻塞本地资源回收。
    }
    await _statuses.close();
  }
}

enum _HostSlotState { connecting, idle, active }

class _IoRelayClientGateway implements RelayClientGateway {
  _IoRelayClientGateway({
    required this.server,
    required this.configuration,
    required this.target,
  });

  final ServerSocket server;
  final _RelayClientConfiguration configuration;
  final RelayTarget target;
  final Set<Socket> _localConnections = {};
  final Set<_BufferedConnection> _relayConnections = {};
  StreamSubscription<Socket>? _subscription;
  bool _closed = false;

  @override
  Uri get localBaseUri =>
      Uri(scheme: 'http', host: '127.0.0.1', port: server.port);

  @override
  Uri get localEntryUri {
    return localBaseUri.replace(
      path: configuration.authorityEntryPath,
      fragment: Uri(
        queryParameters: {
          playmeshGameInvitationTokenParameter: configuration.shareToken,
        },
      ).query,
    );
  }

  void start() {
    _subscription = server.listen(
      (socket) => unawaited(_serve(socket)),
      onError: (_) => close(),
    );
  }

  Future<void> _serve(Socket local) async {
    if (_closed) {
      local.destroy();
      return;
    }
    _BufferedConnection? relay;
    _localConnections.add(local);
    try {
      relay = await _openRelayUpgrade(
        serverBaseUri: configuration.serverBaseUri,
        path: configuration.clientPath,
        queryParameters: {'tunnelId': configuration.tunnelId},
        headers: {'X-Playmesh-Join-Capability': configuration.joinCapability},
      );
      if (_closed) return;
      _relayConnections.add(relay);
      final salt = _randomBytes(_saltLength);
      relay.add([..._protocolMagic, ...salt]);
      await relay.flush();
      final keys = await _deriveDirectionalKeys(
        configuration.sharedSecret,
        salt,
      );
      final reader = _EncryptedRecordReader(
        relay,
        secretKey: keys.hostToClient,
        direction: _hostToClientDirection,
      );
      final writer = _EncryptedRecordWriter(
        relay,
        secretKey: keys.clientToHost,
        direction: _clientToHostDirection,
      );
      await writer.write(Uint8List.fromList([target.protocolCode]));
      await _bridgeEncryptedAndPlain(
        encryptedReader: reader,
        encryptedWriter: writer,
        plain: local,
      );
    } on Object {
      // 单条浏览器连接失败由 WebView 按普通网络错误处理。
    } finally {
      _localConnections.remove(local);
      local.destroy();
      if (relay != null) {
        _relayConnections.remove(relay);
        await relay.close();
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
    final relays = _relayConnections.toList(growable: false);
    _localConnections.clear();
    _relayConnections.clear();
    for (final socket in locals) {
      socket.destroy();
    }
    for (final relay in relays) {
      await relay.close();
    }
  }
}

class _DirectionalKeys {
  const _DirectionalKeys({
    required this.clientToHost,
    required this.hostToClient,
  });

  final SecretKey clientToHost;
  final SecretKey hostToClient;
}

class _EncryptedRecordWriter {
  _EncryptedRecordWriter(
    this.connection, {
    required this.secretKey,
    required this.direction,
  });

  final _BufferedConnection connection;
  final SecretKey secretKey;
  final int direction;
  final AesGcm algorithm = AesGcm.with256bits();
  int _counter = 0;

  Future<void> write(Uint8List bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      final end = min(offset + _maxPlaintextRecordBytes, bytes.length);
      final nonce = _nonce(direction, _counter++);
      final box = await algorithm.encrypt(
        bytes.sublist(offset, end),
        secretKey: secretKey,
        nonce: nonce,
      );
      final header = ByteData(4)..setUint32(0, box.cipherText.length);
      connection.add(header.buffer.asUint8List());
      connection.add(box.cipherText);
      connection.add(box.mac.bytes);
      await connection.flush();
      offset = end;
    }
  }
}

class _EncryptedRecordReader {
  _EncryptedRecordReader(
    this.connection, {
    required this.secretKey,
    required this.direction,
  });

  final _BufferedConnection connection;
  final SecretKey secretKey;
  final int direction;
  final AesGcm algorithm = AesGcm.with256bits();
  int _counter = 0;

  Future<Uint8List> read() async {
    final lengthBytes = await connection.readExact(4);
    final length = ByteData.sublistView(lengthBytes).getUint32(0);
    if (length < 1 || length > _maxPlaintextRecordBytes) {
      throw const FormatException('公共中转密文记录长度无效');
    }
    final cipherText = await connection.readExact(length);
    final mac = await connection.readExact(_macLength);
    final nonce = _nonce(direction, _counter++);
    final clearText = await algorithm.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: secretKey,
    );
    return Uint8List.fromList(clearText);
  }
}

class _BufferedConnection {
  _BufferedConnection(this.socket)
    : _iterator = StreamIterator<Uint8List>(socket);

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
      if (_offset >= _buffer.length) {
        if (!await _iterator.moveNext()) {
          throw const SocketException('公共中转连接提前关闭');
        }
        _buffer = _iterator.current;
        _offset = 0;
      }
      final available = _buffer.length - _offset;
      final copied = min(length - written, available);
      result.setRange(written, written + copied, _buffer, _offset);
      written += copied;
      _offset += copied;
    }
    return result;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _iterator.cancel();
    socket.destroy();
  }
}

Future<void> _bridgeEncryptedAndPlain({
  required _EncryptedRecordReader encryptedReader,
  required _EncryptedRecordWriter encryptedWriter,
  required Socket plain,
}) async {
  final completed = Completer<void>();
  var writing = Future<void>.value();
  late final StreamSubscription<Uint8List> plainSubscription;

  void finish() {
    if (!completed.isCompleted) completed.complete();
  }

  plainSubscription = plain.listen(
    (chunk) {
      plainSubscription.pause();
      writing = writing
          .then((_) => encryptedWriter.write(chunk))
          .catchError((Object _) => finish())
          .whenComplete(plainSubscription.resume);
    },
    onError: (_) => finish(),
    onDone: finish,
    cancelOnError: true,
  );
  unawaited(() async {
    try {
      while (!completed.isCompleted) {
        final clearText = await encryptedReader.read();
        plain.add(clearText);
        await plain.flush();
      }
    } on Object {
      finish();
    }
  }());
  await completed.future;
  await plainSubscription.cancel();
  await writing;
}

Future<_RelayCredentials> _createTunnel({
  required Uri serverBaseUri,
  required String sourceToken,
  required String hostPath,
}) async {
  final response = await http
      .post(
        serverBaseUri.resolve(hostPath),
        headers: {
          if (sourceToken.trim().isNotEmpty)
            HttpHeaders.authorizationHeader: 'Bearer ${sourceToken.trim()}',
        },
      )
      .timeout(const Duration(seconds: 12));
  final body = _jsonObject(response.bodyBytes);
  if (response.statusCode != HttpStatus.created) {
    throw StateError(
      (body['message'] ?? body['error'] ?? '创建公共中转隧道失败').toString(),
    );
  }
  return _RelayCredentials.fromJson(body);
}

Future<void> _deleteTunnel({
  required Uri serverBaseUri,
  required String sourceToken,
  required String hostPath,
  required _RelayCredentials credentials,
}) async {
  final endpoint = serverBaseUri
      .resolve(hostPath)
      .replace(queryParameters: {'tunnelId': credentials.tunnelId});
  await http
      .delete(
        endpoint,
        headers: {
          if (sourceToken.trim().isNotEmpty)
            HttpHeaders.authorizationHeader: 'Bearer ${sourceToken.trim()}',
          'X-Playmesh-Host-Lease': credentials.hostLease,
        },
      )
      .timeout(const Duration(seconds: 8));
}

Future<_BufferedConnection> _openRelayUpgrade({
  required Uri serverBaseUri,
  required String path,
  required Map<String, String> queryParameters,
  required Map<String, String> headers,
}) async {
  final endpoint = serverBaseUri
      .resolve(path)
      .replace(queryParameters: queryParameters);
  final port = endpoint.port;
  final Socket socket = endpoint.scheme == 'https'
      ? await SecureSocket.connect(endpoint.host, port)
      : await Socket.connect(endpoint.host, port);
  final connection = _BufferedConnection(socket);
  try {
    final target = endpoint.hasQuery
        ? '${endpoint.path}?${endpoint.query}'
        : endpoint.path;
    final defaultPort =
        (endpoint.scheme == 'http' && port == 80) ||
        (endpoint.scheme == 'https' && port == 443);
    final host = defaultPort ? endpoint.host : '${endpoint.host}:$port';
    final request = StringBuffer()
      ..write('GET $target HTTP/1.1\r\n')
      ..write('Host: $host\r\n')
      ..write('Connection: Upgrade\r\n')
      ..write('Upgrade: playmesh-tunnel\r\n');
    for (final MapEntry(:key, :value) in headers.entries) {
      request.write('$key: $value\r\n');
    }
    request.write('\r\n');
    connection.add(ascii.encode(request.toString()));
    await connection.flush();
    final responseHeader = await _readUpgradeHeader(connection);
    final statusLine = responseHeader.split('\r\n').first;
    if (!statusLine.contains(' 101 ')) {
      throw StateError('公共中转 Upgrade 失败：$statusLine');
    }
    return connection;
  } on Object {
    await connection.close();
    rethrow;
  }
}

Future<String> _readUpgradeHeader(_BufferedConnection connection) async {
  final bytes = <int>[];
  while (bytes.length < _maxUpgradeHeaderBytes) {
    bytes.add((await connection.readExact(1)).single);
    final length = bytes.length;
    if (length >= 4 &&
        bytes[length - 4] == 13 &&
        bytes[length - 3] == 10 &&
        bytes[length - 2] == 13 &&
        bytes[length - 1] == 10) {
      return ascii.decode(bytes);
    }
  }
  throw const FormatException('公共中转 Upgrade 响应头过大');
}

Future<_DirectionalKeys> _deriveDirectionalKeys(
  Uint8List sharedSecret,
  List<int> salt,
) async {
  final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final baseKey = SecretKey(sharedSecret);
  return _DirectionalKeys(
    clientToHost: await hkdf.deriveKey(
      secretKey: baseKey,
      nonce: salt,
      info: utf8.encode('playmesh-relay-v1/client-to-host'),
    ),
    hostToClient: await hkdf.deriveKey(
      secretKey: baseKey,
      nonce: salt,
      info: utf8.encode('playmesh-relay-v1/host-to-client'),
    ),
  );
}

Uint8List _nonce(int direction, int counter) {
  if (counter < 0 || counter > 0x7fffffffffffffff) {
    throw StateError('公共中转加密计数器已耗尽');
  }
  final nonce = ByteData(12)
    ..setUint32(0, direction)
    ..setUint64(4, counter);
  return nonce.buffer.asUint8List();
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

String _encodeInviteToken(_InviteTokenPayload payload) {
  final clientPath = utf8.encode(payload.clientPath);
  final joinCapability = utf8.encode(payload.joinCapability);
  final authorityEntryPath = utf8.encode(payload.authorityEntryPath);
  final shareToken = utf8.encode(payload.shareToken);
  for (final MapEntry(:key, :value) in {
    'clientPath': clientPath,
    'joinCapability': joinCapability,
    'shareToken': shareToken,
  }.entries) {
    if (value.isEmpty || value.length > 255) {
      throw FormatException('$key 的编码长度必须在 1 到 255 字节之间');
    }
  }
  if (authorityEntryPath.isEmpty || authorityEntryPath.length > 0xffff) {
    throw const FormatException('authorityEntryPath 的编码长度必须在 1 到 65535 字节之间');
  }
  if (payload.sharedSecret.length != 32) {
    throw const FormatException('公共中转端到端密钥长度无效');
  }
  final bytes = <int>[
    _inviteTokenVersion,
    clientPath.length,
    joinCapability.length,
    authorityEntryPath.length >> 8,
    authorityEntryPath.length & 0xff,
    shareToken.length,
    ...clientPath,
    ...joinCapability,
    ...authorityEntryPath,
    ...shareToken,
    ...payload.sharedSecret,
  ];
  return base64Url.encode(bytes).replaceAll('=', '');
}

_InviteTokenPayload _decodeInviteToken(String value) {
  try {
    final normalized = value.padRight((value.length + 3) ~/ 4 * 4, '=');
    final bytes = base64Url.decode(normalized);
    if (bytes.length < 6 + 32 || bytes.first != _inviteTokenVersion) {
      throw const FormatException('公共中转 inviteToken 版本无效');
    }
    final clientPathLength = bytes[1];
    final capabilityLength = bytes[2];
    final authorityEntryPathLength = (bytes[3] << 8) | bytes[4];
    final shareTokenLength = bytes[5];
    final expectedLength =
        6 +
        clientPathLength +
        capabilityLength +
        authorityEntryPathLength +
        shareTokenLength +
        32;
    if (clientPathLength < 1 ||
        capabilityLength < 1 ||
        authorityEntryPathLength < 1 ||
        shareTokenLength < 1 ||
        bytes.length != expectedLength) {
      throw const FormatException('公共中转 inviteToken 长度无效');
    }
    var offset = 6;
    String readString(int length) {
      final result = utf8.decode(bytes.sublist(offset, offset + length));
      offset += length;
      return result;
    }

    final clientPath = readString(clientPathLength);
    final joinCapability = readString(capabilityLength);
    final authorityEntryPath = readString(authorityEntryPathLength);
    final shareToken = readString(shareTokenLength);
    final sharedSecret = Uint8List.fromList(bytes.sublist(offset));
    return _InviteTokenPayload(
      clientPath: clientPath,
      joinCapability: joinCapability,
      authorityEntryPath: authorityEntryPath,
      shareToken: shareToken,
      sharedSecret: sharedSecret,
    );
  } on FormatException catch (error) {
    if (error.message.toString().startsWith('公共中转 inviteToken')) rethrow;
    throw const FormatException('公共中转 inviteToken 编码无效');
  }
}

Map<String, Object?> _jsonObject(List<int> bodyBytes) {
  final decoded = jsonDecode(utf8.decode(bodyBytes));
  if (decoded is! Map) throw const FormatException('公共中转响应必须是对象');
  return Map<String, Object?>.from(decoded);
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key 必须是非空字符串');
  }
  return value.trim();
}

({String path, String shareToken}) _parseAuthorityEntryUri(Uri value) {
  late final Map<String, String> fragment;
  try {
    fragment = parsePlaymeshInvitationFragment(value.fragment);
  } on FormatException {
    throw const FormatException('公共中转缺少有效的 Authority 游戏入口');
  }
  final shareToken = fragment[playmeshGameInvitationTokenParameter];
  if (value.scheme != 'http' ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.path != playmeshGameInvitationPath ||
      value.hasQuery ||
      fragment.length != 1 ||
      shareToken?.trim().isNotEmpty != true) {
    throw const FormatException('公共中转缺少有效的 Authority 游戏入口');
  }
  return (path: playmeshGameInvitationPath, shareToken: shareToken!.trim());
}

void _validateServerBase(Uri value) {
  if (!{'http', 'https'}.contains(value.scheme) ||
      value.host.isEmpty ||
      value.userInfo.isNotEmpty ||
      value.query.isNotEmpty ||
      value.fragment.isNotEmpty) {
    throw const FormatException('中转服务器必须是有效的 HTTP/HTTPS 地址');
  }
}

void _validateRelayPath(String value, String field) {
  if (!value.startsWith('/') || value.contains('?') || value.contains('#')) {
    throw FormatException('$field 必须是绝对路径');
  }
}

bool _equalBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  var difference = 0;
  for (var index = 0; index < left.length; index += 1) {
    difference |= left[index] ^ right[index];
  }
  return difference == 0;
}
