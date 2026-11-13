import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nianxia/app/notebook.dart';
import 'package:nianxia/app/backup.dart';

import 'recording_search_test.dart' show writeWave;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'readableExportContainsOnlyTextAndAudio and preserves append relationship',
    () async {
      final home = await Directory.systemTemp.createTemp('nx-readable-');
      final book = await Notebook.open(home);
      try {
        final parent = await book.saveText('synthetic parent');
        await book.saveText('synthetic child', parentId: parent.id);
        final draft = await book.beginCapture(parentId: parent.id);
        await writeWave(draft.path);
        await book.finishCapture(draft);
        final output = await BackupService(book).exportReadable();
        final zip = ZipDecoder().decodeBytes(
          await output.readAsBytes(),
          verify: true,
        );
        expect(
          zip.files.any(
            (f) =>
                f.name == 'manifest.json' ||
                f.name.endsWith('.sqlite') ||
                f.name.endsWith('.json'),
          ),
          isFalse,
        );
        expect(
          zip.files
              .where(
                (f) => f.name.startsWith('notes/') && f.name.endsWith('.txt'),
              )
              .length,
          3,
        );
        expect(zip.files.where((f) => f.name.startsWith('audio/')).length, 1);
        final text = zip.files
            .where((f) => f.name.endsWith('.txt'))
            .map((f) => utf8.decode(f.content))
            .join('\n');
        expect(text, contains('synthetic child'));
        expect(text, contains(parent.id));
        expect(text, contains('未加密'));
        expect(text, contains('不用于完整恢复'));
      } finally {
        await book.close();
        await home.delete(recursive: true);
      }
    },
  );
}
