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
    final profileCode = _profileCodeLabel();
    if (profileCode == null) {
      return const SizedBox.shrink();
    }

    final connectionLink =
        _buildProfileConnectionLink(selectedTreeId, profileCode);
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
      child: Row(
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
      ),
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
  Widget _buildTreeCardCompact(
    BuildContext context, {
    required FamilyPerson person,
    required bool isFriendsTree,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final photoCount = person.photoGallery.length;
    final avatarImage = buildAvatarImageProvider(person.primaryPhotoUrl);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        borderRadius: BorderRadius.circular(20),
        plain: true,
        child: Row(
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
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: photoCount == 0 ? 'Фото пока нет' : 'Фото ($photoCount)',
              icon: const Icon(Icons.photo_library_outlined, size: 19),
              onPressed: photoCount == 0
                  ? null
                  : () => _showSelectedTreePersonGallery(person),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'История',
              icon: const Icon(Icons.history_outlined, size: 19),
              onPressed: () => _showSelectedTreePersonHistory(person),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Открыть карточку',
              icon: const Icon(Icons.open_in_new_rounded, size: 19),
              onPressed: () => context.push(
                relativeDetailsRoute(person.id, treeId: person.treeId),
              ),
            ),
          ],
        ),
      ),
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
}

// _StatBadge / _StatDivider used to live here for the legacy stats row;
// they were only referenced from _buildStatsRow which has been removed
// in the Profile Redesign pass (ProfileHeroStat handles stats now).
