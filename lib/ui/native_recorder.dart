import 'platform_controls.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../app/capture_session_controller.dart';
import '../domain/capture_session.dart';
import 'common.dart';

class NativeCaptureScope extends InheritedWidget {
  const NativeCaptureScope({
    super.key,
    required this.capture,
    required super.child,
  });
  final CaptureSessionController? capture;
  static CaptureSessionController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<NativeCaptureScope>()?.capture;
  @override
  bool updateShouldNotify(NativeCaptureScope oldWidget) =>
      oldWidget.capture != capture;
}

Future<Object?> openNativeRecorder(
  BuildContext context,
  CaptureSessionController capture, {
  bool query = false,
  String? parentId,
}) async {
  try {
    final mode = query ? CaptureMode.query : CaptureMode.record;
    final value = await capture.start(mode: mode, parentId: parentId);
    if (!context.mounted) return null;
    if (value.request.mode != mode || value.request.parentId != parentId) {
      notice(context, '请先处理已有录音，再发起新的查询或追加。');
      return null;
    }
    return await showModalBottomSheet<Object?>(
      context: context,
      sheetAnimationStyle: PlatformControls.animationStyle(context),
      isDismissible: false,
      enableDrag: false,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => NativeRecorderPanel(
        capture: capture,
        sessionId: value.sessionId,
        query: query,
      ),
    );
  } catch (e) {
    if (context.mounted) notice(context, userError(e));
    return null;
  }
}

/// The page observes the process owner; collapsing never disposes/cancels it.
class NativeRecorderPanel extends StatefulWidget {
  const NativeRecorderPanel({
    super.key,
    required this.capture,
    required this.sessionId,
    this.query = false,
    this.onClose,
  });
  final CaptureSessionController capture;
  final String sessionId;
  final bool query;
  final Future<void> Function(Object? result)? onClose;
  @override
  State<NativeRecorderPanel> createState() => _NativeRecorderPanelState();
}

class _NativeRecorderPanelState extends State<NativeRecorderPanel>
    with WidgetsBindingObserver {
  bool busy = false, closed = false;
  String? error;
  CaptureSnapshot? get value =>
      widget.capture.snapshot?.sessionId == widget.sessionId
      ? widget.capture.snapshot
      : null;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.capture.addListener(update);
  }

  void update() {
    if (!mounted || closed) return;
    if (widget.capture.savedId == widget.sessionId && !widget.query) {
      closed = true;
      unawaited(() async {
        try {
          final record = await widget.capture.book.get(widget.sessionId);
          await completeClose(record);
        } catch (_) {
          if (mounted) {
            setState(() {
              closed = false;
              error = '记录已保存，暂时无法返回，请重试。';
            });
          }
        }
      }());
      return;
    }
    if (value?.phase == NativeCapturePhase.cancelled) {
      close();
      return;
    }
    setState(() {});
  }

  void close([Object? result]) {
    if (!mounted || closed) return;
    closed = true;
    unawaited(completeClose(result));
  }

  Future<void> completeClose(Object? result) async {
    if (!mounted) return;
    try {
      if (widget.onClose != null) {
        await widget.onClose!(result);
      } else {
        Navigator.pop(context, result);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          closed = false;
          error = '无法返回，请稍后重试。录音状态保持不变。';
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (widget.query &&
        state != AppLifecycleState.resumed &&
        value != null &&
        {
          NativeCapturePhase.starting,
          NativeCapturePhase.recording,
        }.contains(value!.phase)) {
      // Stop acquisition immediately; recognition is a later foreground action.
      unawaited(
        widget.capture.stop(expectedSessionId: widget.sessionId).catchError((
          Object e,
        ) {
          if (mounted && !closed) setState(() => error = userError(e));
        }),
      );
    }
  }

  Future<void> finish() async {
    if (busy || closed) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.capture.stop(expectedSessionId: widget.sessionId);
      if (widget.query) {
        if (closed || !mounted) {
          await widget.capture.discard(sessionId: widget.sessionId);
          return;
        }
        final query = await widget.capture.finishQuery(
          expectedSessionId: widget.sessionId,
        );
        if (mounted) close(query);
      } else {
        update();
      }
    } catch (e) {
      if (mounted && !closed) setState(() => error = userError(e));
    } finally {
      if (mounted && !closed) setState(() => busy = false);
    }
  }

  Future<void> standalone() async {
    if (busy ||
        !await confirm(
          context,
          '保存为独立记录？',
          '此操作将保留音频，不再追加到原记录。',
          action: '保存为独立记录',
        ) ||
        !mounted) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.capture.saveStandalone(expectedSessionId: widget.sessionId);
      update();
    } catch (e) {
      if (mounted && !closed) setState(() => error = userError(e));
    } finally {
      if (mounted && !closed) setState(() => busy = false);
    }
  }

  Future<void> discard() async {
    if (busy && !widget.query) return;
    if (!await confirm(
          context,
          widget.query ? '取消本次查询？' : '丢弃这段录音？',
          widget.query
              ? (busy ? '不会产生记录。本地识别结束后会清理临时音频。' : '临时查询音频将删除，不会成为记录。')
              : '尚未保存的音频将删除。',
          action: '确认丢弃',
        ) ||
        !mounted) {
      return;
    }
    if (widget.query && busy) {
      close();
      return;
    }
    setState(() => busy = true);
    try {
      await widget.capture.discard(sessionId: widget.sessionId);
      close();
    } catch (e) {
      if (mounted && !closed) setState(() => error = userError(e));
    } finally {
      if (mounted && !closed) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    widget.capture.removeListener(update);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = value;
    final phase = current?.phase;
    final recording = phase == NativeCapturePhase.recording;
    final finalized = phase == NativeCapturePhase.finalized;
    final status = widget.capture.savedId == widget.sessionId
        ? '音频已保存'
        : busy || phase == NativeCapturePhase.finalizing
        ? (widget.query ? '正在本地识别查询' : '正在保存音频')
        : recording
        ? '正在录音'
        : finalized
        ? (widget.query ? '录音已结束，等待识别' : '录音已结束，尚未保存')
        : phase == NativeCapturePhase.failed
        ? '录音未完成'
        : '正在准备麦克风';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (widget.query) {
            discard();
          } else if (!busy) {
            close();
          }
        }
      },
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
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
                    if (!widget.query)
                      TextButton.icon(
                        onPressed: busy ? null : () => close(),
                        icon: const Icon(Icons.expand_more_rounded),
                        label: const Text('收起'),
                      ),
                  ],
                ),
                Text(
                  widget.query ? '只用于这次查找，不会成为记录' : '最长 2 分钟，到时自动停止保存',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 28),
                Icon(
                  recording ? Icons.mic_none_rounded : Icons.mic_off_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  durationText(current?.elapsedMs ?? 0),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 48,
                    fontWeight: FontWeight.w400,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 24),
                if (recording) ...[
                  Text('麦克风音量', style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(height: 12),
                  Semantics(
                    label: '实时麦克风音量',
                    child: LinearProgressIndicator(
                      value: current!.level,
                      minHeight: 5,
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
                const Divider(),
                const SizedBox(height: 12),
                Text(
                  widget.query
                      ? '切后台或锁屏会结束采集，返回后再识别和确认查找。'
                      : '收起后继续录音\n停止后先保存，再转写',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if ((current?.elapsedMs ?? 0) >= 105000)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text('即将达到两分钟，录音将自动结束。'),
                  ),
                if (error != null || widget.capture.lastError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(error ?? widget.capture.lastError!),
                    ),
                  ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: busy ? null : finish,
                  icon: const Icon(Icons.stop_rounded),
                  label: Text(
                    busy
                        ? (widget.query ? '识别中' : '保存中')
                        : widget.query
                        ? (finalized ? '识别查询' : '结束并识别')
                        : finalized
                        ? '重试保存'
                        : '停止并保存',
                  ),
                ),
                if (!widget.query &&
                    finalized &&
                    current?.request.parentId != null)
                  OutlinedButton(
                    onPressed: busy ? null : standalone,
                    child: const Text('保存为独立记录'),
                  ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: busy && !widget.query ? null : discard,
                  child: Text(widget.query ? '取消本次查询' : '丢弃这段录音'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NativeCaptureBar extends StatefulWidget {
  const NativeCaptureBar({
    super.key,
    required this.capture,
    required this.onOpen,
  });
  final CaptureSessionController capture;
  final VoidCallback onOpen;
  @override
  State<NativeCaptureBar> createState() => _NativeCaptureBarState();
}

class _NativeCaptureBarState extends State<NativeCaptureBar> {
  bool busy = false;
  Future<void> stop() async {
    if (busy) return;
    final id = widget.capture.snapshot?.sessionId;
    if (id == null) return;
    setState(() => busy = true);
    try {
      await widget.capture.stop(expectedSessionId: id);
    } catch (e) {
      if (mounted) notice(context, userError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.capture.snapshot;
    return BottomActions(
      primary: Material(
        color: Theme.of(context).colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  key: const Key('capture-return'),
                  onPressed: busy ? null : widget.onOpen,
                  icon: const Icon(Icons.mic_none_rounded),
                  label: Text(
                    '${widget.capture.book.captureActive ? '录音中' : '尚未保存'} ${durationText(value?.elapsedMs ?? 0)}',
                  ),
                ),
              ),
              IconButton(
                tooltip: '停止并保存',
                onPressed: busy ? null : stop,
                icon: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop_circle_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
