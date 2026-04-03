import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../models/chat_preview.dart';
import '../models/family_person.dart';
import '../providers/tree_provider.dart';

class ChatsListScreen extends StatefulWidget {
  const ChatsListScreen({super.key});

  @override
  State<ChatsListScreen> createState() => _ChatsListScreenState();
}

class _ChatsListScreenState extends State<ChatsListScreen> {
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();

  StreamSubscription<List<ChatPreview>>? _chatsSubscription;
  List<ChatPreview> _chatPreviews = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  @override
  void dispose() {
    _chatsSubscription?.cancel();
    super.dispose();
  }

  void _loadChats() {
    final currentUserId = _authService.currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Пользователь не авторизован.';
      });
      return;
    }

    _chatsSubscription?.cancel();
    _chatsSubscription = _chatService.getUserChatsStream(currentUserId).listen(
      (chatPreviews) {
        if (!mounted) {
          return;
        }
        setState(() {
          _chatPreviews = chatPreviews;
          _isLoading = false;
          _errorMessage = null;
        });
      },
      onError: (_) {
        if (!mounted) {
          return;
        }
        setState(() {
          _isLoading = false;
          _errorMessage = 'Не удалось загрузить чаты.';
        });
      },
    );
  }

  String _formatTimestamp(DateTime timestamp) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final messageDate =
        DateTime(timestamp.year, timestamp.month, timestamp.day);

    if (messageDate == today) {
      return DateFormat.Hm('ru').format(timestamp);
    }

    final yesterday = today.subtract(const Duration(days: 1));
    if (messageDate == yesterday) {
      return 'Вчера';
    }

    if (now.difference(timestamp).inDays < 7) {
      const weekdays = ['Пн', 'Вт', 'Ср', 'Чт', 'Пт', 'Сб', 'Вс'];
      return weekdays[timestamp.weekday - 1];
    }

    return DateFormat('d MMM', 'ru').format(timestamp);
  }

  Future<void> _openGroupChatComposer() async {
    final currentUserId = _authService.currentUserId;
    final messenger = ScaffoldMessenger.of(context);
    final treeProvider = context.read<TreeProvider>();
    final selectedTreeId = treeProvider.selectedTreeId;

    if (currentUserId == null || currentUserId.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Сначала войдите в аккаунт.')),
      );
      return;
    }

    if (selectedTreeId == null || selectedTreeId.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: const Text('Сначала выберите семейное дерево.'),
          action: SnackBarAction(
            label: 'Открыть',
            onPressed: () => context.go('/tree?selector=1'),
          ),
        ),
      );
      return;
    }

    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Список родных временно недоступен.')),
      );
      return;
    }

    final draft = await showModalBottomSheet<_CreateGroupChatDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CreateGroupChatSheet(
        treeId: selectedTreeId,
        currentUserId: currentUserId,
      ),
    );

    if (!mounted || draft == null) {
      return;
    }

    try {
      final chatId = await _chatService.createGroupChat(
        participantIds: draft.participantIds,
        title: draft.title,
        treeId: selectedTreeId,
      );
      if (chatId == null || chatId.isEmpty) {
        throw StateError('Не удалось создать чат');
      }

      final title = (draft.title?.trim().isNotEmpty ?? false)
          ? draft.title!.trim()
          : 'Групповой чат';
      final encodedTitle = Uri.encodeComponent(title);
      if (!mounted) {
        return;
      }
      context.push('/chats/view/$chatId?type=group&title=$encodedTitle');
    } catch (_) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        const SnackBar(content: Text('Не удалось создать групповой чат.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentUserId = _authService.currentUserId ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Чаты'),
        centerTitle: false,
        titleTextStyle: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        actions: [
          IconButton(
            onPressed: _openGroupChatComposer,
            tooltip: 'Новый групповой чат',
            icon: const Icon(Icons.group_add_outlined),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildErrorState()
              : _chatPreviews.isEmpty
                  ? _buildEmptyState(theme)
                  : _buildChatList(theme, currentUserId),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 56, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              _errorMessage!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16, color: Colors.grey[600]),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _errorMessage = null;
                });
                _loadChats();
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Повторить'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color:
                    theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.chat_bubble_outline_rounded,
                size: 40,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Пока нет чатов',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Начните личный диалог или соберите семейный групповой чат '
              'для текущего дерева.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.grey[600],
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openGroupChatComposer,
              icon: const Icon(Icons.group_add_outlined),
              label: const Text('Создать групповой чат'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => context.go('/relatives'),
              icon: const Icon(Icons.people_outline),
              label: const Text('Открыть родных'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.go('/tree'),
              icon: const Icon(Icons.account_tree_outlined),
              label: const Text('Открыть дерево'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatList(ThemeData theme, String currentUserId) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _chatPreviews.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        indent: 76,
        color: theme.dividerColor.withValues(alpha: 0.3),
      ),
      itemBuilder: (context, index) {
        final chat = _chatPreviews[index];
        final hasUnread = chat.unreadCount > 0;
        final isLastFromMe = chat.lastMessageSenderId == currentUserId;
        final messageTime = chat.lastMessageTime.toDate();
        final timeLabel = _formatTimestamp(messageTime);

        return InkWell(
          onTap: () {
            final titleParam = Uri.encodeComponent(chat.displayName);
            final photoParam =
                chat.displayPhotoUrl != null && chat.displayPhotoUrl!.isNotEmpty
                    ? '&photo=${Uri.encodeComponent(chat.displayPhotoUrl!)}'
                    : '';
            final userParam = !chat.isGroup && chat.otherUserId.isNotEmpty
                ? '&userId=${Uri.encodeComponent(chat.otherUserId)}'
                : '';
            context.push(
              '/chats/view/${chat.chatId}?type=${Uri.encodeComponent(chat.type)}&title=$titleParam$photoParam$userParam',
            );
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundImage: chat.displayPhotoUrl != null &&
                          chat.displayPhotoUrl!.isNotEmpty
                      ? NetworkImage(chat.displayPhotoUrl!)
                      : null,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: chat.displayPhotoUrl == null ||
                          chat.displayPhotoUrl!.isEmpty
                      ? chat.isGroup
                          ? Icon(
                              Icons.group_outlined,
                              color: theme.colorScheme.onPrimaryContainer,
                            )
                          : Text(
                              chat.displayName.isNotEmpty
                                  ? chat.displayName[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            )
                      : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              chat.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: hasUnread
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            timeLabel,
                            style: TextStyle(
                              fontSize: 13,
                              color: hasUnread
                                  ? theme.colorScheme.primary
                                  : Colors.grey[500],
                              fontWeight: hasUnread
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (chat.isGroup) ...[
                            Icon(
                              Icons.groups_2_outlined,
                              size: 15,
                              color: Colors.grey[500],
                            ),
                            const SizedBox(width: 4),
                          ],
                          if (isLastFromMe)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.done_all,
                                size: 16,
                                color: Colors.grey[400],
                              ),
                            ),
                          Expanded(
                            child: Text(
                              chat.lastMessage.isNotEmpty
                                  ? chat.lastMessage
                                  : 'Нет сообщений',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                color: hasUnread
                                    ? Colors.black87
                                    : Colors.grey[600],
                                fontWeight: hasUnread
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                fontStyle: chat.lastMessage.isEmpty
                                    ? FontStyle.italic
                                    : FontStyle.normal,
                              ),
                            ),
                          ),
                          if (hasUnread) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                chat.unreadCount > 99
                                    ? '99+'
                                    : chat.unreadCount.toString(),
                                style: TextStyle(
                                  color: theme.colorScheme.onPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _CreateGroupChatDraft {
  const _CreateGroupChatDraft({
    required this.participantIds,
    this.title,
  });

  final List<String> participantIds;
  final String? title;
}

class _GroupChatParticipant {
  const _GroupChatParticipant({
    required this.userId,
    required this.name,
    required this.photoUrl,
    required this.relationLabel,
  });

  final String userId;
  final String name;
  final String? photoUrl;
  final String relationLabel;
}

class _CreateGroupChatSheet extends StatefulWidget {
  const _CreateGroupChatSheet({
    required this.treeId,
    required this.currentUserId,
  });

  final String treeId;
  final String currentUserId;

  @override
  State<_CreateGroupChatSheet> createState() => _CreateGroupChatSheetState();
}

class _CreateGroupChatSheetState extends State<_CreateGroupChatSheet> {
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedUserIds = <String>{};

  bool _isLoading = true;
  String? _errorMessage;
  List<_GroupChatParticipant> _participants = const <_GroupChatParticipant>[];

  @override
  void initState() {
    super.initState();
    _loadParticipants();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void dispose() {
    _searchController.removeListener(_handleSearchChanged);
    _titleController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleSearchChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadParticipants() async {
    try {
      final relatives = await _familyTreeService.getRelatives(widget.treeId);
      final participantsByUserId = <String, _GroupChatParticipant>{};

      for (final relative in relatives) {
        final userId = relative.userId;
        if (userId == null ||
            userId.isEmpty ||
            userId == widget.currentUserId ||
            participantsByUserId.containsKey(userId)) {
          continue;
        }

        participantsByUserId[userId] = _GroupChatParticipant(
          userId: userId,
          name:
              relative.name.trim().isNotEmpty ? relative.name : 'Пользователь',
          photoUrl: relative.photoUrl,
          relationLabel: _relationLabel(relative),
        );
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _participants = participantsByUserId.values.toList()
          ..sort((left, right) => left.name.compareTo(right.name));
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorMessage = 'Не удалось загрузить участников дерева.';
        _isLoading = false;
      });
    }
  }

  String _relationLabel(FamilyPerson person) {
    final relation = (person.relation ?? '').trim();
    return relation.isNotEmpty ? relation : 'Родственник';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final search = _searchController.text.trim().toLowerCase();
    final filteredParticipants = _participants.where((participant) {
      if (search.isEmpty) {
        return true;
      }

      return participant.name.toLowerCase().contains(search) ||
          participant.relationLabel.toLowerCase().contains(search);
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
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Новый групповой чат',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Выберите минимум двух родственников из текущего дерева.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _titleController,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Название чата',
                  hintText: 'Например, Семья Кузнецовых',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Найти по имени',
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : _errorMessage != null
                        ? Center(
                            child: Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : filteredParticipants.isEmpty
                            ? const Center(
                                child: Text(
                                  'В этом дереве пока нет родственников с аккаунтом.',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : ListView.separated(
                                itemCount: filteredParticipants.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 4),
                                itemBuilder: (context, index) {
                                  final participant =
                                      filteredParticipants[index];
                                  final isSelected = _selectedUserIds
                                      .contains(participant.userId);
                                  return CheckboxListTile(
                                    value: isSelected,
                                    onChanged: (_) {
                                      setState(() {
                                        if (isSelected) {
                                          _selectedUserIds.remove(
                                            participant.userId,
                                          );
                                        } else {
                                          _selectedUserIds.add(
                                            participant.userId,
                                          );
                                        }
                                      });
                                    },
                                    secondary: CircleAvatar(
                                      backgroundImage: participant.photoUrl !=
                                                  null &&
                                              participant.photoUrl!.isNotEmpty
                                          ? NetworkImage(participant.photoUrl!)
                                          : null,
                                      child: participant.photoUrl == null ||
                                              participant.photoUrl!.isEmpty
                                          ? Text(
                                              participant.name.isNotEmpty
                                                  ? participant.name[0]
                                                  : '?',
                                            )
                                          : null,
                                    ),
                                    title: Text(participant.name),
                                    subtitle: Text(participant.relationLabel),
                                    controlAffinity:
                                        ListTileControlAffinity.trailing,
                                    contentPadding: EdgeInsets.zero,
                                  );
                                },
                              ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selectedUserIds.length < 2
                      ? null
                      : () {
                          Navigator.of(context).pop(
                            _CreateGroupChatDraft(
                              participantIds: _selectedUserIds.toList(),
                              title: _titleController.text.trim(),
                            ),
                          );
                        },
                  icon: const Icon(Icons.groups_2_outlined),
                  label: Text(
                    _selectedUserIds.length < 2
                        ? 'Выберите ещё участников'
                        : 'Создать чат',
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
