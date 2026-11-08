import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import 'common.dart';
import 'theme.dart';
import 'editor.dart';
import 'detail.dart';
import 'search.dart';
import 'settings.dart';
import 'recorder.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.book,
    this.models,
    this.shortcut,
    required this.themeMode,
    required this.onTheme,
  });
  final Notebook book;
  final LocalModels? models;
  final ValueNotifier<String?>? shortcut;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onTheme;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool favorites = false;
  bool capturing = false;
  @override
  void initState() {
    super.initState();
    widget.shortcut?.addListener(_shortcut);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _shortcut();
      if (widget.book.recoveredCount > 0) {
        notice(context, '已恢复 ${widget.book.recoveredCount} 段录音，请核对内容。');
      }
    });
  }

  @override
  void dispose() {
    widget.shortcut?.removeListener(_shortcut);
    super.dispose();
  }

  void _shortcut() {
    final action = widget.shortcut?.value;
    if (action == null || !mounted) {
      return;
    }
    widget.shortcut!.value = null;
    if (widget.book.captureActive) {
      notice(context, '正在录音，请先停止保存或丢弃。');
      return;
    }
    Navigator.of(context).popUntil((r) => r.isFirst);
    if (action == 'capture') {
      record();
    } else if (action == 'search') {
      find(voice: true);
    }
  }

  Future<void> record() async {
    if (capturing) {
      return;
    }
    capturing = true;
    try {
      final r = await openRecorder(context, widget.book, widget.models);
      if (mounted && r is Record) {
        notice(context, '音频已保存，转写稍后完成');
      }
    } finally {
      capturing = false;
    }
  }

  void find({bool voice = false}) {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            SearchPage(book: widget.book, models: widget.models, voice: voice),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    bottomNavigationBar: SafeArea(
      child: ReadingWidth(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: record,
                  icon: const Icon(Icons.mic_none_rounded),
                  label: const Text('记一下'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: find,
                  icon: const Icon(Icons.search_rounded),
                  label: const Text('找一下'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    body: SafeArea(
      child: ReadingWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const NoteMark(size: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '念下',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                  ),
                  IconButton(
                    tooltip: '设置',
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => SettingsPage(
                          book: widget.book,
                          models: widget.models,
                          themeMode: widget.themeMode,
                          onTheme: widget.onTheme,
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => setState(() => favorites = false),
                    child: Text(
                      '全部记录',
                      style: TextStyle(
                        fontWeight: favorites
                            ? FontWeight.normal
                            : FontWeight.w600,
                        color: favorites
                            ? Theme.of(context).colorScheme.onSurfaceVariant
                            : null,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => favorites = true),
                    child: Text(
                      '收藏',
                      style: TextStyle(
                        fontWeight: favorites
                            ? FontWeight.w600
                            : FontWeight.normal,
                        color: favorites
                            ? null
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => openEditor(context, widget.book),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('写文字'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: widget.book,
                builder: (context, _) {
                  final roots = widget.book.records
                      .where((r) => favorites ? r.favorite : r.parentId == null)
                      .toList();
                  if (roots.isEmpty) {
                    return EmptyState(
                      icon: favorites
                          ? Icons.star_border_rounded
                          : Icons.notes_rounded,
                      title: favorites ? '还没有收藏' : '想到什么，就记下来',
                      detail: favorites
                          ? '在记录详情中收藏重要想法。'
                          : '说一段话，或写几个字。\n内容保存在这台设备上。',
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                    itemCount: roots.length,
                    itemBuilder: (context, i) => RecordRow(
                      record: roots[i],
                      appendCount: widget.book.children(roots[i].id).length,
                      onTap: () => openDetail(
                        context,
                        widget.book,
                        roots[i].id,
                        models: widget.models,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class RecordRow extends StatelessWidget {
  const RecordRow({
    super.key,
    required this.record,
    required this.onTap,
    this.snippet,
    this.appendCount = 0,
  });
  final Record record;
  final VoidCallback onTap;
  final String? snippet;
  final int appendCount;
  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  snippet ?? (record.body.isEmpty ? '语音记录，等待转写' : record.body),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
              if (record.favorite)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.star_rounded, size: 18),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                recordDate(record),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (record.audio != null)
                Text(
                  '语音 ${durationText(record.durationMs)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (record.parentId != null)
                Text('追加内容', style: Theme.of(context).textTheme.bodySmall),
              if (appendCount > 0)
                Text(
                  '$appendCount 次追加',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(),
        ],
      ),
    ),
  );
}
