import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/foundation/gdevelop_project_mutation_lock.dart';

void main() {
  test('old/new 反向顺序使用同一确定性双锁且不会死锁', () async {
    const lock = GDevelopProjectMutationLock();
    final root = await Directory.systemTemp.createTemp('gdevelop-lock-');
    addTearDown(() => root.delete(recursive: true));
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var secondEntered = false;

    final first = lock.run(
      projectRoots: [Directory('${root.path}/a'), Directory('${root.path}/b')],
      action: () async {
        firstEntered.complete();
        await releaseFirst.future;
      },
    );
    await firstEntered.future;
    final second = lock.run(
      projectRoots: [Directory('${root.path}/b'), Directory('${root.path}/a')],
      action: () async => secondEntered = true,
    );
    await Future<void>.delayed(Duration.zero);
    expect(secondEntered, isFalse);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(secondEntered, isTrue);
  });

  test('互不相交的项目锁保持并行', () async {
    const lock = GDevelopProjectMutationLock();
    final root = await Directory.systemTemp.createTemp('gdevelop-lock-');
    addTearDown(() => root.delete(recursive: true));
    final enteredA = Completer<void>();
    final enteredB = Completer<void>();
    final release = Completer<void>();

    final first = lock.run(
      projectRoots: [Directory('${root.path}/a')],
      action: () async {
        enteredA.complete();
        await release.future;
      },
    );
    final second = lock.run(
      projectRoots: [Directory('${root.path}/b')],
      action: () async {
        enteredB.complete();
        await release.future;
      },
    );
    await Future.wait([enteredA.future, enteredB.future]);
    release.complete();
    await Future.wait([first, second]);
  });
}
