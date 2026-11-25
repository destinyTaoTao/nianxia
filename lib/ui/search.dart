import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../app/capture_session_controller.dart';
import '../app/inference_runtime.dart';
import '../platform/local_models.dart';
import 'common.dart';
import '../domain/search_page.dart' as paging;
import 'detail.dart';
import 'voice_query.dart';
import '../platform/capture_controller.dart';
import 'result_playback.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.book,
    this.models,
    this.captureSession,
    this.microphone,
    this.voice = false,
  });
  final Notebook book;
  final LocalModels? models;
  final CaptureSessionController? captureSession;
  final bool voice;
  final MicrophoneInput? microphone;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> with WidgetsBindingObserver {
  final text = TextEditingController();
  final inputFocus = FocusNode();
  bool autofocusInput = true;
  bool inputCanFocus = true;
  final scroll = ScrollController();
  DateTimeRange? range;
  String dateChoice = 'all';
  paging.SearchQuery? confirmed, resultQuery;
  List<paging.SearchHitSummary> hits = [];
  paging.SearchCursor? next;
  paging.SearchCancellation? cancellation;
  bool busy = false, semantic = false, approximate = false, reviewVoice = false;
  bool resultsOutdated = false, errorMore = false, errorAtEnd = false;
  int? knownTotal;
  String? error, fallback, changeNotice, inputError;
  int generation = 0, voiceEpoch = 0;
  int resultEpoch = 0;
  bool noticeAnnounced = false;

  paging.SearchQuery query(String value) => paging.SearchQuery(
    text: value.trim(),
    from: range?.start,
    to: range?.end,
  );
  bool matchesDraft(paging.SearchQuery value) {
    bool sameDay(DateTime? a, DateTime? b) =>
        a?.year == b?.year && a?.month == b?.month && a?.day == b?.day;
    return value.text == text.text.trim() &&
        sameDay(value.from, range?.start) &&
        sameDay(value.to, range?.end);
  }

  bool get busySameQuery =>
      busy && confirmed != null && matchesDraft(confirmed!);
  bool get stale =>
      resultQuery != null && (resultsOutdated || !matchesDraft(resultQuery!));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.book.contentChanges.addListener(sourceChanged);
    scroll.addListener(scrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      var ready = false;
      try {
        ready =
            await (widget.captureSession?.runtime.ready(
                  InferenceCapability.semantic,
                ) ??
                widget.models?.ready(InferenceCapability.semantic) ??
                Future.value(false));
      } catch (_) {
        /* Keyword lookup does not require a model. */
      }
      if (!mounted) return;
      setState(() => semantic = ready);
      if (widget.voice) voice();
    });
  }

  @override
  void dispose() {
    voiceEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    widget.book.contentChanges.removeListener(sourceChanged);
    scroll.dispose();
    cancellation?.cancel();
    text.dispose();
    inputFocus.dispose();
    generation++;
    super.dispose();
  }

  void invalidate() {
    cancellation?.cancel();
    cancellation = null;
    generation++;
    next = null;
    busy = false;
    error = null;
    inputError = null;
    errorMore = false;
    errorAtEnd = false;
    changeNotice = null;
    noticeAnnounced = false;
    resultsOutdated = resultQuery != null;
  }

  void edited() {
    voiceEpoch++;
    setState(() {
      invalidate();
      if (text.text.trim().isEmpty) {
        hits = [];
        confirmed = resultQuery = null;
        fallback = null;
        knownTotal = null;
        resultsOutdated = false;
        reviewVoice = false;
      }
    });
  }

  void sourceChanged() {
    if (!mounted) return;
    final previous = confirmed;
    resultEpoch++;
    setState(invalidate);
    if (previous != null && !reviewVoice && matchesDraft(previous)) {
      run(previous, sourceRefresh: true);
    } else if (resultQuery != null) {
      setState(() => changeNotice = '记录已变化，提交查找后更新结果。');
      announceChange();
    }
  }

  Future<void> submitSearch() async {
    if (text.text.trim().isEmpty) return;
    late paging.SearchQuery requested;
    try {
      requested = query(text.text);
    } on NotebookException catch (e) {
      setState(
        () => inputError = text.text.trim().length > 10000
            ? '查找文字过长，请缩短后重试。'
            : userError(e),
      );
      return;
    }
    if (busy && confirmed?.identity == requested.identity) return;
    FocusScope.of(context).unfocus();
    await run(requested, toTop: true);
  }

  void scrolled() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < 400 &&
        next != null &&
        !busy &&
        !stale &&
        error == null &&
        confirmed != null) {
      run(confirmed!, more: true);
    }
  }

  Future<void> retry() async {
    final requested = confirmed;
    if (requested == null) return;
    await run(requested, more: errorMore, toTop: !errorAtEnd);
  }

  Future<void> run(
    paging.SearchQuery requested, {
    bool more = false,
    bool toTop = false,
    bool sourceRefresh = false,
  }) async {
    if (more && (busy || next == null || stale)) return;
    final previousCount = hits.length;
    final cursor = more ? next : null;
    final version = ++generation;
    if (!more) {
      cancellation?.cancel();
      cancellation = paging.SearchCancellation();
    }
    final token = cancellation;
    final embedder = semantic
        ? (widget.captureSession?.runtime ?? widget.models)
        : null;
    setState(() {
      if (!more) resultEpoch++;
      confirmed = requested;
      reviewVoice = false;
      busy = true;
      error = null;
      errorMore = false;
      errorAtEnd = false;
      changeNotice = null;
      noticeAnnounced = false;
      if (!more) {
        next = null;
        resultsOutdated = resultQuery != null;
      }
    });
    var restarted = false;
    try {
      var found = await widget.book.searchPage(
        requested,
        after: cursor,
        embedder: embedder,
        cancellation: token,
      );
      if (!mounted || version != generation) return;
      restarted = found.reset;
      if (restarted) {
        setState(() {
          resultsOutdated = resultQuery != null;
          next = null;
        });
        found = await widget.book.searchPage(
          requested,
          embedder: embedder,
          cancellation: token,
        );
        if (!mounted || version != generation) return;
        if (found.reset) throw const NotebookException('记录正在变化，请再查找一次。');
      }
      var collected = [...found.entries];
      final wanted = sourceRefresh || restarted ? previousCount : 0;
      while (collected.length < wanted && found.next != null) {
        final following = await widget.book.searchPage(
          requested,
          after: found.next,
          embedder: embedder,
          cancellation: token,
        );
        if (!mounted || version != generation) return;
        if (following.reset) {
          if (restarted) throw const NotebookException('记录正在变化，请再查找一次。');
          restarted = true;
          setState(() {
            resultsOutdated = resultQuery != null;
            next = null;
          });
          found = await widget.book.searchPage(
            requested,
            embedder: embedder,
            cancellation: token,
          );
          if (!mounted || version != generation) return;
          if (found.reset) throw const NotebookException('记录正在变化，请再查找一次。');
          collected = [...found.entries];
        } else {
          found = following;
          collected.addAll(found.entries);
        }
      }
      setState(() {
        hits = more && !restarted ? [...hits, ...collected] : collected;
        resultQuery = requested;
        resultsOutdated = false;
        next = found.next;
        knownTotal = found.knownTotal;
        approximate = found.semanticApproximate;
        fallback = found.fallbackReason;
        busy = false;
        if (sourceRefresh) {
          changeNotice = '记录已变化，已重新查找。';
        } else if (restarted) {
          changeNotice = '查找已刷新，已重新载入结果。';
        }
      });
      announceChange();
      if (toTop && scroll.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && generation == version && scroll.hasClients) {
            scroll.jumpTo(0);
          }
        });
      }
    } catch (e) {
      if (!mounted || generation != version) return;
      setState(() {
        error = userError(e);
        errorMore = more && !restarted;
        errorAtEnd = more;
        busy = false;
        if (restarted) {
          next = null;
          resultsOutdated = resultQuery != null;
        }
      });
    }
  }

  void announceChange() {
    if (!mounted ||
        changeNotice == null ||
        noticeAnnounced ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    noticeAnnounced = true;
    notice(context, changeNotice!);
  }

  Future<void> openHit(String id) async {
    final position = scroll.hasClients ? scroll.offset : 0.0;
    final identity = confirmed?.identity;
    // Route focus restoration must not scroll the search field back on screen.
    setState(() {
      autofocusInput = false;
      inputCanFocus = false;
    });
    inputFocus.canRequestFocus = false;
    try {
      await openDetail(context, widget.book, id, models: widget.models);
    } finally {
      if (mounted) {
        setState(() => inputCanFocus = true);
        announceChange();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && confirmed?.identity == identity && scroll.hasClients) {
            scroll.jumpTo(position.clamp(0.0, scroll.position.maxScrollExtent));
          }
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) voiceEpoch++;
  }

  Future<void> voice() async {
    final epoch = ++voiceEpoch;
    if (widget.book.captureActive) {
      notice(context, '请先处理当前录音，再说出查找线索。');
      return;
    }
    var ready = false;
    try {
      ready =
          await (widget.captureSession?.runtime.ready(
                InferenceCapability.speech,
              ) ??
              widget.models?.ready(InferenceCapability.speech) ??
              Future.value(false));
    } catch (_) {
      /* Keep the text path available. */
    }
    if (!mounted ||
        epoch != voiceEpoch ||
        !(ModalRoute.of(context)?.isCurrent ?? false) ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      return;
    }
    if (!ready) {
      notice(context, '语音模型未就绪，可直接输入文字查找，或在设置下载模型。');
      return;
    }
    FocusScope.of(context).unfocus();
    final result = await openVoiceQuery(
      context,
      widget.book,
      widget.models,
      captureSession: widget.captureSession,
      microphone: widget.microphone,
    );
    if (!mounted ||
        epoch != voiceEpoch ||
        !(ModalRoute.of(context)?.isCurrent ?? false) ||
        result is! String) {
      return;
    }
    setState(() {
      invalidate();
      text.text = result;
      reviewVoice = true;
      hits = [];
      confirmed = resultQuery = null;
      fallback = null;
      knownTotal = null;
      resultsOutdated = false;
    });
  }

  void applyDates(String choice, DateTimeRange? value) {
    final previous = confirmed;
    setState(() {
      invalidate();
      dateChoice = choice;
      range = value;
    });
    if (previous != null && !reviewVoice) {
      run(query(previous.text), toTop: true);
    }
  }

  void chooseDates(String choice) {
    final now = widget.book.clock();
    final today = DateTime(now.year, now.month, now.day);
    if (choice == 'custom') {
      dates();
      return;
    }
    applyDates(
      choice,
      choice == 'all'
          ? null
          : DateTimeRange(
              start: choice == 'today'
                  ? today
                  : DateTime(now.year, now.month, now.day - 6),
              end: today,
            ),
    );
  }

  Future<void> dates() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: range,
      helpText: '按记录创建日期筛选',
    );
    if (selected != null && mounted) applyDates('custom', selected);
  }

  String dateText(DateTime? from, DateTime? to) {
    String day(DateTime d) => '${d.year}/${d.month}/${d.day}';
    if (from == null) return '全部日期';
    return '${day(from)} 至 ${day(to!)}';
  }

  String get countText => next != null || knownTotal == null
      ? '已显示 ${hits.length} 条记录'
      : '找到 $knownTotal 条记录${approximate ? '，含近似语义匹配' : ''}';

  Widget failure() => SliverPadding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
    sliver: SliverToBoxAdapter(
      child: PaperSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              errorAtEnd ? '后续记录未能加载' : '暂时无法查找',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(error!),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: retry, child: const Text('重试查找')),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('找一下')),
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    body: SafeArea(
      top: false,
      child: ReadingWidth(
        child: CustomScrollView(
          key: const Key('search-scroll'),
          controller: scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('search-input'),
                      controller: text,
                      focusNode: inputFocus,
                      canRequestFocus: inputCanFocus,
                      autofocus: autofocusInput && !widget.voice,
                      textInputAction: TextInputAction.search,
                      maxLength: 500,
                      decoration: InputDecoration(
                        hintText: semantic ? '输入关键词或描述' : '输入记得的关键词',
                        hintMaxLines: 2,
                        errorText: inputError,
                        counterText: '',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: text.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空查找内容',
                                onPressed: () {
                                  text.clear();
                                  edited();
                                },
                                icon: const Icon(Icons.close_rounded, size: 20),
                              ),
                      ),
                      onChanged: (_) => edited(),
                      onSubmitted: (_) => submitSearch(),
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final voiceButton = OutlinedButton.icon(
                          onPressed: voice,
                          icon: const Icon(Icons.mic_none_rounded),
                          label: const Text('语音查找'),
                        );
                        final searchButton = FilledButton(
                          key: const Key('search-submit'),
                          onPressed: text.text.trim().isEmpty || busySameQuery
                              ? null
                              : submitSearch,
                          child: Text(busySameQuery ? '查找中' : '查找'),
                        );
                        if (MediaQuery.textScalerOf(context).scale(16) > 22) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              voiceButton,
                              const SizedBox(height: 10),
                              searchButton,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            Expanded(flex: 3, child: voiceButton),
                            const SizedBox(width: 12),
                            Expanded(flex: 2, child: searchButton),
                          ],
                        );
                      },
                    ),
                    if (reviewVoice) ...[
                      const SizedBox(height: 12),
                      Text(
                        '识别文字可以修改，确认后点“查找”。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (reviewVoice)
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(onPressed: voice, child: const Text('重说')),
                          TextButton(
                            onPressed: () {
                              text.clear();
                              edited();
                            },
                            child: const Text('取消语音查询'),
                          ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final choice in const [
                          ('all', '全部'),
                          ('today', '今天'),
                          ('week', '最近七天'),
                          ('custom', '自定义'),
                        ])
                          ChoiceChip(
                            key: Key('search-date-${choice.$1}'),
                            label: Text(choice.$2),
                            selected: dateChoice == choice.$1,
                            showCheckmark: false,
                            onSelected: (_) => chooseDates(choice.$1),
                          ),
                      ],
                    ),
                    if (range != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '按创建日期：${dateText(range?.start, range?.end)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (busy)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (error != null && !errorAtEnd) failure(),
            if (changeNotice != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Text(
                    changeNotice!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            if (resultQuery != null)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '“${resultQuery!.text}” · ${dateText(resultQuery!.from, resultQuery!.to)}',
                        key: const Key('search-result-context'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          stale ? '尚未更新 · 上次已显示 ${hits.length} 条记录' : countText,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      if (stale && !busy && error == null)
                        Text(
                          '输入或条件已修改，点“查找”更新结果。',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (fallback != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            fallback!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (hits.isNotEmpty)
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                sliver: SliverList.builder(
                  itemCount: hits.length,
                  itemBuilder: (context, i) {
                    final entry = hits[i];
                    return SearchSummaryRow(
                      key: ValueKey('${entry.id}:$resultEpoch'),
                      book: widget.book,
                      entry: entry,
                      onTap: () => openHit(entry.id),
                      onParent: entry.parentId == null
                          ? null
                          : () => openHit(entry.parentId!),
                    );
                  },
                ),
              )
            else if (!busy && error == null && !reviewVoice)
              SliverFillRemaining(
                hasScrollBody: false,
                child: resultQuery != null && !stale
                    ? EmptyState(
                        icon: Icons.search_off_rounded,
                        title: '没有找到相关记录',
                        detail: range == null
                            ? '换个关键词，再试一次。'
                            : '试试其他关键词，或放宽日期范围。',
                        action: range == null
                            ? null
                            : OutlinedButton(
                                onPressed: () => applyDates('all', null),
                                child: const Text('清除日期条件'),
                              ),
                      )
                    : EmptyState(
                        icon: Icons.search_rounded,
                        title: resultQuery != null
                            ? '上次查找没有结果，尚未更新'
                            : '找回之前的想法',
                        detail: '输入关键词后，点击“查找”或使用键盘查找。',
                      ),
              ),
            if (error != null && errorAtEnd) failure(),
            if (next != null && !busy && !stale && error == null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: OutlinedButton(
                    onPressed: () => run(confirmed!, more: true),
                    child: const Text('继续加载'),
                  ),
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        ),
      ),
    ),
  );
}

/// A display-only projection; opening a result reads its current full source.
class SearchSummaryRow extends StatelessWidget {
  const SearchSummaryRow({
    super.key,
    required this.book,
    required this.entry,
    required this.onTap,
    this.onParent,
  });
  final Notebook book;
  final paging.SearchHitSummary entry;
  final VoidCallback onTap;
  final VoidCallback? onParent;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var preview = entry.snippet.trim();
    if (preview.startsWith('${entry.title}\n')) {
      preview = preview.substring(entry.title.length).trimLeft();
    }
    final local = entry.createdAt.toUtc().add(
      Duration(minutes: entry.offsetMinutes),
    );
    final time =
        '${local.year}年${local.month}月${local.day}日 ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(fontSize: 18),
              ),
              if (preview.isNotEmpty && preview != entry.title.trim()) ...[
                const SizedBox(height: 8),
                Text(
                  preview,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium,
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  Text(time, style: theme.textTheme.bodySmall),
                  Text(
                    entry.hasAudio
                        ? '音频 ${durationText(entry.durationMs)}'
                        : '文字',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (entry.kind == paging.MatchKind.semantic)
                    Text('近似匹配', style: theme.textTheme.bodySmall),
                  if (entry.parentId != null)
                    Text('追加内容', style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 12),
              if (entry.parentId != null)
                entry.parentTitle == null
                    ? Text('所属原记录已不可用', style: theme.textTheme.bodySmall)
                    : TextButton(
                        onPressed: onParent,
                        child: Text(
                          '所属：${entry.parentTitle}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.start,
                        ),
                      ),
              if (entry.hasAudio)
                ResultPlaybackButton(book: book, id: entry.id),
              const Divider(height: 1),
            ],
          ),
        ),
      ),
    );
  }
}
