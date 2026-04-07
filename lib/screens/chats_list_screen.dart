// ignore_for_file: unused_field, unused_element
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
import '../models/family_relation.dart';
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
  List<_GroupChatParticipant> _relatives = [];
  bool _isLoading = true;
  String? _errorMessage;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadChats();
    _loadRelatives();
  }

  @override
  void dispose() {
    _chatsSubscription?.cancel();
    _searchController.dispose();
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

  void _loadRelatives() async {
    try {
      final treeId =
          Provider.of<TreeProvider>(context, listen: false).selectedTreeId;
      if (treeId == null || treeId.isEmpty) return;

      final service = GetIt.I<FamilyTreeServiceInterface>();
      final relatives = await service.getRelatives(treeId);
      final currentUserId = _authService.currentUserId;

      if (!mounted) return;
      setState(() {
        _relatives = relatives
            .where((p) => p.userId != null && p.userId != currentUserId)
            .map((p) => _GroupChatParticipant(
                  userId: p.userId!,
                  name: p.name.trim().isNotEmpty ? p.name : 'Родственник',
                  photoUrl: p.photoUrl,
                  relationLabel: (p.relation ?? '').trim().isNotEmpty
                      ? p.relation!
                      : 'Родственник',
                ))
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
      });
    } catch (e) {
      debugPrint('Error loading relatives for search: $e');
    }
  }

  Future<void> _openChatComposer() async {
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

    final draft = await showModalBottomSheet<_CreateChatDraft>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CreateChatSheet(
        treeId: selectedTreeId,
        currentUserId: currentUserId,
      ),
    );

    if (!mounted || draft == null) {
      return;
    }

    try {
      late final String? chatId;
      late final String title;
      late final String chatType;
      if (draft.mode == _ChatComposerMode.direct) {
        title = draft.directUserName ?? 'Личный чат';
        chatType = 'direct';
        chatId = await _chatService.getOrCreateChat(draft.directUserId ?? '');
      } else if (draft.mode == _ChatComposerMode.branch ||
          draft.mode == _ChatComposerMode.branches) {
        title = _resolveBranchChatTitle(draft);
        chatType = 'branch';
        chatId = await _chatService.createBranchChat(
          treeId: selectedTreeId,
          branchRootPersonIds: draft.branchRootPersonIds,
          title: title,
        );
      } else {
        title = (draft.title?.trim().isNotEmpty ?? false)
            ? draft.title!.trim()
            : 'Групповой чат';
        chatType = 'group';
        chatId = await _chatService.createGroupChat(
          participantIds: draft.participantIds,
          title: draft.title,
          treeId: selectedTreeId,
        );
      }

      if (chatId == null || chatId.isEmpty) {
        throw StateError('Не удалось создать чат');
      }

      final encodedTitle = Uri.encodeComponent(title);
      if (!mounted) {
        return;
      }
      context.push('/chats/view/$chatId?type=$chatType&title=$encodedTitle');
    } catch (_) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            draft.mode == _ChatComposerMode.branch ||
                    draft.mode == _ChatComposerMode.branches
                ? 'Не удалось создать чат ветки.'
                : draft.mode == _ChatComposerMode.direct
                    ? 'Не удалось открыть личный чат.'
                    : 'Не удалось создать групповой чат.',
          ),
        ),
      );
    }
  }

  String _resolveBranchChatTitle(_CreateChatDraft draft) {
    final explicitTitle = draft.title?.trim();
    if (explicitTitle != null && explicitTitle.isNotEmpty) {
      return explicitTitle;
    }

    if (draft.branchRootNames.length == 1) {
      return 'Ветка ${draft.branchRootNames.first}';
    }

    if (draft.branchRootNames.isEmpty) {
      return 'Чат веток';
    }

    final previewNames = draft.branchRootNames.take(2).join(', ');
    final suffix = draft.branchRootNames.length > 2 ? ' и ещё' : '';
    return 'Ветки: $previewNames$suffix';
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
            onPressed: _openChatComposer,
            tooltip: 'Новый чат',
            icon: const Icon(Icons.add_comment_outlined),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? _buildErrorState()
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1400),
                    child: Column(
                      children: [
                        _buildSearchBar(theme),
                        Expanded(
                          child: _chatPreviews.isEmpty && _searchQuery.isEmpty
                              ? _buildEmptyState(theme)
                              : _buildChatList(theme, currentUserId),
                        ),
                      ],
                    ),
                  ),
                ),
    );
  }

  Widget _buildSearchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: TextField(
        controller: _searchController,
        onChanged: (value) {
          setState(() {
            _searchQuery = value.trim().toLowerCase();
          });
        },
        decoration: InputDecoration(
          hintText: 'Поиск чатов и людей',
          prefixIcon: const Icon(Icons.search, size: 22),
          suffixIcon: _searchQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {
                      _searchQuery = '';
                    });
                  },
                )
              : null,
          filled: true,
          fillColor:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(
                color: theme.colorScheme.primary.withValues(alpha: 0.5)),
          ),
        ),
      ),
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
              onPressed: _openChatComposer,
              icon: const Icon(Icons.add_comment_outlined),
              label: const Text('Создать чат'),
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
    final filteredChats = _chatPreviews.where((chat) {
      if (_searchQuery.isEmpty) return true;
      return chat.displayName.toLowerCase().contains(_searchQuery) ||
          chat.lastMessage.toLowerCase().contains(_searchQuery);
    }).toList();

    final filteredRelatives = _searchQuery.isEmpty
        ? const <_GroupChatParticipant>[]
        : _relatives.where((p) {
            final hasChat = _chatPreviews
                .any((c) => !c.isGroup && c.otherUserId == p.userId);
            if (hasChat) return false;
            return p.name.toLowerCase().contains(_searchQuery) ||
                p.relationLabel.toLowerCase().contains(_searchQuery);
          }).toList();

    if (filteredChats.isEmpty &&
        filteredRelatives.isEmpty &&
        _searchQuery.isNotEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('Ничего не найдено', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Попробуйте другой запрос или создайте новый чат.',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    final showRelatives = filteredRelatives.isNotEmpty;
    final totalCount = filteredChats.length +
        (showRelatives ? filteredRelatives.length + 1 : 0);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: totalCount,
      itemBuilder: (context, index) {
        if (index < filteredChats.length) {
          return _buildChatTile(theme, filteredChats[index], currentUserId);
        }

        if (showRelatives) {
          final relativeIndex = index - filteredChats.length;
          if (relativeIndex == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Люди',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            );
          }
          final participant = filteredRelatives[relativeIndex - 1];
          return ListTile(
            onTap: () => _openPrivateChat(participant),
            leading: CircleAvatar(
              radius: 24,
              backgroundImage: (participant.photoUrl?.isNotEmpty ?? false)
                  ? NetworkImage(participant.photoUrl!)
                  : null,
              child: (participant.photoUrl?.isEmpty ?? true)
                  ? Text(participant.name.isNotEmpty
                      ? participant.name[0].toUpperCase()
                      : '?')
                  : null,
            ),
            title: Text(participant.name,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(participant.relationLabel),
            trailing: const Icon(Icons.chevron_right, size: 20),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  Future<void> _openPrivateChat(_GroupChatParticipant participant) async {
    setState(() => _isLoading = true);
    try {
      final chatId = await _chatService.getOrCreateChat(participant.userId);
      if (chatId != null && mounted) {
        context.push(
          '/chats/view/$chatId?type=direct&title=${Uri.encodeComponent(participant.name)}'
          '${participant.photoUrl != null ? '&photo=${Uri.encodeComponent(participant.photoUrl!)}' : ''}'
          '&userId=${participant.userId}',
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть чат.')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildChatTile(
      ThemeData theme, ChatPreview chat, String currentUserId) {
    final hasUnread = chat.unreadCount > 0;
    final isLastFromMe = chat.lastMessageSenderId == currentUserId;
    final messageTime = chat.lastMessageTime;
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
              child:
                  chat.displayPhotoUrl == null || chat.displayPhotoUrl!.isEmpty
                      ? chat.isGroup
                          ? Icon(
                              chat.isBranch
                                  ? Icons.account_tree_outlined
                                  : Icons.group_outlined,
                              color: theme.colorScheme.onPrimaryContainer,
                            )
                          : Text(
                              chat.displayName.isNotEmpty
                                  ? chat.displayName[0].toUpperCase()
                                  : '?',
                              style: TextStyle(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontWeight: FontWeight.bold,
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
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          chat.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight:
                                hasUnread ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ),
                      Text(
                        timeLabel,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: hasUnread
                              ? theme.colorScheme.primary
                              : Colors.grey[600],
                          fontWeight:
                              hasUnread ? FontWeight.w700 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (isLastFromMe) ...[
                        Icon(
                          Icons.done_all,
                          size: 14,
                          color: Colors.grey[500],
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          chat.lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color:
                                hasUnread ? Colors.black87 : Colors.grey[600],
                            fontWeight:
                                hasUnread ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            chat.unreadCount.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
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

enum _ChatComposerMode { direct, group, branch, branches }

class _CreateChatDraft {
  const _CreateChatDraft({
    required this.mode,
    this.participantIds = const <String>[],
    this.branchRootPersonIds = const <String>[],
    this.branchRootNames = const <String>[],
    this.directUserId,
    this.directUserName,
    this.title,
  });

  final _ChatComposerMode mode;
  final List<String> participantIds;
  final List<String> branchRootPersonIds;
  final List<String> branchRootNames;
  final String? directUserId;
  final String? directUserName;
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

class _BranchChatCandidate {
  const _BranchChatCandidate({
    required this.personId,
    required this.name,
    required this.photoUrl,
    required this.relationLabel,
    required this.linkedParticipantIds,
  });

  final String personId;
  final String name;
  final String? photoUrl;
  final String relationLabel;
  final Set<String> linkedParticipantIds;

  int get linkedParticipantCount => linkedParticipantIds.length;
}

class _CreateChatSheet extends StatefulWidget {
  const _CreateChatSheet({
    required this.treeId,
    required this.currentUserId,
  });

  final String treeId;
  final String currentUserId;

  @override
  State<_CreateChatSheet> createState() => _CreateChatSheetState();
}

class _CreateChatSheetState extends State<_CreateChatSheet> {
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selectedUserIds = <String>{};
  final Set<String> _selectedBranchRootIds = <String>{};

  _ChatComposerMode _mode = _ChatComposerMode.direct;
  late final TabController _tabController;

  bool _isLoading = true;
  String? _errorMessage;
  List<_GroupChatParticipant> _participants = const <_GroupChatParticipant>[];
  List<_BranchChatCandidate> _branchCandidates = const <_BranchChatCandidate>[];

  @override
  void initState() {
    super.initState();
    _loadParticipants();
    _searchController.addListener(_handleSearchChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // DefaultTabController handles state, but we might want to listen to it
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
      final results = await Future.wait([
        _familyTreeService.getRelatives(widget.treeId),
        _familyTreeService.getRelations(widget.treeId),
      ]);
      final relatives = results[0] as List<FamilyPerson>;
      final relations = results[1] as List<FamilyRelation>;
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
        _branchCandidates = _buildBranchCandidates(relatives, relations);
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

  List<_BranchChatCandidate> _buildBranchCandidates(
    List<FamilyPerson> relatives,
    List<FamilyRelation> relations,
  ) {
    final candidates = relatives.map((person) {
      final linkedUserIds = _buildLinkedBranchParticipantIds(
        branchRootPersonId: person.id,
        relatives: relatives,
        relations: relations,
      );
      linkedUserIds.remove(widget.currentUserId);

      return _BranchChatCandidate(
        personId: person.id,
        name: person.name.trim().isNotEmpty ? person.name : 'Без имени',
        photoUrl: person.photoUrl,
        relationLabel: _relationLabel(person),
        linkedParticipantIds: linkedUserIds,
      );
    }).toList()
      ..sort((left, right) {
        final availability = right.linkedParticipantCount.compareTo(
          left.linkedParticipantCount,
        );
        if (availability != 0) {
          return availability;
        }
        return left.name.compareTo(right.name);
      });
    return candidates;
  }

  Set<String> _buildLinkedBranchParticipantIds({
    required String branchRootPersonId,
    required List<FamilyPerson> relatives,
    required List<FamilyRelation> relations,
  }) {
    final visibleIds = _buildBranchVisiblePersonIds(
      branchRootPersonId: branchRootPersonId,
      relatives: relatives,
      relations: relations,
    );
    final linkedUserIds = <String>{};
    for (final person in relatives) {
      if (!visibleIds.contains(person.id)) {
        continue;
      }
      final linkedUserId = person.userId?.trim();
      if (linkedUserId != null && linkedUserId.isNotEmpty) {
        linkedUserIds.add(linkedUserId);
      }
    }
    return linkedUserIds;
  }

  Set<String> _buildBranchVisiblePersonIds({
    required String branchRootPersonId,
    required List<FamilyPerson> relatives,
    required List<FamilyRelation> relations,
  }) {
    final personIds = relatives.map((person) => person.id).toSet();
    if (!personIds.contains(branchRootPersonId)) {
      return personIds;
    }

    final childrenByParent = <String, Set<String>>{};
    final spousesByPerson = <String, Set<String>>{};
    for (final relation in relations) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null && childId != null) {
        childrenByParent.putIfAbsent(parentId, () => <String>{}).add(childId);
      }
      if (_isSpouseRelation(relation)) {
        spousesByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        spousesByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
      }
    }

    final visibleIds = <String>{branchRootPersonId};
    final queue = <String>[branchRootPersonId];
    while (queue.isNotEmpty) {
      final currentId = queue.removeAt(0);
      for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
        if (visibleIds.add(spouseId)) {
          queue.add(spouseId);
        }
      }
      for (final childId in childrenByParent[currentId] ?? const <String>{}) {
        if (visibleIds.add(childId)) {
          queue.add(childId);
        }
      }
    }

    return visibleIds;
  }

  bool _isSpouseRelation(FamilyRelation relation) {
    return relation.relation1to2 == RelationType.spouse ||
        relation.relation2to1 == RelationType.spouse ||
        relation.relation1to2 == RelationType.partner ||
        relation.relation2to1 == RelationType.partner ||
        relation.relation1to2 == RelationType.ex_spouse ||
        relation.relation2to1 == RelationType.ex_spouse ||
        relation.relation1to2 == RelationType.ex_partner ||
        relation.relation2to1 == RelationType.ex_partner;
  }

  String? _parentIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person1Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person2Id;
    }
    return null;
  }

  String? _childIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.child ||
        relation.relation2to1 == RelationType.parent) {
      return relation.person1Id;
    }
    if (relation.relation2to1 == RelationType.child ||
        relation.relation1to2 == RelationType.parent) {
      return relation.person2Id;
    }
    return null;
  }

  Set<String> _selectedBranchParticipantIds() {
    final linkedUserIds = <String>{};
    for (final candidate in _branchCandidates) {
      if (_selectedBranchRootIds.contains(candidate.personId)) {
        linkedUserIds.addAll(candidate.linkedParticipantIds);
      }
    }
    return linkedUserIds;
  }

  bool get _canSubmitDirect => _selectedUserIds.length == 1;

  bool get _canSubmitGroup => _selectedUserIds.length >= 2;

  bool get _canSubmitBranch =>
      _selectedBranchRootIds.isNotEmpty &&
      _selectedBranchParticipantIds().isNotEmpty;

  bool get _canSubmitSingleBranch =>
      _selectedBranchRootIds.length == 1 &&
      _selectedBranchParticipantIds().isNotEmpty;

  String get _branchSelectionLabel {
    if (_selectedBranchRootIds.isEmpty) {
      return 'Выберите ветку';
    }
    final linkedCount = _selectedBranchParticipantIds().length;
    if (linkedCount <= 0) {
      return 'В ветке пока некому писать';
    }
    return linkedCount == 1 ? 'Открыть чат ветки' : 'Открыть чат веток';
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
    final filteredBranches = _branchCandidates.where((candidate) {
      if (search.isEmpty) {
        return true;
      }
      return candidate.name.toLowerCase().contains(search) ||
          candidate.relationLabel.toLowerCase().contains(search);
    }).toList();

    return DefaultTabController(
      length: 4,
      initialIndex: _mode.index,
      child: Builder(
        builder: (context) {
          final tabController = DefaultTabController.of(context);
          tabController.addListener(() {
            if (tabController.indexIsChanging) {
              setState(() {
                _mode = _ChatComposerMode.values[tabController.index];
              });
            }
          });

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 8,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: SizedBox(
                height: 620,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Новый чат',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                          style: IconButton.styleFrom(
                            backgroundColor: theme
                                .colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: TabBar(
                        dividerColor: Colors.transparent,
                        indicatorSize: TabBarIndicatorSize.tab,
                        indicator: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: theme.colorScheme.primary,
                        ),
                        labelColor: theme.colorScheme.onPrimary,
                        unselectedLabelColor:
                            theme.colorScheme.onSurfaceVariant,
                        labelStyle: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                        tabs: const [
                          Tab(text: 'Личный'),
                          Tab(text: 'Группа'),
                          Tab(text: 'Ветка'),
                          Tab(text: 'Ветки'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: _mode == _ChatComposerMode.direct ||
                                _mode == _ChatComposerMode.group
                            ? 'Найти родственника'
                            : 'Найти ветку по имени',
                        filled: true,
                        fillColor: theme.colorScheme.surfaceContainerHighest
                            .withValues(alpha: 0.3),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                              color: theme.colorScheme.primary, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_mode != _ChatComposerMode.direct) ...[
                      TextField(
                        controller: _titleController,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          labelText: 'Название чата',
                          hintText: _mode == _ChatComposerMode.group
                              ? 'Например: Семья Ивановых'
                              : 'Необязательно',
                          prefixIcon: const Icon(Icons.title, size: 20),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    Expanded(
                      child: _isLoading
                          ? const Center(child: CircularProgressIndicator())
                          : _errorMessage != null
                              ? Center(
                                  child: Text(
                                    _errorMessage!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: theme.colorScheme.error),
                                  ),
                                )
                              : TabBarView(
                                  physics: const NeverScrollableScrollPhysics(),
                                  children: [
                                    _buildParticipantSelector(
                                        filteredParticipants,
                                        multi: false),
                                    _buildParticipantSelector(
                                        filteredParticipants,
                                        multi: true),
                                    _buildBranchSelector(filteredBranches,
                                        multi: false),
                                    _buildBranchSelector(filteredBranches,
                                        multi: true),
                                  ],
                                ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        onPressed:
                            _canSubmitCurrentMode ? _submitCurrentMode : null,
                        style: FilledButton.styleFrom(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        icon: Icon(_submitIcon),
                        label: Text(_submitLabel),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  bool get _canSubmitCurrentMode {
    switch (_mode) {
      case _ChatComposerMode.direct:
        return _canSubmitDirect;
      case _ChatComposerMode.group:
        return _canSubmitGroup;
      case _ChatComposerMode.branch:
        return _canSubmitSingleBranch;
      case _ChatComposerMode.branches:
        return _canSubmitBranch;
    }
  }

  void _submitCurrentMode() {
    switch (_mode) {
      case _ChatComposerMode.direct:
        _submitDirectDraft();
        break;
      case _ChatComposerMode.group:
        _submitGroupDraft();
        break;
      case _ChatComposerMode.branch:
        _submitSingleBranchDraft();
        break;
      case _ChatComposerMode.branches:
        _submitBranchDraft();
        break;
    }
  }

  IconData get _submitIcon {
    switch (_mode) {
      case _ChatComposerMode.direct:
        return Icons.chat_bubble_outline;
      case _ChatComposerMode.group:
        return Icons.groups_2_outlined;
      case _ChatComposerMode.branch:
      case _ChatComposerMode.branches:
        return Icons.account_tree_outlined;
    }
  }

  String get _submitLabel {
    switch (_mode) {
      case _ChatComposerMode.direct:
        return _canSubmitDirect ? 'Открыть чат' : 'Выберите собеседника';
      case _ChatComposerMode.group:
        return _canSubmitGroup ? 'Создать группу' : 'Выберите участников';
      case _ChatComposerMode.branch:
        return _canSubmitSingleBranch ? 'Открыть чат ветки' : 'Выберите ветку';
      case _ChatComposerMode.branches:
        return _canSubmitBranch ? 'Открыть чат веток' : 'Выберите ветки';
    }
  }

  Widget _buildParticipantSelector(List<_GroupChatParticipant> participants,
      {required bool multi}) {
    if (participants.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_search_outlined,
                  size: 48, color: Colors.grey[400]),
              const SizedBox(height: 12),
              const Text(
                'Родственники не найдены.\nУбедитесь, что они добавлены в дерево и имеют аккаунт.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: participants.length,
      itemBuilder: (context, index) {
        final participant = participants[index];
        final isSelected = _selectedUserIds.contains(participant.userId);
        return ListTile(
          onTap: () {
            setState(() {
              if (!multi) {
                _selectedUserIds
                  ..clear()
                  ..add(participant.userId);
                // In direct mode, we can submit immediately on tap if we want,
                // but let's keep the explicit button for consistency or single-selection feel.
                return;
              }
              if (isSelected) {
                _selectedUserIds.remove(participant.userId);
              } else {
                _selectedUserIds.add(participant.userId);
              }
            });
          },
          leading: CircleAvatar(
            radius: 20,
            backgroundImage:
                participant.photoUrl != null && participant.photoUrl!.isNotEmpty
                    ? NetworkImage(participant.photoUrl!)
                    : null,
            child: participant.photoUrl == null || participant.photoUrl!.isEmpty
                ? Text(participant.name.isNotEmpty
                    ? participant.name[0].toUpperCase()
                    : '?')
                : null,
          ),
          title: Text(
            participant.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(participant.relationLabel),
          trailing: multi
              ? Checkbox(
                  value: isSelected,
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedUserIds.add(participant.userId);
                      } else {
                        _selectedUserIds.remove(participant.userId);
                      }
                    });
                  },
                )
              : (isSelected
                  ? Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary)
                  : null),
        );
      },
    );
  }

  Widget _buildBranchSelector(List<_BranchChatCandidate> candidates,
      {required bool multi}) {
    if (candidates.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.account_tree_outlined,
                  size: 48, color: Colors.grey[400]),
              const SizedBox(height: 12),
              const Text(
                'Ветки не найдены.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: candidates.length,
      itemBuilder: (context, index) {
        final candidate = candidates[index];
        final isSelected = _selectedBranchRootIds.contains(candidate.personId);
        final linkedCount = candidate.linkedParticipantCount;
        return ListTile(
          onTap: () {
            setState(() {
              if (!multi) {
                _selectedBranchRootIds
                  ..clear()
                  ..add(candidate.personId);
                return;
              }
              if (isSelected) {
                _selectedBranchRootIds.remove(candidate.personId);
              } else {
                _selectedBranchRootIds.add(candidate.personId);
              }
            });
          },
          leading: CircleAvatar(
            radius: 20,
            backgroundImage:
                candidate.photoUrl != null && candidate.photoUrl!.isNotEmpty
                    ? NetworkImage(candidate.photoUrl!)
                    : null,
            child: candidate.photoUrl == null || candidate.photoUrl!.isEmpty
                ? Text(candidate.name.isNotEmpty
                    ? candidate.name[0].toUpperCase()
                    : '?')
                : null,
          ),
          title: Text(
            candidate.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            linkedCount > 0
                ? '${candidate.relationLabel} · $linkedCount ${_participantLabel(linkedCount)}'
                : '${candidate.relationLabel} · Нет участников',
          ),
          trailing: multi
              ? Checkbox(
                  value: isSelected,
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _selectedBranchRootIds.add(candidate.personId);
                      } else {
                        _selectedBranchRootIds.remove(candidate.personId);
                      }
                    });
                  },
                )
              : (isSelected
                  ? Icon(Icons.check_circle,
                      color: Theme.of(context).colorScheme.primary)
                  : null),
        );
      },
    );
  }

  String _participantLabel(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod10 == 1 && mod100 != 11) {
      return 'участник';
    }
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'участника';
    }
    return 'участников';
  }

  void _submitDirectDraft() {
    final participant = _participants.firstWhere(
      (entry) => _selectedUserIds.contains(entry.userId),
    );
    Navigator.of(context).pop(
      _CreateChatDraft(
        mode: _ChatComposerMode.direct,
        directUserId: participant.userId,
        directUserName: participant.name,
      ),
    );
  }

  void _submitGroupDraft() {
    Navigator.of(context).pop(
      _CreateChatDraft(
        mode: _ChatComposerMode.group,
        participantIds: _selectedUserIds.toList(),
        title: _titleController.text.trim(),
      ),
    );
  }

  void _submitSingleBranchDraft() {
    final selectedCandidate = _branchCandidates.firstWhere(
      (candidate) => _selectedBranchRootIds.contains(candidate.personId),
    );
    Navigator.of(context).pop(
      _CreateChatDraft(
        mode: _ChatComposerMode.branch,
        branchRootPersonIds: [selectedCandidate.personId],
        branchRootNames: [selectedCandidate.name],
        title: _titleController.text.trim(),
      ),
    );
  }

  void _submitBranchDraft() {
    final selectedCandidates = _branchCandidates
        .where(
            (candidate) => _selectedBranchRootIds.contains(candidate.personId))
        .toList()
      ..sort((left, right) => left.name.compareTo(right.name));
    Navigator.of(context).pop(
      _CreateChatDraft(
        mode: _ChatComposerMode.branch,
        branchRootPersonIds:
            selectedCandidates.map((candidate) => candidate.personId).toList(),
        branchRootNames:
            selectedCandidates.map((candidate) => candidate.name).toList(),
        title: _titleController.text.trim(),
      ),
    );
  }
}
