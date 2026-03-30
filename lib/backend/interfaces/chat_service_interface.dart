import '../../models/chat_message.dart';
import '../../models/chat_preview.dart';
import 'package:image_picker/image_picker.dart';

abstract class ChatServiceInterface {
  String? get currentUserId;
  String buildChatId(String otherUserId);
  Stream<List<ChatPreview>> getUserChatsStream(String userId);
  Stream<int> getTotalUnreadCountStream(String userId);
  Stream<List<ChatMessage>> getMessagesStream(String chatId);
  Future<void> sendMessage({
    required String otherUserId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  });
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) {
    return sendMessage(otherUserId: otherUserId, text: text);
  }

  Future<void> markChatAsRead(String chatId, String userId);
  Future<String?> getOrCreateChat(String otherUserId);
}
