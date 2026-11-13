import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart' as ort;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../app/inference_runtime.dart';
import '../domain/record.dart';
import '../data/model_store.dart';

class BertTokenizer {
  BertTokenizer(List<String> vocab)
    : vocab = {for (var i = 0; i < vocab.length; i++) vocab[i]: i};
  final Map<String, int> vocab;
  static final _punct = RegExp(r'\p{P}', unicode: true);
  static final _control = RegExp(r'[\p{Cc}\p{Cf}]', unicode: true);
  static bool _chinese(int c) =>
      (c >= 0x4e00 && c <= 0x9fff) ||
      (c >= 0x3400 && c <= 0x4dbf) ||
      (c >= 0x20000 && c <= 0x2fa1f) ||
      (c >= 0xf900 && c <= 0xfaff);
  List<int> encode(String text, {bool special = true}) {
    final words = <String>[];
    var current = StringBuffer();
    void flush() {
      if (current.isNotEmpty) {
        words.add(current.toString());
        current = StringBuffer();
      }
    }

    for (final c in text.runes) {
      final ch = String.fromCharCode(c);
      if (c == 0 ||
          c == 0xfffd ||
          (_control.hasMatch(ch) && c != 9 && c != 10 && c != 13) ||
          (c < 32 && c != 9 && c != 10 && c != 13) ||
          (c >= 127 && c <= 159)) {
        continue;
      }
      if (RegExp(r'\s', unicode: true).hasMatch(ch)) {
        flush();
        continue;
      }
      final punctuation =
          (c >= 33 && c <= 47) ||
          (c >= 58 && c <= 64) ||
          (c >= 91 && c <= 96) ||
          (c >= 123 && c <= 126) ||
          _punct.hasMatch(ch);
      if (_chinese(c) || punctuation) {
        flush();
        words.add(ch);
      } else {
        current.write(ch);
      }
    }
    flush();
    final ids = <int>[];
    for (final word in words) {
      final chars = word.runes.map(String.fromCharCode).toList();
      if (chars.length > 100) {
        ids.add(vocab['[UNK]']!);
        continue;
      }
      final pieces = <int>[];
      var start = 0;
      var bad = false;
      while (start < chars.length) {
        var end = chars.length;
        int? found;
        while (end > start) {
          found =
              vocab['${start > 0 ? '##' : ''}${chars.sublist(start, end).join()}'];
          if (found != null) {
            break;
          }
          end--;
        }
        if (found == null) {
          bad = true;
          break;
        }
        pieces.add(found);
        start = end;
      }
      ids.addAll(bad ? [vocab['[UNK]']!] : pieces);
    }
    return special ? [vocab['[CLS]']!, ...ids, vocab['[SEP]']!] : ids;
  }
}

class _Work {
  _Work(this.action, this.done);
  final Future<dynamic> Function() action;
  final Completer<dynamic> done;
}

class InferenceQueue {
  static const _maxPending = 64;
  final Queue<_Work> _foreground = Queue(), _background = Queue();
  bool _running = false;
  bool _paused = false;
  bool _closed = false;
  _Work? _active;
  set paused(bool value) {
    if (_closed) return;
    _paused = value;
    if (!value) {
      _drain();
    }
  }

  Future<T> run<T>(Future<T> Function() action, {bool foreground = true}) {
    if (_closed || _foreground.length + _background.length >= _maxPending) {
      return Future.error(
        NotebookException(_closed ? '推理已关闭。' : '推理任务已排满，请稍后重试。'),
      );
    }
    final c = Completer<dynamic>();
    (foreground ? _foreground : _background).add(_Work(action, c));
    _drain();
    return c.future.then((v) => v as T);
  }

  Future<void> _drain() async {
    if (_closed || _running || _paused) {
      return;
    }
    _running = true;
    try {
      while (!_closed &&
          !_paused &&
          (_foreground.isNotEmpty || _background.isNotEmpty)) {
        final work = (_foreground.isNotEmpty ? _foreground : _background)
            .removeFirst();
        _active = work;
        try {
          final result = await work.action();
          if (!work.done.isCompleted) work.done.complete(result);
        } catch (e, st) {
          if (!work.done.isCompleted) work.done.completeError(e, st);
        } finally {
          _active = null;
        }
      }
    } finally {
      _running = false;
    }
  }

  /// Native work already executing releases its resources in its own finally;
  /// queued work is never started, and no result is delivered after closing.
  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final work in [?_active, ..._foreground, ..._background]) {
      if (!work.done.isCompleted) {
        work.done.completeError(const NotebookException('推理已关闭。'));
      }
    }
    _foreground.clear();
    _background.clear();
  }
}

class LocalModels extends ChangeNotifier implements InferenceRuntime {
  LocalModels(this.store) {
    store.addListener(notifyListeners);
  }
  final ModelStore store;
  final queue = InferenceQueue();
  static const queryInstruction = '为这个句子生成表示以用于检索相关文章：';
  @override
  String? get searchModelVersion {
    final models = store.models.where((m) => m.id == 'bge');
    return models.isEmpty
        ? null
        : '${models.first.version}:bert-cls-l2-w480-o32-v1';
  }

  @override
  Future<bool> ready(InferenceCapability capability) => store.ready(
    capability == InferenceCapability.speech ? 'sensevoice' : 'bge',
  );
  @override
  Future<String> transcribe(String path, {bool foreground = true}) =>
      transcribeFile(path, foreground: foreground);
  Future<String> transcribeFile(String path, {bool foreground = true}) =>
      queue.run(() async {
        if (!await store.ready('sensevoice')) {
          throw const NotebookException('请先在设置下载语音模型。');
        }
        final model = store.file('sensevoice', 'model.int8.onnx');
        final tokens = store.file('sensevoice', 'tokens.txt');
        return _recognizeOffThread(path, model, tokens);
      }, foreground: foreground);
  @override
  Future<List<double>> embed(String text, {required bool query}) =>
      queue.run(() async {
        if (!await store.ready('bge')) {
          throw const NotebookException('语义模型未就绪，仍可使用关键词查找。');
        }
        final model = store.file('bge', 'model.int8.onnx');
        final vocab = store.file('bge', 'vocab.txt');
        return _embedOffThread(text, query, model, vocab);
      }, foreground: query);

  bool _disposed = false;
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    store.removeListener(notifyListeners);
    queue.dispose();
    store.dispose();
    super.dispose();
  }
}

String recognizeWave(String path, String model, String tokens) {
  sherpa.initBindings();
  final wave = sherpa.readWave(path);
  if (wave.samples.isEmpty || wave.sampleRate != 16000) {
    throw const NotebookException('音频格式无效。');
  }
  var energy = 0.0;
  for (final s in wave.samples) {
    energy += s * s;
  }
  if (math.sqrt(energy / wave.samples.length) < 0.001) {
    throw const NotebookException('未检测到有效语音，请检查录音内容后重试。');
  }
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        tokens: tokens,
        numThreads: 1,
        debug: false,
        provider: 'cpu',
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: model,
          language: 'auto',
          useInverseTextNormalization: true,
        ),
      ),
    ),
  );
  final stream = recognizer.createStream();
  try {
    stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
    recognizer.decode(stream);
    return recognizer
        .getResult(stream)
        .text
        .replaceAll(RegExp(r'<\|[^>]*\|>'), '')
        .trim();
  } finally {
    stream.free();
    recognizer.free();
  }
}

Future<String> _recognizeOffThread(String path, String model, String tokens) =>
    Isolate.run(() => recognizeWave(path, model, tokens));

Future<List<double>> _embedOffThread(
  String text,
  bool query,
  String model,
  String vocab,
) => Isolate.run(() => _embedText(text, query, model, vocab));

List<double> _embedText(String text, bool query, String model, String vocab) {
  final tokenizer = BertTokenizer(File(vocab).readAsLinesSync());
  final ids = tokenizer.encode(
    query ? '${LocalModels.queryInstruction}$text' : text,
    special: false,
  );
  ort.OrtEnv.instance.init(level: ort.OrtLoggingLevel.error);
  final options = ort.OrtSessionOptions()
    ..setIntraOpNumThreads(1)
    ..setInterOpNumThreads(1);
  ort.OrtSession? session;
  final sum = List<double>.filled(512, 0);
  var chunks = 0;
  try {
    session = ort.OrtSession.fromFile(File(model), options);
    for (var start = 0; start < math.max(1, ids.length); start += 448) {
      final input = [
        tokenizer.vocab['[CLS]']!,
        ...ids.sublist(start, math.min(ids.length, start + 480)),
        tokenizer.vocab['[SEP]']!,
      ];
      final tensors = <String, ort.OrtValue>{};
      List<ort.OrtValue?>? outputs;
      final run = ort.OrtRunOptions();
      try {
        for (final name in session.inputNames) {
          final data = switch (name) {
            'input_ids' => input,
            'attention_mask' => List<int>.filled(input.length, 1),
            'token_type_ids' => List<int>.filled(input.length, 0),
            _ => throw const NotebookException('向量模型输入契约不匹配。'),
          };
          tensors[name] = ort.OrtValueTensor.createTensorWithDataList(
            Int64List.fromList(data),
            [1, input.length],
          );
        }
        outputs = session.run(run, tensors);
        final index = session.outputNames.indexOf('last_hidden_state');
        final values = outputs[index < 0 ? 0 : index]?.value;
        if (values is! List ||
            values.length != 1 ||
            values.first is! List ||
            (values.first as List).isEmpty) {
          throw const NotebookException('向量模型输出契约不匹配。');
        }
        final cls = (values.first as List).first;
        if (cls is! List || cls.length != 512) {
          throw const NotebookException('向量模型维度不匹配。');
        }
        var norm = 0.0;
        for (final v in cls) {
          norm += (v as num) * v;
        }
        norm = math.sqrt(norm);
        if (norm == 0 || !norm.isFinite) {
          throw const NotebookException('无效语义向量。');
        }
        for (var i = 0; i < 512; i++) {
          sum[i] += (cls[i] as num).toDouble() / norm;
        }
        chunks++;
      } finally {
        run.release();
        for (final t in tensors.values) {
          t.release();
        }
        if (outputs != null) {
          for (final t in outputs) {
            t?.release();
          }
        }
      }
      if (query || start + 480 >= ids.length) {
        break;
      }
    }
    if (chunks == 0) {
      throw const NotebookException('无法生成语义向量。');
    }
    final norm = math.sqrt(sum.fold<double>(0, (a, v) => a + v * v));
    return sum.map((v) => v / norm).toList();
  } finally {
    session?.release();
    options.release();
    ort.OrtEnv.instance.release();
  }
}
