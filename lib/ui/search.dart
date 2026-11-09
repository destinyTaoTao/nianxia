import 'dart:async';

import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import 'common.dart';
import 'home.dart' show RecordRow;
import 'detail.dart';
import 'recorder.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    required this.book,
    this.models,
    this.voice = false,
  });
  final Notebook book;
  final LocalModels? models;
  final bool voice;
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final text = TextEditingController();
  DateTimeRange? range;
  List<SearchHit> hits = [];
  bool busy = false;
  bool semantic = false;
  String? error;
  String? fallback;
  int generation = 0;
  Timer? debounce;
  @override
  void initState() {
    super.initState();
    widget.book.addListener(changed);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      semantic = await widget.models?.store.ready('bge') ?? false;
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
    widget.book.removeListener(changed);
    debounce?.cancel();
    text.dispose();
    generation++;
    super.dispose();
  }

  void changed() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 250), search);
  }

  Future<void> search() async {
    final version = ++generation;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final found = await widget.book.search(
        text.text,
        from: range?.start,
        to: range?.end,
        embedder: semantic ? widget.models : null,
      );
      if (mounted && generation == version) {
        setState(() {
          hits = found;
          fallback = found.fallbackReason;
          busy = false;
        });
      }
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
    if (widget.models == null ||
        !await widget.models!.store.ready('sensevoice')) {
      if (mounted) notice(context, '语音模型未就绪，可直接输入文字查找，或在设置下载模型。');
      return;
    }
    if (!mounted) return;
    final result = await openRecorder(
      context,
      widget.book,
      widget.models,
      query: true,
    );
    if (mounted && result is String) {
      text.text = result;
      search();
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
      search();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('找一下')),
    body: ReadingWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
            child: TextField(
              key: const Key('search-input'),
              controller: text,
              autofocus: !widget.voice,
              maxLength: 500,
              decoration: InputDecoration(
                hintText: semantic ? '输入关键词或描述' : '输入记得的关键词',
                hintMaxLines: 2,
                counterText: '',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '语音查找',
                  onPressed: voice,
                  icon: const Icon(Icons.mic_none_rounded),
                ),
              ),
              onChanged: (_) => changed(),
              onSubmitted: (_) => search(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 16, 8),
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
                        : '${range!.start.month}月${range!.start.day}日 至 ${range!.end.month}月${range!.end.day}日',
                  ),
                ),
                if (range != null)
                  IconButton(
                    tooltip: '清除日期条件',
                    onPressed: () {
                      setState(() => range = null);
                      search();
                    },
                    icon: const Icon(Icons.close, size: 18),
                  ),
                if (fallback != null && text.text.trim().isNotEmpty)
                  Text(fallback!, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: error != null
                ? EmptyState(title: '暂时无法查找', detail: error!)
                : text.text.trim().isEmpty
                ? const EmptyState(
                    icon: Icons.search_rounded,
                    title: '找回之前的想法',
                    detail: '输入关键词，或点麦克风说出要找的内容。',
                  )
                : hits.isEmpty && !busy
                ? const EmptyState(
                    icon: Icons.search_off_rounded,
                    title: '没有找到相关记录',
                    detail: '换个关键词，或清除日期条件再试。',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    itemCount: hits.length,
                    itemBuilder: (context, i) => RecordRow(
                      record: hits[i].record,
                      snippet: hits[i].snippet,
                      onTap: () => openDetail(
                        context,
                        widget.book,
                        hits[i].record.id,
                        models: widget.models,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    ),
  );
}
