import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import '../platform/capture_controller.dart';
import 'capsule.dart';
import 'theme.dart';
import 'home.dart';
import 'editor.dart';

class NianxiaApp extends StatefulWidget {
  const NianxiaApp({
    super.key,
    required this.book,
    this.models,
    this.shortcut,
    this.fontFamily,
    this.initialTheme = ThemeMode.system,
    this.captureMicrophone,
    this.onCapsuleReturn,
  });
  final Notebook book;
  final LocalModels? models;
  final ValueNotifier<String?>? shortcut;
  final String? fontFamily;
  final ThemeMode initialTheme;
  final MicrophoneInput? captureMicrophone;
  final Future<void> Function()? onCapsuleReturn;
  @override
  State<NianxiaApp> createState() => _NianxiaAppState();
}

class _NianxiaAppState extends State<NianxiaApp> with WidgetsBindingObserver {
  late ThemeMode mode = widget.initialTheme;
  late bool capsule = widget.shortcut?.value == 'capsule';
  final navigator = GlobalKey<NavigatorState>();
  final capsuleNavigator = GlobalKey<NavigatorState>();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (capsule) widget.shortcut!.value = null;
    widget.shortcut?.addListener(externalAction);
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
    theme: notebookTheme(Brightness.light, fontFamily: widget.fontFamily),
    darkTheme: notebookTheme(Brightness.dark, fontFamily: widget.fontFamily),
    themeMode: mode,
    themeAnimationDuration:
        MediaQuery.maybeOf(context)?.disableAnimations == true
        ? Duration.zero
        : const Duration(milliseconds: 180),
    // Keep unsaved editors and their navigation stack while hiding the library.
    // Capsule confirmations use their own Navigator above the hidden pages.
    builder: (context, child) => Stack(
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
    home: HomePage(
      book: widget.book,
      models: widget.models,
      shortcut: widget.shortcut,
      themeMode: mode,
      onTheme: (v) => setState(() => mode = v),
    ),
  );
}
