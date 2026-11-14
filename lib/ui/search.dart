import 'dart:async';

import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../app/capture_session_controller.dart';
import '../app/inference_runtime.dart';
import '../platform/local_models.dart';
import 'common.dart';
import '../domain/search_page.dart' as paging;
import 'detail.dart';
import 'recorder.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.book,
    this.models,
    this.captureSession,
    this.voice = false,
  });
  final Notebook book;
  final LocalModels? models;
  final CaptureSessionController? captureSession;
  final bool voice;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final text = TextEditingController();
  DateTimeRange? range;
  List<paging.SearchHitSummary> hits = [];
  paging.SearchCursor? next;
  paging.SearchCancellation? cancellation;
  final scroll = ScrollController();
  bool busy = false;
  bool semantic = false;
  bool approximate = false;
  bool reviewVoice = false;
  String? error;
  String? fallback;
  int generation = 0;
  Timer? debounce;
  @override
  void initState() {
    super.initState();
    widget.book.contentChanges.addListener(changed);
    scroll.addListener(scrolled);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      semantic =
          await (widget.captureSession?.runtime.ready(
                InferenceCapability.semantic,
              ) ??
              widget.models?.ready(InferenceCapability.semantic) ??
              Future.value(false));
      if (mounted) {
        setState(() {});
        if (widget.voice) {
          voice();
        }
      }
    });
  }

  @override
  void dispose() {
    widget.book.contentChanges.removeListener(changed);
    scroll.dispose();
    cancellation?.cancel();
    debounce?.cancel();
    text.dispose();
    generation++;
    super.dispose();
  }

  void changed() {
    cancellation?.cancel();
    next = null;
    debounce?.cancel();
    generation++;
    setState(() {
      hits = [];
      error = null;
      fallback = null;
      busy = text.text.trim().isNotEmpty && !reviewVoice;
    });
    if (!reviewVoice) {
      debounce = Timer(const Duration(milliseconds: 250), search);
    }
  }

  void clearDates() {
    setState(() => range = null);
    if (!reviewVoice) search();
  }

  Future<void> submitSearch() async {
    FocusScope.of(context).unfocus();
    await search();
  }

  void scrolled() {
    if (scroll.hasClients &&
        scroll.position.extentAfter < 400 &&
        next != null &&
        !busy &&
        error == null) {
      search(more: true);
    }
  }

  Future<void> search({bool more = false}) async {
    if (more && (busy || next == null)) return;
    debounce?.cancel();
    final version = ++generation;
    if (!more) {
      cancellation?.cancel();
      cancellation = paging.SearchCancellation();
    }
    setState(() {
      reviewVoice = false;
      busy = true;
      error = null;
      if (!more) {
        hits = [];
        next = null;
        fallback = null;
      }
    });
    try {
      final found = await widget.book.searchPage(
        paging.SearchQuery(text: text.text, from: range?.start, to: range?.end),
        after: more ? next : null,
        embedder: semantic
            ? (widget.captureSession?.runtime ?? widget.models)
            : null,
        cancellation: cancellation,
      );
      if (!mounted || generation != version) return;
      setState(() {
        hits = more && !found.reset
            ? [...hits, ...found.entries]
            : found.entries;
        next = found.next;
        approximate = found.semanticApproximate;
        fallback = found.fallbackReason;
        busy = false;
      });
      if (more && found.reset) notice(context, '记录已变化，已重新查找。');
    } catch (e) {
      if (mounted && generation == version) {
        setState(() {
          error = userError(e);
          busy = false;
        });
      }
    }
  }

  Future<void> voice() async {
    if (!await (widget.captureSession?.runtime.ready(
          InferenceCapability.speech,
        ) ??
        widget.models?.ready(InferenceCapability.speech) ??
        Future.value(false))) {
      if (mounted) notice(context, '语音模型未就绪，可直接输入文字查找，或在设置下载模型。');
      return;
    }
    if (!mounted) return;
    FocusScope.of(context).unfocus();
    final result = await openRecorder(
      context,
      widget.book,
      widget.models,
      query: true,
      captureSession: widget.captureSession,
    );
    if (mounted && result is String) {
      debounce?.cancel();
      generation++;
      text.text = result;
      setState(() {
        reviewVoice = true;
        hits = [];
        busy = false;
        error = null;
        fallback = null;
      });
    }
  }

  Future<void> dates() async {
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: range,
      helpText: '按记录创建日期筛选',
    );
    if (selected != null && mounted) {
      setState(() => range = selected);
      if (!reviewVoice) search();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('找一下')),
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    body: SafeArea(
      top: false,
      child: ReadingWidth(
        child: CustomScrollView(
          controller: scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('search-input'),
                      controller: text,
                      autofocus: !widget.voice,
                      textInputAction: TextInputAction.search,
                      maxLength: 500,
                      decoration: InputDecoration(
                        hintText: semantic ? '输入关键词或描述' : '输入记得的关键词',
                        hintMaxLines: 2,
                        counterText: '',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: text.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空查找内容',
                                onPressed: () {
                                  reviewVoice = false;
                                  text.clear();
                                  changed();
                                },
                                icon: const Icon(Icons.close_rounded, size: 20),
                              ),
                      ),
                      onChanged: (_) => changed(),
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
                          onPressed: text.text.trim().isEmpty || busy
                              ? null
                              : submitSearch,
                          child: Text(busy ? '查找中' : '查找'),
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
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: dates,
                      icon: const Icon(Icons.date_range_outlined, size: 18),
                      label: Text(
                        range == null
                            ? '按日期筛选'
                            : '${range!.start.year}/${range!.start.month}/${range!.start.day} 至 ${range!.end.year}/${range!.end.month}/${range!.end.day}',
                      ),
                    ),
                    if (range != null)
                      IconButton(
                        tooltip: '清除日期条件',
                        onPressed: clearDates,
                        icon: const Icon(Icons.close_rounded, size: 18),
                      ),
                    if (fallback != null && text.text.trim().isNotEmpty)
                      Text(
                        fallback!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ),
            if (busy)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.search_off_rounded,
                  title: '暂时无法查找',
                  detail: error!,
                  action: OutlinedButton(
                    onPressed: search,
                    child: const Text('重试查找'),
                  ),
                ),
              )
            else if (text.text.trim().isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.search_rounded,
                  title: '找回之前的想法',
                  detail: range == null
                      ? '输入关键词，或用语音说出你记得的内容。'
                      : '输入关键词，在所选日期内查找。',
                ),
              )
            else if (reviewVoice)
              const SliverToBoxAdapter(child: SizedBox(height: 24))
            else if (hits.isEmpty && !busy)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.search_off_rounded,
                  title: '没有找到相关记录',
                  detail: range == null ? '换个关键词，再试一次。' : '试试其他关键词，或放宽日期范围。',
                  action: range == null
                      ? null
                      : OutlinedButton(
                          onPressed: clearDates,
                          child: const Text('清除日期条件'),
                        ),
                ),
              )
            else ...[
              if (!busy)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  sliver: SliverToBoxAdapter(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        next != null
                            ? '已显示 ${hits.length} 条记录'
                            : approximate
                            ? '找到 ${hits.length} 条记录，含近似语义匹配'
                            : '找到 ${hits.length} 条记录',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                sliver: SliverList.builder(
                  itemCount: hits.length,
                  itemBuilder: (context, i) => SearchSummaryRow(
                    entry: hits[i],
                    onTap: () => openDetail(
                      context,
                      widget.book,
                      hits[i].id,
                      models: widget.models,
                    ),
                  ),
                ),
              ),
              if (next != null && !busy)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: OutlinedButton(
                      onPressed: () => search(more: true),
                      child: const Text('继续加载'),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// A display-only projection; opening a result reads its current full source.
class SearchSummaryRow extends StatelessWidget {
  const SearchSummaryRow({super.key, required this.entry, required this.onTap});
  final paging.SearchHitSummary entry;
  final VoidCallback onTap;
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
              const Divider(height: 1),
            ],
          ),
        ),
      ),
    );
  }
}
