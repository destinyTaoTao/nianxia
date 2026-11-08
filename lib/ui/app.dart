import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app/notebook.dart';
import '../platform/local_models.dart';
import 'theme.dart';
import 'home.dart';

class NianxiaApp extends StatefulWidget {
  const NianxiaApp({
    super.key,
    required this.book,
    this.models,
    this.shortcut,
    this.fontFamily,
    this.initialTheme = ThemeMode.system,
  });
  final Notebook book;
  final LocalModels? models;
  final ValueNotifier<String?>? shortcut;
  final String? fontFamily;
  final ThemeMode initialTheme;
  @override
  State<NianxiaApp> createState() => _NianxiaAppState();
}

class _NianxiaAppState extends State<NianxiaApp> {
  late ThemeMode mode = widget.initialTheme;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '念下',
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
    home: HomePage(
      book: widget.book,
      models: widget.models,
      shortcut: widget.shortcut,
      themeMode: mode,
      onTheme: (v) => setState(() => mode = v),
    ),
  );
}
