import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

const validationApplicationId = 'app.nianxia.nianxia.test';
const _system = MethodChannel('app.nianxia/system');

bool isIsolatedValidationIdentity(
  Map<String, Object?> identity, {
  required String platform,
  required String temporaryPath,
}) {
  if (identity['applicationId'] != validationApplicationId) return false;
  final cache = identity['cacheRoot'];
  final roots = identity['temporaryRoots'];
  if (cache is! String || roots is! List || roots.isEmpty) return false;
  final normalized = p.normalize(temporaryPath);
  bool allowedRoot(Object? value) {
    if (value is! String ||
        !p.isAbsolute(value) ||
        p.normalize(value) != value) {
      return false;
    }
    if (platform == 'android') {
      return RegExp(
        r'^/data/(?:user/0|data)/app\.nianxia\.nianxia\.test/(?:cache|code_cache)$',
      ).hasMatch(value);
    }
    if (platform == 'ios') {
      return RegExp(
        r'/Containers/Data/Application/[0-9A-Fa-f-]{36}/(?:tmp|Library/Caches)$',
      ).hasMatch(value);
    }
    return false;
  }

  return allowedRoot(cache) &&
      roots.every(allowedRoot) &&
      roots.any(
        (root) => normalized == root || p.isWithin(root as String, normalized),
      );
}

Future<Map<String, Object?>> _identity() async {
  final value = await _system.invokeMapMethod<String, Object?>(
    'validationIdentity',
  );
  if (value == null ||
      !isIsolatedValidationIdentity(
        value,
        platform: Platform.operatingSystem,
        temporaryPath: Directory.systemTemp.resolveSymbolicLinksSync(),
      )) {
    throw StateError('验证只允许在已核验身份的独立测试应用私有缓存中执行。');
  }
  return value;
}

Future<void> requireIsolatedValidation() async {
  await _identity();
}

Future<void> writeRecordingCheckpoint() async {
  final identity = await _identity();
  const runId = String.fromEnvironment('VALIDATION_RUN_ID');
  const testCase = String.fromEnvironment('VALIDATION_CASE');
  if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(runId) ||
      testCase != 'capture-matrix') {
    throw StateError('缺少有效的熄屏验证标识。');
  }
  final data = {
    'applicationId': validationApplicationId,
    'runId': runId,
    'case': testCase,
  };
  final directory = await Directory(
    p.join(identity['cacheRoot'] as String, 'validation-progress'),
  ).create(recursive: true);
  final output = File(p.join(directory.path, '${data['runId']}.json'));
  final partial = File('${output.path}.partial');
  await partial.writeAsString(
    jsonEncode({...data, 'phase': 'recording'}),
    flush: true,
  );
  await partial.rename(output.path);
}

Future<Map<String, Object?>> writeValidationResult({
  required bool passed,
  Map<String, num> metrics = const {},
}) async {
  final identity = await _identity();
  const runId = String.fromEnvironment('VALIDATION_RUN_ID');
  const testCase = String.fromEnvironment('VALIDATION_CASE');
  if (!RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      ).hasMatch(runId) ||
      !RegExp(r'^[a-z-]{1,64}$').hasMatch(testCase) ||
      metrics.values.any((value) => !value.isFinite)) {
    throw StateError('缺少有效的验证运行标识。');
  }
  final data = <String, Object?>{
    'applicationId': validationApplicationId,
    'runId': runId,
    'case': testCase,
    'passed': passed,
    'metrics': metrics,
  };
  final directory = await Directory(
    p.join(identity['cacheRoot'] as String, 'validation-results'),
  ).create(recursive: true);
  final output = File(p.join(directory.path, '$runId.json'));
  final partial = File('${output.path}.partial');
  await partial.writeAsString(jsonEncode(data), flush: true);
  await partial.rename(output.path);
  return data;
}
