import 'package:flutter/material.dart';

import '../app/capture_session_controller.dart';
import '../app/notebook.dart';
import '../platform/capture_controller.dart';
import '../platform/capture_device_fence.dart';
import '../platform/local_models.dart';
import 'hold_recorder.dart';
import 'platform_controls.dart';
import 'recorder.dart';
import 'common.dart';

Future<String?> openVoiceQuery(
  BuildContext context,
  Notebook book,
  LocalModels? models, {
  CaptureSessionController? captureSession,
  MicrophoneInput? microphone,
}) => showModalBottomSheet<String>(
  context: context,
  sheetAnimationStyle: PlatformControls.animationStyle(context),
  isScrollControlled: true,
  useSafeArea: true,
  isDismissible: false,
  enableDrag: false,
  builder: (_) => _VoiceQuery(
    book: book,
    models: models,
    capture: captureSession,
    microphone: microphone,
  ),
);

class _VoiceQuery extends StatefulWidget {
  const _VoiceQuery({
    required this.book,
    this.models,
    this.capture,
    this.microphone,
  });
  final Notebook book;
  final LocalModels? models;
  final CaptureSessionController? capture;
  final MicrophoneInput? microphone;
  @override
  State<_VoiceQuery> createState() => _VoiceQueryState();
}

class _VoiceQueryState extends State<_VoiceQuery> with WidgetsBindingObserver {
  bool closing = false, active = false;
  Set<Route<Object?>>? pointRoutes;
  bool get current =>
      mounted &&
      !closing &&
      (ModalRoute.of(context)?.isCurrent ?? false) &&
      (WidgetsBinding.instance.lifecycleState == null ||
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void close([String? result]) {
    if (!mounted || closing) return;
    final route = ModalRoute.of<String>(context);
    if (route == null ||
        !route.isActive ||
        result != null && !route.isCurrent) {
      return;
    }
    closing = true;
    final navigator = Navigator.of(context);
    // Only the recorder and confirmations created by this query belong to it.
    // Another search page opened above them keeps its route and input intact.
    for (final child in pointRoutes?.toList().reversed ?? <Route<Object?>>[]) {
      completeOwnedRoute<Object?>(navigator, child);
    }
    completeOwnedRoute<String>(navigator, route, result);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) close();
  }

  @override
  void dispose() {
    closing = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> tapQuery() async {
    if (!current ||
        active ||
        widget.book.captureActive && !CaptureDeviceFence.canRetryRelease) {
      return;
    }
    final owned = <Route<Object?>>{};
    pointRoutes = owned;
    try {
      final result = await openRecorder(
        context,
        widget.book,
        widget.models,
        query: true,
        captureSession: widget.capture,
        microphone: widget.microphone,
        onOwnedRoute: (route) {
          owned.removeWhere((previous) => !previous.isActive);
          owned.add(route);
        },
      );
      if (current && result is String) close(result);
    } finally {
      if (identical(pointRoutes, owned)) pointRoutes = null;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) closing = true;
    },
    child: SafeArea(
      key: const Key('voice-query-panel'),
      child: SingleChildScrollView(
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
                      '说出查找线索',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: () => close(),
                    tooltip: '取消语音查询',
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '仅用于这次查找，不会成为记录。\n松手识别，文字可以修改后再查找。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 168),
              HoldRecorder(
                book: widget.book,
                models: widget.models,
                native: widget.capture,
                microphone: widget.microphone,
                query: true,
                onQuery: (value) {
                  if (current) close(value);
                },
                onTapRecord: tapQuery,
                onSaved: () {},
                onActive: (value) {
                  if (mounted && !closing) setState(() => active = value);
                },
                onRecovery: () => close(),
              ),
              TextButton(onPressed: () => close(), child: const Text('改用文字')),
            ],
          ),
        ),
      ),
    ),
  );
}
