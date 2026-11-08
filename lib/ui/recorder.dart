import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import '../platform/capture_controller.dart';
import 'common.dart';

Future<Object?> openRecorder(
  BuildContext context,
  Notebook book,
  LocalModels? models, {
  String? parentId,
  bool query = false,
}) => book.captureActive
    ? Future.value(null)
    : showModalBottomSheet<Object?>(
        context: context,
        isDismissible: false,
        enableDrag: false,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => _Recorder(
          book: book,
          models: models,
          parentId: parentId,
          query: query,
        ),
      );

class _Recorder extends StatefulWidget {
  const _Recorder({
    required this.book,
    this.models,
    this.parentId,
    this.query = false,
  });
  final Notebook book;
  final LocalModels? models;
  final String? parentId;
  final bool query;
  @override
  State<_Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<_Recorder> {
  late final capture = CaptureController(
    widget.book,
    models: widget.models,
    parentId: widget.parentId,
    query: widget.query,
  );
  bool closed = false;
  @override
  void initState() {
    super.initState();
    capture.addListener(update);
    capture.start();
  }

  void update() {
    if (!mounted || closed) {
      return;
    }
    if (capture.state == 'done' || capture.state == 'cancelled') {
      closed = true;
      Navigator.pop(context, capture.queryText ?? capture.saved);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    capture.removeListener(update);
    capture.dispose();
    super.dispose();
  }

  Future<void> cancel() async {
    if (capture.state == 'saving') {
      return;
    }
    if (capture.state == 'recording' &&
        !await confirm(
          context,
          widget.query ? '取消本次查询？' : '丢弃这段录音？',
          widget.query ? '临时查询音频将删除，不会成为记录。' : '尚未保存的音频将删除。',
          action: '确认丢弃',
        )) {
      return;
    }
    await capture.discard();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !capture.active,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) {
        notice(context, '请先停止保存或选择丢弃。');
      }
    },
    child: SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.query ? '说出要找的内容' : '记下此刻的想法',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: capture.state == 'saving' ? null : cancel,
                    tooltip: '丢弃并关闭',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                widget.query ? '仅用于这次查找，结束后删除查询音频' : '最长 2 分钟，到时自动停止保存',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 32),
              Semantics(
                liveRegion: true,
                label: '录音状态 ${capture.state}，${durationText(capture.elapsed)}',
                child: Text(
                  durationText(capture.elapsed),
                  style: const TextStyle(
                    fontSize: 48,
                    fontWeight: FontWeight.w400,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              if (capture.state == 'recording') ...[
                Semantics(
                  label: '实时麦克风音量',
                  child: LinearProgressIndicator(
                    value: capture.amplitude,
                    minHeight: 4,
                  ),
                ),
                const SizedBox(height: 12),
                const Text('正在录音'),
              ] else
                Text(
                  capture.error ??
                      (capture.state == 'saving'
                          ? (widget.query ? '正在本地识别查询' : '正在保存音频')
                          : '正在准备麦克风'),
                  textAlign: TextAlign.center,
                ),
              const SizedBox(height: 28),
              if (capture.state == 'recording')
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: capture.finish,
                    icon: const Icon(Icons.stop_rounded),
                    label: Text(widget.query ? '停止并查找' : '停止并保存'),
                  ),
                ),
              if (capture.state == 'failed')
                Wrap(
                  spacing: 12,
                  children: [
                    if (capture.draft != null && !widget.query)
                      FilledButton(
                        onPressed: capture.retry,
                        child: const Text('重试保存'),
                      ),
                    OutlinedButton(
                      onPressed: cancel,
                      child: const Text('关闭或丢弃'),
                    ),
                  ],
                ),
              if (capture.state == 'saving' || capture.state == 'starting')
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    ),
  );
}
