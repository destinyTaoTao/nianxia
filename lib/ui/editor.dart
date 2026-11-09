import 'package:flutter/material.dart';

import '../app/notebook.dart';
import 'common.dart';

Future<void> openEditor(
  BuildContext context,
  Notebook book, {
  Record? record,
  String? parentId,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => _Editor(book: book, record: record, parentId: parentId),
  ),
);

class _Editor extends StatefulWidget {
  const _Editor({required this.book, this.record, this.parentId});
  final Notebook book;
  final Record? record;
  final String? parentId;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final text = TextEditingController(text: widget.record?.body ?? '');
  bool busy = false;
  bool dirty = false;
  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (busy) {
      return;
    }
    setState(() => busy = true);
    try {
      if (widget.record == null) {
        await widget.book.saveText(text.text, parentId: widget.parentId);
      } else {
        await widget.book.edit(
          widget.record!.id,
          text.text,
          expectedRevision: widget.record!.revision,
        );
      }
      if (mounted) {
        Navigator.pop(context);
        notice(context, '已保存');
      }
    } catch (e) {
      if (mounted) {
        notice(context, userError(e));
        setState(() => busy = false);
      }
    }
  }

  Future<void> leave() async {
    if (!dirty ||
        await confirm(context, '放弃尚未保存的修改？', '已保存的原文保持不变。', action: '放弃修改')) {
      if (mounted) {
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty && !busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !busy) {
        leave();
      }
    },
    child: Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: busy ? null : leave,
          tooltip: '返回',
          icon: const Icon(Icons.arrow_back),
        ),
        title: Text(
          widget.record != null
              ? '编辑正文'
              : widget.parentId != null
              ? '接着写'
              : '写文字',
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : save,
            child: Text(busy ? '保存中' : '保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ReadingWidth(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: PaperSurface(
            child: TextField(
              key: const Key('body-editor'),
              controller: text,
              autofocus: true,
              expands: true,
              minLines: null,
              maxLines: null,
              maxLength: 100000,
              textAlignVertical: TextAlignVertical.top,
              style: Theme.of(context).textTheme.bodyLarge,
              decoration: const InputDecoration(
                hintText: '此刻在想什么？',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                counterText: '',
              ),
              onChanged: (_) => setState(() => dirty = true),
            ),
          ),
        ),
      ),
    ),
  );
}
