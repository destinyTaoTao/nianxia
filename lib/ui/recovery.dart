import 'platform_controls.dart';

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app/notebook.dart';
import '../app/capture_session_controller.dart';
import '../domain/recovery_entry.dart';
import 'common.dart';
import 'detail.dart' show AudioPlayback;

class RecoveryScreen extends StatefulWidget {
  const RecoveryScreen({super.key, required this.book, this.captureSession});
  final Notebook book;
  final CaptureSessionController? captureSession;
  @override
  State<RecoveryScreen> createState() => _RecoveryScreenState();
}

class _RecoveryScreenState extends State<RecoveryScreen> {
  List<RecoveryEntry> entries = [];
  String? next, error, status;
  bool loading = true, busy = false;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load({bool more = false}) async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final page = await widget.book.recoveryPage(after: more ? next : null);
      if (mounted) {
        setState(() {
          entries = more ? [...entries, ...page.entries] : page.entries;
          next = page.next;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = userError(e);
          loading = false;
        });
      }
    }
  }

  Future<void> discard(RecoveryEntry entry) async {
    if (busy ||
        !await confirm(
          context,
          '丢弃待恢复片段？',
          '此资料尚未保存为记录，丢弃后无法恢复。建议先导出原始资料。',
          action: '确认丢弃',
        ) ||
        !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.book.discardRecoveryEntry(entry.id);
      await widget.captureSession?.reconnect();
      if (mounted) {
        setState(() => status = '片段已丢弃');
        await load();
      }
    } catch (e) {
      if (mounted) setState(() => status = userError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> export(RecoveryEntry entry) async {
    if (busy ||
        !await confirm(
          context,
          '导出原始资料（未加密）？',
          '包含此片段的原始文件和恢复信息。选择云盘或其他应用会使资料离开设备。它不是完整备份。',
          action: '生成导出',
        ) ||
        !mounted) {
      return;
    }
    setState(() => busy = true);
    File? file;
    try {
      file = await widget.book.exportRecoveryEntry(entry.id);
      if (!mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          subject: '念下待恢复资料（未加密）',
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      if (mounted) {
        setState(
          () => status = result.status == ShareResultStatus.dismissed
              ? '已取消分享，未确认外部保存'
              : '已交给分享页，请核对实际保存位置',
        );
      }
    } catch (e) {
      if (mounted) setState(() => status = userError(e));
    } finally {
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          if (mounted) setState(() => status = '临时副本尚未清理，重新打开应用后将重试清理。');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> play(RecoveryEntry entry) async {
    if (busy) return;
    setState(() => busy = true);
    File? file;
    try {
      file = await widget.book.previewRecoveryAudio(entry.id);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        sheetAnimationStyle: PlatformControls.animationStyle(context),
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AudioPlayback(path: file!.path, duration: entry.durationMs!),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => status = userError(e));
    } finally {
      if (file != null) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {
          if (mounted) setState(() => status = '临时副本尚未清理，重新打开应用后将重试清理。');
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('待恢复资料'),
      actions: [
        IconButton(
          tooltip: '刷新恢复列表',
          onPressed: busy || loading ? null : () => load(),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    ),
    body: SafeArea(
      top: false,
      child: ReadingWidth(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('这些资料尚未确认为已保存的记录。可先试听或导出，再决定是否丢弃。未知格式保留原样。'),
            const SizedBox(height: 16),
            if (status != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Semantics(liveRegion: true, child: Text(status!)),
              ),
            if (loading || busy) const LinearProgressIndicator(),
            if (error != null) ...[
              Text(error!),
              OutlinedButton(onPressed: () => load(), child: const Text('重试')),
            ],
            if (entries.isEmpty && !loading && error == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Text('没有待恢复资料', textAlign: TextAlign.center),
              ),
            for (final entry in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(switch (entry.kind) {
                      RecoveryKind.unfinishedCapture => '未完成的录音',
                      RecoveryKind.quarantinedFile => '隔离片段',
                      RecoveryKind.unrecognizedJournal => '无法识别的恢复标记',
                    }, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '文件时间 ${entry.modifiedAt.toLocal().toString().substring(0, 16)} · ${(entry.bytes / 1024).toStringAsFixed(1)} KB${entry.durationMs == null ? '' : ' · ${durationText(entry.durationMs!)}'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Text(switch (entry.problem) {
                      RecoveryProblem.interrupted => '保存尚未完成，请先核对。',
                      RecoveryProblem.invalidAudio => '暂时无法播放，原始文件仍可导出。',
                      RecoveryProblem.missingAudio => '音频不可用，恢复信息仍保留。',
                      RecoveryProblem.unknownFormat => '格式无法识别，原始文件已保留，可先导出。',
                    }),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        if (entry.canPlay)
                          OutlinedButton.icon(
                            onPressed: busy ? null : () => play(entry),
                            icon: const Icon(Icons.play_arrow_rounded),
                            label: const Text('试听'),
                          ),
                        OutlinedButton(
                          onPressed: busy ? null : () => export(entry),
                          child: const Text('导出原始资料'),
                        ),
                        if (entry.canDiscard)
                          TextButton(
                            onPressed: busy ? null : () => discard(entry),
                            child: const Text('丢弃'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                  ],
                ),
              ),
            if (next != null && !loading)
              OutlinedButton(
                onPressed: () => load(more: true),
                child: const Text('加载更多待恢复资料'),
              ),
          ],
        ),
      ),
    ),
  );
}
