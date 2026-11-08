import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/data/model_store.dart';
import 'package:nianxia/platform/capture_controller.dart';
import 'package:nianxia/platform/local_models.dart';

class TestMicrophone implements MicrophoneInput {
  final chunks = StreamController<Uint8List>();
  bool failStop = false;
  @override
  Future<bool> allowed() async => true;
  @override
  Future<Stream<Uint8List>> start() async => chunks.stream;
  @override
  Future<void> stop() async {
    if (failStop) {
      throw const FileSystemException('stop failure');
    }
    await chunks.close();
  }

  @override
  Future<void> cancel() async {
    if (!chunks.isClosed) {
      await chunks.close();
    }
  }

  @override
  Future<void> close() async {
    if (!chunks.isClosed) {
      await chunks.close();
    }
  }

  @override
  Stream<double> get levels => const Stream.empty();
  @override
  Stream<void> get interruptions => const Stream.empty();
}

class QueryReadyStore extends ModelStore {
  QueryReadyStore(Directory home) : super(home, []);
  @override
  Future<bool> ready(String id) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory home;
  late Notebook book;
  setUp(() async {
    home = await Directory.systemTemp.createTemp('nianxia-microphone-');
    book = await Notebook.open(home);
  });
  tearDown(() async {
    book.dispose();
    await home.delete(recursive: true);
  });
  test('两分钟采样边界自动保存，原生停止延迟不会使整段丢失', () async {
    final mic = TestMicrophone();
    final capture = CaptureController(book, microphone: mic);
    try {
      await capture.start();
      final done = Completer<void>();
      capture.addListener(() {
        if (capture.state == 'done' && !done.isCompleted) {
          done.complete();
        }
      });
      mic.chunks.add(
        Uint8List(3846400),
      ); // A final device buffer crosses the declared limit.
      await done.future.timeout(const Duration(seconds: 5));
      expect(capture.error, isNull);
      expect(book.records.single.durationMs, 120000);
      expect(await File(book.audioPath(book.records.single)).length(), 3840044);
    } finally {
      capture.dispose();
    }
  });
  test('查询原生停止失败也立即清理临时音频，不保存查询记录', () async {
    final mic = TestMicrophone()..failStop = true;
    final store = QueryReadyStore(home);
    final capture = CaptureController(
      book,
      microphone: mic,
      models: LocalModels(store),
      query: true,
    );
    try {
      await capture.start();
      mic.chunks.add(Uint8List(32000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await capture.finish();
      expect(capture.state, 'failed');
      expect(book.records, isEmpty);
      expect(await File(capture.draft!.path).exists(), isFalse);
    } finally {
      capture.dispose();
      store.dispose();
    }
  });
}
