import 'package:flutter/material.dart';

import '../app/notebook.dart';
import 'common.dart';
import 'hold_recorder.dart';
import '../app/capture_session_controller.dart';
import '../platform/capture_controller.dart';
import '../platform/local_models.dart';

bool sameRecordedDay(Record a, Record b) {
  final x = a.recordedLocal, y = b.recordedLocal;
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

class NotebookDayHeading extends StatelessWidget {
  const NotebookDayHeading({
    super.key,
    required this.record,
    required this.now,
  });
  final Record record;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final day = record.recordedLocal;
    final today = DateTime.utc(now.year, now.month, now.day);
    final difference = today
        .difference(DateTime.utc(day.year, day.month, day.day))
        .inDays;
    final year = day.year == now.year ? '' : '${day.year}年';
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 10),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 10,
        children: [
          Text(
            '$year${day.month}月${day.day}日',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (difference == 0 || difference == 1)
            Text(
              difference == 0 ? '今天' : '昨天',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class NotebookEntry extends StatelessWidget {
  const NotebookEntry({
    super.key,
    required this.record,
    required this.appendCount,
    required this.onOpen,
    required this.onFavorite,
  });
  final Record record;
  final int appendCount;
  final VoidCallback onOpen, onFavorite;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = record.recordedLocal;
    final time =
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    final title = record.body.trim().isEmpty ? '$time 的录音' : record.title;
    final remainder = record.body.trim().split('\n').skip(1).join('\n').trim();
    final wideText = MediaQuery.textScalerOf(context).scale(14) > 22;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium,
        ),
        if (remainder.isNotEmpty)
          Text(
            remainder,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          ),
        if (record.audio != null || record.parentId != null || appendCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (record.audio != null)
                  Semantics(
                    label: '语音记录 ${durationText(record.durationMs)}，打开详情回放',
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow_rounded, size: 18),
                        Text(
                          durationText(record.durationMs),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                if (record.transcription == 'pending' ||
                    record.transcription == 'running')
                  Text(
                    record.transcription == 'running' ? '正在转写' : '等待转写',
                    style: theme.textTheme.bodySmall,
                  ),
                if (record.transcription == 'failed')
                  Text('转写失败，音频已保存', style: theme.textTheme.bodySmall),
                if (record.parentId != null)
                  Text('追加内容', style: theme.textTheme.bodySmall),
                if (appendCount > 0)
                  Text('$appendCount 次追加', style: theme.textTheme.bodySmall),
              ],
            ),
          ),
      ],
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!wideText)
                Padding(
                  padding: const EdgeInsets.only(top: 3, right: 12),
                  child: Text(time, style: theme.textTheme.bodySmall),
                ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (wideText) Text(time, style: theme.textTheme.bodySmall),
                    content,
                  ],
                ),
              ),
              IconButton(
                tooltip: '${record.favorite ? '取消收藏' : '收藏'}：$title',
                onPressed: onFavorite,
                icon: Icon(
                  record.favorite
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeComposer extends StatefulWidget {
  const HomeComposer({
    super.key,
    required this.book,
    required this.onRecord,
    required this.onSaved,
    required this.onHoldActive,
    required this.onRecovery,
    this.captureSession,
    this.microphone,
    this.models,
  });
  final Notebook book;
  final VoidCallback onRecord, onSaved, onRecovery;
  final ValueChanged<bool> onHoldActive;
  final CaptureSessionController? captureSession;
  final MicrophoneInput? microphone;
  final LocalModels? models;
  @override
  State<HomeComposer> createState() => _HomeComposerState();
}

class _HomeComposerState extends State<HomeComposer> {
  final text = TextEditingController();
  final focus = FocusNode();
  bool writing = false, busy = false, holding = false;
  String? error;
  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }

  void mode(bool value) {
    if (busy || holding) return;
    setState(() => writing = value);
    if (value) {
      focus.requestFocus();
    } else {
      focus.unfocus();
    }
  }

  Future<void> save() async {
    if (busy || text.text.trim().isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.book.saveText(text.text);
      if (!mounted) return;
      text.clear();
      focus.unfocus();
      setState(() {
        writing = false;
        busy = false;
      });
      widget.onSaved();
      notice(context, '已保存');
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = userError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !holding && !writing && text.text.isEmpty && !busy,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || busy || holding) return;
        if (writing) {
          mode(false);
          return;
        }
        if (await confirm(context, '放弃尚未保存的文字？', '这次输入还未保存。', action: '放弃文字')) {
          if (mounted) setState(text.clear);
        }
      },
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: ReadingWidth(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight:
                    (MediaQuery.sizeOf(context).height -
                        MediaQuery.viewInsetsOf(context).bottom) *
                    .65,
              ),
              child: SingleChildScrollView(
                clipBehavior: Clip.none,
                physics: holding ? const NeverScrollableScrollPhysics() : null,
                child: Material(
                  color: theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(20),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 4,
                          children: [
                            TextButton(
                              key: const Key('home-mode-voice'),
                              onPressed: busy || holding
                                  ? null
                                  : () => mode(false),
                              child: Text(
                                '说话',
                                style: TextStyle(
                                  fontWeight: !writing
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            TextButton(
                              key: const Key('home-mode-text'),
                              onPressed: busy || holding
                                  ? null
                                  : () => mode(true),
                              child: Text(
                                '写文字',
                                style: TextStyle(
                                  fontWeight: writing
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (writing)
                              IconButton(
                                tooltip: '返回',
                                onPressed: busy || holding
                                    ? null
                                    : () => mode(false),
                                icon: const Icon(Icons.keyboard_hide_outlined),
                              ),
                          ],
                        ),
                        if (writing) ...[
                          TextField(
                            key: const Key('body-editor'),
                            controller: text,
                            focusNode: focus,
                            enabled: !busy,
                            minLines: 1,
                            maxLines: 3,
                            maxLength: 100000,
                            decoration: const InputDecoration(
                              hintText: '此刻在想什么？',
                              counterText: '',
                              border: InputBorder.none,
                            ),
                            onChanged: (_) => setState(() => error = null),
                          ),
                          if (error != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: Semantics(
                                liveRegion: true,
                                child: Text(
                                  error!,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                            ),
                          FilledButton(
                            key: const Key('home-save-text'),
                            onPressed: busy || text.text.trim().isEmpty
                                ? null
                                : save,
                            child: Text(busy ? '保存中' : '保存'),
                          ),
                        ] else
                          HoldRecorder(
                            book: widget.book,
                            models: widget.models,
                            native: widget.captureSession,
                            microphone: widget.microphone,
                            onTapRecord: widget.onRecord,
                            onSaved: widget.onSaved,
                            onRecovery: widget.onRecovery,
                            onActive: (value) {
                              setState(() => holding = value);
                              widget.onHoldActive(value);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
