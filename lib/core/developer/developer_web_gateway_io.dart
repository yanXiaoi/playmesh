import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../../models/game_capabilities.dart';
import '../../models/game_summary.dart';
import '../../models/local_game_entry.dart';
import '../game_package/game_package_transfer_service.dart';
import '../game_sdk/generated_sdk_versions.dart';
import '../network/lan_endpoint_resolver.dart';
import 'developer_ai_prompt_templates.dart';
import 'developer_capability_test_service.dart';
import 'developer_channel.dart';
import 'developer_event_hub.dart';
import 'developer_project_catalog.dart';
import 'developer_run_controller.dart';
import 'developer_web_gateway_contract.dart';

enum _AiPromptKind { chat, agent }

Future<DeveloperWebGateway> startDeveloperWebGateway({
  required int port,
  String? token,
  String? path,
  DeveloperProjectCatalog? catalog,
  DeveloperAiPromptTemplateStore? promptTemplates,
  DeveloperRunController? runController,
  DeveloperCapabilityTestService? capabilityTests,
  GamePackageTransferService? packageTransfer,
  String Function()? currentAuthor,
  DateTime Function()? clock,
}) async {
  if (port < 1 || port > 65535) {
    throw const FormatException('开发者通道端口必须在 1 到 65535 之间');
  }
  final normalizedToken = _createToken(token);
  final normalizedPath = _createPath(path);
  try {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    final gateway = _IoDeveloperWebGateway(
      server: server,
      token: normalizedToken,
      path: normalizedPath,
      catalog: catalog ?? const _EmptyDeveloperProjectCatalog(),
      promptTemplates: promptTemplates ?? DeveloperAiPromptTemplateStore(),
      runController: runController ?? DeveloperRunController(),
      capabilityTests: capabilityTests ?? DeveloperCapabilityTestService(),
      packageTransfer: packageTransfer ?? GamePackageTransferService(),
      currentAuthor: currentAuthor,
      clock: clock ?? DateTime.now,
    );
    gateway.listen();
    return gateway;
  } on SocketException catch (error) {
    throw StateError('无法监听开发者端口 $port：${error.message}');
  }
}

class _IoDeveloperWebGateway implements DeveloperWebGateway {
  _IoDeveloperWebGateway({
    required this.server,
    required this.token,
    required this.path,
    required this.catalog,
    required this.promptTemplates,
    required this.runController,
    required this.capabilityTests,
    required this.packageTransfer,
    required this.currentAuthor,
    required this.clock,
  }) : session = DeveloperSession(
         enabled: true,
         port: server.port,
         path: path,
         token: token,
         tokenHint: token.substring(token.length - 6),
         workspacePath: '/dev/$path/workspace',
         docsPath: '/dev/docs',
         openApiPath: '/dev/openapi.json',
         sdkManifestPath: '/dev/sdk-manifest.json',
         createdAt: DateTime.now().toUtc(),
       );

  final HttpServer server;
  final String token;
  final String path;
  final DeveloperProjectCatalog catalog;
  final DeveloperAiPromptTemplateStore promptTemplates;
  final DeveloperRunController runController;
  final DeveloperCapabilityTestService capabilityTests;
  final GamePackageTransferService packageTransfer;
  final String Function()? currentAuthor;
  final DateTime Function() clock;
  Future<void> _packageFileTail = Future<void>.value();
  @override
  final DeveloperSession session;

  String _requireCurrentAuthor() {
    final author = currentAuthor?.call().trim() ?? '';
    if (author.isEmpty) {
      throw StateError('当前 App 昵称不可用，无法写入项目作者');
    }
    return author;
  }

  void listen() {
    server.listen((request) async {
      final requestId = 'dev-${_randomHex(8)}';
      request.response.headers.set('X-Request-ID', requestId);
      try {
        await _handle(request, requestId);
      } on FormatException catch (error) {
        await _error(
          request.response,
          HttpStatus.badRequest,
          requestId,
          'invalid_request',
          error.message,
        );
      } on StateError catch (error) {
        await _error(
          request.response,
          HttpStatus.notFound,
          requestId,
          'not_found',
          error.message,
        );
      } on DeveloperRevisionConflict catch (error) {
        await _json(request.response, HttpStatus.conflict, {
          'requestId': requestId,
          'error': {
            'code': 'revision_conflict',
            'message': '文件已被其他客户端修改',
            'currentRevision': error.currentRevision,
          },
        });
      } on DeveloperProjectValidationFailure catch (error) {
        await _json(request.response, HttpStatus.unprocessableEntity, {
          'requestId': requestId,
          'error': {
            'code': 'package_validation_failed',
            'message': '项目校验未通过，不能启动游戏',
          },
          'validation': error.report.toJson(),
        });
      } on Object {
        await _error(
          request.response,
          HttpStatus.internalServerError,
          requestId,
          'internal_error',
          '开发者通道处理请求失败',
        );
      }
    });
  }

  Future<void> _handle(HttpRequest request, String requestId) async {
    if (request.method == 'GET' &&
        request.uri.path.startsWith('/playmesh/developer/')) {
      await _servePublicAsset(request, request.uri.path);
      return;
    }
    if (!_authenticated(request)) {
      await _error(
        request.response,
        HttpStatus.unauthorized,
        requestId,
        'unauthorized',
        '开发者会话 Token 无效',
      );
      return;
    }

    final route = request.uri.path;
    if (request.method == 'GET' && route == session.workspacePath) {
      request.response.cookies.add(
        Cookie('playmesh_developer_token', token)
          ..httpOnly = true
          ..sameSite = SameSite.strict
          ..path = '/',
      );
      final workspace = await rootBundle.loadString(
        'assets/playmesh-library/public/developer/workspace.html',
      );
      await _html(request.response, workspace);
      return;
    }
    if (request.method == 'GET' && route == '/dev/docs') {
      await _text(request.response, _docs, 'text/markdown; charset=utf-8');
      return;
    }
    if (request.method == 'GET' && route == '/dev/openapi.json') {
      try {
        await _serveDeveloperFile(request, 'contracts/openapi.json');
      } on Object {
        await _json(request.response, HttpStatus.ok, _openApi());
      }
      return;
    }
    if (request.method == 'GET' && route == '/dev/sdk-manifest.json') {
      await _serveDeveloperFile(request, 'contracts/sdk-manifest.json');
      return;
    }
    if (request.method == 'GET' &&
        route == '/dev/schemas/developer-session.json') {
      await _json(request.response, HttpStatus.ok, _sessionSchema);
      return;
    }
    if (request.method == 'GET' &&
        route == '/dev/schemas/project-validation.json') {
      await _json(request.response, HttpStatus.ok, _projectValidationSchema);
      return;
    }
    if (request.method == 'GET' && route == '/dev/schemas/sdk-v1.json') {
      await _serveDeveloperFile(request, 'contracts/schemas/sdk-v1.json');
      return;
    }
    if (request.method == 'GET' && route == '/dev/schemas/game-manifest.json') {
      await _serveDeveloperFile(
        request,
        'contracts/schemas/game-manifest.json',
      );
      return;
    }
    if (request.method == 'GET' &&
        route == '/dev/schemas/game-capabilities.json') {
      await _serveDeveloperFile(
        request,
        'contracts/schemas/game-capabilities.json',
      );
      return;
    }
    if (request.method == 'GET' &&
        route == '/dev/examples/list-projects.json') {
      await _json(request.response, HttpStatus.ok, {
        'method': 'GET',
        'path': '/dev/api/projects',
        'authorization': 'Bearer <developer-token>',
      });
      return;
    }
    if (request.method == 'GET' &&
        route == '/dev/examples/validate-project.json') {
      await _json(request.response, HttpStatus.ok, {
        'method': 'GET',
        'path': '/dev/api/projects/{projectId}/validate',
        'authorization': 'Bearer <developer-token>',
        'success': {
          'valid': true,
          'errorCount': 0,
          'warningCount': 0,
          'diagnostics': <Object>[],
        },
      });
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/status') {
      final baseUrls = await _availableBaseUrls(request);
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'enabled': true,
        'port': server.port,
        'baseUrls': baseUrls.map((uri) => uri.toString()).toList(),
        'tokenHint': session.tokenHint,
        'gameSdkVersion': generatedGameSdkVersion,
        'appSdkVersion': generatedAppSdkVersion,
        'createdAt': session.createdAt?.millisecondsSinceEpoch,
      });
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/sdk') {
      await _serveSdkBundle(request, requestId);
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/run') {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'run': runController.activeStatus?.toJson(),
      });
      return;
    }
    if (request.method == 'POST' && route == '/dev/api/packages/import') {
      await _importPackage(request, requestId);
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/projects') {
      final projects = await catalog.listProjects();
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projects': projects.map((project) => project.toJson()).toList(),
      });
      return;
    }
    if (request.method == 'POST' && route == '/dev/api/projects') {
      final body = await _jsonBody(request);
      final orientation = GameOrientation.fromManifestValue(
        body['orientation'] as String? ?? 'landscape',
      );
      final displayMode = body['displayMode'] as String? ?? 'multi_screen';
      final controllerOrientationValue =
          body['controllerOrientation'] as String?;
      final controllerOrientation = controllerOrientationValue == null
          ? null
          : GameOrientation.fromManifestValue(controllerOrientationValue);
      final now = clock().toUtc();
      final project = await catalog.createProject(
        DeveloperProjectDraft(
          id: body['id'] as String? ?? '',
          name: body['name'] as String? ?? '',
          author: _requireCurrentAuthor(),
          lastModifiedAt: now,
          description: body['description'] as String? ?? '',
          orientation: orientation,
          controllerOrientation: controllerOrientation,
          displayMode: displayMode,
          minPlayers: body['minPlayers'] as int? ?? 2,
          maxPlayers: body['maxPlayers'] as int? ?? 5,
          mode: body['mode'] as String? ?? 'multiplayer',
          tags: _stringValues(body['tags']),
          requiredCapabilities: _stringValues(body['requiredCapabilities']),
          controllerRequiredCapabilities: _stringValues(
            body['controllerRequiredCapabilities'],
          ),
        ),
      );
      developerEventHub.emit({
        'type': 'project.created',
        'projectId': project.id,
        'project': project.toJson(),
        'clientId': body['clientId'] as String? ?? 'api',
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.created, {
        'requestId': requestId,
        'project': project.toJson(),
      });
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/events') {
      await _serveEvents(request);
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/logs') {
      final requestedLimit = int.tryParse(
        request.uri.queryParameters['limit'] ?? '50',
      );
      if (requestedLimit == null || requestedLimit < 1 || requestedLimit > 50) {
        throw const FormatException('日志 limit 必须在 1 到 50 之间');
      }
      final projectId = request.uri.queryParameters['projectId'];
      final runId = request.uri.queryParameters['runId'];
      final cached = developerEventHub.recentLogs.where((event) {
        if (projectId != null && event['projectId'] != projectId) return false;
        if (runId != null && event['runId'] != runId) return false;
        return true;
      }).toList();
      final start = cached.length > requestedLimit
          ? cached.length - requestedLimit
          : 0;
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'logs': cached.sublist(start),
        'count': cached.length - start,
        'maxLimit': 50,
        'cachedEntries': cached.length,
      });
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/ai-context') {
      await _json(request.response, HttpStatus.ok, _aiContext(request));
      return;
    }
    if (request.method == 'GET' && route == '/dev/api/capabilities') {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'capabilities': capabilityTests.registry.descriptors
            .map((definition) => definition.toJson())
            .toList(),
      });
      return;
    }
    if (route == '/dev/api/capability-tests') {
      if (request.method == 'GET') {
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'capabilities': capabilityTests.describe(),
        });
        return;
      }
      if (request.method == 'POST') {
        final body = await _optionalJsonBody(request);
        final rawCodes = body['codes'];
        final List<Object?>? codeItems;
        if (rawCodes == null) {
          codeItems = null;
        } else if (rawCodes is List) {
          codeItems = rawCodes.cast<Object?>();
        } else {
          throw const FormatException('codes 必须是字符串数组');
        }
        final codes = codeItems
            ?.map((item) {
              if (item is! String || item.isEmpty) {
                throw const FormatException('codes 必须是非空字符串数组');
              }
              return item;
            })
            .toList(growable: false);
        final timeoutMs = body['timeoutMs'] ?? 3000;
        if (timeoutMs is! int || timeoutMs < 250 || timeoutMs > 10000) {
          throw const FormatException('timeoutMs 必须是 250 到 10000 的整数');
        }
        final results = await capabilityTests.run(
          codes: codes,
          timeout: Duration(milliseconds: timeoutMs),
        );
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'testedAt': DateTime.now().toUtc().millisecondsSinceEpoch,
          'results': results,
          'passed': results.where((item) => item['status'] == 'passed').length,
          'total': results.length,
        });
        return;
      }
    }
    if (route == '/dev/api/ai-prompt-templates' && request.method == 'GET') {
      await _servePromptTemplates(request, requestId);
      return;
    }
    if (route.startsWith('/dev/api/ai-prompt-templates/')) {
      final templateId = route.substring(
        '/dev/api/ai-prompt-templates/'.length,
      );
      if (request.method == 'PUT') {
        await _savePromptTemplate(request, requestId, templateId);
        return;
      }
      if (request.method == 'DELETE') {
        await _resetPromptTemplate(request, requestId, templateId);
        return;
      }
    }
    if (request.method == 'GET' && route == '/dev/api/qr.svg') {
      final value = request.uri.queryParameters['value'] ?? '';
      if (value.isEmpty) throw const FormatException('二维码内容不能为空');
      await _text(
        request.response,
        _qrSvg(value),
        'image/svg+xml; charset=utf-8',
      );
      return;
    }
    if (request.method == 'GET' && route.startsWith('/playmesh/')) {
      await _servePublicAsset(request, route);
      return;
    }

    final segments = request.uri.pathSegments;
    if (segments.length == 4 &&
        segments[0] == 'dev' &&
        segments[1] == 'api' &&
        segments[2] == 'projects' &&
        request.method == 'DELETE') {
      final projectId = segments[3];
      final phase = runController.status(projectId).phase;
      if (phase == DeveloperRunPhase.starting ||
          phase == DeveloperRunPhase.running) {
        await _error(
          request.response,
          HttpStatus.conflict,
          requestId,
          'game_running',
          '请先退出当前运行中的游戏，再删除项目',
        );
        return;
      }
      await catalog.deleteProject(projectId);
      developerEventHub.emit({
        'type': 'project.deleted',
        'projectId': projectId,
        'clientId': request.uri.queryParameters['clientId'] ?? 'api',
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'deleted': true,
      });
      return;
    }
    if (segments.length >= 5 &&
        segments[0] == 'dev' &&
        segments[1] == 'api' &&
        segments[2] == 'projects') {
      final projectId = segments[3];
      if (request.method == 'POST' &&
          segments.length == 5 &&
          segments[4] == 'copy') {
        final body = await _jsonBody(request);
        final project = await catalog.copyProject(
          projectId,
          id: body['id'] as String? ?? '',
          name: body['name'] as String? ?? '',
          author: _requireCurrentAuthor(),
          lastModifiedAt: clock().toUtc(),
        );
        developerEventHub.emit({
          'type': 'project.created',
          'projectId': project.id,
          'sourceProjectId': projectId,
          'project': project.toJson(),
          'clientId': body['clientId'] as String? ?? 'api',
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        await _json(request.response, HttpStatus.created, {
          'requestId': requestId,
          'sourceProjectId': projectId,
          'project': project.toJson(),
        });
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'files') {
        final files = await catalog.listFiles(projectId);
        final directories = await catalog.listDirectories(projectId);
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'projectId': projectId,
          'files': files,
          'directories': directories,
        });
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'package') {
        await _exportProjectPackage(request, requestId, projectId);
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'chat-prompt.txt') {
        await _serveAiPrompt(request, projectId, kind: _AiPromptKind.chat);
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'agent-prompt.txt') {
        await _serveAiPrompt(request, projectId, kind: _AiPromptKind.agent);
        return;
      }
      if (segments.length == 5 && segments[4] == 'directory') {
        if (request.method == 'POST') {
          await _createDirectory(request, requestId, projectId);
          return;
        }
        if (request.method == 'DELETE') {
          await _deleteDirectory(request, requestId, projectId);
          return;
        }
      }
      if (request.method == 'POST' &&
          segments.length == 5 &&
          segments[4] == 'file-operations') {
        await _fileOperation(request, requestId, projectId);
        return;
      }
      if (segments.length == 6 && segments[4] == 'quick-operations') {
        if (request.method == 'POST' && segments[5] == 'preview') {
          await _previewQuickOperations(request, requestId, projectId);
          return;
        }
        if (request.method == 'POST' && segments[5] == 'apply') {
          await _applyQuickOperations(request, requestId, projectId);
          return;
        }
      }
      if (segments.length >= 5 && segments[4] == 'local-history') {
        if (request.method == 'GET' && segments.length == 5) {
          final path = request.uri.queryParameters['path'] ?? '';
          final operations = await catalog.listLocalHistory(projectId, path);
          await _json(request.response, HttpStatus.ok, {
            'requestId': requestId,
            'projectId': projectId,
            'path': path,
            'mergeWindowSeconds':
                DeveloperLocalHistoryStore.mergeWindow.inSeconds,
            'operations': operations.map((item) => item.toJson()).toList(),
          });
          return;
        }
        if (request.method == 'GET' &&
            segments.length == 6 &&
            segments[5] == 'diff') {
          final path = request.uri.queryParameters['path'] ?? '';
          final operationId = request.uri.queryParameters['operationId'] ?? '';
          final diff = await catalog.localHistoryDiff(
            projectId,
            operationId,
            path,
          );
          await _json(request.response, HttpStatus.ok, {
            'requestId': requestId,
            ...diff.toJson(),
          });
          return;
        }
        if (request.method == 'POST' &&
            segments.length == 6 &&
            segments[5] == 'restore') {
          await _restoreLocalHistory(request, requestId, projectId);
          return;
        }
      }
      if (segments.length == 5 && segments[4] == 'file') {
        final path = request.uri.queryParameters['path'] ?? '';
        if (request.method == 'GET') {
          final file = await catalog.readFile(projectId, path);
          if (!file.isText) throw const FormatException('该接口只读取文本文件');
          request.response.headers
            ..contentType = ContentType.parse(file.contentType)
            ..set('X-Playmesh-Revision', file.revision)
            ..set('X-Playmesh-Readonly', file.readOnly);
          request.response.add(file.bytes);
          await request.response.close();
          return;
        }
        if (request.method == 'PUT') {
          await _saveFile(request, requestId, projectId, path);
          return;
        }
        if (request.method == 'PATCH') {
          await _patchFile(request, requestId, projectId, path);
          return;
        }
        if (request.method == 'DELETE') {
          await _deleteFile(request, requestId, projectId, path);
          return;
        }
      }
      if (segments.length == 5 && segments[4] == 'manifest') {
        if (request.method == 'GET') {
          await _readManifest(request, requestId, projectId);
          return;
        }
        if (request.method == 'PUT') {
          await _saveManifest(request, requestId, projectId);
          return;
        }
      }
      if (segments.length == 5 && segments[4] == 'capabilities') {
        if (request.method == 'GET') {
          await _readCapabilities(request, requestId, projectId);
          return;
        }
        if (request.method == 'PUT') {
          await _saveCapabilities(request, requestId, projectId);
          return;
        }
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'asset') {
        final path = request.uri.queryParameters['path'] ?? '';
        final file = await catalog.readFile(projectId, path);
        request.response.headers
          ..contentType = ContentType.parse(file.contentType)
          ..set('X-Playmesh-Revision', file.revision)
          ..set('X-Playmesh-Readonly', file.readOnly);
        request.response.add(file.bytes);
        await request.response.close();
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'diff') {
        final path = request.uri.queryParameters['path'] ?? '';
        await _json(
          request.response,
          HttpStatus.ok,
          (await catalog.diffFile(projectId, path)).toJson(),
        );
        return;
      }
      if (request.method == 'GET' &&
          segments.length == 5 &&
          segments[4] == 'validate') {
        final report = await catalog.validateProject(projectId);
        developerEventHub.emit({
          'type': 'project.validated',
          'projectId': projectId,
          'valid': report.valid,
          'errorCount': report.errorCount,
          'warningCount': report.warningCount,
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          ...report.toJson(),
        });
        return;
      }
      if (request.method == 'DELETE' &&
          segments.length == 5 &&
          segments[4] == 'data') {
        final phase = runController.status(projectId).phase;
        if (phase == DeveloperRunPhase.starting ||
            phase == DeveloperRunPhase.running) {
          await _error(
            request.response,
            HttpStatus.conflict,
            requestId,
            'game_running',
            '请先退出当前运行中的游戏，再清理游戏数据',
          );
          return;
        }
        final existed = await catalog.clearGameData(projectId);
        developerEventHub.emit({
          'type': 'project.data-cleared',
          'projectId': projectId,
          'existed': existed,
          'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
        });
        await _json(request.response, HttpStatus.ok, {
          'requestId': requestId,
          'projectId': projectId,
          'directory': 'data',
          'existed': existed,
          'cachePreserved': true,
        });
        return;
      }
      if (segments.length == 5 && segments[4] == 'run') {
        if (request.method == 'POST') {
          await catalog.prepareGame(projectId);
          final status = await runController.run(projectId);
          await _json(request.response, HttpStatus.accepted, status.toJson());
          return;
        }
        if (request.method == 'GET') {
          await _json(
            request.response,
            HttpStatus.ok,
            runController.status(projectId).toJson(),
          );
          return;
        }
      }
      if (request.method == 'POST' &&
          segments.length == 6 &&
          segments[4] == 'run' &&
          segments[5] == 'restart') {
        final status = await runController.restart(projectId);
        await _json(request.response, HttpStatus.accepted, status.toJson());
        return;
      }
      if (request.method == 'POST' &&
          segments.length == 6 &&
          segments[4] == 'run' &&
          segments[5] == 'stop') {
        final status = await runController.stop(projectId);
        await _json(request.response, HttpStatus.ok, status.toJson());
        return;
      }
    }

    await _error(
      request.response,
      HttpStatus.notFound,
      requestId,
      'route_not_found',
      '开发者接口不存在',
    );
  }

  Future<void> _serveSdkBundle(HttpRequest request, String requestId) async {
    const names = [
      'playmesh.js',
      'playmesh-app.js',
      'playmesh.d.ts',
      'playmesh-app.d.ts',
    ];
    final files = <String, String>{};
    for (final name in names) {
      final data = await rootBundle.load(
        'assets/playmesh-library/public/sdk/v1/$name',
      );
      files[name] = base64Encode(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'gameSdkVersion': generatedGameSdkVersion,
      'appSdkVersion': generatedAppSdkVersion,
      'encoding': 'base64',
      'files': files,
    });
  }

  Future<void> _exportProjectPackage(
    HttpRequest request,
    String requestId,
    String projectId,
  ) => _serializePackageFile(
    () => _exportProjectPackageNow(request, requestId, projectId),
  );

  Future<void> _exportProjectPackageNow(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-developer-export.playmesh.zip',
    );
    try {
      if (await file.exists()) await file.delete();
      final project = (await catalog.listProjects()).firstWhere(
        (candidate) => candidate.id == projectId,
        orElse: () => throw StateError('开发者项目不存在'),
      );
      final rootFilePath = project.rootFilePath;
      if (rootFilePath == null) {
        throw StateError('该项目没有可拉取的本地工作区');
      }
      final game = GameSummary(
        id: project.id,
        name: project.name,
        version: project.version,
        description: '',
        minPlayers: 1,
        maxPlayers: 1,
        supportsMultiplayer: false,
        displayModeLabel: '',
        displayMode: 'multi_screen',
        orientation: GameOrientation.landscape,
        entry: LocalGameEntry(
          assetPath: 'app/index.html',
          statusLabel: '开发项目',
          packageRootFilePath: rootFilePath,
        ),
      );
      await packageTransfer.exportPackage(game, file, validate: false);
      request.response.headers
        ..contentType = ContentType('application', 'zip')
        ..set(
          'Content-Disposition',
          'attachment; filename="$projectId.playmesh.zip"',
        )
        ..set('X-Request-ID', requestId);
      await file.openRead().pipe(request.response);
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _importPackage(HttpRequest request, String requestId) =>
      _serializePackageFile(() => _importPackageNow(request, requestId));

  Future<void> _importPackageNow(HttpRequest request, String requestId) async {
    final builder = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in request) {
      length += chunk.length;
      if (length > GamePackageTransferService.maxCompressedBytes) {
        throw const FormatException('游戏包压缩文件不能超过 64 MiB');
      }
      builder.add(chunk);
    }
    if (length == 0) throw const FormatException('上传的游戏包不能为空');
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'playmesh-developer-import.playmesh.zip',
    );
    try {
      if (await file.exists()) await file.delete();
      await file.writeAsBytes(builder.takeBytes(), flush: true);
      final game = await catalog.publishPackage(
        file,
        author: _requireCurrentAuthor(),
        lastModifiedAt: clock().toUtc(),
      );
      developerEventHub.emit({
        'type': 'project.imported',
        'projectId': game.id,
        'version': game.version,
        'clientId': request.headers.value('X-Playmesh-Client-ID') ?? 'cli',
        'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
      });
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'project': {'id': game.id, 'name': game.name, 'version': game.version},
        'committed': true,
        'preservedDirectories': ['data', 'cache'],
      });
    } finally {
      if (await file.exists()) await file.delete();
    }
  }

  Future<T> _serializePackageFile<T>(Future<T> Function() action) {
    final operation = _packageFileTail.then((_) => action());
    _packageFileTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _servePublicAsset(HttpRequest request, String route) async {
    final relativePath = route.substring('/playmesh/'.length);
    if (relativePath.isEmpty || relativePath.split('/').contains('..')) {
      throw const FormatException('平台资源路径无效');
    }
    final data = await rootBundle.load(
      'assets/playmesh-library/public/$relativePath',
    );
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    request.response.headers.contentType = ContentType.parse(
      _publicContentType(relativePath),
    );
    request.response.add(bytes);
    await request.response.close();
  }

  Future<void> _serveDeveloperFile(
    HttpRequest request,
    String relativePath,
  ) async {
    if (relativePath.isEmpty || relativePath.split('/').contains('..')) {
      throw const FormatException('开发者文档资源路径无效');
    }
    final data = await rootBundle.load(
      'assets/playmesh-library/public/developer/$relativePath',
    );
    request.response.headers.contentType = ContentType.parse(
      _publicContentType(relativePath),
    );
    request.response.add(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    await request.response.close();
  }

  Future<void> _serveAiPrompt(
    HttpRequest request,
    String projectId, {
    required _AiPromptKind kind,
  }) async {
    final isAgent = kind == _AiPromptKind.agent;
    final manifestFile = await catalog.readFile(projectId, 'main.json');
    final decodedManifest = jsonDecode(utf8.decode(manifestFile.bytes));
    if (decodedManifest is! Map) throw const FormatException('main.json 必须是对象');
    final manifest = Map<String, Object?>.from(decodedManifest);
    final modes = _stringValues(manifest['modes']);
    final displayModes = _stringValues(manifest['displayModes']);
    if (modes.length != 1) {
      throw const FormatException('main.json modes 必须且只能声明一个游戏模式');
    }
    if (displayModes.length != 1) {
      throw const FormatException('main.json displayModes 必须且只能声明一个显示模式');
    }
    final isSolo = modes.contains('solo');
    final isMultiplayer = modes.contains('multiplayer');
    final isMultiScreen = displayModes.contains('multi_screen');
    final isSingleScreen = displayModes.contains('single_screen_multiplayer');
    final entries = manifest['entries'];
    final gameEntry = entries is Map && entries['game'] is String
        ? (entries['game'] as String).trim()
        : 'app/index.html';
    final controllerEntry = entries is Map && entries['controller'] is String
        ? (entries['controller'] as String).trim()
        : 'app/controller/index.html';
    if (!isSolo && !isMultiplayer) {
      throw const FormatException('main.json 未声明支持的游戏模式');
    }
    if (isMultiplayer && !isMultiScreen && !isSingleScreen) {
      throw const FormatException('联机游戏未声明支持的显示模式');
    }
    final authority = manifest['authority'];
    final authorityEntry = authority is Map && authority['entry'] is String
        ? (authority['entry'] as String).trim()
        : null;
    if (isMultiplayer && (authorityEntry == null || authorityEntry.isEmpty)) {
      throw const FormatException('联机游戏 main.json 缺少 authority.entry');
    }

    final projectFiles = await catalog.listFiles(projectId);
    var declaredCapabilities = const <String>[];
    var controllerDeclaredCapabilities = const <String>[];
    if (projectFiles.contains('capabilities.json')) {
      final capabilitiesFile = await catalog.readFile(
        projectId,
        'capabilities.json',
      );
      final decodedCapabilities = jsonDecode(
        utf8.decode(capabilitiesFile.bytes),
      );
      if (decodedCapabilities is! Map) {
        throw const FormatException('capabilities.json 必须是对象');
      }
      final capabilities = GameCapabilities.fromJson(
        Map<String, Object?>.from(decodedCapabilities),
      );
      declaredCapabilities = capabilities.required.toList()..sort();
      controllerDeclaredCapabilities = capabilities.controllerRequired.toList()
        ..sort();
    }

    final promptParts = <String>[
      await _loadPromptTemplate(isAgent ? 'agent-common' : 'common'),
      await _loadPromptTemplate('custom-ideas'),
      if (isSolo) await _loadPromptTemplate('solo'),
      if (isMultiplayer) await _loadPromptTemplate('multiplayer'),
      if (isMultiplayer && isMultiScreen)
        await _loadPromptTemplate('multi-screen'),
      if (isMultiplayer && isSingleScreen)
        await _loadPromptTemplate('single-screen-multiplayer'),
    ];
    final gameSdkDeclaration = await rootBundle.loadString(
      'assets/playmesh-library/public/sdk/v1/playmesh.d.ts',
    );
    final appSdkDeclaration = await rootBundle.loadString(
      'assets/playmesh-library/public/sdk/v1/playmesh-app.d.ts',
    );
    final allDirectories = [...await catalog.listDirectories(projectId)]
      ..sort();
    final allPaths = [...projectFiles]..sort();
    bool relevant(String path) => _isPromptRelevantPath(
      path,
      includeAuthority: isMultiplayer,
      includeController: isMultiplayer && isSingleScreen,
    );
    final directories = allDirectories.where(relevant).toList();
    final paths = allPaths.where(relevant).toList();
    final authorityExists =
        authorityEntry != null && paths.contains(authorityEntry);
    String presentedPath(String path) {
      if (isAgent || !path.startsWith('app/')) return path;
      return path.substring('app/'.length);
    }

    final presentedGameEntry = presentedPath(gameEntry);
    final presentedControllerEntry = presentedPath(controllerEntry);
    final output = StringBuffer()
      ..writeln(promptParts.map((part) => part.trim()).join('\n\n'))
      ..writeln()
      ..writeln('============================================================')
      ..writeln('统一 SDK TypeScript 声明（唯一接口事实源）')
      ..writeln('============================================================')
      ..writeln('以下内容由 SDK 手写源在同一次构建中生成；方法、参数、返回值、类型、版本和中文 JSDoc 均以此为准。')
      ..writeln('提示词中的规则性摘要不能覆盖或扩展这些声明。')
      ..writeln()
      ..writeln('===== BEGIN SDK DECLARATION: playmesh.d.ts =====')
      ..writeln(gameSdkDeclaration.trim())
      ..writeln('===== END SDK DECLARATION: playmesh.d.ts =====')
      ..writeln()
      ..writeln('===== BEGIN SDK DECLARATION: playmesh-app.d.ts =====')
      ..writeln(appSdkDeclaration.trim())
      ..writeln('===== END SDK DECLARATION: playmesh-app.d.ts =====')
      ..writeln()
      ..writeln('============================================================')
      ..writeln('当前项目类型与强制交付要求（最高优先级）')
      ..writeln('============================================================')
      ..writeln()
      ..writeln('projectId: $projectId')
      ..writeln('modes: ${modes.join(', ')}')
      ..writeln('displayModes: ${displayModes.join(', ')}')
      ..writeln(
        isAgent
            ? 'entries.game: $gameEntry'
            : 'entries.game（快速操作路径）: $presentedGameEntry',
      )
      ..writeln(
        isAgent
            ? 'entries.controller: $controllerEntry'
            : 'entries.controller（快速操作路径）: $presentedControllerEntry',
      )
      ..writeln('exportedAt: ${DateTime.now().toUtc().toIso8601String()}')
      ..writeln(
        '本项目允许的公共 SDK：playmesh.version、playmesh.ready、'
        'playmesh.lifecycle.*、playmesh.storage.*、playmesh.performance.*、'
        'playmesh.app.*',
      )
      ..writeln(
        '当前 capabilities.json.required：'
        '${declaredCapabilities.isEmpty ? '未声明' : declaredCapabilities.join(', ')}',
      )
      ..writeln(
        '当前 capabilities.json.controllerRequired：'
        '${controllerDeclaredCapabilities.isEmpty ? '未声明' : controllerDeclaredCapabilities.join(', ')}',
      );
    if (!isAgent) {
      final selectedCodes = {
        ...declaredCapabilities,
        ...controllerDeclaredCapabilities,
      };
      final selectedDefinitions = capabilityTests.registry.descriptors
          .where((definition) => selectedCodes.contains(definition.code))
          .map((definition) => definition.toJson())
          .toList(growable: false);
      output
        ..writeln()
        ..writeln('当前项目已勾选能力的完整声明（对话 AI 能力上下文）：')
        ..writeln(
          '这里只提供 capabilities.json.required/controllerRequired '
          '已声明的能力，不包含未勾选的平台注册能力。',
        );
      if (selectedDefinitions.isEmpty) {
        output.writeln('未声明平台能力。');
      } else {
        output.writeln(
          const JsonEncoder.withIndent('  ').convert(selectedDefinitions),
        );
      }
    }
    if (isAgent) {
      final origin = await _promptBaseUrl(request);
      final workspaceUrl = origin.replace(
        path: session.workspacePath,
        queryParameters: {'token': token},
      );
      String endpoint(String route) => origin.replace(path: route).toString();
      output
        ..writeln()
        ..writeln(
          '============================================================',
        )
        ..writeln('Developer Gateway 接口（Agent 必须直接调用）')
        ..writeln(
          '============================================================',
        )
        ..writeln('Base URL: $origin')
        ..writeln('Authorization: Bearer $token')
        ..writeln(
          '本地 CLI 连接命令（完整地址，可直接执行）: '
          'playmesh-cli to "$workspaceUrl"',
        )
        ..writeln('项目 ID: $projectId')
        ..writeln('GET ${endpoint('/dev/api/projects/$projectId/files')}')
        ..writeln(
          'GET|PUT ${endpoint('/dev/api/projects/$projectId/manifest')} '
          '(id 不可修改)',
        )
        ..writeln(
          'GET|PUT ${endpoint('/dev/api/projects/$projectId/capabilities')}',
        )
        ..writeln(
          'GET ${endpoint('/dev/api/capabilities')} '
          '(读取当前全平台注册能力列表及每项完整声明：code、apiVersion、平台状态、optionsSchema、methods、events)',
        )
        ..writeln(
          'GET ${endpoint('/dev/api/capability-tests')} '
          '(读取当前全平台能力测试项与可测试状态)',
        )
        ..writeln(
          'POST ${endpoint('/dev/api/capability-tests')} '
          '(执行能力测试；JSON: {"codes":["能力 code"],"timeoutMs":3000}；codes 省略或为空时测试全部)',
        )
        ..writeln(
          'GET|PUT|PATCH|DELETE '
          '${endpoint('/dev/api/projects/$projectId/file')}?path={path}',
        )
        ..writeln(
          'GET ${endpoint('/dev/api/projects/$projectId/asset')}?path={path}',
        )
        ..writeln(
          'POST|DELETE '
          '${endpoint('/dev/api/projects/$projectId/directory')}?path={path}',
        )
        ..writeln(
          'POST ${endpoint('/dev/api/projects/$projectId/file-operations')}',
        )
        ..writeln(
          'POST ${endpoint('/dev/api/projects/$projectId/quick-operations/preview')}',
        )
        ..writeln(
          'POST ${endpoint('/dev/api/projects/$projectId/quick-operations/apply')}',
        )
        ..writeln('GET ${endpoint('/dev/api/projects/$projectId/validate')}')
        ..writeln(
          'DELETE ${endpoint('/dev/api/projects/$projectId/data')} '
          '(高风险：仅删除 data，保留 cache；游戏运行中不可调用)',
        )
        ..writeln('GET|POST ${endpoint('/dev/api/projects/$projectId/run')}')
        ..writeln(
          'POST ${endpoint('/dev/api/projects/$projectId/run/restart')}',
        )
        ..writeln('POST ${endpoint('/dev/api/projects/$projectId/run/stop')}')
        ..writeln('GET ${endpoint('/dev/api/logs')}?limit=50')
        ..writeln('GET ${endpoint('/dev/api/events')} (可选 SSE 实时通道)')
        ..writeln('GET ${endpoint('/dev/sdk-manifest.json')}')
        ..writeln('GET ${endpoint('/dev/schemas/sdk-v1.json')}')
        ..writeln('GET ${endpoint('/dev/schemas/game-manifest.json')}')
        ..writeln('GET ${endpoint('/dev/schemas/game-capabilities.json')}')
        ..writeln('GET ${endpoint('/dev/openapi.json')}')
        ..writeln(
          '写文件必须携带当前 baseRevision；main.json 原文只读，只能通过 '
          'manifest API 修改且 id 不可修改。',
        );
    }
    if (isSolo && !isMultiplayer) {
      output
        ..writeln('唯一允许类型：单机')
        ..writeln('禁止生成 controller、Authority service 或任何联机 SDK 代码。');
    }
    if (isMultiplayer) {
      final quickAuthorityPath = authorityEntry!.startsWith('app/')
          ? authorityEntry.substring('app/'.length)
          : authorityEntry;
      output
        ..writeln(
          '本项目额外允许的联机 SDK：playmesh.session.*、playmesh.player.*、'
          'playmesh.sync.*；playmesh.game.*、playmesh.authority.onService '
          '仅用于高级自定义消息',
        )
        ..writeln(
          isAgent
              ? 'Authority 入口：$authorityEntry'
              : 'Authority 入口（快速操作路径）：$quickAuthorityPath',
        )
        ..writeln('Authority 入口当前存在：$authorityExists')
        ..writeln(
          authorityExists
              ? isAgent
                    ? '必须读取并在需要时通过文件 API 完整实现：$authorityEntry'
                    : '必须检查并在需要时使用 replace_file:$quickAuthorityPath 完整实现该入口。'
              : isAgent
              ? '必须通过文件 API 创建：$authorityEntry'
              : '本次回答必须使用 create_file 或 replace_file 创建：$quickAuthorityPath',
        )
        ..writeln(
          '$presentedGameEntry 必须加载 Authority 入口，并在 isAuthority() 为 true 时启动状态同步。',
        )
        ..writeln(
          '每个 sync.submitAction 类型必须有 onInput 处理分支，所有页面必须 observe 最新快照。',
        );
    }
    if (isMultiplayer && isMultiScreen && !isSingleScreen) {
      output.writeln('唯一允许显示类型：普通多人多屏；不得创建或使用 $presentedControllerEntry。');
    }
    if (isMultiplayer && isSingleScreen && !isMultiScreen) {
      output.writeln('唯一允许显示类型：单屏多人；必须完整实现 $presentedControllerEntry。');
    }
    output
      ..writeln()
      ..writeln('============================================================')
      ..writeln('当前项目树（已排除与当前游戏类型无关的骨架文件）')
      ..writeln('============================================================')
      ..writeln();
    for (final directory in directories) {
      final shown = presentedPath(directory);
      if (isAgent || (shown.isNotEmpty && shown != 'app')) {
        output.writeln('- [directory] $shown/');
      }
    }
    for (final path in paths) {
      output.writeln('- [file] ${presentedPath(path)}');
    }
    output
      ..writeln()
      ..writeln('============================================================')
      ..writeln('当前项目文件')
      ..writeln('============================================================')
      ..writeln();
    for (final path in paths) {
      final file = await catalog.readFile(projectId, path);
      final content = _chatAiTextContent(file);
      output
        ..writeln('===== BEGIN WORKSPACE FILE: ${presentedPath(path)} =====')
        ..writeln('content-type: ${file.contentType}')
        ..writeln('size: ${file.bytes.length} bytes')
        ..writeln('revision: ${file.revision}')
        ..writeln('read-only: ${file.readOnly}');
      if (content == null) {
        output.writeln(
          'content: [binary omitted from text bundle; use this path and '
          'metadata when requesting the resource from the user]',
        );
      } else {
        output
          ..writeln('----- CONTENT -----')
          ..writeln(content);
      }
      output
        ..writeln('===== END WORKSPACE FILE: ${presentedPath(path)} =====')
        ..writeln();
    }
    output
      ..writeln('============================================================')
      ..writeln('最终执行指令')
      ..writeln('============================================================')
      ..writeln('只根据上面声明的当前游戏类型修改项目。')
      ..writeln('当前项目源码优先于示例，但不得违反强制交付要求。');
    if (isMultiplayer) {
      output
        ..writeln('输出前再次确认 Authority 入口存在且不是空壳。')
        ..writeln('输出前再次确认 sync.submitAction -> onInput -> observe 数据链完整。');
    }
    if (isAgent) {
      output
        ..writeln('直接调用上面的 Developer Gateway 接口完成修改，不要只返回代码。')
        ..writeln('修改后必须调用 validate 并修复全部 error。')
        ..writeln('未运行时调用 run，已运行时可调用 run/restart 或 run/stop；轮询 GET run 获取结果。')
        ..writeln('最后调用 GET /dev/api/logs?limit=50 读取结构化日志；不强制消费 SSE。');
    } else {
      output.writeln('最终回答只能包含可直接粘贴到工作区的快速操作文本。');
    }
    final fileKind = isAgent ? 'agent' : 'chat';
    request.response.headers
      ..contentType = ContentType('text', 'plain', charset: 'utf-8')
      ..set(
        'Content-Disposition',
        'attachment; filename="$projectId-playmesh-$fileKind-prompt.txt"',
      );
    final encoded = utf8.encode(output.toString());
    final downloadBytes = <int>[0xef, 0xbb, 0xbf, ...encoded];
    request.response.contentLength = downloadBytes.length;
    request.response.add(downloadBytes);
    await request.response.close();
  }

  Future<String> _loadPromptTemplate(String id) async =>
      (await promptTemplates.read(id)).content;

  Future<List<Uri>> _availableBaseUrls(HttpRequest request) async {
    final urls = <String, Uri>{};
    void add(Uri uri) {
      final normalized = Uri(scheme: 'http', host: uri.host, port: server.port);
      urls[normalized.toString()] = normalized;
    }

    add(request.requestedUri);
    for (final endpoint in await resolveLanEndpoints(server.port)) {
      add(endpoint);
    }
    add(Uri(scheme: 'http', host: InternetAddress.loopbackIPv4.address));
    return urls.values.toList(growable: false);
  }

  Future<Uri> _promptBaseUrl(HttpRequest request) async {
    final selected = request.uri.queryParameters['baseUrl']?.trim() ?? '';
    if (selected.isEmpty) {
      return Uri(
        scheme: request.requestedUri.scheme,
        host: request.requestedUri.host,
        port: request.requestedUri.port,
      );
    }
    final parsed = Uri.tryParse(selected);
    if (parsed == null ||
        parsed.scheme != 'http' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.port != server.port ||
        (parsed.path.isNotEmpty && parsed.path != '/') ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw const FormatException('Agent Base URL 必须是当前开发者网关的本机 HTTP 地址');
    }
    final normalized = Uri(
      scheme: 'http',
      host: parsed.host,
      port: server.port,
    );
    final available = await _availableBaseUrls(request);
    if (!available.contains(normalized)) {
      throw const FormatException('Agent Base URL 不属于当前设备的可用地址');
    }
    return normalized;
  }

  Future<void> _servePromptTemplates(
    HttpRequest request,
    String requestId,
  ) async {
    final templates = await promptTemplates.list();
    final categories = <String, Map<String, Object?>>{};
    for (final template in templates) {
      final descriptor = template.descriptor;
      final category = categories.putIfAbsent(
        descriptor.category,
        () => {
          'id': descriptor.category,
          'name': descriptor.categoryName,
          'items': <Object?>[],
        },
      );
      (category['items']! as List<Object?>).add(template.toJson());
    }
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'categories': categories.values.toList(growable: false),
    });
  }

  Future<void> _savePromptTemplate(
    HttpRequest request,
    String requestId,
    String templateId,
  ) async {
    final body = await _jsonBody(request);
    final content = body['content'];
    if (content is! String) throw const FormatException('content 必须是字符串');
    final template = await promptTemplates.save(templateId, content);
    developerEventHub.emit({
      'type': 'ai.prompt-template.saved',
      'templateId': templateId,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'template': template.toJson(),
    });
  }

  Future<void> _resetPromptTemplate(
    HttpRequest request,
    String requestId,
    String templateId,
  ) async {
    final template = await promptTemplates.reset(templateId);
    developerEventHub.emit({
      'type': 'ai.prompt-template.reset',
      'templateId': templateId,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'template': template.toJson(),
    });
  }

  Future<void> _createDirectory(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final path = request.uri.queryParameters['path'] ?? '';
    final body = await _optionalJsonBody(request);
    await catalog.createDirectory(projectId, path);
    developerEventHub.emit({
      'type': 'directory.created',
      'projectId': projectId,
      'path': path,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.created, {
      'requestId': requestId,
      'projectId': projectId,
      'path': path,
      'created': true,
    });
  }

  Future<void> _restoreLocalHistory(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    final operationId = body['operationId'];
    final path = body['path'];
    final versionName = body['version'];
    if (operationId is! String || path is! String || versionName is! String) {
      throw const FormatException('operationId、path 和 version 必须是字符串');
    }
    final version = switch (versionName) {
      'before' => DeveloperHistoryVersion.before,
      'after' => DeveloperHistoryVersion.after,
      _ => throw const FormatException('version 只支持 before 或 after'),
    };
    await catalog.restoreLocalHistory(projectId, operationId, path, version);
    developerEventHub.emit({
      'type': 'workspace.restored',
      'projectId': projectId,
      'path': path,
      'operationId': operationId,
      'version': version.name,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'path': path,
      'operationId': operationId,
      'version': version.name,
      'restored': true,
    });
  }

  Future<void> _deleteDirectory(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final path = request.uri.queryParameters['path'] ?? '';
    final body = await _optionalJsonBody(request);
    await catalog.deleteDirectory(projectId, path);
    developerEventHub.emit({
      'type': 'directory.deleted',
      'projectId': projectId,
      'path': path,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'path': path,
      'deleted': true,
    });
  }

  Future<void> _fileOperation(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    final operation = body['operation'];
    final source = body['source'];
    final destination = body['destination'];
    if (operation is! String || source is! String || destination is! String) {
      throw const FormatException('operation、source、destination 必须是字符串');
    }
    List<String> extracted = const [];
    switch (operation) {
      case 'copy':
        await catalog.copyEntry(projectId, source, destination);
        break;
      case 'move':
        await catalog.moveEntry(projectId, source, destination);
        break;
      case 'extract':
        extracted = await catalog.extractZip(projectId, source, destination);
        break;
      default:
        throw const FormatException('operation 只支持 copy、move 或 extract');
    }
    developerEventHub.emit({
      'type': 'files.operated',
      'projectId': projectId,
      'operation': operation,
      'source': source,
      'destination': destination,
      'clientId': body['clientId'],
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'operation': operation,
      'source': source,
      'destination': destination,
      'extracted': extracted,
    });
  }

  Future<void> _saveFile(
    HttpRequest request,
    String requestId,
    String projectId,
    String path,
  ) async {
    final body = await _jsonBody(request);
    final content = body['content'];
    if (content is! String) throw const FormatException('content 必须是字符串');
    DeveloperProjectFile? before;
    try {
      before = await catalog.readFile(projectId, path);
    } on StateError {
      // PUT also creates new files inside the project sandbox.
    }
    final encoding = body['encoding'] as String? ?? 'utf8';
    final bytes = switch (encoding) {
      'utf8' => utf8.encode(content),
      'base64' => base64Decode(content),
      _ => throw const FormatException('encoding 只支持 utf8 或 base64'),
    };
    final saved = await catalog.writeFile(
      projectId,
      path,
      bytes,
      expectedRevision: body['baseRevision'] as int?,
    );
    final operations = before != null && before.isText && encoding == 'utf8'
        ? _minimalOperations(utf8.decode(before.bytes), content)
        : const <Map<String, Object?>>[];
    _emitFileEvent(
      type: 'file.saved',
      projectId: projectId,
      path: path,
      revision: saved.revision,
      clientId: body['clientId'] as String?,
      operations: operations,
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      ..._fileJson(saved),
    });
  }

  Future<void> _readManifest(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final file = await catalog.readFile(projectId, 'main.json');
    final decoded = jsonDecode(utf8.decode(file.bytes));
    if (decoded is! Map) throw const FormatException('项目 main.json 无效');
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'revision': file.revision,
      'manifest': Map<String, Object?>.from(decoded),
    });
  }

  Future<void> _saveManifest(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    final rawManifest = body['manifest'];
    if (rawManifest is! Map) {
      throw const FormatException('manifest 必须是对象');
    }
    final before = await catalog.readFile(projectId, 'main.json');
    final saved = await catalog.updateManifest(
      projectId,
      Map<String, Object?>.from(rawManifest),
      expectedRevision: body['baseRevision'] as int?,
    );
    final content = utf8.decode(saved.bytes);
    _emitFileEvent(
      type: 'manifest.saved',
      projectId: projectId,
      path: 'main.json',
      revision: saved.revision,
      clientId: body['clientId'] as String?,
      operations: _minimalOperations(utf8.decode(before.bytes), content),
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'revision': saved.revision,
      'manifest': jsonDecode(content),
    });
  }

  Future<void> _readCapabilities(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    try {
      final file = await catalog.readFile(projectId, 'capabilities.json');
      final decoded = jsonDecode(utf8.decode(file.bytes));
      if (decoded is! Map) {
        throw const FormatException('项目 capabilities.json 无效');
      }
      final capabilities = GameCapabilities.fromJson(
        Map<String, Object?>.from(decoded),
      );
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'exists': true,
        'revision': file.revision,
        'required': capabilities.required.toList(),
        'controllerRequired': capabilities.controllerRequired.toList(),
      });
    } on StateError {
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'exists': false,
        'revision': 0,
        'required': <String>[],
        'controllerRequired': <String>[],
      });
    }
  }

  Future<void> _saveCapabilities(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    final required = body['required'];
    final capabilities = GameCapabilities.fromJson({
      'required': required,
      'controllerRequired': body['controllerRequired'],
    });
    final manifest = jsonDecode(
      utf8.decode((await catalog.readFile(projectId, 'main.json')).bytes),
    );
    final singleScreen =
        manifest is Map &&
        manifest['displayModes'] is List &&
        (manifest['displayModes'] as List).contains(
          'single_screen_multiplayer',
        );
    if (!singleScreen && capabilities.controllerRequired.isNotEmpty) {
      throw const FormatException('仅单屏多人项目可以声明控制器能力');
    }
    DeveloperProjectFile? before;
    try {
      before = await catalog.readFile(projectId, 'capabilities.json');
    } on StateError {
      // An empty declaration is represented by an absent optional file.
    }
    final clientId = body['clientId'] as String?;
    if (capabilities.isEmpty) {
      if (before != null) {
        await catalog.deleteFile(
          projectId,
          'capabilities.json',
          expectedRevision: body['baseRevision'] as int?,
        );
        _emitFileEvent(
          type: 'file.deleted',
          projectId: projectId,
          path: 'capabilities.json',
          revision: before.revision + 1,
          clientId: clientId,
          operations: const [],
        );
      }
      await _json(request.response, HttpStatus.ok, {
        'requestId': requestId,
        'projectId': projectId,
        'exists': false,
        'revision': before == null ? 0 : before.revision + 1,
        'required': <String>[],
        'controllerRequired': <String>[],
      });
      return;
    }
    final content =
        '${const JsonEncoder.withIndent('  ').convert(capabilities.toJson())}\n';
    final saved = await catalog.writeFile(
      projectId,
      'capabilities.json',
      utf8.encode(content),
      expectedRevision: body['baseRevision'] as int?,
    );
    _emitFileEvent(
      type: 'capabilities.saved',
      projectId: projectId,
      path: 'capabilities.json',
      revision: saved.revision,
      clientId: clientId,
      operations: before == null
          ? const []
          : _minimalOperations(utf8.decode(before.bytes), content),
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'exists': true,
      'revision': saved.revision,
      'required': capabilities.required.toList(),
      'controllerRequired': capabilities.controllerRequired.toList(),
    });
  }

  Future<void> _patchFile(
    HttpRequest request,
    String requestId,
    String projectId,
    String path,
  ) async {
    final body = await _jsonBody(request);
    final current = await catalog.readFile(projectId, path);
    if (!current.isText) throw const FormatException('仅文本文件支持范围编辑');
    final rawOperations = body['operations'];
    if (rawOperations is! List || rawOperations.isEmpty) {
      throw const FormatException('operations 必须是非空数组');
    }
    var content = utf8.decode(current.bytes);
    final operations = <Map<String, Object?>>[];
    for (final raw in rawOperations) {
      if (raw is! Map) throw const FormatException('编辑操作格式无效');
      final operation = Map<String, Object?>.from(raw);
      final start = operation['start'];
      final end = operation['end'];
      final text = operation['text'];
      if (start is! int ||
          end is! int ||
          text is! String ||
          start < 0 ||
          end < start ||
          end > content.length) {
        throw const FormatException('编辑范围无效');
      }
      content = content.replaceRange(start, end, text);
      operations.add({'start': start, 'end': end, 'text': text});
    }
    final saved = await catalog.writeFile(
      projectId,
      path,
      utf8.encode(content),
      expectedRevision: body['baseRevision'] as int?,
    );
    _emitFileEvent(
      type: 'file.patched',
      projectId: projectId,
      path: path,
      revision: saved.revision,
      clientId: body['clientId'] as String?,
      operations: operations,
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      ..._fileJson(saved),
    });
  }

  Future<void> _deleteFile(
    HttpRequest request,
    String requestId,
    String projectId,
    String path,
  ) async {
    final body = await _optionalJsonBody(request);
    await catalog.deleteFile(
      projectId,
      path,
      expectedRevision: body['baseRevision'] as int?,
    );
    final revision = (body['baseRevision'] as int? ?? 0) + 1;
    _emitFileEvent(
      type: 'file.deleted',
      projectId: projectId,
      path: path,
      revision: revision,
      clientId: body['clientId'] as String?,
      operations: const [],
    );
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'projectId': projectId,
      'path': path,
      'deleted': true,
      'revision': revision,
    });
  }

  Future<void> _previewQuickOperations(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    final commands = body['commands'];
    if (commands is! String) {
      throw const FormatException('commands 必须是字符串');
    }
    final preview = await _buildQuickPreview(projectId, commands);
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      ...preview.toJson(),
    });
  }

  Future<void> _applyQuickOperations(
    HttpRequest request,
    String requestId,
    String projectId,
  ) async {
    final body = await _jsonBody(request);
    final commands = body['commands'];
    if (commands is! String) {
      throw const FormatException('commands 必须是字符串');
    }
    final preview = await _buildQuickPreview(projectId, commands);
    final rawRevisions = body['baseRevisions'];
    if (rawRevisions is! Map) {
      throw const FormatException('应用前必须先预览并提交 baseRevisions');
    }
    final expectedRevisions = <String, int>{};
    for (final entry in rawRevisions.entries) {
      if (entry.key is! String || entry.value is! int) {
        throw const FormatException('baseRevisions 格式无效');
      }
      expectedRevisions[entry.key as String] = entry.value as int;
    }
    final changed = {
      for (final file in preview.files)
        if (file.original != file.current) file.path: utf8.encode(file.current),
    };
    if (changed.isEmpty) throw const FormatException('快速操作没有产生修改');
    final saved = await catalog.writeFilesAtomic(
      projectId,
      changed,
      expectedRevisions: expectedRevisions,
    );
    final clientId = body['clientId'] as String?;
    for (final file in saved) {
      final before = preview.files.firstWhere((item) => item.path == file.path);
      _emitFileEvent(
        type: 'file.batch',
        projectId: projectId,
        path: file.path,
        revision: file.revision,
        clientId: clientId,
        operations: _minimalOperations(before.original, before.current),
      );
    }
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      'applied': saved.map(_fileJson).toList(),
    });
  }

  Future<_QuickPreview> _buildQuickPreview(
    String projectId,
    String commands,
  ) async {
    final operations = _parseQuickOperations(commands);
    final available = (await catalog.listFiles(projectId)).toSet();
    final working = <String, String>{};
    final originals = <String, String>{};
    final revisions = <String, int>{};
    final createdPaths = <String>{};

    Future<void> load(String path, {required bool mustExist}) async {
      if (working.containsKey(path)) return;
      if (!available.contains(path)) {
        if (mustExist) {
          throw FormatException(
            '文件不存在：$path；新文件请使用 create_file 或 replace_file',
          );
        }
        working[path] = '';
        originals[path] = '';
        revisions[path] = 0;
        return;
      }
      final file = await catalog.readFile(projectId, path);
      if (!file.isText) throw FormatException('仅文本文件支持快速操作：$path');
      final content = utf8.decode(file.bytes);
      working[path] = content;
      originals[path] = content;
      revisions[path] = file.revision;
    }

    for (final operation in operations) {
      final exists =
          available.contains(operation.path) ||
          createdPaths.contains(operation.path);
      switch (operation.type) {
        case _QuickOperationType.createFile:
          if (exists) throw FormatException('文件已存在：${operation.path}');
          await load(operation.path, mustExist: false);
          working[operation.path] = operation.content;
          createdPaths.add(operation.path);
        case _QuickOperationType.replaceFile:
          await load(operation.path, mustExist: false);
          working[operation.path] = operation.content;
          if (!exists) createdPaths.add(operation.path);
        case _QuickOperationType.insertLines:
          await load(operation.path, mustExist: true);
          working[operation.path] = _insertLines(
            working[operation.path]!,
            operation.startLine!,
            operation.content,
          );
        case _QuickOperationType.replaceLines:
          await load(operation.path, mustExist: true);
          working[operation.path] = _replaceLines(
            working[operation.path]!,
            operation.startLine!,
            operation.endLine!,
            operation.content,
          );
      }
    }
    return _QuickPreview([
      for (final entry in working.entries)
        _QuickPreviewFile(
          path: entry.key,
          original: originals[entry.key]!,
          current: entry.value,
          revision: revisions[entry.key]!,
          created: !available.contains(entry.key),
        ),
    ]);
  }

  Future<void> _serveEvents(HttpRequest request) async {
    final response = request.response;
    response.bufferOutput = false;
    response
      ..headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      )
      ..headers.set('Cache-Control', 'no-cache')
      ..headers.set('Connection', 'keep-alive')
      ..write('retry: 1500\n\n');
    await response.flush();
    final subscription = developerEventHub.events.listen((event) {
      response.write('event: ${event['type']}\n');
      response.write('data: ${jsonEncode(event)}\n\n');
      unawaited(response.flush());
    });
    final heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
      response.write(': heartbeat\n\n');
      unawaited(response.flush());
    });
    try {
      await response.done;
    } finally {
      heartbeat.cancel();
      await subscription.cancel();
    }
  }

  void _emitFileEvent({
    required String type,
    required String projectId,
    required String path,
    required int revision,
    required String? clientId,
    required List<Map<String, Object?>> operations,
  }) {
    developerEventHub.emit({
      'type': type,
      'projectId': projectId,
      'path': path,
      'revision': revision,
      'clientId': clientId ?? 'api',
      'operations': operations,
      'timestamp': DateTime.now().toUtc().millisecondsSinceEpoch,
    });
  }

  Map<String, Object?> _aiContext(HttpRequest request) {
    final origin = Uri(
      scheme: request.requestedUri.scheme,
      host: request.requestedUri.host,
      port: request.requestedUri.port,
    );
    String endpoint(String path) => origin
        .replace(path: path, queryParameters: {'token': token})
        .toString();
    return {
      'authentication': {
        'type': 'bearer',
        'token': token,
        'tokenHint': session.tokenHint,
        'authorizationHeader': 'Authorization: Bearer $token',
        'queryParameter': 'token=$token',
        'scope': 'current_developer_session',
      },
      'interfaces': {
        'openapi': endpoint('/dev/openapi.json'),
        'schemas': {
          'developerSession': endpoint('/dev/schemas/developer-session.json'),
          'projectValidation': endpoint('/dev/schemas/project-validation.json'),
          'gameManifest': endpoint('/dev/schemas/game-manifest.json'),
          'gameCapabilities': endpoint('/dev/schemas/game-capabilities.json'),
          'sdkTypes': endpoint('/dev/schemas/sdk-v1.json'),
        },
        'sdkManifest': endpoint('/dev/sdk-manifest.json'),
        'capabilityRegistry': endpoint('/dev/api/capabilities'),
        'capabilityTests': endpoint('/dev/api/capability-tests'),
        'docs': endpoint('/dev/docs'),
        'currentProjectChatPrompt': endpoint(
          '/dev/api/projects/{projectId}/chat-prompt.txt',
        ),
        'currentProjectAgentPrompt': endpoint(
          '/dev/api/projects/{projectId}/agent-prompt.txt',
        ),
        'aiPromptTemplates': endpoint('/dev/api/ai-prompt-templates'),
        'validationSchema': endpoint('/dev/schemas/project-validation.json'),
        'validationExample': endpoint('/dev/examples/validate-project.json'),
        'events': endpoint('/dev/api/events'),
        'recentLogs': endpoint('/dev/api/logs?limit=50'),
        'projects': endpoint('/dev/api/projects'),
        'defaultTemplate': endpoint(
          '/playmesh/developer/templates/default-game/template.json',
        ),
      },
      'operations': _interfaceCatalog
          .map(
            (operation) => {
              ...operation,
              'authentication': 'developer-token',
              'availableToAi': true,
            },
          )
          .toList(),
      'rules': {
        'workspaceIdentity': {
          'persistent': true,
          'fields': ['port', 'token', 'path'],
          'settingsPath': 'playmesh-library/developer/settings.json',
          'disabledBehavior': 'temporarily_unavailable',
        },
        'mainJsonMutable': true,
        'mainJsonWriteEndpoint': '/dev/api/projects/{projectId}/manifest',
        'mainJsonImmutableFields': ['id', 'author', 'lastModifiedAt'],
        'mainJsonRawFileWriteAllowed': false,
        'capabilitiesWriteEndpoint':
            '/dev/api/projects/{projectId}/capabilities',
        'supportsPreciseEdits': true,
        'fileDisplay': {
          'text': 'editable',
          'pngJpegGifWebpSvg': 'preview',
          'otherBinary': 'listed_without_preview',
        },
        'binaryWriteEncoding': 'base64',
        'directoryManagement': {
          'listField': 'directories',
          'createEndpoint':
              '/dev/api/projects/{projectId}/directory?path={path}',
          'deleteMethod': 'DELETE',
          'uploadVia': 'PUT file with encoding=base64',
          'maxFileBytes': 2097152,
        },
        'localHistory': {
          'mergeWindowSeconds':
              DeveloperLocalHistoryStore.mergeWindow.inSeconds,
          'maxOperations': 100,
          'storageModel': 'baseline_plus_post_change_snapshots',
          'storagePath': 'cache/developer/local-history/',
          'snapshotExcludes': ['data/', 'cache/'],
          'beforeVersion': 'previous_operation_snapshot_or_baseline',
          'versions': ['before', 'after'],
          'mainJsonRestorable': false,
        },
        'validation': {
          'endpoint': '/dev/api/projects/{projectId}/validate',
          'runRequiresValidProject': true,
          'diagnosticFields': [
            'severity',
            'code',
            'message',
            'path',
            'line',
            'column',
            'hint',
          ],
        },
        'quickOperationRoot': 'app/；capabilities.json 使用项目根路径',
        'quickOperations': [
          'create_file',
          'replace_file',
          'insert_lines',
          'replace_lines',
        ],
        'quickOperationSemantics': {
          'create_file': 'create only; missing parent directories are created',
          'replace_file':
              'upsert full text; missing file and parent directories are created',
          'insert_lines':
              'target must already exist or be created earlier in the same batch',
          'replace_lines':
              'target must already exist or be created earlier in the same batch',
        },
        'events': 'SSE',
        'runStatus': {
          'event': 'run.status',
          'phases': ['idle', 'starting', 'running', 'stopped', 'error'],
        },
        'runtimeLogs': {
          'event': 'runtime.log',
          'pollEndpoint': '/dev/api/logs?limit=50',
          'pollFilters': ['projectId', 'runId'],
          'pollMaxEntries': 50,
          'sources': ['app-webview', 'standalone-html-webview'],
          'eventIdentity': 'eventId',
          'scope': 'local-device',
          'capturedEvents': [
            'console',
            'uncaught.error',
            'unhandled.rejection',
            'resource.error',
          ],
          'appCacheEntries': DeveloperEventHub.maxRecentLogs,
          'forwardedOnlyWhileSseIsObserved': false,
          'nativeConsolePreserved': true,
        },
      },
    };
  }

  bool _authenticated(HttpRequest request) {
    final authorization = request.headers.value(
      HttpHeaders.authorizationHeader,
    );
    var candidate = authorization?.startsWith('Bearer ') == true
        ? authorization!.substring(7).trim()
        : request.uri.queryParameters['token']?.trim() ?? '';
    if (candidate.isEmpty) {
      for (final cookie in request.cookies) {
        if (cookie.name == 'playmesh_developer_token') {
          candidate = cookie.value;
          break;
        }
      }
    }
    return _constantTimeEquals(candidate, token);
  }

  @override
  Future<List<Uri>> workspaceLinks() async {
    final endpoints = await resolveLanEndpoints(server.port);
    final bases = endpoints.isEmpty
        ? [Uri(scheme: 'http', host: '127.0.0.1', port: server.port)]
        : endpoints;
    return bases
        .map(
          (base) => base.replace(
            path: session.workspacePath,
            queryParameters: {'token': token},
          ),
        )
        .toList(growable: false);
  }

  @override
  Future<void> close() async {
    await server.close(force: true);
    await capabilityTests.dispose();
  }
}

class _EmptyDeveloperProjectCatalog implements DeveloperProjectCatalog {
  const _EmptyDeveloperProjectCatalog();

  @override
  Future<List<DeveloperProject>> listProjects() async => const [];

  @override
  Future<DeveloperProject> createProject(DeveloperProjectDraft draft) async {
    throw StateError('开发者项目不可用');
  }

  @override
  Future<DeveloperProject> copyProject(
    String sourceProjectId, {
    required String id,
    required String name,
    required String author,
    required DateTime lastModifiedAt,
  }) async {
    throw StateError('开发者项目不可用');
  }

  @override
  Future<void> deleteProject(String projectId) async {
    throw StateError('开发者项目不可用');
  }

  @override
  Future<GameSummary> publishPackage(
    File source, {
    required String author,
    required DateTime lastModifiedAt,
  }) async {
    throw StateError('开发者项目不可用');
  }

  @override
  Future<List<String>> listFiles(String projectId) async => const [];

  @override
  Future<List<String>> listDirectories(String projectId) async => const [];

  @override
  Future<void> createDirectory(String projectId, String path) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<void> deleteDirectory(String projectId, String path) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<void> copyEntry(
    String projectId,
    String source,
    String destination,
  ) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<void> moveEntry(
    String projectId,
    String source,
    String destination,
  ) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<List<String>> extractZip(
    String projectId,
    String archivePath,
    String destinationDirectory,
  ) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<DeveloperProjectFile> readFile(String projectId, String path) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<DeveloperProjectFile> updateManifest(
    String projectId,
    Map<String, Object?> manifest, {
    int? expectedRevision,
  }) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<DeveloperProjectFile> writeFile(
    String projectId,
    String path,
    List<int> bytes, {
    int? expectedRevision,
  }) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<List<DeveloperProjectFile>> writeFilesAtomic(
    String projectId,
    Map<String, List<int>> files, {
    Map<String, int>? expectedRevisions,
  }) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<void> deleteFile(
    String projectId,
    String path, {
    int? expectedRevision,
  }) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<DeveloperFileDiff> diffFile(String projectId, String path) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<List<DeveloperLocalHistoryOperation>> listLocalHistory(
    String projectId,
    String path,
  ) async => const [];

  @override
  Future<DeveloperLocalHistoryDiff> localHistoryDiff(
    String projectId,
    String operationId,
    String path,
  ) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<void> restoreLocalHistory(
    String projectId,
    String operationId,
    String path,
    DeveloperHistoryVersion version,
  ) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<DeveloperProjectValidationReport> validateProject(
    String projectId,
  ) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<bool> clearGameData(String projectId) async {
    throw StateError('开发者项目不存在');
  }

  @override
  Future<GameSummary> prepareGame(String projectId) async {
    throw StateError('开发者项目不存在');
  }
}

Future<Map<String, Object?>> _jsonBody(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.length > 3 * 1024 * 1024) {
    throw const FormatException('请求内容超过 3 MiB');
  }
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('请求体必须是 JSON 对象');
  return Map<String, Object?>.from(decoded);
}

Future<Map<String, Object?>> _optionalJsonBody(HttpRequest request) async {
  final text = await utf8.decoder.bind(request).join();
  if (text.trim().isEmpty) return <String, Object?>{};
  final decoded = jsonDecode(text);
  if (decoded is! Map) throw const FormatException('请求体必须是 JSON 对象');
  return Map<String, Object?>.from(decoded);
}

Map<String, Object?> _fileJson(DeveloperProjectFile file) => {
  'path': file.path,
  'readOnly': file.readOnly,
  'revision': file.revision,
  'contentType': file.contentType,
};

enum _QuickOperationType { createFile, replaceFile, insertLines, replaceLines }

class _QuickOperation {
  const _QuickOperation({
    required this.type,
    required this.path,
    required this.content,
    this.startLine,
    this.endLine,
  });

  final _QuickOperationType type;
  final String path;
  final String content;
  final int? startLine;
  final int? endLine;
}

class _QuickPreviewFile {
  const _QuickPreviewFile({
    required this.path,
    required this.original,
    required this.current,
    required this.revision,
    required this.created,
  });

  final String path;
  final String original;
  final String current;
  final int revision;
  final bool created;

  Map<String, Object?> toJson() => {
    'path': path,
    'original': original,
    'current': current,
    'changed': original != current,
    'created': created,
    'revision': revision,
  };
}

class _QuickPreview {
  const _QuickPreview(this.files);

  final List<_QuickPreviewFile> files;

  Map<String, Object?> toJson() => {
    'files': files.map((file) => file.toJson()).toList(),
    'baseRevisions': {for (final file in files) file.path: file.revision},
  };
}

List<_QuickOperation> _parseQuickOperations(String source) {
  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  final operations = <_QuickOperation>[];
  var index = 0;
  while (index < lines.length) {
    if (lines[index].trim().isEmpty) {
      index += 1;
      continue;
    }
    final header = RegExp(
      r'^----(create_file|replace_file|insert_lines|replace_lines):(.+)$',
    ).firstMatch(lines[index]);
    if (header == null) {
      throw FormatException('第 ${index + 1} 行不是有效的快速操作头');
    }
    final command = header.group(1)!;
    final argument = header.group(2)!.trim();
    final contentLines = <String>[];
    index += 1;
    while (index < lines.length && lines[index] != '----end') {
      contentLines.add(lines[index]);
      index += 1;
    }
    if (index >= lines.length) throw FormatException('$command 缺少 ----end');
    index += 1;
    final content = contentLines.isEmpty ? '' : '${contentLines.join('\n')}\n';
    final parsed = _parseQuickArgument(command, argument);
    operations.add(
      _QuickOperation(
        type: parsed.type,
        path: parsed.path,
        content: content,
        startLine: parsed.startLine,
        endLine: parsed.endLine,
      ),
    );
  }
  if (operations.isEmpty) throw const FormatException('没有找到快速操作指令');
  return operations;
}

_QuickOperation _parseQuickArgument(String command, String argument) {
  _QuickOperationType type;
  int? startLine;
  int? endLine;
  var path = argument;
  if (command == 'insert_lines') {
    type = _QuickOperationType.insertLines;
    final match = RegExp(r'^(.*):(\d+)$').firstMatch(argument);
    if (match == null) throw const FormatException('insert_lines 行号无效');
    path = match.group(1)!;
    startLine = int.parse(match.group(2)!);
  } else if (command == 'replace_lines') {
    type = _QuickOperationType.replaceLines;
    final match = RegExp(r'^(.*):(\d+)-(\d+)$').firstMatch(argument);
    if (match == null) throw const FormatException('replace_lines 行号范围无效');
    path = match.group(1)!;
    startLine = int.parse(match.group(2)!);
    endLine = int.parse(match.group(3)!);
  } else {
    type = command == 'create_file'
        ? _QuickOperationType.createFile
        : _QuickOperationType.replaceFile;
  }
  final normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty ||
      normalized.startsWith('/') ||
      normalized
          .split('/')
          .any((segment) => segment.isEmpty || segment == '..')) {
    throw const FormatException('快速操作文件路径无效');
  }
  return _QuickOperation(
    type: type,
    path: normalized == 'capabilities.json' ? normalized : 'app/$normalized',
    content: '',
    startLine: startLine,
    endLine: endLine,
  );
}

String _insertLines(String source, int line, String content) {
  final lines = source.split('\n');
  final maxLine = lines.length;
  if (line < 1 || line > maxLine) {
    throw FormatException('插入行号超出范围：$line');
  }
  final offset = _lineOffset(source, line);
  return source.replaceRange(offset, offset, content);
}

String _replaceLines(String source, int start, int end, String content) {
  if (start < 1 || end < start) throw const FormatException('替换行号范围无效');
  final startOffset = _lineOffset(source, start);
  final endOffset = _lineOffset(source, end + 1, allowEnd: true);
  return source.replaceRange(startOffset, endOffset, content);
}

int _lineOffset(String source, int line, {bool allowEnd = false}) {
  if (line == 1) return 0;
  var current = 1;
  for (var index = 0; index < source.length; index += 1) {
    if (source.codeUnitAt(index) == 10) {
      current += 1;
      if (current == line) return index + 1;
    }
  }
  if (allowEnd && current + 1 == line) return source.length;
  throw FormatException('行号超出范围：$line');
}

List<Map<String, Object?>> _minimalOperations(String before, String after) {
  if (before == after) return const [];
  var prefix = 0;
  final shortest = min(before.length, after.length);
  while (prefix < shortest &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix += 1;
  }
  var beforeSuffix = before.length;
  var afterSuffix = after.length;
  while (beforeSuffix > prefix &&
      afterSuffix > prefix &&
      before.codeUnitAt(beforeSuffix - 1) ==
          after.codeUnitAt(afterSuffix - 1)) {
    beforeSuffix -= 1;
    afterSuffix -= 1;
  }
  return [
    {
      'start': prefix,
      'end': beforeSuffix,
      'text': after.substring(prefix, afterSuffix),
    },
  ];
}

String _qrSvg(String value) {
  final code = QrCode.fromData(
    data: value,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(code);
  const quiet = 4;
  final size = image.moduleCount + quiet * 2;
  final buffer = StringBuffer(
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 $size $size" '
    'shape-rendering="crispEdges"><rect width="100%" height="100%" fill="white"/>',
  );
  for (var row = 0; row < image.moduleCount; row += 1) {
    for (var column = 0; column < image.moduleCount; column += 1) {
      if (image.isDark(row, column)) {
        buffer.write(
          '<rect x="${column + quiet}" y="${row + quiet}" width="1" height="1" fill="#111"/>',
        );
      }
    }
  }
  return '${buffer.toString()}</svg>';
}

String _createToken(String? customToken) {
  final value = customToken?.trim() ?? '';
  if (value.isNotEmpty) {
    if (value.length < 8 || value.length > 128) {
      throw const FormatException('开发者 Token 长度必须为 8 到 128 个字符');
    }
    return value;
  }
  return base64Url.encode(_randomBytes(32)).replaceAll('=', '');
}

String _createPath(String? persistedPath) {
  final value = persistedPath?.trim() ?? '';
  if (value.isEmpty) return _randomHex(16);
  if (!RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(value)) {
    throw const FormatException('开发者工作区路径无效');
  }
  return value;
}

List<int> _randomBytes(int length) {
  final random = Random.secure();
  return List<int>.generate(length, (_) => random.nextInt(256));
}

String _randomHex(int length) => _randomBytes(
  length,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

bool _constantTimeEquals(String left, String right) {
  final a = utf8.encode(left);
  final b = utf8.encode(right);
  var difference = a.length ^ b.length;
  final length = max(a.length, b.length);
  for (var index = 0; index < length; index += 1) {
    difference |=
        (index < a.length ? a[index] : 0) ^ (index < b.length ? b[index] : 0);
  }
  return difference == 0;
}

String? _chatAiTextContent(DeveloperProjectFile file) {
  const additionalTextExtensions = {
    '.csv',
    '.frag',
    '.glsl',
    '.graphql',
    '.jsx',
    '.ts',
    '.tsx',
    '.vert',
    '.xml',
    '.yaml',
    '.yml',
  };
  final lowerPath = file.path.toLowerCase();
  final isKnownText =
      file.isText ||
      file.contentType.startsWith('image/svg+xml') ||
      additionalTextExtensions.any(lowerPath.endsWith);
  if (!isKnownText) return null;
  try {
    return utf8.decode(file.bytes);
  } on FormatException {
    return null;
  }
}

List<String> _stringValues(Object? value) {
  if (value is! List) return const [];
  return value
      .whereType<String>()
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

bool _isPromptRelevantPath(
  String path, {
  required bool includeAuthority,
  required bool includeController,
}) {
  if (!includeController &&
      (path == 'app/controller' || path.startsWith('app/controller/'))) {
    return false;
  }
  if (!includeAuthority &&
      (path == 'app/static/js/service' ||
          path.startsWith('app/static/js/service/'))) {
    return false;
  }
  return true;
}

String _publicContentType(String path) {
  if (path.endsWith('.d.ts')) return 'text/plain; charset=utf-8';
  if (path.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (path.endsWith('.css')) return 'text/css; charset=utf-8';
  if (path.endsWith('.json')) return 'application/json; charset=utf-8';
  if (path.endsWith('.html')) return 'text/html; charset=utf-8';
  if (path.endsWith('.md') || path.endsWith('.txt')) {
    return 'text/plain; charset=utf-8';
  }
  return 'application/octet-stream';
}

Future<void> _html(HttpResponse response, String body) =>
    _text(response, body, 'text/html; charset=utf-8');

Future<void> _text(
  HttpResponse response,
  String body,
  String contentType,
) async {
  response.headers.contentType = ContentType.parse(contentType);
  response.write(body);
  await response.close();
}

Future<void> _json(HttpResponse response, int status, Object body) async {
  response.statusCode = status;
  response.headers.contentType = ContentType.json;
  response.write(jsonEncode(body));
  await response.close();
}

Future<void> _error(
  HttpResponse response,
  int status,
  String requestId,
  String code,
  String message,
) {
  return _json(response, status, {
    'requestId': requestId,
    'error': {'code': code, 'message': message},
  });
}

const _docs = '''# Playmesh Developer Channel API

所有 `/dev/*` 请求必须携带当前开发者 Token，可使用 `Authorization: Bearer <token>` 或 `token` 查询参数。

Gateway 固定绑定 `0.0.0.0`，端口由设置页配置，默认 `16666`。端口、Token 和工作区路径持久化到 `playmesh-library/developer/settings.json`；关闭开发者模式或退出 App 只停止监听，重新开启后恢复同一工作区链接。工作区和 AI 客户端共用项目文件、修订号、本地历史与 SSE 事件流。`main.json` 原文禁止通过普通文件接口写入，但可通过“项目设置”或受校验的 manifest API 修改除稳定 `id` 外的字段。`capabilities.json` 通过专用能力接口按统一注册表修改；其他项目资源可保存、范围编辑、删除、查看 Diff 和按时间操作恢复。

- `GET /dev/api/status`（返回本机可用 `baseUrls`）
- `GET /dev/api/sdk`（返回统一生成的两套 JavaScript SDK 与 `.d.ts`）
- `GET /dev/api/run`（返回当前唯一运行项目）
- `POST /dev/api/packages/import`（整包导入或更新，仅替换发布文件并保留 data/cache）
- `GET /dev/api/projects`
- `POST /dev/api/projects`
- `POST /dev/api/projects/{projectId}/copy`（复制源码到新的项目 ID，不复制 data/cache/本地历史）
- `DELETE /dev/api/projects/{projectId}`（永久删除已停止的项目）
- `GET /dev/api/projects/{projectId}/files`
- `GET /dev/api/projects/{projectId}/package`（导出标准 Playmesh ZIP）
- `GET|PUT /dev/api/projects/{projectId}/manifest`（`id` 永久只读）
- `GET|PUT /dev/api/projects/{projectId}/capabilities`
- `GET /dev/api/capabilities`（全平台注册插件的版本、方法、事件和平台状态）
- `GET|POST /dev/api/capability-tests`（读取自检项；测试全部或指定能力并返回首个样本/错误）
- `GET /dev/api/projects/{projectId}/chat-prompt.txt`
- `GET /dev/api/projects/{projectId}/agent-prompt.txt?baseUrl={baseUrl}`（`baseUrl` 必须来自 status 枚举）
- `POST /dev/api/projects/{projectId}/directory?path=app/static/new-folder`
- `DELETE /dev/api/projects/{projectId}/directory?path=app/static/old-folder`
- `POST /dev/api/projects/{projectId}/file-operations`（复制、移动、解压 ZIP）
- `GET|PUT|PATCH|DELETE /dev/api/projects/{projectId}/file?path=app/index.html`
- `GET /dev/api/projects/{projectId}/local-history?path=app/static`
- `GET /dev/api/projects/{projectId}/local-history/diff?operationId=...&path=app/static`
- `POST /dev/api/projects/{projectId}/local-history/restore`
- `GET /dev/api/projects/{projectId}/asset?path=app/static/image/icon.png`
- `POST /dev/api/projects/{projectId}/quick-operations/preview`
- `POST /dev/api/projects/{projectId}/quick-operations/apply`
- `GET /dev/api/projects/{projectId}/diff?path=app/index.html`
- `GET /dev/api/projects/{projectId}/validate`
- `DELETE /dev/api/projects/{projectId}/data`（仅清理游戏 SDK 持久数据，保留 cache）
- `GET|POST /dev/api/projects/{projectId}/run`
- `POST /dev/api/projects/{projectId}/run/restart`
- `POST /dev/api/projects/{projectId}/run/stop`
- `GET /dev/api/logs?limit=50`
- `GET /dev/api/events`
- `GET /dev/api/ai-context`
- `GET /dev/api/ai-prompt-templates`
- `PUT|DELETE /dev/api/ai-prompt-templates/{templateId}`
- `GET /dev/schemas/project-validation.json`
- `GET /dev/schemas/game-manifest.json`
- `GET /dev/schemas/game-capabilities.json`
- `GET /dev/schemas/sdk-v1.json`
- `GET /dev/examples/validate-project.json`

快速操作支持 `create_file`、`replace_file`、`insert_lines` 和 `replace_lines`。普通路径相对于项目的 `app/`，固定路径 `capabilities.json` 指向项目根能力声明。`create_file` 只创建新文件，`replace_file` 为完整文本 upsert；二者都会递归创建缺失的父目录。行操作要求目标已存在或在同一批操作中先创建。必须先调用预览接口取得 `baseRevisions`，再确认应用；批量修改以同一事务提交。

平台能力 code、中文名、说明、apiVersion、方法、事件和平台状态以 `GET /dev/api/capabilities` 为唯一元数据来源。`GET /dev/api/capability-tests` 始终返回全平台注册表并调用插件自带自检，`POST` 的 `codes` 为空或省略时测试全部插件；不得按当前项目声明过滤测试页。游戏能力声明使用 `GET|PUT /dev/api/projects/{projectId}/capabilities`；AI 不得维护平行硬编码列表。声明非空时主 SDK 在 App 与浏览器每次进入游戏时弹出确认，拒绝则退出；不支持项只做标注，不阻塞用户同意后进入。

对话提示词只内嵌当前项目已勾选能力的完整插件声明，不包含未勾选能力。Agent 提示词不内嵌全量注册表，而是写入使用所选 Base URL 的 `GET /dev/api/capabilities`、`GET /dev/api/capability-tests` 和 `POST /dev/api/capability-tests`，由 Agent 按需读取实时契约与执行测试。工作区“复制全平台能力”独立调用注册表 API，与当前项目勾选无关。

工作区直接编辑 UTF-8 文本，并可预览 PNG、JPEG、GIF、WebP 和 SVG。其他二进制文件会显示在文件树中但不提供页面预览。`PUT file` 的 `encoding` 默认为 `utf8`；传 `base64` 时可以完整替换图片或其他二进制资源。`PATCH file` 只支持文本。

游戏与控制器继续使用原生 `console.log/info/warn/error/debug`。Console 由运行页面的宿主底层捕获，不经过 Game SDK 或游戏网关。App WebView 只把当前设备页面的输出写入本机 `runtime.log`，每条包含 `eventId`、`projectId` 和 `runId`；每次启动或刷新游戏前清空旧缓存，并在本次运行期间保留最近 500 条。`GET /dev/api/logs` 可用 `projectId/runId` 过滤，CLI 用它回放订阅前的早期日志并与 SSE 去重。普通浏览器在自身开发者工具查看本机 Console，日志不会跨设备转发，也不写磁盘。App WebView 入口缺少主 SDK 标签时，资源网关会自动补齐 App SDK 和 Game SDK；资源或脚本加载失败由宿主直接记录错误。

运行项目前会执行游戏包校验。校验报告包含稳定诊断码、严重级别、文件路径、行列和修复提示；存在 `error` 时运行接口返回 `422 package_validation_failed`。校验覆盖 main.json 语义、项目 ID、`entries.game`、`entries.controller`、`authority.entry`、icon 文件、发布包禁止文件，以及 HTML/CSS/JavaScript 的本地资源引用。页面入口未声明时分别使用 `app/index.html` 和 `app/controller/index.html`。

`sdk-manifest.json` 逐方法声明签名、可用角色、返回值、约束和错误；`sdk-v1.json` 提供 Player、SessionSnapshot、AuthorityContext、AuthorityResult、LifecycleEvent 和 SdkBootstrap 的正式 Schema。AI 必须根据正式契约和当前项目类型完成开发。
''';

Map<String, Object?> _openApi() => {
  'openapi': '3.1.0',
  'info': {'title': 'Playmesh Developer Channel', 'version': '1.7.0'},
  'paths': {
    '/dev/api/status': {'get': _operation('读取开发者通道状态')},
    '/dev/api/sdk': {'get': _operation('读取统一生成的 SDK 与类型声明')},
    '/dev/api/run': {'get': _operation('读取当前唯一运行项目')},
    '/dev/api/packages/import': {
      'post': _operation(
        '导入或更新标准 Playmesh 游戏包并保留 data/cache',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects': {
      'get': _operation('列出当前开发者项目'),
      'post': _operation(
        '从默认模板创建项目',
        permission: 'project.create',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}': {
      'delete': _operation(
        '永久删除已停止的项目、数据、缓存和本地历史',
        permission: 'project.delete',
        risk: 'high',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/copy': {
      'post': _operation(
        '复制项目源码并使用新的项目 ID',
        permission: 'project.create',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/capabilities': {'get': _operation('读取统一能力注册表')},
    '/dev/api/capability-tests': {
      'get': _operation('读取平台注册表驱动的能力自检清单'),
      'post': _operation(
        '测试全部或指定平台能力',
        permission: 'capability.test',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/manifest': {
      'get': _operation('读取 main.json 可视化编辑数据'),
      'put': _operation(
        '校验并保存 main.json（id 不可修改）',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/capabilities': {
      'get': _operation('读取能力声明'),
      'put': _operation(
        '创建、更新或删除能力声明',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/events': {'get': _operation('订阅项目实时事件')},
    '/dev/api/logs': {'get': _operation('读取最近 1 到 50 条运行日志')},
    '/dev/api/ai-context': {'get': _operation('读取 AI 接口与鉴权上下文')},
    '/dev/api/ai-prompt-templates': {'get': _operation('读取分组后的全局 AI 提示模板')},
    '/dev/api/ai-prompt-templates/{templateId}': {
      'put': _operation(
        '保存全局 AI 提示模板覆盖',
        permission: 'ai.prompt.configure',
        risk: 'medium',
        idempotent: false,
      ),
      'delete': _operation(
        '恢复全局 AI 提示模板默认值',
        permission: 'ai.prompt.configure',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/qr.svg': {'get': _operation('生成联机链接二维码')},
    '/dev/api/projects/{projectId}/files': {'get': _operation('列出项目文件与文件夹')},
    '/dev/api/projects/{projectId}/package': {
      'get': _operation('无语义校验拉取现有项目文件，用于损坏项目修复'),
    },
    '/dev/api/projects/{projectId}/chat-prompt.txt': {
      'get': _operation('按当前游戏类型导出对话 AI 提示词 TXT'),
    },
    '/dev/api/projects/{projectId}/agent-prompt.txt': {
      'get': _operation('导出包含开发接口与鉴权的 Agent 提示词 TXT'),
    },
    '/dev/api/projects/{projectId}/directory': {
      'post': _operation(
        '创建项目文件夹',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
      'delete': _operation(
        '递归删除项目文件夹',
        permission: 'project.write',
        risk: 'high',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/file-operations': {
      'post': _operation(
        '复制、移动或解压上传后的项目文件',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/local-history': {
      'get': _operation('按时间操作列出本地历史'),
    },
    '/dev/api/projects/{projectId}/local-history/diff': {
      'get': _operation('读取本地历史结构化差异'),
    },
    '/dev/api/projects/{projectId}/local-history/restore': {
      'post': _operation(
        '用历史快照全量替换文件夹或工作区',
        permission: 'project.write',
        risk: 'high',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/file': {
      'get': _operation('读取项目文本文件'),
      'put': _operation(
        '保存完整文件',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
      'patch': _operation(
        '按 UTF-16 偏移精确编辑文件',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
      'delete': _operation(
        '删除项目文件',
        permission: 'project.write',
        risk: 'high',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/asset': {'get': _operation('读取图片或二进制项目资源')},
    '/dev/api/projects/{projectId}/quick-operations/preview': {
      'post': _operation('预览快速操作 Diff'),
    },
    '/dev/api/projects/{projectId}/quick-operations/apply': {
      'post': _operation(
        '原子应用快速操作',
        permission: 'project.write',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/diff': {'get': _operation('读取文件 Diff')},
    '/dev/api/projects/{projectId}/validate': {
      'get': _operation('校验游戏包并返回结构化诊断'),
    },
    '/dev/api/projects/{projectId}/data': {
      'delete': _operation(
        '清理当前游戏的 SDK 持久数据，仅删除 data 目录并保留 cache',
        permission: 'project.data.clear',
        risk: 'high',
        idempotent: true,
      ),
    },
    '/dev/api/projects/{projectId}/run': {
      'get': _operation('读取运行状态'),
      'post': _operation(
        '请求 App 启动项目',
        permission: 'runtime.run',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/run/restart': {
      'post': _operation(
        '重新启动当前运行中的项目',
        permission: 'runtime.run',
        risk: 'medium',
        idempotent: false,
      ),
    },
    '/dev/api/projects/{projectId}/run/stop': {
      'post': _operation(
        '停止当前运行中的项目并关闭游戏会话',
        permission: 'runtime.run',
        risk: 'medium',
        idempotent: false,
      ),
    },
  },
  'components': {
    'securitySchemes': {
      'developerToken': {
        'type': 'http',
        'scheme': 'bearer',
        'description': '持久开发者工作区 token，与端口和工作区路径一起保存。',
      },
    },
  },
};

Map<String, Object?> _operation(
  String summary, {
  String permission = 'project.read',
  String risk = 'low',
  bool idempotent = true,
}) => {
  'summary': summary,
  'security': [
    {'developerToken': <Object>[]},
  ],
  'x-permission': permission,
  'x-risk': risk,
  'x-idempotent': idempotent,
  'x-retry': idempotent ? 'safe' : 'revision_guarded',
  'responses': {
    '200': {'description': '成功'},
    '401': {'description': 'Token 无效或开发者模式已关闭'},
  },
};

const _interfaceCatalog = [
  {'method': 'GET', 'path': '/dev/docs', 'permission': 'docs.read'},
  {'method': 'GET', 'path': '/dev/openapi.json', 'permission': 'docs.read'},
  {
    'method': 'GET',
    'path': '/dev/sdk-manifest.json',
    'permission': 'docs.read',
  },
  {
    'method': 'GET',
    'path': '/dev/schemas/developer-session.json',
    'permission': 'docs.read',
  },
  {
    'method': 'GET',
    'path': '/dev/schemas/project-validation.json',
    'permission': 'docs.read',
  },
  {
    'method': 'GET',
    'path': '/dev/schemas/game-manifest.json',
    'permission': 'docs.read',
  },
  {
    'method': 'GET',
    'path': '/dev/schemas/game-capabilities.json',
    'permission': 'docs.read',
  },
  {
    'method': 'GET',
    'path': '/dev/schemas/sdk-v1.json',
    'permission': 'docs.read',
  },
  {'method': 'GET', 'path': '/dev/api/status', 'permission': 'project.read'},
  {'method': 'GET', 'path': '/dev/api/sdk', 'permission': 'sdk.read'},
  {'method': 'GET', 'path': '/dev/api/run', 'permission': 'runtime.run'},
  {
    'method': 'POST',
    'path': '/dev/api/packages/import',
    'permission': 'project.write',
  },
  {'method': 'GET', 'path': '/dev/api/projects', 'permission': 'project.read'},
  {
    'method': 'GET',
    'path': '/dev/api/capabilities',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path': '/dev/api/capability-tests',
    'permission': 'project.read',
  },
  {
    'method': 'POST',
    'path': '/dev/api/capability-tests',
    'permission': 'capability.test',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects',
    'permission': 'project.create',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/copy',
    'permission': 'project.create',
  },
  {
    'method': 'DELETE',
    'path': '/dev/api/projects/{projectId}',
    'permission': 'project.delete',
  },
  {'method': 'GET', 'path': '/dev/api/events', 'permission': 'event.subscribe'},
  {'method': 'GET', 'path': '/dev/api/logs?limit=50', 'permission': 'log.read'},
  {'method': 'GET', 'path': '/dev/api/ai-context', 'permission': 'ai.context'},
  {
    'method': 'GET',
    'path': '/dev/api/ai-prompt-templates',
    'permission': 'ai.prompt.read',
  },
  {
    'method': 'PUT',
    'path': '/dev/api/ai-prompt-templates/{templateId}',
    'permission': 'ai.prompt.configure',
  },
  {
    'method': 'DELETE',
    'path': '/dev/api/ai-prompt-templates/{templateId}',
    'permission': 'ai.prompt.configure',
  },
  {
    'method': 'GET',
    'path': '/dev/api/qr.svg?value={url}',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/files',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/package',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/manifest',
    'permission': 'project.read',
  },
  {
    'method': 'PUT',
    'path': '/dev/api/projects/{projectId}/manifest',
    'permission': 'project.write',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/capabilities',
    'permission': 'project.read',
  },
  {
    'method': 'PUT',
    'path': '/dev/api/projects/{projectId}/capabilities',
    'permission': 'project.write',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/chat-prompt.txt',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/agent-prompt.txt?baseUrl={baseUrl}',
    'permission': 'project.read',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/directory?path={path}',
    'permission': 'project.write',
  },
  {
    'method': 'DELETE',
    'path': '/dev/api/projects/{projectId}/directory?path={path}',
    'permission': 'project.write',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/file-operations',
    'permission': 'project.write',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/local-history?path={path}',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path':
        '/dev/api/projects/{projectId}/local-history/diff?operationId={id}&path={path}',
    'permission': 'project.read',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/local-history/restore',
    'permission': 'project.write',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/file?path={path}',
    'permission': 'project.read',
  },
  {
    'method': 'PUT',
    'path': '/dev/api/projects/{projectId}/file?path={path}',
    'permission': 'project.write',
  },
  {
    'method': 'PATCH',
    'path': '/dev/api/projects/{projectId}/file?path={path}',
    'permission': 'project.write',
  },
  {
    'method': 'DELETE',
    'path': '/dev/api/projects/{projectId}/file?path={path}',
    'permission': 'project.write',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/asset?path={path}',
    'permission': 'project.read',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/quick-operations/preview',
    'permission': 'project.read',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/quick-operations/apply',
    'permission': 'project.write',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/diff?path={path}',
    'permission': 'project.read',
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/validate',
    'permission': 'project.read',
  },
  {
    'method': 'DELETE',
    'path': '/dev/api/projects/{projectId}/data',
    'permission': 'project.data.clear',
    'risk': 'high',
    'requiresConfirmation': true,
    'idempotent': true,
  },
  {
    'method': 'GET',
    'path': '/dev/api/projects/{projectId}/run',
    'permission': 'runtime.run',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/run',
    'permission': 'runtime.run',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/run/restart',
    'permission': 'runtime.run',
  },
  {
    'method': 'POST',
    'path': '/dev/api/projects/{projectId}/run/stop',
    'permission': 'runtime.run',
  },
];

const _sessionSchema = {
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  'title': 'DeveloperSession',
  'type': 'object',
  'required': ['enabled', 'port'],
  'properties': {
    'enabled': {'type': 'boolean'},
    'port': {'type': 'integer', 'minimum': 1, 'maximum': 65535},
    'path': {'type': 'string'},
    'tokenHint': {'type': 'string'},
    'workspacePath': {'type': 'string'},
    'createdAt': {'type': 'integer'},
  },
};

const _projectValidationSchema = {
  r'$schema': 'https://json-schema.org/draft/2020-12/schema',
  'title': 'DeveloperProjectValidationReport',
  'type': 'object',
  'required': [
    'projectId',
    'valid',
    'errorCount',
    'warningCount',
    'fileCount',
    'totalBytes',
    'diagnostics',
  ],
  'properties': {
    'projectId': {'type': 'string'},
    'valid': {'type': 'boolean'},
    'errorCount': {'type': 'integer', 'minimum': 0},
    'warningCount': {'type': 'integer', 'minimum': 0},
    'fileCount': {'type': 'integer', 'minimum': 0},
    'totalBytes': {'type': 'integer', 'minimum': 0},
    'diagnostics': {
      'type': 'array',
      'items': {
        'type': 'object',
        'required': ['code', 'severity', 'message', 'path'],
        'properties': {
          'code': {'type': 'string'},
          'severity': {
            'type': 'string',
            'enum': ['error', 'warning', 'info'],
          },
          'message': {'type': 'string'},
          'path': {'type': 'string'},
          'line': {'type': 'integer', 'minimum': 1},
          'column': {'type': 'integer', 'minimum': 1},
          'hint': {'type': 'string'},
        },
      },
    },
  },
};
