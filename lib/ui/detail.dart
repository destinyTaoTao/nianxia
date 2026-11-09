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
  Future<void> remove(Record r) async {
    final count = widget.book.children(r.id).length;
    if (!await confirm(
      context,
      count > 0 ? '删除这组 ${count + 1} 条记录？' : '删除这条记录？',
      '正文、原音频、转写和整理结果将从本应用中删除。已加入系统日历的事件保持不变。',
      action: '删除',
    )) {
      return;
    }
    try {
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
      final consent = widget.book.prepareOrganization(r.id);
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.book,
    builder: (context, _) {
      final r = widget.book.get(widget.id);
      if (r == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('记录')),
          body: const EmptyState(title: '记录已删除', detail: '返回查看其他记录。'),
        );
      }
      final children = widget.book.children(r.id);
      return Scaffold(
        appBar: AppBar(
          title: const Text('记录'),
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
                r.favorite ? Icons.star_rounded : Icons.star_border_rounded,
              ),
            ),
            IconButton(
              tooltip: '编辑正文',
              onPressed: () => openEditor(context, widget.book, record: r),
              icon: const Icon(Icons.edit_outlined),
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
        body: ReadingWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
            children: [
              PaperSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      recordDate(r),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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
                    SelectableText(
                      r.body.isEmpty ? '音频已保存，等待转写。' : r.body,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    if (r.audio != null) ...[
                      const SizedBox(height: 24),
                      AudioPlayback(
                        path: widget.book.audioPath(r),
                        duration: r.durationMs,
                      ),
                      const SizedBox(height: 8),
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
                              onPressed: transcribing
                                  ? null
                                  : () => transcribe(r),
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
                  ],
                ),
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
                      '${children.length} 次追加',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () =>
                          openEditor(context, widget.book, parentId: r.id),
                      icon: const Icon(Icons.edit_outlined, size: 18),
                      label: const Text('追加文字'),
                    ),
                    TextButton.icon(
                      onPressed: () => openRecorder(
                        context,
                        widget.book,
                        widget.models,
                        parentId: r.id,
                      ),
                      icon: const Icon(Icons.mic_none_rounded, size: 20),
                      label: const Text('追加语音'),
                    ),
                  ],
                ),
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
              ],
            ],
          ),
        ),
      );
    },
  );
}

class AudioPlayback extends StatefulWidget {
  const AudioPlayback({super.key, required this.path, required this.duration});
  final String path;
  final int duration;
  @override
  State<AudioPlayback> createState() => _AudioPlaybackState();
}

class _AudioPlaybackState extends State<AudioPlayback> {
  final player = AudioPlayer();
  bool loading = false;
  String? error;
  Future<void> toggle() async {
    if (loading) {
      return;
    }
    setState(() => loading = true);
    try {
      if (player.playing) {
        await player.pause();
      } else {
        if (player.audioSource == null) {
          await player.setFilePath(widget.path);
        }
        if (player.processingState == ProcessingState.completed) {
          await player.seek(Duration.zero);
        }
        player.play().catchError((Object _) {
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
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StreamBuilder<PlayerState>(
              stream: player.playerStateStream,
              builder: (context, s) => IconButton(
                onPressed: loading ? null : toggle,
                tooltip: player.playing ? '暂停原音频' : '播放原音频',
                icon: Icon(
                  player.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (context, s) => Slider(
                  label: '回放位置',
                  value: (s.data?.inMilliseconds ?? 0)
                      .clamp(0, widget.duration)
                      .toDouble(),
                  max: widget.duration.toDouble().clamp(1, double.infinity),
                  onChanged: (v) =>
                      player.seek(Duration(milliseconds: v.round())),
                ),
              ),
            ),
            Text(
              durationText(widget.duration),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        if (error != null)
          Text(error!, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );
}
