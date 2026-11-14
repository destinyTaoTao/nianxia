import 'platform_controls.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import '../platform/organizer.dart';
import 'common.dart';
import 'editor.dart';
import 'recorder.dart';
import 'calendar_form.dart';

Future<void> openDetail(
  BuildContext context,
  Notebook book,
  String id, {
  LocalModels? models,
}) => Navigator.push<void>(
  context,
  MaterialPageRoute(
    builder: (_) => DetailPage(book: book, id: id, models: models),
  ),
);

class DetailPage extends StatefulWidget {
  const DetailPage({
    super.key,
    required this.book,
    required this.id,
    this.models,
  });
  final Notebook book;
  final String id;
  final LocalModels? models;
  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> {
  bool cloudBusy = false;
  bool transcribing = false;
  RecordDetail? detail;
  bool loading = true;
  Object? loadError;
  int request = 0;

  @override
  void initState() {
    super.initState();
    widget.book.addListener(recordsChanged);
    unawaited(loadDetail(reset: true));
  }

  @override
  void didUpdateWidget(covariant DetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book) {
      oldWidget.book.removeListener(recordsChanged);
      widget.book.addListener(recordsChanged);
    }
    if (oldWidget.book != widget.book || oldWidget.id != widget.id) {
      detail = null;
      unawaited(loadDetail(reset: true));
    }
  }

  @override
  void dispose() {
    widget.book.removeListener(recordsChanged);
    super.dispose();
  }

  void recordsChanged() => unawaited(loadDetail(reset: true));

  Future<void> loadDetail({bool reset = false}) async {
    if (!reset && (loading || detail?.children.next == null)) return;
    final current = ++request;
    final previous = detail;
    setState(() {
      loading = true;
      loadError = null;
    });
    try {
      final result = await widget.book.detail(
        widget.id,
        after: reset ? null : previous?.children.next,
        generation: reset ? null : previous?.children.generation,
      );
      if (!mounted || current != request) return;
      setState(() {
        if (result == null ||
            reset ||
            result.children.reset ||
            previous == null) {
          detail = result;
        } else {
          detail = RecordDetail(
            result.record,
            RecordPage(
              [...previous.children.entries, ...result.children.entries],
              result.children.next,
              result.children.generation,
            ),
            result.childCount,
          );
        }
        loading = false;
      });
    } catch (error) {
      if (!mounted || current != request) return;
      setState(() {
        loading = false;
        loadError = error;
      });
    }
  }

  Future<void> remove(Record r) async {
    try {
      final count = await widget.book.childCount(r.id);
      if (!mounted) return;
      if (!await confirm(
        context,
        count > 0 ? '删除这组 ${count + 1} 条记录？' : '删除这条记录？',
        '正文、原音频、转写和整理结果将从本应用中删除。已加入系统日历的事件保持不变。',
        action: '删除',
      )) {
        return;
      }
      if (!mounted) return;
      await widget.book.delete(r.id);
      if (mounted) {
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        notice(context, userError(e));
      }
    }
  }

  Future<void> transcribe(Record r) async {
    if (widget.models == null) {
      notice(context, '请先准备离线语音模型。');
      return;
    }
    setState(() => transcribing = true);
    try {
      final ok = await widget.book.transcribe(r.id, widget.models!);
      if (mounted) {
        notice(context, ok ? '转写已完成' : '正文已改变，迟到的转写未写回。');
      }
    } catch (e) {
      if (mounted) {
        notice(context, userError(e));
      }
    } finally {
      if (mounted) {
        setState(() => transcribing = false);
      }
    }
  }

  Future<void> organize(Record r) async {
    if (cloudBusy) {
      return;
    }
    try {
      setState(() => cloudBusy = true);
      final consent = await widget.book.prepareOrganization(r.id);
      final key = await KeyVault().read();
      if (!mounted) {
        return;
      }
      if (key == null) {
        notice(context, '请先到设置配置自己的 DeepSeek API Key，云端整理默认关闭。');
        return;
      }
      final allowed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('发送这条正文到 DeepSeek？'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '仅发送下方文本，不发送音频、查询或其他记录。服务商将处理此内容，并按你的账户计费。失败不自动重试，再次发送可能重复计费。',
                  ),
                  const SizedBox(height: 16),
                  SelectableText(consent.text),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认发送'),
            ),
          ],
        ),
      );
      if (allowed != true || !mounted) {
        return;
      }
      setState(() => cloudBusy = true);
      final ok = await widget.book.organize(
        consent,
        DeepSeekOrganizer(key: key),
      );
      if (mounted) {
        notice(context, ok ? '整理已完成，请对照原文核对' : '记录已修改或删除，旧整理结果未写回。');
      }
    } catch (e) {
      if (mounted) {
        notice(context, userError(e));
      }
    } finally {
      if (mounted) {
        setState(() => cloudBusy = false);
      }
    }
  }

  Future<void> append(Record record) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      sheetAnimationStyle: PlatformControls.animationStyle(context),
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => SingleChildScrollView(
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 20, 12, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('接着这条想法记', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('追加文字'),
                  onTap: () => Navigator.pop(context, 'text'),
                ),
                ListTile(
                  leading: const Icon(Icons.mic_none_rounded),
                  title: const Text('追加语音'),
                  onTap: () => Navigator.pop(context, 'voice'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'text') {
      await openEditor(context, widget.book, parentId: record.id);
    } else if (action == 'voice') {
      await openRecorder(
        context,
        widget.book,
        widget.models,
        parentId: record.id,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = detail?.record;
    if (r == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('记录')),
        body: loading
            ? const Center(child: CircularProgressIndicator())
            : loadError != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('记录未能加载，请重试。'),
                    TextButton(
                      onPressed: () => loadDetail(reset: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              )
            : const EmptyState(title: '记录已删除', detail: '返回查看其他记录。'),
      );
    }
    final children = detail!.children.entries.map((entry) => entry.record);
    final heading = r.body.trim().contains('\n') ? r.title : null;
    final body = heading == null
        ? r.body
        : r.body.trim().substring(heading.length).trimLeft();
    return Scaffold(
      appBar: AppBar(
        title: const Text('记录详情'),
        actions: [
          IconButton(
            tooltip: r.favorite ? '取消收藏' : '收藏记录',
            onPressed: () async {
              try {
                await widget.book.favorite(r.id, !r.favorite);
              } catch (e) {
                if (context.mounted) {
                  notice(context, userError(e));
                }
              }
            },
            icon: Icon(
              r.favorite
                  ? Icons.bookmark_rounded
                  : Icons.bookmark_border_rounded,
            ),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (v) {
              if (v == 'delete') {
                remove(r);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'delete', child: Text('删除记录')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: BottomActions(
        primary: r.parentId == null
            ? FilledButton.icon(
                onPressed: () => append(r),
                icon: const Icon(Icons.add_rounded),
                label: const Text('追加内容'),
              )
            : Tooltip(
                message: '编辑正文',
                child: FilledButton.icon(
                  onPressed: () => openEditor(context, widget.book, record: r),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
              ),
        secondary: r.parentId == null
            ? Tooltip(
                message: '编辑正文',
                child: FilledButton.tonalIcon(
                  onPressed: () => openEditor(context, widget.book, record: r),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑'),
                ),
              )
            : null,
      ),
      body: ReadingWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
          children: [
            if (loading) const LinearProgressIndicator(),
            if (loadError != null)
              TextButton(
                onPressed: () => loadDetail(reset: true),
                child: const Text('记录更新失败，重试'),
              ),
            Text(recordDate(r), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 20),
            if (r.parentId != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => openDetail(
                    context,
                    widget.book,
                    r.parentId!,
                    models: widget.models,
                  ),
                  icon: const Icon(Icons.subdirectory_arrow_left),
                  label: const Text('查看所属记录'),
                ),
              ),
            if (heading != null) ...[
              SelectableText(
                heading,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 24),
            ],
            if (r.audio != null) ...[
              AudioPlayback(
                path: widget.book.audioPath(r),
                duration: r.durationMs,
              ),
              const SizedBox(height: 24),
            ],
            SelectableText(
              r.body.isEmpty
                  ? switch (r.transcription) {
                      'failed' => '这段录音暂未转写成功，原音频已保留。',
                      'running' => '正在转写，请稍候。',
                      _ => '音频已保存，等待转写。',
                    }
                  : body,
              style: heading == null && body.length <= 48
                  ? Theme.of(context).textTheme.titleLarge
                  : Theme.of(context).textTheme.bodyLarge
                        ?.copyWith(fontSize: 17, height: 1.9),
            ),
            if (r.audio != null) ...[
              const SizedBox(height: 16),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text(switch (r.transcription) {
                    'pending' => '待转写，模型就绪后处理',
                    'running' => '正在本地转写',
                    'failed' => '转写失败，音频已保留',
                    'stale' => '正文已改变，旧转写未写回',
                    _ => '原音频已保留',
                  }, style: Theme.of(context).textTheme.bodySmall),
                  if (r.transcription != 'running')
                    TextButton(
                      onPressed: transcribing ? null : () => transcribe(r),
                      child: Text(transcribing ? '转写中' : '重新转写'),
                    ),
                ],
              ),
            ],
            if (r.transcript != null)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('查看原始转写'),
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        r.transcript!,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: () => openCalendar(
                    context,
                    initialTitle: r.body.isEmpty ? '' : r.title,
                  ),
                  icon: const Icon(Icons.event_outlined),
                  label: const Text('加入日历'),
                ),
                OutlinedButton.icon(
                  onPressed: cloudBusy ? null : () => organize(r),
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: Text(cloudBusy ? '整理中' : '云端整理'),
                ),
              ],
            ),
            if (r.organization != null) ...[
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 24),
              Text(
                '整理结果${r.organizationStale ? '（已过期）' : ''}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                r.organizationStale
                    ? '正文已编辑。这是旧版本的整理，使用前请重新核对。'
                    : '由 DeepSeek 生成，请对照依据核对，原文保持不变。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Text(
                r.organization!['title'] as String,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final item in (r.organization!['points'] as List))
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item['text'] as String),
                      const SizedBox(height: 4),
                      Text(
                        '原文：${item['evidence']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              for (final item in (r.organization!['tasks'] as List))
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '事项候选：${item['title']}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        '原文：${item['evidence']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if ((item['timeText'] as String).isNotEmpty)
                        Text(
                          '原始时间：${item['timeText']}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      TextButton.icon(
                        onPressed: () => openCalendar(
                          context,
                          initialTitle: item['title'] as String,
                          location: item['location'] as String,
                          evidence: item['evidence'] as String,
                          stale: r.organizationStale,
                        ),
                        icon: const Icon(Icons.event_outlined),
                        label: const Text('核对并加入日历'),
                      ),
                    ],
                  ),
                ),
            ],
            if (r.parentId == null) ...[
              const SizedBox(height: 32),
              const Divider(),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '接着记',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  Text(
                    '${detail!.childCount} 次追加',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              for (final child in children)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    child.body.isEmpty ? '语音记录，等待转写' : child.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(recordDate(child)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => openDetail(
                    context,
                    widget.book,
                    child.id,
                    models: widget.models,
                  ),
                ),
              if (detail!.children.next != null)
                TextButton(
                  onPressed: loading ? null : () => loadDetail(),
                  child: Text(
                    loading
                        ? '加载中'
                        : loadError != null
                        ? '加载失败，重试'
                        : '加载更多追加',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class AudioPlayback extends StatefulWidget {
  const AudioPlayback({super.key, required this.path, required this.duration});
  final String path;
  final int duration;
  @override
  State<AudioPlayback> createState() => _AudioPlaybackState();
}

class _AudioPlaybackState extends State<AudioPlayback> {
  AudioPlayer? player;
  bool loading = false;
  String? error;
  // just_audio keeps `playing` true at EOF; completed audio is ready to replay.
  bool get isPlaying =>
      player?.playing == true &&
      player?.processingState != ProcessingState.completed;

  Future<void> toggle() async {
    if (loading) {
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    final current = player ??= AudioPlayer();
    try {
      if (isPlaying) {
        await current.pause();
      } else {
        if (current.audioSource == null) {
          await current.setFilePath(widget.path);
        }
        if (current.processingState == ProcessingState.completed) {
          await current.seek(Duration.zero);
        }
        current.play().catchError((Object _) {
          if (mounted) {
            setState(() => error = '无法回放，请检查原音频是否完整。');
          }
        });
      }
    } catch (_) {
      error = '无法回放，请检查原音频是否完整。';
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StreamBuilder<PlayerState>(
              stream: player?.playerStateStream,
              builder: (context, s) => IconButton.filled(
                onPressed: loading ? null : toggle,
                tooltip: isPlaying ? '暂停原音频' : '播放原音频',
                icon: Icon(
                  isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '原始音频',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            Text(
              durationText(widget.duration),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        StreamBuilder<Duration>(
          stream: player?.positionStream,
          builder: (context, s) => Slider(
            label: '回放位置',
            value: (s.data?.inMilliseconds ?? 0)
                .clamp(0, widget.duration)
                .toDouble(),
            max: widget.duration.toDouble().clamp(1, double.infinity),
            onChanged: player?.audioSource == null
                ? null
                : (v) => player!.seek(Duration(milliseconds: v.round())),
          ),
        ),
        if (error != null)
          Text(error!, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
