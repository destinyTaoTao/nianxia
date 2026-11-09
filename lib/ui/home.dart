import 'dart:async';

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
  bool capturing = false;
  bool? speechReady;
  int modelCheck = 0;
  @override
  void initState() {
    super.initState();
    widget.shortcut?.addListener(_shortcut);
    widget.models?.store.addListener(modelChanged);
    unawaited(loadSpeechStatus());
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
    widget.models?.store.removeListener(modelChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.models?.store != widget.models?.store) {
      oldWidget.models?.store.removeListener(modelChanged);
      widget.models?.store.addListener(modelChanged);
      speechReady = null;
      unawaited(loadSpeechStatus());
    }
  }

  void modelChanged() {
    if (widget.models?.store.progress.containsKey('sensevoice') != true) {
      unawaited(loadSpeechStatus());
    }
  }

  Future<void> loadSpeechStatus() async {
    final version = ++modelCheck;
    final models = widget.models;
    if (models == null) return;
    bool ready;
    try {
      ready = await models.store.ready('sensevoice');
    } catch (_) {
      ready = false;
    }
    if (mounted && version == modelCheck) {
      setState(() => speechReady = ready);
    }
  }

  void _shortcut() {
    final action = widget.shortcut?.value;
    if ((action != 'capture' && action != 'search') || !mounted) {
      return;
    }
    widget.shortcut!.value = null;
    if (widget.book.captureActive) {
      notice(context, '正在录音，请先停止保存或丢弃。');
      return;
    }
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

  void library() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _RecordsPage(book: widget.book, models: widget.models),
      ),
    );
  }

  Future<void> settings({bool modelsFirst = false}) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          book: widget.book,
          models: widget.models,
          themeMode: widget.themeMode,
          onTheme: widget.onTheme,
          modelsFirst: modelsFirst,
        ),
      ),
    );
    await loadSpeechStatus();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ReadingWidth(
        child: ListenableBuilder(
          listenable: widget.book,
          builder: (context, _) {
            final recent = widget.book.records
                .where((r) => r.parentId == null)
                .take(3)
                .toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 28),
              children: [
                Row(
                  children: [
                    const NoteMark(size: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '念下',
                        style: Theme.of(context).textTheme.titleLarge
                            ?.copyWith(fontSize: 20),
                      ),
                    ),
                    IconButton(
                      tooltip: '设置',
                      onPressed: () => settings(),
                      icon: const Icon(Icons.settings_outlined),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                PaperSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '记下你的想法',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: record,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18,
                            vertical: 20,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: Theme.of(context).colorScheme.onPrimary
                                    .withValues(alpha: .12),
                              ),
                              child: const Icon(
                                Icons.mic_none_rounded,
                                size: 26,
                              ),
                            ),
                            const SizedBox(width: 18),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    '录音记一下',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '最长2分钟，停止后保存',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary
                                          .withValues(alpha: .78),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final secondaryStyle = OutlinedButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                            side: BorderSide.none,
                          );
                          final write = OutlinedButton.icon(
                            style: secondaryStyle,
                            onPressed: () => openEditor(context, widget.book),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            label: const Text('写文字'),
                          );
                          final search = OutlinedButton.icon(
                            style: secondaryStyle,
                            onPressed: find,
                            icon: const Icon(Icons.search_rounded, size: 20),
                            label: const Text('找一下'),
                          );
                          if (MediaQuery.textScalerOf(context).scale(16) > 22) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                write,
                                const SizedBox(height: 12),
                                search,
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: write),
                              const SizedBox(width: 12),
                              Expanded(child: search),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
                if (speechReady == false) ...[
                  const SizedBox(height: 14),
                  PaperSurface(
                    padding: EdgeInsets.zero,
                    child: InkWell(
                      onTap: () => settings(modelsFirst: true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.download_outlined,
                              size: 22,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '离线转写尚未就绪',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontSize: 14),
                                  ),
                                  Text(
                                    '录音照常保存',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '准备语音转写',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 8),
                            const Icon(Icons.chevron_right_rounded, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '最近记录',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    TextButton(onPressed: library, child: const Text('全部记录')),
                  ],
                ),
                PaperSurface(
                  padding: recent.isEmpty
                      ? const EdgeInsets.all(22)
                      : EdgeInsets.zero,
                  child: recent.isEmpty
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '还没有记录',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '点上方录音或写文字，记下第一条想法。',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        )
                      : Column(
                          children: [
                            for (var i = 0; i < recent.length; i++) ...[
                              if (i > 0)
                                const Divider(indent: 66, endIndent: 16),
                              RecordRow(
                                record: recent[i],
                                grouped: true,
                                appendCount: widget.book
                                    .children(recent[i].id)
                                    .length,
                                onTap: () => openDetail(
                                  context,
                                  widget.book,
                                  recent[i].id,
                                  models: widget.models,
                                ),
                              ),
                            ],
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

class _RecordsPage extends StatefulWidget {
  const _RecordsPage({required this.book, this.models});
  final Notebook book;
  final LocalModels? models;
  @override
  State<_RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<_RecordsPage> {
  bool favorites = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('记录')),
    body: ReadingWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('全部记录'),
                    selected: !favorites,
                    onSelected: (_) => setState(() => favorites = false),
                  ),
                  ChoiceChip(
                    label: const Text('收藏'),
                    selected: favorites,
                    onSelected: (_) => setState(() => favorites = true),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: widget.book,
              builder: (context, _) {
                final records = widget.book.records
                    .where((r) => favorites ? r.favorite : r.parentId == null)
                    .toList();
                if (records.isEmpty) {
                  return EmptyState(
                    icon: favorites
                        ? Icons.star_border_rounded
                        : Icons.notes_rounded,
                    title: favorites ? '还没有收藏' : '还没有记录',
                    detail: favorites ? '在记录详情中收藏重要想法。' : '返回首页，录音或写文字开始记录。',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  itemCount: records.length,
                  itemBuilder: (context, i) => RecordRow(
                    record: records[i],
                    appendCount: widget.book.children(records[i].id).length,
                    onTap: () => openDetail(
                      context,
                      widget.book,
                      records[i].id,
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
  );
}

class RecordRow extends StatelessWidget {
  const RecordRow({
    super.key,
    required this.record,
    required this.onTap,
    this.snippet,
    this.appendCount = 0,
    this.grouped = false,
  });
  final Record record;
  final VoidCallback onTap;
  final String? snippet;
  final int appendCount;
  final bool grouped;
  @override
  Widget build(BuildContext context) {
    final d = record.recordedLocal;
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final year = d.year == DateTime.now().year ? '' : '${d.year}年';
    final date = '$year${d.month}月${d.day}日 $time';
    final row = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    record.audio == null
                        ? Icons.notes_rounded
                        : Icons.mic_none_rounded,
                    size: 21,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              snippet ??
                                  (record.body.trim().isEmpty
                                      ? '$time 的录音'
                                      : record.body),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                          if (record.favorite)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Icons.star_rounded, size: 16),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        children: [
                          Text(
                            date,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (record.audio != null)
                            Text(
                              durationText(record.durationMs),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (record.transcription == 'pending' &&
                              record.body.trim().isEmpty)
                            Text(
                              '待转文字',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (record.parentId != null)
                            Text(
                              '追加内容',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          if (appendCount > 0)
                            Text(
                              '$appendCount 次追加',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (grouped) return row;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: row,
      ),
    );
  }
}
