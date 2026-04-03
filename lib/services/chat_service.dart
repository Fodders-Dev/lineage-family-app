import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import '../models/chat_message.dart';
import '../models/chat_preview.dart';
import '../models/chat_send_progress.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/storage_service_interface.dart';

class ChatService implements ChatServiceInterface {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final StorageServiceInterface _storageService =
      GetIt.I<StorageServiceInterface>();

  @override
  String? get currentUserId => _auth.currentUser?.uid;

  // Отправка сообщения
  Future<void> _persistMessage(ChatMessage message) async {
    try {
      // Сохраняем сообщение
      final docRef =
          await _firestore.collection('messages').add(message.toMap());

      // Обновляем или создаем информацию о чате
      await _updateChatPreview(message);

      print('Сообщение отправлено с ID: ${docRef.id}');
    } catch (e) {
      print('Ошибка при отправке сообщения: $e');
      rethrow;
    }
  }

  @override
  String buildChatId(String otherUserId) {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('Пользователь не авторизован');
    }

    return currentUser.uid.compareTo(otherUserId) < 0
        ? '${currentUser.uid}_$otherUserId'
        : '${otherUserId}_${currentUser.uid}';
  }

  // Обновление информации о чате
  Future<void> _updateChatPreview(ChatMessage message) async {
    try {
      // ID текущего пользователя
      final currentUserId = _auth.currentUser!.uid;

      // ID другого пользователя
      final otherUserId =
          message.chatId.split('_').firstWhere((id) => id != currentUserId);

      // Получаем данные текущего пользователя
      final currentUserDoc =
          await _firestore.collection('users').doc(currentUserId).get();
      final currentUser = currentUserDoc.data() ?? {};

      // Получаем данные другого пользователя
      final otherUserDoc =
          await _firestore.collection('users').doc(otherUserId).get();
      final otherUser = otherUserDoc.data() ?? {};

      final previewText = message.text.isNotEmpty
          ? message.text
          : (message.mediaUrls != null && message.mediaUrls!.isNotEmpty
              ? 'Фото'
              : 'Сообщение');

      // Создаем/обновляем информацию о чате для текущего пользователя
      await _firestore
          .collection('chat_previews')
          .doc('${message.chatId}_$currentUserId')
          .set({
        'chatId': message.chatId,
        'userId': currentUserId,
        'otherUserId': otherUserId,
        'otherUserName': otherUser['displayName'] ?? 'Пользователь',
        'otherUserPhotoUrl': otherUser['photoURL'],
        'lastMessage': previewText,
        'lastMessageTime': message.timestamp,
        'unreadCount': 0, // текущий пользователь отправил, значит прочитал
        'lastMessageSenderId': message.senderId,
      }, SetOptions(merge: true));

      // Создаем/обновляем информацию о чате для другого пользователя
      await _firestore
          .collection('chat_previews')
          .doc('${message.chatId}_$otherUserId')
          .set({
        'chatId': message.chatId,
        'userId': otherUserId,
        'otherUserId': currentUserId,
        'otherUserName': currentUser['displayName'] ?? 'Пользователь',
        'otherUserPhotoUrl': currentUser['photoURL'],
        'lastMessage': previewText,
        'lastMessageTime': message.timestamp,
        'unreadCount': FieldValue.increment(1), // увеличиваем непрочитанное
        'lastMessageSenderId': message.senderId,
      }, SetOptions(merge: true));
    } catch (e) {
      print('Ошибка при обновлении информации о чате: $e');
    }
  }

  @override
  Future<void> markChatAsRead(String chatId, String userId) async {
    try {
      // Обновляем превью чата - снижаем счетчик непрочитанных до нуля
      await _firestore
          .collection('chat_previews')
          .doc('${chatId}_$userId')
          .update({'unreadCount': 0});

      // Находим все непрочитанные сообщения этого чата, отправленные не текущим пользователем
      final unreadMessagesQuery = await _firestore
          .collection('messages')
          .where('chatId', isEqualTo: chatId)
          .where('senderId', isNotEqualTo: userId)
          .where('isRead', isEqualTo: false)
          .get();

      // Отмечаем все сообщения как прочитанные
      final batch = _firestore.batch();
      for (var doc in unreadMessagesQuery.docs) {
        batch.update(doc.reference, {'isRead': true});
      }

      await batch.commit();
    } catch (e) {
      print('Ошибка при отметке чата как прочитанного: $e');
    }
  }

  // Получение всех чатов текущего пользователя
  @override
  Stream<List<ChatPreview>> getUserChatsStream(String userId) {
    return _firestore
        .collection('chat_previews')
        .where('userId', isEqualTo: userId)
        .orderBy('lastMessageTime', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return ChatPreview.fromMap({'id': doc.id, ...doc.data()});
      }).toList();
    });
  }

  // Получение общего количества непрочитанных сообщений
  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    return _firestore
        .collection('chat_previews')
        .where('userId', isEqualTo: userId)
        .snapshots()
        .map((snapshot) {
      int total = 0;
      for (var doc in snapshot.docs) {
        total += (doc.data()['unreadCount'] as int? ?? 0);
      }
      return total;
    });
  }

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return _firestore
        .collection('messages')
        .where('chatId', isEqualTo: chatId)
        .orderBy('timestamp', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return ChatMessage.fromMap({'id': doc.id, ...doc.data()});
      }).toList();
    });
  }

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) async {
    await sendMessage(otherUserId: otherUserId, text: text);
  }

  @override
  Future<void> sendMessage({
    required String otherUserId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) async {
    await sendMessageToChat(
      chatId: buildChatId(otherUserId),
      text: text,
      attachments: attachments,
    );
  }

  @override
  Future<void> sendMessageToChat({
    required String chatId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
    void Function(ChatSendProgress progress)? onProgress,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('Пользователь не авторизован');
    }

    final trimmedText = text.trim();
    if (trimmedText.isEmpty && attachments.isEmpty) {
      throw Exception('Сообщение не должно быть пустым');
    }

    final uploadedUrls = <String>[];
    if (attachments.isNotEmpty) {
      onProgress?.call(
        const ChatSendProgress(
          stage: ChatSendProgressStage.preparing,
          completed: 0,
          total: 1,
        ),
      );
      onProgress?.call(
        ChatSendProgress(
          stage: ChatSendProgressStage.uploading,
          completed: 0,
          total: attachments.length,
        ),
      );
    }

    for (var index = 0; index < attachments.length; index++) {
      final attachment = attachments[index];
      final uploadedUrl = await _storageService.uploadImage(
        attachment,
        'chat-images/${currentUser.uid}',
      );
      if (uploadedUrl != null && uploadedUrl.isNotEmpty) {
        uploadedUrls.add(uploadedUrl);
      }
      onProgress?.call(
        ChatSendProgress(
          stage: ChatSendProgressStage.uploading,
          completed: index + 1,
          total: attachments.length,
        ),
      );
    }

    final participants = chatId
        .split('_')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    if (!participants.contains(currentUser.uid) || participants.length < 2) {
      throw Exception('Групповые чаты пока недоступны в этом backend');
    }

    onProgress?.call(
      const ChatSendProgress(
        stage: ChatSendProgressStage.sending,
        completed: 1,
        total: 1,
      ),
    );

    final message = ChatMessage(
      id: '',
      chatId: chatId,
      senderId: currentUser.uid,
      text: trimmedText,
      timestamp: DateTime.now(),
      isRead: false,
      imageUrl: uploadedUrls.isNotEmpty ? uploadedUrls.first : null,
      mediaUrls: uploadedUrls.isNotEmpty ? uploadedUrls : null,
      participants: participants,
      senderName: currentUser.displayName ?? 'Пользователь',
    );

    await _persistMessage(message);
  }

  @override
  Future<String?> getOrCreateChat(String otherUserId) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) return null;

      // Создаем ID чата как комбинацию двух ID пользователей (меньший + больший)
      // Это обеспечивает уникальность ID чата для любой пары пользователей
      final chatId = currentUser.uid.compareTo(otherUserId) < 0
          ? '${currentUser.uid}_$otherUserId'
          : '${otherUserId}_${currentUser.uid}';

      // Проверяем, существует ли чат
      final chatDoc = await _firestore.collection('chats').doc(chatId).get();

      if (!chatDoc.exists) {
        // Если чата нет, создаем его
        await _firestore.collection('chats').doc(chatId).set({
          'participants': [currentUser.uid, otherUserId],
          'createdAt': FieldValue.serverTimestamp(),
          'lastMessage': null,
          'lastMessageTime': null,
        });

        // Добавляем чат в список чатов для обоих пользователей
        await _firestore
            .collection('users')
            .doc(currentUser.uid)
            .collection('chats')
            .doc(chatId)
            .set({
          'chatId': chatId,
          'otherUserId': otherUserId,
          'lastRead': FieldValue.serverTimestamp(),
          'unreadCount': 0,
        });

        await _firestore
            .collection('users')
            .doc(otherUserId)
            .collection('chats')
            .doc(chatId)
            .set({
          'chatId': chatId,
          'otherUserId': currentUser.uid,
          'lastRead': FieldValue.serverTimestamp(),
          'unreadCount': 0,
        });
      }

      return chatId;
    } catch (e) {
      print('Ошибка при создании/получении чата: $e');
      return null;
    }
  }

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        throw Exception('Пользователь не авторизован');
      }

      final normalizedParticipants = <String>{
        currentUser.uid,
        ...participantIds.where((value) => value.trim().isNotEmpty),
      }.toList()
        ..sort();
      if (normalizedParticipants.length < 3) {
        throw Exception('Нужно минимум два участника кроме вас');
      }

      final chatRef = _firestore.collection('chats').doc();
      final chatId = chatRef.id;
      final previewTitle =
          (title ?? '').trim().isNotEmpty ? title!.trim() : 'Групповой чат';
      final timestamp = Timestamp.now();

      await chatRef.set({
        'type': 'group',
        'title': previewTitle,
        'participantIds': normalizedParticipants,
        'treeId': treeId,
        'createdBy': currentUser.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      final batch = _firestore.batch();
      for (final participantId in normalizedParticipants) {
        batch.set(
          _firestore
              .collection('chat_previews')
              .doc('${chatId}_$participantId'),
          {
            'chatId': chatId,
            'userId': participantId,
            'type': 'group',
            'title': previewTitle,
            'participantIds': normalizedParticipants,
            'otherUserId': '',
            'otherUserName': previewTitle,
            'otherUserPhotoUrl': null,
            'lastMessage': '',
            'lastMessageTime': timestamp,
            'unreadCount': 0,
            'lastMessageSenderId': '',
          },
          SetOptions(merge: true),
        );
      }
      await batch.commit();

      return chatId;
    } catch (e) {
      print('Ошибка при создании группового чата: $e');
      return null;
    }
  }

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) async {
    return null;
  }
}
