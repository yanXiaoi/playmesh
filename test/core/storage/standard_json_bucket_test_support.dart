import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/storage/game_bucket_http.dart';

Future<http.Response> sendStandardJsonBucketRequest({
  required Uri baseUri,
  required String requestId,
  required String gameId,
  required String operation,
  required String bucket,
  String? key,
  Object? value,
  String? revision,
  String? expectedRevision,
  Map<String, String> headers = const {},
}) async {
  if ({'set', 'sync.set', 'remove', 'clear'}.contains(operation) &&
      expectedRevision == null) {
    throw ArgumentError.value(
      expectedRevision,
      'expectedRevision',
      '$operation requires the current revision',
    );
  }
  final body = jsonEncode({
    'protocolVersion': playmeshStandardJsonProtocolVersion,
    'requestId': requestId,
    'gameId': gameId,
    'operation': operation,
    'bucket': bucket,
    'key': ?key,
    if (operation == 'set') 'value': value,
    if (operation == 'sync.set') 'value': value,
    if (operation == 'get' || operation == 'sync.get') 'revision': revision,
    if ({'set', 'sync.set', 'remove', 'clear'}.contains(operation))
      'expectedRevision': expectedRevision,
  });
  final digest = await Sha256().hash(utf8.encode(body));
  final digestHex = digest.bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  final requestHeaders = {'X-Playmesh-Content-Sha256': digestHex, ...headers};
  final endpoint = baseUri.resolve(playmeshStandardJsonBucketPath);
  switch (operation) {
    case 'set':
    case 'sync.set':
      return http.put(
        endpoint,
        headers: {'Content-Type': 'application/json', ...requestHeaders},
        body: body,
      );
    case 'get':
    case 'sync.get':
    case 'remove':
    case 'clear':
      final payload = base64Url.encode(utf8.encode(body)).replaceAll('=', '');
      final queryEndpoint = endpoint.replace(
        queryParameters: {'payload': payload},
      );
      return operation == 'get' || operation == 'sync.get'
          ? http.get(queryEndpoint, headers: requestHeaders)
          : http.delete(queryEndpoint, headers: requestHeaders);
    default:
      throw ArgumentError.value(operation, 'operation', 'unsupported');
  }
}

Map<String, Object?> standardJsonBucketResult(http.Response response) =>
    Map<String, Object?>.from(
      (jsonDecode(response.body) as Map<String, Object?>)['result']! as Map,
    );

Object? standardJsonBucketValue(http.Response response) =>
    standardJsonBucketResult(response)['value'];

String standardJsonBucketRevision(http.Response response) =>
    standardJsonBucketResult(response)['revision']! as String;
