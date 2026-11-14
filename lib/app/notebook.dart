import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:crypto/crypto.dart';

import '../domain/capture_session.dart';
import '../domain/local_job.dart';
import '../domain/search_page.dart';

import '../domain/ports.dart';
import '../data/capture_store.dart';
export '../data/capture_store.dart' show CaptureDraft;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import '../data/storage.dart';
import '../domain/record_page.dart';
export '../domain/record_page.dart';
import '../domain/record.dart';
import '../domain/semantic_vector.dart';
import '../domain/organization.dart';
import 'record_search.dart';
export '../domain/record.dart';

class Notebook extends ChangeNotifier {
  Notebook._(this.home, this.repository, this.clock);
  static Future<Notebook> open(
    Directory home, {
    DateTime Function()? clock,
    bool deferMaintenance = false,
  }) async {
    await home.create(recursive: true);
    await Directory(p.join(home.path, 'audio')).create();
    await Directory(p.join(home.path, 'drafts')).create();
    final book = Notebook._(
      home,
      await Storage.open(home),
      clock ?? DateTime.now,
    );
    try {
      book._themeMode = await book.repository.themeMode;
      await book._recover();
      if (!deferMaintenance) await book.runMaintenance();
      return book;
    } catch (_) {
      await book.close();
      rethrow;
    }
  }

  final Directory home;
  final Storage repository;
  final DateTime Function() clock;
  String? _themeMode;
  String? get themeMode => _themeMode;
  Future<void> saveThemeMode(String mode) => _operation(() async {
    await repository.saveThemeMode(mode);
    _themeMode = mode;
  });
  Future<LocalJob?> claimLocalJob({
    Set<JobKind> kinds = const {JobKind.transcription, JobKind.embedding},
    String speechModelVersion = 'unversioned',
  }) => repository.claimLocalJob(
    kinds: kinds,
    speechModelVersion: speechModelVersion,
  );
  Future<void> finishLocalJob(LocalJob job, {required JobOutcome outcome}) =>
      repository.finishLocalJob(job, outcome: outcome);
  Future<List<Record>> get records => repository.all();
  Future<Record?> get(String id) => repository.get(id);
  Future<RecordPage> page({
    RecordCursor? after,
    int? generation,
    bool favorites = false,
  }) => repository.page(
    after: after,
    generation: generation,
    favorites: favorites,
  );
  Future<RecordDetail?> detail(
    String id, {
    RecordCursor? after,
    int? generation,
  }) => repository.detail(id, after: after, generation: generation);
  Future<int> childCount(String id) => repository.childCount(id);
  Future<List<Record>> children(String id) => repository.children(id);
  Future<Record> saveText(String text, {String? parentId}) =>
      _operation(() async {
        if (text.trim().isEmpty || text.length > 100000) {
          throw const NotebookException('请输入 1–100,000 字的正文。');
        }
        if (parentId != null && (await get(parentId))?.parentId != null) {
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
        await repository.insert(r);
        changed();
        return r;
      });

  Future<void> edit(String id, String text, {required int expectedRevision}) =>
      _operation(() async {
        if (text.trim().isEmpty || text.length > 100000) {
          throw const NotebookException('请输入 1–100,000 字的正文。');
        }
        await repository.edit(id, text.trim(), expectedRevision);
        changed();
      });

  Future<void> favorite(String id, bool value) => _operation(() async {
    await repository.favorite(id, value);
    changed();
  });

  Future<void> delete(String id) {
    final deletion = _operation(() async {
      if (_mediaLeases > 0) {
        throw const NotebookException('正在备份或恢复，请完成后再删除记录。');
      }
      await repository.delete(id);
      changed();
      await _drainMediaDeletions();
    });
    // Register the whole operation before its first async reply. An archive
    // lease cannot start preparing media in the SQL-to-cleanup gap.
    final previous = _mediaMutation;
    final barrier = Future.wait<void>([
      ?previous,
      deletion.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]).then<void>((_) {});
    _mediaMutation = barrier;
    unawaited(
      barrier.then((_) {
        if (identical(_mediaMutation, barrier)) _mediaMutation = null;
      }),
    );
    return deletion;
  }

  final contentChanges = ValueNotifier<int>(0);
  void changed({bool content = true}) {
    if (!_closed) {
      if (content) contentChanges.value++;
      notifyListeners();
    }
  }

  Future<void> setSearchModelVersion(String version) => _operation(() async {
    await repository.ensureIndexVersion(version);
    changed(content: false);
  });

  final captureChanges = ValueNotifier<bool>(false);
  bool _captureActive = false;
  bool get captureActive => _captureActive;
  set captureActive(bool active) {
    if (_captureActive == active || _closed) return;
    _captureActive = active;
    captureChanges.value = active;
  }

  int recoveredCount = 0;
  final List<CaptureDraft> recoveryDrafts = [];
  final Set<String> _transcribing = {};
  bool _closed = false;
  bool get isClosed => _closed;
  int _mediaLeases = 0;
  Future<void>? _mediaMutation;
  final Map<String, Future<void>> _captureOperations = {};
  late final _search = RecordSearch(repository, isClosed: () => _closed);

  // Save and discard share a single seam. Checking SQLite before asynchronous
  // file I/O alone cannot protect a recording from a concurrent discard.
  Future<T> _withCapture<T>(String id, Future<T> Function() action) =>
      _operation(() async {
        final previous = _captureOperations[id];
        final released = Completer<void>();
        _captureOperations[id] = released.future;
        try {
          await previous;
          if (_closed) throw const NotebookException('本地资料库已关闭。');
          return await action();
        } finally {
          released.complete();
          if (identical(_captureOperations[id], released.future)) {
            _captureOperations.remove(id);
          }
        }
      });

  /// Keeps immutable media referenced by an archive snapshot alive. Edits and
  /// new captures remain available; each archive owns its snapshot of metadata.
  Future<T> withMediaLease<T>(Future<T> Function() action) async {
    if (_closed) {
      throw const NotebookException('本地资料库已关闭。');
    }
    _mediaLeases++;
    try {
      await _mediaMutation;
      await _mediaCleanup;
      return await action();
    } finally {
      _mediaLeases--;
      if (_mediaLeases == 0 && _mediaIdle != null && !_mediaIdle!.isCompleted) {
        _mediaIdle!.complete();
      }
    }
  }

  CaptureStore get captures => CaptureStore(home);
  String audioPath(Record r) => captures.audio(r.audio!);
  Future<CaptureDraft> beginCapture({String? parentId, bool query = false}) =>
      _operation(() async {
        if (parentId != null && await get(parentId) == null) {
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
      });

  Future<Record> finishCapture(
    CaptureDraft draft, {
    bool recovering = false,
    bool standalone = false,
  }) => _withCapture(
    draft.id,
    () => _finishCapture(draft, recovering: recovering, standalone: standalone),
  );

  Future<Record> acceptNativeCapture(
    FinalizedCapture clip, {
    bool standalone = false,
  }) {
    final draft = captures.nativeDraft(clip);
    return _withCapture(
      draft.id,
      () => withMediaLease(() async {
        if (await get(draft.id) == null) await captures.persistNative(clip);
        return _finishCapture(draft, standalone: standalone);
      }),
    );
  }

  Future<Record> _finishCapture(
    CaptureDraft draft, {
    bool recovering = false,
    bool standalone = false,
  }) async {
    if (draft.query) {
      throw const NotebookException('查询不能保存为记录。');
    }
    final existing = await get(draft.id);
    if (existing != null) {
      if (draft.nativePcmBytes != null) {
        if (existing.audio != '${draft.id}.wav' ||
            existing.createdAt != draft.createdAt ||
            existing.timezone != draft.timezone ||
            existing.offsetMinutes != draft.offsetMinutes ||
            existing.parentId != draft.parentId &&
                !(existing.parentId == null && draft.parentId != null) ||
            existing.durationMs != draft.nativePcmBytes! * 1000 ~/ 32000) {
          throw const NotebookException('录音来源与已有记录不一致，原文件保留。');
        }
        final destination = File(audioPath(existing));
        await _validateNativeWave(destination, draft.nativePcmBytes!);
        final source = File(draft.path);
        if (await source.exists()) {
          await _validateNativeWave(source, draft.nativePcmBytes!);
          if ((await sha256.bind(source.openRead()).first) !=
              (await sha256.bind(destination.openRead()).first)) {
            throw const NotebookException('录音与已有音频不一致，原文件保留。');
          }
        }
      }
      return existing;
    }
    final dest = captures.audio('${draft.id}.wav');
    final src = await File(draft.path).exists() ? File(draft.path) : File(dest);
    if (draft.nativePcmBytes != null) {
      final destination = File(dest);
      if (src.path != dest && await destination.exists()) {
        throw const NotebookException('目标音频已存在，原文件保留，请核对恢复资料。');
      }
      if (!standalone &&
          draft.parentId != null &&
          await get(draft.parentId!) == null) {
        throw const NotebookException('原记录已删除，请确认是否保存为独立记录。');
      }
      await _validateNativeWave(src, draft.nativePcmBytes!);
    }
    final duration = await validateWave(
      src,
      repair: recovering && draft.nativePcmBytes == null,
    );
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
    await repository.insert(r);
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
      changed();
    }
    return r;
  }

  Future<void> _validateNativeWave(File file, int bytes) async {
    if (bytes <= 0 ||
        bytes > 3840000 ||
        bytes.isOdd ||
        await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.isWithin(home.path, file.path) ||
        await file.resolveSymbolicLinks() !=
            p.join(
              await home.resolveSymbolicLinks(),
              p.relative(file.path, from: home.path),
            ) ||
        await file.length() != bytes + 44) {
      throw const NotebookException('原生录音文件不完整或路径无效，原文件保留。');
    }
    await validateWave(file);
  }

  Future<void> cancelCapture(CaptureDraft draft) =>
      _withCapture(draft.id, () async {
        if (!draft.query && await get(draft.id) != null) {
          throw const NotebookException('录音已经保存。若要删除，请从记录详情操作。');
        }
        await captures.discard(draft);
        recoveryDrafts.removeWhere((d) => d.id == draft.id);
        if (!_closed) {
          changed();
        }
      });

  Future<void> _recover() async {
    for (final name in ['imports', 'exports']) {
      final temporary = Directory(p.join(home.path, name));
      if (await temporary.exists()) {
        try {
          await temporary.delete(recursive: true);
        } on FileSystemException {
          recoveryWarnings++;
        }
      }
    }
    final queries = Directory(p.join(home.path, 'queries'));
    if (await queries.exists()) {
      try {
        await queries.delete(recursive: true);
      } on FileSystemException {
        recoveryWarnings++;
      }
    }
    await for (final file in Directory(p.join(home.path, 'drafts')).list()) {
      if (file is! File || !file.path.endsWith('.json')) {
        continue;
      }
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if (j.containsKey('nativeCaptureVersion') &&
            j['nativeCaptureVersion'] != 1) {
          recoveryWarnings++;
          continue;
        }
        if (j['discarded'] == true) {
          final id = p.basenameWithoutExtension(file.path);
          if (await get(id) != null) {
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
        final native = j['nativeCaptureVersion'] == 1;
        if (native) validateCaptureId(id);
        if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(id)) {
          continue;
        }
        final draft = CaptureDraft(
          id: id,
          path: p.join(
            home.path,
            native ? 'native-captures' : 'drafts',
            '$id.wav',
          ),
          createdAt: DateTime.parse(j['createdAt'] as String),
          timezone: j['timezone'] as String,
          offsetMinutes: j['offsetMinutes'] as int,
          parentId: j['parentId'] as String?,
          nativePcmBytes: native ? j['pcmBytes'] as int : null,
        );
        if (!native && await get(id) != null) {
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
  }

  Future<void>? _maintenance;

  /// Optional full scan runs after startup. Every move shares capture's lock
  /// and a media barrier; reference checks are fresh, never an old snapshot.
  Future<void> runMaintenance() => _maintenance ??= _operation(() async {
    if (_mediaLeases > 0 || captureActive) return;
    if (!await repository.completeReferencedMediaDeletions()) {
      recoveryWarnings++;
    }
    await _drainMediaDeletions();
    await for (final file in Directory(p.join(home.path, 'audio')).list()) {
      if (_closed) break;
      if (file is! File) continue;
      final id = p.basenameWithoutExtension(file.path);
      await _withCapture(id, () async {
        if (_closed || _mediaLeases > 0 || captureActive) return;
        final previous = _mediaMutation;
        final complete = Completer<void>();
        _mediaMutation = complete.future;
        try {
          await previous;
          if (_closed ||
              _mediaLeases > 0 ||
              captureActive ||
              await repository.audioProtected(p.basename(file.path)) ||
              await captures.marker(id).exists()) {
            return;
          }
          try {
            final quarantine = await Directory(
              p.join(home.path, 'quarantine', const Uuid().v4()),
            ).create(recursive: true);
            await file.rename(p.join(quarantine.path, p.basename(file.path)));
          } on FileSystemException {
            /* Preserve original if isolation fails. */
          }
          recoveryWarnings++;
        } finally {
          complete.complete();
          if (identical(_mediaMutation, complete.future)) _mediaMutation = null;
        }
      });
      await Future<void>.delayed(Duration.zero);
    }
  }).whenComplete(() => _maintenance = null);

  int recoveryWarnings = 0;
  Future<void>? _mediaCleanup;

  Future<void> _drainMediaDeletions() => _mediaCleanup ??= _cleanDeletedMedia()
      .whenComplete(() => _mediaCleanup = null);

  Future<void> _cleanDeletedMedia() async {
    final blocked = <String>{};
    while (!_closed) {
      final pending = (await repository.pendingMediaDeletions())
          .where((name) => !blocked.contains(name))
          .toList();
      if (pending.isEmpty) return;
      for (final name in pending) {
        if (_closed) return;
        if (p.basename(name) != name ||
            name == '.' ||
            name == '..' ||
            name.contains('\\') ||
            p.isAbsolute(name)) {
          blocked.add(name);
          recoveryWarnings++;
          continue;
        }
        try {
          final path = p.join(home.path, 'audio', name);
          final type = await FileSystemEntity.type(path, followLinks: false);
          if (type == FileSystemEntityType.directory) {
            throw const FileSystemException('Audio path is occupied');
          }
          if (type != FileSystemEntityType.notFound) await File(path).delete();
          if (!_closed) await repository.completeMediaDeletion(name);
        } on FileSystemException {
          blocked.add(name);
          recoveryWarnings++;
        } on NotebookException {
          // The record deletion already committed. Leave its durable intent
          // for a later retry instead of reporting the user operation failed.
          blocked.add(name);
          recoveryWarnings++;
        }
      }
    }
  }

  Future<bool> transcribe(String id, Transcriber engine) =>
      _operation(() async {
        final r = await get(id);
        if (r == null || r.audio == null || !_transcribing.add(id)) {
          return false;
        }
        await repository.transcriptionState(id, 'running');
        changed();
        try {
          if (_closed) return false;
          final result = await _untilClosed(engine.transcribe(audioPath(r)));
          final text = result?.trim() ?? '';
          if (_closed) {
            return false;
          }
          if (text.isEmpty) {
            throw const NotebookException('未识别到语音，音频已保留，可重试或编辑正文。');
          }
          if (text.length > 100000) {
            throw const NotebookException('转写超过 100,000 字，未写入正文，音频已保留，可重试。');
          }
          final accepted = await repository.transcript(id, r.revision, text);
          if (!accepted) {
            await repository.transcriptionState(id, 'stale');
          }
          changed();
          return accepted;
        } catch (_) {
          if (!_closed) {
            await repository.transcriptionState(id, 'failed');
            changed();
          }
          rethrow;
        } finally {
          _transcribing.remove(id);
        }
      });

  Future<String> transcribeQuery(CaptureDraft draft, Transcriber engine) =>
      _operation(() async {
        if (!draft.query) {
          throw const NotebookException('不是语音查询。');
        }
        try {
          await validateWave(File(draft.path));
          if (_closed) throw const NotebookException('本地资料库已关闭。');
          final result = await _untilClosed(engine.transcribe(draft.path));
          if (result == null) throw const NotebookException('查询已结束。');
          return result;
        } finally {
          await captures.discard(draft);
        }
      });

  static String normalize(String text) => RecordSearch.normalize(text);
  Future<SearchPage> searchPage(
    SearchQuery query, {
    SearchCursor? after,
    Embedder? embedder,
    SearchCancellation? cancellation,
    int limit = 40,
  }) => _search.searchPage(
    query,
    after: after,
    embedder: embedder,
    cancellation: cancellation,
    limit: limit,
  );
  Future<SearchResults> search(
    String query, {
    DateTime? from,
    DateTime? to,
    Embedder? embedder,
  }) => _search.search(query, from: from, to: to, embedder: embedder);

  Future<bool> index(String id, Embedder embedder) => _operation(() async {
    final modelVersion = await repository.indexModelVersion;
    final r = await get(id);
    if (_closed || r == null || r.body.isEmpty) {
      return false;
    }
    final result = await _untilClosed(embedder.embed(r.body, query: false));
    if (result == null) return false;
    final vector = unitVector(result);
    if (_closed) {
      return false;
    }
    final ok = await repository.embedding(
      id,
      r.revision,
      vector,
      modelVersion: modelVersion,
    );
    changed(content: false);
    return ok;
  });

  final Set<String> _organizing = {};
  Future<OrganizationConsent> prepareOrganization(String id) =>
      _operation(() async {
        final r = await get(id);
        if (r == null || r.body.trim().isEmpty || r.body.length > 8000) {
          throw const NotebookException('请选择 1–8,000 字的单条正文。');
        }
        return OrganizationConsent(r.id, r.revision, r.body);
      });

  Future<bool> organize(OrganizationConsent consent, Organizer organizer) =>
      _operation(() async {
        // Capture the generation as the first accepted storage request, before
        // asynchronous record reads can yield to a model replacement.
        final model = await repository.organizationModelVersion;
        final r = await get(consent.recordId);
        if (r == null ||
            r.revision != consent.revision ||
            r.body != consent.text) {
          throw const NotebookException('正文已改变，请重新核对发送内容。');
        }
        if (_closed) return false;
        if (!_organizing.add(r.id)) {
          throw const NotebookException('正在整理，请勿重复发送。');
        }
        try {
          final result = await _untilClosed(organizer.organize(consent.text));
          if (_closed || result == null) {
            return false;
          }
          Map<String, dynamic> validated;
          try {
            validated = validateOrganization(result, consent.text);
          } on FormatException {
            throw const NotebookException('整理结果无效，原文已保留。');
          }
          final ok = await repository.derived(
            r.id,
            r.revision,
            validated,
            modelVersion: model,
          );
          changed(content: false);
          return ok;
        } finally {
          _organizing.remove(r.id);
        }
      });

  final _closingSignal = Completer<void>();
  int _operations = 0;
  Completer<void>? _idle, _mediaIdle;
  Future<void>? _closeFuture;
  bool _notifierDisposed = false;

  Future<T> _operation<T>(Future<T> Function() action) async {
    if (_closed) throw const NotebookException('本地资料库已关闭。');
    _operations++;
    try {
      return await action();
    } finally {
      _operations--;
      if (_operations == 0 && _idle != null && !_idle!.isCompleted) {
        _idle!.complete();
      }
    }
  }

  Future<T?> _untilClosed<T>(Future<T> work) => Future.any<T?>([
    work.then<T?>((value) => value),
    _closingSignal.future.then<T?>((_) => null),
  ]);

  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closed = true;
    _closingSignal.complete();
    _closeFuture = _finishClose();
    dispose();
    return _closeFuture!;
  }

  Future<void> _finishClose() async {
    if (_operations > 0) {
      _idle = Completer<void>();
      await _idle!.future;
    }
    if (_mediaLeases > 0) {
      _mediaIdle = Completer<void>();
      await _mediaIdle!.future;
    }
    await repository.close();
  }

  @override
  void dispose() {
    if (_notifierDisposed) return;
    _notifierDisposed = true;
    contentChanges.dispose();
    captureChanges.dispose();
    super.dispose();
    unawaited(close());
  }
}

class OrganizationConsent {
  const OrganizationConsent(this.recordId, this.revision, this.text);
  final String recordId, text;
  final int revision;
}
