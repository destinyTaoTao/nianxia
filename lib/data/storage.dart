import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../domain/record.dart';
import '../domain/local_job.dart';
import 'local_job_store.dart';
import '../domain/record_page.dart';
import '../domain/restore_report.dart';
import '../domain/search_page.dart';
import 'record_repository.dart';
import 'search_index.dart';
import 'restore_store.dart';
import 'search_paging_store.dart';

/// Owns one persistent database isolate. Neither handles, SQL closures nor
/// native pointers cross its seam. A close fences new requests and drains all
/// already accepted work before releasing SQLite.
class Storage {
  Storage._() {
    _subscription = _messages.listen(_receive);
  }
  final _messages = ReceivePort();
  final _ready = Completer<SendPort>();
  late final StreamSubscription<dynamic> _subscription;
  final _pending = <int, Completer<Object?>>{};
  final _progress = <int, void Function(double)>{};
  final _progressErrors = <int, (Object, StackTrace)>{};
  SendPort? _commands;
  int _sequence = 0;
  bool _closing = false, _exited = false;
  Future<void>? _closeFuture;

  static Future<Storage> open(Directory home) async {
    final storage = Storage._();
    try {
      await Isolate.spawn(
        _storageMain,
        [home.path, storage._messages.sendPort],
        debugName: 'nianxia-storage',
        onError: storage._messages.sendPort,
        onExit: storage._messages.sendPort,
      );
      storage._commands = await storage._ready.future;
      return storage;
    } catch (_) {
      await storage._subscription.cancel();
      storage._messages.close();
      rethrow;
    }
  }

  void _receive(dynamic message) {
    if (message == null || message is! List || message.length < 3) {
      _exited = true;
      final error = const NotebookException('本地存储已停止，请保留资料并重新打开应用。');
      if (!_ready.isCompleted) _ready.completeError(error);
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError(error);
      }
      _pending.clear();
      return;
    }
    final id = message[0] as int;
    if (message[1] == 'progress') {
      if (!_progressErrors.containsKey(id)) {
        try {
          _progress[id]?.call(message[2] as double);
        } catch (error, stack) {
          _progressErrors[id] = (error, stack);
        }
      }
      return;
    }
    if (id == 0) {
      if (message[1] == true) {
        _ready.complete(message[2] as SendPort);
      } else {
        _ready.completeError(_error(message[2] as Map));
      }
      return;
    }
    final c = _pending.remove(id);
    if (c == null) return;
    if (message[1] == true) {
      c.complete(message[2]);
    } else {
      c.completeError(_error(message[2] as Map));
    }
  }

  static Exception _error(Map value) => value['kind'] == 'format'
      ? const FormatException('本地资料格式无法识别。')
      : NotebookException(value['message'] as String);

  Future<T> _call<T>(
    _Command command, [
    List<Object?> args = const [],
    void Function(double)? progress,
  ]) async {
    if (_exited || _closing && command != _Command.close) {
      throw const NotebookException('本地资料库已关闭。');
    }
    final id = ++_sequence;
    final c = Completer<Object?>();
    _pending[id] = c;
    if (progress != null) _progress[id] = progress;
    _commands!.send([id, command, args]);
    try {
      final result = await c.future;
      final failure = _progressErrors[id];
      if (failure != null) Error.throwWithStackTrace(failure.$1, failure.$2);
      return result as T;
    } finally {
      _progress.remove(id);
      _progressErrors.remove(id);
    }
  }

  Future<LocalJob?> claimLocalJob({
    Set<JobKind> kinds = const {JobKind.transcription, JobKind.embedding},
    String speechModelVersion = 'unversioned',
  }) => _call(_Command.claimJob, [kinds, speechModelVersion]);
  Future<void> finishLocalJob(LocalJob job, {required JobOutcome outcome}) =>
      _call(_Command.finishJob, [job, outcome]);
  Future<DateTime?> nextLocalJobAttempt(Set<JobKind> kinds) =>
      _call(_Command.nextJobAttempt, [kinds]);
  Future<bool> audioProtected(String name) =>
      _call(_Command.audioProtected, [name]);
  Future<Record?> get(String id) => _call(_Command.get, [id]);
  Future<List<Record>> all({bool includeVectors = false}) =>
      _call(_Command.all, [includeVectors]);
  Future<RecordPage> page({
    RecordCursor? after,
    int? generation,
    bool favorites = false,
    String? parentId,
    int limit = 40,
  }) => _call(_Command.page, [after, generation, favorites, parentId, limit]);
  Future<RecordDetail?> detail(
    String id, {
    RecordCursor? after,
    int? generation,
  }) => _call(_Command.detail, [id, after, generation]);
  Future<int> childCount(String id) => _call(_Command.childCount, [id]);
  Future<List<Record>> children(String id) => _call(_Command.children, [id]);
  Future<List<String>> audioReferences() => _call(_Command.audioReferences);
  Future<List<Record>> pendingJobs({
    required bool transcription,
    String after = '',
  }) => _call(_Command.pendingJobs, [transcription, after]);
  Future<String?> get themeMode => _call(_Command.theme);
  Future<void> saveThemeMode(String mode) => _call(_Command.saveTheme, [mode]);
  Future<String> get indexModelVersion => _call(_Command.indexModel);
  Future<String> get organizationModelVersion =>
      _call(_Command.organizationModel);
  Future<void> ensureIndexVersion(String version) =>
      _call(_Command.ensureIndex, [version]);
  Future<void> ensureOrganizationVersion(String version) =>
      _call(_Command.ensureOrganization, [version]);
  Future<void> insert(Record record) => _call(_Command.insert, [record]);
  Future<void> edit(String id, String text, int revision) =>
      _call(_Command.edit, [id, text, revision]);
  Future<void> favorite(String id, bool value) =>
      _call(_Command.favorite, [id, value]);
  Future<void> delete(String id) => _call(_Command.delete, [id]);
  Future<void> transcriptionState(String id, String state) =>
      _call(_Command.transcriptionState, [id, state]);
  Future<bool> transcript(String id, int revision, String text) =>
      _call(_Command.transcript, [id, revision, text]);
  Future<bool> embedding(
    String id,
    int revision,
    List<double> vector, {
    String? modelVersion,
  }) => _call(_Command.embedding, [id, revision, vector, modelVersion]);
  Future<bool> derived(
    String id,
    int revision,
    Map<String, dynamic> value, {
    String? modelVersion,
  }) => _call(_Command.derived, [id, revision, value, modelVersion]);
  Future<List<String>> pendingMediaDeletions() => _call(_Command.pendingMedia);
  Future<void> completeMediaDeletion(String name) =>
      _call(_Command.completeMedia, [name]);
  Future<bool> completeReferencedMediaDeletions() =>
      _call(_Command.completeReferencedMedia);
  Future<void> snapshotTo(String path) => _call(_Command.snapshot, [path]);
  Future<void> prepareRestore(String work, {void Function(double)? progress}) =>
      _call(_Command.prepareRestore, [work], progress);
  Future<RestoreReport> mergeRestore(String work) =>
      _call(_Command.mergeRestore, [work]);
  Future<int> cleanupRestore(String work) =>
      _call(_Command.cleanupRestore, [work]);
  Future<SearchResults> search(
    String query, {
    DateTime? from,
    DateTime? to,
    List<double>? vector,
    required String model,
    String? fallback,
    bool semanticRequested = false,
  }) => _call(_Command.search, [
    query,
    from,
    to,
    vector,
    model,
    fallback,
    semanticRequested,
  ]);

  /// Explicit maintenance barrier for preparation tools and native validation.
  Future<void> waitForSearchIndex() => _call(_Command.waitForSearchIndex, []);
  Future<SearchPage> searchPage(
    SearchQuery query, {
    required String requestId,
    SearchCursor? after,
    List<double>? vector,
    String? model,
    String? fallback,
    bool semanticRequested = false,
    int limit = 40,
  }) => _call(_Command.searchSummaryPage, [
    query,
    requestId,
    after,
    vector,
    model,
    fallback,
    semanticRequested,
    limit,
  ]);
  Future<void> cancelSearch(String id) => _call(_Command.cancelSearch, [id]);

  Future<void> close() => _closeFuture ??= _finishClose();
  Future<void> _finishClose() async {
    _closing = true;
    try {
      await Future.wait(
        _pending.values
            .map(
              (c) => c.future.then<void>(
                (_) {},
                onError: (Object _, StackTrace _) {},
              ),
            )
            .toList(),
      );
      if (!_exited) await _call<void>(_Command.close);
    } finally {
      await _subscription.cancel();
      _messages.close();
    }
  }
}

enum _Command {
  nextJobAttempt,
  audioProtected,
  claimJob,
  finishJob,
  get,
  all,
  page,
  detail,
  childCount,
  audioReferences,
  pendingJobs,
  theme,
  saveTheme,
  indexModel,
  organizationModel,
  ensureIndex,
  ensureOrganization,
  insert,
  edit,
  favorite,
  delete,
  transcriptionState,
  transcript,
  embedding,
  derived,
  pendingMedia,
  completeMedia,
  completeReferencedMedia,
  snapshot,
  close,
  search,
  searchSummaryPage,
  cancelSearch,
  waitForSearchIndex,
  prepareRestore,
  mergeRestore,
  cleanupRestore,
  children,
}

Map<String, Object?> _failure(Object error) => {
  'kind': error is FormatException ? 'format' : 'storage',
  'message': error is NotebookException ? error.message : '本地存储操作失败，请保留资料并重试。',
};

void _storageMain(List<Object> arguments) {
  final replies = arguments[1] as SendPort;
  final commands = ReceivePort();
  late final RecordRepository repository;
  late final SearchIndex searchIndex;
  late final SearchPagingStore searchPages;
  late final LocalJobStore jobs;
  try {
    repository = RecordRepository(Directory(arguments[0] as String));
    searchIndex = SearchIndex(repository, Directory(arguments[0] as String));
    searchPages = SearchPagingStore(
      repository,
      searchIndex,
      Directory(arguments[0] as String),
    );
    jobs = LocalJobStore(repository, Directory(arguments[0] as String));
    replies.send([0, true, commands.sendPort]);
  } catch (error) {
    replies.send([0, false, _failure(error)]);
    commands.close();
    return;
  }
  commands.listen((dynamic message) async {
    final id = message[0] as int, command = message[1] as _Command;
    final args = message[2] as List;
    try {
      final result = _execute(
        repository,
        searchIndex,
        searchPages,
        jobs,
        command,
        args,
        Directory(arguments[0] as String),
        (value) => replies.send([id, 'progress', value]),
      );
      replies.send([id, true, result is Future ? await result : result]);
    } catch (error) {
      replies.send([id, false, _failure(error)]);
    } finally {
      if (command == _Command.close) commands.close();
    }
  });
}

Object? _execute(
  RecordRepository r,
  SearchIndex searchIndex,
  SearchPagingStore searchPages,
  LocalJobStore jobs,
  _Command command,
  List a,
  Directory home,
  void Function(double) progress,
) {
  switch (command) {
    case _Command.nextJobAttempt:
      return jobs.nextAttempt(a[0] as Set<JobKind>);
    case _Command.audioProtected:
      return r.db.select(
        'SELECT 1 FROM records WHERE audio=? UNION ALL SELECT 1 FROM pending_media_deletions WHERE audio=? LIMIT 1',
        [a[0], a[0]],
      ).isNotEmpty;
    case _Command.claimJob:
      return jobs.claim(a[0] as Set<JobKind>, a[1] as String);
    case _Command.finishJob:
      jobs.finish(a[0] as LocalJob, a[1] as JobOutcome);
      return null;
    case _Command.get:
      return r.get(a[0] as String);
    case _Command.all:
      return r.all(includeVectors: a[0] as bool);
    case _Command.page:
      return r.page(
        after: a[0] as RecordCursor?,
        generation: a[1] as int?,
        favorites: a[2] as bool,
        parentId: a[3] as String?,
        limit: a[4] as int,
      );
    case _Command.detail:
      return r.detail(
        a[0] as String,
        after: a[1] as RecordCursor?,
        generation: a[2] as int?,
      );
    case _Command.childCount:
      return r.childCount(a[0] as String);
    case _Command.children:
      return r.children(a[0] as String);
    case _Command.audioReferences:
      return r.audioReferences();
    case _Command.pendingJobs:
      return r.pendingJobs(transcription: a[0] as bool, after: a[1] as String);
    case _Command.theme:
      return r.themeMode;
    case _Command.saveTheme:
      r.saveThemeMode(a[0] as String);
      return null;
    case _Command.indexModel:
      return r.indexModelVersion;
    case _Command.organizationModel:
      return r.organizationModelVersion;
    case _Command.ensureIndex:
      r.ensureIndexVersion(a[0] as String);
      return null;
    case _Command.ensureOrganization:
      r.ensureOrganizationVersion(a[0] as String);
      return null;
    case _Command.insert:
      r.insert(a[0] as Record);
      return null;
    case _Command.edit:
      r.edit(a[0] as String, a[1] as String, a[2] as int);
      return null;
    case _Command.favorite:
      r.favorite(a[0] as String, a[1] as bool);
      return null;
    case _Command.delete:
      r.delete(a[0] as String);
      return null;
    case _Command.transcriptionState:
      r.transcriptionState(a[0] as String, a[1] as String);
      return null;
    case _Command.transcript:
      return r.transcript(a[0] as String, a[1] as int, a[2] as String);
    case _Command.embedding:
      return r.embedding(
        a[0] as String,
        a[1] as int,
        (a[2] as List).cast<double>(),
        modelVersion: a[3] as String?,
      );
    case _Command.derived:
      return r.derived(
        a[0] as String,
        a[1] as int,
        a[2] as Map<String, dynamic>,
        modelVersion: a[3] as String?,
      );
    case _Command.pendingMedia:
      return r.pendingMediaDeletions();
    case _Command.completeMedia:
      r.completeMediaDeletion(a[0] as String);
      return null;
    case _Command.completeReferencedMedia:
      return r.completeReferencedMediaDeletions();
    case _Command.snapshot:
      r.snapshotTo(a[0] as String);
      return null;
    case _Command.close:
      return searchIndex.close().then((_) {
        try {
          searchPages.close();
          jobs.close();
        } finally {
          r.close();
        }
      });
    case _Command.cancelSearch:
      searchPages.cancel(a[0] as String);
      return null;
    case _Command.searchSummaryPage:
      return searchPages.page(
        a[0] as SearchQuery,
        requestId: a[1] as String,
        after: a[2] as SearchCursor?,
        vector: a[3] as List<double>?,
        model: a[4] as String?,
        fallback: a[5] as String?,
        semanticRequested: a[6] as bool,
        limit: a[7] as int,
      );
    case _Command.search:
      return searchIndex.search(
        a[0] as String,
        a[1] as DateTime?,
        a[2] as DateTime?,
        a[3] as List<double>?,
        a[4] as String,
        a[5] as String?,
        a[6] as bool,
      );
    case _Command.waitForSearchIndex:
      return searchIndex.waitForIndexing();
    case _Command.prepareRestore:
      return RestoreStore(r, home).prepare(a[0] as String, progress);
    case _Command.mergeRestore:
      return RestoreStore(r, home).merge(a[0] as String);
    case _Command.cleanupRestore:
      return RestoreStore(r, home).cleanup(a[0] as String);
  }
}
