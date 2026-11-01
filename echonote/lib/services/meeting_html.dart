import '../models/recording.dart';
import '../utils/format.dart';

/// The exported minutes: one self-contained HTML file for people without
/// the app (spec feature-html-export). One fixed look (style B, cards like
/// the app), system fonts only and nothing loaded from the network, light
/// or dark following the reader's system, plain when printed.
///
/// Leaves out the user's own notes, the AI notes on them, the transcript
/// and timestamps: the reader has no recording, and notes are private.
String buildMeetingHtml(
  Recording recording, {
  Recording? previous,
  required DateTime exportedAt,
}) {
  final a = recording.analysis;
  if (a == null) {
    throw ArgumentError('recording ${recording.id} has no analysis');
  }
  final title = recording.displayTitle;

  final chips = [
    formatExportDate(recording.createdAt),
    if (recording.durationMs != null) formatLength(recording.durationMs!),
    if (a.attendees.isNotEmpty) '出席：${a.attendees.join('、')}',
  ];

  final body = StringBuffer()
    ..write('<header><h1>${_esc(title)}</h1><div class="chips">')
    ..writeAll(chips.map((c) => '<span class="chip">${_esc(c)}</span>'))
    ..write('</div></header>');

  if (a.overview.isNotEmpty || a.keyPoints.isNotEmpty) {
    body.write('<section class="card"><h2><span class="dot"></span>摘要</h2>');
    if (a.overview.isNotEmpty) body.write('<p>${_esc(a.overview)}</p>');
    if (a.keyPoints.isNotEmpty) body.write(_list(a.keyPoints));
    body.write('</section>');
  }

  final f = a.followUp;
  if (!f.isEmpty) {
    body.write(
      '<section class="card fu"><h2><span class="dot"></span>與上次相比</h2>',
    );
    if (previous != null) {
      body.write(
        '<div class="from">接續：${_esc(previous.displayTitle)}（${formatIsoDate(previous.createdAt)}）</div>',
      );
    }
    if (f.todoProgress.isNotEmpty) {
      body.write('<div class="sub">上次的待辦</div>');
      for (final p in f.todoProgress) {
        body.write(
          _statusRow(p.status.label, _todoTone[p.status]!, p.task, p.note),
        );
      }
    }
    if (f.decisionChanges.isNotEmpty) {
      body.write('<div class="sub">決議的變化</div>');
      for (final d in f.decisionChanges) {
        body.write(
          _statusRow(
            d.change.label,
            _changeTone[d.change]!,
            d.current,
            '上次：${d.previousDecision}',
          ),
        );
      }
    }
    if (f.newTopics.isNotEmpty) {
      body.write(
        '<div class="sub">新的主題</div><div>${f.newTopics.map(_esc).join('、')}</div>',
      );
    }
    body.write('</section>');
  }

  if (a.todos.isNotEmpty) {
    body.write('<section class="card"><h2><span class="dot"></span>待辦事項</h2>');
    for (final t in a.todos) {
      final meta = [
        ?t.owner,
        if (t.dueDate != null) '期限 ${t.dueDate}',
      ].join(' · ');
      body
        ..write(
          '<div class="todo"><span class="box">${t.done ? '☑' : '☐'}</span><div>',
        )
        ..write('<div class="t${t.done ? ' done' : ''}">${_esc(t.task)}</div>')
        ..write(meta.isEmpty ? '' : '<div class="m">${_esc(meta)}</div>')
        ..write('</div></div>');
    }
    body.write('</section>');
  }

  if (a.agendaItems.isNotEmpty) {
    body.write('<section class="card"><h2><span class="dot"></span>會議紀錄</h2>');
    for (final item in a.agendaItems) {
      body.write('<div class="agenda"><h3>${_esc(item.topic)}</h3>');
      if (item.discussion.isNotEmpty) {
        body.write('<div>${_esc(item.discussion)}</div>');
      }
      for (final d in item.decisions) {
        body.write('<div class="dec">決議：${_esc(d)}</div>');
      }
      body.write('</div>');
    }
    body.write('</section>');
  }

  body.write(
    '<footer>由 EchoNote 產生 · ${_esc(formatExportStamp(exportedAt))}<br>'
    '內容由 AI 根據錄音整理，請以實際討論為準</footer>',
  );

  return '<!DOCTYPE html>\n<html lang="zh-Hant">\n<head>\n<meta charset="utf-8">\n'
      '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
      '<title>${_esc(title)}</title>\n<style>$_css</style>\n</head>\n'
      '<body><main class="doc">$body</main></body>\n</html>\n';
}

/// The summary card's copy text: overview and key points, then what changed
/// since the previous meeting when there is a follow-up.
String summaryCopyText(MeetingAnalysis a) {
  final lines = [a.overview, ...a.keyPoints.map((p) => '• $p')];
  final f = a.followUp;
  if (!f.isEmpty) {
    lines
      ..add('')
      ..add('與上次相比');
    if (f.todoProgress.isNotEmpty) {
      lines
        ..add('上次的待辦：')
        ..addAll(f.todoProgress.map((p) => '• ${p.task}（${p.status.label}）'));
    }
    if (f.decisionChanges.isNotEmpty) {
      lines
        ..add('決議的變化：')
        ..addAll(
          f.decisionChanges.map(
            (d) => '• ${d.previousDecision} → ${d.current}（${d.change.label}）',
          ),
        );
    }
    if (f.newTopics.isNotEmpty) lines.add('新的主題：${f.newTopics.join('、')}');
  }
  return lines.join('\n');
}

/// `<title>_<YYYY-MM-DD>.html`, with characters file systems reject swapped
/// for `_` (same rule as the transcript export).
String meetingHtmlFileName(Recording recording) =>
    '${safeFileName(recording.displayTitle)}_${formatIsoDate(recording.createdAt)}.html';

String safeFileName(String name) =>
    name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

/// 2026-11-01（六）14:05
String formatExportDate(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
  return '${formatIsoDate(t)}（${weekdays[t.weekday - 1]}）${two(t.hour)}:${two(t.minute)}';
}

/// 2026-11-01 18:30
String formatExportStamp(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${formatIsoDate(t)} ${two(t.hour)}:${two(t.minute)}';
}

const _todoTone = {
  TodoProgressStatus.done: 'ok',
  TodoProgressStatus.inProgress: 'wa',
  TodoProgressStatus.notMentioned: 'mu',
};

const _changeTone = {
  DecisionChangeKind.continued: 'ok',
  DecisionChangeKind.revised: 'wa',
  DecisionChangeKind.reversed: 'no',
};

String _statusRow(String label, String tone, String title, String detail) =>
    '<div class="row"><span class="pill $tone">${_esc(label)}</span><div class="t">${_esc(title)}'
    '${detail.isEmpty ? '' : '<div class="m">${_esc(detail)}</div>'}</div></div>';

String _list(List<String> items) =>
    '<ul>${items.map((i) => '<li>${_esc(i)}</li>').join()}</ul>';

/// Every piece of text in the file comes from the user or the model.
String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

const _css = '''
:root{--bg:#F3F5F8;--card:#FFFFFF;--fg:#15191F;--mut:#5D6573;--ln:#E1E5EA;--ac:#0B7D8C;--acs:#D6F0F3;--ok:#2E7D5B;--oks:#DCEEE4;--wa:#9A5F00;--was:#FBEBD2;--no:#B3261E;--nos:#F9DEDC;color-scheme:light dark}
@media (prefers-color-scheme:dark){:root{--bg:#14171C;--card:#1D2129;--fg:#E8EBF0;--mut:#8D95A3;--ln:#2A2F39;--ac:#6FD3E0;--acs:#173A40;--ok:#6AD69A;--oks:#173325;--wa:#F2B84B;--was:#3A2F17;--no:#FF6B6B;--nos:#3D1C1E}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,BlinkMacSystemFont,"PingFang TC","Noto Sans TC","Microsoft JhengHei",sans-serif;-webkit-text-size-adjust:100%}
.doc{max-width:720px;margin:0 auto;padding:18px 12px 24px}
header{padding:6px 6px 14px}
h1{font-size:23px;margin:0 0 6px;line-height:1.35}
.chips{display:flex;flex-wrap:wrap;gap:6px}
.chip{background:var(--card);border:1px solid var(--ln);border-radius:999px;padding:2px 10px;font-size:12px;color:var(--mut)}
.card{background:var(--card);border:1px solid var(--ln);border-radius:16px;padding:14px 16px;margin-bottom:12px}
.card h2{font-size:17px;margin:0 0 8px;display:flex;align-items:center;gap:8px}
.dot{width:8px;height:8px;border-radius:50%;background:var(--ac)}
.fu{background:var(--acs);border-color:transparent}
p{margin:0 0 8px}
ul{margin:0;padding-left:18px}
li{margin:3px 0}
.sub{font-size:13px;font-weight:600;color:var(--mut);margin:10px 0 4px}
.from{font-size:13px;color:var(--mut);margin:-4px 0 8px}
.row{display:flex;gap:8px;align-items:flex-start;margin:6px 0}
.t{flex:1}
.m{font-size:13px;color:var(--mut)}
.pill{font-size:11px;font-weight:600;border-radius:999px;padding:1px 8px;white-space:nowrap;margin-top:2px}
.pill.ok{background:var(--oks);color:var(--ok)}.pill.wa{background:var(--was);color:var(--wa)}.pill.no{background:var(--nos);color:var(--no)}.pill.mu{background:var(--ln);color:var(--mut)}
.todo{display:flex;gap:10px;padding:8px 0;border-top:1px solid var(--ln)}
.todo:first-of-type{border-top:0}
.box{font-size:18px;line-height:1.3}
.todo .t{font-size:16px;font-weight:500}
.done{text-decoration:line-through;color:var(--mut)}
.agenda{border-top:1px solid var(--ln);padding:10px 0}
.agenda:first-of-type{border-top:0;padding-top:0}
.agenda h3{font-size:15px;margin:0 0 2px}
.dec{background:var(--acs);border-radius:8px;padding:4px 10px;margin-top:6px;font-size:14px}
footer{text-align:center;font-size:12px;color:var(--mut);margin-top:6px}
@media print{:root{--bg:#fff;--card:#fff;--fg:#000;--mut:#444;--ln:#ccc;--acs:#fff;--oks:#fff;--was:#fff;--nos:#fff;--ok:#000;--wa:#000;--no:#000;--ac:#000}.card{break-inside:avoid;border-color:#ccc}.pill{border:1px solid #999}.dec{border-left:3px solid #999;border-radius:0}}
''';
