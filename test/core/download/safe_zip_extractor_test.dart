import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/safe_zip_extractor_contract.dart';
import 'package:playmesh/core/download/safe_zip_extractor_io.dart';

void main() {
  test(
    'extracts direct-root files with bounded streaming and CRC validation',
    () async {
      final fixture = await _ZipFixture.create();
      addTearDown(fixture.close);
      await fixture.writeArchive({
        'index.html': utf8.encode('<html></html>'),
        'playmesh-integration.json': utf8.encode('{"schemaVersion":1}'),
        'assets/app.js': utf8.encode('console.log(1);'),
      });

      final result = await const IoSafeZipExtractor().extract(
        archivePath: fixture.archive.path,
        destinationPath: fixture.destination.path,
      );

      expect(result.fileCount, 3);
      expect(result.relativePaths, contains('assets/app.js'));
      expect(
        await File(
          '${fixture.destination.path}${Platform.pathSeparator}assets'
          '${Platform.pathSeparator}app.js',
        ).readAsString(),
        'console.log(1);',
      );
    },
  );

  test(
    'rejects traversal, absolute, backslash and unsafe Windows paths',
    () async {
      final cases = <String, Future<void> Function(_ZipFixture)>{
        'traversal': (fixture) => fixture.writeArchive({
          '../evil': [1],
        }),
        'absolute': (fixture) => fixture.writeArchive({
          '/evil': [1],
        }),
        'drive': (fixture) => fixture.writeArchive({
          'C:/evil': [1],
        }),
        'reserved': (fixture) => fixture.writeArchive({
          'assets/CON.txt': [1],
        }),
        'backslash': (fixture) async {
          await fixture.writeArchive({
            'aa/bb.txt': [1],
          });
          await fixture.replaceArchiveName('aa/bb.txt', 'aa\\bb.txt');
        },
      };
      for (final testCase in cases.entries) {
        final fixture = await _ZipFixture.create();
        addTearDown(fixture.close);
        await testCase.value(fixture);

        await expectLater(
          const IoSafeZipExtractor().extract(
            archivePath: fixture.archive.path,
            destinationPath: fixture.destination.path,
          ),
          throwsA(isA<SafeZipExtractionException>()),
          reason: testCase.key,
        );
      }
    },
  );

  test(
    'rejects symlinks, case duplicates and file-directory collisions',
    () async {
      final symlinkFixture = await _ZipFixture.create();
      addTearDown(symlinkFixture.close);
      final link = ArchiveFile('link', 7, utf8.encode('../evil'))
        ..isFile = false
        ..isSymbolicLink = true
        ..mode = 0xA000 | 0x1ff;
      await symlinkFixture.writeEntries([link]);
      await symlinkFixture.markCentralDirectoryAsUnix();
      await expectLater(
        const IoSafeZipExtractor().extract(
          archivePath: symlinkFixture.archive.path,
          destinationPath: symlinkFixture.destination.path,
        ),
        throwsA(
          isA<SafeZipExtractionException>().having(
            (error) => error.diagnostic,
            'diagnostic',
            'zip_symbolic_link',
          ),
        ),
      );

      for (final paths in const [
        ['index.html', 'Index.html'],
        ['assets', 'assets/app.js'],
      ]) {
        final fixture = await _ZipFixture.create();
        addTearDown(fixture.close);
        await fixture.writeArchive({
          for (final path in paths) path: [1],
        });
        await expectLater(
          const IoSafeZipExtractor().extract(
            archivePath: fixture.archive.path,
            destinationPath: fixture.destination.path,
          ),
          throwsA(isA<SafeZipExtractionException>()),
        );
      }
    },
  );

  test(
    'declared file count, single-file and expanded limits fail preflight',
    () async {
      final cases = [
        (
          policy: const SafeZipExtractionPolicy(maxFileCount: 1),
          files: <String, List<int>>{
            'a': [1],
            'b': [2],
          },
        ),
        (
          policy: const SafeZipExtractionPolicy(maxSingleFileBytes: 2),
          files: <String, List<int>>{
            'a': [1, 2, 3],
          },
        ),
        (
          policy: const SafeZipExtractionPolicy(maxExpandedBytes: 3),
          files: <String, List<int>>{
            'a': [1, 2],
            'b': [3, 4],
          },
        ),
      ];
      for (final testCase in cases) {
        final fixture = await _ZipFixture.create();
        addTearDown(fixture.close);
        await fixture.writeArchive(testCase.files);
        await expectLater(
          IoSafeZipExtractor(policy: testCase.policy).extract(
            archivePath: fixture.archive.path,
            destinationPath: fixture.destination.path,
          ),
          throwsA(isA<SafeZipExtractionException>()),
        );
      }
    },
  );

  test('non-empty extraction destination is rejected', () async {
    final fixture = await _ZipFixture.create();
    addTearDown(fixture.close);
    await fixture.writeArchive({
      'index.html': [1],
    });
    await fixture.destination.create();
    await File(
      '${fixture.destination.path}${Platform.pathSeparator}old.txt',
    ).writeAsString('old');

    await expectLater(
      const IoSafeZipExtractor().extract(
        archivePath: fixture.archive.path,
        destinationPath: fixture.destination.path,
      ),
      throwsA(
        isA<SafeZipExtractionException>().having(
          (error) => error.diagnostic,
          'diagnostic',
          'zip_destination_not_empty',
        ),
      ),
    );
  });
}

class _ZipFixture {
  _ZipFixture({
    required this.root,
    required this.archive,
    required this.destination,
  });

  final Directory root;
  final File archive;
  final Directory destination;

  static Future<_ZipFixture> create() async {
    final root = await Directory.systemTemp.createTemp('safe-zip-');
    return _ZipFixture(
      root: root,
      archive: File('${root.path}${Platform.pathSeparator}source.zip'),
      destination: Directory(
        '${root.path}${Platform.pathSeparator}destination',
      ),
    );
  }

  Future<void> writeArchive(Map<String, List<int>> files) => writeEntries(
    files.entries.map(
      (entry) => ArchiveFile(entry.key, entry.value.length, entry.value),
    ),
  );

  Future<void> writeEntries(Iterable<ArchiveFile> files) async {
    final value = Archive();
    for (final file in files) {
      value.addFile(file);
    }
    await archive.writeAsBytes(ZipEncoder().encode(value)!);
  }

  Future<void> replaceArchiveName(String before, String after) async {
    final bytes = await archive.readAsBytes();
    final source = utf8.encode(before);
    final replacement = utf8.encode(after);
    expect(replacement.length, source.length);
    var replacements = 0;
    for (var index = 0; index <= bytes.length - source.length; index += 1) {
      var matches = true;
      for (var offset = 0; offset < source.length; offset += 1) {
        if (bytes[index + offset] != source[offset]) {
          matches = false;
          break;
        }
      }
      if (!matches) continue;
      bytes.setRange(index, index + replacement.length, replacement);
      replacements += 1;
      index += source.length - 1;
    }
    expect(replacements, greaterThanOrEqualTo(2));
    await archive.writeAsBytes(bytes);
  }

  Future<void> markCentralDirectoryAsUnix() async {
    final bytes = await archive.readAsBytes();
    var headers = 0;
    for (var index = 0; index <= bytes.length - 6; index += 1) {
      if (bytes[index] == 0x50 &&
          bytes[index + 1] == 0x4b &&
          bytes[index + 2] == 0x01 &&
          bytes[index + 3] == 0x02) {
        bytes[index + 5] = 3;
        headers += 1;
      }
    }
    expect(headers, greaterThan(0));
    await archive.writeAsBytes(bytes);
  }

  Future<void> close() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}
