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

  /// «Связь» placeholder, shown in the right pane when no chat is open.
  ///
  /// Чанк 26: было полноразмерной карточкой (заголовок + контекст-пилюля +
  /// три кнопки + три строки подсказок) — на пустой панели это читалось
  /// как отдельный мини-дашборд рядом с уже насыщенным списком слева.
  /// Все действия отсюда дублировались в другом месте («Новый чат» — в
  /// топбаре списка, «Родные»/«Дерево» — в нав-рейле шелла), так что
  /// карточка добавляла шум без нового функционала. Теперь это просто
  /// центрированные иконка + строка — как «Select a chat» в Telegram
  /// Desktop — без своей рамки/фона.
  Widget _buildConnectPane(
    ThemeData theme, {
    required bool isFriendsTree,
    required String? selectedTreeName,
  }) {
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_outlined,
              size: 40,
              color: tokens.inkMuted,
            ),
            const SizedBox(height: 10),
            Text(
              'Связь',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: tokens.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Выберите чат слева, чтобы начать переписку',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.inkMuted,
              ),
            ),
          ],
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
    // Мобильный список без «обзорной» строки: переключатель дерева живёт в
    // топбаре (как на главной), счётчик новых — на бейдже вкладки. Первый
    // чат должен начинаться сразу под поиском и табами, как в Telegram.
    // Системный «назад» при открытом поиске закрывает поиск, а не вкладку.
    return PopScope(
      canPop: !_isSearchOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closeSearch();
      },
      child: Column(
        children: [
          _buildFilterBar(theme, compact: true),
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
      padding: EdgeInsets.fromLTRB(10, compact ? 6 : 8, 10, compact ? 4 : 10),
      child: GlassPanel(
        padding: EdgeInsets.zero,
        blur: 12,
        borderRadius: BorderRadius.circular(compact ? 14 : 18),
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        child: SizedBox(
          height: compact ? 40 : null,
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
      padding: EdgeInsets.fromLTRB(
        compact ? 4 : 12,
        compact ? 2 : 0,
        12,
        compact ? 0 : 12,
      ),
      child: compact
          ? _buildFilterTabs(theme, archivedCount: archivedCount)
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

  /// Мобильные фильтры — текстовые табы с подчёркиванием (как папки в
  /// Telegram), а не чипы: та же функция, вдвое ниже и без рамок.
  Widget _buildFilterTabs(ThemeData theme, {required int archivedCount}) {
    final entries = <MapEntry<_ChatsVisibilityFilter, String>>[
      const MapEntry(_ChatsVisibilityFilter.all, 'Все'),
      const MapEntry(_ChatsVisibilityFilter.unread, 'Непрочитанные'),
      MapEntry(
        _ChatsVisibilityFilter.archived,
        archivedCount > 0 ? 'Архив ($archivedCount)' : 'Архив',
      ),
    ];
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        children: [
          for (final entry in entries)
            _buildFilterTab(theme, filter: entry.key, label: entry.value),
        ],
      ),
    );
  }

  Widget _buildFilterTab(
    ThemeData theme, {
    required _ChatsVisibilityFilter filter,
    required String label,
  }) {
    final selected = _activeFilter == filter;
    final color = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant;
    return InkWell(
      key: ValueKey<String>('chats-filter-${_filterKeySuffix(filter)}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => _setActiveFilter(filter),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: color,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
            const SizedBox(height: 3),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              height: 2.5,
              width: selected ? 22 : 0,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Ключи табов совпадают с ключами десктопных чипов — на них завязаны тесты.
  String _filterKeySuffix(_ChatsVisibilityFilter filter) {
    if (filter == _ChatsVisibilityFilter.unread) return 'unread';
    if (filter == _ChatsVisibilityFilter.archived) return 'archive';
    return 'all';
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
