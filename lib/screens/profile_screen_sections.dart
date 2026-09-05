part of 'profile_screen.dart';

extension _ProfileScreenSections on _ProfileScreenState {
  Widget _buildProfileStateCard({
    required IconData icon,
    required String title,
    required String message,
    bool showProgress = false,
    List<Widget> actions = const <Widget>[],
  }) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            borderRadius: BorderRadius.circular(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 28,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.38,
                  ),
                ),
                if (showProgress) ...[
                  const SizedBox(height: 18),
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ],
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 10,
                    runSpacing: 10,
                    children: actions,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContributionEmptyState() {
    final theme = Theme.of(context);

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      borderRadius: BorderRadius.circular(20),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.mark_email_read_outlined,
              color: theme.colorScheme.primary,
              size: 21,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Предложений нет',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Новые правки появятся здесь.',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _profileCodeLabel() {
    final profile = _userProfile;
    if (profile == null) {
      return null;
    }
    final username = profile.username.trim();
    if (username.isNotEmpty) {
      return username.startsWith('@') ? username.substring(1) : username;
    }
    return null;
  }

  Widget _buildProfileConnectionSection({
    required String? selectedTreeId,
    required String? selectedTreeName,
  }) {
    final content = _buildProfileCodeRowContent(selectedTreeId: selectedTreeId);
    if (content == null) {
      return const SizedBox.shrink();
    }
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: content,
    );
  }

  /// Row content shared by [_buildProfileConnectionSection] (wide
  /// sidebar, boxed) and the flat quick-actions row in the narrow
  /// layout — qr icon + «Профильный код» + copy/share (or a fallback
  /// «Дерево» button when no tree is selected to link into). Returns
  /// null when the user has no profile code yet — callers decide how
  /// to skip the row (empty box vs. omitting it from a row list).
  Widget? _buildProfileCodeRowContent({required String? selectedTreeId}) {
    final profileCode = _profileCodeLabel();
    if (profileCode == null) {
      return null;
    }

    final connectionLink =
        _buildProfileConnectionLink(selectedTreeId, profileCode);
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Row(
      children: [
        Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: tokens.warmSoft,
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(
            Icons.qr_code_2_rounded,
            color: tokens.warm,
            size: 21,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Профильный код',
                style: AppTheme.sans(
                  color: tokens.ink,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '@$profileCode',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.sans(
                  color: tokens.inkMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        if (connectionLink == null)
          OutlinedButton(
            onPressed: () => context.go('/trees'),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Дерево'),
          )
        else ...[
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Скопировать ссылку',
            onPressed: () => _copyProfileConnectionLink(connectionLink),
            icon: const Icon(Icons.copy_outlined, size: 20),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Поделиться',
            onPressed: () => _shareProfileConnectionLink(connectionLink),
            icon: const Icon(Icons.share_outlined, size: 20),
          ),
        ],
      ],
    );
  }

  Widget _buildStoriesRailSection() {
    return StoryRail(
      title: 'Истории',
      currentUserId: _currentUserId ?? '',
      stories: _userStories,
      isLoading: _isLoadingStories,
      unavailable: _storiesUnavailable,
      onRetry: () {
        if (_currentUserId != null) {
          _loadStoriesForContext(
            selectedTreeId: context.read<TreeProvider>().selectedTreeId,
            currentUserId: _currentUserId!,
          );
        }
      },
      onCreateStory: () async {
        final result = await context.push('/stories/create');
        if (!mounted) {
          return;
        }
        if (result == true && _currentUserId != null) {
          _loadStoriesForContext(
            selectedTreeId: context.read<TreeProvider>().selectedTreeId,
            currentUserId: _currentUserId!,
          );
        }
      },
      onOpenStories: (stories) async {
        if (stories.isEmpty) {
          return;
        }
        final story = stories.last;
        final route = '/stories/view/${story.treeId}/${story.authorId}';
        await context.push(
          route,
        );
        if (!mounted) {
          return;
        }
        if (_currentUserId != null) {
          _loadStoriesForContext(
            selectedTreeId: context.read<TreeProvider>().selectedTreeId,
            currentUserId: _currentUserId!,
          );
        }
      },
      emptyLabel: 'Добавьте первую историю.',
    );
  }

  Future<void> _acceptContribution(ProfileContribution contribution) async {
    try {
      await _profileService.acceptProfileContribution(contribution.id);
      await _loadUserData();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Предложение применено к профилю.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            describeUserFacingError(
              authService: _authService,
              error: error,
              fallbackMessage:
                  'Не удалось применить правку. Попробуйте ещё раз.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _rejectContribution(ProfileContribution contribution) async {
    try {
      await _profileService.rejectProfileContribution(contribution.id);
      await _loadUserData();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Предложение отклонено.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            describeUserFacingError(
              authService: _authService,
              error: error,
              fallbackMessage:
                  'Не удалось отклонить правку. Попробуйте ещё раз.',
            ),
          ),
        ),
      );
    }
  }

  Widget _buildContributionCard(ProfileContribution contribution) {
    final theme = Theme.of(context);
    final fieldSummary = contribution.fields.entries
        .map((entry) => '${_contributionFieldLabel(entry.key)}: ${entry.value}')
        .join('\n');

    return GlassPanel(
      plain: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            contribution.authorDisplayName?.trim().isNotEmpty == true
                ? contribution.authorDisplayName!
                : 'Родственник',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          if ((contribution.message ?? '').isNotEmpty) ...[
            Text(
              contribution.message!,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 10),
          ],
          Text(
            fieldSummary,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _acceptContribution(contribution),
                  child: const Text('Принять'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _rejectContribution(contribution),
                  child: const Text('Отклонить'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _contributionFieldLabel(String fieldKey) {
    switch (fieldKey) {
      case 'firstName':
        return 'Имя';
      case 'lastName':
        return 'Фамилия';
      case 'middleName':
        return 'Отчество';
      case 'maidenName':
        return 'Девичья фамилия';
      case 'birthDate':
        return 'Дата рождения';
      case 'birthPlace':
        return 'Место рождения';
      case 'bio':
        return 'О человеке';
      case 'aboutFamily':
        return 'Для семьи';
      case 'familyStatus':
        return 'Семейное положение';
      case 'education':
        return 'Учёба';
      case 'work':
        return 'Работа и дело';
      case 'hometown':
        return 'Родной город';
      case 'languages':
        return 'Языки';
      case 'values':
        return 'Ценности';
      case 'religion':
        return 'Религия';
      case 'interests':
        return 'Интересы';
      default:
        return fieldKey;
    }
  }

  // ── New helper widgets called from the redesigned build() ─────────────────
  //
  // _buildStatsRow / _buildTreeChip used to feed the legacy
  // PersonDossierView slot — the Profile Redesign hero card now packs
  // the same stats + chips inline (see ProfileHeroCard / PillButton in
  // profile_screen.dart) so those helpers are gone.

  /// Compact "tree card" row — replaces the old big GraphContextBanner.
  /// Used on the wide-layout sidebar, which keeps its own boxed rhythm
  /// (see `_buildProfileSidebarColumn`); the narrow-layout quick-actions
  /// list below reuses [_buildTreeCardRowContent] directly without the
  /// extra GlassPanel border.
  Widget _buildTreeCardCompact(
    BuildContext context, {
    required FamilyPerson person,
    required bool isFriendsTree,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        borderRadius: BorderRadius.circular(20),
        plain: true,
        child: _buildTreeCardRowContent(context, person: person),
      ),
    );
  }

  /// Row content shared by [_buildTreeCardCompact] (wide sidebar, boxed)
  /// and the flat quick-actions row in the narrow (mobile) layout —
  /// avatar + name + three compact icon actions.
  Widget _buildTreeCardRowContent(
    BuildContext context, {
    required FamilyPerson person,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final photoCount = person.photoGallery.length;
    final avatarImage = buildAvatarImageProvider(person.primaryPhotoUrl);

    return Row(
      children: [
        CircleAvatar(
          radius: 18,
          backgroundImage: avatarImage,
          backgroundColor: scheme.primary.withValues(alpha: 0.12),
          foregroundColor: scheme.primary,
          child: avatarImage == null
              ? Text(
                  person.initials,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                  ),
                )
              : null,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Карточка в дереве',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                person.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
        // 40dp square icon actions (спека чанка 14) вместо IconButton с
        // VisualDensity.compact — тот всё ещё тянул к дефолтным 48dp
        // Material-констрейнтам, три штуки подряд плюс имя не влезали
        // на 360dp без сжатия колонки с именем до нечитаемого хвоста.
        _CompactSquareIconButton(
          tooltip: photoCount == 0 ? 'Фото пока нет' : 'Фото ($photoCount)',
          icon: Icons.photo_library_outlined,
          onPressed: photoCount == 0
              ? null
              : () => _showSelectedTreePersonGallery(person),
        ),
        _CompactSquareIconButton(
          tooltip: 'История',
          icon: Icons.history_outlined,
          onPressed: () => _showSelectedTreePersonHistory(person),
        ),
        _CompactSquareIconButton(
          tooltip: 'Открыть карточку',
          icon: Icons.open_in_new_rounded,
          onPressed: () => context.push(
            relativeDetailsRoute(person.id, treeId: person.treeId),
          ),
        ),
      ],
    );
  }

  /// Small "Account settings" card that replaces the full trust-summary panel.
  Widget _buildAccountSettingsLink(ColorScheme scheme, ThemeData theme) {
    final status = _accountLinkingStatus;
    final hasLinkedChannel =
        status?.primaryTrustedChannel?.label.isNotEmpty == true;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tokens.accentSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(Icons.shield_outlined, size: 20, color: tokens.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasLinkedChannel ? 'Аккаунт защищён' : 'Настройки аккаунта',
                  style: AppTheme.sans(
                    color: tokens.ink,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                  ),
                ),
                if (hasLinkedChannel)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Основной канал: ${status!.primaryTrustedChannel?.label}',
                      style: AppTheme.sans(
                        color: tokens.inkMuted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => context.push('/profile/settings'),
            child: Text(
              'Настройки',
              style: AppTheme.sans(
                color: tokens.accent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Chunk 14 density pass: unified quick-actions list ──────────────────
  //
  // «Профили» / «Карточка в дереве» / «Настройки аккаунта» / «Истории» /
  // «Профильный код» used to be five separate bordered cards stacked with
  // 8-16dp gaps between them on the narrow (mobile) layout — each one
  // mostly white space around a single line of real content. Telegram
  // groups exactly this kind of «about the account, not the content» rows
  // into one flat list with hairline dividers inside a single surface —
  // `_buildQuickActionsSection` is that list for the narrow layout. The
  // wide layout keeps its own boxed sidebar column (`_buildAccountSettingsLink`
  // / `_buildProfileConnectionSection` above, `_buildStoriesRailSection`
  // elsewhere in this file) untouched — different rhythm, more room.

  /// One row in [_buildQuickActionsSection]. `ListTile` + `VisualDensity
  /// (vertical: -1)` is the row primitive already established for
  /// settings/sessions density passes (see `settings_screen._buildActionRow`,
  /// commit 46038c3) — reused here so the row picks up the theme's own
  /// 16sp title / 13-14sp subtitle instead of hand-rolled font sizes.
  Widget _buildMenuRow({
    required IconData icon,
    required String title,
    String? subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        (Theme.of(context).brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return ListTile(
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      onTap: onTap,
      leading: Icon(icon, size: 24, color: tokens.accent),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: trailing ??
          (onTap != null
              ? Icon(Icons.chevron_right_rounded, color: tokens.inkMuted)
              : null),
    );
  }

  /// «Настройки аккаунта» as a chevron row (spec: item 2) instead of the
  /// boxed card + trailing «Настройки» button used on the wide sidebar
  /// (`_buildAccountSettingsLink` above) — same title/subtitle logic.
  Widget _buildAccountSettingsMenuRow() {
    final status = _accountLinkingStatus;
    final hasLinkedChannel =
        status?.primaryTrustedChannel?.label.isNotEmpty == true;
    return _buildMenuRow(
      icon: Icons.shield_outlined,
      title: hasLinkedChannel ? 'Аккаунт защищён' : 'Настройки аккаунта',
      subtitle: hasLinkedChannel
          ? 'Основной канал: ${status!.primaryTrustedChannel?.label}'
          : null,
      onTap: () => context.push('/profile/settings'),
    );
  }

  /// «Истории · N» summary row + «Создать» action (spec: item 2) —
  /// replaces the full `StoryRail` avatar strip on the narrow layout.
  /// Browsing isn't lost: tapping the row opens the latest story via
  /// [_openOwnStories], same route the rail's avatar tap used.
  Widget _buildStoriesMenuRow() {
    final count = _userStories.length;
    String? subtitle;
    if (_isLoadingStories && _userStories.isEmpty) {
      subtitle = 'Загружаем…';
    } else if (_storiesUnavailable) {
      subtitle = 'Истории недоступны';
    } else if (count == 0) {
      subtitle = 'Добавьте первую историю';
    }
    return _buildMenuRow(
      icon: Icons.auto_stories_outlined,
      title: count == 0 ? 'Истории' : 'Истории · $count',
      subtitle: subtitle,
      trailing: TextButton.icon(
        onPressed: _createOwnStory,
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: const Icon(Icons.add_rounded, size: 18),
        label: const Text('Создать'),
      ),
      onTap: count == 0 ? null : _openOwnStories,
    );
  }

  /// Same navigation the old `StoryRail`'s add-tile used
  /// (`_buildStoriesRailSection.onCreateStory`), duplicated here rather
  /// than shared because the two call sites diverge in surrounding UI
  /// (rail vs. menu row) and this is the whole body.
  Future<void> _createOwnStory() async {
    final result = await context.push('/stories/create');
    if (!mounted) return;
    if (result == true && _currentUserId != null) {
      _loadStoriesForContext(
        selectedTreeId: context.read<TreeProvider>().selectedTreeId,
        currentUserId: _currentUserId!,
      );
    }
  }

  /// Opens the most recently created own story — mirrors
  /// `_buildStoriesRailSection.onOpenStories`'s «last after ascending
  /// sort» pick, since the quick row has no per-story avatar to tap.
  Future<void> _openOwnStories() async {
    if (_userStories.isEmpty) return;
    final sorted = List<Story>.from(_userStories)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    final story = sorted.last;
    await context.push('/stories/view/${story.treeId}/${story.authorId}');
    if (!mounted) return;
    if (_currentUserId != null) {
      _loadStoriesForContext(
        selectedTreeId: context.read<TreeProvider>().selectedTreeId,
        currentUserId: _currentUserId!,
      );
    }
  }

  /// The merged flat list itself — one bordered surface, hairline
  /// dividers between rows, radius 20 (spec: item 1's «скругление 20+»).
  Widget _buildQuickActionsSection({
    required RodnyaDesignTokens tokens,
    required String? selectedTreeId,
  }) {
    final profileCodeRow =
        _buildProfileCodeRowContent(selectedTreeId: selectedTreeId);

    final rows = <Widget>[
      _buildMenuRow(
        icon: Icons.people_outline,
        title: _graphProfilesLabel(context),
        onTap: () {
          if (selectedTreeId == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_graphSelectionHint(context)),
                action: SnackBarAction(
                  label: 'Выбрать',
                  onPressed: () => context.go('/tree'),
                ),
              ),
            );
          } else {
            context.push('/profile/offline_profiles');
          }
        },
      ),
      if (_selectedTreePerson != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: _buildTreeCardRowContent(context, person: _selectedTreePerson!),
        ),
      if (_accountLinkingStatus != null) _buildAccountSettingsMenuRow(),
      _buildStoriesMenuRow(),
      if (profileCodeRow != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: profileCodeRow,
        ),
    ];

    final divider = Container(
      margin: const EdgeInsets.only(left: 52),
      height: 0.7,
      color: tokens.surfaceLine.withValues(alpha: 0.7),
    );
    final spacedRows = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      spacedRows.add(rows[i]);
      if (i != rows.length - 1) {
        spacedRows.add(divider);
      }
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      decoration: BoxDecoration(
        color: tokens.surfaceStrong,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(children: spacedRows),
      ),
    );
  }
}

/// 40×40 icon action used inside the «Карточка в дереве» row (spec:
/// item 1 — «три компактные иконки-действия (по 40dp)»). A plain
/// `IconButton` even with `VisualDensity.compact` still measures near
/// Material3's default 48dp minimum; tight constraints pin it to 40dp so
/// three of these plus the name column fit a 360dp-wide screen without
/// truncating the person's name.
class _CompactSquareIconButton extends StatelessWidget {
  const _CompactSquareIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 40, height: 40),
      visualDensity: VisualDensity.compact,
    );
  }
}

// _StatBadge / _StatDivider used to live here for the legacy stats row;
// they were only referenced from _buildStatsRow which has been removed
// in the Profile Redesign pass (ProfileHeroStat handles stats now).
