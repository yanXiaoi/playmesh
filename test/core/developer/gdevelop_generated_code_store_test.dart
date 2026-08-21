import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/developer/gdevelop_generated_code_store.dart';

void main() {
  test('keeps generated code in bounded session memory', () {
    final store = GDevelopGeneratedCodeStore(
      maximumEntryBytes: 8,
      maximumTotalBytes: 8,
      maximumEntries: 2,
    );

    store.put('session-a.js', utf8.encode('1234'));
    store.put('session-b.js', utf8.encode('5678'));
    expect(utf8.decode(store.read('session-a.js')!), '1234');

    store.put('session-c.js', utf8.encode('90'));
    expect(store.read('session-a.js'), isNull);
    expect(store.length, 2);
    expect(store.totalBytes, 6);

    store.clear();
    expect(store.length, 0);
    expect(store.totalBytes, 0);
  });

  test('rejects unsafe keys and oversized generated code', () {
    final store = GDevelopGeneratedCodeStore(
      maximumEntryBytes: 4,
      maximumTotalBytes: 8,
    );
    expect(() => store.put('../escape.js', [1]), throwsFormatException);
    expect(
      () => store.put('safe.js', [1, 2, 3, 4, 5]),
      throwsA(isA<GDevelopGeneratedCodeTooLarge>()),
    );
  });
}
