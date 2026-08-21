import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/developer/developer_preview_service.dart';
import 'package:playmesh/core/developer/developer_run_controller.dart';
import 'package:playmesh/core/game_package/game_web_resource_source.dart';
import 'package:playmesh/models/game_summary.dart';
import 'package:playmesh/models/local_game_entry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test(
    'chunked preview stages without install and runs through development source',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'developer-preview-test-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final controller = DeveloperRunController();
      DeveloperResourceSession? launchedSession;
      controller.onLaunch = (request) async {
        launchedSession = request.resourceSession;
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
        controller.reportRunning(
          projectId: request.projectId,
          expectedRunId: request.runId,
          links: [Uri.parse('http://192.168.1.5:3000/join')],
        );
      };
      final service = DeveloperPreviewService(
        runController: controller,
        temporaryRoot: temporary,
      );
      addTearDown(service.dispose);
      const gameId = 'com.example.preview';
      final archive = _package(gameId, marker: 'FIRST');

      final preview = await service.start(
        gameId: gameId,
        archive: Stream<List<int>>.fromIterable([
          archive.sublist(0, archive.length ~/ 2),
          archive.sublist(archive.length ~/ 2),
        ]),
      );

      expect(preview.run.phase, DeveloperRunPhase.running);
      expect(preview.run.links, hasLength(1));
      expect(launchedSession?.runtimeDeclaration?.manifest.id, gameId);
      expect(launchedSession?.runtimeDeclaration?.gameEntryOverride, isNull);
      expect(preview.toJson(), isNot(contains('credential')));
      expect(
        jsonEncode(preview.toJson()),
        isNot(contains('Development-Credential')),
      );

      final response = await http.get(
        launchedSession!.resourceBaseUri.resolve('index.html'),
        headers: {
          playmeshDevelopmentCredentialHeader: launchedSession!.credential,
        },
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('FIRST'));

      final status = await service.status(gameId);
      expect(status.previewId, preview.previewId);
      expect(status.toJson()['expiresAt'], isA<int>());
      expect((status.toJson()['run'] as Map)['links'], isA<List<String>>());
    },
  );

  test(
    'new generation replaces old source and stale stop is rejected',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'developer-preview-generation-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final controller = DeveloperRunController();
      final sessions = <DeveloperResourceSession>[];
      controller.onLaunch = (request) async {
        sessions.add(request.resourceSession!);
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
        controller.reportRunning(
          projectId: request.projectId,
          expectedRunId: request.runId,
        );
      };
      final service = DeveloperPreviewService(
        runController: controller,
        temporaryRoot: temporary,
      );
      addTearDown(service.dispose);
      const gameId = 'com.example.generation';

      final first = await service.start(
        gameId: gameId,
        archive: Stream.value(_package(gameId, marker: 'FIRST')),
      );
      final oldBaseUri = sessions.single.resourceBaseUri;
      final second = await service.start(
        gameId: gameId,
        archive: Stream.value(_package(gameId, marker: 'SECOND')),
        declaredLength: _package(gameId, marker: 'SECOND').length,
      );

      expect(second.previewId, isNot(first.previewId));
      await expectLater(
        http.get(oldBaseUri.resolve('index.html')),
        throwsA(anything),
      );
      await expectLater(
        service.stop(gameId: gameId, previewId: first.previewId),
        throwsA(isA<DeveloperPreviewGenerationConflict>()),
      );
      final stopped = await service.stop(
        gameId: gameId,
        previewId: second.previewId,
      );
      expect(stopped.run.phase, DeveloperRunPhase.stopped);
      await expectLater(
        service.status(gameId),
        throwsA(isA<DeveloperPreviewNotFound>()),
      );
    },
  );

  test(
    'dormant multiplayer runtime files never promote a solo preview',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'developer-preview-dormant-runtime-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final controller = DeveloperRunController();
      DeveloperResourceSession? launchedSession;
      controller.onLaunch = (request) async {
        launchedSession = request.resourceSession;
        controller.registerStopHandler(
          request.projectId,
          () async {},
          expectedRunId: request.runId,
        );
        controller.reportRunning(
          projectId: request.projectId,
          expectedRunId: request.runId,
        );
      };
      final service = DeveloperPreviewService(
        runController: controller,
        temporaryRoot: temporary,
      );
      addTearDown(service.dispose);
      const gameId = 'com.example.dormant-runtime';

      await service.start(
        gameId: gameId,
        archive: Stream.value(
          _package(gameId, includeDormantMultiplayerRuntime: true),
        ),
      );

      final declaration = launchedSession!.runtimeDeclaration!;
      expect(declaration.manifest.supportsMultiplayer, isFalse);
      final runtimeSummary = declaration.applyTo(
        GameSummary(
          id: 'stale',
          name: 'Stale',
          version: '0.0.0',
          description: '',
          minPlayers: 2,
          maxPlayers: 5,
          supportsMultiplayer: true,
          displayModeLabel: 'stale',
          displayMode: 'stale',
          orientation: declaration.manifest.orientation,
          entry: const LocalGameEntry(
            statusLabel: 'stale',
            gameEntryPath: 'stale.html',
          ),
        ),
      );
      expect(runtimeSummary.supportsMultiplayer, isFalse);
      expect(declaration.manifest.authority, isNull);
      final bootstrap = await http.get(
        launchedSession!.resourceBaseUri.resolve('static/js/service/index.js'),
        headers: {
          playmeshDevelopmentCredentialHeader: launchedSession!.credential,
        },
      );
      expect(bootstrap.statusCode, HttpStatus.ok);
      expect(bootstrap.body, contains('DORMANT_CANONICAL_BOOTSTRAP'));
    },
  );

  test(
    'embedded preview is transient, same-origin addressable, and does not launch App runtime',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'developer-embedded-preview-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      var launches = 0;
      final controller = DeveloperRunController(
        onLaunch: (_) async => launches++,
      );
      final service = DeveloperPreviewService(
        runController: controller,
        temporaryRoot: temporary,
      );
      addTearDown(service.dispose);
      const gameId = 'com.example.embedded-preview';

      final preview = await service.start(
        gameId: gameId,
        archive: Stream.value(_package(gameId, marker: 'EMBEDDED')),
        surface: DeveloperPreviewSurface.embedded,
        embeddedLinkBuilder: (previewId) => Uri.parse(
          'http://127.0.0.1:16666/dev/session/gdevelop/'
          'embedded-preview/$gameId/$previewId/index.html',
        ),
      );

      expect(launches, 0);
      expect(controller.activeStatus, isNull);
      expect(preview.run.phase, DeveloperRunPhase.running);
      expect(preview.run.runId, preview.previewId);
      expect(preview.run.links.single.query, isEmpty);
      final resourceSession = service.embeddedResourceSession(
        gameId: gameId,
        previewId: preview.previewId,
      );
      expect(resourceSession, isNotNull);
      final response = await http.get(
        resourceSession!.resourceBaseUri.resolve('index.html'),
        headers: {
          playmeshDevelopmentCredentialHeader: resourceSession.credential,
        },
      );
      expect(response.statusCode, HttpStatus.ok);
      expect(response.body, contains('EMBEDDED'));

      await service.stop(gameId: gameId, previewId: preview.previewId);
      expect(
        service.embeddedResourceSession(
          gameId: gameId,
          previewId: preview.previewId,
        ),
        isNull,
      );
    },
  );

  test('manifest id mismatch is rejected before changing active run', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'developer-preview-id-',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final controller = DeveloperRunController(onLaunch: (_) async {});
    final service = DeveloperPreviewService(
      runController: controller,
      temporaryRoot: temporary,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.start(
        gameId: 'com.example.expected',
        archive: Stream.value(_package('com.example.other')),
      ),
      throwsA(isA<DeveloperPreviewPackageInvalid>()),
    );
    expect(controller.activeStatus, isNull);
  });

  test('staged declaration is one-time and never launches by itself', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'developer-preview-declaration-',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    var launches = 0;
    final controller = DeveloperRunController(
      onLaunch: (_) async => launches++,
    );
    final service = DeveloperPreviewService(
      runController: controller,
      temporaryRoot: temporary,
    );
    addTearDown(service.dispose);
    const gameId = 'com.example.declaration';

    final staged = await service.stageRuntimeDeclaration(
      gameId: gameId,
      archive: Stream.value(_package(gameId)),
    );
    final declaration = await service.consumeRuntimeDeclaration(
      gameId: gameId,
      packageId: staged.packageId,
    );

    expect(staged.toJson(), isNot(contains('manifest')));
    expect(declaration.manifest.id, gameId);
    expect(launches, 0);
    expect(controller.activeStatus, isNull);
    await expectLater(
      service.consumeRuntimeDeclaration(
        gameId: gameId,
        packageId: staged.packageId,
      ),
      throwsA(isA<DeveloperPreviewPackageRequired>()),
    );
  });
}

List<int> _package(
  String gameId, {
  String marker = 'PREVIEW',
  bool includeDormantMultiplayerRuntime = false,
}) {
  final manifest = utf8.encode(
    jsonEncode({
      'id': gameId,
      'name': 'Preview',
      'author': 'Tester',
      'lastModifiedAt': 0,
      'remarks': 'Temporary preview',
      'version': '0.1.0',
      'sdkVersion': '4.1.0',
      'appSdkVersion': '3.3.0',
      'orientation': 'landscape',
      'modes': ['solo'],
      'displayModes': ['multi_screen'],
      'players': {'min': 1, 'max': 1},
      'entries': {'game': 'index.html'},
      'tags': <String>[],
    }),
  );
  final index = utf8.encode(
    '<!doctype html><html><head></head><body>$marker</body></html>',
  );
  final archive = Archive()
    ..addFile(ArchiveFile('main.json', manifest.length, manifest))
    ..addFile(ArchiveFile('app/index.html', index.length, index));
  if (includeDormantMultiplayerRuntime) {
    final bridge = utf8.encode('DORMANT_MULTIPLAYER_BRIDGE');
    final bootstrap = utf8.encode('DORMANT_CANONICAL_BOOTSTRAP');
    archive
      ..addFile(
        ArchiveFile(
          'app/static/js/service/playmesh-multiplayer-bridge.js',
          bridge.length,
          bridge,
        ),
      )
      ..addFile(
        ArchiveFile(
          'app/static/js/service/index.js',
          bootstrap.length,
          bootstrap,
        ),
      );
  }
  return ZipEncoder().encode(archive)!;
}
