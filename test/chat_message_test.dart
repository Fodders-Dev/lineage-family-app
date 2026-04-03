import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/models/chat_attachment.dart';
import 'package:lineage/models/chat_message.dart';

void main() {
  test('ChatMessage reads typed attachments from payload', () {
    final message = ChatMessage.fromMap({
      'id': 'message-1',
      'chatId': 'chat-1',
      'senderId': 'user-1',
      'text': '',
      'timestamp': '2026-04-04T12:00:00.000Z',
      'isRead': false,
      'participants': const ['user-1', 'user-2'],
      'attachments': const [
        {
          'type': 'video',
          'url': 'https://cdn.example.test/clip.mp4',
          'mimeType': 'video/mp4',
          'fileName': 'clip.mp4',
          'sizeBytes': 1024,
        },
      ],
    });

    expect(message.attachments, hasLength(1));
    expect(message.attachments.first.type, ChatAttachmentType.video);
    expect(message.attachments.first.url, 'https://cdn.example.test/clip.mp4');
    expect(message.mediaUrls, ['https://cdn.example.test/clip.mp4']);
    expect(message.imageUrl, 'https://cdn.example.test/clip.mp4');
  });

  test('ChatMessage falls back to legacy imageUrl/mediaUrls', () {
    final message = ChatMessage.fromMap({
      'id': 'message-2',
      'chatId': 'chat-1',
      'senderId': 'user-1',
      'text': '',
      'timestamp': '2026-04-04T12:00:00.000Z',
      'isRead': false,
      'participants': const ['user-1', 'user-2'],
      'imageUrl': 'https://cdn.example.test/photo-1.jpg',
      'mediaUrls': const [
        'https://cdn.example.test/photo-1.jpg',
        'https://cdn.example.test/photo-2.jpg',
      ],
    });

    expect(message.attachments, hasLength(2));
    expect(
      message.attachments.every(
        (attachment) => attachment.type == ChatAttachmentType.image,
      ),
      isTrue,
    );
    expect(message.mediaUrls, [
      'https://cdn.example.test/photo-1.jpg',
      'https://cdn.example.test/photo-2.jpg',
    ]);
    expect(message.toMap()['attachments'], isNotEmpty);
  });
}
