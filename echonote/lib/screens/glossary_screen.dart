import 'package:flutter/material.dart';

import '../models/glossary.dart';
import '../services/glossary_store.dart';
import '../services/whisper_prompt.dart';

/// The global glossary. Listed in prompt priority order, so the user sees
/// which terms make it into transcription.
class GlossaryScreen extends StatefulWidget {
  const GlossaryScreen({super.key, this.store});

  final GlossaryStore? store;

  @override
  State<GlossaryScreen> createState() => _GlossaryScreenState();
}

class _GlossaryScreenState extends State<GlossaryScreen> {
  late final GlossaryStore _store = widget.store ?? GlossaryStore();
  GlossaryLoadResult? _loaded;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await _store.load();
    if (mounted) setState(() => _loaded = loaded);
  }

  List<GlossaryTerm> get _terms => _loaded!.terms;

  Future<void> _save() async {
    setState(() {});
    await _store.save(_terms);
  }

  void _showSnack(String message, {SnackBarAction? action}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  Future<void> _add() async {
    final term = await _promptTerm(title: '新增詞條', others: _terms);
    if (term == null) return;
    final now = DateTime.now();
    _terms.add(GlossaryTerm(
      id: now.microsecondsSinceEpoch.toString(),
      term: term,
      createdAt: now,
      lastUsedAt: now,
    ));
    await _save();
  }

  Future<void> _edit(GlossaryTerm term) async {
    final edited = await _promptTerm(
      title: '編輯詞條',
      initial: term.term,
      others: _terms.where((t) => !identical(t, term)).toList(),
    );
    if (edited == null || edited == term.term) return;
    term
      ..term = edited
      ..lastUsedAt = DateTime.now();
    await _save();
  }

  Future<void> _togglePin(GlossaryTerm term) async {
    term.pinned = !term.pinned;
    await _save();
  }

  Future<void> _delete(GlossaryTerm term) async {
    final index = _terms.indexOf(term);
    _terms.removeAt(index);
    await _save();
    if (!mounted) return;
    _showSnack(
      '已刪除「${term.term}」',
      action: SnackBarAction(
        label: '復原',
        onPressed: () {
          _terms.insert(index.clamp(0, _terms.length), term);
          _save();
        },
      ),
    );
  }

  /// Returns the trimmed term, or null when cancelled. Validates against
  /// [others] before closing.
  Future<String?> _promptTerm({
    required String title,
    required List<GlossaryTerm> others,
    String? initial,
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) => _TermDialog(title: title, initial: initial, others: others),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _loaded;
    return Scaffold(
      appBar: AppBar(title: const Text('詞庫')),
      floatingActionButton: loaded == null || loaded.isCorrupt
          ? null
          : FloatingActionButton(onPressed: _add, tooltip: '新增詞條', child: const Icon(Icons.add)),
      body: switch (loaded) {
        null => const Center(child: CircularProgressIndicator()),
        GlossaryLoadResult(isCorrupt: true) => const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              '詞庫檔案已損毀，無法讀取。\n轉錄和分析會先在沒有詞庫的情況下進行；為了不讓資料永久遺失，這裡不會覆寫它。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
        _ => _buildList(),
      },
    );
  }

  Widget _buildList() {
    if (_terms.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '加入人名、公司名、產品名等專有名詞，轉錄和摘要會優先使用正確寫法。\n修改逐字稿時也可以直接把正確寫法加進來。',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final ordered = sortByPromptPriority(_terms);
    final inPrompt = selectPromptTerms(_terms);
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            '前 ${inPrompt.length} 個詞會送進語音轉錄（上限 $kGlossaryPromptMaxChars 字）。'
            '釘選的詞優先，其次是最近用過的。全部的詞都會用在摘要。',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final term in ordered)
          ListTile(
            leading: IconButton(
              icon: Icon(term.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              tooltip: term.pinned ? '取消釘選' : '釘選',
              onPressed: () => _togglePin(term),
            ),
            title: Text(term.term),
            subtitle: _subtitle(term, inTranscription: inPrompt.contains(term)),
            onTap: () => _edit(term),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '刪除',
              onPressed: () => _delete(term),
            ),
          ),
      ],
    );
  }

  Widget? _subtitle(GlossaryTerm term, {required bool inTranscription}) {
    final parts = [
      if (!inTranscription) '只用在摘要',
      if (term.source == GlossaryTermSource.learned) '從修改中學到',
      if (term.aliases.isNotEmpty) '常見誤寫：${term.aliases.join('、')}',
    ];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}

/// Owns its text controller, so the field outlives the closing animation.
class _TermDialog extends StatefulWidget {
  const _TermDialog({required this.title, required this.others, this.initial});

  final String title;
  final String? initial;
  final List<GlossaryTerm> others;

  @override
  State<_TermDialog> createState() => _TermDialogState();
}

class _TermDialogState extends State<_TermDialog> {
  late final _controller = TextEditingController(text: widget.initial);
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = validateNewTerm(_controller.text, widget.others);
    if (error != null) {
      setState(() => _error = error.message);
      return;
    }
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: '例如：台積電', errorText: _error),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: _submit, child: const Text('儲存')),
      ],
    );
  }
}
