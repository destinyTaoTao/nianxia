import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/notebook.dart';
import '../app/backup.dart';
import '../app/diagnostics.dart';
import '../app/capture_session_controller.dart';
import '../platform/local_models.dart';
import '../platform/capture_controller.dart';
import '../platform/capture_device_fence.dart';
import 'capsule.dart';
import 'theme.dart';
import 'home.dart';
import 'editor.dart';
import 'native_recorder.dart';
import '../platform/appearance.dart';
import 'platform_controls.dart';

import 'dart:async';

import '../platform/playback_coordinator.dart';

class NianxiaApp extends StatefulWidget {
  const NianxiaApp({
    super.key,
    required this.book,
    this.models,
    this.captureSession,
    this.appearanceAdapter,
    this.backupService,
    this.diagnostics,
    this.startupNotice,
    this.shortcut,
    this.fontFamily,
    this.initialTheme = ThemeMode.system,
    this.captureMicrophone,
    this.onCapsuleReturn,
  });
  final Notebook book;
  final LocalModels? models;
  final CaptureSessionController? captureSession;
  final PlatformAppearanceAdapter? appearanceAdapter;
  final BackupService? backupService;
  final LocalDiagnostics? diagnostics;
  final String? startupNotice;
  final ValueNotifier<String?>? shortcut;
  final String? fontFamily;
  final ThemeMode initialTheme;
  final MicrophoneInput? captureMicrophone;
  final Future<void> Function()? onCapsuleReturn;
  @override
  State<NianxiaApp> createState() => _NianxiaAppState();
}

class _NianxiaAppState extends State<NianxiaApp> with WidgetsBindingObserver {
  late ThemeMode mode =
      ThemeMode.values
          .where((value) => value.name == widget.book.themeMode)
          .firstOrNull ??
      widget.initialTheme;
  late bool capsule = widget.shortcut?.value == 'capsule';
  late final appearance =
      widget.appearanceAdapter ?? PlatformAppearanceAdapter();
  void appearanceChanged() {
    if (mounted) setState(() {});
  }

  late PlaybackCoordinator playback;
  final navigator = GlobalKey<NavigatorState>();
  final capsuleNavigator = GlobalKey<NavigatorState>();
  Future<bool> changeTheme(ThemeMode value) async {
    try {
      await widget.book.saveThemeMode(value.name);
      if (!mounted) return false;
      setState(() => mode = value);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    playback = PlaybackCoordinator.retain(
      widget.book,
      diagnostics: widget.diagnostics,
    );
    appearance.addListener(appearanceChanged);
    unawaited(appearance.start());
    WidgetsBinding.instance.addObserver(this);
    if (capsule) widget.shortcut!.value = null;
    widget.shortcut?.addListener(externalAction);
  }

  @override
  void didUpdateWidget(covariant NianxiaApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book) {
      final previous = playback;
      unawaited(previous.stop().catchError((Object _) {}));
      unawaited(previous.release().catchError((Object _) {}));
      playback = PlaybackCoordinator.retain(
        widget.book,
        diagnostics: widget.diagnostics,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      unawaited(playback.stop().catchError((Object _) {}));
    }
    final capture = widget.captureSession;
    if (state == AppLifecycleState.resumed && capture != null) {
      unawaited(
        capture.reconnect().catchError((Object _) {
          /* Pending data remains available for recovery. */
        }),
      );
    }
  }

  @override
  Future<bool> didPopRoute() async {
    if (!capsule) return false;
    await capsuleNavigator.currentState?.maybePop();
    return true;
  }

  void externalAction() {
    final action = widget.shortcut?.value;
    if (capsule && action == 'search') {
      widget.shortcut!.value = null;
      if (widget.book.captureActive && !CaptureDeviceFence.canRetryRelease) {
        return;
      }
      setState(() => capsule = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.shortcut!.value = 'search';
      });
      return;
    }
    if (action != 'capsule' && action != 'home') return;
    widget.shortcut!.value = null;
    // One notebook and one microphone session, including repeated hardware keys.
    if (widget.book.captureActive && !CaptureDeviceFence.canRetryRelease ||
        capsule && action == 'capsule') {
      return;
    }
    setState(() => capsule = action == 'capsule');
  }

  Future<void> returnFromCapsule() async {
    if (widget.onCapsuleReturn != null) {
      await widget.onCapsuleReturn!();
    } else {
      await const MethodChannel('app.nianxia/system')
          .invokeMethod<void>('dismissCapsule');
    }
    if (mounted) setState(() => capsule = false);
  }

  void writeFromCapsule() {
    setState(() => capsule = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && navigator.currentState != null) {
        openEditor(navigator.currentState!.context, widget.book);
      }
    });
  }

  @override
  void dispose() {
    unawaited(playback.release().catchError((Object _) {}));
    WidgetsBinding.instance.removeObserver(this);
    appearance.removeListener(appearanceChanged);
    if (widget.appearanceAdapter == null) appearance.dispose();
    widget.shortcut?.removeListener(externalAction);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '念下',
    navigatorKey: navigator,
    onNavigationNotification: (notification) {
      // Hidden notebook routes must not release Android's back callback while
      // the visible capsule is saving or confirming a discard.
      SystemNavigator.setFrameworkHandlesBack(
        capsule || notification.canHandlePop,
      );
      return true;
    },
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: notebookTheme(
      Brightness.light,
      fontFamily: widget.fontFamily,
      reduceMotion: appearance.value.reduceMotion,
      highContrast: appearance.value.increaseContrast,
    ),
    darkTheme: notebookTheme(
      Brightness.dark,
      fontFamily: widget.fontFamily,
      reduceMotion: appearance.value.reduceMotion,
      highContrast: appearance.value.increaseContrast,
    ),
    themeMode: mode,
    // Switch the canvas immediately; avoid whole-page mixed-color frames.
    themeAnimationDuration: Duration.zero,
    // Keep unsaved editors and their navigation stack while hiding the library.
    // Capsule confirmations use their own Navigator above the hidden pages.
    builder: (context, child) => ThemePreferenceScope(
      mode: mode,
      child: AppearanceScope(
        appearance: appearance.value,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            disableAnimations:
                MediaQuery.of(context).disableAnimations ||
                appearance.value.reduceMotion,
            highContrast:
                MediaQuery.of(context).highContrast ||
                appearance.value.increaseContrast,
          ),
          child: NativeCaptureScope(
            capture: widget.captureSession,
            microphone: widget.captureMicrophone,
            child: Stack(
              children: [
                ExcludeFocus(
                  excluding: capsule,
                  child: Offstage(offstage: capsule, child: child),
                ),
                if (capsule)
                  HeroControllerScope.none(
                    child: Navigator(
                      key: capsuleNavigator,
                      onGenerateRoute: (_) => PageRouteBuilder<void>(
                        opaque: false,
                        transitionDuration: Duration.zero,
                        reverseTransitionDuration: Duration.zero,
                        pageBuilder: (_, _, _) => CaptureCapsule(
                          book: widget.book,
                          captureSession: widget.captureSession,
                          models: widget.models,
                          microphone: widget.captureMicrophone,
                          onReturn: returnFromCapsule,
                          onWrite: writeFromCapsule,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
    home: HomePage(
      book: widget.book,
      captureSession: widget.captureSession,
      backupService: widget.backupService,
      diagnostics: widget.diagnostics,
      startupNotice: widget.startupNotice,
      models: widget.models,
      shortcut: widget.shortcut,
      themeMode: mode,
      onTheme: changeTheme,
      captureMicrophone: widget.captureMicrophone,
    ),
  );
}
