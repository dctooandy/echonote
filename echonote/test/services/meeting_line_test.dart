import 'package:echonote/models/recording.dart';
import 'package:echonote/services/meeting_line.dart';
import 'package:flutter_test/flutter_test.dart';

MeetingAnalysis _analysis({List<String> decisions = const [], List<Todo> todos = const []}) => MeetingAnalysis(
  overview: '摘要',
  keyPoints: const [],
  todos: todos,
  title: '週會',
  attendees: const [],
  agendaItems: [AgendaItem(topic: '議題', discussion: '討論', decisions: decisions)],
);

void main() {
  group('normalizeDue', () {
    test('one deadline written different ways reads the same', () {
      for (final due in ['本週三前', '週三前', '週三', '星期三', '禮拜三前', '周三前', '這週三']) {
        expect(normalizeDue(due), '週三前', reason: due);
      }
      for (final due in ['本週', '這週', '本週內', '這週內']) {
        expect(normalizeDue(due), '本週內', reason: due);
      }
    });

    test('no date, however it is written, is null', () {
      for (final due in [null, '', '  ', '未指定', '無', '待定']) {
        expect(normalizeDue(due), isNull, reason: due);
      }
    });

    test('other wording is kept', () {
      expect(normalizeDue('週五下午四點前'), '週五下午四點前');
      expect(normalizeDue('每週'), '每週');
    });
  });

  test('next week is later, but before next week is not', () {
    expect(isLaterDue('下週'), isTrue);
    expect(isLaterDue('隔週五'), isTrue);
    expect(isLaterDue('下個月'), isTrue);
    expect(isLaterDue('下週前'), isFalse);
    expect(isLaterDue('下週以前'), isFalse);
    expect(isLaterDue('週五前'), isFalse);
    expect(isLaterDue(null), isFalse);
  });

  test('the whole message, in format C', () {
    final body = lineMessageBody(
      _analysis(
        decisions: ['11 月 15 日上線', '主色用藍色', '11 月 15 日上線'],
        todos: [
          Todo(task: '申請網域', owner: 'Andy'),
          Todo(task: '找報價', owner: 'Andy', dueDate: '本週五前'),
          Todo(task: '提供推薦語', owner: '王經理', dueDate: '週五前'),
          Todo(task: '首頁文案', owner: 'Andy', dueDate: '週三'),
          Todo(task: '評估英文版', owner: 'Andy', dueDate: '下週'),
          Todo(task: '已經做完', owner: 'Andy', dueDate: '週三', done: true),
        ],
      ),
      myName: 'Andy',
    );
    expect(body, '''
【您已決定的事項】
1. 11 月 15 日上線
2. 主色用藍色

【本週要做的事】
週三前
・首頁文案
週五前
・找報價
・（麻煩您）提供推薦語
沒有期限
・申請網域

【之後】
下週
・評估英文版''');
  });

  test('without knowing who the user is, nothing says 麻煩您 and owners show', () {
    final body = lineMessageBody(_analysis(todos: [Todo(task: '報價', owner: '小明'), Todo(task: '文案')]));
    expect(body, contains('・報價（小明）'));
    expect(body, contains('・文案'));
    expect(body, isNot(contains('麻煩您')));
  });

  test('a todo with no owner counts as the user\'s', () {
    expect(lineMessageBody(_analysis(todos: [Todo(task: '文案')]), myName: 'Andy'), isNot(contains('麻煩您')));
  });

  test('empty sections are left out, and nothing at all is empty', () {
    expect(lineMessageBody(_analysis(decisions: ['決定'])), '【您已決定的事項】\n1. 決定');
    expect(lineMessageBody(_analysis()), '');
    expect(lineMessageBody(_analysis(todos: [Todo(task: '做完了', done: true)])), '');
  });

  test('the greeting goes only with a name', () {
    expect(lineMessage(' 陳醫師 ', '內容'), '陳醫師好，今天會議的結論整理如下：\n\n內容');
    expect(lineMessage('  ', '內容'), '內容');
  });
}
