import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../backend/interfaces/chat_service_interface.dart';
import '../models/chat_message.dart';

class InCallChatSheet extends StatefulWidget {
  const InCallChatSheet({
    super.key,
    required this.chatId,
    required this.chatService,
  });

  final String chatId;
  final ChatServiceInterface chatService;

  @override
  State<InCallChatSheet> createState() => _InCallChatSheetState();
}

class _InCallChatSheetState extends State<InCallChatSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.chatService.refreshMessages(widget.chatId));
    final currentUserId = widget.chatService.currentUserId;
    if (currentUserId != null && currentUserId.isNotEmpty) {
      unawaited(
          widget.chatService.markChatAsRead(widget.chatId, currentUserId));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) {
      return;
    }
    setState(() {
      _isSending = true;
    });
    try {
      await widget.chatService.sendMessageToChat(
        chatId: widget.chatId,
        text: text,
      );
      if (mounted) {
        _controller.clear();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось отправить сообщение.'),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final height = math.min(mediaQuery.size.height * 0.72, 620.0);
    return SafeArea(
      child: SizedBox(
        height: height,
        child: Column(
          children: [
            Padding(
              // Шапка листа: showDragHandle уже даёт ручку сверху — свой
              // верхний отступ убран, чтобы не дублировать пустоту.
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline_rounded),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Чат во время звонка',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Закрыть',
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: StreamBuilder<List<ChatMessage>>(
                stream: widget.chatService.getMessagesStream(widget.chatId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final messages = List<ChatMessage>.from(
                    snapshot.data ?? const <ChatMessage>[],
                  )..sort((a, b) => a.timestamp.compareTo(b.timestamp));
                  final visibleMessages = messages.length > 40
                      ? messages.sublist(messages.length - 40)
                      : messages;
                  if (visibleMessages.isEmpty) {
                    return Center(
                      child: Text(
                        'Сообщений пока нет.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    );
                  }
                  return ListView.builder(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    itemCount: visibleMessages.length,
                    itemBuilder: (context, index) {
                      final message =
                          visibleMessages[visibleMessages.length - 1 - index];
                      return _InCallMessageBubble(
                        message: message,
                        isMine: message.senderId ==
                            widget.chatService.currentUserId,
                      );
                    },
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                12,
                6,
                12,
                10 + mediaQuery.viewInsets.bottom,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => unawaited(_sendMessage()),
                      decoration: const InputDecoration(
                        hintText: 'Сообщение',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed:
                        _isSending ? null : () => unawaited(_sendMessage()),
                    icon: _isSending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                    tooltip: 'Отправить',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InCallMessageBubble extends StatelessWidget {
  const _InCallMessageBubble({
    required this.message,
    required this.isMine,
  });

  final ChatMessage message;
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = message.text.trim().isNotEmpty
        ? message.text.trim()
        : message.attachments.isEmpty
            ? 'Сообщение'
            : 'Вложение';
    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: isMine
                ? theme.colorScheme.primaryContainer
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!isMine && message.senderName?.trim().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      message.senderName!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                Text(text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
