import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/core/download/app_resource_source_catalog.dart';

void main() {
  test('projects only the requested resource and preserves channel order', () {
    final catalog = AppResourceSourceCatalog.parse(
      jsonEncode([
        {
          'name': 'Gitee',
          'app': 'https://gitee.example/app.json',
          'gdevelop': 'https://gitee.example/gdevelop.json',
          'futureResource': {'schema': 1},
        },
        {'name': 'GitHub', 'app': 'https://github.example/app.json'},
        {'name': 'Mirror', 'gdevelop': 'https://mirror.example/gdevelop.json'},
      ]),
    );

    expect(catalog.endpointsFor('app').endpoints.map((item) => item.name), [
      'Gitee',
      'GitHub',
    ]);
    expect(
      catalog.endpointsFor('gdevelop').endpoints.map((item) => item.name),
      ['Gitee', 'Mirror'],
    );
  });

  test(
    'ignores unrelated channel contents and supports future resource keys',
    () {
      final catalog = AppResourceSourceCatalog.parse(
        jsonEncode([
          {
            'name': 'App',
            'app': 'https://app.example/update.json',
            'gdevelop': false,
          },
          42,
          {'name': 'Future', 'future': 'https://future.example/update.json'},
        ]),
      );

      expect(catalog.endpointsFor('app').endpoints.single.name, 'App');
      expect(catalog.endpointsFor('future').endpoints.single.name, 'Future');
      expect(catalog.endpointsFor('missing').endpoints, isEmpty);
    },
  );

  test('selected endpoints keep HTTP and unrestricted URI components', () {
    final catalog = AppResourceSourceCatalog.parse(
      jsonEncode([
        {
          'name': 'Channel',
          'app': 'https://safe.example/update.json',
          'gdevelop': 'http://user:pass@example.com/update.json#latest',
        },
      ]),
    );

    expect(catalog.endpointsFor('app').endpoints, hasLength(1));
    expect(
      catalog.endpointsFor('gdevelop').endpoints.single.url.toString(),
      'http://user:pass@example.com/update.json#latest',
    );
  });
}
