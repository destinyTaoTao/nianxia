import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class SimulatedAudioDevice {
  bool playing = false, disposed = false;
  double volume = 1;
  int position = 0;
}

/// Device-boundary fixture for the pinned just_audio method-channel protocol.
/// Runs the actual AudioPlayer, including its local flags and error handling.
class JustAudioDeviceFixture {
  final devices = <String, SimulatedAudioDevice>{};
  final channels = <String>{};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  bool failPause = false, failMute = false, failDispose = false;
  int pauseRequests = 0, muteRequests = 0;
  bool get audible =>
      devices.values.any((v) => v.playing && !v.disposed && v.volume > 0);
  void handler(String name, Future<Object?> Function(MethodCall)? callback) {
    channels.add(name);
    messenger.setMockMethodCallHandler(MethodChannel(name), callback);
  }

  void bind() {
    handler('com.ryanheise.audio_session', (_) async => null);
    handler(
      'com.ryanheise.android_audio_manager',
      (call) async => call.method == 'getDevices' ? <Object?>[] : true,
    );
    handler('com.ryanheise.just_audio.methods', (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'init') {
        final id = args['id'] as String;
        final device = devices[id] = SimulatedAudioDevice();
        handler('com.ryanheise.just_audio.events.$id', (_) async => null);
        handler('com.ryanheise.just_audio.data.$id', (_) async => null);
        handler('com.ryanheise.just_audio.methods.$id', (method) async {
          final values = (method.arguments as Map?) ?? {};
          switch (method.method) {
            case 'load':
              emit(id, device);
              return {'duration': 1000000};
            case 'play':
              device.playing = true;
              return {};
            case 'pause':
              pauseRequests++;
              if (failPause) throw PlatformException(code: 'pause-unavailable');
              device.playing = false;
              return {};
            case 'setVolume':
              final volume = (values['volume'] as num).toDouble();
              if (volume == 0) {
                muteRequests++;
                if (failMute) throw PlatformException(code: 'mute-unavailable');
              }
              device.volume = volume;
              return {};
            case 'seek':
              device.position = values['position'] as int? ?? 0;
              emit(id, device);
              return {};
            case 'dispose':
              if (failDispose) {
                throw PlatformException(code: 'dispose-unavailable');
              }
              device.disposed = true;
              device.playing = false;
              return {};
            default:
              return {};
          }
        });
        return null;
      }
      if (call.method == 'disposePlayer' ||
          call.method == 'disposeAllPlayers') {
        if (failDispose) throw PlatformException(code: 'dispose-unavailable');
        for (final entry in devices.entries) {
          if (call.method == 'disposeAllPlayers' || entry.key == args['id']) {
            entry.value.disposed = true;
            entry.value.playing = false;
          }
        }
        return {};
      }
      return {};
    });
  }

  void emit(String id, SimulatedAudioDevice value) {
    ui.channelBuffers.push(
      'com.ryanheise.just_audio.events.$id',
      const StandardMethodCodec().encodeSuccessEnvelope({
        'processingState': 3,
        'updateTime': DateTime.now().millisecondsSinceEpoch,
        'updatePosition': value.position,
        'bufferedPosition': 1000000,
        'duration': 1000000,
        'currentIndex': 0,
      }),
      (_) {},
    );
  }

  void allowStops() {
    failPause = failMute = failDispose = false;
  }

  void unbind() {
    allowStops();
    for (final name in channels) {
      messenger.setMockMethodCallHandler(MethodChannel(name), null);
    }
  }
}
