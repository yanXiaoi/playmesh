import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:playmesh/models/game_manifest.dart';

void main() {
  final fixture =
      jsonDecode(
            File(
              'test/fixtures/playmesh_game_manifest_parity.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final baseManifest = Map<String, Object?>.from(
    fixture['baseManifest']! as Map,
  );

  test('浏览器 builder golden 输出全部通过 Dart 权威 Manifest 解析', () {
    final cases = fixture['builderCases']! as List;
    for (final rawCase in cases) {
      final fixtureCase = Map<String, Object?>.from(rawCase as Map);
      final manifest = Map<String, Object?>.from(
        fixtureCase['manifest']! as Map,
      );
      expect(
        () => GameManifest.fromJson(manifest),
        returnsNormally,
        reason: fixtureCase['name']! as String,
      );
    }
  });

  test('浏览器 validator 与 Dart 权威 Manifest 保持 baseline 兼容语义', () {
    final cases = fixture['validationCases']! as List;
    for (final rawCase in cases) {
      final fixtureCase = Map<String, Object?>.from(rawCase as Map);
      final manifest = _deepClone(baseManifest);
      for (final entry in _map(fixtureCase['set']).entries) {
        manifest[entry.key] = _deepCloneValue(entry.value);
      }
      for (final entry in _map(fixtureCase['add']).entries) {
        manifest[entry.key] = _deepCloneValue(entry.value);
      }
      final repeat = fixtureCase['repeat'];
      if (repeat is Map) {
        final descriptor = Map<String, Object?>.from(repeat);
        _setPath(
          manifest,
          descriptor['path']! as String,
          List<String>.filled(
            descriptor['count']! as int,
            descriptor['character']! as String,
          ).join(),
        );
      }
      final valid = fixtureCase['valid']! as bool;
      final matcher = valid ? returnsNormally : throwsFormatException;
      expect(
        () => GameManifest.fromJson(manifest),
        matcher,
        reason: fixtureCase['name']! as String,
      );
    }
  });
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? Map<String, Object?>.from(value) : const <String, Object?>{};

Map<String, Object?> _deepClone(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

Object? _deepCloneValue(Object? value) => jsonDecode(jsonEncode(value));

void _setPath(Map<String, Object?> target, String path, Object? value) {
  final segments = path.split('.');
  Object? current = target;
  for (final segment in segments.take(segments.length - 1)) {
    current = current is List
        ? current[int.parse(segment)]
        : (current! as Map)[segment];
  }
  final last = segments.last;
  if (current is List) {
    current[int.parse(last)] = value;
  } else {
    (current! as Map)[last] = value;
  }
}
