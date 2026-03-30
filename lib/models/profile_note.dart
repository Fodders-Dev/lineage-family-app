import 'package:cloud_firestore/cloud_firestore.dart';

class ProfileNote {
  final String id; // ID документа в Firestore
  final String title;
  final String content;
  final Timestamp createdAt; // Дата создания для сортировки

  ProfileNote({
    required this.id,
    required this.title,
    required this.content,
    required this.createdAt,
  });

  // Фабричный конструктор для создания из Firestore документа
  factory ProfileNote.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data()!;
    return ProfileNote(
      id: doc.id,
      title: data['title'] ?? '',
      content: data['content'] ?? '',
      createdAt: data['createdAt'] ??
          Timestamp.now(), // Предоставим значение по умолчанию
    );
  }

  // Метод для преобразования в Map для Firestore
  Map<String, dynamic> toFirestore() {
    return {
      'title': title,
      'content': content,
      // При создании используем FieldValue.serverTimestamp(),
      // но здесь оставляем createdAt для возможности обновления (хотя обычно не обновляют)
      'createdAt': createdAt,
    };
  }

  // Добавим метод toMap для удобства при обновлении
  Map<String, dynamic> toMap() {
    return {
      'title': title,
      'content': content,
      // createdAt не обновляем
    };
  }
}
