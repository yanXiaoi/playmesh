import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_event_hub.dart';
import 'package:playmesh/core/developer/developer_installation_package_service.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/developer/developer_web_gateway.dart';
import 'package:playmesh/core/download/endpoint_probe_contract.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('安装包 Developer Operation', () {
    late Directory root;
    late _InstallationPackageCatalog catalog;
    late _FakeInstallationPackageService service;
    late DeveloperWebGateway gateway;
    late http.Client client;
    late Uri base;

    const token = 'installation-package-gateway-token';

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'developer-installation-package-gateway-',
      );
      catalog = _InstallationPackageCatalog();
      service = _FakeInstallationPackageService(root);
      final port = await _availablePort();
      gateway = await startDeveloperWebGateway(
        port: port,
        token: token,
        catalog: catalog,
        installationPackageService: service,
      );
      client = http.Client();
      base = Uri.parse('http://127.0.0.1:$port');
    });

    tearDown(() async {
      client.close();
      await gateway.close();
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('操作目录声明四条正式路由和严格创建 schema', () async {
      final response = await client.get(
        base.resolve('/dev/api/operations?target=all'),
        headers: _authorization(token),
      );

      expect(response.statusCode, HttpStatus.ok, reason: response.body);
      final catalogDocument = jsonDecode(response.body) as Map;
      expect(catalogDocument['catalogVersion'], '5.0.0');
      final operations = catalogDocument['operations'] as List;
      Map<String, Object?> operation(String id) => Map<String, Object?>.from(
        operations.singleWhere((item) => (item as Map)['id'] == id) as Map,
      );

      final options = operation('package_exports.options');
      final create = operation('package_exports.create');
      final download = operation('package_exports.download');
      final release = operation('package_exports.release');
      expect(options, containsPair('method', 'GET'));
      expect(create, containsPair('method', 'POST'));
      expect(download, containsPair('method', 'GET'));
      expect(release, containsPair('method', 'DELETE'));
      expect(options['path'], '/dev/api/projects/{projectId}/package-exports');
      expect(create['path'], options['path']);
      expect(
        download['path'],
        '/dev/api/projects/{projectId}/package-exports/{exportId}',
      );
      expect(release['path'], download['path']);
      for (final item in [options, create, download, release]) {
        expect(item['chatEnabled'], isFalse);
        expect(item['agentEnabled'], isFalse);
      }

      final schema = Map<String, Object?>.from(
        create['requestBodySchema']! as Map,
      );
      expect(schema['additionalProperties'], isFalse);
      expect(schema['required'], [
        'target',
        'refreshRuntime',
        'runtimeDownloadId',
        'autoApproveCapabilities',
        'relayServer',
      ]);
      final properties = Map<String, Object?>.from(
        schema['properties']! as Map,
      );
      expect(properties.keys, [
        'target',
        'refreshRuntime',
        'runtimeDownloadId',
        'autoApproveCapabilities',
        'relayServer',
      ]);
      expect(properties, isNot(contains('relayServerId')));
      final target = Map<String, Object?>.from(properties['target']! as Map);
      expect(target['enum'], [
        developerInstallationPackageTargetAndroidArm64,
        developerInstallationPackageTargetAndroidX86_64,
        developerInstallationPackageTargetWindowsX64,
      ]);
      expect(
        Map<String, Object?>.from(properties['refreshRuntime']! as Map)['type'],
        'boolean',
      );
      expect(
        Map<String, Object?>.from(
          properties['runtimeDownloadId']! as Map,
        )['type'],
        ['string', 'null'],
      );
      expect(
        Map<String, Object?>.from(
          properties['autoApproveCapabilities']! as Map,
        )['type'],
        'boolean',
      );
      expect(
        Map<String, Object?>.from(properties['relayServer']! as Map)['type'],
        ['string', 'null'],
      );
      final parameters = (create['parameters'] as List)
          .map((item) => Map<String, Object?>.from(item as Map))
          .toList();
      expect(
        parameters,
        contains(
          allOf(
            containsPair(
              'name',
              developerInstallationPackageProgressRequestIdHeader,
            ),
            containsPair('location', 'header'),
            containsPair('required', false),
          ),
        ),
      );
    });

    test('options 首次只返回三个底包的本地状态', () async {
      final response = await client.get(
        base.resolve('/dev/api/projects/demo/package-exports'),
        headers: _authorization(token),
      );

      expect(response.statusCode, HttpStatus.ok, reason: response.body);
      expect(
        response.headers['x-playmesh-operation-id'],
        'package_exports.options',
      );
      final body = jsonDecode(response.body) as Map;
      expect(body['projectId'], 'demo');
      expect(body['available'], isTrue);
      expect(body['scope'], 'local');
      final targets = body['targets'] as List;
      expect(
        targets.map((item) => (item as Map)['id']),
        developerInstallationPackageTargetIds,
      );
      expect(
        targets.first,
        allOf(
          containsPair('installed', true),
          containsPair('downloadAvailable', false),
          containsPair('updateAvailable', false),
          containsPair('runtimeOptionsLoaded', false),
          containsPair('runtimeDownloads', isEmpty),
        ),
      );
      expect(body, isNot(contains('relayServers')));
      expect(service.inspectLocalTargetsCount, 1);
      expect(service.inspectRuntimeTargetCount, 0);
      expect(service.probeRuntimeTargetDownloadsCount, 0);
      expect(service.inspectRelayServersCount, 0);
    });

    test('options 只在指定 scope 后读取线路、测速和中转服务器', () async {
      final runtimeResponse = await client.get(
        base.resolve(
          '/dev/api/projects/demo/package-exports'
          '?scope=runtime&target=android-arm64',
        ),
        headers: _authorization(token),
      );
      expect(runtimeResponse.statusCode, HttpStatus.ok);
      final runtimeBody = jsonDecode(runtimeResponse.body) as Map;
      expect(runtimeBody['scope'], 'runtime');
      expect(runtimeBody['target'], containsPair('runtimeOptionsLoaded', true));
      expect((runtimeBody['target'] as Map)['runtimeDownloads'], hasLength(1));
      expect(service.inspectRuntimeTargetCount, 1);
      expect(service.probeRuntimeTargetDownloadsCount, 0);

      final probesResponse = await client.get(
        base.resolve(
          '/dev/api/projects/demo/package-exports'
          '?scope=probes&target=android-arm64&source=${'c' * 64}',
        ),
        headers: _authorization(token),
      );
      expect(probesResponse.statusCode, HttpStatus.ok);
      final probesBody = jsonDecode(probesResponse.body) as Map;
      expect(probesBody['scope'], 'probes');
      expect(probesBody['targetId'], 'android-arm64');
      expect(probesBody['sourceId'], 'c' * 64);
      expect(probesBody['runtimeDownloads'], hasLength(1));
      expect(service.probeRuntimeTargetDownloadsCount, 1);
      expect(service.probedRuntimeSourceIds, ['c' * 64]);

      final relaysResponse = await client.get(
        base.resolve('/dev/api/projects/demo/package-exports?scope=relays'),
        headers: _authorization(token),
      );
      expect(relaysResponse.statusCode, HttpStatus.ok);
      final relaysBody = jsonDecode(relaysResponse.body) as Map;
      expect(relaysBody['scope'], 'relays');
      expect(relaysBody['relayServers'], [
        {
          'id': 'source-relay-primary',
          'name': 'Primary Relay',
          'address': 'https://relay.example.test',
          'token': 'relay-read-token',
          'latencyMs': 23,
        },
      ]);
      expect(service.inspectRelayServersCount, 1);
      expect(service.inspectLocalTargetsCount, 0);
    });

    test('options 拒绝无目标测速和本地 scope 携带目标', () async {
      for (final path in [
        '/dev/api/projects/demo/package-exports?scope=probes',
        '/dev/api/projects/demo/package-exports'
            '?scope=probes&target=android-arm64',
        '/dev/api/projects/demo/package-exports'
            '?scope=probes&target=android-arm64&source=unsafe',
        '/dev/api/projects/demo/package-exports'
            '?scope=local&target=android-arm64',
      ]) {
        final response = await client.get(
          base.resolve(path),
          headers: _authorization(token),
        );
        expect(response.statusCode, HttpStatus.badRequest);
      }
      expect(service.inspectLocalTargetsCount, 0);
      expect(service.probeRuntimeTargetDownloadsCount, 0);
    });

    test('create 透传单个中转地址并可流式下载和显式释放', () async {
      final collection = base.resolve('/dev/api/projects/demo/package-exports');
      final createResponse = await client.post(
        collection,
        headers: {
          ..._authorization(token),
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': true,
          'runtimeDownloadId': 'a' * 64,
          'autoApproveCapabilities': true,
          'relayServer': 'http://8.137.106.103:16668?token=666666',
        }),
      );

      expect(
        createResponse.statusCode,
        HttpStatus.created,
        reason: createResponse.body,
      );
      expect(
        createResponse.headers['x-playmesh-operation-id'],
        'package_exports.create',
      );
      expect(service.createRequests, hasLength(1));
      expect(service.createRequests.single.targetId, 'android-arm64');
      expect(service.createRequests.single.refreshRuntime, isTrue);
      expect(service.createRequests.single.runtimeDownloadId, 'a' * 64);
      expect(service.createRequests.single.autoApproveCapabilities, isTrue);
      expect(
        service.createRequests.single.relayServer,
        Uri.parse('http://8.137.106.103:16668?token=666666'),
      );
      expect(catalog.prepareCount, 1);
      final created = jsonDecode(createResponse.body) as Map;
      final exportId = created['exportId'] as String;
      final downloadPath = created['downloadPath'] as String;
      expect(downloadPath, '/dev/api/projects/demo/package-exports/$exportId');
      expect(created['filename'], 'demo-v1.0.0.apk');
      expect(created['mimeType'], 'application/vnd.android.package-archive');
      expect(created['size'], service.androidBytes.length);

      final isolatedGet = await client.get(
        base.resolve('/dev/api/projects/other/package-exports/$exportId'),
        headers: _authorization(token),
      );
      expect(isolatedGet.statusCode, HttpStatus.notFound);
      final isolatedDelete = await client.delete(
        base.resolve('/dev/api/projects/other/package-exports/$exportId'),
        headers: _authorization(token),
      );
      expect(isolatedDelete.statusCode, HttpStatus.noContent);
      expect(service.releasedIds, isEmpty);

      final downloadResponse = await client.get(
        base.resolve(downloadPath),
        headers: _authorization(token),
      );
      expect(downloadResponse.statusCode, HttpStatus.ok);
      expect(
        downloadResponse.headers['x-playmesh-operation-id'],
        'package_exports.download',
      );
      expect(
        downloadResponse.headers[HttpHeaders.contentTypeHeader],
        'application/vnd.android.package-archive',
      );
      expect(
        downloadResponse.headers[HttpHeaders.contentLengthHeader],
        service.androidBytes.length.toString(),
      );
      expect(
        downloadResponse.headers['content-disposition'],
        "attachment; filename*=UTF-8''demo-v1.0.0.apk",
      );
      expect(downloadResponse.bodyBytes, service.androidBytes);
      await _eventually(() => service.releasedIds.contains(exportId));
      expect(service.releasedIds, [exportId]);

      final afterDownload = await client.get(
        base.resolve(downloadPath),
        headers: _authorization(token),
      );
      expect(afterDownload.statusCode, HttpStatus.notFound);

      final releaseResponse = await client.delete(
        base.resolve(downloadPath),
        headers: _authorization(token),
      );
      expect(releaseResponse.statusCode, HttpStatus.noContent);
      expect(
        releaseResponse.headers['x-playmesh-operation-id'],
        'package_exports.release',
      );
      expect(service.releasedIds, [exportId]);
    });

    test('create 通过客户端 requestId 发送隔离且无敏感字段的阶段事件', () async {
      const progressRequestId = 'export_client_12345678';
      final events = <Map<String, Object?>>[];
      final subscription = developerEventHub.events
          .where(
            (event) =>
                event['type'] == 'package_export.progress' &&
                event['requestId'] == progressRequestId,
          )
          .listen(events.add);
      try {
        final response = await client.post(
          base.resolve('/dev/api/projects/demo/package-exports'),
          headers: {
            ..._authorization(token),
            HttpHeaders.contentTypeHeader: 'application/json',
            developerInstallationPackageProgressRequestIdHeader:
                progressRequestId,
          },
          body: jsonEncode({
            'target': developerInstallationPackageTargetAndroidArm64,
            'refreshRuntime': false,
            'runtimeDownloadId': null,
            'autoApproveCapabilities': false,
            'relayServer': 'https://relay.example.test?token=private-token',
          }),
        );
        await Future<void>.delayed(Duration.zero);

        expect(response.statusCode, HttpStatus.created, reason: response.body);
        expect(
          response.headers[developerInstallationPackageProgressRequestIdHeader
              .toLowerCase()],
          progressRequestId,
        );
        expect(
          (jsonDecode(response.body) as Map)['progressRequestId'],
          progressRequestId,
        );
        expect(events.map((event) => event['stage']), [
          'preparing',
          'runtime_check',
          'package_build',
          'native_export',
          'completed',
        ]);
        expect(
          events.where((event) => event['stage'] == 'completed'),
          hasLength(1),
        );
        expect(events.where((event) => event['stage'] == 'failed'), isEmpty);
        for (final event in events) {
          expect(event['projectId'], 'demo');
          expect(event['requestId'], progressRequestId);
          expect(
            event['target'],
            developerInstallationPackageTargetAndroidArm64,
          );
          expect(event['timestamp'], isA<int>());
          final encoded = jsonEncode(event).toLowerCase();
          expect(encoded, isNot(contains(root.path.toLowerCase())));
          expect(encoded, isNot(contains('relay.example.test')));
          expect(encoded, isNot(contains('private-token')));
          expect(encoded, isNot(contains('keystore')));
          expect(encoded, isNot(contains('password')));
        }
      } finally {
        await subscription.cancel();
      }
    });

    test('项目校验失败仅发送一个 failed 终态', () async {
      const progressRequestId = 'export_invalid_123456';
      final events = <Map<String, Object?>>[];
      final subscription = developerEventHub.events
          .where(
            (event) =>
                event['type'] == 'package_export.progress' &&
                event['requestId'] == progressRequestId,
          )
          .listen(events.add);
      try {
        final response = await client.post(
          base.resolve('/dev/api/projects/invalid/package-exports'),
          headers: {
            ..._authorization(token),
            HttpHeaders.contentTypeHeader: 'application/json',
            developerInstallationPackageProgressRequestIdHeader:
                progressRequestId,
          },
          body: jsonEncode({
            'target': developerInstallationPackageTargetWindowsX64,
            'refreshRuntime': false,
            'runtimeDownloadId': null,
            'autoApproveCapabilities': false,
            'relayServer': null,
          }),
        );
        await Future<void>.delayed(Duration.zero);

        expect(response.statusCode, HttpStatus.unprocessableEntity);
        expect(events.map((event) => event['stage']), ['preparing', 'failed']);
        expect(events.last['errorCode'], 'package_validation_failed');
        expect(
          events.where(
            (event) =>
                event['stage'] == 'completed' || event['stage'] == 'failed',
          ),
          hasLength(1),
        );
      } finally {
        await subscription.cancel();
      }
    });

    test('create 严格拒绝不安全的进度 requestId header', () async {
      for (final value in ['short', 'unsafe/request-id', 'unsafe.request.id']) {
        final response = await client.post(
          base.resolve('/dev/api/projects/demo/package-exports'),
          headers: {
            ..._authorization(token),
            HttpHeaders.contentTypeHeader: 'application/json',
            developerInstallationPackageProgressRequestIdHeader: value,
          },
          body: jsonEncode({
            'target': developerInstallationPackageTargetWindowsX64,
            'refreshRuntime': false,
            'runtimeDownloadId': null,
            'autoApproveCapabilities': false,
            'relayServer': null,
          }),
        );
        expect(
          response.statusCode,
          HttpStatus.badRequest,
          reason: '$value: ${response.body}',
        );
      }
      expect(service.createRequests, isEmpty);
      expect(catalog.prepareCount, 0);
    });

    test('create 严格拒绝缺失、额外和错误类型字段', () async {
      final collection = base.resolve('/dev/api/projects/demo/package-exports');
      final bodies = <Map<String, Object?>>[
        {
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': false,
        },
        {
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': null,
          'unexpected': true,
        },
        {
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': null,
          'relayServerId': 'source-relay-primary',
        },
        {
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': 'false',
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': null,
        },
        {
          'target': 'android-arm32',
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': null,
        },
        {
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': true,
          'runtimeDownloadId': 'unsafe-download-id',
          'autoApproveCapabilities': false,
          'relayServer': null,
        },
        {
          'target': developerInstallationPackageTargetAndroidArm64,
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': 'true',
          'relayServer': null,
        },
      ];

      for (final body in bodies) {
        final response = await client.post(
          collection,
          headers: {
            ..._authorization(token),
            HttpHeaders.contentTypeHeader: 'application/json',
          },
          body: jsonEncode(body),
        );
        expect(
          response.statusCode,
          HttpStatus.badRequest,
          reason: response.body,
        );
      }
      expect(service.createRequests, isEmpty);
      expect(catalog.prepareCount, 0);
    });

    test('create 拒绝非 publicURL 形态的中转地址', () async {
      final response = await client.post(
        base.resolve('/dev/api/projects/demo/package-exports'),
        headers: {
          ..._authorization(token),
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({
          'target': developerInstallationPackageTargetWindowsX64,
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': 'https://relay.example.com/private/path?token=x',
        }),
      );

      expect(response.statusCode, HttpStatus.badRequest, reason: response.body);
      expect(service.createRequests, isEmpty);
      expect(catalog.prepareCount, 0);
    });

    test('项目校验失败时不准备项目或调用安装包服务', () async {
      final response = await client.post(
        base.resolve('/dev/api/projects/invalid/package-exports'),
        headers: {
          ..._authorization(token),
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({
          'target': developerInstallationPackageTargetAndroidX86_64,
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': null,
        }),
      );

      expect(
        response.statusCode,
        HttpStatus.unprocessableEntity,
        reason: response.body,
      );
      final body = jsonDecode(response.body) as Map;
      expect(body['error'], containsPair('code', 'package_validation_failed'));
      expect(body['validation'], containsPair('valid', false));
      expect(service.createRequests, isEmpty);
      expect(catalog.prepareCount, 0);
    });

    test('未接入安装包服务时 options 明示不可用且 create 返回 503', () async {
      final unavailablePort = await _availablePort();
      final unavailable = await startDeveloperWebGateway(
        port: unavailablePort,
        token: token,
        catalog: _InstallationPackageCatalog(),
      );
      addTearDown(unavailable.close);
      final unavailableBase = Uri.parse('http://127.0.0.1:$unavailablePort');

      final options = await client.get(
        unavailableBase.resolve('/dev/api/projects/demo/package-exports'),
        headers: _authorization(token),
      );
      expect(options.statusCode, HttpStatus.ok, reason: options.body);
      expect(
        jsonDecode(options.body),
        allOf(
          containsPair('available', false),
          containsPair('targets', isEmpty),
        ),
      );

      final create = await client.post(
        unavailableBase.resolve('/dev/api/projects/demo/package-exports'),
        headers: {
          ..._authorization(token),
          HttpHeaders.contentTypeHeader: 'application/json',
        },
        body: jsonEncode({
          'target': developerInstallationPackageTargetWindowsX64,
          'refreshRuntime': false,
          'runtimeDownloadId': null,
          'autoApproveCapabilities': false,
          'relayServer': null,
        }),
      );
      expect(
        create.statusCode,
        HttpStatus.serviceUnavailable,
        reason: create.body,
      );
      expect(
        (jsonDecode(create.body) as Map)['error'],
        containsPair('code', 'package_export_unavailable'),
      );
    });
  });
}

Map<String, String> _authorization(String token) => {
  HttpHeaders.authorizationHeader: 'Bearer $token',
};

Future<int> _availablePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition did not become true before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _CreateRequest {
  const _CreateRequest({
    required this.game,
    required this.targetId,
    required this.refreshRuntime,
    required this.runtimeDownloadId,
    required this.autoApproveCapabilities,
    required this.relayServer,
  });

  final GameSummary game;
  final String targetId;
  final bool refreshRuntime;
  final String? runtimeDownloadId;
  final bool autoApproveCapabilities;
  final Uri? relayServer;
}

final class _FakeInstallationPackageService
    implements DeveloperInstallationPackageService {
  _FakeInstallationPackageService(this.root);

  final Directory root;
  final androidBytes = List<int>.generate(4096, (index) => index % 251);
  final windowsBytes = List<int>.generate(3072, (index) => index % 239);
  final createRequests = <_CreateRequest>[];
  final releasedIds = <String>[];
  final artifacts = <String, DeveloperInstallationPackageArtifact>{};
  var inspectCount = 0;
  var inspectLocalTargetsCount = 0;
  var inspectRuntimeTargetCount = 0;
  var probeRuntimeTargetDownloadsCount = 0;
  final probedRuntimeSourceIds = <String>[];
  var inspectRelayServersCount = 0;
  var closeCount = 0;

  List<DeveloperInstallationPackageTargetStatus> _targetStatuses() => [
    DeveloperInstallationPackageTargetStatus(
      id: developerInstallationPackageTargetAndroidArm64,
      platform: 'android',
      architecture: 'arm64-v8a',
      runtimeFilename: 'playmesh-runtime-arm.apk',
      installed: true,
      downloadAvailable: true,
      updateAvailable: true,
      runtimeDownloads: [
        DeveloperInstallationPackageRuntimeDownload(
          id: 'a' * 64,
          name: 'Primary Runtime Download',
          address: Uri.parse('https://runtime.example.test/arm.apk'),
          manifestSourceId: 'c' * 64,
          manifestSourceName: 'Primary Runtime Manifest',
          manifestSourceAddress: Uri.parse(
            'https://runtime.example.test/update.json',
          ),
          probeState: EndpointProbeState.reachable,
          latencyMs: 18,
        ),
      ],
      runtimeVersion: '1.0.0',
      sizeBytes: 4096,
    ),
    DeveloperInstallationPackageTargetStatus(
      id: developerInstallationPackageTargetAndroidX86_64,
      platform: 'android',
      architecture: 'x86_64',
      runtimeFilename: 'playmesh-runtime-x86.apk',
      installed: false,
      downloadAvailable: true,
      updateAvailable: false,
      runtimeDownloads: [
        DeveloperInstallationPackageRuntimeDownload(
          id: 'b' * 64,
          name: 'Mirror Runtime Download',
          address: Uri.parse('https://runtime.example.test/x86.apk'),
          manifestSourceId: 'c' * 64,
          manifestSourceName: 'Primary Runtime Manifest',
          manifestSourceAddress: Uri.parse(
            'https://runtime.example.test/update.json',
          ),
          probeState: EndpointProbeState.timeout,
        ),
      ],
      runtimeVersion: '1.0.0',
      sizeBytes: 4096,
    ),
    DeveloperInstallationPackageTargetStatus(
      id: developerInstallationPackageTargetWindowsX64,
      platform: 'windows',
      architecture: 'x64',
      runtimeFilename: 'playmesh-runtime-win.zip',
      installed: true,
      downloadAvailable: false,
      updateAvailable: false,
      runtimeVersion: '1.0.0',
      sizeBytes: 3072,
    ),
  ];

  @override
  Future<List<DeveloperInstallationPackageTargetStatus>>
  inspectLocalTargets() async {
    inspectLocalTargetsCount += 1;
    return [
      for (final status in _targetStatuses())
        DeveloperInstallationPackageTargetStatus(
          id: status.id,
          platform: status.platform,
          architecture: status.architecture,
          runtimeFilename: status.runtimeFilename,
          installed: status.installed,
          downloadAvailable: false,
          updateAvailable: false,
          sizeBytes: status.sizeBytes,
        ),
    ];
  }

  @override
  Future<List<DeveloperInstallationPackageTargetStatus>>
  inspectTargets() async {
    inspectCount += 1;
    return _targetStatuses();
  }

  @override
  Future<DeveloperInstallationPackageTargetStatus> inspectRuntimeTarget(
    String targetId,
  ) async {
    inspectRuntimeTargetCount += 1;
    return _targetStatuses().singleWhere((target) => target.id == targetId);
  }

  @override
  Future<List<DeveloperInstallationPackageRuntimeDownload>>
  probeRuntimeTargetDownloads(String targetId, String manifestSourceId) async {
    probeRuntimeTargetDownloadsCount += 1;
    probedRuntimeSourceIds.add(manifestSourceId);
    return _targetStatuses()
        .singleWhere((target) => target.id == targetId)
        .runtimeDownloads
        .where((download) => download.manifestSourceId == manifestSourceId)
        .toList(growable: false);
  }

  @override
  Future<List<DeveloperInstallationPackageRelayServer>>
  inspectRelayServers() async {
    inspectRelayServersCount += 1;
    return [
      DeveloperInstallationPackageRelayServer(
        id: 'source-relay-primary',
        name: 'Primary Relay',
        address: Uri.parse('https://relay.example.test'),
        token: 'relay-read-token',
        latencyMs: 23,
      ),
    ];
  }

  @override
  Future<DeveloperInstallationPackageArtifact> create({
    required GameSummary game,
    required String targetId,
    required bool refreshRuntime,
    String? runtimeDownloadId,
    bool autoApproveCapabilities = false,
    Uri? relayServer,
    DeveloperInstallationPackageProgressCallback? onProgress,
  }) async {
    createRequests.add(
      _CreateRequest(
        game: game,
        targetId: targetId,
        refreshRuntime: refreshRuntime,
        runtimeDownloadId: runtimeDownloadId,
        autoApproveCapabilities: autoApproveCapabilities,
        relayServer: relayServer,
      ),
    );
    onProgress?.call(
      const DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.runtimeCheck,
      ),
    );
    onProgress?.call(
      const DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.packageBuild,
      ),
    );
    onProgress?.call(
      const DeveloperInstallationPackageProgress(
        stage: DeveloperInstallationPackageProgressStage.nativeExport,
      ),
    );
    final windows = targetId == developerInstallationPackageTargetWindowsX64;
    final bytes = windows ? windowsBytes : androidBytes;
    final extension = windows ? 'zip' : 'apk';
    final exportId = 'exportabcdefghijklmnopqr${createRequests.length}';
    final file = File(
      '${root.path}${Platform.pathSeparator}$exportId.$extension',
    );
    await file.writeAsBytes(bytes, flush: true);
    final artifact = DeveloperInstallationPackageArtifact(
      id: exportId,
      projectId: game.id,
      filePath: file.path,
      filename: '${game.id}-v${game.version}.$extension',
      mimeType: windows
          ? 'application/zip'
          : 'application/vnd.android.package-archive',
      size: bytes.length,
    );
    artifacts[exportId] = artifact;
    return artifact;
  }

  @override
  DeveloperInstallationPackageArtifact? find(String exportId) =>
      artifacts[exportId];

  @override
  Future<void> release(String exportId) async {
    releasedIds.add(exportId);
    final artifact = artifacts.remove(exportId);
    if (artifact != null) {
      final file = File(artifact.filePath);
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<void> close() async {
    closeCount += 1;
  }
}

final class _InstallationPackageCatalog extends Fake
    implements DeveloperProjectCatalog {
  var prepareCount = 0;

  @override
  Future<List<DeveloperProject>> listProjects() async => const [
    DeveloperProject(
      id: 'demo',
      name: 'Demo',
      version: '1.0.0',
      rootFilePath: '/projects/demo',
    ),
    DeveloperProject(
      id: 'other',
      name: 'Other',
      version: '1.0.0',
      rootFilePath: '/projects/other',
    ),
    DeveloperProject(
      id: 'invalid',
      name: 'Invalid',
      version: '1.0.0',
      rootFilePath: '/projects/invalid',
    ),
  ];

  @override
  Future<DeveloperProjectValidationReport> validateProject(
    String projectId,
  ) async => projectId == 'invalid'
      ? const DeveloperProjectValidationReport(
          projectId: 'invalid',
          diagnostics: [
            DeveloperProjectDiagnostic(
              code: 'entry_missing',
              severity: DeveloperDiagnosticSeverity.error,
              message: '主入口不存在',
              path: 'app/index.html',
            ),
          ],
          fileCount: 1,
          totalBytes: 32,
        )
      : DeveloperProjectValidationReport(
          projectId: projectId,
          diagnostics: const [],
          fileCount: 2,
          totalBytes: 64,
        );

  @override
  Future<GameSummary> prepareGame(String projectId) async {
    prepareCount += 1;
    return GameSummary(
      id: projectId,
      name: projectId,
      version: '1.0.0',
      description: '',
      minPlayers: 1,
      maxPlayers: 4,
      supportsMultiplayer: true,
      displayModeLabel: '多屏',
      displayMode: 'multi_screen',
      orientation: GameOrientation.landscape,
      entry: LocalGameEntry(
        gameEntryPath: 'index.html',
        statusLabel: '开发项目',
        packageRootFilePath: '/managed/packages/$projectId',
      ),
    );
  }
}
