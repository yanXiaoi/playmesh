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
  "sdkVersion": "1.0.0",
  "orientation": "landscape",
  "controllerOrientation": "portrait",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": {"min": 2, "max": 4},
  "authority": {"entry": "app/static/js/service/index.js"},
  "tags": []
}''');
    await _write(workspace, 'app/index.html', '''<!doctype html>
<html>
<body><img src="/app/static/image/missing.png"></body>
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
      'reference': '/app/static/image/missing.png',
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
  "sdkVersion": "1.0.0",
  "orientation": "landscape",
  "modes": ["multiplayer"],
  "displayModes": ["multi_screen"],
  "players": {"min": 2, "max": 4},
  "authority": {"entry": "app/static/js/service/index.js"}
}''');
    await _write(
      workspace,
      'app/index.html',
      '<script type="module" src="/app/static/js/player/index.js"></script>',
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

    final report = await const DeveloperProjectValidator().validate(
      projectId: 'com.example.valid',
      workspace: workspace,
    );

    expect(report.valid, isTrue);
    expect(report.errorCount, 0);
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
  "sdkVersion": "1.0.0",
  "orientation": "landscape",
  "controllerOrientation": "portrait",
  "modes": ["multiplayer"],
  "displayModes": ["single_screen_multiplayer"],
  "players": {"min": 2, "max": 4},
  "entries": {
    "game": "app/play/main.html",
    "controller": "app/remote/pad.html"
  },
  "authority": {"entry": "app/service/authority.js"}
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
}

Future<void> _write(Directory root, String path, String content) async {
  final file = File(
    '${root.path}${Platform.pathSeparator}'
    '${path.replaceAll('/', Platform.pathSeparator)}',
  );
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}
