import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_project_validation.dart';

void main() {
  test('项目校验返回可定位的入口、资源和危险文件诊断', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-project-validation-',
    );
    addTearDown(() => workspace.delete(recursive: true));

    await _write(workspace, 'main.json', '''{
  "id": "com.example.validation",
  "name": "Validation",
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "controllerOrientation": "portrait",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": {"min": 2, "max": 4},
  "entries": {
    "game": "index.html",
    "controller": "controller/index.html"
  },
  "authority": {"entry": "static/js/service/index.js"},
  "tags": []
}''');
    await _write(workspace, 'app/index.html', '''<!doctype html>
<html>
<body><img src="/static/image/missing.png"></body>
</html>''');
    await _write(
      workspace,
      'app/static/js/service/index.js',
      'export function handleAction() {}\n',
    );
    await _write(workspace, 'app/static/tool.exe', 'not executable');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.validation',
      workspace: workspace,
    );

    expect(report.valid, isFalse);
    expect(
      report.diagnostics.map((diagnostic) => diagnostic.code),
      containsAll([
        'controller_entry_missing',
        'resource_missing',
        'forbidden_publish_file',
      ]),
    );
    final missingResource = report.diagnostics.singleWhere(
      (diagnostic) => diagnostic.code == 'resource_missing',
    );
    expect(missingResource.path, 'app/index.html');
    expect(missingResource.line, 3);
    expect(missingResource.column, isNotNull);
    expect(missingResource.messageArguments, {
      'reference': '/static/image/missing.png',
    });
    expect(missingResource.hintArguments, {
      'resolvedPath': 'app/static/image/missing.png',
    });
    expect(
      missingResource.toJson(),
      containsPair('message', missingResource.message),
    );
    expect(
      missingResource.toJson(),
      containsPair('messageArguments', missingResource.messageArguments),
    );
  });

  test('合法项目通过校验', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-valid-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));

    await _write(workspace, 'main.json', '''{
  "id": "com.example.valid",
  "name": "Valid",
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "displayModes": ["multi_screen"],
  "players": {"min": 2, "max": 4},
  "entries": {"game": "index.html?scene=main&player=1&player=2"},
  "authority": {"entry": "static/js/service/index.js"}
}''');
    await _write(
      workspace,
      'app/index.html',
      '<script type="module" src="/static/js/player/index.js"></script>'
          '<img src="/assets/playmesh/logo.png">',
    );
    await _write(
      workspace,
      'app/static/js/player/index.js',
      'import { handleAction } from "../service/index.js";\n',
    );
    await _write(
      workspace,
      'app/static/js/service/index.js',
      'export function handleAction() {}\n',
    );
    await _write(workspace, 'app/assets/playmesh/logo.png', 'png');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.valid',
      workspace: workspace,
    );

    expect(report.valid, isTrue);
    expect(report.errorCount, 0);
  });

  test('开发工作区允许用户 app 目录入口和嵌套同名资源', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-user-app-project-',
    );
    addTearDown(() => workspace.delete(recursive: true));

    await _write(workspace, 'main.json', '''{
  "id": "com.example.user-app",
  "name": "User App Directory",
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1},
  "entries": {"game": "app/index.html"}
}''');
    await _write(
      workspace,
      'app/app/index.html',
      '<script src="/app/playmesh/user.js"></script>',
    );
    await _write(
      workspace,
      'app/app/playmesh/user.js',
      'window.userAppRoute = true;',
    );

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.user-app',
      workspace: workspace,
    );

    expect(report.valid, isTrue, reason: '${report.diagnostics}');
    expect(report.errorCount, 0);
  });

  test('非联机项目不校验遗留的控制器和 Authority 文件', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-solo-stale-entries-',
    );
    addTearDown(() => workspace.delete(recursive: true));

    await _write(workspace, 'main.json', '''{
  "id": "com.example.solo-stale",
  "name": "Solo Stale Entries",
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1},
  "entries": {
    "game": "index.html",
    "controller": "missing/controller.html"
  },
  "authority": {"entry": "missing/authority.js"}
}''');
    await _write(workspace, 'app/index.html', '<!doctype html>');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.solo-stale',
      workspace: workspace,
    );

    expect(report.valid, isTrue, reason: '${report.diagnostics}');
    expect(
      report.diagnostics.map((item) => item.code),
      isNot(
        contains(anyOf('controller_entry_missing', 'authority_entry_missing')),
      ),
    );
  });

  test('自定义入口按 main.json 路径校验并报告缺失控制器', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-custom-entry-validation-',
    );
    addTearDown(() => workspace.delete(recursive: true));

    await _write(workspace, 'main.json', '''{
  "id": "com.example.custom-entry",
  "name": "Custom Entry",
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "controllerOrientation": "portrait",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": {"min": 2, "max": 4},
  "entries": {
    "game": "play/main.html?scene=lobby",
    "controller": "remote/pad.html?layout=compact"
  },
  "authority": {"entry": "service/authority.js"}
}''');
    await _write(workspace, 'app/play/main.html', '<!doctype html>');
    await _write(workspace, 'app/service/authority.js', 'export {};');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.custom-entry',
      workspace: workspace,
    );

    final diagnostic = report.diagnostics.singleWhere(
      (item) => item.code == 'controller_entry_missing',
    );
    expect(diagnostic.path, 'app/remote/pad.html');
    expect(diagnostic.messageArguments, {'path': 'app/remote/pad.html'});
    expect(diagnostic.hintArguments, {'path': 'app/remote/pad.html'});
    expect(
      report.diagnostics.map((item) => item.code),
      isNot(contains('app_entry_missing')),
    );
  });

  test('拒绝 app 下保留运行时目录并允许嵌套同名目录', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-reserved-path-validation-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    await _write(workspace, 'main.json', '''{
  "id": "com.example.reserved",
  "name": "Reserved",
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1},
  "entries": {"game": "index.html"}
}''');
    await _write(workspace, 'app/index.html', '<!doctype html>');
    await _write(workspace, 'app/PLAYMESH/sdk.js', 'export {};');
    await _write(workspace, 'app/assets/playmesh/game.js', 'export {};');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.reserved',
      workspace: workspace,
    );

    final reserved = report.diagnostics.where(
      (item) => item.code == 'reserved_runtime_namespace',
    );
    expect(reserved, hasLength(1));
    expect(reserved.single.path, 'app/PLAYMESH/sdk.js');
    expect(
      report.diagnostics.any(
        (item) => item.path == 'app/assets/playmesh/game.js',
      ),
      isFalse,
    );
  });

  test('缺少清单时只报告清单契约错误且仍执行安全检查', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-missing-manifest-validation-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    await _write(workspace, 'app/static/tool.exe', 'not executable');
    await _write(workspace, 'icon.png', 'not a png');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.missing-manifest',
      workspace: workspace,
    );
    final codes = report.diagnostics.map((item) => item.code);

    expect(codes, contains('manifest_missing'));
    expect(codes, contains('forbidden_publish_file'));
    expect(codes, contains('root_icon_invalid'));
    expect(codes, isNot(contains('app_entry_missing')));
  });

  test('无效清单不会派生默认 app/index.html 入口诊断', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'playmesh-invalid-manifest-validation-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    await _write(workspace, 'main.json', '''{
  "id": "com.example.invalid-manifest",
  "name": "Invalid",
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "landscape",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1},
  "entries": {}
}''');

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.invalid-manifest',
      workspace: workspace,
    );
    final codes = report.diagnostics.map((item) => item.code);

    expect(codes, contains('manifest_semantic_invalid'));
    expect(codes, isNot(contains('app_entry_missing')));
  });
}

Future<void> _write(Directory root, String path, String content) async {
  final file = File(
    '${root.path}${Platform.pathSeparator}'
    '${path.replaceAll('/', Platform.pathSeparator)}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}
