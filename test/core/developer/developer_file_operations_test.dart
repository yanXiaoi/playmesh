import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/developer_project_catalog.dart';
import 'package:playmesh/core/game_package/game_library_repository.dart';

void main() {
  test('工作区支持复制、移动和解压上传后的 ZIP', () async {
    final root = await Directory.systemTemp.createTemp('playmesh-file-ops-');
    addTearDown(() => root.delete(recursive: true));
    final project = Directory(
      '${root.path}${Platform.pathSeparator}com.example.fileops',
    );
    await project.create(recursive: true);
    await File(
      '${project.path}${Platform.pathSeparator}main.json',
    ).writeAsString(_manifest);
    final source = File(
      '${project.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}source.txt',
    );
    await source.parent.create(recursive: true);
    await source.writeAsString('source');
    final archive = Archive();
    final html = utf8.encode('<!doctype html>');
    archive.addFile(ArchiveFile('site/index.html', html.length, html));
    await File(
      '${project.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}uploaded.zip',
    ).writeAsBytes(ZipEncoder().encode(archive)!);
    final catalog = GameLibraryDeveloperProjectCatalog(
      GameLibraryRepository(() async => const []),
      workspaceRoot: root,
    );

    await catalog.copyEntry(
      'com.example.fileops',
      'app/source.txt',
      'app/copied.txt',
    );
    await catalog.moveEntry(
      'com.example.fileops',
      'app/copied.txt',
      'app/moved.txt',
    );
    final extracted = await catalog.extractZip(
      'com.example.fileops',
      'app/uploaded.zip',
      'app/imported',
    );

    expect(
      await File(
        '${project.path}${Platform.pathSeparator}app${Platform.pathSeparator}moved.txt',
      ).readAsString(),
      'source',
    );
    expect(extracted, ['app/imported/site/index.html']);
    expect(
      await File(
        '${project.path}${Platform.pathSeparator}app'
        '${Platform.pathSeparator}imported${Platform.pathSeparator}site'
        '${Platform.pathSeparator}index.html',
      ).exists(),
      isTrue,
    );
    await expectLater(
      catalog.moveEntry('com.example.fileops', 'app', 'renamed-app'),
      throwsFormatException,
    );
    await File(
      '${project.path}${Platform.pathSeparator}app'
      '${Platform.pathSeparator}not-an-archive.txt',
    ).writeAsString('plain text');
    await expectLater(
      catalog.extractZip(
        'com.example.fileops',
        'app/not-an-archive.txt',
        'app/imported-text',
      ),
      throwsFormatException,
    );
  });
}

const _manifest = '''{
  "id": "com.example.fileops",
  "name": "File Operations",
  "author": "Test Author",
  "lastModifiedAt": 1784851200000,
  "version": "1.0.0",
  "sdkVersion": "4.1.0",
  "appSdkVersion": "3.3.0",
  "orientation": "portrait",
  "modes": ["solo"],
  "displayModes": ["multi_screen"],
  "players": {"min": 1, "max": 1},
  "entries": {"game": "index.html"}
}''';
