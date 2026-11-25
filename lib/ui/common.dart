import 'package:flutter/material.dart';

import '../domain/record.dart';
import 'platform_controls.dart';

void notice(BuildContext context, String text) {
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

/// Completes the route that accepted an operation. A page or dialog opened
/// above it while the operation was pending must stay open.
void completeOwnedRoute<T>(
  NavigatorState navigator,
  Route<T>? route, [
  T? result,
]) {
  if (!navigator.mounted ||
      route == null ||
      !route.isActive ||
      route.navigator != navigator) {
    return;
  }
  if (route.isCurrent) {
    navigator.pop<T>(result);
  } else {
    navigator.removeRoute<T>(route, result);
  }
}

String userError(Object error) =>
    error is NotebookException ? error.message : '操作失败，请检查权限、可用空间后重试。原有内容保持不变。';
String recordDate(Record r) {
  final d = r.recordedLocal;
  return '${d.year}年${d.month}月${d.day}日 ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String durationText(int ms) {
  final s = ms ~/ 1000;
  return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
}

/// One quiet, accessible deadline warning for both recording owners and all
/// entry gestures. It never claims that a pending save has completed.
class CaptureLimitHint extends StatelessWidget {
  const CaptureLimitHint({
    super.key,
    required this.elapsedMs,
    required this.recording,
  });
  final int elapsedMs;
  final bool recording;
  @override
  Widget build(BuildContext context) {
    if (!recording || elapsedMs < 105000) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: const Text('即将达到两分钟，录音将自动结束。', textAlign: TextAlign.center),
      ),
    );
  }
}

class ReadingWidth extends StatelessWidget {
  const ReadingWidth({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: child,
    ),
  );
}

/// A shared quiet surface for related controls or a piece of note content.
class PaperSurface extends StatelessWidget {
  const PaperSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  @override
  Widget build(BuildContext context) => Material(
    // Match the immediate app theme, including inherited body text colors.
    animationDuration: Duration.zero,
    color: Theme.of(context).colorScheme.surface,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

/// Keeps the main actions reachable while the page content scrolls.
class BottomActions extends StatelessWidget {
  const BottomActions({super.key, required this.primary, this.secondary});
  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) => PlatformControls.operationSurface(
    context,
    SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: ReadingWidth(
        child: MediaQuery.textScalerOf(context).scale(16) > 22
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  primary,
                  if (secondary != null) ...[
                    const SizedBox(height: 10),
                    secondary!,
                  ],
                ],
              )
            : Row(
                children: [
                  Expanded(flex: 5, child: primary),
                  if (secondary != null) ...[
                    const SizedBox(width: 12),
                    Expanded(flex: 4, child: secondary!),
                  ],
                ],
              ),
      ),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.detail,
    this.icon = Icons.notes_rounded,
    this.action,
  });
  final String title, detail;
  final IconData icon;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 40,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 24),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 16), action!],
        ],
      ),
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '确认',
  ValueChanged<ModalRoute<bool>>? onRoute,
}) async =>
    await showDialog<bool>(
      context: context,
      animationStyle: PlatformControls.animationStyle(context),
      builder: (context) {
        final route = ModalRoute.of<bool>(context);
        if (route != null) onRoute?.call(route);
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        );
      },
    ) ??
    false;
