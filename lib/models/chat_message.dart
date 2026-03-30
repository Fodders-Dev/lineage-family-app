import 'package:hive/hive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

part 'chat_message.g.dart';

@HiveType(typeId: 4)
class ChatMessage extends HiveObject {
  @HiveField(0)
  final String id;
  @HiveField(1)
  final String chatId;
  @HiveField(2)
  final String senderId;
  @HiveField(3)
  final String text;
  @HiveField(4)
  final DateTime timestamp;
  @HiveField(5)
  final bool isRead;
  @HiveField(6)
  final String? imageUrl;
  @HiveField(7)
  final List<String>? mediaUrls;
  @HiveField(8)
  final List<String> participants;
  @HiveField(9)
  final String? senderName;

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.isRead,
    this.imageUrl,
    this.mediaUrls,
    required this.participants,
    this.senderName,
  });

  DateTime getDateTime() {
    return timestamp;
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    DateTime parsedTimestamp;
    final ts = map['timestamp'];
    if (ts is DateTime) {
      parsedTimestamp = ts;
    } else if (ts is Timestamp) {
      parsedTimestamp = ts.toDate();
    } else if (ts is String) {
      parsedTimestamp = DateTime.tryParse(ts) ?? DateTime.now();
    } else {
      parsedTimestamp = DateTime.now();
    }

    return ChatMessage(
      id: map['id'] ?? '',
      chatId: map['chatId'] ?? '',
      senderId: map['senderId'] ?? '',
      text: map['text'] ?? '',
      timestamp: parsedTimestamp,
      isRead: map['isRead'] ?? false,
      imageUrl: map['imageUrl'],
      mediaUrls:
          map['mediaUrls'] != null ? List<String>.from(map['mediaUrls']) : null,
      participants: List<String>.from(map['participants'] ?? []),
      senderName: map['senderName'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'chatId': chatId,
      'senderId': senderId,
      'text': text,
      'timestamp': Timestamp.fromDate(timestamp),
      'isRead': isRead,
      'imageUrl': imageUrl,
      'mediaUrls': mediaUrls,
      'participants': participants,
      'senderName': senderName,
    };
  }

  factory ChatMessage.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return ChatMessage(
      id: doc.id,
      chatId: data['chatId'] ?? '',
      senderId: data['senderId'] ?? '',
      text: data['text'] ?? '',
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRead: data['isRead'] ?? false,
      imageUrl: data['imageUrl'] as String?,
      mediaUrls: (data['mediaUrls'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      participants: (data['participants'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      senderName: data['senderName'] as String?,
    );
  }

  static ChatMessage create({
    required String chatId,
    required String senderId,
    required String text,
    String? imageUrl,
    List<String>? mediaUrls,
    required List<String> participants,
    String? senderName,
  }) {
    return ChatMessage(
      id: FirebaseFirestore.instance.collection('messages').doc().id,
      chatId: chatId,
      senderId: senderId,
      text: text,
      timestamp: DateTime.now(),
      isRead: false,
      imageUrl: imageUrl,
      mediaUrls: mediaUrls,
      participants: participants,
      senderName: senderName,
    );
  }
}
