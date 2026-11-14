import 'platform_controls.dart';

import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import '../platform/capture_controller.dart';
import 'common.dart';
import 'editor.dart';
import '../app/capture_session_controller.dart';
import 'native_recorder.dart';

enum _RecorderAction { write }

Future<Object?> openRecorder(
  BuildContext context,
  Notebook book,
  LocalModels? models, {
  String? parentId,
  bool query = false,
  MicrophoneInput? microphone,
  VoidCallback? onSaved,
  CaptureSessionController? captureSession,
}) async {
  captureSession ??= NativeCaptureScope.maybeOf(context);
  if (captureSession != null) {
    if (!identical(captureSession.book, book)) {
      throw const NotebookException('录音资料库与当前页面不一致，请重新打开应用。');
    }
    final result = await openNativeRecorder(
      context,
      captureSession,
      query: query,
      parentId: parentId,
    );
    if (result is Record) onSaved?.call();
    return result;
  }
  if (book.captureActive) return null;
  final result = await showModalBottomSheet<Object?>(
    context: context,
    sheetAnimationStyle: PlatformControls.animationStyle(context),
    isDismissible: false,
    enableDrag: false,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _Recorder(
      book: book,
      models: models,
      parentId: parentId,
      query: query,
      microphone: microphone,
    ),
  );
  if (result == _RecorderAction.write) {
    if (context.mounted) {
      await openEditor(context, book, parentId: parentId, onSaved: onSaved);
    }
    return null;
  }
  if (result is Record) onSaved?.call();
  return result;
}

class _Recorder extends StatefulWidget {
  const _Recorder({
    required this.book,
    this.models,
    this.parentId,
    this.query = false,
    this.microphone,
  });
  final Notebook book;
  final LocalModels? models;
  final String? parentId;
  final bool query;
  final MicrophoneInput? microphone;
  @override
  State<_Recorder> createState() => _RecorderState();
}

class _RecorderState extends State<_Recorder> {
  late final capture = CaptureController(
    widget.book,
    models: widget.models,
    parentId: widget.parentId,
    query: widget.query,
    microphone: widget.microphone,
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
    if ((capture.state == 'recording' || capture.draft != null) &&
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
  Widget build(BuildContext context) {
    final status = switch (capture.state) {
      'recording' => '正在录音',
      'saving' => widget.query ? '正在本地识别查询' : '正在保存音频',
      'failed' => widget.query ? '查询未完成' : '录音未保存',
      _ => '正在准备麦克风',
    };
    return PopScope(
      canPop: !capture.active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) notice(context, '请先停止保存或选择丢弃。');
      },
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          widget.query ? '说出要找的内容' : status,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: capture.state == 'saving' ? null : cancel,
                      tooltip: '丢弃并关闭',
                      icon: Icon(
                        Icons.close_rounded,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ],
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.query ? '仅用于这次查找，不会成为记录' : '最长 2 分钟，到时自动停止保存',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                const SizedBox(height: 28),
                Icon(
                  capture.state == 'failed'
                      ? Icons.mic_off_outlined
                      : Icons.mic_none_rounded,
                  size: 42,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Semantics(
                  label: '录音时长 ${durationText(capture.elapsed)}',
                  excludeSemantics: true,
                  child: Text(
                    durationText(capture.elapsed),
                    style: Theme.of(context).textTheme.headlineMedium!.copyWith(
                      fontSize: 48,
                      fontWeight: FontWeight.w400,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (capture.state == 'recording') ...[
                  const SizedBox(height: 20),
                  SizedBox(
                    width: 180,
                    child: Semantics(
                      label: '实时麦克风音量',
                      child: LinearProgressIndicator(
                        value: capture.amplitude,
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    widget.query ? '说出你记得的内容，识别后可以修改' : '说完点停止，保存后再转写',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
                if (widget.query) ...[
                  const SizedBox(height: 12),
                  Text(
                    '结束后删除查询音频',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
                if (capture.error != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(capture.error!, textAlign: TextAlign.center),
                  ),
                ],
                const SizedBox(height: 28),
                if (capture.state == 'recording') ...[
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: capture.finish,
                      icon: const Icon(Icons.stop_rounded),
                      label: Text(widget.query ? '停止并查看文字' : '停止并保存'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: cancel,
                    child: Text(widget.query ? '取消查找' : '取消录音'),
                  ),
                ],
                if (capture.state == 'failed')
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    alignment: WrapAlignment.center,
                    children: [
                      if (!widget.query && capture.draft == null)
                        FilledButton.icon(
                          onPressed: () =>
                              Navigator.pop(context, _RecorderAction.write),
                          icon: const Icon(Icons.edit_outlined),
                          label: Text(widget.parentId == null ? '写文字' : '追加文字'),
                        ),
                      if (capture.draft != null && !widget.query)
                        FilledButton(
                          onPressed: capture.retry,
                          child: const Text('重试保存'),
                        ),
                      OutlinedButton(
                        onPressed: cancel,
                        child: Text(capture.draft == null ? '关闭' : '丢弃片段'),
                      ),
                    ],
                  ),
                if (capture.state == 'saving' || capture.state == 'starting')
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
