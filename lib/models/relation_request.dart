import '../utils/date_parser.dart';
import 'family_relation.dart';

enum RequestStatus {
  pending, // Ожидает подтверждения
  accepted, // Принято
  rejected, // Отклонено
  canceled, // Отменено отправителем
}

/// Запрос на подтверждение родства между реальными пользователями
class RelationRequest {
  final String id;
  final String treeId; // ID семейного дерева
  final String senderId; // ID отправителя (пользователя)
  final String recipientId; // ID получателя (пользователя)
  final RelationType
      senderToRecipient; // Как отправитель относится к получателю
  final String?
      targetPersonId; // ID офлайн-записи FamilyPerson, которую связываем (если применимо)
  final DateTime createdAt; // Когда создан запрос
  final DateTime? respondedAt; // Когда был дан ответ
  final RequestStatus status; // Статус запроса
  final String? message; // Сообщение к запросу

  RelationRequest({
    required this.id,
    required this.treeId,
    required this.senderId,
    required this.recipientId,
    required this.senderToRecipient,
    this.targetPersonId,
    required this.createdAt,
    this.respondedAt,
    this.status = RequestStatus.pending,
    this.message,
  });

  factory RelationRequest.fromFirestore(dynamic doc) {
    final data = doc.data() as Map<String, dynamic>;
    return RelationRequest(
      id: doc.id,
      treeId: data['treeId'] ?? '',
      senderId: data['senderId'] ?? '',
      recipientId: data['recipientId'] ?? '',
      senderToRecipient: stringToRelationType(
        data['senderToRecipient'] ?? data['relationType'] ?? 'other',
      ),
      targetPersonId: data['targetPersonId'] ?? data['offlineRelativeId'],
      createdAt: parseDateTimeRequired(data['createdAt']),
      respondedAt: data['respondedAt'] != null
          ? parseDateTimeRequired(data['respondedAt'])
          : null,
      status: _stringToRequestStatus(data['status'] ?? 'pending'),
      message: data['message'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'treeId': treeId,
      'senderId': senderId,
      'recipientId': recipientId,
      'senderToRecipient': relationTypeToString(senderToRecipient),
      'targetPersonId': targetPersonId,
      'createdAt': createdAt.toIso8601String(),
      'respondedAt': respondedAt?.toIso8601String(),
      'status': requestStatusToString(status),
      'message': message,
    };
  }

  // Конвертация статуса запроса из строки
  static RequestStatus _stringToRequestStatus(String value) {
    switch (value) {
      case 'accepted':
        return RequestStatus.accepted;
      case 'rejected':
        return RequestStatus.rejected;
      case 'canceled':
        return RequestStatus.canceled;
      default:
        return RequestStatus.pending;
    }
  }

  // Конвертация статуса запроса в строку
  static String requestStatusToString(RequestStatus status) {
    switch (status) {
      case RequestStatus.accepted:
        return 'accepted';
      case RequestStatus.rejected:
        return 'rejected';
      case RequestStatus.canceled:
        return 'canceled';
      case RequestStatus.pending:
        return 'pending';
    }
  }

  // Вспомогательные методы для преобразования RelationType
  static RelationType stringToRelationType(String value) {
    return FamilyRelation.stringToRelationType(value);
  }

  static String relationTypeToString(RelationType type) {
    return FamilyRelation.relationTypeToString(type);
  }

  // Получение ответного отношения
  RelationType getRecipientToSender() {
    return FamilyRelation.getMirrorRelation(senderToRecipient);
  }

  // Проверка, может ли запрос быть отменен
  bool canCancel() {
    return status == RequestStatus.pending;
  }

  // Проверка, может ли запрос быть обработан (принят/отклонен)
  bool canRespond() {
    return status == RequestStatus.pending;
  }
}
