import 'package:flutter/services.dart';

class CalendarEvent {
  const CalendarEvent({
    required this.title,
    required this.start,
    required this.end,
    this.location = '',
    this.reminderMinutes,
  });
  final String title, location;
  final DateTime start, end;
  final int? reminderMinutes;
  String? validate() {
    if (title.trim().isEmpty || title.length > 200 || location.length > 200) {
      return '请填写 1–200 字标题，地点不超过 200 字。';
    }
    if (!end.isAfter(start) ||
        end.difference(start) > const Duration(days: 7)) {
      return '结束时间须晚于开始时间，时长不超过七天。';
    }
    if (reminderMinutes != null &&
        (reminderMinutes! < 0 || reminderMinutes! > 10080)) {
      return '提醒须在开始前 0–10,080 分钟内。';
    }
    return null;
  }

  Map<String, dynamic> toMap() => {
    'title': title.trim(),
    'location': location.trim(),
    'start': start.millisecondsSinceEpoch,
    'end': end.millisecondsSinceEpoch,
    'reminderMinutes': reminderMinutes,
  };
  String get copyText =>
      '$title\n${start.toLocal()} 至 ${end.toLocal()}\n$location\n${reminderMinutes == null ? '不提醒' : '开始前 $reminderMinutes 分钟提醒'}';
}

enum CalendarOutcome {
  saved('已保存到系统日历'),
  cancelled('已取消，尚未设置提醒'),
  unknown('保存未确认，请在日历中核对；不要重复添加'),
  unavailable('无法打开日历，尚未设置提醒，可复制事项');

  const CalendarOutcome(this.message);
  final String message;
}

class CalendarBridge {
  static const _channel = MethodChannel('app.nianxia/system');
  bool _busy = false;
  Future<CalendarOutcome> open(CalendarEvent event) async {
    final error = event.validate();
    if (error != null) {
      throw ArgumentError(error);
    }
    if (_busy) {
      return CalendarOutcome.unknown;
    }
    _busy = true;
    try {
      final result = await _channel.invokeMethod<String>(
        'calendar',
        event.toMap(),
      );
      return CalendarOutcome.values.firstWhere(
        (s) => s.name == result,
        orElse: () => CalendarOutcome.unknown,
      );
    } on PlatformException {
      return CalendarOutcome.unavailable;
    } on MissingPluginException {
      return CalendarOutcome.unavailable;
    } finally {
      _busy = false;
    }
  }
}
