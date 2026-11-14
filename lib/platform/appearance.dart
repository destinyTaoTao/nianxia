import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

@immutable
class PlatformAppearance {
  const PlatformAppearance({
    this.reduceMotion = false,
    this.reduceTransparency = true,
    this.increaseContrast = false,
    this.glassSupported = false,
  });
  final bool reduceMotion, reduceTransparency, increaseContrast, glassSupported;
  bool get allowsGlass =>
      glassSupported && !reduceTransparency && !increaseContrast;
  static PlatformAppearance? fromMap(Object? data) {
    if (data is! Map ||
        [
          'reduceMotion',
          'reduceTransparency',
          'increaseContrast',
          'glassSupported',
        ].any((key) => data[key] is! bool)) {
      return null;
    }
    return PlatformAppearance(
      reduceMotion: data['reduceMotion'] as bool,
      reduceTransparency: data['reduceTransparency'] as bool,
      increaseContrast: data['increaseContrast'] as bool,
      // No native glass renderer has passed the platform prototype gate.
      glassSupported: false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlatformAppearance &&
      reduceMotion == other.reduceMotion &&
      reduceTransparency == other.reduceTransparency &&
      increaseContrast == other.increaseContrast &&
      glassSupported == other.glassSupported;
  @override
  int get hashCode => Object.hash(
    reduceMotion,
    reduceTransparency,
    increaseContrast,
    glassSupported,
  );
}

/// Preferences are optional presentation input, never a prerequisite for data.
class PlatformAppearanceAdapter extends ChangeNotifier
    with WidgetsBindingObserver {
  PlatformAppearanceAdapter({TargetPlatform? platform, MethodChannel? channel})
    : platform = platform ?? defaultTargetPlatform,
      channel = channel ?? const MethodChannel('app.nianxia/appearance');
  final TargetPlatform platform;
  final MethodChannel channel;
  PlatformAppearance _value = const PlatformAppearance();
  PlatformAppearance get value => _value;
  bool _started = false, _disposed = false;
  int _revision = 0;
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    if (platform == TargetPlatform.iOS) {
      channel.setMethodCallHandler((call) async {
        if (!_disposed && call.method == 'changed') {
          _revision++;
          final next = PlatformAppearance.fromMap(call.arguments);
          if (next != null) _set(next);
        }
      });
    }
    await refresh();
  }

  void _set(PlatformAppearance next) {
    if (_disposed || next == value) return;
    _value = next;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (_disposed) return;
    if (platform != TargetPlatform.iOS) {
      final features =
          WidgetsBinding.instance.platformDispatcher.accessibilityFeatures;
      _set(
        PlatformAppearance(
          reduceMotion: features.disableAnimations,
          increaseContrast: features.highContrast,
        ),
      );
      return;
    }
    final revision = ++_revision;
    try {
      final next = PlatformAppearance.fromMap(
        await channel.invokeMethod<Object?>('current'),
      );
      if (!_disposed && revision == _revision && next != null) _set(next);
    } catch (_) {
      // Retain conservative opaque rendering and framework accessibility input.
    }
  }

  @override
  void didChangeAccessibilityFeatures() {
    refresh();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _revision++;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
      if (platform == TargetPlatform.iOS) channel.setMethodCallHandler(null);
    }
    super.dispose();
  }
}
