part of 'chats_list_screen.dart';

extension _ChatsListScreenSections on _ChatsListScreenState {
  Widget _buildDesktopShell({
    required ThemeData theme,
    required String currentUserId,
    required bool isFriendsTree,
    required String? selectedTreeName,
    required bool showInitialLoading,
  }) {
    final listPanel = GlassPanel(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(22),
      color: theme.colorScheme.surface.withValues(alpha: 0.78),
      child: Column(
        children: [
          _buildChatsOverview(
            theme,
            isFriendsTree: isFriendsTree,
            selectedTreeName: selectedTreeName,
            showLoadingPulse: showInitialLoading,
          ),
          _buildSearchBar(theme),
          _buildFilterBar(theme),
          Expanded(
            child: showInitialLoading
                ? _buildInitialLoadingState(theme)
                : _chatPreviews.isEmpty && _searchQuery.isEmpty
                    ? _buildEmptyState(theme)
                    : _buildChatList(theme, currentUserId),
          ),
        ],
      ),
    );

    if (!_isWideLayout(context)) {
      return _buildMobileShell(
        theme: theme,
        currentUserId: currentUserId,
        isFriendsTree: isFriendsTree,
        selectedTreeName: selectedTreeName,
        showInitialLoading: showInitialLoading,
      );
    }

    // Desktop master-detail (Telegram-style): the chat list is a resizable
    // left column; opening a chat fills the right pane instead of pushing a
    // full-screen route over the shell. No chat open → «Связь» placeholder.
    final Widget rightPane = _selectedChat == null
        ? _buildConnectPane(
            theme,
            isFriendsTree: isFriendsTree,
            selectedTreeName: selectedTreeName,
          )
        : _buildChatDetailPane(theme);

    return SizedBox(
      height: double.infinity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: _chatListPaneWidth, child: listPanel),
          _buildPaneResizer(theme),
          Expanded(child: rightPane),
        ],
      ),
    );
  }

  /// Draggable divider between the list and the detail pane. Clamps the
  /// list width to a sane range and persists it across sessions.
  Widget _buildPaneResizer(ThemeData theme) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) =>
            _resizeChatListPane(details.delta.dx),
        onHorizontalDragEnd: (_) => unawaited(_persistChatListPaneWidth()),
        child: SizedBox(
          width: 16,
          child: Center(
            child: Container(
              width: 4,
              margin: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Right pane hosting the selected chat as an embedded ChatScreen — no
  /// «назад» leading; switching chats swaps the pane via its ValueKey.
  Widget _buildChatDetailPane(ThemeData theme) {
    final selected = _selectedChat!;
    return GlassPanel(
      padding: EdgeInsets.zero,
      borderRadius: BorderRadius.circular(22),
      color: theme.colorScheme.surface.withValues(alpha: 0.82),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: ChatScreen(
          key: ValueKey<String>('embedded-chat-${selected.chatId}'),
          chatId: selected.chatId,
          chatType: selected.chatType,
          title: selected.title,
          photoUrl: selected.photoUrl,
          otherUserId: selected.otherUserId,
          embedded: true,
          onOpenDirectChat: ({
            required chatId,
            required title,
            photoUrl,
            otherUserId,
          }) =>
              _openChatTarget(
            chatId: chatId,
            chatType: 'direct',
            title: title,
            photoUrl: photoUrl,
            otherUserId: otherUserId,
          ),
        ),
      ),
    );
  }

  /// «Связь» quick-actions placeholder, shown in the right pane when no chat
  /// is open. (Previously a permanent 320px side rail.)
  Widget _buildConnectPane(
    ThemeData theme, {
    required bool isFriendsTree,
    required String? selectedTreeName,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: GlassPanel(
          padding: const EdgeInsets.all(18),
          borderRadius: BorderRadius.circular(30),
          color: theme.colorScheme.surface.withValues(alpha: 0.76),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Связь',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              _buildContextPill(
                theme,
                isFriendsTree: isFriendsTree,
                label: selectedTreeName ??
                    (isFriendsTree ? 'Круг друзей' : 'Семейное дерево'),
              ),
              const SizedBox(height: 16),
              // Quick actions. Live deploy showed the previous
              // FilledButton.icon + FilledButton.tonalIcon mix
              // rendering as three indistinguishable green
              // rectangles — the warm sage palette fuses primary
              // and secondaryContainer at low contrast against
              // the panel's tinted glass backdrop. One filled
              // accent CTA + two outlined buttons gives a clear
              // visual hierarchy and readable labels on both
              // light and dark themes.
              FilledButton.icon(
                onPressed: _openChatComposer,
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                icon: const Icon(Icons.add_comment_outlined, size: 18),
                label: const Text('Создать чат'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => context.go('/relatives'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                icon: const Icon(Icons.people_outline, size: 18),
                label: Text(
                  isFriendsTree ? 'Открыть связи' : 'Открыть родных',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => context.go('/tree'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: const Text('Открыть дерево'),
              ),
              const SizedBox(height: 18),
              _buildDesktopHint(
                theme,
                icon: Icons.search,
                title: 'Поиск',
                subtitle: isFriendsTree ? 'Чаты и люди круга' : 'Чаты и родные',
              ),
              const SizedBox(height: 12),
              _buildDesktopHint(
                theme,
                icon: Icons.group_add_outlined,
                title: 'Новый чат',
                subtitle: 'Личный, групповой или чат ветки',
              ),
              const SizedBox(height: 12),
              _buildDesktopHint(
                theme,
                icon: Icons.mark_chat_read_outlined,
                title: 'Поток',
                subtitle: 'Новые, архив и быстрые действия',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileShell({
    required ThemeData theme,
    required String currentUserId,
    required bool isFriendsTree,
    required String? selectedTreeName,
    required bool showInitialLoading,
  }) {
    return Column(
      children: [
        _buildChatsOverview(
          theme,
          isFriendsTree: isFriendsTree,
          selectedTreeName: selectedTreeName,
          showLoadingPulse: showInitialLoading,
          compact: true,
        ),
        _buildSearchBar(theme, compact: true),
        _buildFilterBar(theme, compact: true),
        Expanded(
          child: showInitialLoading
              ? _buildInitialLoadingState(theme)
              : _chatPreviews.isEmpty && _searchQuery.isEmpty
                  ? _buildEmptyState(theme)
                  : _buildChatList(theme, currentUserId),
        ),
      ],
    );
  }

  Widget _buildDesktopHint(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(icon, color: theme.colorScheme.primary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChatsOverview(
    ThemeData theme, {
    required bool isFriendsTree,
    required String? selectedTreeName,
    required bool showLoadingPulse,
    bool compact = false,
  }) {
    // Slim overview: just the active context pill plus a single unread/all
    // status chip. Detailed counts live further down inside individual list
    // entries — this header should help orient at a glance, not enumerate.
    final unreadCount = _chatPreviews.fold<int>(
      0,
      (sum, chat) => sum + chat.unreadCount,
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 6 : 10, 12, 0),
      child: SizedBox(
        height: compact ? 34 : null,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _buildContextPill(
                  theme,
                  isFriendsTree: isFriendsTree,
                  label: selectedTreeName ??
                      (isFriendsTree ? 'Круг друзей' : 'Семейное дерево'),
                  compact: compact,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Align(
                alignment: Alignment.centerRight,
                child: _buildChatStatChip(
                  theme,
                  icon: unreadCount > 0
                      ? Icons.mark_chat_unread_outlined
                      : Icons.mark_chat_read_outlined,
                  label: unreadCount > 0
                      ? (compact
                          ? '$unreadCount новых'
                          : _countLabel(
                              unreadCount,
                              one: 'непрочитанный',
                              few: 'непрочитанных',
                              many: 'непрочитанных',
                            ))
                      : (compact ? 'Новых нет' : 'Нет непрочитанных'),
                  highlighted: unreadCount > 0,
                  compact: compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContextPill(
    ThemeData theme, {
    required bool isFriendsTree,
    required String label,
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.16),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isFriendsTree
                ? Icons.diversity_3_outlined
                : Icons.account_tree_outlined,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: (compact
                      ? theme.textTheme.labelMedium
                      : theme.textTheme.labelLarge)
                  ?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatStatChip(
    ThemeData theme, {
    required IconData icon,
    required String label,
    bool highlighted = false,
    bool compact = false,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 10,
        vertical: compact ? 5 : 6,
      ),
      decoration: BoxDecoration(
        color: highlighted
            ? theme.colorScheme.primary.withValues(alpha: 0.10)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: (compact
                      ? theme.textTheme.labelMedium
                      : theme.textTheme.labelLarge)
                  ?.copyWith(
                color: highlighted ? theme.colorScheme.primary : null,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(ThemeData theme, {bool compact = false}) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 5 : 8, 12, compact ? 6 : 10),
      child: GlassPanel(
        padding: EdgeInsets.zero,
        blur: 12,
        borderRadius: BorderRadius.circular(compact ? 16 : 18),
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        child: SizedBox(
          height: compact ? 44 : null,
          child: TextField(
            controller: _searchController,
            focusNode: _searchFocusNode,
            textAlignVertical: TextAlignVertical.center,
            onChanged: (value) {
              _setSearchQuery(value.trim().toLowerCase());
            },
            decoration: InputDecoration(
              hintText: context.read<TreeProvider>().selectedTreeKind ==
                      TreeKind.friends
                  ? 'Поиск чатов и людей круга'
                  : 'Поиск чатов и людей',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      tooltip: 'Очистить поиск',
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () {
                        _clearSearchQuery();
                      },
                    )
                  : null,
              filled: false,
              isDense: compact,
              contentPadding: EdgeInsets.symmetric(
                vertical: compact ? 0 : 14,
                horizontal: 14,
              ),
              border: InputBorder.none,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFilterBar(ThemeData theme, {bool compact = false}) {
    final archivedCount = _archivedPreviewCount();
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, compact ? 4 : 12),
      child: compact
          ? SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                children: _buildFilterChips(
                  theme,
                  archivedCount: archivedCount,
                  compact: true,
                ),
              ),
            )
          : Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _buildFilterChips(
                theme,
                archivedCount: archivedCount,
              ),
            ),
    );
  }

  List<Widget> _buildFilterChips(
    ThemeData theme, {
    required int archivedCount,
    bool compact = false,
  }) {
    final chipPadding = compact
        ? const EdgeInsets.symmetric(horizontal: 10)
        : const EdgeInsets.symmetric(horizontal: 12);
    return [
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: const ValueKey<String>('chats-filter-all'),
          label: const Text('Все'),
          selected: _activeFilter == _ChatsVisibilityFilter.all,
          onSelected: (_) {
            _setActiveFilter(_ChatsVisibilityFilter.all);
          },
          labelPadding: chipPadding,
          visualDensity: compact
              ? const VisualDensity(horizontal: -2, vertical: -2)
              : null,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: const ValueKey<String>('chats-filter-unread'),
          label: const Text('Непрочитанные'),
          selected: _activeFilter == _ChatsVisibilityFilter.unread,
          onSelected: (_) {
            _setActiveFilter(_ChatsVisibilityFilter.unread);
          },
          labelPadding: chipPadding,
          visualDensity: compact
              ? const VisualDensity(horizontal: -2, vertical: -2)
              : null,
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          key: const ValueKey<String>('chats-filter-archive'),
          label: Text(
            archivedCount > 0 ? 'Архив ($archivedCount)' : 'Архив',
          ),
          selected: _activeFilter == _ChatsVisibilityFilter.archived,
          onSelected: (_) {
            _setActiveFilter(_ChatsVisibilityFilter.archived);
          },
          labelPadding: chipPadding,
          visualDensity: compact
              ? const VisualDensity(horizontal: -2, vertical: -2)
              : null,
        ),
      ),
    ];
  }

  Widget _buildFilterEmptyState(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String message,
    required String actionLabel,
    required VoidCallback onAction,
    String? secondaryActionLabel,
    VoidCallback? onSecondaryAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: GlassPanel(
            borderRadius: BorderRadius.circular(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 34, color: theme.colorScheme.primary),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton(
                      onPressed: onAction,
                      child: Text(actionLabel),
                    ),
                    if (secondaryActionLabel != null &&
                        onSecondaryAction != null)
                      FilledButton.tonal(
                        onPressed: onSecondaryAction,
                        child: Text(secondaryActionLabel),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildArchiveSummaryCard(ThemeData theme) {
    final archivedCount = _archivedPreviewCount();
    final unreadCount = _archivedUnreadCount();
    final archiveLabel = _countLabel(
      archivedCount,
      one: 'чат в архиве',
      few: 'чата в архиве',
      many: 'чатов в архиве',
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () {
          _setActiveFilter(_ChatsVisibilityFilter.archived);
        },
        child: GlassPanel(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          borderRadius: BorderRadius.circular(22),
          blur: 10,
          color: theme.colorScheme.surface.withValues(alpha: 0.74),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  Icons.archive_outlined,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      archiveLabel,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      unreadCount > 0
                          ? '$unreadCount непрочитанных'
                          : 'Чистый основной поток',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildChatMetaPill(
    ThemeData theme, {
    required IconData icon,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
