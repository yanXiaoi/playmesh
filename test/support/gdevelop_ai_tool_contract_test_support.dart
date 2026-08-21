import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:playmesh/core/developer/gdevelop_ai_tool_registry.dart';

const gdevelopAiToolContractTestPath =
    'assets/playmesh-library/public/GDevelop/playmesh/runtime/ai/tools.json';

Map<String, Object?> loadGDevelopAiToolContractForTest() =>
    Map<String, Object?>.from(
      jsonDecode(File(gdevelopAiToolContractTestPath).readAsStringSync())
          as Map,
    );

GDevelopAiToolRegistry loadGDevelopAiToolRegistryForTest() {
  final contract = loadGDevelopAiToolContractForTest();
  return GDevelopAiToolRegistry.fromContract(
    contract,
    contractHash: sha256
        .convert(utf8.encode(jsonEncode(_canonicalizeContract(contract))))
        .toString(),
  );
}

Object? _canonicalizeContract(Object? value) {
  if (value is List) {
    return value.map(_canonicalizeContract).toList(growable: false);
  }
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalizeContract(value[key]),
    };
  }
  return value;
}
