part of '../../developer_web_gateway_io.dart';

class _LocalizationOperation implements _DeveloperHttpOperation {
  const _LocalizationOperation();

  @override
  List<DeveloperOperationDefinition> get definitions => const [
    DeveloperOperationDefinition(
      id: 'workspace.localization',
      method: 'GET',
      path: '/dev/api/localization',
      summary: '读取 App 当前语言、主题和统一 App 文案',
    ),
    DeveloperOperationDefinition(
      id: 'workspace.localization_update',
      method: 'PUT',
      path: '/dev/api/localization',
      summary: '通过 App 统一 UI 控制器切换语言或主题',
    ),
  ];

  @override
  Future<void> handle(
    _IoDeveloperWebGateway gateway,
    HttpRequest request,
    String requestId,
    DeveloperOperationDefinition definition,
    Map<String, String> pathParameters,
  ) async {
    final bridge = gateway.localizationBridge;
    if (bridge == null) {
      await _error(
        request.response,
        HttpStatus.serviceUnavailable,
        requestId,
        'localization_unavailable',
        'App 本地化桥接尚未就绪',
      );
      return;
    }
    final requestedLocale = request.uri.queryParameters['locale']?.trim() ?? '';
    final resolvesLocale =
        definition.id == 'workspace.localization' && requestedLocale.isNotEmpty;
    if (resolvesLocale &&
        (requestedLocale.length > 64 ||
            !RegExp(
              r'^[A-Za-z]{2,8}(?:[-_][A-Za-z0-9]{1,8})*$',
            ).hasMatch(requestedLocale))) {
      throw const FormatException('locale query 格式无效');
    }
    if (definition.id == 'workspace.localization_update') {
      final body = await _jsonBody(request);
      final updatesLocale = body.containsKey('localeId');
      final updatesTheme = body.containsKey('themeMode');
      if (!updatesLocale && !updatesTheme) {
        throw const FormatException('必须提供 localeId 或 themeMode');
      }
      String? localeId;
      if (updatesLocale) {
        final rawLocaleId = body['localeId'];
        if (rawLocaleId != null && rawLocaleId is! String) {
          throw const FormatException('localeId 必须是字符串或 null');
        }
        localeId = (rawLocaleId as String?)?.trim();
      }
      String? themeMode;
      if (updatesTheme) {
        final rawThemeMode = body['themeMode'];
        if (rawThemeMode is! String) {
          throw const FormatException('themeMode 必须是字符串');
        }
        themeMode = rawThemeMode.trim();
        if (!const {'system', 'light', 'dark'}.contains(themeMode)) {
          throw const FormatException('themeMode 必须是 system、light 或 dark');
        }
      }
      if (updatesLocale) {
        await bridge.useLocale(
          localeId == null || localeId.isEmpty ? null : localeId,
        );
      }
      if (updatesTheme) {
        await bridge.useTheme(themeMode!);
      }
    }
    final localization = resolvesLocale
        ? bridge.resolve(requestedLocale)
        : bridge.current();
    await _json(request.response, HttpStatus.ok, {
      'requestId': requestId,
      ...localization.toJson(),
      if (resolvesLocale)
        'messages': {
          for (final entry in localization.messages.entries)
            if (entry.key.startsWith('workspace.gdevelop_'))
              entry.key: entry.value,
        },
      if (resolvesLocale) 'resolvedLocale': localization.localeId,
    });
  }
}
