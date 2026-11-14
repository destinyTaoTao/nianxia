import 'package:flutter/material.dart';

import '../platform/appearance.dart';

class AppearanceScope extends InheritedWidget {
  const AppearanceScope({
    super.key,
    required this.appearance,
    required super.child,
  });
  final PlatformAppearance appearance;
  static PlatformAppearance of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppearanceScope>()
          ?.appearance ??
      const PlatformAppearance();
  @override
  bool updateShouldNotify(AppearanceScope oldWidget) =>
      appearance != oldWidget.appearance;
}

abstract final class PlatformControls {
  static bool reduceMotion(BuildContext context) =>
      AppearanceScope.of(context).reduceMotion ||
      MediaQuery.maybeOf(context)?.disableAnimations == true;
  static AnimationStyle? animationStyle(BuildContext context) =>
      reduceMotion(context) ? AnimationStyle.noAnimation : null;
  // Both platforms retain the same actions and semantics. Native iOS glass is
  // gated until a real SDK prototype passes layering/keyboard/touch/perf checks.
  static Widget operationSurface(BuildContext context, Widget child) =>
      ColoredBox(
        key: const Key('opaque-operation-surface'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: child,
      );
}

class NoPageTransitionsBuilder extends PageTransitionsBuilder {
  const NoPageTransitionsBuilder();
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
