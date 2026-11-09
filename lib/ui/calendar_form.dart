import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../platform/calendar.dart';
import 'common.dart';

Future<void> openCalendar(
  BuildContext context, {
  String initialTitle = '',
  String location = '',
  String? evidence,
  bool stale = false,
}) => Navigator.push<void>(
  context,
  MaterialPageRoute(
    builder: (_) => _CalendarForm(
      initialTitle: initialTitle,
      initialLocation: location,
      evidence: evidence,
      stale: stale,
    ),
  ),
);

class _CalendarForm extends StatefulWidget {
  const _CalendarForm({
    required this.initialTitle,
    required this.initialLocation,
    this.evidence,
    this.stale = false,
  });
  final String initialTitle, initialLocation;
  final String? evidence;
  final bool stale;
  @override
  State<_CalendarForm> createState() => _CalendarFormState();
}

class _CalendarFormState extends State<_CalendarForm> {
  late final title = TextEditingController(
    text: widget.initialTitle.length > 200
        ? widget.initialTitle.substring(0, 200)
        : widget.initialTitle,
  );
  late final location = TextEditingController(text: widget.initialLocation);
  DateTime? day;
  TimeOfDay? start, end;
  int? reminder = 15;
  bool busy = false;
  bool attempted = false;
  CalendarOutcome? outcome;
  final bridge = CalendarBridge();
  String get plannedReminder => reminder == null
      ? '不提醒'
      : reminder == 0
      ? '开始时'
      : '开始前 $reminder 分钟';
  @override
  void dispose() {
    title.dispose();
    location.dispose();
    super.dispose();
  }

  CalendarEvent? event() {
    if (day == null || start == null || end == null) {
      notice(context, '请明确选择日期、开始和结束时间。');
      return null;
    }
    return CalendarEvent(
      title: title.text,
      location: location.text,
      start: DateTime(
        day!.year,
        day!.month,
        day!.day,
        start!.hour,
        start!.minute,
      ),
      end: DateTime(day!.year, day!.month, day!.day, end!.hour, end!.minute),
      reminderMinutes: reminder,
    );
  }

  Future<void> chooseDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: day ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) {
      setState(() => day = d);
    }
  }

  Future<void> chooseTime(bool beginning) async {
    final t = await showTimePicker(
      context: context,
      initialTime:
          (beginning ? start : end) ?? const TimeOfDay(hour: 9, minute: 0),
    );
    if (t != null) {
      setState(() {
        if (beginning) {
          start = t;
        } else {
          end = t;
        }
      });
    }
  }

  Future<void> send() async {
    final e = event();
    if (e == null) {
      return;
    }
    final error = e.validate();
    if (error != null) {
      notice(context, error);
      return;
    }
    if (attempted &&
        !await confirm(
          context,
          '再次打开日历？',
          '先检查日历中是否已经保存，重复操作可能创建重复事件。',
          action: '再次打开',
        )) {
      return;
    }
    setState(() => busy = true);
    final result = await bridge.open(e);
    if (mounted) {
      setState(() {
        busy = false;
        attempted = true;
        outcome = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('核对日历事项')),
    body: ReadingWidth(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        children: [
          if (widget.stale)
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('这条候选来自旧版本正文，请重新对照原文核对。'),
            ),
          if (widget.evidence != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Text(
                '原文依据：${widget.evidence}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          PaperSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: title,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '事项标题'),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: location,
                  maxLength: 200,
                  decoration: const InputDecoration(labelText: '地点（可选）'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          PaperSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('时间与提醒', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: busy ? null : chooseDay,
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(
                    day == null
                        ? '选择具体日期'
                        : '${day!.year}年${day!.month}月${day!.day}日',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    OutlinedButton(
                      onPressed: busy ? null : () => chooseTime(true),
                      child: Text(
                        start == null ? '开始时间' : '开始 ${start!.format(context)}',
                      ),
                    ),
                    OutlinedButton(
                      onPressed: busy ? null : () => chooseTime(false),
                      child: Text(
                        end == null ? '结束时间' : '结束 ${end!.format(context)}',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (start != null && end != null)
                  Text(
                    '时长：${(end!.hour * 60 + end!.minute) - (start!.hour * 60 + start!.minute)} 分钟（同一天）',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  isDense: false,
                  itemHeight: null,
                  initialValue: reminder,
                  decoration: InputDecoration(
                    labelText:
                        Theme.of(context).platform == TargetPlatform.android
                        ? '计划提醒时间'
                        : '提醒时间',
                  ),
                  items: const [
                    DropdownMenuItem(value: -1, child: Text('不提醒')),
                    DropdownMenuItem(value: 0, child: Text('开始时')),
                    DropdownMenuItem(value: 5, child: Text('开始前 5 分钟')),
                    DropdownMenuItem(value: 15, child: Text('开始前 15 分钟')),
                    DropdownMenuItem(value: 30, child: Text('开始前 30 分钟')),
                    DropdownMenuItem(value: 60, child: Text('开始前 1 小时')),
                  ],
                  onChanged: busy
                      ? null
                      : (v) => setState(() => reminder = v == -1 ? null : v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            Theme.of(context).platform == TargetPlatform.android
                ? '请在系统日历中手动设置提醒：$plannedReminder。本页尚未设置提醒，由你在系统页决定保存或取消。同步日历可能使事项离开设备。'
                : '接下来由你在系统日历中决定保存或取消。同步日历可能使事项离开设备。只传标题、地点、时间和提醒；请在系统页再次核对提醒。',
            style: const TextStyle(fontSize: 14, height: 1.6),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: busy || outcome == CalendarOutcome.saved ? null : send,
            icon: const Icon(Icons.open_in_new_rounded),
            label: Text(busy ? '正在打开' : '打开系统日历核对'),
          ),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: () {
              final e = event();
              if (e == null) {
                return;
              }
              Clipboard.setData(ClipboardData(text: e.copyText));
              notice(context, '已复制事项，尚未设置提醒');
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('复制事项信息'),
          ),
          if (outcome != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Semantics(liveRegion: true, child: Text(outcome!.message)),
            ),
        ],
      ),
    ),
  );
}
