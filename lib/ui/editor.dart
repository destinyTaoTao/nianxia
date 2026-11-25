import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/notebook.dart';
import 'common.dart';

Future<Record?> openEditor(
  BuildContext context,
  Notebook book, {
  Record? record,
  String? parentId,
  String? parentTitle,
  VoidCallback? onSaved,
}) => Navigator.of(context).push<Record>(
  MaterialPageRoute<Record>(
    builder: (_) => _Editor(
      book: book,
      record: record,
      parentId: parentId,
      parentTitle: parentTitle,
      onSaved: onSaved,
    ),
  ),
);

class _Editor extends StatefulWidget {
  const _Editor({
    required this.book,
    this.record,
    this.parentId,
    this.parentTitle,
    this.onSaved,
  });
  final Notebook book;
  final Record? record;
  final String? parentId;
  final String? parentTitle;
  final VoidCallback? onSaved;
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  late final text = TextEditingController(text: widget.record?.body ?? '');
  late Record? baseline = widget.record;
  Record? conflict;
  TextSubmission? submission;
  late String? parentTitle = widget.parentTitle;
  bool busy = false, deleted = false, confirming = false, parentMissing = false;
  String? error;
  bool get dirty => text.text != (baseline?.body ?? '');
  bool get canSave =>
      !busy &&
      !deleted &&
      !parentMissing &&
      conflict == null &&
      text.text.trim().isNotEmpty &&
      (baseline == null || dirty);
  @override
  void initState() {
    super.initState();
    if (widget.parentId != null && parentTitle == null) {
      widget.book
          .get(widget.parentId!)
          .then(
            (value) {
              if (mounted && value != null) {
                setState(() => parentTitle = value.title);
              }
            },
            onError: (Object _, StackTrace _) {
              /* The draft remains usable; save checks the parent atomically. */
            },
          );
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void showConflict(Record? latest) {
    conflict = latest;
    deleted = latest == null;
    error = deleted ? '记录已删除，草稿仍保留。' : '记录已更新，草稿仍保留。';
  }

  Future<void> save({bool standalone = false}) async {
    if (standalone
        ? (busy || !parentMissing || text.text.trim().isEmpty)
        : !canSave) {
      return;
    }
    final editorRoute = ModalRoute.of<Record>(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => busy = true);
    try {
      final base = baseline;
      Record? saved;
      if (base == null) {
        if (submission?.text != text.text.trim()) submission = null;
        submission ??= widget.book.prepareText(
          text.text,
          parentId: widget.parentId,
        );
        saved = await widget.book.saveTextSubmission(
          submission!,
          standalone: standalone,
        );
      } else {
        await widget.book.edit(
          base.id,
          text.text,
          expectedRevision: base.revision,
        );
      }
      if (mounted) {
        widget.onSaved?.call();
        completeOwnedRoute<Record>(navigator, editorRoute, saved);
        if (messenger?.mounted ?? false) {
          messenger!.showSnackBar(const SnackBar(content: Text('已保存')));
        }
      }
    } catch (e) {
      // A write failure alone cannot distinguish a conflict from unavailable
      // storage. Read the source, without changing the draft or its revision.
      Record? latest;
      var checked = false;
      var missingParent = false;
      if (baseline != null) {
        try {
          latest = await widget.book.get(baseline!.id);
          checked = true;
        } catch (_) {
          /* Keep the actual save failure, not a false deletion. */
        }
      }
      if (baseline == null && widget.parentId != null && !standalone) {
        try {
          missingParent = await widget.book.get(widget.parentId!) == null;
        } catch (_) {
          /* An unreadable parent is not proof of deletion. */
        }
      }
      if (mounted) {
        setState(() {
          busy = false;
          error = '保存未完成。${userError(e)}';
          if (missingParent) {
            parentMissing = true;
            error = '原记录已删除，追加内容仍保留。';
          }
          if (checked &&
              (latest == null || latest.revision != baseline!.revision)) {
            showConflict(latest);
          }
        });
      }
    }
  }

  Future<void> saveStandalone() async {
    if (busy || confirming || text.text.trim().isEmpty) return;
    confirming = true;
    final accepted = await confirm(
      context,
      '保存为独立记录？',
      '原记录已不存在。本次文字将作为新的独立记录保存。',
      action: '保存为独立记录',
    );
    confirming = false;
    if (accepted && mounted) await save(standalone: true);
  }

  Future<void> copyDraft() async {
    try {
      await Clipboard.setData(ClipboardData(text: text.text));
      if (mounted) notice(context, '草稿已复制');
    } catch (_) {
      if (mounted) notice(context, '无法复制，可长按正文选择复制。');
    }
  }

  Future<void> latest({bool replace = false}) async {
    if (busy || baseline == null) return;
    if (replace) {
      if (confirming) return;
      confirming = true;
      final accepted = await confirm(
        context,
        '替换当前草稿？',
        '当前草稿将被最新正文替换。需要保留时，请先复制草稿。',
        action: '替换草稿',
      );
      confirming = false;
      if (!accepted || !mounted) return;
    }
    setState(() => busy = true);
    try {
      final value = await widget.book.get(baseline!.id);
      if (!mounted) return;
      setState(() {
        busy = false;
        if (value == null) {
          showConflict(null);
        } else if (replace) {
          baseline = value;
          text.value = TextEditingValue(
            text: value.body,
            selection: TextSelection.collapsed(offset: value.body.length),
          );
          conflict = null;
          deleted = false;
          error = null;
        } else {
          showConflict(value);
        }
      });
      if (value == null || replace) return;
      FocusScope.of(context).unfocus();
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('最新正文', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 16),
                  SelectableText(
                    value.body,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 20),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('返回草稿'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '最新内容暂时无法读取。${userError(e)}';
        });
      }
    }
  }

  Future<void> leave() async {
    if (busy || confirming) return;
    confirming = true;
    try {
      if (!dirty ||
          await confirm(
            context,
            '放弃尚未保存的修改？',
            '当前草稿将放弃，其他已保存内容不会改变。',
            action: '放弃修改',
          )) {
        if (mounted) Navigator.pop(context);
      }
    } finally {
      confirming = false;
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !dirty && !busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !busy) leave();
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
            onPressed: canSave ? save : null,
            child: Text(busy ? '保存中' : '保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ReadingWidth(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.parentId != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  '追加到：${parentTitle ?? '所属原记录'}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - 28).clamp(
                        0,
                        double.infinity,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (error != null) ...[
                          PaperSurface(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  liveRegion: true,
                                  child: Text(error!),
                                ),
                                if (parentMissing)
                                  Wrap(
                                    spacing: 8,
                                    children: [
                                      TextButton(
                                        onPressed: copyDraft,
                                        child: const Text('复制我的草稿'),
                                      ),
                                      TextButton(
                                        onPressed:
                                            busy || text.text.trim().isEmpty
                                            ? null
                                            : saveStandalone,
                                        child: const Text('保存为独立记录'),
                                      ),
                                    ],
                                  ),
                                if (conflict != null || deleted) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    deleted
                                        ? '可复制草稿后返回，不会另建记录。'
                                        : '先核对最新内容；载入前可复制保留自己的草稿。',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall,
                                  ),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      TextButton(
                                        onPressed: copyDraft,
                                        child: const Text('复制我的草稿'),
                                      ),
                                      if (!deleted)
                                        TextButton(
                                          onPressed: busy
                                              ? null
                                              : () => latest(),
                                          child: const Text('查看最新内容'),
                                        ),
                                      if (!deleted)
                                        TextButton(
                                          onPressed: busy
                                              ? null
                                              : () => latest(replace: true),
                                          child: const Text('载入最新正文'),
                                        ),
                                    ],
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        PaperSurface(
                          child: TextField(
                            key: const Key('body-editor'),
                            controller: text,
                            autofocus: true,
                            readOnly: busy,
                            minLines: 8,
                            maxLines: null,
                            maxLength: 100000,
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
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
