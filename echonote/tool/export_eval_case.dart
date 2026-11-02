// Turns one meeting from a downloaded app container into an eval-set case's
// request.json, built by the same code the app sends with (spec
// feature-analysis-eval-set, decision 2).
//
//   dart run tool/export_eval_case.dart \
//     --container <…/AppData/Documents or the .xcappdata> \
//     --meeting <id, title or recording name; a unique part is enough> \
//     --out <case folder> [--glossary]
//
// --glossary attaches the container's glossary; leave it off for cases that
// weren't recorded for it (the glossary is global).

import 'dart:convert';
import 'dart:io';

import 'package:echonote/models/glossary.dart';
import 'package:echonote/models/recording.dart';
import 'package:echonote/services/analysis_request.dart';
import 'package:echonote/services/meeting_chain.dart';

class ExportException implements Exception {
  ExportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The app's Documents folder inside [path]: [path] itself, or the
/// `AppData/Documents` of a downloaded `.xcappdata`.
Directory documentsIn(String path) {
  for (final candidate in [path, '$path/AppData/Documents']) {
    if (Directory('$candidate/history').existsSync()) return Directory(candidate);
  }
  throw ExportException('$path 裡找不到 history 資料夾');
}

List<Recording> loadRecordings(Directory documents) {
  final recordings = <Recording>[];
  for (final file in Directory('${documents.path}/history').listSync().whereType<File>()) {
    if (!file.path.endsWith('.json')) continue;
    try {
      recordings.add(Recording.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>));
    } catch (_) {
      // Same as the app: skip unreadable entries.
    }
  }
  return recordings..sort((a, b) => b.createdAt.compareTo(a.createdAt));
}

/// The one meeting whose id equals [query], or whose title or recording
/// name contains it.
Recording findMeeting(List<Recording> all, String query) {
  final byId = all.where((r) => r.id == query).toList();
  if (byId.isNotEmpty) return byId.single;
  final matches = all.where((r) => r.displayTitle.contains(query) || r.audioName.contains(query)).toList();
  if (matches.length == 1) return matches.single;
  if (matches.isEmpty) throw ExportException('找不到「$query」');
  throw ExportException(
    '「$query」對到 ${matches.length} 場，請改用 id：\n'
    '${matches.map((r) => '  ${r.id}  ${r.displayTitle}（${r.audioName}）').join('\n')}',
  );
}

List<String> loadGlossary(Directory documents) {
  final file = File('${documents.path}/glossary.json');
  if (!file.existsSync()) return [];
  final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  return [
    for (final t in json['terms'] as List<dynamic>) GlossaryTerm.fromJson(t as Map<String, dynamic>).term,
  ];
}

/// The user's name from the container's settings, as the app reads it.
String? loadMyName(Directory documents) {
  final file = File('${documents.path}/settings.json');
  if (!file.existsSync()) return null;
  final value = (jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)['my_name'];
  return value is String && value.trim().isNotEmpty ? value : null;
}

/// The request the app would send to analyze [meeting] now, with its
/// previous meetings frozen as they are in the container.
Map<String, dynamic> exportEvalCase(Directory documents, String meeting, {required bool withGlossary}) {
  final all = loadRecordings(documents);
  final recording = findMeeting(all, meeting);
  if (!recording.isTranscribed) throw ExportException('「${recording.displayTitle}」還沒轉錄');
  return buildAnalysisRequest(
    recording.segments,
    glossary: withGlossary ? loadGlossary(documents) : const [],
    notes: recording.notes,
    previous: previousChain(recording, all),
    myName: recording.iAttended ? loadMyName(documents) : null,
  ).request;
}

void main(List<String> args) {
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final container = option('--container');
  final meeting = option('--meeting');
  final out = option('--out');
  if (container == null || meeting == null || out == null) {
    stderr.writeln('用法：dart run tool/export_eval_case.dart --container <路徑> --meeting <名稱或 id> --out <案例資料夾> [--glossary]');
    exitCode = 64;
    return;
  }
  try {
    final request = exportEvalCase(documentsIn(container), meeting, withGlossary: args.contains('--glossary'));
    Directory(out).createSync(recursive: true);
    File('$out/request.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(request)}\n');
    final previous = (request['previous_meetings'] as List?)?.length ?? 0;
    stdout.writeln(
      '已寫入 $out/request.json：${(request['segments'] as List).length} 段逐字稿、'
      '${(request['glossary'] as List?)?.length ?? 0} 個詞庫詞、'
      '${(request['highlights'] as List?)?.length ?? 0} 則筆記、$previous 場前一場',
    );
  } on ExportException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  }
}
