import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:playmesh/core/profile/avatar_image.dart';

/// Exercises the same public HTTP contract through App and Runtime routes.
void registerBucketHttpRangeTests({
  required Future<Uri> Function(List<int>) upload,
  required Future<Uri> Function(Uint8List, String) uploadAvatar,
}) {
  final bytes = ascii.encode('0123456789');
  const huge = '9999999999999999999999999999999999999999';

  group('Bucket HTTP Range', () {
    for (final sample in [
      ('bytes=2-5', 2, 6),
      ('bytes=6-', 6, 10),
      ('bytes=-3', 7, 10),
      ('bytes=8-99', 8, 10),
      ('bytes=-99', 0, 10),
      ('bytes=0-0', 0, 1),
      ('BYTES=1-2', 1, 3),
      ('bytes=0002-0004', 2, 5),
      ('bytes=3-$huge', 3, 10),
      ('bytes=-$huge', 0, 10),
      ('bytes=100-200,2-3', 2, 4),
      ('bytes=1-4,3-6,7-8', 1, 9),
      ('bytes=, 2-3,', 2, 4),
    ]) {
      test('${sample.$1} returns only the requested bytes', () async {
        final uri = await upload(bytes);
        final full = await http.get(uri);
        final response = await http.get(uri, headers: {'Range': sample.$1});
        expect(response.statusCode, HttpStatus.partialContent);
        expect(response.bodyBytes, bytes.sublist(sample.$2, sample.$3));
        expect(response.headers['content-length'], '${sample.$3 - sample.$2}');
        expect(
          response.headers['content-range'],
          'bytes ${sample.$2}-${sample.$3 - 1}/10',
        );
        for (final header in [
          'content-type',
          'cache-control',
          'x-content-type-options',
          'last-modified',
        ]) {
          expect(
            response.headers[header],
            full.headers[header],
            reason: header,
          );
        }
        expect(response.headers['accept-ranges'], 'bytes');
      });
    }

    for (final range in [
      'bytes=10-',
      'bytes=100-200',
      'bytes=-0',
      'bytes=$huge-',
      'bytes=10-20,100-',
    ]) {
      test('$range returns 416 with the complete length', () async {
        final uri = await upload(bytes);
        final response = await http.get(uri, headers: {'Range': range});
        expect(response.statusCode, HttpStatus.requestedRangeNotSatisfiable);
        expect(response.headers['content-range'], 'bytes */10');
        expect(response.headers['content-length'], '0');
        expect(response.headers['accept-ranges'], 'bytes');
        expect(response.bodyBytes, isEmpty);
      });
    }

    test(
      'multiple non-adjacent ranges use a complete multipart body',
      () async {
        final uri = await upload(bytes);
        final response = await http.get(
          uri,
          headers: {'Range': 'bytes=8-9, 0-1, 100-200'},
        );
        expect(response.statusCode, HttpStatus.partialContent);
        expect(response.headers['content-range'], isNull);
        final type = ContentType.parse(response.headers['content-type']!);
        expect(type.mimeType, 'multipart/byteranges');
        final boundary = type.parameters['boundary'];
        expect(boundary, isNotNull);
        expect(
          response.body,
          '--$boundary\r\nContent-Type: video/mp4\r\n'
          'Content-Range: bytes 8-9/10\r\n\r\n89\r\n'
          '--$boundary\r\nContent-Type: video/mp4\r\n'
          'Content-Range: bytes 0-1/10\r\n\r\n01\r\n'
          '--$boundary--\r\n',
        );
        expect(
          int.parse(response.headers['content-length']!),
          response.bodyBytes.length,
        );
      },
    );

    test(
      'unknown, malformed and excessive ranges fall back to full 200',
      () async {
        final uri = await upload(bytes);
        for (final range in [
          'items=0-1',
          'bytes=',
          'bytes=-',
          'bytes=5-2',
          'bytes=oops',
          'bytes=+1-2',
          'bytes=1 -2',
          'bytes=0-1,oops',
          'bytes=1.5-2',
          'bytes=${List.filled(17, '0-0').join(',')}',
          'bytes=0-${List.filled(8200, '9').join()}',
        ]) {
          final response = await http.get(uri, headers: {'Range': range});
          expect(response.statusCode, HttpStatus.ok, reason: range);
          expect(response.bodyBytes, bytes);
          expect(response.headers['content-range'], isNull);
          expect(response.headers['content-length'], '10');
        }
      },
    );

    test(
      'HEAD ignores Range and returns full metadata without a body',
      () async {
        final uri = await upload(bytes);
        for (final range in ['bytes=2-4', 'bytes=999-', 'bytes=0-1,8-9']) {
          final response = await http.head(uri, headers: {'Range': range});
          expect(response.statusCode, HttpStatus.ok);
          expect(response.headers['content-length'], '10');
          expect(response.headers['accept-ranges'], 'bytes');
          expect(response.headers['content-range'], isNull);
          expect(response.bodyBytes, isEmpty);
        }
      },
    );

    test(
      'empty files ignore Range without inventing a negative byte offset',
      () async {
        final uri = await upload([]);
        for (final range in ['bytes=0-0', 'bytes=-1', 'bytes=0-']) {
          final response = await http.get(uri, headers: {'Range': range});
          expect(response.statusCode, HttpStatus.ok);
          expect(response.headers['content-length'], '0');
          expect(response.headers['content-range'], isNull);
          expect(response.bodyBytes, isEmpty);
        }
      },
    );

    test(
      'If-Range requires an exact immutable file modification date',
      () async {
        final uri = await upload(bytes);
        final metadata = await http.head(uri);
        final modified = metadata.headers['last-modified']!;
        final response = await http.get(
          uri,
          headers: {'Range': 'bytes=2-4', 'If-Range': modified},
        );
        expect(response.statusCode, HttpStatus.partialContent);
        expect(response.bodyBytes, bytes.sublist(2, 5));
        for (final validator in [
          HttpDate.format(
            HttpDate.parse(modified).subtract(const Duration(days: 1)),
          ),
          HttpDate.format(
            HttpDate.parse(modified).add(const Duration(days: 1)),
          ),
          'not-a-date',
          '"unknown"',
          'W/"unknown"',
        ]) {
          final fallback = await http.get(
            uri,
            headers: {'Range': 'bytes=100-', 'If-Range': validator},
          );
          expect(fallback.statusCode, HttpStatus.ok, reason: validator);
          expect(fallback.bodyBytes, bytes);
          expect(fallback.headers['content-range'], isNull);
        }
      },
    );

    test('avatar ETag conditions take precedence over Range', () async {
      final avatar = await AvatarImage.normalize(
        base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0l'
          'EQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
        ),
      );
      final uri = await uploadAvatar(avatar.pngBytes, avatar.sha256);
      final metadata = await http.head(uri);
      final etag = metadata.headers['etag']!;
      final partial = await http.get(
        uri,
        headers: {'Range': 'bytes=0-3', 'If-Range': etag},
      );
      expect(partial.statusCode, HttpStatus.partialContent);
      expect(partial.bodyBytes, avatar.pngBytes.sublist(0, 4));
      expect(partial.headers['etag'], etag);
      expect(partial.headers['cache-control'], 'private, no-cache');
      expect(partial.headers['content-type'], 'image/png');
      for (final validator in [
        'W/$etag',
        '"stale"',
        HttpDate.format(DateTime.now()),
      ]) {
        final full = await http.get(
          uri,
          headers: {'Range': 'bytes=0-3', 'If-Range': validator},
        );
        expect(full.statusCode, HttpStatus.ok);
        expect(full.bodyBytes, avatar.pngBytes);
      }
      final cached = await http.get(
        uri,
        headers: {'Range': 'bytes=999999-', 'If-None-Match': etag},
      );
      expect(cached.statusCode, HttpStatus.notModified);
      expect(cached.headers['content-range'], isNull);
      expect(cached.bodyBytes, isEmpty);
    });

    test('Range never bypasses missing or private file checks', () async {
      final uri = await upload(bytes);
      for (final path in [
        '/bucket/karaoke-media',
        '/bucket/karaoke-media/1000000000000.mp4',
        '/bucket/save/save.json',
        '/bucket/_sys-private/1000000000000.mp4',
      ]) {
        final response = await http.get(
          uri.resolve(path),
          headers: {'Range': 'bytes=0-1'},
        );
        expect(response.statusCode, HttpStatus.notFound, reason: path);
        expect(response.headers['content-range'], isNull);
      }
    });
  });
}
