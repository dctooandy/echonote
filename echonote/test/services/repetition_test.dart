import 'dart:convert';
import 'dart:io';

import 'package:echonote/services/repetition.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The same file drives the C++ test of collapse_repetitions.h.
  final cases = (jsonDecode(File('test/fixtures/repetition_cases.json').readAsStringSync())
          as Map<String, dynamic>)['cases']
      as List<dynamic>;

  for (final c in cases.cast<Map<String, dynamic>>()) {
    test(c['name'], () {
      final result = collapseRepetitions(c['input'] as String);

      expect(result.text, c['output']);
      expect(result.collapsed, c['collapsed']);
    });
  }

  test('collapsing twice changes nothing more', () {
    for (final c in cases.cast<Map<String, dynamic>>()) {
      final once = collapseRepetitions(c['input'] as String).text;

      expect(collapseRepetitions(once).collapsed, 0, reason: c['name'] as String);
    }
  });
}
