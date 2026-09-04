part of 'relative_details_screen.dart';

extension _RelativeDetailsScreenSections on _RelativeDetailsScreenState {
  Widget _buildRelativeStateCard({
    required IconData icon,
    required String title,
    required String message,
    bool showProgress = false,
    List<Widget> actions = const <Widget>[],
  }) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: GlassPanel(
            padding: const EdgeInsets.all(22),
            borderRadius: BorderRadius.circular(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
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

  Widget _buildBody() {
    if (_isLoading) {
      // P0b: без жаргона «досье» — тёплый и короткий лоадер.
      return _buildRelativeStateCard(
        icon: Icons.family_restroom_outlined,
        title: 'Открываем карточку…',
        message: 'Один момент.',
        showProgress: true,
      );
    }
    final errorKind = _errorKind;
    if (errorKind != null) {
      // P0b: честные заглушки — различаем «нет связи» / «не нашли» /
      // «нет доступа», тексты тёплые и без техслов.
      switch (errorKind) {
        case _CardErrorKind.network:
          return _buildRelativeStateCard(
            icon: Icons.cloud_off_outlined,
            title: 'Не получилось загрузить',
            message: 'Проверьте интернет и попробуйте ещё раз.',
            actions: [
              FilledButton.icon(
                onPressed: _loadData,
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
              OutlinedButton.icon(
                onPressed: () => context.pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Назад'),
              ),
            ],
          );
        case _CardErrorKind.notFound:
          return _buildRelativeStateCard(
            icon: Icons.person_search_outlined,
            title: 'Карточка не нашлась',
            message: 'Мы поискали во всех ваших деревьях. '
                'Возможно, эту карточку удалили.',
            actions: [
              OutlinedButton.icon(
                onPressed: () => context.pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Назад'),
              ),
            ],
          );
        case _CardErrorKind.accessDenied:
          return _buildRelativeStateCard(
            icon: Icons.lock_outline,
            title: 'Карточка закрыта',
            message: 'Её владелец ограничил доступ. '
                'Загляните позже или напишите ему.',
            actions: [
              OutlinedButton.icon(
                onPressed: () => context.pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Назад'),
              ),
            ],
          );
      }
    }
    if (_person == null) {
      return _buildRelativeStateCard(
        icon: Icons.person_off_outlined,
        title: 'Карточка не найдена',
        message:
            'Похоже, эта запись уже была удалена или ещё не успела синхронизироваться.',
        actions: [
          FilledButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: const Text('Обновить'),
          ),
          OutlinedButton.icon(
            onPressed: () => context.pop(),
            icon: const Icon(Icons.arrow_back),
            label: const Text('Назад'),
          ),
        ],
      );
    }

    final dossier = _resolveDossier();
    final bool canStartChat = _canStartChatWithPerson();
    final bool canInvite = _canInvitePerson();
    final contactStatus = _getContactStatus();
    final directRelationLabel = _getDirectRelationLabel();
    final galleryEntries = _person!.photoGallery;

    final person = _person!;
    final isDeceased = !person.isAlive || person.deathDate != null;
    final fullName =
        dossier.displayName.isNotEmpty ? dossier.displayName : person.name;
    final loc = _composeRelativeLocation(dossier);
    final years = _composeYears(person);

    final headerStatus = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: contactStatus.color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: contactStatus.color.withValues(alpha: 0.22),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(contactStatus.icon, size: 13, color: contactStatus.color),
              const SizedBox(width: 5),
              Text(
                contactStatus.label,
                style: AppTheme.sans(
                  color: contactStatus.color,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 5),
        Text(
          contactStatus.description,
          style: AppTheme.sans(
            color: Theme.of(context)
                .colorScheme
                .onSurfaceVariant
                .withValues(alpha: 0.85),
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0,
            height: 1.35,
          ),
        ),
      ],
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildReadFirstHeader(
                person: person,
                dossier: dossier,
                fullName: fullName,
                isDeceased: isDeceased,
                directRelationLabel: directRelationLabel,
                location: loc,
                deceasedYears: years,
                bio: dossier.bio.trim().isNotEmpty
                    ? dossier.bio.trim()
                    : (person.bio?.trim().isNotEmpty == true
                        ? person.bio!.trim()
                        : null),
                canStartChat: canStartChat,
                canInvite: canInvite,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: headerStatus,
              ),
              // «Основная информация» — key structured facts, right under
              // the header (§3.2.1, revised from C1: these are the card's
              // skeleton, kept on view). Self-hides if nothing is filled.
              _buildBasicInfoSection(),
              // «Семейные истории» — read-first article (§3.1 order: шапка →
              // Основная информация → биография → … → Семья). Empty-CTA
              // suppressed: the header's primary CTA already offers it.
              if (_person != null)
                ProfileBiographySection(
                  personId: person.id,
                  fullName: fullName,
                  relation: directRelationLabel,
                  gender: person.gender.name,
                  canEdit: _canDirectEditProfile(),
                  showEmptyCta: false,
                  authorNames: _authorNamesMap(),
                ),
              // Phase 3.4 chunk 5: conflict header-banner.
              // Showcase'ит «у этого человека N расхождений с
              // другими ветками» с CTA «Посмотреть и решить» →
              // открывает reusable IdentityConflictsSheet.
              if (_personConflicts.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: IdentityConflictsHeaderBanner(
                    count: _personConflicts.length,
                    onTap: _showPersonConflictsSheet,
                  ),
                ),
              if (_duplicateSuggestions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 18, 12, 0),
                  child: _buildDuplicateSuggestionBanner(),
                ),
              // §3.1 read-first: «Семья» sits right under the biography
              // (only alerts between). «Связь», заметка, галерея,
              // история-audit … follow below — nothing removed/hidden.
              if (_buildDirectFamilyRows().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _buildFamilySection(),
                ),
              // P1a: мягкое приглашение дозаполнить анкету (только на
              // редактируемой карточке; исчезает при полной анкете).
              // Паддинг внутри builder'а — скрытая плашка стоит 0dp.
              _buildCompletenessNudge(dossier, galleryEntries),
              if (_kinshipSectionHasContent()) _buildKinshipSection(),
              // «О человеке» (structured facts) moved to the «Основная
              // информация» ⋯-screen (§3.2.1) — keeps the main card
              // read-first.
              if (dossier.familySummary.trim().isNotEmpty ||
                  dossier.aboutFamily.trim().isNotEmpty)
                _buildRelativeFamilyNoteSection(dossier),
              if (galleryEntries.isNotEmpty || _canEditOrDelete())
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _buildGallerySection(galleryEntries),
                ),
              if (_person != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _buildHistorySection(),
                ),
              if (person.userId != null && person.userId!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _buildLinkedProfileSection(),
                ),
              if (_graphTreeService != null &&
                  (person.id != _currentUserPersonId || _canEditOrDelete()))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: _buildRelationToolsSection(),
                ),
              // «Кто видит карточку» (§3.2.2 card visibility + 100-year
              // rule) moved to its own ⋯-screen (ProfileVisibilityScreen)
              // — no longer inline on the main card.
              // Phase 3.4 chunk 4 (PHASE-3.4-UI-PROPOSAL §2.4):
              // sensitive contacts section с явным «Видно тебе»
              // badge. Owner-only-всегда (даже edit grant не
              // открывает). Показываем только когда viewer === self
              // (т.е. это карточка собственного аккаунта juzer'а),
              // потому что phone/email лежат в его UserProfile.
              // Anonymous person'ы (userId == null) не имеют
              // contacts payload'а в текущей схеме — sensitive
              // attribute поверх PersonAttribute(field:'contacts')
              // возможен, но deferred (TODO когда появится UI для
              // anonymous person contact entry).
              if (_isViewerOwnPerson(person))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: SensitiveContactsSection(
                    isOwner: true,
                    phoneNumber: _userProfile?.phoneNumber,
                    email: _userProfile?.email,
                    addressLine: _composeAddressLine(_userProfile),
                    onEdit: () => context.push('/profile/edit'),
                  ),
                ),
              // Profile Redesign: prominent «Удалить из дерева»
              // button at the tail of the card. Only shown when the
              // viewer can edit (mirrors the appbar trash icon's
              // existing gate). The bottom button matches the design
              // spec better than a tiny icon — destructive actions
              // shouldn't hide.
              if (_canDirectEditProfile())
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                  child: _DeleteRelativeButton(onTap: _deleteRelative),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Viewer §3.1: read-first header ─────────────────────────────────────────

  // Replaces the cover-style ProfileHeroCard on this screen with the
  // read-first header: centred 120px avatar, name (memorial framing when
  // deceased), «relation · age|years», preserved bio/location, a primary
  // «Добавить историю/воспоминание» CTA (editor-gated → article editor),
  // plus Написать/Пригласить as secondary CTAs. Management actions live in
  // the AppBar ⋯ menu; structured-field edit stays as the AppBar ✏️.
  Widget _buildReadFirstHeader({
    required FamilyPerson person,
    required PersonDossier dossier,
    required String fullName,
    required bool isDeceased,
    required String? directRelationLabel,
    required String? location,
    required String? deceasedYears,
    required String? bio,
    required bool canStartChat,
    required bool canInvite,
  }) {
    final theme = Theme.of(context);
    final photoUrl = normalizePhotoUrl(dossier.photoUrl);
    final initials = _avatarInitials(fullName);
    final subtitle = _composeRelationLine(
      directRelationLabel,
      person,
      isDeceased,
      deceasedYears,
    );
    final canEditStory = _canDirectEditProfile();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildHeaderAvatar(photoUrl, initials),
          const SizedBox(height: 10),
          Text(
            isDeceased ? '† Память: $fullName' : fullName,
            key: const Key('profile-name'),
            textAlign: TextAlign.center,
            style: AppTheme.serif(
              color: theme.colorScheme.onSurface,
              fontSize: 23,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              height: 1.2,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 5),
            Text(
              subtitle,
              key: const Key('profile-relation-line'),
              textAlign: TextAlign.center,
              style: AppTheme.sans(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
          if (location != null && location.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              location,
              textAlign: TextAlign.center,
              style: AppTheme.sans(
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0,
              ),
            ),
          ],
          if (bio != null && bio.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              bio.trim(),
              textAlign: TextAlign.center,
              style: AppTheme.serif(
                color: theme.colorScheme.onSurfaceVariant,
                fontSize: 14.5,
                fontWeight: FontWeight.w400,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Действия — один ряд компактных плиток (как в профиле Telegram),
          // а не столбик кнопок во всю ширину: три-четыре кнопки съедали
          // 150–200dp первого экрана. Ключи и подписи сохранены.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _HeroActionTile(
                    key: const Key('profile-ask-story'),
                    icon: Icons.question_answer_outlined,
                    label: 'Спросить историю',
                    primary: true,
                    onTap: () => _askFamilyStory(
                      name: fullName,
                      relation: directRelationLabel,
                      gender: person.gender.name,
                    ),
                  ),
                ),
                if (canEditStory) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HeroActionTile(
                      key: const Key('profile-add-story'),
                      icon: Icons.edit_outlined,
                      label: isDeceased
                          ? 'Добавить воспоминание'
                          : 'Добавить историю',
                      onTap: () => _openBiographyEditor(
                        name: fullName,
                        relation: directRelationLabel,
                        gender: person.gender.name,
                      ),
                    ),
                  ),
                ],
                if (canStartChat) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HeroActionTile(
                      key: const Key('profile-write'),
                      icon: Icons.message_outlined,
                      label: 'Написать',
                      onTap: _openChatWithPerson,
                    ),
                  ),
                ],
                if (canInvite) ...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: _HeroActionTile(
                      key: const Key('profile-invite'),
                      icon: Icons.person_add_alt_1_outlined,
                      label: _isGeneratingLink ? 'Готовим…' : 'Пригласить в Родню',
                      onTap: _isGeneratingLink
                          ? null
                          : _generateAndShareInviteLink,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderAvatar(String? photoUrl, String initials) {
    final theme = Theme.of(context);
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        border: Border.all(color: theme.colorScheme.surface, width: 3),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            spreadRadius: -6,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipOval(
        child: (photoUrl != null && photoUrl.isNotEmpty)
            ? CachedNetworkImage(
                imageUrl: photoUrl,
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                // M2: декод под 120dp-аватар.
                memCacheWidth: decodeCacheWidth(context, 120),
                placeholder: (_, __) => _avatarFallback(initials),
                errorWidget: (_, __, ___) => _avatarFallback(initials),
              )
            : _avatarFallback(initials),
      ),
    );
  }

  Widget _avatarFallback(String initials) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        initials,
        style: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  String _avatarInitials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts[0].substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
  }

  String? _composeRelationLine(
    String? relation,
    FamilyPerson person,
    bool isDeceased,
    String? deceasedYears,
  ) {
    final parts = <String>[];
    final rel = relation?.trim();
    if (rel != null && rel.isNotEmpty) parts.add(rel);
    if (isDeceased) {
      if (deceasedYears != null && deceasedYears.trim().isNotEmpty) {
        parts.add(deceasedYears.trim());
      }
    } else {
      final age = _composeAge(person);
      if (age != null) parts.add(age);
    }
    if (parts.isEmpty) return null;
    return parts.join(' · ');
  }

  String? _composeAge(FamilyPerson person) {
    final birth = person.birthDate;
    if (birth == null) return null;
    final now = DateTime.now();
    // F5: «знаю только год» — день/месяц фейковые (01.01), точный возраст
    // не посчитать. Считаем по годам и честно показываем «~78 лет».
    if (person.birthDateIsYearOnly) {
      final age = now.year - birth.year;
      if (age < 0 || age > 130) return null;
      return '~$age ${_pluralYears(age)}';
    }
    var age = now.year - birth.year;
    if (now.month < birth.month ||
        (now.month == birth.month && now.day < birth.day)) {
      age--;
    }
    if (age < 0 || age > 130) return null;
    return '$age ${_pluralYears(age)}';
  }

  String _pluralYears(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'год';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'года';
    return 'лет';
  }

  void _openBiographyEditor({
    required String name,
    String? relation,
    String? gender,
    FamilyStoryQuestion? initialQuestion,
  }) {
    final person = _person;
    if (person == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileArticleEditorScreen(
          personId: person.id,
          personName: name,
          personRelation: relation,
          personGender: gender,
          initialStoryTitle: initialQuestion?.title,
          initialStoryQuestion: initialQuestion?.question,
          initialStoryHint: initialQuestion == null
              ? null
              : buildFamilyStoryEditorHint(initialQuestion),
        ),
      ),
    );
  }

  Future<void> _askFamilyStory({
    required String name,
    String? relation,
    String? gender,
  }) async {
    final action = await showFamilyStoryQuestionsSheet(
      context,
      personName: name,
      relation: relation,
    );
    if (action == null || !mounted) return;
    switch (action.type) {
      case FamilyStoryQuestionActionType.share:
        await _shareFamilyStoryQuestion(
          question: action.question,
          name: name,
          relation: relation,
          gender: gender,
        );
        break;
      case FamilyStoryQuestionActionType.saveAnswer:
        _openBiographyEditor(
          name: name,
          relation: relation,
          gender: gender,
          initialQuestion: action.question,
        );
        break;
    }
  }

  Future<void> _shareFamilyStoryQuestion({
    required FamilyStoryQuestion question,
    required String name,
    String? relation,
    String? gender,
  }) async {
    final message = buildFamilyStoryShareMessage(
      question: question,
      personName: name,
      relation: relation,
    );
    try {
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          text: message,
          subject: 'Вопрос для семейной истории',
          sharePositionOrigin:
              box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Вопрос готов к отправке.'),
          action: SnackBarAction(
            label: 'Сохранить ответ',
            onPressed: () => _openBiographyEditor(
              name: name,
              relation: relation,
              gender: gender,
              initialQuestion: question,
            ),
          ),
        ),
      );
    } catch (error) {
      debugPrint('Не удалось открыть отправку семейного вопроса: $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Не удалось открыть отправку.'),
          action: SnackBarAction(
            label: 'Сохранить ответ',
            onPressed: () => _openBiographyEditor(
              name: name,
              relation: relation,
              gender: gender,
              initialQuestion: question,
            ),
          ),
        ),
      );
    }
  }

  // AppBar ⋯ overflow — the §3.2 card menu. Each item maps to an existing
  // action or a dedicated screen, and is shown only when it has a
  // destination. Deferred: 📜 История изменений (needs a backend edit-
  // history endpoint — flagged as a separate заход) and 👥 Соавторы
  // (sub-chunk 2d). 🔗 Поделиться (browse-token, §3.2.7) isn't wired in
  // this context yet (only invite-to-family exists — that's the header CTA).
  Future<void> _openActionsMenu() async {
    final person = _person;
    if (person == null) return;
    final tiles = <Widget>[];
    // «Основная информация» is now a prominent on-card section (revised
    // from C1) — no longer a ⋯ entry.
    if (_canSuggestProfileEdits()) {
      tiles.add(_actionTile(
        keyValue: 'action-suggest-edits',
        icon: Icons.edit_note_outlined,
        label: 'Предложить правку',
        onTap: _suggestProfileChanges,
      ));
    }
    // §3.2.2 card visibility (radio + 100-year rule) — its own screen,
    // replacing the old inline VisibilityToggleSection.
    if (person.identityId != null && person.identityId!.isNotEmpty) {
      tiles.add(_actionTile(
        keyValue: 'action-visibility',
        icon: Icons.visibility_outlined,
        label: 'Кто видит карточку',
        onTap: _openVisibilityScreen,
      ));
    }
    // Per-field visibility (name / photo / dates …) — kept as a separate
    // entry so nothing is lost.
    if (_identityService != null && _canEditOrDelete()) {
      tiles.add(_actionTile(
        keyValue: 'action-privacy-fields',
        icon: Icons.lock_outline_rounded,
        label: _isUpdatingPrivacy ? 'Сохраняем…' : 'Видимость по полям',
        onTap: _showPrivacySettings,
      ));
    }
    // §3.2.4 article change log (read-access → any viewer). The ARTICLE
    // history (/article/history), not the broader inline tree-history.
    tiles.add(_actionTile(
      keyValue: 'action-history',
      icon: Icons.history_rounded,
      label: 'История изменений',
      onTap: _openArticleHistory,
    ));
    tiles.add(_actionTile(
      keyValue: 'action-voice',
      icon: Icons.graphic_eq_rounded,
      label: 'Голосовые записи',
      onTap: _openVoiceRecordings,
    ));
    tiles.add(_actionTile(
      keyValue: 'action-photos',
      icon: Icons.photo_library_outlined,
      label: 'Все фото',
      onTap: _openAllPhotos,
    ));
    if (_currentTreeId != null) {
      tiles.add(_actionTile(
        keyValue: 'action-open-tree',
        icon: Icons.account_tree_outlined,
        label: 'Открыть в дереве',
        onTap: _openInTree,
      ));
    }
    if (_identityService != null &&
        _currentTreeId != null &&
        person.userId != _authService.currentUserId) {
      tiles.add(_actionTile(
        keyValue: 'action-claim',
        icon: Icons.verified_user_outlined,
        label: _isUpdatingIdentity ? 'Подтверждение…' : 'Это моя карточка',
        onTap: _requestIdentityClaim,
      ));
    }
    if (_canUnlinkUser()) {
      tiles.add(_actionTile(
        keyValue: 'action-unlink',
        icon: Icons.person_remove_outlined,
        label: 'Отвязать пользователя',
        onTap: _unlinkUser,
      ));
    }
    if (_canDirectEditProfile()) {
      tiles.add(_actionTile(
        keyValue: 'action-delete',
        icon: Icons.delete_outline,
        label: 'Удалить из дерева',
        destructive: true,
        onTap: _deleteRelative,
      ));
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: tiles,
          ),
        ),
      ),
    );
  }

  // userId → display name, from the people on this tree — for «кто записал»
  // (Голосовые) and «Соавторы» (2d).
  Map<String, String> _authorNamesMap() {
    final map = <String, String>{};
    for (final person in _treePeople) {
      final uid = person.userId;
      if (uid != null && uid.isNotEmpty && person.name.trim().isNotEmpty) {
        map[uid] = person.name.trim();
      }
    }
    return map;
  }

  void _openVoiceRecordings() {
    final person = _person;
    if (person == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileVoiceRecordingsScreen(
          personId: person.id,
          personName: person.name,
          authorNames: _authorNamesMap(),
        ),
      ),
    );
  }

  void _openArticleHistory() {
    final person = _person;
    if (person == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileArticleHistoryScreen(
          personId: person.id,
          personName: person.name,
          actorNames: _authorNamesMap(),
        ),
      ),
    );
  }

  void _openAllPhotos() {
    final person = _person;
    if (person == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileAllPhotosScreen(
          personId: person.id,
          personName: person.name,
        ),
      ),
    );
  }

  void _openInTree() {
    final treeId = _currentTreeId;
    if (treeId == null) return;
    context.go('/tree/view/$treeId');
  }

  void _openVisibilityScreen() {
    final person = _person;
    if (person == null ||
        person.identityId == null ||
        person.identityId!.isEmpty) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileVisibilityScreen(
          graphPersonId: person.identityId!,
          viewerUserId: _authService.currentUserId ?? '',
          familyTreeService: _familyService,
        ),
      ),
    );
  }

  // The person's dossier (linked profile → tree person fallback). Shared by
  // the main card and the «Основная информация» screen.
  PersonDossier _resolveDossier() {
    return _dossier ??
        (_userProfile != null
            ? PersonDossier.fromProfile(_userProfile!, treePerson: _person)
            : PersonDossier.fromPerson(
                _person!,
                canEditFamilyFields: _canEditOrDelete(),
              ));
  }

  String? _basicGenderLabel(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'Мужской';
      case Gender.female:
        return 'Женский';
      case Gender.other:
        return 'Другой';
      case Gender.unknown:
        return null;
    }
  }

  // §3.2.1 read-first facts section, on the card under the header. Shows
  // only filled fields, grouped (паспорт/места → отношение/пол → био-
  // факты). NO name (the header already shows it) and the birth DATE (not
  // the header's age). Edit ✏️ (gated) → existing structured editor.
  // Self-hides when nothing is filled.
  Widget _buildBasicInfoSection() {
    final person = _person;
    if (person == null) return const SizedBox.shrink();
    final d = _resolveDossier();

    final passport = <_BasicInfoRow>[];
    void addPassport(String label, String? value, {bool memorial = false}) {
      final v = value?.trim() ?? '';
      if (v.isNotEmpty) {
        passport.add(_BasicInfoRow(label, v, memorial: memorial));
      }
    }

    addPassport('Девичья фамилия', d.maidenName);
    if (person.birthDate != null) {
      // F5: «знаю только год» → «1888 год» вместо фейкового «1 января 1888».
      addPassport(
        person.birthDateIsYearOnly ? 'Год рождения' : 'Дата рождения',
        person.birthDateIsYearOnly
            ? '${person.birthDate!.year}'
            : _formatRussianDate(person.birthDate!),
      );
    }
    addPassport('Место рождения', d.birthPlace);
    addPassport('Родом из', d.hometown);
    if (person.deathDate != null) {
      addPassport(
        person.deathDateIsYearOnly ? 'Год смерти' : 'Дата смерти',
        person.deathDateIsYearOnly
            ? '${person.deathDate!.year}'
            : _formatRussianDate(person.deathDate!),
        memorial: true,
      );
    }
    addPassport('Место смерти', person.deathPlace);

    final who = <_BasicInfoRow>[];
    final relation = _getDirectRelationLabel();
    if (relation != null && relation.trim().isNotEmpty) {
      who.add(_BasicInfoRow('Отношение', relation.trim()));
    }
    final gender = _basicGenderLabel(person.gender);
    if (gender != null) who.add(_BasicInfoRow('Пол', gender));

    final about = <_BasicInfoRow>[];
    void addAbout(String label, String value) {
      if (value.trim().isNotEmpty) {
        about.add(_BasicInfoRow(label, value.trim()));
      }
    }

    addAbout('Образование', d.education);
    addAbout('Работа', d.work);
    addAbout('Языки', d.languages);
    addAbout('Интересы', d.interests);

    final groups = [passport, who, about].where((g) => g.isNotEmpty).toList();
    if (groups.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Основная информация',
                key: const Key('basic-info-title'),
                style: AppTheme.serif(
                  color: theme.colorScheme.onSurface,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const Spacer(),
              if (_canDirectEditProfile())
                IconButton(
                  key: const Key('basic-info-edit'),
                  tooltip: 'Редактировать',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: _editRelative,
                ),
            ],
          ),
          const SizedBox(height: 4),
          for (var gi = 0; gi < groups.length; gi++) ...[
            if (gi > 0) const SizedBox(height: 10),
            for (final row in groups[gi]) _basicInfoRow(theme, row),
          ],
        ],
      ),
    );
  }

  Widget _basicInfoRow(ThemeData theme, _BasicInfoRow row) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              row.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              row.value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'Lora',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (row.memorial) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '† Память',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _actionTile({
    required String keyValue,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool destructive = false,
  }) {
    final color = destructive ? Colors.redAccent : null;
    return ListTile(
      key: Key(keyValue),
      leading: Icon(icon, color: color),
      title: Text(label, style: color == null ? null : TextStyle(color: color)),
      onTap: () {
        Navigator.of(context).pop();
        onTap();
      },
    );
  }

  // ── Profile Redesign helpers (relative card flavour) ───────────────────────

  /// P1a: мягкий индикатор полноты анкеты + одна подсказка. Это
  /// приглашение, не задача: без красноты и процентов-укоров. Считаем 4
  /// базовых пункта (фото · дата рождения · место · биография); подсказка
  /// предлагает первый незаполненный по приоритету и по тапу открывает
  /// нужную форму. Полностью заполненная анкета — плашки нет.
  Widget _buildCompletenessNudge(
    PersonDossier dossier,
    List<Map<String, dynamic>> galleryEntries,
  ) {
    final person = _person;
    if (person == null || !_canDirectEditProfile()) {
      return const SizedBox.shrink();
    }

    final hasPhoto = (person.photoUrl?.trim().isNotEmpty ?? false) ||
        galleryEntries.isNotEmpty;
    final hasBirthDate = person.birthDate != null;
    final hasPlace = _composeRelativeLocation(dossier) != null;
    final hasBio = person.bio?.trim().isNotEmpty ?? false;

    final filled = [hasPhoto, hasBirthDate, hasPlace, hasBio]
        .where((value) => value)
        .length;
    const total = 4;
    if (filled >= total) {
      return const SizedBox.shrink();
    }

    // Приоритет подсказки: фото → даты → места → биография.
    final String hint;
    final VoidCallback onTap;
    if (!hasPhoto) {
      hint = 'Добавьте фото';
      onTap = _pickAndUploadGalleryImage;
    } else if (!hasBirthDate) {
      hint = 'Добавьте дату рождения';
      onTap = _editRelative;
    } else if (!hasPlace) {
      hint = 'Укажите место';
      onTap = _editRelative;
    } else {
      hint = 'Расскажите о человеке';
      onTap = _editRelative;
    }

    final tokens = AppTheme.tokensOf(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Material(
        color: tokens.accentSoft.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          key: const Key('relative-completeness-nudge'),
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 18,
                  color: tokens.accent,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Заполнено $filled из $total · $hint',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.sans(
                      color: tokens.ink,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: tokens.inkMuted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _composeRelativeLocation(PersonDossier d) {
    final city = d.city?.trim() ?? '';
    final country = d.country?.trim() ?? '';
    final birthPlace = d.birthPlace?.trim() ?? '';
    if (city.isNotEmpty && country.isNotEmpty) return '$city · $country';
    if (city.isNotEmpty) return city;
    if (country.isNotEmpty) return country;
    if (birthPlace.isNotEmpty) return birthPlace;
    return null;
  }

  String? _composeYears(FamilyPerson person) {
    final birth = person.birthDate?.year;
    final death = person.deathDate?.year;
    if (birth == null && death == null) return null;
    if (birth != null && death != null) return '$birth — $death';
    if (birth != null) return '$birth г.';
    return '— $death';
  }

  bool _kinshipSectionHasContent() {
    final descriptor = _viewerDescriptor;
    if (descriptor == null) return false;
    if (_person?.id == _currentUserPersonId) return false;
    final label = (descriptor.primaryRelationLabel ?? '').trim();
    final summary = (descriptor.pathSummary ?? '').trim();
    return label.isNotEmpty || summary.isNotEmpty;
  }

  Widget _buildKinshipSection() {
    final descriptor = _viewerDescriptor!;
    final label = (descriptor.primaryRelationLabel ?? '').trim();
    final summary = (descriptor.pathSummary ?? '').trim();
    final modifier =
        descriptor.isBlood ? 'кровное родство' : 'родственная связь';
    final altCount = descriptor.alternatePathCount;
    final altSuffix = altCount > 0
        ? altCount == 1
            ? ' · ещё 1 путь'
            : ' · ещё $altCount пути'
        : '';

    final rows = <Widget>[];
    if (label.isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.diversity_3_outlined,
        label: 'Родство',
        value: '$label · $modifier$altSuffix',
        isFirst: rows.isEmpty,
      ));
    }
    if (summary.isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.route_outlined,
        label: 'Путь',
        value: summary,
        isFirst: rows.isEmpty,
        onTap: _showRelationPathSheet,
      ));
    }
    if (rows.isNotEmpty) {
      final last = rows.removeLast() as InfoRow;
      rows.add(InfoRow(
        icon: last.icon,
        label: last.label,
        value: last.value,
        isFirst: last.isFirst,
        isLast: true,
        onTap: last.onTap,
      ));
    }
    return ProfileSection(title: 'Связь', children: rows);
  }

  Widget _buildRelativeFamilyNoteSection(PersonDossier d) {
    final summary = d.familySummary.trim();
    final about = d.aboutFamily.trim();
    final rows = <Widget>[];
    if (summary.isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.notes_outlined,
        label: 'Для семьи',
        value: summary,
        warm: true,
        isFirst: rows.isEmpty,
      ));
    }
    if (about.isNotEmpty) {
      rows.add(InfoRow(
        icon: Icons.family_restroom_outlined,
        label: 'О семье',
        value: about,
        warm: true,
        isFirst: rows.isEmpty,
      ));
    }
    if (rows.isNotEmpty) {
      final last = rows.removeLast() as InfoRow;
      rows.add(InfoRow(
        icon: last.icon,
        label: last.label,
        value: last.value,
        warm: last.warm,
        isFirst: last.isFirst,
        isLast: true,
      ));
    }
    return ProfileSection(title: 'Заметка для семьи', children: rows);
  }

  String _formatRussianDate(DateTime d) {
    const months = [
      'января',
      'февраля',
      'марта',
      'апреля',
      'мая',
      'июня',
      'июля',
      'августа',
      'сентября',
      'октября',
      'ноября',
      'декабря',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  Widget _buildDuplicateSuggestionBanner() {
    final theme = Theme.of(context);
    final suggestion = _duplicateSuggestions.first;
    final otherPerson = suggestion.otherPersonFor(_person!.id);
    final extraCount = _duplicateSuggestions.length - 1;

    return GlassPanel(
      padding: const EdgeInsets.all(16),
      borderRadius: BorderRadius.circular(24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.person_search_outlined,
              color: theme.colorScheme.onTertiaryContainer,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Возможное совпадение',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  extraCount > 0
                      ? 'Похоже, эта карточка может совпадать с ${otherPerson.displayName} и ещё $extraCount.'
                      : 'Похоже, эта карточка может совпадать с ${otherPerson.displayName}.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: suggestion.reasons
                      .take(3)
                      .map(
                        (reason) => Chip(
                          label: Text(reason),
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                      .toList(growable: false),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => _showDuplicateSuggestionSheet(suggestion),
                    icon: const Icon(Icons.compare_arrows_outlined),
                    label: const Text('Сравнить'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDuplicateSuggestionSheet(PersonDuplicateSuggestion suggestion) {
    if (_person == null || !suggestion.involves(_person!.id)) {
      return;
    }
    final currentPerson = suggestion.personA.id == _person!.id
        ? suggestion.personA
        : suggestion.personB;
    final otherPerson = suggestion.otherPersonFor(_person!.id);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Сравнение карточек',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Перед объединением семьи стоит проверить, не описывают ли эти карточки одного человека.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                _buildDuplicatePersonSummary('Эта карточка', currentPerson),
                const SizedBox(height: 12),
                _buildDuplicatePersonSummary('Похожая карточка', otherPerson),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: suggestion.reasons
                      .map(
                        (reason) => Chip(
                          avatar: const Icon(Icons.check, size: 16),
                          label: Text(reason),
                          visualDensity: VisualDensity.compact,
                        ),
                      )
                      .toList(growable: false),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDuplicatePersonSummary(String title, FamilyPerson person) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            person.displayName,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(_formatDuplicatePersonFacts(person)),
        ],
      ),
    );
  }

  String _formatDuplicatePersonFacts(FamilyPerson person) {
    final facts = <String>[
      _formatDuplicateGender(person.gender),
      person.birthDate != null
          // F5: для yearOnly — «р. 1888» вместо фейкового 01.01.1888.
          ? (person.birthDateIsYearOnly
              ? 'р. ${person.birthDate!.year}'
              : DateFormat('dd.MM.yyyy').format(person.birthDate!))
          : 'Дата рождения не указана',
    ];
    final birthPlace = person.birthPlace?.trim();
    if (birthPlace != null && birthPlace.isNotEmpty) {
      facts.add(birthPlace);
    }
    return facts.join(' • ');
  }

  String _formatDuplicateGender(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'Мужчина';
      case Gender.female:
        return 'Женщина';
      case Gender.other:
        return 'Другой пол';
      case Gender.unknown:
        return 'Пол не указан';
    }
  }

  Widget _buildInfoSection(String title, List<Widget> children) {
    // Redesign-aligned section frame for the relative card's tail
    // sections (Фотографии / История изменений / Связанный профиль /
    // Связи и родство / Семья). Uppercase Manrope title + warm
    // tinted card matches the hero / facts pattern; the children get
    // their own internal padding via the inner Padding wrapper.
    return ProfileSection(
      title: title,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildGallerySection(List<Map<String, dynamic>> galleryEntries) {
    final canManageGallery = _canEditOrDelete();
    // Пустое состояние — одной короткой строкой рядом с кнопкой: раньше под
    // ней шла ещё карточка-подсказка о том же, а мотивация «добавьте фото»
    // и так есть в плашке заполненности выше.
    final countLabel = galleryEntries.isEmpty
        ? 'Фотографий пока нет'
        : galleryEntries.length == 1
            ? '1 фото'
            : '${galleryEntries.length} фото';

    return _buildInfoSection('Фотографии', [
      Row(
        children: [
          Expanded(
            child: Text(
              countLabel,
              style: TextStyle(color: Colors.grey[700]),
            ),
          ),
          if (_isUpdatingGallery)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else if (canManageGallery)
            OutlinedButton.icon(
              onPressed: _pickAndUploadGalleryImage,
              icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
              label: const Text('Добавить фото'),
            ),
        ],
      ),
      if (galleryEntries.isNotEmpty) const SizedBox(height: 10),
      if (galleryEntries.isNotEmpty)
        SizedBox(
          height: 146,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: galleryEntries.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final media = galleryEntries[index];
              final mediaUrl = media['url']?.toString() ?? '';
              final normalizedMediaUrl = normalizePhotoUrl(mediaUrl);
              final isPrimary = media['isPrimary'] == true;

              return InkWell(
                onTap: normalizedMediaUrl == null
                    ? null
                    : () => _openGalleryViewer(
                          galleryEntries,
                          initialIndex: index,
                        ),
                borderRadius: BorderRadius.circular(18),
                child: SizedBox(
                  width: 116,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: isPrimary
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context)
                                          .colorScheme
                                          .outlineVariant,
                                  width: isPrimary ? 2 : 1,
                                ),
                                color: Theme.of(context)
                                    .colorScheme
                                    .surfaceContainerLowest,
                              ),
                              clipBehavior: Clip.antiAlias,
                              child: normalizedMediaUrl == null
                                  ? Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.grey[600],
                                      ),
                                    )
                                  : CachedNetworkImage(
                                      imageUrl: normalizedMediaUrl,
                                      fit: BoxFit.cover,
                                      width: double.infinity,
                                      // M2: тайл галереи карточки — 116dp.
                                      memCacheWidth:
                                          decodeCacheWidth(context, 116),
                                      errorWidget: (context, url, error) =>
                                          Center(
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          color: Colors.grey[600],
                                        ),
                                      ),
                                    ),
                            ),
                            Positioned(
                              left: 8,
                              top: 8,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.58),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  child: Text(
                                    isPrimary ? 'Основное' : 'Фото',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            if (canManageGallery)
                              Positioned(
                                right: 4,
                                top: 4,
                                child: PopupMenuButton<_RelativeGalleryAction>(
                                  tooltip: 'Действия с фото',
                                  onSelected: (action) {
                                    switch (action) {
                                      case _RelativeGalleryAction.makePrimary:
                                        _setPrimaryGalleryMedia(media);
                                        break;
                                      case _RelativeGalleryAction.delete:
                                        _deleteGalleryMedia(media);
                                        break;
                                    }
                                  },
                                  itemBuilder: (context) => [
                                    if (!isPrimary)
                                      const PopupMenuItem<
                                          _RelativeGalleryAction>(
                                        value:
                                            _RelativeGalleryAction.makePrimary,
                                        child: Text('Сделать основным'),
                                      ),
                                    const PopupMenuItem<_RelativeGalleryAction>(
                                      value: _RelativeGalleryAction.delete,
                                      child: Text('Удалить фото'),
                                    ),
                                  ],
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color:
                                          Colors.black.withValues(alpha: 0.55),
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(6),
                                    child: const Icon(
                                      Icons.more_vert,
                                      size: 16,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isPrimary ? 'Используется в дереве' : 'Дополнительное',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.grey[800],
                          fontSize: 12,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
    ]);
  }

  Widget _buildHistorySection() {
    final latestRecord =
        _historyRecords.isNotEmpty ? _historyRecords.first : null;
    final summaryLabel = _historyRecords.isEmpty
        ? 'Журнал пока пуст'
        : _historyRecords.length == 1
            ? '1 запись'
            : '${_historyRecords.length} записей';

    return _buildInfoSection('История изменений', [
      if (_isLoadingHistory)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Center(child: CircularProgressIndicator()),
        )
      else
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .primaryContainer
                          .withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      latestRecord == null
                          ? Icons.history_outlined
                          : _historyIcon(latestRecord),
                      size: 18,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          latestRecord == null
                              ? 'Журнал ещё пуст.'
                              : _historyTitle(latestRecord),
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          latestRecord == null
                              ? 'Как только семья добавит правку, фото или новую связь, здесь появится история изменений.'
                              : _historySubtitle(latestRecord),
                          style: TextStyle(
                            color: Colors.grey[700],
                            fontSize: 12,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.summarize_outlined, size: 16),
                    label: Text(summaryLabel),
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _openHistorySheet,
                    icon: const Icon(Icons.history_outlined, size: 18),
                    label: const Text('Открыть историю'),
                  ),
                ],
              ),
            ],
          ),
        ),
    ]);
  }

  Widget _buildLinkedProfileSection() {
    final linkedUserId = _person?.userId;
    if (linkedUserId == null || linkedUserId.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildInfoSection('Связанный профиль', [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.72),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.link_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _userProfile?.displayName ?? _person!.displayName,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Карточка связана с аккаунтом в Родне. Фото, имя и базовые данные синхронизируются из профиля.',
                        style: TextStyle(
                          color: Colors.grey[700],
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  avatar: const Icon(Icons.person_outline, size: 16),
                  label: Text(
                    _person?.id == _currentUserPersonId
                        ? 'Это ваш профиль'
                        : 'Профиль подтвержден',
                  ),
                ),
                if (_userProfile?.city != null || _userProfile?.country != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.location_on_outlined, size: 16),
                    label: Text(
                      _buildPlaceLabel(
                            _userProfile?.city,
                            _userProfile?.country,
                          ) ??
                          'Локация не указана',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _buildRelationToolsSection() {
    final personWarnings = _graphWarningsForCurrentPerson();
    return _buildInfoSection('Связи и родство', [
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Проверка работает поверх нового графа дерева: можно посмотреть цепочку родства и быстро исправить прямые связи.',
              style: TextStyle(
                color: Colors.grey[800],
                height: 1.35,
              ),
            ),
            if (personWarnings.isNotEmpty) ...[
              const SizedBox(height: 12),
              ...personWarnings.map(
                (warning) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildGraphWarningCard(warning),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_person != null && _currentTreeId != null)
                  FilledButton.icon(
                    onPressed: _showQuickAddRelativeSheet,
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('Добавить родственника'),
                  ),
                if (_person!.id != _currentUserPersonId)
                  FilledButton.tonalIcon(
                    onPressed: _showRelationPathSheet,
                    icon: const Icon(Icons.route_outlined, size: 18),
                    label: const Text('Путь родства'),
                  ),
                if (_hasAdditionalParentSets())
                  OutlinedButton.icon(
                    onPressed: _showOtherParentsSheet,
                    icon: const Icon(Icons.account_tree_outlined, size: 18),
                    label: const Text('Другие родители'),
                  ),
                if (_canEditOrDelete())
                  OutlinedButton.icon(
                    onPressed: _showRelationManagementSheet,
                    icon: const Icon(Icons.hub_outlined, size: 18),
                    label: const Text('Исправить связи'),
                  ),
              ],
            ),
          ],
        ),
      ),
    ]);
  }

  String? _buildPlaceLabel(String? city, String? country) {
    final hasCity = city != null && city.isNotEmpty;
    final hasCountry = country != null && country.isNotEmpty;
    if (!hasCity && !hasCountry) {
      return null;
    }

    if (hasCity && hasCountry) {
      return '$city, $country';
    }

    return city ?? country;
  }

  _RelativeContactStatus _getContactStatus() {
    if (_person?.id == _currentUserPersonId) {
      return const _RelativeContactStatus(
        label: 'Это вы',
        description:
            'Эта карточка уже связана с вашим профилем и показывает семье актуальные данные о вас.',
        icon: Icons.person,
        color: Colors.blue,
      );
    }

    if (_canStartChatWithPerson()) {
      return _RelativeContactStatus(
        label: 'Есть аккаунт в Родне',
        description:
            'Сейчас проще всего быстро выйти на контакт: написать человеку или помочь с обновлением профиля.',
        icon: Icons.verified_user_outlined,
        color: Colors.green.shade700,
      );
    }

    if (_canInvitePerson()) {
      return _RelativeContactStatus(
        label: 'Пока без аккаунта',
        description:
            'Сначала отправьте приглашение, чтобы человек подключился к дереву, чату и своему профилю.',
        icon: Icons.person_add_alt_1_outlined,
        color: Colors.orange.shade700,
      );
    }

    return _RelativeContactStatus(
      label: 'Карточка в дереве',
      description:
          'Пока это только карточка в дереве. Здесь лучше всего собирать семейные сведения, фотографии и память о человеке.',
      icon: Icons.visibility_outlined,
      color: Colors.grey.shade700,
    );
  }

  String? _getDirectRelationLabel() {
    final exactViewerLabel = _viewerRelationLabel?.trim();
    if (exactViewerLabel != null && exactViewerLabel.isNotEmpty) {
      return exactViewerLabel;
    }
    if (_person == null ||
        _relationToCurrentUser == null ||
        _relationToCurrentUser == RelationType.other) {
      return null;
    }

    final relationRelativeToUser = FamilyRelation.getMirrorRelation(
      _relationToCurrentUser!,
    );
    return FamilyRelation.getRelationName(
      relationRelativeToUser,
      _person!.gender,
    );
  }

  List<_EditableRelationLink> _buildEditableRelationLinks() {
    if (_person == null) {
      return const <_EditableRelationLink>[];
    }

    final peopleById = {for (final person in _treePeople) person.id: person};
    final links = <_EditableRelationLink>[];
    for (final relation in _relations) {
      late final String relatedPersonId;
      late final RelationType relationFromRelatedPerson;
      if (relation.person1Id == _person!.id) {
        relatedPersonId = relation.person2Id;
        relationFromRelatedPerson = relation.relation2to1;
      } else if (relation.person2Id == _person!.id) {
        relatedPersonId = relation.person1Id;
        relationFromRelatedPerson = relation.relation1to2;
      } else {
        continue;
      }

      final relatedPerson = peopleById[relatedPersonId];
      if (relatedPerson == null) {
        continue;
      }
      links.add(
        _EditableRelationLink(
          relation: relation,
          relatedPerson: relatedPerson,
          relationFromRelatedPerson: relationFromRelatedPerson,
        ),
      );
    }
    return links;
  }

  List<TreeGraphFamilyUnit> _parentFamilyUnitsForCurrentPerson() {
    if (_person == null || _graphSnapshot == null) {
      return const <TreeGraphFamilyUnit>[];
    }
    return _graphSnapshot!.parentFamilyUnitsForChild(_person!.id);
  }

  bool _hasAdditionalParentSets() {
    final units = _parentFamilyUnitsForCurrentPerson();
    if (units.length > 1) {
      return true;
    }
    return units.any((unit) => unit.isPrimaryParentSet == false);
  }

  List<TreeGraphWarning> _graphWarningsForCurrentPerson() {
    if (_person == null || _graphSnapshot == null) {
      return const <TreeGraphWarning>[];
    }
    return _sortedGraphWarnings(_graphSnapshot!.warningsForPerson(_person!.id));
  }

  List<TreeGraphWarning> _graphWarningsForRelationManagement(
    List<_EditableRelationLink> links,
  ) {
    final snapshot = _graphSnapshot;
    if (snapshot == null) {
      return _graphWarningsForCurrentPerson();
    }

    final warningsById = <String, TreeGraphWarning>{
      for (final warning in _graphWarningsForCurrentPerson())
        warning.id: warning,
    };
    for (final link in links) {
      for (final warning in snapshot.warningsForRelation(link.relation.id)) {
        warningsById[warning.id] = warning;
      }
    }
    return _sortedGraphWarnings(warningsById.values);
  }

  List<TreeGraphWarning> _sortedGraphWarnings(
    Iterable<TreeGraphWarning> warnings,
  ) {
    final items = warnings.toList();
    items.sort((left, right) {
      final severityComparison = _graphWarningPriority(right.severity)
          .compareTo(_graphWarningPriority(left.severity));
      if (severityComparison != 0) {
        return severityComparison;
      }
      return left.message.compareTo(right.message);
    });
    return items;
  }

  int _graphWarningPriority(String? severity) {
    switch ((severity ?? '').trim().toLowerCase()) {
      case 'error':
        return 3;
      case 'warning':
        return 2;
      case 'info':
        return 1;
      default:
        return 0;
    }
  }

  String _graphWarningTitle(TreeGraphWarning warning) {
    switch (warning.code) {
      case 'multiple_primary_parent_sets':
        return 'Несколько основных родителей';
      case 'auto_repaired_parent_link':
        return 'Связь достроена автоматически';
      case 'conflicting_direct_links':
        return 'Конфликт прямых связей';
      default:
        return 'Проверка дерева';
    }
  }

  Color _graphWarningAccent(TreeGraphWarning warning) {
    final colorScheme = Theme.of(context).colorScheme;
    switch ((warning.severity).trim().toLowerCase()) {
      case 'error':
        return colorScheme.error;
      case 'info':
        return colorScheme.primary;
      default:
        return colorScheme.tertiary;
    }
  }

  IconData _graphWarningIcon(TreeGraphWarning warning) {
    switch ((warning.severity).trim().toLowerCase()) {
      case 'error':
        return Icons.error_outline_rounded;
      case 'info':
        return Icons.info_outline_rounded;
      default:
        return Icons.warning_amber_rounded;
    }
  }

  Widget _buildGraphWarningCard(
    TreeGraphWarning warning, {
    bool compact = false,
  }) {
    final accent = _graphWarningAccent(warning);
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 10 : 12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accent.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _graphWarningIcon(warning),
            size: compact ? 18 : 20,
            color: accent,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _graphWarningTitle(warning),
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: accent,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  warning.message,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        height: 1.35,
                        color: colorScheme.onSurface,
                      ),
                ),
                if (warning.hint != null &&
                    warning.hint!.trim().isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    warning.hint!.trim(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          height: 1.35,
                          color: colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String? _normalizeOptionalText(String? value) {
    final normalized = value?.trim();
    if (normalized == null || normalized.isEmpty) {
      return null;
    }
    return normalized;
  }

  FamilyRelation? _findDirectRelation(String fromPersonId, String toPersonId) {
    final snapshotRelation =
        _graphSnapshot?.findDirectRelation(fromPersonId, toPersonId);
    if (snapshotRelation != null) {
      return snapshotRelation;
    }
    for (final relation in _relations) {
      if ((relation.person1Id == fromPersonId &&
              relation.person2Id == toPersonId) ||
          (relation.person1Id == toPersonId &&
              relation.person2Id == fromPersonId)) {
        return relation;
      }
    }
    return null;
  }

  String? _describeRelationContext(FamilyRelation relation) {
    final parts = <String>[];
    final normalizedParentSetType =
        _normalizeOptionalText(relation.parentSetType);
    if (normalizedParentSetType != null) {
      var label = FamilyRelation.getParentSetTypeLabel(normalizedParentSetType);
      if (relation.isPrimaryParentSet == false) {
        label = '$label, дополнительный набор родителей';
      }
      parts.add(label);
    }

    final unionParts = <String>[];
    final normalizedUnionType = _normalizeOptionalText(relation.unionType);
    if (normalizedUnionType != null) {
      unionParts.add(FamilyRelation.getUnionTypeLabel(normalizedUnionType));
    }
    final normalizedUnionStatus = _normalizeOptionalText(relation.unionStatus);
    if (normalizedUnionStatus != null) {
      unionParts.add(FamilyRelation.getUnionStatusLabel(normalizedUnionStatus));
    }
    if (unionParts.isNotEmpty) {
      parts.add(unionParts.join(' • '));
    }

    return parts.isEmpty ? null : parts.join(' • ');
  }

  String _buildPathStepLabel({
    required String fromPersonId,
    required String toPersonId,
    required Map<String, FamilyPerson> peopleById,
  }) {
    final relation = _findDirectRelation(fromPersonId, toPersonId);
    if (relation == null) {
      return 'Связь';
    }
    final customLabel = relation.customLabelFromPerson(fromPersonId);
    if (customLabel != null) {
      return customLabel;
    }
    final relationType = relation.relationFromPerson(fromPersonId);
    if (relationType == null) {
      return 'Связь';
    }
    return FamilyRelation.getRelationName(
      relationType,
      peopleById[toPersonId]?.gender,
    );
  }

  Widget _buildPathInfoChip({
    required IconData icon,
    required String label,
  }) {
    return Chip(
      visualDensity: VisualDensity.compact,
      avatar: Icon(icon, size: 16),
      label: Text(label),
    );
  }

  // _buildStatusChip used to render a contact-status chip in the
  // PersonDossierView header area. The new redesign hero card surfaces
  // the same information through `relBadge` + the status text rendered
  // directly under the hero — the chip helper is no longer needed.

  // Viewer §3.1 «## Семья»: read-first family section — serif heading,
  // the direct relatives (each tappable → their card) with relation
  // labels, and a «🌳 Открыть в дереве» button. Reuses _buildDirectFamilyRows.
  Widget _buildFamilySection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Семья',
          key: const Key('family-section-title'),
          style: AppTheme.serif(
            color: theme.colorScheme.onSurface,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 12),
        ..._buildDirectFamilyRows(),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('family-open-tree'),
            onPressed: _currentTreeId == null ? null : _openInTree,
            icon: const Icon(Icons.account_tree_outlined, size: 18),
            label: const Text('Открыть в дереве'),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildDirectFamilyRows() {
    if (_person == null) {
      return const [];
    }

    final peopleById = {for (final person in _treePeople) person.id: person};
    final rows = <Widget>[];

    for (final relation in _relations) {
      late final String relatedPersonId;
      late final RelationType relationFromRelatedPerson;

      if (relation.person1Id == _person!.id) {
        relatedPersonId = relation.person2Id;
        relationFromRelatedPerson = relation.relation2to1;
      } else if (relation.person2Id == _person!.id) {
        relatedPersonId = relation.person1Id;
        relationFromRelatedPerson = relation.relation1to2;
      } else {
        continue;
      }

      final relatedPerson = peopleById[relatedPersonId];
      if (relatedPerson == null) {
        continue;
      }

      rows.add(
        InkWell(
          onTap: () => context.push(
            relativeDetailsRoute(relatedPerson.id, treeId: _currentTreeId),
          ),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    relatedPerson.displayName,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  relation.customLabelToPerson(_person!.id) ??
                      FamilyRelation.getRelationName(
                        relationFromRelatedPerson,
                        relatedPerson.gender,
                      ),
                  style: TextStyle(color: Colors.grey[700]),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      );
    }

    return rows;
  }
}

/// One labelled fact in the «Основная информация» section. [memorial]
/// appends a «† Память» badge (death date).
class _BasicInfoRow {
  const _BasicInfoRow(this.label, this.value, {this.memorial = false});
  final String label;
  final String value;
  final bool memorial;
}

/// Bottom-of-card destructive button for «Удалить из дерева». Matches
/// the design's red-tinted ghost treatment (Bordered, transparent
/// fill, soft red ink) — destructive intent without screaming red.
class _DeleteRelativeButton extends StatelessWidget {
  const _DeleteRelativeButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const dangerInk = Color(0xFFC0392B);
    final dangerLine = dangerInk.withValues(alpha: 0.32);
    final dangerSoft = dangerInk.withValues(alpha: 0.06);
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 18),
          decoration: BoxDecoration(
            color: Theme.of(context).brightness == Brightness.dark
                ? dangerSoft
                : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: dangerLine, width: 1),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.delete_outline_rounded, size: 18, color: dangerInk),
              const SizedBox(width: 8),
              Text(
                'Удалить из дерева',
                style: AppTheme.sans(
                  color: dangerInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Плитка действия в шапке карточки: иконка + подпись в две строки,
/// одинаковая высота в ряду (IntrinsicHeight у родителя). Первичная —
/// заливка акцентом, остальные — тихая поверхность с тонкой рамкой.
class _HeroActionTile extends StatelessWidget {
  const _HeroActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final tokens = AppTheme.tokensOf(context);
    final enabled = onTap != null;
    final background = primary ? tokens.accent : tokens.surfaceStrong;
    final foreground = primary ? tokens.accentInk : tokens.ink;
    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: Material(
        color: background,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            decoration: primary
                ? null
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: tokens.surfaceLine, width: 0.8),
                  ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 22, color: foreground),
                const SizedBox(height: 4),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.sans(
                    color: foreground,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
