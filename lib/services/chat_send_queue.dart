import 'dart:async';

import 'package:image_picker/image_picker.dart';

import '../backend/interfaces/chat_service_interface.dart';
import '../models/chat_attachment.dart';
import '../models/chat_message.dart';
import '../models/chat_send_progress.dart';
import 'custom_api_auth_service.dart';
import 'pending_send_queue.dart';

enum ChatPendingMessageStatus { pending, sent, failed }

/// Пофайловый статус загрузки вложения исходящего сообщения —
/// деривация из (status, progress): загрузка идёт строго последовательно
/// в порядке attachments, completed растёт по одному (UX-аудит P1:
/// вместо одного общего бара «2/5» — состояние на каждом превью).
enum ChatAttachmentUploadStatus { queued, uploading, done, failed }

class ChatPendingMessage {
  const ChatPendingMessage({
    required this.localId,
    required this.chatId,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.attachments,
    required this.forwardedAttachments,
    required this.status,
    this.replyTo,
    this.progress,
    this.errorText,
    this.expiresInSeconds,
  });

  final String localId;
  final String chatId;
  final String senderId;
  final String text;
  final DateTime timestamp;
  final List<XFile> attachments;
  final List<ChatAttachment> forwardedAttachments;
  final ChatPendingMessageStatus status;
  final ChatReplyReference? replyTo;
  final ChatSendProgress? progress;
  final String? errorText;
  final int? expiresInSeconds;

  /// Статусы загрузки по каждому вложению (длина == attachments.length).
  /// Правила: sent → все done; failed → i < completed done, остальные
  /// failed (упавший файл ≈ первый не-загруженный); pending+preparing →
  /// все queued; pending+uploading → i < completed done, i == completed
  /// uploading, дальше queued; pending+sending (или без progress при
  /// вложениях — уже финальный POST) → все done.
  List<ChatAttachmentUploadStatus> get attachmentUploadStatuses {
    final total = attachments.length;
    if (total == 0) {
      return const <ChatAttachmentUploadStatus>[];
    }
    if (status == ChatPendingMessageStatus.sent) {
      return List<ChatAttachmentUploadStatus>.filled(
        total,
        ChatAttachmentUploadStatus.done,
      );
    }
    final currentProgress = progress;
    final completed = currentProgress?.completed ?? 0;
    if (status == ChatPendingMessageStatus.failed) {
      // Стадия sending — файлы УЖЕ загружены (сервис эмитит completed/
      // total в POST-единицах 1/1, не в файловых): упал финальный POST,
      // плитки все done, сообщение ретраится целиком кнопкой «Повторить».
      // Иначе (uploading/preparing) — completed в файловых единицах:
      // догруженные done, начиная с упавшего — failed.
      if (currentProgress?.stage == ChatSendProgressStage.sending) {
        return List<ChatAttachmentUploadStatus>.filled(
          total,
          ChatAttachmentUploadStatus.done,
        );
      }
      return List<ChatAttachmentUploadStatus>.generate(
        total,
        (i) => i < completed
            ? ChatAttachmentUploadStatus.done
            : ChatAttachmentUploadStatus.failed,
      );
    }
    switch (currentProgress?.stage) {
      case ChatSendProgressStage.preparing:
        return List<ChatAttachmentUploadStatus>.filled(
          total,
          ChatAttachmentUploadStatus.queued,
        );
      case ChatSendProgressStage.uploading:
        return List<ChatAttachmentUploadStatus>.generate(
          total,
          (i) => i < completed
              ? ChatAttachmentUploadStatus.done
              : (i == completed
                  ? ChatAttachmentUploadStatus.uploading
                  : ChatAttachmentUploadStatus.queued),
        );
      case ChatSendProgressStage.sending:
      case null:
        return List<ChatAttachmentUploadStatus>.filled(
          total,
          ChatAttachmentUploadStatus.done,
        );
    }
  }

  ChatPendingMessage copyWith({
    ChatPendingMessageStatus? status,
    ChatSendProgress? progress,
    String? errorText,
  }) {
    return ChatPendingMessage(
      localId: localId,
      chatId: chatId,
      senderId: senderId,
      text: text,
      timestamp: timestamp,
      attachments: attachments,
      forwardedAttachments: forwardedAttachments,
      status: status ?? this.status,
      replyTo: replyTo,
      progress: progress ?? this.progress,
      errorText: errorText,
      expiresInSeconds: expiresInSeconds,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'localId': localId,
      'chatId': chatId,
      'senderId': senderId,
      'text': text,
      'timestamp': timestamp.toIso8601String(),
      'attachments': attachments.map(_xFileToJson).toList(growable: false),
      'forwardedAttachments': forwardedAttachments
          .map((attachment) => attachment.toMap())
          .toList(growable: false),
      'status': status.name,
      if (replyTo != null) 'replyTo': replyTo!.toMap(),
      if (progress != null) 'progress': _progressToJson(progress!),
      if (errorText != null && errorText!.trim().isNotEmpty)
        'errorText': errorText,
      if (expiresInSeconds != null) 'expiresInSeconds': expiresInSeconds,
    };
  }

  factory ChatPendingMessage.fromJson(Map<String, dynamic> json) {
    final status = ChatPendingMessageStatus.values.firstWhere(
      (value) => value.name == json['status']?.toString(),
      orElse: () => ChatPendingMessageStatus.failed,
    );
    return ChatPendingMessage(
      localId: json['localId']?.toString() ?? '',
      chatId: json['chatId']?.toString() ?? '',
      senderId: json['senderId']?.toString() ?? '',
      text: json['text']?.toString() ?? '',
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      attachments: _xFilesFromJson(json['attachments']),
      forwardedAttachments:
          ChatAttachment.listFromDynamic(json['forwardedAttachments']),
      status: status,
      replyTo: _replyFromJson(json['replyTo']),
      progress: _progressFromJson(json['progress']),
      errorText: json['errorText']?.toString(),
      expiresInSeconds: _asInt(json['expiresInSeconds']),
    );
  }

  static Map<String, dynamic> _xFileToJson(XFile file) {
    return <String, dynamic>{
      'path': file.path,
      'name': file.name,
      if (file.mimeType != null && file.mimeType!.isNotEmpty)
        'mimeType': file.mimeType,
    };
  }

  static List<XFile> _xFilesFromJson(dynamic raw) {
    if (raw is! List<dynamic>) {
      return const <XFile>[];
    }
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .map((entry) {
          final filePath = entry['path']?.toString() ?? '';
          if (filePath.trim().isEmpty) {
            return null;
          }
          return XFile(
            filePath,
            name: entry['name']?.toString(),
            mimeType: entry['mimeType']?.toString(),
          );
        })
        .whereType<XFile>()
        .toList(growable: false);
  }

  static ChatReplyReference? _replyFromJson(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      final reply = ChatReplyReference.fromMap(raw);
      return reply.messageId.isEmpty ? null : reply;
    }
    if (raw is Map) {
      final reply = ChatReplyReference.fromMap(Map<String, dynamic>.from(raw));
      return reply.messageId.isEmpty ? null : reply;
    }
    return null;
  }

  static Map<String, dynamic> _progressToJson(ChatSendProgress progress) {
    return <String, dynamic>{
      'stage': progress.stage.name,
      'completed': progress.completed,
      'total': progress.total,
    };
  }

  static ChatSendProgress? _progressFromJson(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(raw);
    final stage = ChatSendProgressStage.values.firstWhere(
      (value) => value.name == map['stage']?.toString(),
      orElse: () => ChatSendProgressStage.sending,
    );
    return ChatSendProgress(
      stage: stage,
      completed: _asInt(map['completed']) ?? 0,
      total: _asInt(map['total']) ?? 1,
    );
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}

/// Очередь исходящих сообщений чата. Вся механика (Hive-recovery, дедуп
/// in-flight, автоповтор при возврате сети, notify-до-persist) живёт в
/// [PendingSendQueue] — она извлечена ОТСЮДА без изменения поведения, чат
/// остаётся её эталонным потребителем. Здесь — только модель сообщения,
/// таймауты и серверный echo-дедуп.
class ChatSendQueue extends PendingSendQueue<ChatPendingMessage> {
  ChatSendQueue({
    required ChatServiceInterface chatService,
    super.appStatusService,
    String boxName = 'chat_send_queue_v1',
  })  : _chatService = chatService,
        super(boxName: boxName);

  ChatSendQueue.memory({
    required ChatServiceInterface chatService,
    super.appStatusService,
  })  : _chatService = chatService,
        super(boxName: null);

  final ChatServiceInterface _chatService;

  List<ChatPendingMessage> messagesFor(String chatId) => itemsFor(chatId);

  Future<void> restoreChat(String chatId) => restoreKey(chatId);

  Future<ChatPendingMessage> enqueue({
    required String chatId,
    required String senderId,
    required String text,
    List<XFile> attachments = const <XFile>[],
    List<ChatAttachment> forwardedAttachments = const <ChatAttachment>[],
    ChatReplyReference? replyTo,
    int? expiresInSeconds,
  }) async {
    final normalizedChatId = chatId.trim();
    if (normalizedChatId.isEmpty) {
      throw StateError('Чат недоступен');
    }
    if (text.trim().isEmpty &&
        attachments.isEmpty &&
        forwardedAttachments.isEmpty) {
      throw StateError('Сообщение не должно быть пустым');
    }

    await restoreChat(normalizedChatId);

    final message = ChatPendingMessage(
      localId: newLocalId(),
      chatId: normalizedChatId,
      senderId: senderId,
      text: text,
      timestamp: DateTime.now(),
      attachments: List<XFile>.from(attachments),
      forwardedAttachments: List<ChatAttachment>.from(forwardedAttachments),
      status: ChatPendingMessageStatus.pending,
      replyTo: replyTo,
      progress: attachments.isNotEmpty
          ? ChatSendProgress(
              stage: ChatSendProgressStage.preparing,
              completed: 0,
              total: attachments.length,
            )
          : const ChatSendProgress(
              stage: ChatSendProgressStage.sending,
              completed: 1,
              total: 1,
            ),
      expiresInSeconds: expiresInSeconds,
    );
    addAndSend(message);
    return message;
  }

  Future<void> retry(String chatId, String clientMessageId) =>
      retryItem(chatId, clientMessageId);

  Future<void> remove(String chatId, String clientMessageId) =>
      removeItem(chatId, clientMessageId);

  Future<void> confirmRemoteMessages(
    String chatId,
    List<ChatMessage> remoteMessages,
  ) async {
    final confirmedIds = remoteMessages
        .map((message) => message.clientMessageId?.trim())
        .whereType<String>()
        .where((clientMessageId) => clientMessageId.isNotEmpty)
        .toSet();
    if (confirmedIds.isEmpty) {
      return;
    }

    final currentMessages = itemsFor(chatId);
    final nextMessages = currentMessages
        .where((message) => !confirmedIds.contains(message.localId))
        .toList(growable: false);
    if (nextMessages.length == currentMessages.length) {
      return;
    }
    replaceItems(chatId, nextMessages);
  }

  /// S4: явный потолок ожидания ACK — дольше держать «отправляется»
  /// нечестно: переводим в failed с ретраем по тапу. С вложениями
  /// аплоад легитимно дольше — потолок мягче.
  static const Duration _sendTimeout = Duration(seconds: 10);
  static const Duration _sendTimeoutWithAttachments = Duration(seconds: 45);

  @override
  String itemKey(ChatPendingMessage item) => item.chatId;

  @override
  String itemId(ChatPendingMessage item) => item.localId;

  @override
  DateTime itemTimestamp(ChatPendingMessage item) => item.timestamp;

  @override
  bool isItemPending(ChatPendingMessage item) =>
      item.status == ChatPendingMessageStatus.pending;

  @override
  bool isItemFailed(ChatPendingMessage item) =>
      item.status == ChatPendingMessageStatus.failed;

  @override
  ChatPendingMessage markItemSent(ChatPendingMessage item) => item.copyWith(
        status: ChatPendingMessageStatus.sent,
        errorText: null,
      );

  @override
  ChatPendingMessage markItemFailed(
    ChatPendingMessage item,
    String errorText,
  ) =>
      item.copyWith(
        status: ChatPendingMessageStatus.failed,
        errorText: errorText,
      );

  @override
  ChatPendingMessage prepareItemForRetry(ChatPendingMessage item) =>
      item.copyWith(
        status: ChatPendingMessageStatus.pending,
        progress: item.attachments.isNotEmpty
            ? ChatSendProgress(
                stage: ChatSendProgressStage.preparing,
                completed: 0,
                total: item.attachments.length,
              )
            : const ChatSendProgress(
                stage: ChatSendProgressStage.sending,
                completed: 1,
                total: 1,
              ),
        errorText: null,
      );

  @override
  Map<String, dynamic> itemToJson(ChatPendingMessage item) => item.toJson();

  @override
  ChatPendingMessage itemFromJson(Map<String, dynamic> json) =>
      ChatPendingMessage.fromJson(json);

  @override
  Future<void> performSend(ChatPendingMessage item) {
    return _chatService.sendMessageToChat(
      chatId: item.chatId,
      text: item.text,
      attachments: item.attachments,
      forwardedAttachments: item.forwardedAttachments,
      replyTo: item.replyTo,
      clientMessageId: item.localId,
      expiresInSeconds: item.expiresInSeconds,
      onProgress: (progress) {
        transformItem(
          item.chatId,
          item.localId,
          (message) => message.copyWith(progress: progress),
        );
      },
    );
  }

  @override
  Duration sendTimeoutFor(ChatPendingMessage item) =>
      item.attachments.isEmpty ? _sendTimeout : _sendTimeoutWithAttachments;

  @override
  String errorTextFor(Object error) {
    if (error is TimeoutException) {
      return 'Не дождались ответа сервера. Нажмите, чтобы повторить.';
    }
    if (error is CustomApiException && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    if (error is UnsupportedError && error.message?.trim().isNotEmpty == true) {
      return error.message!.trim();
    }
    return 'Не удалось отправить сообщение.';
  }

  @override
  String get perfTraceLabel => 'chat.send-to-ack';
}
