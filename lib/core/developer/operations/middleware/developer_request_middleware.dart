part of '../../developer_web_gateway_io.dart';

typedef _DeveloperRequestNext = Future<void> Function();

abstract interface class _DeveloperRequestMiddleware {
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  );
}

class _DeveloperErrorMiddleware implements _DeveloperRequestMiddleware {
  const _DeveloperErrorMiddleware();

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  ) async {
    try {
      await next();
    } on DeveloperViewUnavailable catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'app_view_unavailable',
          'message': error.message,
          'details': {
            'requiresForegroundView': true,
            ...error.availability.toJson(),
          },
        },
      });
    } on DeveloperCapabilityUnavailable catch (error) {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        error.code,
        error.message,
      );
    } on PlatformException catch (error) {
      final nativeMessage = error.message?.trim();
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': error.code,
          'message': nativeMessage == null || nativeMessage.isEmpty
              ? error.toString()
              : nativeMessage,
          if (error.details != null) 'details': error.details,
        },
      });
    } on FormatException catch (error) {
      await _error(
        request.response,
        HttpStatus.badRequest,
        requestId,
        'invalid_request',
        error.message,
      );
    } on GDevelopAiProjectContextValidationException catch (error) {
      await _json(request.response, HttpStatus.badRequest, {
        'requestId': requestId,
        'error': {
          'code': error.code,
          'message': error.message,
          'reason': ?error.safeDiagnosticReason,
        },
      });
    } on GDevelopEventPayloadValidationException catch (error) {
      await _error(
        request.response,
        HttpStatus.badRequest,
        requestId,
        error.code,
        error.message,
      );
    } on GDevelopProjectRootConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': ProjectProvisioningConflict.code,
          'message': '项目 gameId 已存在或项目类型不匹配',
          'gameId': error.gameId,
        },
      });
    } on GDevelopProjectRootMissing catch (error) {
      await _json(request.response, HttpStatus.notFound, {
        'requestId': requestId,
        'error': {
          'code': ProjectProvisioningMissing.code,
          'message': 'GDevelop 项目根不存在',
          'gameId': error.gameId,
        },
      });
    } on GDevelopProjectConfigRevisionConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': GDevelopProjectConfigRevisionConflict.code,
          'message': 'GDevelop 项目配置已被其他客户端修改',
          'currentRevision': error.currentRevision,
        },
      });
    } on GDevelopProjectConfigInvalidState {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        GDevelopProjectConfigInvalidState.code,
        'GDevelop 项目配置损坏，拒绝覆盖未知状态',
      );
    } on PendingProjectCommitLocked catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_project_mutation_locked',
          'message': 'GDevelop 项目正被可恢复事务锁定',
          'activeTxId': error.activeTxId,
          'phase': error.phase.wireName,
        },
      });
    } on PendingProjectCommitIdempotencyConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_restore_idempotency_conflict',
          'message': '同一 idempotencyKey 已绑定不同恢复请求',
          'idempotencyKey': error.idempotencyKey,
        },
      });
    } on PendingProjectCommitNotFound catch (error) {
      await _json(request.response, HttpStatus.notFound, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_restore_transaction_not_found',
          'message': 'GDevelop 恢复事务不存在或 receipt 已过期',
          'txId': error.txId,
        },
      });
    } on PendingProjectCommitInvalidTransition catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_restore_invalid_transition',
          'message': 'GDevelop 恢复事务 phase 不允许该操作',
          'from': error.from.wireName,
          'to': error.to.wireName,
        },
      });
    } on PendingProjectCommitExpired catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_restore_transaction_expired',
          'message': 'GDevelop 恢复 PREPARED 事务已过期并放弃',
          'txId': error.txId,
        },
      });
    } on GDevelopRestoreTargetSnapshotMismatch {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        GDevelopRestoreTargetSnapshotMismatch.code,
        'GDevelop 恢复目标快照与冻结 evidence 不一致',
      );
    } on GDevelopRestoreAckMismatch {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        GDevelopRestoreAckMismatch.code,
        '浏览器持久化 evidence 与恢复 target 不匹配',
      );
    } on GDevelopRestoreTransactionUnavailable catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': GDevelopRestoreTransactionUnavailable.code,
          'message': '当前 GDevelop 恢复 phase 不允许该操作',
          'phase': error.phase.wireName,
        },
      });
    } on GDevelopProjectAllocationLocked catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_project_allocation_locked',
          'message': 'GDevelop 项目 gameId 正被 allocation 事务保留',
          'activeTxId': error.txId,
          'gameId': error.gameId,
          'phase': error.phase.wireName,
        },
      });
    } on GDevelopProjectAllocationEvidenceMismatch catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_allocation_evidence_mismatch',
          'message': 'GDevelop allocation workspace evidence 不匹配',
          // 仅返回受控的证据校验原因，不返回 hash、项目内容或 Token。
          'reason': error.code,
        },
      });
    } on GDevelopProjectAllocationResourceNotPlanned catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_allocation_resource_not_planned',
          'message': '资源尚未加入当前 allocation 事务计划',
          'contentHash': error.contentHash,
        },
      });
    } on GDevelopProjectAllocationUnavailable catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_allocation_unavailable',
          'message': '当前 allocation phase 不允许该操作',
          'phase': error.phase.wireName,
        },
      });
    } on GDevelopProjectAllocationIdempotencyConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_allocation_idempotency_conflict',
          'message': '同一 idempotencyKey 已绑定不同 allocation 请求',
          'idempotencyKey': error.idempotencyKey,
        },
      });
    } on GDevelopProjectAllocationNotFound catch (error) {
      await _json(request.response, HttpStatus.notFound, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_allocation_not_found',
          'message': 'GDevelop allocation 事务不存在或 receipt 已过期',
          'txId': error.txId,
        },
      });
    } on GDevelopProjectRekeyMutationLocked catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_project_mutation_locked',
          'message': 'GDevelop 项目正被 rekey 事务锁定',
          'activeTxId': error.txId,
          'phase': error.phase.wireName,
          'oldGameId': error.oldGameId,
          'newGameId': error.newGameId,
        },
      });
    } on GDevelopProjectRekeyOldChanged {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        'gdevelop_rekey_old_changed',
        'GDevelop rekey 来源 evidence 已变化',
      );
    } on GDevelopProjectRekeyAckMismatch {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        'gdevelop_rekey_ack_mismatch',
        '浏览器 rekey evidence 与冻结 target 不匹配',
      );
    } on GDevelopProjectRekeyTargetChanged {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        'gdevelop_rekey_target_changed',
        'GDevelop rekey 新项目根与冻结 target evidence 不一致',
      );
    } on GDevelopProjectRekeyUnavailable catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_rekey_transaction_unavailable',
          'message': '当前 rekey phase 不允许该操作',
          'phase': error.phase.wireName,
        },
      });
    } on GDevelopProjectRekeyIdempotencyConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_rekey_idempotency_conflict',
          'message': '同一 idempotencyKey 已绑定不同 rekey 请求',
          'idempotencyKey': error.idempotencyKey,
        },
      });
    } on GDevelopProjectRekeyNotFound catch (error) {
      await _json(request.response, HttpStatus.notFound, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_rekey_transaction_not_found',
          'message': 'GDevelop rekey 事务不存在或 receipt 已过期',
          'txId': error.txId,
        },
      });
    } on DeveloperPreviewNotFound {
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'preview_not_found',
        '当前项目没有活动的临时预览',
      );
    } on DeveloperPreviewGenerationConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'preview_generation_conflict',
          'message': '临时预览已被新 generation 取代',
          'currentPreviewId': error.currentPreviewId,
        },
      });
    } on DeveloperPreviewPackageInvalid catch (error) {
      await _error(
        request.response,
        HttpStatus.unprocessableEntity,
        requestId,
        'preview_package_invalid',
        error.message,
      );
    } on DeveloperPreviewPackageRequired catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'stage': error.stage,
        'operation': error.operation,
        'status': HttpStatus.conflict,
        'reason': DeveloperPreviewPackageRequired.code,
        'error': {
          'code': DeveloperPreviewPackageRequired.code,
          'message': '开发运行必须先上传并校验本次临时 app 包',
          'reason': DeveloperPreviewPackageRequired.code,
        },
      });
    } on GDevelopAiSessionNotFound {
      await _error(
        request.response,
        HttpStatus.notFound,
        requestId,
        'gdevelop_ai_session_not_found',
        'GDevelop AI 编辑器会话不存在或已经过期',
      );
    } on GDevelopAiCallConflict catch (error) {
      await _error(
        request.response,
        HttpStatus.conflict,
        requestId,
        error.code,
        error.message,
      );
    } on GDevelopAiExecutionOutputValidationException catch (error) {
      await _error(
        request.response,
        HttpStatus.badRequest,
        requestId,
        error.code,
        error.message,
      );
    } on GDevelopWebIdeInstallException catch (error) {
      final temporarilyUnavailable =
          error.diagnostic == 'gdevelop_install_io_unavailable' ||
          error.diagnostic == 'gdevelop_manager_closed' ||
          error.diagnostic == 'gdevelop_ai_tools_provider_unavailable';
      await _error(
        request.response,
        temporarilyUnavailable
            ? HttpStatus.serviceUnavailable
            : HttpStatus.conflict,
        requestId,
        error.diagnostic,
        temporarilyUnavailable
            ? 'The installed GDevelop WebIDE tool contract is temporarily unavailable.'
            : 'The installed GDevelop WebIDE tool contract is missing or failed identity validation. Reinstall or repair the WebIDE.',
      );
    } on GDevelopAiToolValidationException catch (error) {
      await _error(
        request.response,
        HttpStatus.badRequest,
        requestId,
        error.code,
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
    } on GDevelopHistoryRevisionConflict catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_revision_conflict',
          'message': 'GDevelop 工程历史已被其他客户端修改',
          'currentRevision': error.currentRevision,
        },
      });
    } on GDevelopHistoryRevisionNotFound catch (error) {
      await _json(request.response, HttpStatus.notFound, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_history_revision_not_found',
          'message': 'GDevelop 工程历史修订不存在',
          'revision': error.revision,
        },
      });
    } on LocalVersionObjectMissing catch (error) {
      await _json(request.response, HttpStatus.conflict, {
        'requestId': requestId,
        'error': {
          'code': 'gdevelop_resource_missing',
          'message': 'GDevelop 工程引用的资源尚未暂存或已经不可用',
          'contentHash': error.hash,
        },
      });
    } on LocalVersionQuotaExceeded catch (error) {
      await _json(request.response, 413, {
        'requestId': requestId,
        'error': {
          'code': 'history_quota_exceeded',
          'message': 'GDevelop 本地历史超过存储配额',
          'scope': error.scope,
          'limit': error.limit,
        },
      });
    } on _DeveloperRequestTooLarge catch (error) {
      await _json(request.response, 413, {
        'requestId': requestId,
        'error': {
          'code': 'request_too_large',
          'message': '请求内容超过允许上限',
          'limit': error.limit,
        },
      });
    } on TimeoutException {
      await _error(
        request.response,
        HttpStatus.requestTimeout,
        requestId,
        'upload_timeout',
        '上传等待数据超时',
      );
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
  }
}

class _DeveloperAuthenticationMiddleware
    implements _DeveloperRequestMiddleware {
  const _DeveloperAuthenticationMiddleware();

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext next,
  ) async {
    if (request.method == 'GET' &&
        request.uri.path.startsWith('/playmesh/developer/')) {
      await next();
      return;
    }
    final header = request.headers.value(HttpHeaders.authorizationHeader);
    final bearer = header != null && header.startsWith('Bearer ')
        ? header.substring(7)
        : '';
    final query = request.uri.queryParameters['token'] ?? '';
    final cookie = request.cookies
        .where((item) => item.name == 'playmesh_developer_token')
        .map((item) => item.value)
        .firstOrNull;
    if (header != null && header.trim().isNotEmpty) {
      // An explicit Authorization header is authoritative. Never fall back to
      // a cookie or bootstrap query when an invalid bearer was supplied.
      if (!_constantTimeEquals(bearer, gateway.token)) {
        await _error(
          request.response,
          HttpStatus.unauthorized,
          requestId,
          'unauthorized',
          '开发者会话 Token 无效',
        );
        return;
      }
      await next();
      return;
    } else if (_constantTimeEquals(query, gateway.token)) {
      final gdevelopPath = gateway.session.gdevelopWorkspacePath;
      final bootstrapRouteAllowed =
          request.method == 'GET' &&
          (request.uri.path == gateway.session.workspacePath ||
              (gdevelopPath != null &&
                  (request.uri.path == gdevelopPath ||
                      request.uri.path ==
                          gdevelopPath.substring(0, gdevelopPath.length - 1))));
      if (!bootstrapRouteAllowed) {
        await _error(
          request.response,
          HttpStatus.forbidden,
          requestId,
          'developer_bootstrap_forbidden',
          'URL bootstrap Token 只允许建立开发者工作区 Cookie',
        );
        return;
      }
      await next();
      return;
    } else if (_constantTimeEquals(cookie ?? '', gateway.token)) {
      await next();
      return;
    } else {
      await _error(
        request.response,
        HttpStatus.unauthorized,
        requestId,
        'unauthorized',
        '开发者会话 Token 无效',
      );
      return;
    }
  }
}

class _DeveloperRequestPipeline {
  const _DeveloperRequestPipeline(this.middleware);

  final List<_DeveloperRequestMiddleware> middleware;

  Future<void> run(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    _DeveloperRequestNext terminal,
  ) {
    Future<void> invoke(int index) {
      if (index == middleware.length) return terminal();
      return middleware[index].handle(
        gateway,
        request,
        requestId,
        () => invoke(index + 1),
      );
    }

    return invoke(0);
  }
}
