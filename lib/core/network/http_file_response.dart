import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Streams an authorized file after the caller has set its type/cache headers
/// and evaluated ordinary preconditions (e.g. If-None-Match).
///
/// Only immutable files can use their second-resolution modification date as
/// a strong If-Range validator. Mutable files must use their existing ETag.
Future<void> serveHttpFile(
  HttpRequest request,
  File file, {
  bool immutable = false,
}) async {
  final response = request.response;
  final stat = await file.stat();
  final length = stat.size;
  response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  DateTime? modified;
  if (immutable) {
    final now = DateTime.now().toUtc();
    final date = stat.modified.toUtc();
    modified = HttpDate.parse(HttpDate.format(date.isAfter(now) ? now : date));
    response.headers.set(
      HttpHeaders.lastModifiedHeader,
      HttpDate.format(modified),
    );
  }
  // RFC 9110: Range only applies to GET, never HEAD. An empty representation
  // may ignore Range, including a non-zero suffix request for an empty file.
  List<_ByteRange>? ranges;
  if (request.method == 'GET' && length > 0) {
    final values = request.headers[HttpHeaders.rangeHeader];
    if (values != null && _ifRangeMatches(request, modified)) {
      ranges = _parseRanges(values.join(','), length);
    }
  }
  if (ranges == null) {
    response.contentLength = length;
    if (request.method == 'HEAD' || length == 0) {
      await response.close();
    } else {
      await file.openRead(0, length).pipe(response);
    }
    return;
  }
  if (ranges.isEmpty) {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$length');
    response.contentLength = 0;
    await response.close();
    return;
  }
  response.statusCode = HttpStatus.partialContent;
  if (ranges.length == 1) {
    final range = ranges.single;
    response.headers.set(
      HttpHeaders.contentRangeHeader,
      range.contentRange(length),
    );
    response.contentLength = range.length;
    await file.openRead(range.start, range.end).pipe(response);
    return;
  }

  final random = Random.secure();
  final boundary =
      'playmesh_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  final type =
      response.headers.contentType?.toString() ?? 'application/octet-stream';
  final prefixes = [
    for (final range in ranges)
      utf8.encode(
        '--$boundary\r\nContent-Type: $type\r\n'
        'Content-Range: ${range.contentRange(length)}\r\n\r\n',
      ),
  ];
  final ending = ascii.encode('--$boundary--\r\n');
  response.headers.contentType = ContentType(
    'multipart',
    'byteranges',
    parameters: {'boundary': boundary},
  );
  response.contentLength =
      ending.length +
      List.generate(
        ranges.length,
        (index) => prefixes[index].length + ranges![index].length + 2,
      ).fold<int>(0, (a, b) => a + b);
  for (var index = 0; index < ranges.length; index++) {
    response.add(prefixes[index]);
    await response.addStream(
      file.openRead(ranges[index].start, ranges[index].end),
    );
    response.add(const [13, 10]);
  }
  response.add(ending);
  await response.close();
}

bool _ifRangeMatches(HttpRequest request, DateTime? modified) {
  final values = request.headers[HttpHeaders.ifRangeHeader];
  if (values == null) return true;
  if (values.length != 1) return false;
  final validator = values.single.trim();
  if (validator.startsWith('"') || validator.startsWith('W/')) {
    final etag = request.response.headers.value(HttpHeaders.etagHeader);
    return !validator.startsWith('W/') && validator == etag;
  }
  if (modified == null) return false;
  try {
    return HttpDate.parse(validator).isAtSameMomentAs(modified);
  } on HttpException {
    return false;
  }
}

// null means ignore Range and send 200; [] means valid but unsatisfiable (416).
// Bound parser work and multipart overhead. Coalesce overlaps/adjacency so a
// small header cannot make the server stream the same large file repeatedly.
List<_ByteRange>? _parseRanges(String header, int length) {
  if (header.length > 8192) return null;
  final separator = header.indexOf('=');
  if (separator < 0 ||
      header.substring(0, separator).toLowerCase() != 'bytes') {
    return null;
  }
  final parts = header.substring(separator + 1).split(',');
  if (parts.length > 16) return null;
  final limit = BigInt.from(length);
  final ranges = <_ByteRange>[];
  var count = 0;
  for (final part in parts) {
    final value = part.trim();
    if (value.isEmpty) continue; // Empty HTTP list elements are ignored.
    final match = RegExp(r'^(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) return null;
    count++;
    final first = match[1]!.isEmpty ? null : BigInt.parse(match[1]!);
    final last = match[2]!.isEmpty ? null : BigInt.parse(match[2]!);
    if (first == null) {
      if (last == BigInt.zero) continue;
      ranges.add(
        _ByteRange(last! >= limit ? 0 : length - last.toInt(), length, count),
      );
    } else {
      if (last != null && last < first) return null;
      if (first >= limit) continue;
      ranges.add(
        _ByteRange(
          first.toInt(),
          last == null || last >= limit ? length : last.toInt() + 1,
          count,
        ),
      );
    }
  }
  if (count == 0) return null;
  ranges.sort((a, b) => a.start.compareTo(b.start));
  final merged = <_ByteRange>[];
  for (final range in ranges) {
    if (merged.isNotEmpty && range.start <= merged.last.end) {
      final previous = merged.removeLast();
      merged.add(
        _ByteRange(
          previous.start,
          max(previous.end, range.end),
          min(previous.order, range.order),
        ),
      );
    } else {
      merged.add(range);
    }
  }
  // Retain the client's requested part order after coalescing overlaps.
  merged.sort((a, b) => a.order.compareTo(b.order));
  return merged;
}

class _ByteRange {
  const _ByteRange(this.start, this.end, this.order);
  final int start;
  final int end; // Exclusive, matching File.openRead.
  final int order;
  int get length => end - start;
  String contentRange(int length) => 'bytes $start-${end - 1}/$length';
}
