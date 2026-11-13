Map<String, dynamic> validateOrganization(dynamic value, String source) {
  if (value is! Map<String, dynamic> ||
      value.keys.toSet().difference({'title', 'points', 'tasks'}).isNotEmpty) {
    throw const FormatException('invalid organization');
  }
  String text(dynamic v, int max, {bool empty = false}) {
    if (v is! String || v.length > max || (!empty && v.trim().isEmpty)) {
      throw const FormatException('invalid field');
    }
    return v;
  }

  final title = text(value['title'], 80);
  final points = value['points'];
  final tasks = value['tasks'];
  if (points is! List ||
      points.length > 8 ||
      tasks is! List ||
      tasks.length > 6) {
    throw const FormatException('invalid lists');
  }
  List<Map<String, dynamic>> validate(List list, bool task) => list.map((item) {
    if (item is! Map<String, dynamic> ||
        item.keys
            .toSet()
            .difference(
              task
                  ? {'title', 'evidence', 'timeText', 'location'}
                  : {'text', 'evidence'},
            )
            .isNotEmpty) {
      throw const FormatException('invalid item');
    }
    final evidence = text(item['evidence'], 400);
    if (!source.contains(evidence)) {
      throw const FormatException('missing evidence');
    }
    if (task) {
      final time = text(item['timeText'], 80, empty: true);
      final location = text(item['location'], 120, empty: true);
      if ((time.isNotEmpty && !source.contains(time)) ||
          (location.isNotEmpty && !source.contains(location))) {
        throw const FormatException('invented context');
      }
      return {
        'title': text(item['title'], 80),
        'evidence': evidence,
        'timeText': time,
        'location': location,
      };
    }
    return {'text': text(item['text'], 240), 'evidence': evidence};
  }).toList();
  return {
    'title': title,
    'points': validate(points, false),
    'tasks': validate(tasks, true),
  };
}
