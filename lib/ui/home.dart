import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  final FutureOr<bool> Function(ThemeMode) onTheme;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final scroll = ScrollController();
  bool capturing = false;
  bool themeBusy = false;
  bool favorites = false;
  bool? speechReady;
  int modelCheck = 0;
  List<RecordListEntry> entries = [];
  RecordCursor? next;
  int? generation;
  int request = 0;
  bool loading = true;
  Object? loadError;
  bool retryRefresh = false;

  void recordsChanged() => unawaited(loadRecords(reset: true));

  void scrolled() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < 600 &&
        !loading &&
        loadError == null &&
        next != null) {
      unawaited(loadRecords());
    }
  }

  Future<void> loadRecords({bool reset = false}) async {
    if (!reset && (loading || next == null)) return;
    final current = ++request;
    final wanted = reset
        ? (entries.length < 40 ? 40 : entries.length)
        : entries.length + 40;
    var refreshed = reset ? <RecordListEntry>[] : [...entries];
    var cursor = reset ? null : next;
    var pageGeneration = reset ? null : generation;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      do {
        final page = await widget.book.page(
          after: cursor,
          generation: pageGeneration,
          favorites: favorites,
        );
        if (!mounted || current != request) return;
        // A storage generation change starts a new window; never combine it
        // with entries read before the change.
        if (page.reset) refreshed = [];
        refreshed.addAll(page.entries);
        cursor = page.next;
        pageGeneration = page.generation;
      } while (refreshed.length < wanted && cursor != null);
      setState(() {
        entries = refreshed;
        next = cursor;
        generation = pageGeneration;
        loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && current == request) scrolled();
      });
    } catch (error) {
      if (!mounted || current != request) return;
      setState(() {
        loading = false;
        loadError = error;
        retryRefresh = reset;
      });
    }
  }

  void filterRecords(bool value) {
    if (favorites == value) return;
    setState(() {
      favorites = value;
      entries = [];
      next = null;
      generation = null;
    });
    unawaited(loadRecords(reset: true));
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  @override
  void initState() {
    super.initState();
    widget.book.contentChanges.addListener(recordsChanged);
    scroll.addListener(scrolled);
    unawaited(loadRecords(reset: true));
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
    widget.book.contentChanges.removeListener(recordsChanged);
    scroll.dispose();
    widget.shortcut?.removeListener(_shortcut);
    widget.models?.store.removeListener(modelChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book) {
      oldWidget.book.contentChanges.removeListener(recordsChanged);
      widget.book.contentChanges.addListener(recordsChanged);
      entries = [];
      next = null;
      generation = null;
      unawaited(loadRecords(reset: true));
    }
    if (oldWidget.shortcut != widget.shortcut) {
      oldWidget.shortcut?.removeListener(_shortcut);
      widget.shortcut?.addListener(_shortcut);
    }
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
      final r = await openRecorder(
        context,
        widget.book,
        widget.models,
        onSaved: showSavedRecord,
      );
      if (mounted && r is Record) {
        notice(context, '音频已保存，转写稍后完成');
      }
    } finally {
      capturing = false;
    }
  }

  void showSavedRecord() {
    if (!mounted) return;
    if (favorites) filterRecords(false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && scroll.hasClients) scroll.jumpTo(0);
    });
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

  Future<void> changeTheme(ThemeMode mode) async {
    if (themeBusy) return;
    setState(() => themeBusy = true);
    var saved = false;
    try {
      saved = await widget.onTheme(mode);
    } catch (_) {
      // Preserve the active theme when persistence fails.
    }
    if (!mounted) return;
    setState(() => themeBusy = false);
    if (!saved) notice(context, '主题设置未保存，请重试。');
  }

  Future<void> toggleFavorite(Record record) async {
    try {
      await widget.book.favorite(record.id, !record.favorite);
    } catch (e) {
      if (mounted) notice(context, userError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: theme.appBarTheme.systemOverlayStyle!,
      child: Scaffold(
        bottomNavigationBar: BottomActions(
          primary: FilledButton.icon(
            onPressed: record,
            icon: const Icon(Icons.mic_none_rounded),
            label: const Text('记一下'),
          ),
          secondary: FilledButton.tonalIcon(
            onPressed: () =>
                openEditor(context, widget.book, onSaved: showSavedRecord),
            icon: const Icon(Icons.edit_outlined),
            label: const Text('写文字'),
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: ColoredBox(
            color: colors.surfaceContainerLow,
            child: CustomScrollView(
              controller: scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: ColoredBox(
                    color: theme.scaffoldBackgroundColor,
                    child: ReadingWidth(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                const NoteMark(size: 26),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    '念下',
                                    style: theme.textTheme.titleLarge,
                                  ),
                                ),
                                IconButton(
                                  tooltip: theme.brightness == Brightness.dark
                                      ? '切换浅色主题'
                                      : '切换深色主题',
                                  onPressed: themeBusy
                                      ? null
                                      : () => changeTheme(
                                          theme.brightness == Brightness.dark
                                              ? ThemeMode.light
                                              : ThemeMode.dark,
                                        ),
                                  icon: Icon(
                                    theme.brightness == Brightness.dark
                                        ? Icons.light_mode_outlined
                                        : Icons.dark_mode_outlined,
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
                            Text(
                              '随手记，慢慢想。',
                              style: theme.textTheme.headlineMedium,
                            ),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: double.infinity,
                              child: Wrap(
                                alignment: WrapAlignment.spaceBetween,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                spacing: 12,
                                runSpacing: 8,
                                children: [
                                  Material(
                                    color: colors.surfaceContainerHighest,
                                    shape: const StadiumBorder(),
                                    child: Padding(
                                      padding: const EdgeInsets.all(3),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          for (final value in [false, true])
                                            Semantics(
                                              selected: favorites == value,
                                              child: TextButton(
                                                onPressed: () =>
                                                    filterRecords(value),
                                                style: TextButton.styleFrom(
                                                  minimumSize: const Size(
                                                    72,
                                                    48,
                                                  ),
                                                  backgroundColor:
                                                      favorites == value
                                                      ? colors
                                                            .surfaceContainerHigh
                                                      : Colors.transparent,
                                                  foregroundColor:
                                                      favorites == value
                                                      ? colors.onSurface
                                                      : colors.onSurfaceVariant,
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 18,
                                                        vertical: 12,
                                                      ),
                                                ),
                                                child: Text(
                                                  value ? '收藏' : '全部',
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    onPressed: find,
                                    icon: const Icon(Icons.search_rounded),
                                    label: const Text('找一下'),
                                  ),
                                ],
                              ),
                            ),
                            if (speechReady == false) ...[
                              const SizedBox(height: 14),
                              Material(
                                color: colors.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => settings(modelsFirst: true),
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.download_outlined,
                                          size: 22,
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '离线转写尚未就绪',
                                                style: theme
                                                    .textTheme
                                                    .titleMedium
                                                    ?.copyWith(fontSize: 14),
                                              ),
                                              Text(
                                                '录音照常保存',
                                                style:
                                                    theme.textTheme.bodySmall,
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '准备语音转写',
                                                style:
                                                    theme.textTheme.labelLarge,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        const Icon(
                                          Icons.chevron_right_rounded,
                                          size: 20,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (entries.isEmpty && loading)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (entries.isEmpty && loadError != null)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('记录未能加载，请重试。'),
                        TextButton(
                          onPressed: () => loadRecords(reset: true),
                          child: const Text('重试'),
                        ),
                      ],
                    ),
                  )
                else if (entries.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: EmptyState(
                      icon: favorites
                          ? Icons.bookmark_border_rounded
                          : Icons.notes_rounded,
                      title: favorites ? '还没有收藏' : '还没有记录',
                      detail: favorites
                          ? '点击便笺右下角，留下想重看的内容。'
                          : '点下方“记一下”或“写文字”，留下第一个想法。',
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 10),
                    sliver: SliverList.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, i) => ReadingWidth(
                        child: RecordRow(
                          record: entries[i].record,
                          appendCount: entries[i].appendCount,
                          onFavorite: () => toggleFavorite(entries[i].record),
                          onTap: () => openDetail(
                            context,
                            widget.book,
                            entries[i].record.id,
                            models: widget.models,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (entries.isNotEmpty &&
                    (loading || next != null || loadError != null))
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Center(
                        child: loading
                            ? const CircularProgressIndicator()
                            : TextButton(
                                onPressed: () => loadRecords(
                                  reset: loadError != null && retryRefresh,
                                ),
                                child: Text(
                                  loadError != null ? '加载失败，重试' : '加载更多',
                                ),
                              ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A note card shared by the library and source-backed search results.
class RecordRow extends StatelessWidget {
  const RecordRow({
    super.key,
    required this.record,
    required this.onTap,
    this.snippet,
    this.appendCount = 0,
    this.onFavorite,
  });
  final Record record;
  final VoidCallback onTap;
  final VoidCallback? onFavorite;
  final String? snippet;
  final int appendCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = record.recordedLocal;
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final year = d.year == DateTime.now().year ? '' : '${d.year}年';
    final title = record.body.trim().isEmpty ? '$time 的录音' : record.title;
    final remainder = record.body.trim().split('\n').skip(1).join('\n').trim();
    final useSnippet = snippet != null && snippet!.trim() != title;
    var preview = useSnippet ? snippet!.trim() : remainder;
    if (useSnippet && preview.startsWith('$title\n')) {
      preview = preview.substring(title.length).trimLeft();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Material(
        color: theme.colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(fontSize: 20),
                  ),
                ),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Text(
                      preview,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        height: 1.8,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            '$year${d.month}月${d.day}日 $time',
                            style: theme.textTheme.bodySmall,
                          ),
                          if (record.audio != null)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.play_arrow_rounded, size: 16),
                                const SizedBox(width: 3),
                                Text(
                                  durationText(record.durationMs),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            )
                          else
                            Text('文字', style: theme.textTheme.bodySmall),
                          if (record.body.trim().isEmpty &&
                              record.transcription == 'pending')
                            Text('待转文字', style: theme.textTheme.bodySmall),
                          if (record.parentId != null)
                            Text('追加内容', style: theme.textTheme.bodySmall),
                          if (appendCount > 0)
                            Text(
                              '$appendCount 次追加',
                              style: theme.textTheme.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    if (onFavorite != null)
                      IconButton(
                        tooltip: '${record.favorite ? '取消收藏' : '收藏'}：$title',
                        onPressed: onFavorite,
                        isSelected: record.favorite,
                        icon: const Icon(Icons.bookmark_border_rounded),
                        selectedIcon: const Icon(Icons.bookmark_rounded),
                      )
                    else if (record.favorite)
                      const Padding(
                        padding: EdgeInsets.all(12),
                        child: Icon(Icons.bookmark_rounded, size: 20),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
