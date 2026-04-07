import '../utils/date_parser.dart';

class ProfileNote {
  final String id;
  final String title;
  final String content;
  final DateTime createdAt;

  ProfileNote({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  factory ProfileNote.fromFirestore(dynamic doc) {
    final data =
        (doc.data != null ? (doc.data() as Map<String, dynamic>?) : null) ?? {};
    return ProfileNote(
      id: doc.id ?? '',
      title: data['title'] ?? '',
      content: data['content'] ?? '',
      createdAt: parseDateTimeRequired(data['createdAt']),
    );
  }

  factory ProfileNote.fromMap(Map<String, dynamic> map) {
    return ProfileNote(
      id: map['id'] ?? '',
      title: map['title'] ?? '',
      content: map['content'] ?? '',
      createdAt: parseDateTimeRequired(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
