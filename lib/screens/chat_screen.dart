import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as path;

import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../models/chat_details.dart';
import '../models/chat_message.dart';
import '../models/chat_send_progress.dart';

enum _OutgoingMessageStatus { pending, sent, failed }

class _OutgoingMessage {
  const _OutgoingMessage({
    required this.localId,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.attachments,
    required this.status,
    this.progress,
    this.errorText,
  });

  final String localId;
  final String senderId;
  final String text;
  final DateTime timestamp;
  final List<XFile> attachments;
  final _OutgoingMessageStatus status;
  final ChatSendProgress? progress;
  final String? errorText;

  _OutgoingMessage copyWith({
    _OutgoingMessageStatus? status,
    ChatSendProgress? progress,
    String? errorText,
  }) {
    return _OutgoingMessage(
      localId: localId,
      senderId: senderId,
      text: text,
      timestamp: timestamp,
      attachments: attachments,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      errorText: errorText,
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.chatId,
    this.otherUserId,
    this.title = 'Чат',
    this.photoUrl,
    this.relativeId,
    this.chatType = 'direct',
    this.pickImages,
    this.pickVideo,
  }) : assert(
          (chatId != null && chatId != '') ||
              (otherUserId != null && otherUserId != ''),
          'Нужен chatId или otherUserId',
        );

  final String? chatId;
  final String? otherUserId;
  final String title;
  final String? photoUrl;
  final String? relativeId;
  final String chatType;
  final Future<List<XFile>> Function()? pickImages;
  final Future<XFile?> Function()? pickVideo;

  bool get isGroup => chatType == 'group' || chatType == 'branch';

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const int _maxAttachments = 6;

  final TextEditingController _messageController = TextEditingController();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final ImagePicker _imagePicker = ImagePicker();

  String? _currentUserId;
  String? _chatId;
  ChatDetails? _chatDetails;
  String? _bootstrapError;
  bool _isBootstrapping = true;
  bool _isLoadingChatDetails = false;
  bool _isMarkingRead = false;
  int _localMessageCounter = 0;
  late String _resolvedTitle;
  final List<XFile> _selectedAttachments = <XFile>[];
  final List<_OutgoingMessage> _optimisticMessages = <_OutgoingMessage>[];

  @override
  void initState() {
    super.initState();
    _resolvedTitle = widget.title;
    _bootstrapChat();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _bootstrapChat() async {
    setState(() {
      _isBootstrapping = true;
      _bootstrapError = null;
    });

    try {
      final currentUserId = _chatService.currentUserId;
      if (currentUserId == null || currentUserId.isEmpty) {
        throw StateError('Сессия недоступна');
      }

      String? resolvedChatId = widget.chatId;
      if (resolvedChatId == null || resolvedChatId.isEmpty) {
        final otherUserId = widget.otherUserId;
        if (otherUserId == null || otherUserId.isEmpty) {
          throw StateError('Не удалось определить чат');
        }
        resolvedChatId = await _chatService.getOrCreateChat(otherUserId);
      }
      if (resolvedChatId == null || resolvedChatId.isEmpty) {
        throw StateError('Не удалось определить чат');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _currentUserId = currentUserId;
        _chatId = resolvedChatId;
        _isBootstrapping = false;
      });

      unawaited(_loadChatDetails());
      await _markChatAsRead();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrapError =
            'Не удалось открыть чат. Проверьте соединение и попробуйте снова.';
        _isBootstrapping = false;
      });
    }
  }

  Future<void> _loadChatDetails() async {
    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }

    setState(() {
      _isLoadingChatDetails = true;
    });

    try {
      final details = await _chatService.getChatDetails(chatId);
      if (!mounted) {
        return;
      }

      setState(() {
        _chatDetails = details;
        _resolvedTitle = details.displayTitle;
        _isLoadingChatDetails = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingChatDetails = false;
      });
    }
  }

  Future<void> _markChatAsRead() async {
    final chatId = _chatId;
    final userId = _currentUserId;
    if (_isMarkingRead ||
        chatId == null ||
        chatId.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return;
    }

    _isMarkingRead = true;
    try {
      await _chatService.markChatAsRead(chatId, userId);
    } catch (_) {
      // Не блокируем UI, если mark-as-read временно не сработал.
    } finally {
      _isMarkingRead = false;
    }
  }

  Future<void> _pickImageAttachments() async {
    if (_selectedAttachments.length >= _maxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Можно прикрепить не более 6 вложений.'),
        ),
      );
      return;
    }

    try {
      final picked = widget.pickImages != null
          ? await widget.pickImages!()
          : await _imagePicker.pickMultiImage(
              imageQuality: 80,
              maxWidth: 1600,
            );
      if (picked.isEmpty || !mounted) {
        return;
      }

      final next = <XFile>[..._selectedAttachments, ...picked];
      setState(() {
        _selectedAttachments
          ..clear()
          ..addAll(next.take(_maxAttachments));
      });
      if (_selectedAttachments.length < next.length && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Можно прикрепить не более 6 вложений.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать фотографии.')),
      );
    }
  }

  Future<void> _pickVideoAttachment() async {
    if (_selectedAttachments.length >= _maxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Можно прикрепить не более 6 вложений.'),
        ),
      );
      return;
    }

    try {
      final picked = widget.pickVideo != null
          ? await widget.pickVideo!()
          : await _imagePicker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(minutes: 10),
            );
      if (picked == null || !mounted) {
        return;
      }

      setState(() {
        _selectedAttachments.add(picked);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать видео.')),
      );
    }
  }

  Future<void> _openAttachmentPicker() async {
    final choice = await showModalBottomSheet<_AttachmentPickerChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Фото'),
              subtitle:
                  const Text('Сожмём перед отправкой, чтобы быстрее дошло'),
              onTap: () => Navigator.of(context).pop(
                _AttachmentPickerChoice.images,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Видео'),
              subtitle: const Text('Добавится как вложение в чат'),
              onTap: () => Navigator.of(context).pop(
                _AttachmentPickerChoice.video,
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) {
      return;
    }

    if (choice == _AttachmentPickerChoice.images) {
      await _pickImageAttachments();
      return;
    }

    await _pickVideoAttachment();
  }

  Future<void> _sendCurrentMessage() async {
    final currentUserId = _currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }

    final text = _messageController.text.trim();
    final attachments = List<XFile>.from(_selectedAttachments);
    if (text.isEmpty && attachments.isEmpty) {
      return;
    }

    _messageController.clear();
    setState(() {
      _selectedAttachments.clear();
      _optimisticMessages.insert(
        0,
        _OutgoingMessage(
          localId: 'local-${_localMessageCounter++}',
          senderId: currentUserId,
          text: text,
          timestamp: DateTime.now(),
          attachments: attachments,
          status: _OutgoingMessageStatus.pending,
          progress: attachments.isNotEmpty
              ? const ChatSendProgress(
                  stage: ChatSendProgressStage.preparing,
                  completed: 0,
                  total: 1,
                )
              : const ChatSendProgress(
                  stage: ChatSendProgressStage.sending,
                  completed: 1,
                  total: 1,
                ),
        ),
      );
    });

    final pendingMessage = _optimisticMessages.first;
    await _sendOptimisticMessage(pendingMessage);
  }

  Future<void> _sendOptimisticMessage(_OutgoingMessage message) async {
    try {
      final chatId = _chatId;
      if (chatId == null || chatId.isEmpty) {
        throw StateError('Чат недоступен');
      }
      await _chatService.sendMessageToChat(
        chatId: chatId,
        text: message.text,
        attachments: message.attachments,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            final currentIndex = _optimisticMessages.indexWhere(
              (item) => item.localId == message.localId,
            );
            if (currentIndex == -1) {
              return;
            }
            _optimisticMessages[currentIndex] =
                _optimisticMessages[currentIndex].copyWith(progress: progress);
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceOptimisticMessage(
          message.localId,
          message.copyWith(status: _OutgoingMessageStatus.sent),
        );
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceOptimisticMessage(
          message.localId,
          message.copyWith(
            status: _OutgoingMessageStatus.failed,
            errorText: 'Не удалось отправить',
          ),
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить сообщение.')),
      );
    }
  }

  void _replaceOptimisticMessage(String localId, _OutgoingMessage nextMessage) {
    final index = _optimisticMessages.indexWhere(
      (message) => message.localId == localId,
    );
    if (index == -1) {
      return;
    }
    _optimisticMessages[index] = nextMessage;
  }

  bool _matchesRemoteMessage(
    _OutgoingMessage localMessage,
    List<ChatMessage> remoteMessages,
  ) {
    return remoteMessages.any((message) {
      final sameSender = message.senderId == localMessage.senderId;
      final sameText = message.text.trim() == localMessage.text.trim();
      final sameAttachmentCount =
          (message.mediaUrls?.length ?? (message.imageUrl != null ? 1 : 0)) ==
              localMessage.attachments.length;
      final timeDelta =
          message.timestamp.difference(localMessage.timestamp).inSeconds.abs();
      return sameSender && sameText && sameAttachmentCount && timeDelta <= 30;
    });
  }

  Future<void> _openChatInfo() async {
    final details = _chatDetails;
    final currentUserId = _currentUserId;
    if (details == null || currentUserId == null || currentUserId.isEmpty) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ChatInfoSheet(
        initialDetails: details,
        currentUserId: currentUserId,
        onRename: (title) async {
          final updatedDetails = await _chatService.renameGroupChat(
            chatId: details.chatId,
            title: title,
          );
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
            _resolvedTitle = updatedDetails.displayTitle;
          });
          return updatedDetails;
        },
        onAddParticipants: (participantIds) async {
          final updatedDetails = await _chatService.addGroupParticipants(
            chatId: details.chatId,
            participantIds: participantIds,
          );
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
          });
          return updatedDetails;
        },
        onRemoveParticipant: (participantId) async {
          final updatedDetails = await _chatService.removeGroupParticipant(
            chatId: details.chatId,
            participantId: participantId,
          );
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
          });
          return updatedDetails;
        },
      ),
    );
  }

  String _chatSubtitle() {
    final details = _chatDetails;
    if (details != null && details.isBranch) {
      final branchCount = details.branchRoots.length;
      final memberCount = details.memberCount;
      final branchLabel = branchCount == 1 ? '1 ветка' : '$branchCount ветки';
      final memberLabel =
          memberCount == 1 ? '1 участник' : '$memberCount участников';
      return '$branchLabel · $memberLabel';
    }
    if (details != null && details.isGroup) {
      final memberCount = details.memberCount;
      return memberCount == 1 ? '1 участник' : '$memberCount участников';
    }
    return widget.chatType == 'branch'
        ? 'Чат ветки'
        : (widget.isGroup ? 'Групповой чат' : 'Личные сообщения');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            GestureDetector(
              onTap: !widget.isGroup &&
                      widget.relativeId != null &&
                      widget.relativeId!.isNotEmpty
                  ? () => context.push('/relative/details/${widget.relativeId}')
                  : null,
              child: CircleAvatar(
                radius: 20,
                backgroundImage:
                    widget.photoUrl != null && widget.photoUrl!.isNotEmpty
                        ? NetworkImage(widget.photoUrl!)
                        : null,
                child: widget.photoUrl == null || widget.photoUrl!.isEmpty
                    ? widget.isGroup
                        ? const Icon(Icons.group_outlined)
                        : Text(widget.title.isNotEmpty ? widget.title[0] : '?')
                    : null,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _resolvedTitle,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    _chatSubtitle(),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (widget.isGroup)
              IconButton(
                onPressed: _isLoadingChatDetails || _chatDetails == null
                    ? null
                    : _openChatInfo,
                tooltip: 'О чате',
                icon: const Icon(Icons.info_outline),
              ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildMessagesBody()),
          _buildMessageInputArea(),
        ],
      ),
    );
  }

  Widget _buildMessagesBody() {
    if (_isBootstrapping) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_bootstrapError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_bubble_outline, size: 48),
              const SizedBox(height: 12),
              Text(
                _bootstrapError!,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _bootstrapChat,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          ),
        ),
      );
    }

    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return const Center(child: Text('Чат недоступен.'));
    }

    return StreamBuilder<List<ChatMessage>>(
      stream: _chatService.getMessagesStream(chatId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    'Не удалось загрузить сообщения. Попробуйте обновить чат.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _bootstrapChat,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Обновить'),
                  ),
                ],
              ),
            ),
          );
        }

        final remoteMessages = snapshot.data ?? const <ChatMessage>[];
        final hasUnreadIncoming = remoteMessages.any(
          (message) =>
              message.senderId != _currentUserId && message.isRead == false,
        );
        if (hasUnreadIncoming) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _markChatAsRead();
          });
        }

        final optimisticMessages = _optimisticMessages
            .where((message) => !_matchesRemoteMessage(message, remoteMessages))
            .toList();

        if (remoteMessages.isEmpty && optimisticMessages.isEmpty) {
          return const Center(
            child: Text('Сообщений пока нет. Начните диалог первым.'),
          );
        }

        return ListView.builder(
          reverse: true,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: remoteMessages.length + optimisticMessages.length,
          itemBuilder: (context, index) {
            if (index < optimisticMessages.length) {
              final localMessage = optimisticMessages[index];
              return _buildOptimisticBubble(localMessage);
            }

            final remoteMessage =
                remoteMessages[index - optimisticMessages.length];
            final isMe = remoteMessage.senderId == _currentUserId;
            return _buildRemoteBubble(remoteMessage, isMe);
          },
        );
      },
    );
  }

  Widget _buildMessageInputArea() {
    final canSend = _messageController.text.trim().isNotEmpty ||
        _selectedAttachments.isNotEmpty;

    return Material(
      elevation: 5,
      color: Theme.of(context).cardColor,
      child: Padding(
        padding: EdgeInsets.only(
          left: 8,
          right: 8,
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selectedAttachments.isNotEmpty)
              Column(
                children: [
                  Row(
                    children: [
                      Text(
                        _attachmentSummaryLabel(_selectedAttachments),
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Фото будут ужаты, видео отправится как файл.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 74,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _selectedAttachments.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemBuilder: (context, index) {
                        final attachment = _selectedAttachments[index];
                        return Stack(
                          clipBehavior: Clip.none,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(14),
                              child: SizedBox(
                                width: 74,
                                height: 74,
                                child: _LocalMediaTile(file: attachment),
                              ),
                            ),
                            Positioned(
                              top: -6,
                              right: -6,
                              child: IconButton.filledTonal(
                                onPressed: () {
                                  setState(() {
                                    _selectedAttachments.removeAt(index);
                                  });
                                },
                                icon: const Icon(Icons.close, size: 16),
                                visualDensity: VisualDensity.compact,
                                style: IconButton.styleFrom(
                                  minimumSize: const Size(28, 28),
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            if (_selectedAttachments.isNotEmpty) const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _selectedAttachments.length >= _maxAttachments
                      ? null
                      : _openAttachmentPicker,
                  tooltip: 'Добавить вложение',
                  icon: const Icon(Icons.attach_file_rounded),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _messageController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration.collapsed(
                        hintText: 'Сообщение...',
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      minLines: 1,
                      maxLines: 5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  onPressed: canSend ? _sendCurrentMessage : null,
                  elevation: 0,
                  child: const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteBubble(ChatMessage message, bool isMe) {
    return _ChatBubble(
      isMe: isMe,
      senderLabel: widget.isGroup && !isMe
          ? _groupSenderLabel(message.senderName, message.senderId)
          : null,
      text: message.text,
      timeLabel: DateFormat.Hm('ru').format(message.timestamp),
      isRead: message.isRead,
      mediaUrls: message.mediaUrls ??
          (message.imageUrl != null
              ? <String>[message.imageUrl!]
              : const <String>[]),
    );
  }

  Widget _buildOptimisticBubble(_OutgoingMessage message) {
    final timeLabel = DateFormat.Hm('ru').format(message.timestamp);
    final statusLabel = _statusLabelForOutgoingMessage(message);
    final progressValue = message.progress?.value;
    final showProgressBar = message.status == _OutgoingMessageStatus.pending &&
        message.attachments.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _ChatBubble(
              isMe: true,
              text: message.text,
              timeLabel: timeLabel,
              isRead: false,
              mediaUrls: const <String>[],
              localAttachments: message.attachments,
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  statusLabel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (message.status == _OutgoingMessageStatus.failed) ...[
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: () => _sendOptimisticMessage(
                      message.copyWith(
                        status: _OutgoingMessageStatus.pending,
                        errorText: null,
                      ),
                    ),
                    child: const Text('Повторить'),
                  ),
                ],
              ],
            ),
            if (showProgressBar) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: 140,
                child: LinearProgressIndicator(value: progressValue),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabelForOutgoingMessage(_OutgoingMessage message) {
    if (message.status == _OutgoingMessageStatus.failed) {
      return message.errorText ?? 'Ошибка отправки';
    }
    if (message.status == _OutgoingMessageStatus.sent) {
      return 'Отправлено';
    }

    switch (message.progress?.stage) {
      case ChatSendProgressStage.preparing:
        return 'Подготовка вложений...';
      case ChatSendProgressStage.uploading:
        final total = message.progress?.total ?? 0;
        final completed = message.progress?.completed ?? 0;
        if (total > 1) {
          return 'Загрузка вложений $completed/$total';
        }
        return 'Загрузка вложения...';
      case ChatSendProgressStage.sending:
      case null:
        return 'Отправляется...';
    }
  }

  String _attachmentSummaryLabel(List<XFile> files) {
    final count = files.length;
    final noun = count == 1
        ? 'вложение'
        : (count >= 2 && count <= 4 ? 'вложения' : 'вложений');
    return '$count $noun';
  }

  String? _groupSenderLabel(String? senderName, String senderId) {
    final normalizedName = senderName?.trim();
    if (normalizedName != null && normalizedName.isNotEmpty) {
      return normalizedName;
    }
    if (senderId == _currentUserId) {
      return 'Вы';
    }
    return 'Участник';
  }
}

class _ChatInfoSheet extends StatefulWidget {
  const _ChatInfoSheet({
    required this.initialDetails,
    required this.currentUserId,
    required this.onRename,
    required this.onAddParticipants,
    required this.onRemoveParticipant,
  });

  final ChatDetails initialDetails;
  final String currentUserId;
  final Future<ChatDetails> Function(String title) onRename;
  final Future<ChatDetails> Function(List<String> participantIds)
      onAddParticipants;
  final Future<ChatDetails> Function(String participantId) onRemoveParticipant;

  @override
  State<_ChatInfoSheet> createState() => _ChatInfoSheetState();
}

class _ChatInfoSheetState extends State<_ChatInfoSheet> {
  late ChatDetails _details;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _details = widget.initialDetails;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SizedBox(
          height: 600,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'О чате',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _details.displayTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _details.isBranch
                    ? 'Веточный чат обновляется по составу дерева автоматически.'
                    : 'Обычная семейная группа. Можно менять название и участников.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InfoChip(
                    icon: _details.isBranch
                        ? Icons.account_tree_outlined
                        : Icons.groups_2_outlined,
                    label: _details.isBranch ? 'Чат ветки' : 'Группа',
                  ),
                  _InfoChip(
                    icon: Icons.people_outline,
                    label: _details.memberCount == 1
                        ? '1 участник'
                        : '${_details.memberCount} участников',
                  ),
                ],
              ),
              if (_details.branchRoots.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Ветки',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _details.branchRoots
                      .map((root) => Chip(label: Text(root.name)))
                      .toList(),
                ),
              ],
              const SizedBox(height: 16),
              if (_details.isEditableGroup) ...[
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isSaving ? null : _renameChat,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Переименовать'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSaving ? null : _addParticipants,
                        icon: const Icon(Icons.person_add_alt_1_outlined),
                        label: const Text('Добавить'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              Text(
                'Участники',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: _details.participants.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final participant = _details.participants[index];
                    final isCurrentUser =
                        participant.userId == widget.currentUserId;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundImage: participant.photoUrl != null &&
                                participant.photoUrl!.isNotEmpty
                            ? NetworkImage(participant.photoUrl!)
                            : null,
                        child: participant.photoUrl == null ||
                                participant.photoUrl!.isEmpty
                            ? Text(
                                participant.displayName.isNotEmpty
                                    ? participant.displayName[0]
                                    : '?',
                              )
                            : null,
                      ),
                      title: Text(participant.displayName),
                      subtitle: Text(isCurrentUser ? 'Вы' : 'Участник'),
                      trailing: _details.isEditableGroup && !isCurrentUser
                          ? IconButton(
                              onPressed: _isSaving
                                  ? null
                                  : () => _removeParticipant(participant),
                              tooltip: 'Убрать из чата',
                              icon: const Icon(Icons.person_remove_outlined),
                            )
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _renameChat() async {
    final controller = TextEditingController(text: _details.displayTitle);
    final nextTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переименовать чат'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Название',
            hintText: 'Например, Семья Кузнецовых',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted || nextTitle == null || nextTitle.trim().isEmpty) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onRename(nextTitle.trim());
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось переименовать чат.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _addParticipants() async {
    final treeId = _details.treeId;
    if (treeId == null || treeId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для этого чата не найдено дерево.')),
      );
      return;
    }
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Список родных временно недоступен.')),
      );
      return;
    }

    final familyTreeService = GetIt.I<FamilyTreeServiceInterface>();
    final relatives = await familyTreeService.getRelatives(treeId);
    if (!mounted) {
      return;
    }

    final existingParticipantIds = _details.participantIds.toSet();
    final candidates = relatives
        .where((person) {
          final userId = person.userId?.trim();
          return userId != null &&
              userId.isNotEmpty &&
              userId != widget.currentUserId &&
              !existingParticipantIds.contains(userId);
        })
        .map(
          (person) => _GroupChatCandidate(
            userId: person.userId!.trim(),
            displayName:
                person.name.trim().isNotEmpty ? person.name : 'Пользователь',
            photoUrl: person.photoUrl,
            relationLabel: (person.relation ?? '').trim().isNotEmpty
                ? person.relation!.trim()
                : 'Родственник',
          ),
        )
        .toList()
      ..sort((left, right) => left.displayName.compareTo(right.displayName));

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('В этом дереве больше некого добавить.')),
      );
      return;
    }

    final selectedIds = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AddParticipantsSheet(candidates: candidates),
    );

    if (!mounted || selectedIds == null || selectedIds.isEmpty) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onAddParticipants(selectedIds);
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось добавить участников.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _removeParticipant(
    ChatParticipantSummary participant,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Убрать участника'),
        content: Text(
          'Убрать ${participant.displayName} из этого чата?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onRemoveParticipant(participant.userId);
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось обновить состав чата.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(label),
          ],
        ),
      ),
    );
  }
}

class _GroupChatCandidate {
  const _GroupChatCandidate({
    required this.userId,
    required this.displayName,
    required this.relationLabel,
    this.photoUrl,
  });

  final String userId;
  final String displayName;
  final String relationLabel;
  final String? photoUrl;
}

class _AddParticipantsSheet extends StatefulWidget {
  const _AddParticipantsSheet({required this.candidates});

  final List<_GroupChatCandidate> candidates;

  @override
  State<_AddParticipantsSheet> createState() => _AddParticipantsSheetState();
}

class _AddParticipantsSheetState extends State<_AddParticipantsSheet> {
  final Set<String> _selectedIds = <String>{};
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = _searchController.text.trim().toLowerCase();
    final filteredCandidates = widget.candidates.where((candidate) {
      if (search.isEmpty) {
        return true;
      }
      return candidate.displayName.toLowerCase().contains(search) ||
          candidate.relationLabel.toLowerCase().contains(search);
    }).toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SizedBox(
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Добавить участников',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Найти по имени',
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: filteredCandidates.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final candidate = filteredCandidates[index];
                    final isSelected = _selectedIds.contains(candidate.userId);
                    return CheckboxListTile(
                      value: isSelected,
                      onChanged: (_) {
                        setState(() {
                          if (isSelected) {
                            _selectedIds.remove(candidate.userId);
                          } else {
                            _selectedIds.add(candidate.userId);
                          }
                        });
                      },
                      secondary: CircleAvatar(
                        backgroundImage: candidate.photoUrl != null &&
                                candidate.photoUrl!.isNotEmpty
                            ? NetworkImage(candidate.photoUrl!)
                            : null,
                        child: candidate.photoUrl == null ||
                                candidate.photoUrl!.isEmpty
                            ? Text(
                                candidate.displayName.isNotEmpty
                                    ? candidate.displayName[0]
                                    : '?',
                              )
                            : null,
                      ),
                      title: Text(candidate.displayName),
                      subtitle: Text(candidate.relationLabel),
                      controlAffinity: ListTileControlAffinity.trailing,
                      contentPadding: EdgeInsets.zero,
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_selectedIds.toList()),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(
                    _selectedIds.isEmpty
                        ? 'Выберите участников'
                        : 'Добавить ${_selectedIds.length}',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _AttachmentPickerChoice { images, video }

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.isMe,
    required this.text,
    required this.timeLabel,
    required this.isRead,
    this.senderLabel,
    this.mediaUrls = const <String>[],
    this.localAttachments = const <XFile>[],
  });

  final bool isMe;
  final String text;
  final String timeLabel;
  final bool isRead;
  final String? senderLabel;
  final List<String> mediaUrls;
  final List<XFile> localAttachments;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          decoration: BoxDecoration(
            color: isMe ? Colors.blue[600] : Colors.grey[300],
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isMe ? 16 : 0),
              bottomRight: Radius.circular(isMe ? 0 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment:
                isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (senderLabel != null && senderLabel!.isNotEmpty) ...[
                Text(
                  senderLabel!,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.92)
                        : Colors.black54,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
              ],
              if (mediaUrls.isNotEmpty) ...[
                _RemoteMediaGrid(urls: mediaUrls),
                const SizedBox(height: 8),
              ],
              if (localAttachments.isNotEmpty) ...[
                _LocalMediaGrid(files: localAttachments),
                const SizedBox(height: 8),
              ],
              if (text.isNotEmpty)
                Text(
                  text,
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.black87,
                    fontSize: 16,
                  ),
                ),
              if (text.isEmpty && mediaUrls.isEmpty && localAttachments.isEmpty)
                Text(
                  'Сообщение',
                  style: TextStyle(
                    color: isMe ? Colors.white : Colors.black87,
                    fontSize: 16,
                  ),
                ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    timeLabel,
                    style: TextStyle(
                      color: isMe
                          ? Colors.white.withValues(alpha: 0.7)
                          : Colors.black54,
                      fontSize: 11,
                    ),
                  ),
                  if (isMe) ...[
                    const SizedBox(width: 5),
                    Icon(
                      isRead ? Icons.done_all : Icons.done,
                      size: 14,
                      color: isRead
                          ? Colors.lightBlueAccent[100]
                          : Colors.white.withValues(alpha: 0.7),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteMediaGrid extends StatelessWidget {
  const _RemoteMediaGrid({required this.urls});

  final List<String> urls;

  @override
  Widget build(BuildContext context) {
    if (urls.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 220,
          height: 220,
          child: _RemoteMediaTile(url: urls.first),
        ),
      );
    }

    return SizedBox(
      width: 220,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: urls
            .take(4)
            .map(
              (url) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 106,
                  height: 106,
                  child: _RemoteMediaTile(url: url),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _LocalMediaGrid extends StatelessWidget {
  const _LocalMediaGrid({required this.files});

  final List<XFile> files;

  @override
  Widget build(BuildContext context) {
    if (files.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 220,
          height: 220,
          child: _LocalMediaTile(file: files.first),
        ),
      );
    }

    return SizedBox(
      width: 220,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: files
            .take(4)
            .map(
              (file) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 106,
                  height: 106,
                  child: _LocalMediaTile(file: file),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _LocalImagePreview extends StatelessWidget {
  const _LocalImagePreview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        return Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        );
      },
    );
  }
}

class _LocalMediaTile extends StatelessWidget {
  const _LocalMediaTile({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    final kind = _attachmentKindFromName(file.name, file.path);
    if (kind == _ChatAttachmentKind.image) {
      return _LocalImagePreview(file: file);
    }

    return _AttachmentPlaceholder(
      icon: kind == _ChatAttachmentKind.video
          ? Icons.videocam_outlined
          : Icons.insert_drive_file_outlined,
      label:
          kind == _ChatAttachmentKind.video ? 'Видео' : _displayName(file.name),
    );
  }
}

class _RemoteMediaTile extends StatelessWidget {
  const _RemoteMediaTile({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final kind = _attachmentKindFromName(url, url);
    if (kind == _ChatAttachmentKind.image) {
      return Image.network(
        url,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const _AttachmentPlaceholder(
          icon: Icons.broken_image_outlined,
          label: 'Файл',
        ),
      );
    }

    return _AttachmentPlaceholder(
      icon: kind == _ChatAttachmentKind.video
          ? Icons.videocam_outlined
          : Icons.insert_drive_file_outlined,
      label: kind == _ChatAttachmentKind.video ? 'Видео' : _displayName(url),
    );
  }
}

class _AttachmentPlaceholder extends StatelessWidget {
  const _AttachmentPlaceholder({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x11000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon),
              const SizedBox(height: 6),
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _ChatAttachmentKind { image, video, other }

_ChatAttachmentKind _attachmentKindFromName(
  String? preferredName,
  String? fallbackPath,
) {
  final fileName = (preferredName?.trim().isNotEmpty ?? false)
      ? preferredName!.trim()
      : (fallbackPath ?? '');
  final extension = path.extension(fileName).toLowerCase();
  const imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
    '.heif',
  };
  if (imageExtensions.contains(extension)) {
    return _ChatAttachmentKind.image;
  }

  const videoExtensions = <String>{
    '.mp4',
    '.mov',
    '.webm',
    '.m4v',
    '.avi',
    '.mkv',
    '.3gp',
  };
  if (videoExtensions.contains(extension)) {
    return _ChatAttachmentKind.video;
  }

  return _ChatAttachmentKind.other;
}

String _displayName(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Файл';
  }
  final normalized = value.split('/').last.split('?').first;
  return normalized.length > 24
      ? '${normalized.substring(0, 21)}...'
      : normalized;
}
