import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../platform/capture_controller.dart';
import '../platform/local_models.dart';
import 'common.dart';
import 'theme.dart';
import '../app/capture_session_controller.dart';
import '../domain/capture_session.dart';
import 'native_recorder.dart';

/// System quick entry selects the app's injected recording owner.
class CaptureCapsule extends StatelessWidget {
  const CaptureCapsule({
    super.key,
    required this.book,
    this.models,
    this.microphone,
    required this.onReturn,
    required this.onWrite,
    this.captureSession,
  });
  final Notebook book;
  final LocalModels? models;
  final MicrophoneInput? microphone;
  final Future<void> Function() onReturn;
  final VoidCallback onWrite;
  final CaptureSessionController? captureSession;
  @override
  Widget build(BuildContext context) {
    final capture = captureSession;
    if (capture == null) {
      return _LegacyCaptureCapsule(
        book: book,
        models: models,
        microphone: microphone,
        onReturn: onReturn,
        onWrite: onWrite,
      );
    }
    if (!identical(capture.book, book)) {
      throw StateError('Capture source mismatch');
    }
    return _NativeCapsule(
      capture: capture,
      onReturn: onReturn,
      onWrite: onWrite,
    );
  }
}

class _NativeCapsule extends StatefulWidget {
  const _NativeCapsule({
    required this.capture,
    required this.onReturn,
    required this.onWrite,
  });
  final CaptureSessionController capture;
  final Future<void> Function() onReturn;
  final VoidCallback onWrite;
  @override
  State<_NativeCapsule> createState() => _NativeCapsuleState();
}

class _NativeCapsuleState extends State<_NativeCapsule> {
  String? id, error;
  bool returning = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final value = await widget.capture.start(mode: CaptureMode.record);
        if (mounted) setState(() => id = value.sessionId);
      } catch (e) {
        if (mounted) {
          setState(() {
            id = widget.capture.snapshot?.sessionId;
            error = userError(e);
          });
        }
      }
    });
  }

  Future<void> leave(Object? result) async {
    if (returning) return;
    setState(() => returning = true);
    try {
      await widget.onReturn();
    } catch (_) {
      if (mounted) setState(() => error = '无法返回，请稍后重试。录音状态保持不变。');
      rethrow;
    } finally {
      if (mounted) setState(() => returning = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: id == null
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(error ?? '正在准备麦克风'),
                          if (error == null) const CircularProgressIndicator(),
                          if (error != null)
                            TextButton(
                              onPressed: widget.onWrite,
                              child: const Text('写文字'),
                            ),
                          if (error != null)
                            TextButton(
                              onPressed: () async {
                                try {
                                  await leave(null);
                                } catch (_) {}
                              },
                              child: const Text('返回'),
                            ),
                        ],
                      ),
                    )
                  : NativeRecorderPanel(
                      capture: widget.capture,
                      sessionId: id!,
                      onClose: leave,
                    ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// A foreground recording surface; no overlay permission or background mic.
class _LegacyCaptureCapsule extends StatefulWidget {
  const _LegacyCaptureCapsule({
    required this.book,
    this.models,
    this.microphone,
    required this.onReturn,
    required this.onWrite,
  });
  final Notebook book;
  final LocalModels? models;
  final MicrophoneInput? microphone;
  final Future<void> Function() onReturn;
  final VoidCallback onWrite;
  @override
  State<_LegacyCaptureCapsule> createState() => _CaptureCapsuleState();
}

class _CaptureCapsuleState extends State<_LegacyCaptureCapsule> {
  late final capture = CaptureController(
    widget.book,
    models: widget.models,
    microphone: widget.microphone,
  );
  bool returning = false;
  String? returnError;
  @override
  void initState() {
    super.initState();
    capture.addListener(update);
    capture.start();
  }

  void update() {
    if (mounted) setState(() {});
  }

  Future<void> leave() async {
    if (returning || capture.active) return;
    setState(() {
      returning = true;
      returnError = null;
    });
    try {
      await widget.onReturn();
    } catch (_) {
      if (mounted) setState(() => returnError = '无法返回，请使用系统返回键。音频状态保持不变。');
    } finally {
      if (mounted) setState(() => returning = false);
    }
  }

  Future<void> discard() async {
    if (capture.state == 'recording' || capture.draft != null) {
      if (!await confirm(context, '丢弃这段录音？', '尚未保存的音频将删除。', action: '确认丢弃')) {
        return;
      }
    }
    await capture.discard();
    if (capture.state == 'cancelled') await leave();
  }

  @override
  void dispose() {
    capture.removeListener(update);
    capture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = capture.state == 'done';
    final recording = capture.state == 'recording';
    final failed = capture.state == 'failed';
    final colors = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          if (recording) {
            capture.finish();
          } else if (!capture.active) {
            leave();
          }
        }
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Material(
                  color: colors.surface,
                  elevation: 8,
                  shadowColor: Colors.black26,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(32),
                    side: BorderSide(color: colors.outlineVariant),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const NoteMark(size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  done
                                      ? '音频已保存'
                                      : recording
                                      ? '正在录音'
                                      : failed
                                      ? '录音未保存'
                                      : capture.state == 'saving'
                                      ? '正在保存音频'
                                      : '正在准备',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                            ),
                            if (recording)
                              Text(
                                durationText(capture.elapsed),
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (recording) ...[
                          Semantics(
                            label: '实时麦克风音量',
                            child: LinearProgressIndicator(
                              value: capture.amplitude,
                              minHeight: 3,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Text(
                          returnError ??
                              capture.error ??
                              (done
                                  ? '已存到本机，转写稍后完成'
                                  : recording
                                  ? '最长 2 分钟 · 返回键也会停止保存'
                                  : capture.state == 'saving'
                                  ? '正在将音频保存到本机'
                                  : '只在你主动呼出后使用麦克风'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        if (recording)
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              FilledButton.icon(
                                onPressed: capture.finish,
                                icon: const Icon(Icons.stop_rounded),
                                label: const Text('停止并保存'),
                              ),
                              TextButton(
                                onPressed: discard,
                                child: const Text('丢弃'),
                              ),
                            ],
                          )
                        else if (done || failed || capture.state == 'cancelled')
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (failed)
                                TextButton(
                                  onPressed: widget.onWrite,
                                  child: const Text('写文字'),
                                ),
                              if (failed && capture.draft != null)
                                FilledButton(
                                  onPressed: capture.retry,
                                  child: const Text('重试保存'),
                                ),
                              if (failed && capture.draft != null)
                                TextButton(
                                  onPressed: discard,
                                  child: const Text('丢弃'),
                                ),
                              TextButton(
                                onPressed: returning ? null : leave,
                                child: Text(
                                  Theme.of(context).platform ==
                                          TargetPlatform.iOS
                                      ? '完成'
                                      : '返回原应用',
                                ),
                              ),
                            ],
                          )
                        else
                          const Padding(
                            padding: EdgeInsets.all(8),
                            child: SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
