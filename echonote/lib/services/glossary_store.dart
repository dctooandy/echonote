import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/glossary.dart';

class GlossaryCorruptException implements Exception {
  const GlossaryCorruptException();

  @override
  String toString() => '詞庫檔案已損毀，無法修改';
}

class GlossaryLoadResult {
  const GlossaryLoadResult(this.terms, {this.isCorrupt = false});

  final List<GlossaryTerm> terms;

  /// The file exists but couldn't be parsed. [terms] is empty; callers
  /// carry on without a glossary and must not overwrite the file.
  final bool isCorrupt;
}

/// The single, global glossary at `Documents/glossary.json`.
class GlossaryStore {
  GlossaryStore({Future<Directory> Function()? documentsDir})
    : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _documentsDir;

  Future<File> _file() async => File('${(await _documentsDir()).path}/glossary.json');

  Future<GlossaryLoadResult> load() async {
    final file = await _file();
    if (!await file.exists()) return const GlossaryLoadResult([]);
    try {
      final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final terms = (json['terms'] as List<dynamic>)
          .map((t) => GlossaryTerm.fromJson(t as Map<String, dynamic>))
          .toList();
      return GlossaryLoadResult(terms);
    } catch (_) {
      return const GlossaryLoadResult([], isCorrupt: true);
    }
  }

  Future<void> save(List<GlossaryTerm> terms) async {
    final file = await _file();
    await file.writeAsString(
      jsonEncode({'version': 1, 'terms': terms.map((t) => t.toJson()).toList()}),
    );
  }

  /// Adds [raw] (trimmed) as a manual term. Returns why it was rejected, or
  /// null on success. Throws [GlossaryCorruptException] rather than
  /// replacing a file it couldn't read.
  Future<GlossaryTermError?> add(String raw) async {
    final loaded = await load();
    if (loaded.isCorrupt) throw const GlossaryCorruptException();
    final error = validateNewTerm(raw, loaded.terms);
    if (error != null) return error;
    final now = DateTime.now();
    await save([
      ...loaded.terms,
      GlossaryTerm(id: now.microsecondsSinceEpoch.toString(), term: raw.trim(), createdAt: now),
    ]);
    return null;
  }
}
