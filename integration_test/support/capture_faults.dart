import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'isolated_validation.dart';

Future<File> _checkpointFile() async {
  await requireIsolatedValidation();
  final identity = await const MethodChannel('app.nianxia/system')
      .invokeMapMethod<String, Object?>('validationIdentity');
  const runId = String.fromEnvironment('VALIDATION_RUN_ID');
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(runId)) {
    throw StateError('无效验证标识');
  }
  return File(
    p.join(
      identity!['cacheRoot'] as String,
      'validation-progress',
      '$runId.json',
    ),
  );
}

Future<Map<String, Object?>?> readCaptureFaultCheckpoint() async {
  final file = await _checkpointFile();
  if (!await file.exists()) return null;
  if (await file.length() > 4096) throw StateError('验证凭据过大');
  final data = Map<String, Object?>.from(
    jsonDecode(await file.readAsString()) as Map,
  );
  if (data['applicationId'] != validationApplicationId ||
      data['runId'] != const String.fromEnvironment('VALIDATION_RUN_ID') ||
      data['case'] != const String.fromEnvironment('VALIDATION_CASE')) {
    throw StateError('验证凭据不匹配');
  }
  return data;
}

Future<void> writeCaptureFaultCheckpoint(String phase, String sessionId) async {
  final file = await _checkpointFile();
  await file.parent.create(recursive: true);
  final data = {
    'applicationId': validationApplicationId,
    'runId': const String.fromEnvironment('VALIDATION_RUN_ID'),
    'case': const String.fromEnvironment('VALIDATION_CASE'),
    'phase': phase,
    'sessionId': sessionId,
  };
  final partial = File('${file.path}.partial');
  await partial.writeAsString(jsonEncode(data), flush: true);
  await partial.rename(file.path);
}
