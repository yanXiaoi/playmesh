import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:playmesh_file_system_access/webview_download_overlay.dart';

void main() {
  for (final size in [const Size(1100, 760), const Size(360, 700)]) {
    testWidgets('download overlay list and details at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final queue = WebViewDownloadQueue();
      addTearDown(queue.dispose);
      if (Platform.environment['PLAYMESH_DOWNLOAD_QA'] == '1') {
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
        final font = File('C:/Windows/Fonts/msyh.ttc');
        if (font.existsSync()) {
          final loader = FontLoader('DownloadQA')
            ..addFont(
              Future.value(ByteData.sublistView(font.readAsBytesSync())),
            );
          await loader.load();
        }
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: const ValueKey('download-qa'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            locale: const Locale('zh', 'CN'),
            supportedLocales: const [Locale('zh', 'CN')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(
              colorSchemeSeed: const Color(0xff297a74),
              fontFamily: 'DownloadQA',
            ),
            home: Scaffold(
              body: WebViewDownloadOverlay(
                queue: queue,
                child: const ColoredBox(color: Color(0xff172c34)),
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('webview-downloads-button')),
        findsNothing,
      );
      queue.add(
        WebViewDownloadTask(
            id: 'active',
            name: 'karaoke-session.mp4',
            source: 'https://media.example/song.mp4?token=private',
            totalBytes: 8 * 1024 * 1024,
          )
          ..receivedBytes = 2 * 1024 * 1024
          ..destination = 'D:/Downloads/karaoke-session.mp4'
          ..status = WebViewDownloadStatus.downloading,
      );
      queue.add(
        WebViewDownloadTask(
            id: 'done',
            name: 'game-recording.webm',
            totalBytes: 1024 * 1024,
          )
          ..receivedBytes = 1024 * 1024
          ..destination = 'D:/Downloads/game-recording.webm'
          ..status = WebViewDownloadStatus.completed,
      );
      await tester.pump();
      await _capture(
        tester,
        size.width > 600 ? 'download-entry-desktop' : 'download-entry-mobile',
      );
      await tester.tap(
        find.byKey(const ValueKey('webview-downloads-hide-button')),
      );
      await tester.pump();
      expect(find.byType(Dialog), findsNothing);
      expect(
        find.byKey(const ValueKey('webview-downloads-button')),
        findsNothing,
      );
      expect(queue.activeCount, 1);
      queue.changed();
      await tester.pump();
      expect(
        find.byKey(const ValueKey('webview-downloads-button')),
        findsNothing,
      );
      queue.add(WebViewDownloadTask(id: 'next', name: 'next-download.txt'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('webview-downloads-button')));
      await tester.pumpAndSettle();
      expect(find.text('karaoke-session.mp4'), findsOneWidget);
      expect(find.text('game-recording.webm'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        size.width > 600 ? 'downloads-desktop' : 'downloads-mobile',
      );
      await tester.tap(find.byKey(const ValueKey('download-task-active')));
      await tester.pumpAndSettle();
      expect(find.text('https://media.example/song.mp4'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
      expect(find.textContaining('25%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(
        tester,
        size.width > 600 ? 'download-detail-desktop' : 'download-detail-mobile',
      );
    });
  }
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (Platform.environment['PLAYMESH_DOWNLOAD_QA'] != '1') return;
  await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('download-qa')),
    );
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('outputs/download-qa/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}
