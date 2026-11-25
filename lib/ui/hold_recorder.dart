import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/notebook.dart';
import '../app/capture_session_controller.dart';
import '../domain/capture_session.dart';
import '../platform/capture_controller.dart';
import '../platform/capture_device_fence.dart';
import '../platform/local_models.dart';
import 'common.dart';

/// Owns pointer intent only. Existing capture owners retain audio and commit it.
class HoldRecorder extends StatefulWidget {
  const HoldRecorder({
    super.key,
    required this.book,
    this.models,
    this.native,
    this.microphone,
    this.query = false,
    this.parentId,
    this.onSavedRecord,
    this.onRecoveryId,
    this.onQuery,
    required this.onTapRecord,
    required this.onSaved,
    required this.onActive,
    required this.onRecovery,
  });
  final Notebook book;
  final LocalModels? models;
  final CaptureSessionController? native;
  final MicrophoneInput? microphone;
  final bool query;
  final String? parentId;
  final ValueChanged<Record>? onSavedRecord;
  final ValueChanged<String>? onRecoveryId;
  final ValueChanged<String>? onQuery;
  final VoidCallback onTapRecord, onSaved, onRecovery;
  final ValueChanged<bool> onActive;
  @override
  State<HoldRecorder> createState() => _HoldRecorderState();
}

class _HoldRecorderState extends State<HoldRecorder>
    with WidgetsBindingObserver {
  CaptureController? local;
  String? nativeId, error;
  String phase = 'idle';
  int? pointer;
  Offset origin = Offset.zero;
  bool candidate = false,
      validStart = false,
      terminal = false,
      announced = false;
  bool focused = false;
  bool resetting = false;
  bool discardRequested = false;
  bool parentMissing = false,
      checkingParent = false,
      confirmingStandalone = false;
  Record? pendingRecord;
  Future<void>? starting, nativeRecognition;
  bool get active => phase != 'idle';
  int get elapsed => local?.elapsed ?? widget.native?.snapshot?.elapsedMs ?? 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.native?.addListener(nativeChanged);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void reset() {
    if (!mounted || resetting) return;
    resetting = true;
    final old = local;
    local = null;
    old?.removeListener(localChanged);
    void complete() {
      old?.dispose();
      if (!mounted) return;
      nativeId = null;
      phase = 'idle';
      nativeRecognition = null;
      candidate = false;
      error = null;
      discardRequested = false;
      parentMissing = false;
      pendingRecord = null;
      resetting = false;
      changed();
      widget.onActive(false);
    }

    // A notifier cannot dispose itself inside its notification. Keep the input
    // locked until disposal, including multiple pointer events in one packet.
    if (old != null) {
      scheduleMicrotask(complete);
    } else {
      complete();
    }
  }

  void failed(String message) {
    if (!mounted) return;
    terminal = true;
    phase = 'failed';
    error = message;
    changed();
    if (widget.parentId != null && !checkingParent) {
      checkingParent = true;
      unawaited(() async {
        try {
          final parent = await widget.book.get(widget.parentId!);
          if (mounted && phase == 'failed') {
            parentMissing = parent == null;
            if (parentMissing) {
              error = local?.draft != null || nativeId != null
                  ? '原记录已删除，本次录音尚未保存。'
                  : '原记录已删除，本次尚未开始录音。';
            }
            changed();
          }
        } catch (_) {
          /* A failed read cannot prove that the parent is gone. */
        } finally {
          checkingParent = false;
        }
      }());
    }
  }

  void saved() {
    if (!mounted || announced) return;
    announced = true;
    terminal = true;
    phase = 'saving';
    final id = nativeId;
    final record = local?.saved;
    if (record != null) {
      completeSave(record);
    } else if (id != null) {
      unawaited(() async {
        try {
          final value = await widget.book.get(id);
          if (value == null) throw const NotebookException('已保存的记录已被移除。');
          if (mounted && nativeId == id) completeSave(value);
        } catch (e) {
          announced = false;
          failed(userError(e));
        }
      }());
    }
  }

  void deliverSaved() {
    final value = pendingRecord;
    pendingRecord = null;
    if (value != null) widget.onSavedRecord?.call(value);
  }

  void completeSave(Record record) {
    if (!mounted) return;
    pendingRecord = record;
    phase = 'done';
    widget.onSaved();
    notice(context, '音频已保存，等待转写');
    if (pointer == null) {
      deliverSaved();
      reset();
    } else {
      changed();
    }
  }

  void recognized(String value) {
    if (!mounted || announced) return;
    if (value.trim().isEmpty) {
      failed('没有识别到线索，请重说或输入文字。');
      return;
    }
    announced = true;
    terminal = true;
    phase = 'done';
    widget.onQuery?.call(value);
    if (mounted && pointer == null) reset();
  }

  void localChanged() {
    final value = local;
    if (!mounted || value == null) return;
    switch (value.state) {
      case 'recording':
        if (!terminal) phase = 'recording';
      case 'saving':
        terminal = true;
        phase = 'saving';
      case 'done':
        if (widget.query) {
          recognized(value.queryText ?? '');
          return;
        }
        saved();
        return;
      case 'cancelled':
        if (pointer == null) reset();
        return;
      case 'failed':
        failed(value.error ?? '录音未保存，请核对待恢复资料。');
        return;
    }
    changed();
  }

  void nativeChanged() {
    final owner = widget.native;
    final value = owner?.snapshot;
    if (!mounted || nativeId == null) return;
    if (owner!.savedId == nativeId) {
      saved();
      return;
    }
    if (value == null && discardRequested) {
      reset();
      return;
    }
    if (value?.sessionId != nativeId) return;
    switch (value!.phase) {
      case NativeCapturePhase.recording:
        if (!terminal) phase = 'recording';
      case NativeCapturePhase.finalizing:
      case NativeCapturePhase.finalized:
        if (discardRequested) return;
        if (owner.lastError != null) {
          failed(owner.lastError!);
          return;
        }
        // Deadline/platform stop wins before a subsequent slide-to-cancel.
        terminal = true;
        phase = 'saving';
        if (widget.query && value.phase == NativeCapturePhase.finalized) {
          recognizeNative();
        }
      case NativeCapturePhase.failed:
        failed(owner.lastError ?? '录音未完成，请核对待恢复资料。');
      case NativeCapturePhase.cancelled:
        if (!discardRequested && pointer == null) reset();
      case NativeCapturePhase.starting:
        break;
    }
    changed();
  }

  void down(PointerDownEvent event) {
    if (event.buttons != kPrimaryButton || pointer != null || active) return;
    if (widget.book.captureActive && !CaptureDeviceFence.canRetryRelease) {
      notice(context, '请先处理当前录音。');
      return;
    }
    pointer = event.pointer;
    origin = event.position;
    validStart = true;
    terminal = false;
    announced = false;
    candidate = false;
    phase = 'starting';
    widget.onActive(true);
    changed();
    starting = start();
  }

  Future<void> start() async {
    try {
      final owner = widget.native;
      if (owner == null) {
        local = CaptureController(
          widget.book,
          models: widget.models,
          query: widget.query,
          parentId: widget.parentId,
          microphone: widget.microphone,
        );
        local!.addListener(localChanged);
        await local!.start();
      } else {
        final value = await owner.start(
          mode: widget.query ? CaptureMode.query : CaptureMode.record,
          parentId: widget.parentId,
          reuseCurrent: false,
          startAllowed: () => mounted && validStart,
        );
        nativeId = value.sessionId;
        nativeChanged();
      }
    } catch (e) {
      if (!mounted) return;
      if (!validStart && !widget.book.captureActive) {
        reset();
      } else {
        failed(widget.native?.lastError ?? userError(e));
      }
    }
  }

  void move(PointerMoveEvent event) {
    if (event.pointer != pointer || terminal || phase != 'recording') return;
    final distance = origin.dy - event.position.dy;
    final next = candidate ? distance > 40 : distance >= 64;
    if (next != candidate) {
      candidate = next;
      changed();
    }
  }

  void up(PointerUpEvent event) {
    if (pointer != event.pointer) return;
    pointer = null;
    changed();
    if (phase == 'done' || phase == 'idle') {
      if (phase == 'done') deliverSaved();
      reset();
      return;
    }
    unawaited(end(cancel: candidate));
  }

  void cancel(PointerCancelEvent event) {
    if (pointer != event.pointer) return;
    pointer = null;
    if (phase == 'done') {
      deliverSaved();
      reset();
      return;
    }
    changed();
    unawaited(end());
  }

  Future<void> end({bool cancel = false}) async {
    validStart = false;
    if (terminal) return;
    final preparing = phase == 'starting';
    discardRequested = preparing || cancel;
    terminal = true;
    phase = preparing || cancel ? 'ending' : 'saving';
    changed();
    try {
      final value = local;
      if (value != null) {
        if (preparing || cancel) {
          await value.discard();
        } else {
          await value.finish();
        }
      } else {
        await starting;
        final id = nativeId;
        if (!mounted || id == null) return;
        if (cancel && preparing == false) {
          await widget.native!.discard(sessionId: id);
          if (mounted) reset();
        } else if (!preparing) {
          await widget.native!.stop(expectedSessionId: id);
          nativeChanged();
        }
      }
    } catch (e) {
      failed(userError(e));
    }
  }

  void recognizeNative() {
    final id = nativeId;
    if (id == null || nativeRecognition != null || discardRequested) return;
    nativeRecognition = () async {
      try {
        final result = await widget.native!.finishQuery(expectedSessionId: id);
        if (mounted && nativeId == id && !discardRequested) recognized(result);
      } catch (e) {
        if (mounted && nativeId == id && !discardRequested) {
          failed(userError(e));
        }
      }
    }();
  }

  Future<void> restartQuery() async {
    if (!widget.query || phase != 'failed') return;
    discardRequested = true;
    phase = 'ending';
    changed();
    try {
      if (local != null) {
        await local!.discard();
        if (local!.state != 'cancelled') {
          failed(local!.error ?? '临时查询清理未完成，请重试。');
          return;
        }
      } else if (nativeId != null) {
        await widget.native!.discard(sessionId: nativeId);
      }
      if (mounted) reset();
    } catch (e) {
      failed('临时查询清理未完成，请重试。${userError(e)}');
    }
  }

  Future<void> retry() async {
    if (phase != 'failed') return;
    phase = discardRequested ? 'ending' : 'saving';
    changed();
    try {
      if (discardRequested) {
        if (local != null) {
          await local!.discard();
        } else if (nativeId != null) {
          await widget.native!.discard(sessionId: nativeId);
          if (mounted) reset();
        }
      } else if (local != null) {
        await local!.retry();
      } else if (nativeId != null) {
        await widget.native!.stop(expectedSessionId: nativeId);
        nativeChanged();
      }
    } catch (e) {
      failed(userError(e));
    }
  }

  Future<void> standalone() async {
    if (!parentMissing ||
        confirmingStandalone ||
        phase != 'failed' ||
        local?.draft == null && nativeId == null) {
      return;
    }
    confirmingStandalone = true;
    final accepted = await confirm(
      context,
      '保存为独立记录？',
      '原记录已不存在。本段音频将作为新的独立记录保留。',
      action: '保存为独立记录',
    );
    confirmingStandalone = false;
    if (!accepted || !mounted || phase != 'failed') return;
    phase = 'saving';
    changed();
    try {
      if (local != null) {
        await local!.retry(standalone: true);
      } else if (nativeId != null) {
        await widget.native!.saveStandalone(expectedSessionId: nativeId);
        nativeChanged();
      }
    } catch (e) {
      failed(userError(e));
    }
  }

  void interrupt() {
    if (!active) return;
    pointer = null;
    if (phase == 'done') {
      deliverSaved();
      reset();
      return;
    }
    changed();
    if (!terminal) unawaited(end(cancel: widget.query));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) interrupt();
  }

  @override
  void dispose() {
    validStart = false;
    WidgetsBinding.instance.removeObserver(this);
    widget.native?.removeListener(nativeChanged);
    final value = local;
    value?.removeListener(localChanged);
    if (value != null) {
      final ending = widget.query && value.state != 'saving'
          ? value.discard()
          : value.finish();
      unawaited(ending.catchError((Object _) {}));
      value.dispose();
    } else if (nativeId != null && widget.query) {
      unawaited(
        widget.native!.discard(sessionId: nativeId).catchError((Object _) {}),
      );
    } else if (nativeId != null && !terminal) {
      unawaited(
        widget.native!
            .stop(expectedSessionId: nativeId)
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = switch (phase) {
      'starting' => '正在准备录音…',
      'recording' =>
        candidate
            ? '松手取消，移回继续'
            : widget.query
            ? '松手识别，上滑取消'
            : widget.parentId != null
            ? '松手保存追加，上滑取消'
            : '松手保存，上滑取消',
      'saving' => widget.query ? '正在本地识别线索…' : '正在保存音频…',
      'ending' => '正在结束录音…',
      'done' => widget.query ? '识别已完成，请松手' : '音频已保存，请松手',
      _ => '录音未保存，请松手',
    };
    final buttonLabel = switch (phase) {
      'idle' =>
        widget.query
            ? '按住说出线索'
            : widget.parentId != null
            ? '按住追加'
            : '按住说话',
      'starting' => '准备中',
      'recording' =>
        candidate
            ? '松手取消'
            : widget.query
            ? '松手识别'
            : widget.parentId != null
            ? '松手保存追加'
            : '松手保存',
      'saving' => widget.query ? '识别中' : '保存中',
      'ending' => '正在结束',
      'done' => widget.query ? '已识别' : '已保存',
      _ =>
        pointer == null
            ? widget.query
                  ? '查询未完成'
                  : '录音未保存'
            : '请松手',
    };
    final destructive = candidate && phase == 'recording';
    final feedback = Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              destructive ? Icons.close_rounded : Icons.mic_rounded,
              color: destructive || phase == 'recording'
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface,
            ),
            if (phase == 'recording')
              Text(durationText(elapsed), style: theme.textTheme.titleLarge),
            Semantics(
              liveRegion: true,
              child: Text(label, textAlign: TextAlign.center),
            ),
            CaptureLimitHint(
              elapsedMs: elapsed,
              recording: phase == 'recording',
            ),
          ],
        ),
      ),
    );
    return PopScope(
      canPop: widget.query || !active,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) interrupt();
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (phase == 'failed' && pointer == null) ...[
            Semantics(
              liveRegion: true,
              child: Text(error ?? (widget.query ? '查询未完成。' : '录音未保存。')),
            ),
            Wrap(
              spacing: 8,
              children: [
                if (parentMissing &&
                    !widget.query &&
                    (local?.draft != null || nativeId != null))
                  TextButton(
                    onPressed: standalone,
                    child: const Text('保存为独立记录'),
                  ),
                if (!widget.query && (local?.draft != null || nativeId != null))
                  TextButton(
                    onPressed: retry,
                    child: Text(discardRequested ? '重试取消' : '重试保存'),
                  ),
                if (widget.query)
                  TextButton(onPressed: restartQuery, child: const Text('重说'))
                else
                  TextButton(
                    onPressed: () {
                      final hasClip = local?.draft != null || nativeId != null;
                      final id = local?.draft?.id ?? nativeId;
                      reset();
                      if (hasClip && !widget.query) {
                        if (id != null && widget.onRecoveryId != null) {
                          widget.onRecoveryId!(id);
                        } else {
                          widget.onRecovery();
                        }
                      }
                    },
                    child: Text(
                      widget.query
                          ? '重说'
                          : local?.draft != null || nativeId != null
                          ? '查看待恢复资料'
                          : '重新操作',
                    ),
                  ),
              ],
            ),
          ],
          Stack(
            clipBehavior: Clip.none,
            children: [
              Semantics(
                button: true,
                label: widget.query
                    ? '按住说出线索'
                    : widget.parentId != null
                    ? '按住追加'
                    : '按住说话',
                hint: widget.query
                    ? '松手识别，上滑取消。也可点按说出线索。'
                    : widget.parentId != null
                    ? '松手保存追加，上滑取消。也可点按追加。'
                    : '松手保存，上滑取消。也可点按录音。',
                onTap: active ? null : widget.onTapRecord,
                excludeSemantics: true,
                child: FocusableActionDetector(
                  onShowFocusHighlight: (v) => setState(() => focused = v),
                  shortcuts: const {
                    SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                    SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                  },
                  actions: {
                    ActivateIntent: CallbackAction<ActivateIntent>(
                      onInvoke: (_) {
                        if (!active) widget.onTapRecord();
                        return null;
                      },
                    ),
                  },
                  child: Listener(
                    key: Key(widget.query ? 'hold-query' : 'hold-record'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: down,
                    onPointerMove: move,
                    onPointerUp: up,
                    onPointerCancel: cancel,
                    child: Container(
                      width: double.infinity,
                      constraints: const BoxConstraints(minHeight: 58),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: destructive
                            ? theme.colorScheme.error
                            : theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(32),
                        border: focused
                            ? Border.all(
                                color: theme.colorScheme.outline,
                                width: 3,
                              )
                            : null,
                      ),
                      child: Text(
                        buttonLabel,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.titleMedium!.copyWith(
                          color: destructive
                              ? theme.colorScheme.onError
                              : theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (active && phase != 'failed')
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  child: IgnorePointer(
                    child: FractionalTranslation(
                      translation: const Offset(0, -1),
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: feedback,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          TextButton(
            onPressed: active ? null : widget.onTapRecord,
            child: Text(
              widget.query
                  ? '点按说出线索'
                  : widget.parentId != null
                  ? '点按追加'
                  : '点按录音',
            ),
          ),
        ],
      ),
    );
  }
}
