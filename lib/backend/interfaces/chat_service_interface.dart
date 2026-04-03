import '../../models/chat_message.dart';
import '../../models/chat_preview.dart';
import '../../models/chat_send_progress.dart';
import 'package:image_picker/image_picker.dart';

abstract class ChatServiceInterface {
  String? get currentUserId;
  String buildChatId(String otherUserId);
  Stream<List<ChatPreview>> getUserChatsStream(String userId);
  Stream<int> getTotalUnreadCountStream(String userId);
  Stream<List<ChatMessage>> getMessagesStream(String chatId);
  Future<void> sendMessageToChat({
    required String chatId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
    void Function(ChatSendProgress progress)? onProgress,
  }) {
    throw UnsupportedError('sendMessageToChat is not supported');
  }

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
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) {
    throw UnsupportedError('createGroupChat is not supported');
  }

  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) {
    throw UnsupportedError('createBranchChat is not supported');
  }
}
