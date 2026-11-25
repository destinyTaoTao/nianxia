import 'dart:async';

import 'package:flutter/material.dart';

import '../app/notebook.dart';
import '../platform/playback_coordinator.dart';
import 'common.dart';

/// Resolves one current source only after the user requests playback.
class ResultPlaybackButton extends StatefulWidget {
  const ResultPlaybackButton({super.key, required this.book, required this.id});
  final Notebook book;
  final String id;
  @override
  State<ResultPlaybackButton> createState() => _ResultPlaybackButtonState();
}

class _ResultPlaybackButtonState extends State<ResultPlaybackButton>
    with WidgetsBindingObserver {
  final owner = Object();
  late final playback = PlaybackCoordinator.retain(widget.book);
  int epoch = 0;
  bool resolving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.book.contentChanges.addListener(sourceChanged);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      epoch++;
      resolving = false;
      stop();
    }
  }

  bool get foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  void stop() {
    unawaited(playback.stop(owner: owner).catchError((Object _) {}));
  }

  void sourceChanged() {
    epoch++;
    stop();
    if (mounted) {
      setState(() {
        resolving = false;
        error = null;
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!(ModalRoute.of(context)?.isCurrent ?? true)) {
      epoch++;
      resolving = false;
      stop();
    }
  }

  Future<void> toggle() async {
    if (resolving || playback.blocked || !foreground) return;
    final request = ++epoch;
    setState(() {
      resolving = true;
      error = null;
    });
    try {
      final record = await widget.book.get(widget.id);
      if (!mounted ||
          request != epoch ||
          !foreground ||
          !(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      if (record == null || record.audio == null) {
        notice(context, record == null ? '这条记录已删除，请更新查找。' : '这条记录当前没有可回放的音频。');
        return;
      }
      await playback.toggle(owner, widget.book.audioPath(record));
    } catch (_) {
      if (mounted && request == epoch) setState(() => error = '暂时无法读取音频，请重试。');
    } finally {
      if (mounted && request == epoch) setState(() => resolving = false);
    }
  }

  @override
  void dispose() {
    epoch++;
    WidgetsBinding.instance.removeObserver(this);
    widget.book.contentChanges.removeListener(sourceChanged);
    stop();
    unawaited(playback.release().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: playback,
    builder: (context, _) {
      final current = playback.owns(owner);
      final playing = current && playback.playing;
      final busy = resolving || current && playback.busy;
      final failure = error ?? (current ? playback.error : null);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: playing ? '暂停原音频' : '播放原音频',
            child: TextButton.icon(
              key: ValueKey('result-play-${widget.id}'),
              onPressed: busy || playback.blocked ? null : toggle,
              icon: Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              ),
              label: Text(
                busy
                    ? '正在准备'
                    : failure != null
                    ? '重试播放'
                    : playing
                    ? '暂停'
                    : '播放原音',
              ),
            ),
          ),
          if (failure != null)
            Semantics(
              liveRegion: true,
              child: Text(
                failure,
                maxLines: 3,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      );
    },
  );
}
