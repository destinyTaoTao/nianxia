import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/notebook.dart';
import '../app/backup.dart';
import '../app/diagnostics.dart';
import '../app/capture_session_controller.dart';
import '../platform/local_models.dart';
import '../platform/capture_controller.dart';
import 'capsule.dart';
import 'theme.dart';
import 'home.dart';
import 'editor.dart';
import 'native_recorder.dart';
import '../platform/appearance.dart';
import 'platform_controls.dart';

import 'dart:async';

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
    this.initialTheme = ThemeMode.dark,
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
    appearance.addListener(appearanceChanged);
    unawaited(appearance.start());
    WidgetsBinding.instance.addObserver(this);
    if (capsule) widget.shortcut!.value = null;
    widget.shortcut?.addListener(externalAction);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
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
      if (widget.book.captureActive) return;
      setState(() => capsule = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.shortcut!.value = 'search';
      });
      return;
    }
    if (action != 'capsule' && action != 'home') return;
    widget.shortcut!.value = null;
    // One notebook and one microphone session, including repeated hardware keys.
    if (widget.book.captureActive || capsule && action == 'capsule') return;
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
    themeAnimationDuration:
        appearance.value.reduceMotion ||
            WidgetsBinding
                .instance
                .platformDispatcher
                .accessibilityFeatures
                .disableAnimations
        ? Duration.zero
        : const Duration(milliseconds: 180),
    // Keep unsaved editors and their navigation stack while hiding the library.
    // Capsule confirmations use their own Navigator above the hidden pages.
    builder: (context, child) => AppearanceScope(
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
    ),
  );
}
