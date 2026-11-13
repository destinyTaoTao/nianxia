import 'package:flutter/services.dart';

/// Models the external native endpoint; invariants of the real owner are tested
/// in its native suite, not inferred from this test double.
class ControlledNativeCaptureEndpoint {
  Map<String, Object?>? active;
  List<Object?>? pendingReply;
  bool claimed = false;
  final calls = <MethodCall>[];

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'start':
        active ??= {
          ...Map<String, Object?>.from(call.arguments as Map),
          'phase': 'recording',
          'sequence': 1,
          'elapsedMs': 0,
          'pcmBytes': 0,
          'level': 0.0,
        };
        return active;
      case 'current':
        return active;
      case 'pending':
        return pendingReply ?? [];
      case 'stop':
        active = {
          ...active!,
          'phase': 'finalized',
          'sequence': 2,
          'elapsedMs': 2,
          'pcmBytes': 64,
          'relativeAudioName': '${active!['sessionId']}.wav',
        };
        return active;
      case 'claim':
        claimed = true;
        return active;
      case 'cancel':
        if (claimed) {
          throw PlatformException(
            code: 'capture_claimed',
            message: 'private-path-sentinel',
          );
        }
        return null;
      case 'acknowledge':
        return null;
      default:
        throw MissingPluginException();
    }
  }
}
