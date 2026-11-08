import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import '../domain/ports.dart';
import '../data/capture_store.dart';
export '../data/capture_store.dart' show CaptureDraft;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/record_repository.dart';
import '../domain/record.dart';
export '../domain/record.dart';

class Notebook extends ChangeNotifier {
  Notebook._(this.home, this.repository, this.clock);
  static Future<Notebook> open(
    Directory home, {
    DateTime Function()? clock,
  }) async {
    await home.create(recursive: true);
    await Directory(p.join(home.path, 'audio')).create();
    await Directory(p.join(home.path, 'drafts')).create();
    final book = Notebook._(
      home,
      RecordRepository(home),
      clock ?? DateTime.now,
    );
    await book._recover();
    return book;
  }

  final Directory home;
  final RecordRepository repository;
  final DateTime Function() clock;
  List<Record> get records => repository.all();
  Record? get(String id) => repository.get(id);
  List<Record> children(String id) =>
      records.where((r) => r.parentId == id).toList().reversed.toList();
  Future<Record> saveText(String text, {String? parentId}) async {
    if (text.trim().isEmpty || text.length > 100000) {
      throw const NotebookException('请输入 1–100,000 字的正文。');
    }
    if (parentId != null && get(parentId)?.parentId != null) {
      throw const NotebookException('请追加到原记录。');
    }
    final now = clock();
    final r = Record(
      id: const Uuid().v4(),
      body: text.trim(),
      parentId: parentId,
      createdAt: now.toUtc(),
      timezone: now.timeZoneName,
      offsetMinutes: now.timeZoneOffset.inMinutes,
    );
    repository.insert(r);
    notifyListeners();
    return r;
  }

  Future<void> edit(
    String id,
    String text, {
    required int expectedRevision,
  }) async {
    if (text.trim().isEmpty || text.length > 100000) {
      throw const NotebookException('请输入 1–100,000 字的正文。');
    }
    repository.edit(id, text.trim(), expectedRevision);
    notifyListeners();
  }

  Future<void> favorite(String id, bool value) async {
    repository.favorite(id, value);
    notifyListeners();
  }

  Future<void> delete(String id) async {
    final group = records.where((r) => r.id == id || r.parentId == id).toList();
    repository.delete(id);
    notifyListeners();
    for (final r in group) {
      if (r.audio != null) {
        final file = File(p.join(home.path, 'audio', r.audio!));
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
  }

  void changed() {
    if (!_closed) {
      notifyListeners();
    }
  }

  void setSearchModelVersion(String version) {
    repository.ensureIndexVersion(version);
    changed();
  }

  bool captureActive = false;
  int recoveredCount = 0;
  final List<CaptureDraft> recoveryDrafts = [];
  final Set<String> _transcribing = {};
  bool _closed = false;
  CaptureStore get captures => CaptureStore(home);
  String audioPath(Record r) => captures.audio(r.audio!);
  Future<CaptureDraft> beginCapture({
    String? parentId,
    bool query = false,
  }) async {
    if (parentId != null && get(parentId) == null) {
      throw const NotebookException('原记录已删除。');
    }
    final now = clock();
    final id = const Uuid().v4();
    final draft = CaptureDraft(
      id: id,
      path: p.join(home.path, query ? 'queries' : 'drafts', '$id.wav'),
      createdAt: now.toUtc(),
      timezone: now.timeZoneName,
      offsetMinutes: now.timeZoneOffset.inMinutes,
      parentId: parentId,
      query: query,
    );
    await File(draft.path).parent.create(recursive: true);
    await captures.persist(draft);
    return draft;
  }

  Future<Record> finishCapture(
    CaptureDraft draft, {
    bool recovering = false,
    bool standalone = false,
  }) async {
    if (draft.query) {
      throw const NotebookException('查询不能保存为记录。');
    }
    final existing = get(draft.id);
    if (existing != null) {
      return existing;
    }
    final dest = captures.audio('${draft.id}.wav');
    final src = await File(draft.path).exists() ? File(draft.path) : File(dest);
    final duration = await validateWave(src, repair: recovering);
    if (src.path != dest) {
      await src.rename(dest);
    }
    final r = Record(
      id: draft.id,
      body: '',
      parentId: standalone ? null : draft.parentId,
      createdAt: draft.createdAt,
      timezone: draft.timezone,
      offsetMinutes: draft.offsetMinutes,
      audio: '${draft.id}.wav',
      durationMs: duration,
      transcription: 'pending',
    );
    repository.insert(r);
    final journal = captures.marker(draft.id);
    // The SQLite commit is the save boundary. A cleanup failure must not turn
    // a committed recording into an apparent draft that can be discarded.
    try {
      if (await journal.exists()) {
        await journal.delete();
      }
    } catch (_) {
      recoveryWarnings++;
    }
    recoveryDrafts.removeWhere((d) => d.id == draft.id);
    if (!_closed) {
      notifyListeners();
    }
    return r;
  }

  Future<void> cancelCapture(CaptureDraft draft) async {
    if (!draft.query && get(draft.id) != null) {
      throw const NotebookException('录音已经保存。若要删除，请从记录详情操作。');
    }
    await captures.discard(draft);
    recoveryDrafts.removeWhere((d) => d.id == draft.id);
    if (!_closed) {
      notifyListeners();
    }
  }

  Future<void> _recover() async {
    for (final name in ['imports', 'exports']) {
      final temporary = Directory(p.join(home.path, name));
      if (await temporary.exists()) {
        await temporary.delete(recursive: true);
      }
    }
    final queries = Directory(p.join(home.path, 'queries'));
    if (await queries.exists()) {
      await queries.delete(recursive: true);
    }
    await for (final file in Directory(p.join(home.path, 'drafts')).list()) {
      if (file is! File || !file.path.endsWith('.json')) {
        continue;
      }
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (j['discarded'] == true) {
          final id = p.basenameWithoutExtension(file.path);
          if (get(id) != null) {
            await file.delete();
            continue;
          }
          for (final f in [
            File(p.join(home.path, 'drafts', '$id.wav')),
            File(captures.audio('$id.wav')),
          ]) {
            if (await f.exists()) {
              await f.delete();
            }
          }
          await file.delete();
          continue;
        }
        final id = j['id'] as String;
        if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
          continue;
        }
        final draft = CaptureDraft(
          id: id,
          path: p.join(home.path, 'drafts', '$id.wav'),
          createdAt: DateTime.parse(j['createdAt'] as String),
          timezone: j['timezone'] as String,
          offsetMinutes: j['offsetMinutes'] as int,
          parentId: j['parentId'] as String?,
        );
        if (get(id) != null) {
          await file.delete();
          continue;
        }
        try {
          await finishCapture(draft, recovering: true);
          recoveredCount++;
        } catch (_) {
          recoveryDrafts.add(draft);
        }
      } catch (_) {
        // Keep an unreadable journal for explicit recovery, never log its data.
        recoveryWarnings++;
      }
    }
    // Files without records or journals can result from interrupted deletion.
    final referenced = records.map((r) => r.audio).whereType<String>().toSet();
    await for (final file in Directory(p.join(home.path, 'audio')).list()) {
      if (file is File &&
          !referenced.contains(p.basename(file.path)) &&
          !await captures
              .marker(p.basenameWithoutExtension(file.path))
              .exists()) {
        await file.delete();
      }
    }
  }

  int recoveryWarnings = 0;
  Future<bool> transcribe(String id, Transcriber engine) async {
    final r = get(id);
    if (r == null || r.audio == null || !_transcribing.add(id)) {
      return false;
    }
    repository.transcriptionState(id, 'running');
    notifyListeners();
    try {
      final text = (await engine.transcribe(audioPath(r))).trim();
      if (_closed) {
        return false;
      }
      if (text.isEmpty) {
        throw const NotebookException('未识别到语音，音频已保留，可重试或编辑正文。');
      }
      final accepted = repository.transcript(id, r.revision, text);
      if (!accepted) {
        repository.transcriptionState(id, 'stale');
      }
      notifyListeners();
      return accepted;
    } catch (_) {
      if (!_closed) {
        repository.transcriptionState(id, 'failed');
        notifyListeners();
      }
      rethrow;
    } finally {
      _transcribing.remove(id);
    }
  }

  Future<String> transcribeQuery(CaptureDraft draft, Transcriber engine) async {
    if (!draft.query) {
      throw const NotebookException('不是语音查询。');
    }
    try {
      await validateWave(File(draft.path));
      return await engine.transcribe(draft.path);
    } finally {
      await captures.discard(draft);
    }
  }

  static String normalize(String text) => String.fromCharCodes(
    text.runes.map(
      (c) => c == 0x3000 ? 32 : (c >= 0xff01 && c <= 0xff5e ? c - 0xfee0 : c),
    ),
  ).toLowerCase().trim();
  Future<SearchResults> search(
    String query, {
    DateTime? from,
    DateTime? to,
    Embedder? embedder,
  }) async {
    final q = normalize(query);
    if (q.isEmpty) {
      return SearchResults([]);
    }
    List<double>? queryVector;
    String? fallback;
    bool semanticUsed = false;
    if (embedder != null) {
      try {
        queryVector = await embedder.embed(query, query: true);
      } catch (_) {
        fallback = '语义查找暂不可用，已使用关键词查找。';
      }
    }
    if (_closed) {
      return SearchResults([]);
    }
    final hits = <SearchHit>[];
    for (final r in records) {
      final date = DateTime(
        r.recordedLocal.year,
        r.recordedLocal.month,
        r.recordedLocal.day,
      );
      if (from != null &&
          date.isBefore(DateTime(from.year, from.month, from.day))) {
        continue;
      }
      if (to != null && date.isAfter(DateTime(to.year, to.month, to.day))) {
        continue;
      }
      final text = normalize(r.body);
      final exact = text.contains(q);
      var score = exact ? 2.0 : 0.0;
      if (queryVector != null &&
          r.vectorRevision == r.revision &&
          r.vector?.length == queryVector.length) {
        semanticUsed = true;
        final v = r.vector!;
        double dot = 0;
        for (var i = 0; i < v.length; i++) {
          dot += v[i] * queryVector[i];
        }
        // Initial calibration from the native synthetic smoke cases. This is a
        // retrieval cutoff, not a factual confidence score; human evaluation is pending.
        if (dot >= 0.60) {
          score += dot;
        }
      }
      if (score <= 0) {
        continue;
      }
      final at = math.max(0, text.indexOf(q) - 30);
      final end = math.min(r.body.length, at + 150);
      hits.add(
        SearchHit(r, r.body.substring(math.min(at, r.body.length), end), score),
      );
    }
    hits.sort(
      (a, b) => a.score != b.score
          ? b.score.compareTo(a.score)
          : b.record.createdAt.compareTo(a.record.createdAt),
    );
    return SearchResults(
      hits,
      semanticUsed: semanticUsed,
      fallbackReason:
          fallback ??
          (embedder != null && !semanticUsed ? '语义索引尚未就绪，显示关键词结果。' : null),
    );
  }

  Future<bool> index(String id, Embedder embedder) async {
    final r = get(id);
    if (r == null || r.body.isEmpty) {
      return false;
    }
    final vector = await embedder.embed(r.body, query: false);
    if (_closed) {
      return false;
    }
    if (vector.isEmpty || vector.any((v) => !v.isFinite)) {
      throw const NotebookException('语义模型返回无效向量。');
    }
    final ok = repository.embedding(id, r.revision, vector);
    notifyListeners();
    return ok;
  }

  final Set<String> _organizing = {};
  OrganizationConsent prepareOrganization(String id) {
    final r = get(id);
    if (r == null || r.body.trim().isEmpty || r.body.length > 8000) {
      throw const NotebookException('请选择 1–8,000 字的单条正文。');
    }
    return OrganizationConsent(r.id, r.revision, r.body);
  }

  Future<bool> organize(
    OrganizationConsent consent,
    Organizer organizer,
  ) async {
    final r = get(consent.recordId);
    if (r == null || r.revision != consent.revision || r.body != consent.text) {
      throw const NotebookException('正文已改变，请重新核对发送内容。');
    }
    if (!_organizing.add(r.id)) {
      throw const NotebookException('正在整理，请勿重复发送。');
    }
    try {
      final result = await organizer.organize(consent.text);
      if (_closed) {
        return false;
      }
      final ok = repository.derived(r.id, r.revision, result);
      notifyListeners();
      return ok;
    } finally {
      _organizing.remove(r.id);
    }
  }

  @override
  void dispose() {
    _closed = true;
    repository.close();
    super.dispose();
  }
}

class OrganizationConsent {
  const OrganizationConsent(this.recordId, this.revision, this.text);
  final String recordId, text;
  final int revision;
}
