import 'package:cloud_firestore/cloud_firestore.dart';

class ChatPreview {
  final String id;
  final String chatId;
  final String userId;
  final String otherUserId;
  final String otherUserName;
  final String? otherUserPhotoUrl;
  final String lastMessage;
  final Timestamp lastMessageTime;
  final int unreadCount;
  final String lastMessageSenderId;

  ChatPreview({
    required this.id,
    required this.chatId,
    required this.userId,
    required this.otherUserId,
    required this.otherUserName,
    this.otherUserPhotoUrl,
    required this.lastMessage,
    required this.lastMessageTime,
    required this.unreadCount,
    required this.lastMessageSenderId,
  });

  factory ChatPreview.fromMap(Map<String, dynamic> map) {
    return ChatPreview(
      id: map['id'] ?? '',
      chatId: map['chatId'] ?? '',
      userId: map['userId'] ?? '',
      otherUserId: map['otherUserId'] ?? '',
      otherUserName: map['otherUserName'] ?? 'Пользователь',
      otherUserPhotoUrl: map['otherUserPhotoUrl'],
      lastMessage: map['lastMessage'] ?? '',
      lastMessageTime: map['lastMessageTime'] as Timestamp,
      unreadCount: map['unreadCount'] ?? 0,
      lastMessageSenderId: map['lastMessageSenderId'] ?? '',
    );
  }
}
