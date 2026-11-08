import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/record.dart';

class ModelFile {
  const ModelFile({
    required this.name,
    required this.url,
    required this.bytes,
    required this.sha256,
  });
  final String name, sha256;
  final Uri url;
  final int bytes;
}

class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.version,
    required this.label,
    required this.files,
    this.license = '',
    this.source = '',
  });
  final String id, version, label, license, source;
  final List<ModelFile> files;
  int get bytes => files.fold(0, (sum, f) => sum + f.bytes);
  static List<ModelSpec> parse(String json) =>
      (jsonDecode(json) as List).map((j) {
        final id = j['id'] as String;
        final version = j['version'] as String;
        if (!RegExp(r'^[a-z0-9-]+$').hasMatch(id) ||
            !RegExp(r'^[a-z0-9-]+$').hasMatch(version)) {
          throw const FormatException('invalid model id');
        }
        final files = (j['files'] as List).map((f) {
          final name = f['name'] as String;
          final url = Uri.parse(f['url'] as String);
          if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(name) ||
              name.startsWith('.') ||
              url.scheme != 'https' ||
              url.host != 'huggingface.co' ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(f['sha256'] as String)) {
            throw const FormatException('invalid trusted model manifest');
          }
          return ModelFile(
            name: name,
            url: url,
            bytes: f['bytes'] as int,
            sha256: f['sha256'] as String,
          );
        }).toList();
        return ModelSpec(
          id: id,
          version: version,
          label: j['label'] as String,
          license: j['license'] as String,
          source: j['source'] as String,
          files: files,
        );
      }).toList();
}

class ModelStore extends ChangeNotifier {
  ModelStore(this.home, this.models);
  final Directory home;
  final List<ModelSpec> models;
  final Map<String, double> progress = {};
  final Map<String, String> errors = {};
  final Map<String, HttpClient> _clients = {};
  final Set<String> _cancelled = {};
  final Set<String> _verified = {};
  bool _disposed = false;
  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  Directory directory(ModelSpec m) =>
      Directory(p.join(home.path, '${m.id}-${m.version}'));
  ModelSpec spec(String id) => models.firstWhere((m) => m.id == id);
  String file(String id, String name) => p.join(directory(spec(id)).path, name);
  Future<bool> ready(String id) async {
    final m = spec(id);
    final dir = directory(m);
    final key = '${m.id}-${m.version}';
    if (!await File(p.join(dir.path, '.ready')).exists()) {
      return false;
    }
    for (final asset in m.files) {
      final f = File(p.join(dir.path, asset.name));
      if (!await f.exists() || await f.length() != asset.bytes) {
        _verified.remove(key);
        return false;
      }
      if (!_verified.contains(key) &&
          (await crypto.sha256.bind(f.openRead()).first).toString() !=
              asset.sha256) {
        return false;
      }
    }
    _verified.add(key);
    return true;
  }

  void cancel(String id) {
    _cancelled.add(id);
    _clients[id]?.close(force: true);
  }

  Future<void> download(String id) async {
    if (_clients.containsKey(id)) {
      return;
    }
    final m = spec(id);
    final stage = Directory('${directory(m).path}.partial');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    _clients[id] = client;
    _cancelled.remove(id);
    errors.remove(id);
    progress[id] = 0;
    _notify();
    try {
      await stage.create(recursive: true);
      var total = 0;
      for (final asset in m.files) {
        final req = await client.getUrl(asset.url);
        // Only model weights are downloaded. There is no user content or auth
        // header here; HF redirects to its signed weight CDN are allowed.
        final response = await req.close().timeout(const Duration(seconds: 45));
        if (response.statusCode != 200) {
          throw const HttpException('model download failed');
        }
        final f = File(p.join(stage.path, asset.name));
        final sink = f.openWrite();
        var received = 0;
        try {
          await for (final chunk in response.timeout(
            const Duration(seconds: 45),
          )) {
            if (_cancelled.contains(id)) {
              throw const NotebookException('下载已取消。');
            }
            received += chunk.length;
            if (received > asset.bytes) {
              throw const NotebookException('模型大小不符，未启用。');
            }
            sink.add(chunk);
            // Drain periodically to bound queued output on slow storage.
            await sink.flush();
            progress[id] = (total + received) / m.bytes;
            _notify();
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received != asset.bytes ||
            (await crypto.sha256.bind(f.openRead()).first).toString() !=
                asset.sha256) {
          throw const NotebookException('模型校验失败，未启用，请重新下载。');
        }
        total += received;
      }
      if (_cancelled.contains(id)) {
        throw const NotebookException('下载已取消。');
      }
      await File(p.join(stage.path, '.ready'))
          .writeAsString(m.version, flush: true);
      final target = directory(m);
      // Never delete a usable version. A second download of the same version is
      // unnecessary, and an interrupted new version lives in a different path.
      if (await target.exists()) {
        if (await ready(id)) {
          await stage.delete(recursive: true);
          return;
        }
        final broken = Directory('${target.path}.broken');
        if (await broken.exists()) {
          await broken.delete(recursive: true);
        }
        await target.rename(broken.path);
      }
      await stage.rename(target.path);
      _verified.add('${m.id}-${m.version}');
    } catch (_) {
      errors[id] = _cancelled.contains(id)
          ? '下载已取消，可重新下载。'
          : '下载或校验失败。检查网络与剩余空间后重试，原有模型保持可用。';
      rethrow;
    } finally {
      client.close(force: true);
      _clients.remove(id);
      progress.remove(id);
      if (await stage.exists()) {
        await stage.delete(recursive: true);
      }
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final c in _clients.values) {
      c.close(force: true);
    }
    super.dispose();
  }
}
