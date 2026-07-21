class TranscriptSegment {
  TranscriptSegment({required this.startMs, required this.endMs, required this.text});

  final int startMs;
  final int endMs;
  final String text;

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) => TranscriptSegment(
        startMs: json['start_ms'] as int,
        endMs: json['end_ms'] as int,
        text: json['text'] as String,
      );

  Map<String, dynamic> toJson() => {'start_ms': startMs, 'end_ms': endMs, 'text': text};
}

class Todo {
  Todo({
    required this.task,
    this.owner,
    this.dueDate,
    this.sourceTimestampMs,
    this.done = false,
  });

  String task;
  String? owner;
  String? dueDate;
  int? sourceTimestampMs;
  bool done;

  factory Todo.fromJson(Map<String, dynamic> json) => Todo(
        task: json['task'] as String? ?? '',
        owner: json['owner'] as String?,
        dueDate: json['due_date'] as String?,
        sourceTimestampMs: json['source_timestamp_ms'] as int?,
        done: json['done'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'task': task,
        'owner': owner,
        'due_date': dueDate,
        'source_timestamp_ms': sourceTimestampMs,
        'done': done,
      };
}

class AgendaItem {
  AgendaItem({
    required this.topic,
    required this.discussion,
    required this.decisions,
    this.sourceTimestampMs,
  });

  final String topic;
  final String discussion;
  final List<String> decisions;
  final int? sourceTimestampMs;

  factory AgendaItem.fromJson(Map<String, dynamic> json) => AgendaItem(
        topic: json['topic'] as String? ?? '',
        discussion: json['discussion'] as String? ?? '',
        decisions: (json['decisions'] as List<dynamic>? ?? []).cast<String>(),
        sourceTimestampMs: json['source_timestamp_ms'] as int?,
      );

  Map<String, dynamic> toJson() => {
        'topic': topic,
        'discussion': discussion,
        'decisions': decisions,
        'source_timestamp_ms': sourceTimestampMs,
      };
}

class MeetingAnalysis {
  MeetingAnalysis({
    required this.overview,
    required this.keyPoints,
    required this.todos,
    required this.title,
    required this.attendees,
    required this.agendaItems,
  });

  final String overview;
  final List<String> keyPoints;
  final List<Todo> todos;
  String title;
  List<String> attendees;
  final List<AgendaItem> agendaItems;

  factory MeetingAnalysis.fromJson(Map<String, dynamic> json) {
    final summary = json['summary'] as Map<String, dynamic>? ?? {};
    final minutes = json['structured_minutes'] as Map<String, dynamic>? ?? {};
    return MeetingAnalysis(
      overview: summary['overview'] as String? ?? '',
      keyPoints: (summary['key_points'] as List<dynamic>? ?? []).cast<String>(),
      todos: (json['todos'] as List<dynamic>? ?? [])
          .map((t) => Todo.fromJson(t as Map<String, dynamic>))
          .toList(),
      title: minutes['title'] as String? ?? '',
      attendees: (minutes['attendees'] as List<dynamic>? ?? []).cast<String>(),
      agendaItems: (minutes['agenda_items'] as List<dynamic>? ?? [])
          .map((a) => AgendaItem.fromJson(a as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'summary': {'overview': overview, 'key_points': keyPoints},
        'todos': todos.map((t) => t.toJson()).toList(),
        'structured_minutes': {
          'title': title,
          'attendees': attendees,
          'agenda_items': agendaItems.map((a) => a.toJson()).toList(),
        },
      };
}

class Recording {
  Recording({
    required this.id,
    required this.audioName,
    required this.createdAt,
    required this.model,
    required this.elapsedSeconds,
    required this.audioFileName,
    required this.segments,
    this.analysis,
  });

  final String id;
  final String audioName;
  final DateTime createdAt;
  final String model;
  final int elapsedSeconds;

  /// Filename only (e.g. `1721...m4a`), relative to [RecordingStore]'s
  /// recordings directory. Never store an absolute path here — see
  /// [RecordingStore.resolveAudioPath] for why.
  final String audioFileName;
  final List<TranscriptSegment> segments;
  MeetingAnalysis? analysis;

  String get displayTitle =>
      (analysis?.title.isNotEmpty ?? false) ? analysis!.title : audioName;

  factory Recording.fromJson(Map<String, dynamic> json) => Recording(
        id: json['id'] as String,
        audioName: json['audio_name'] as String? ?? '未命名',
        createdAt: DateTime.parse(json['created_at'] as String),
        model: json['model'] as String? ?? '',
        elapsedSeconds: json['elapsed_seconds'] as int? ?? 0,
        audioFileName: json['audio_file_name'] as String,
        segments: (json['segments'] as List<dynamic>)
            .map((s) => TranscriptSegment.fromJson(s as Map<String, dynamic>))
            .toList(),
        analysis: json['analysis'] != null
            ? MeetingAnalysis.fromJson(json['analysis'] as Map<String, dynamic>)
            : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'audio_name': audioName,
        'created_at': createdAt.toIso8601String(),
        'model': model,
        'elapsed_seconds': elapsedSeconds,
        'audio_file_name': audioFileName,
        'segments': segments.map((s) => s.toJson()).toList(),
        'analysis': analysis?.toJson(),
      };
}
