import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../backend/interfaces/chat_service_interface.dart';
import '../models/chat_message.dart';

enum _OutgoingMessageStatus { pending, sent, failed }

class _OutgoingMessage {
  const _OutgoingMessage({
    required this.localId,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.attachments,
    required this.status,
    this.errorText,
  });

  final String localId;
  final String senderId;
  final String text;
  final DateTime timestamp;
  final List<XFile> attachments;
  final _OutgoingMessageStatus status;
  final String? errorText;

  _OutgoingMessage copyWith({
    _OutgoingMessageStatus? status,
    String? errorText,
  }) {
    return _OutgoingMessage(
      localId: localId,
      senderId: senderId,
      text: text,
      timestamp: timestamp,
      attachments: attachments,
      status: status ?? this.status,
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
  String? _bootstrapError;
  bool _isBootstrapping = true;
  bool _isMarkingRead = false;
  int _localMessageCounter = 0;
  final List<XFile> _selectedAttachments = <XFile>[];
  final List<_OutgoingMessage> _optimisticMessages = <_OutgoingMessage>[];

  @override
  void initState() {
    super.initState();
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

  Future<void> _pickAttachments() async {
    if (_selectedAttachments.length >= _maxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Можно прикрепить не более 6 изображений.'),
        ),
      );
      return;
    }

    try {
      final picked = await _imagePicker.pickMultiImage(
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
            content: Text('Можно прикрепить не более 6 изображений.'),
          ),
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать изображения.')),
      );
    }
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
                    widget.title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    widget.isGroup ? 'Групповой чат' : 'Личные сообщения',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
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
                            child: _LocalImagePreview(file: attachment),
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
            if (_selectedAttachments.isNotEmpty) const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _selectedAttachments.length >= _maxAttachments
                      ? null
                      : _pickAttachments,
                  tooltip: 'Добавить фото',
                  icon: const Icon(Icons.photo_library_outlined),
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
    String statusLabel;
    switch (message.status) {
      case _OutgoingMessageStatus.pending:
        statusLabel = 'Отправляется...';
        break;
      case _OutgoingMessageStatus.sent:
        statusLabel = 'Отправлено';
        break;
      case _OutgoingMessageStatus.failed:
        statusLabel = message.errorText ?? 'Ошибка отправки';
        break;
    }

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
          ],
        ),
      ),
    );
  }
}

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.isMe,
    required this.text,
    required this.timeLabel,
    required this.isRead,
    this.mediaUrls = const <String>[],
    this.localAttachments = const <XFile>[],
  });

  final bool isMe;
  final String text;
  final String timeLabel;
  final bool isRead;
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
        child: Image.network(
          urls.first,
          width: 220,
          height: 220,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const SizedBox(
            width: 220,
            height: 220,
            child: ColoredBox(
              color: Color(0x11000000),
              child: Center(child: Icon(Icons.broken_image_outlined)),
            ),
          ),
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
                child: Image.network(
                  url,
                  width: 106,
                  height: 106,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox(
                    width: 106,
                    height: 106,
                    child: ColoredBox(
                      color: Color(0x11000000),
                      child: Center(child: Icon(Icons.broken_image_outlined)),
                    ),
                  ),
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
          child: _LocalImagePreview(file: files.first),
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
                  child: _LocalImagePreview(file: file),
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
