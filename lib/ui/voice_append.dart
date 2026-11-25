import 'package:flutter/material.dart';

import 'common.dart';

import '../app/capture_session_controller.dart';
import '../app/notebook.dart';
import '../platform/capture_controller.dart';
import '../platform/local_models.dart';
import 'hold_recorder.dart';
import 'native_recorder.dart';
import 'platform_controls.dart';
import 'recorder.dart';
import 'recovery.dart';

Future<Record?> openVoiceAppend(
  BuildContext context,
  Notebook book,
  Record parent, {
  LocalModels? models,
}) {
  final native = NativeCaptureScope.maybeOf(context);
  final microphone = NativeCaptureScope.microphoneOf(context);
  return showModalBottomSheet<Record>(
    context: context,
    sheetAnimationStyle: PlatformControls.animationStyle(context),
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => _VoiceAppend(
      book: book,
      parent: parent,
      models: models,
      native: native,
      microphone: microphone,
    ),
  );
}

class _VoiceAppend extends StatefulWidget {
  const _VoiceAppend({
    required this.book,
    required this.parent,
    this.models,
    this.native,
    this.microphone,
  });
  final Notebook book;
  final Record parent;
  final LocalModels? models;
  final CaptureSessionController? native;
  final MicrophoneInput? microphone;
  @override
  State<_VoiceAppend> createState() => _VoiceAppendState();
}

class _VoiceAppendState extends State<_VoiceAppend> {
  bool active = false, pointBusy = false, closing = false;
  void close([Record? record]) {
    if (!mounted || closing) return;
    final route = ModalRoute.of<Record>(context);
    if (route == null || !route.isActive) return;
    closing = true;
    final navigator = Navigator.of(context);
    completeOwnedRoute<Record>(navigator, route, record);
  }

  Future<void> pointRecord() async {
    if (active || pointBusy || closing) return;
    setState(() => pointBusy = true);
    try {
      final result = await openRecorder(
        context,
        widget.book,
        widget.models,
        parentId: widget.parent.id,
        parentTitle: widget.parent.title,
        captureSession: widget.native,
        microphone: widget.microphone,
      );
      if (result is Record && mounted) close(result);
    } finally {
      if (mounted && !closing) setState(() => pointBusy = false);
    }
  }

  Future<void> recover(String id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            RecoveryScreen(book: widget.book, captureSession: widget.native),
      ),
    );
    if (!mounted || closing) return;
    final saved = await widget.book.get(id);
    if (saved != null && mounted) close(saved);
  }

  @override
  Widget build(BuildContext context) => PopScope<Record>(
    canPop: !active && !pointBusy,
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) closing = true;
    },
    child: SafeArea(
      key: const Key('voice-append-panel'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .85,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '接着说',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: active || pointBusy ? null : () => close(),
                    tooltip: '关闭语音追加',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              Text(
                '追加到：${widget.parent.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: MediaQuery.textScalerOf(context).scale(16) > 22
                            ? 260
                            : 160,
                      ),
                      IgnorePointer(
                        ignoring: pointBusy,
                        child: HoldRecorder(
                          book: widget.book,
                          models: widget.models,
                          native: widget.native,
                          microphone: widget.microphone,
                          parentId: widget.parent.id,
                          onTapRecord: pointRecord,
                          onSaved: () {},
                          onSavedRecord: close,
                          onActive: (value) {
                            if (mounted && !closing) {
                              setState(() => active = value);
                            }
                          },
                          onRecovery: () => close(),
                          onRecoveryId: recover,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
