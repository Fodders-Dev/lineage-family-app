import 'dart:convert';

class AppNotificationItem {
  const AppNotificationItem({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.data,
    required this.payload,
  });

  final String id;
  final String type;
  final String title;
  final String body;
  final DateTime? createdAt;
  final Map<String, dynamic> data;
  final String payload;

  factory AppNotificationItem.fromBackendJson(Map<String, dynamic> json) {
    final id = json['id']?.toString() ?? '';
    final type = json['type']?.toString() ?? 'generic';
    final data = _asStringDynamicMap(json['data']);

    return AppNotificationItem(
      id: id,
      type: type,
      title: json['title']?.toString() ?? 'Родня',
      body: json['body']?.toString() ?? '',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      data: data,
      payload: jsonEncode({
        'id': id,
        'type': type,
        'data': data,
      }),
    );
  }

  static Map<String, dynamic> _asStringDynamicMap(dynamic value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return value.map(
        (key, mapValue) => MapEntry(key.toString(), mapValue),
      );
    }
    return const <String, dynamic>{};
  }
}
