part of 'tree_view_screen.dart';

extension _TreeViewScreenSections on _TreeViewScreenState {
  Widget _buildTreeBody({required String selectedTreeId}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 720;
        final isWideDesktop = constraints.maxWidth >= 1180;
        final isEmptyTree = _relativesData.isEmpty &&
            _relationsData.isEmpty &&
            _errorMessage.isEmpty;

        if (_isLoading) {
          return _buildTreeState(
            icon: Icons.sync,
            title: 'Загружаем дерево',
            message: 'Подтягиваем людей и связи.',
            showProgress: true,
          );
        }

        // Ship 2026-05-26 (UX audit Screen 4.1): replaced single «Добавить»
        // button с relation-first guided CTA per audit «mama-fear»
        // observation. Also surfaces guided CTA когда tree has только
        // self person (canvas с tiny lone card в empty space — audit's
        // primary complaint).
        // A-CTA: блокирующий гид показываем только пока юзер его не
        // закрыл. После dismiss — обычный канвас с FAB «Добавить».
        final showGuidedCta =
            !_TreeViewScreenState._guidedCtaDismissedThisSession;

        if (isEmptyTree && showGuidedCta) {
          if (_isFriendsTree) {
            // Friends tree (Круг) — relation-first CTAs don't apply
            // (no «mama/papa» concept). Keep original single-button state.
            return _buildTreeState(
              icon: Icons.account_tree_outlined,
              title: 'Круг пока пустой',
              message: 'Добавьте первого человека в этот круг.',
              actions: [
                FilledButton.icon(
                  onPressed: () => _navigateToAddRelative(selectedTreeId),
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Добавить'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _retryCurrentTree(selectedTreeId),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Обновить'),
                ),
              ],
            );
          }
          // Ship FE4 (2026-05-26): viewer-role empty state shows
          // informational copy (no add CTAs) — viewer cannot mutate
          // tree, поэтому surfacing buttons would mislead.
          return EmptyTreeGuidedCta(
            hasSelfPerson: false,
            viewerMode: _isViewerOnly,
            onAddRelative: (relation, gender) => _navigateToAddRelativeWithHint(
              selectedTreeId,
              relation: relation,
              gender: gender,
            ),
            onAddOther: () => _navigateToAddRelative(selectedTreeId),
            onDismiss: _dismissGuidedCta,
          );
        }

        final selfPerson = _findSelfPerson();
        final treeHasOnlySelf =
            _relativesData.length == 1 && selfPerson != null && !_isFriendsTree;
        if (treeHasOnlySelf && showGuidedCta) {
          return EmptyTreeGuidedCta(
            hasSelfPerson: true,
            viewerMode: _isViewerOnly,
            onAddRelative: (relation, gender) => _navigateToAddRelativeWithHint(
              selectedTreeId,
              relation: relation,
              gender: gender,
              contextPersonId: selfPerson.id,
            ),
            onAddOther: () => _navigateToAddRelative(selectedTreeId),
            onDismiss: _dismissGuidedCta,
          );
        }

        if (_errorMessage.isNotEmpty) {
          return _buildTreeState(
            icon: Icons.error_outline,
            title: 'Дерево сейчас недоступно',
            message: _errorMessage,
            actions: [
              OutlinedButton.icon(
                onPressed: () => _retryCurrentTree(selectedTreeId),
                icon: const Icon(Icons.refresh),
                label: const Text('Повторить'),
              ),
            ],
          );
        }

        final selectedEditPerson = _selectedEditPerson;
        final branchRootPerson = _findBranchRootPerson();
        final warnings = _graphSnapshot?.warnings ?? const <TreeGraphWarning>[];
        final treeWarnings = branchRootPerson == null
            ? warnings
            : _graphSnapshot?.warningsForPerson(branchRootPerson.id) ??
                const <TreeGraphWarning>[];
        final treeCanvas = _buildTreeCanvas();
        final topToolbar = _buildTreeTopToolbar(
          selectedTreeId: selectedTreeId,
          branchRootPerson: branchRootPerson,
          compact: isCompact,
        );

        if (isWideDesktop) {
          // Desktop: tree canvas fills the whole body (full-bleed), the
          // toolbar sits across the top, and "Карта рода" sidebar floats
          // pinned to the left edge as a 312px column. Tree pans behind
          // both, matching the reference design where the family graph
          // is the page surface.
          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(child: treeCanvas),
              Positioned(
                top: 10,
                left: 14,
                right: 14,
                child: topToolbar,
              ),
              Positioned(
                top: 80,
                bottom: 14,
                left: 14,
                width: 312,
                child: _buildTreeContextColumn(
                  selectedTreeId: selectedTreeId,
                  branchRootPerson: branchRootPerson,
                  selectedEditPerson: selectedEditPerson,
                  warnings: treeWarnings,
                  compact: false,
                ),
              ),
            ],
          );
        }

        final compactContextHeight = constraints.maxHeight.isFinite
            ? (constraints.maxHeight * (isCompact ? 0.18 : 0.24))
                .clamp(128.0, isCompact ? 202.0 : 260.0)
                .toDouble()
            : (isCompact ? 210.0 : 260.0);

        // Mobile / compact: tree canvas fills the whole body and the
        // toolbar / context column float above it. The user asked for the
        // tree to read as the page background, not as a contained card —
        // matching the Claude Design reference where the family graph IS
        // the canvas and only thin chrome floats over it.
        //
        // Context column (info card + quick actions + health) starts
        // COLLAPSED so the canvas gets ~85% of the viewport (was ~60%
        // — user feedback "дерево всего лишь 60% экрана занимает").
        // Toggling via the chevron in the top toolbar slides it down.
        final showContextColumn = !_compactChromeCollapsed;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Tree canvas painted behind everything else, edge-to-edge.
            Positioned.fill(child: treeCanvas),
            // Floating chrome on top of the canvas. The headers sit in
            // their own column at the top, leaving the canvas clear in
            // the bottom 70% of the screen for the actual graph.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  isCompact ? 10 : 16,
                  isCompact ? 8 : 12,
                  isCompact ? 10 : 16,
                  0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    topToolbar,
                    // UX-T1.2 FR-b: видимый handle (как у нижнего листа) —
                    // раскрытие хрома больше не прячется за неочевидным
                    // шевроном; подпись со счётчиком намекает, что там детали.
                    if (isCompact) _buildTreeChromeHandle(),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 240),
                      curve: Curves.easeOutCubic,
                      alignment: Alignment.topCenter,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 240),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          return ClipRect(
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0, -0.25),
                                end: Offset.zero,
                              ).animate(animation),
                              child: FadeTransition(
                                  opacity: animation, child: child),
                            ),
                          );
                        },
                        child: showContextColumn
                            ? Padding(
                                key: const ValueKey('tree-chrome-shown'),
                                padding: const EdgeInsets.only(top: 10),
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: compactContextHeight,
                                  ),
                                  child: SingleChildScrollView(
                                    child: _buildTreeContextColumn(
                                      selectedTreeId: selectedTreeId,
                                      branchRootPerson: branchRootPerson,
                                      selectedEditPerson: selectedEditPerson,
                                      warnings: treeWarnings,
                                      compact: true,
                                    ),
                                  ),
                                ),
                              )
                            : const SizedBox(
                                key: ValueKey('tree-chrome-hidden'),
                                height: 0,
                                width: double.infinity,
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildTreeContextColumn({
    required String selectedTreeId,
    required FamilyPerson? branchRootPerson,
    required FamilyPerson? selectedEditPerson,
    required List<TreeGraphWarning> warnings,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final treeName =
        _currentTreeMeta?.name ?? widget.routeTreeName ?? 'Семейное дерево';
    final accent =
        _isFriendsTree ? const Color(0xFF0F9D8A) : theme.colorScheme.primary;
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildTreeHeroPanel(
          treeName: treeName,
          accent: accent,
          compact: compact,
        ),
        SizedBox(height: compact ? 8 : 12),
        _buildTreeQuickActionsPanel(
          selectedTreeId: selectedTreeId,
          branchRootPerson: branchRootPerson,
          compact: compact,
        ),
        if (branchRootPerson != null || selectedEditPerson != null) ...[
          SizedBox(height: compact ? 8 : 12),
          _buildTreeFocusPanel(
            branchRootPerson: branchRootPerson,
            selectedEditPerson: selectedEditPerson,
            accent: accent,
            compact: compact,
          ),
        ],
        if (!compact ||
            warnings.isNotEmpty ||
            _appStatusService.hasVisibleStatus ||
            _errorMessage.isNotEmpty) ...[
          SizedBox(height: compact ? 8 : 12),
          _buildTreeHealthPanel(
            warnings: warnings,
            compact: compact,
          ),
        ],
      ],
    );

    if (compact) {
      return body;
    }

    return SingleChildScrollView(
      child: body,
    );
  }

  /// UX-T1.2 FR-b: дискаверабилити-handle компактного хрома. Вместо
  /// неочевидного шеврона — видимый «потяни за деталями» в стиле drag-handle
  /// нижнего листа: грип-полоска + подпись (FR-a: единственный счётчик-тизер
  /// статов) + шеврон. Тап разворачивает hero-панель (единственный дом
  /// статов) и обратно.
  Widget _buildTreeChromeHandle() {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final collapsed = _compactChromeCollapsed;
    final peopleCount = _relativesData.length;
    final peopleLabel = '$peopleCount ${russianPluralForm(
      peopleCount,
      one: 'человек',
      few: 'человека',
      many: 'человек',
    )}';
    final label = collapsed ? '$peopleLabel · подробнее' : 'Свернуть';

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Center(
        child: Material(
          color: tokens.surfaceStrong.withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: const Key('tree-chrome-handle'),
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              _updateSectionState(() {
                _compactChromeCollapsed = !_compactChromeCollapsed;
              });
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Грип-полоска — узнаваемый «потяни меня» нижнего листа.
                  Container(
                    width: 30,
                    height: 3,
                    decoration: BoxDecoration(
                      color: tokens.inkMuted.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: tokens.inkSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        collapsed
                            ? Icons.expand_more_rounded
                            : Icons.expand_less_rounded,
                        size: 16,
                        color: tokens.inkSecondary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeTopToolbar({
    required String selectedTreeId,
    required FamilyPerson? branchRootPerson,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final accent =
        _isFriendsTree ? const Color(0xFF0F9D8A) : tokens.accentStrong;

    // UX-T1.2 FR-a: пилюли-статы (люди·связи·поколения·флаги) больше не
    // маячат в тулбаре — это был второй дом статов в дополнение к hero-
    // панели. Единственный дом теперь — hero-панель, которая раскрывается
    // по тапу (handle снизу / название дерева). Тулбар несёт только
    // контекст: чип-фильтр ветки + бейдж семьи.

    return GlassPanel(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 7 : 8,
      ),
      borderRadius: BorderRadius.circular(tokens.radiusLg),
      color: tokens.surfaceStrong.withValues(alpha: 0.9),
      borderColor: tokens.surfaceLine,
      child: Row(
        children: [
          // Bug fix (S20 FE: body toolbar overflowed past the trailing
          // icons at 360-393dp). The informational cluster (branch filter
          // chip + семя badge + stat pills) now lives in ONE horizontal
          // scroll bounded by Expanded, so it always yields space to the
          // fixed, always-visible action icons — the Row can't overflow at
          // any width (it scrolls instead). Responsive; no hardcoded width.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTreeBranchFilterChip(
                    branchRootPerson: branchRootPerson,
                    accent: accent,
                    compact: compact,
                  ),
                  SizedBox(width: compact ? 8 : 10),
                  // семя context badge. Bounded so its internal ellipsis
                  // works inside the (otherwise unbounded) horizontal scroll.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 220),
                    child: SemyaContextBadge(
                      semya: _currentSemyaContext?.semya,
                      callerRole: _currentSemyaContext?.callerRole,
                      onTap: _currentSemyaContext != null
                          ? () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => SemyaDetailsScreen(
                                    semyaId: _currentSemyaContext!.semya.id,
                                  ),
                                ),
                              )
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // UX-T1 FR2: на телефоне (compact) единственная кнопка добавления —
          // FAB «Добавить» (Telegram-стиль). Дубль-кнопку из тулбара убираем
          // (оба входа звали один _startAddRelativeFlow). На десктопе
          // (!compact) тулбар-кнопку оставляем как есть.
          if (!compact) ...[
            const SizedBox(width: 10),
            _buildTreeToolbarIconButton(
              icon: Icons.person_add_alt_1_outlined,
              tooltip: _isFriendsTree
                  ? 'Добавить из панели круга'
                  : 'Добавить из панели дерева',
              // Чанк C: тот же флоу, что у FAB (семья → пикер «Кем
              // приходится?», круг → форма) — два верхних входа больше не
              // расходятся.
              onPressed: () => _startAddRelativeFlow(selectedTreeId),
              emphasized: true,
            ),
          ],
          // Selection mode toggle — top-level visible icon instead
          // of buried in the «...» overflow. This is the user's
          // primary tool for slicing the tree («выделить мамину
          // линию и одной кнопкой собрать ветку»), so hiding it
          // behind a popup made it functionally invisible. When
          // active the button shows the close glyph + accent fill
          // so the user has a clear "exit selection" affordance
          // without hunting through the menu.
          //
          // On compact viewports we drop the visible button (the
          // toolbar Row would overflow) and rely on the overflow
          // popup-menu entry — same selection flow, one extra tap.
          if (!compact)
            _buildTreeToolbarIconButton(
              icon: _isSelectionMode
                  ? Icons.close_rounded
                  : Icons.check_box_outlined,
              tooltip: _isSelectionMode
                  ? 'Выйти из режима выбора'
                  : 'Выбрать несколько человек',
              emphasized: _isSelectionMode,
              onPressed: () {
                _updateSectionState(() {
                  _isSelectionMode = !_isSelectionMode;
                  if (!_isSelectionMode) {
                    _selectedPersonIds.clear();
                  } else if (_isEditMode) {
                    // Selection and edit fight over the same gesture
                    // (long-press / drag); switch atomically.
                    _isEditMode = false;
                    _selectedEditPersonId = null;
                  }
                });
              },
            ),
          // UX-T1.2 FR-c: «Расставить карточки» (репозиция) — вторичное
          // действие; на телефоне живёт в overflow «•••» (toggleEditMode),
          // на десктопе остаётся видимой кнопкой тулбара.
          if (!compact)
            _buildTreeToolbarIconButton(
              icon: _isEditMode ? Icons.visibility_outlined : Icons.open_with,
              tooltip:
                  _isEditMode ? 'Вернуться к просмотру' : 'Расставить карточки',
              onPressed: () {
                _updateSectionState(() {
                  _isEditMode = !_isEditMode;
                  if (!_isEditMode) {
                    _selectedEditPersonId = null;
                  } else if (_isSelectionMode) {
                    _isSelectionMode = false;
                    _selectedPersonIds.clear();
                  }
                });
              },
            ),
          // UX-T1.2 FR-b: раскрытие компактного хрома больше не прячется за
          // незаметным шевроном в тулбаре — на телефоне его заменил видимый
          // handle с подписью под тулбаром (см. _buildTreeChromeHandle).
        ],
      ),
    );
  }

  Widget _buildTreeBranchFilterChip({
    required FamilyPerson? branchRootPerson,
    required Color accent,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final hasBranchFocus = branchRootPerson != null;
    final label = hasBranchFocus
        ? branchRootPerson.displayName
        : (_isFriendsTree ? 'Весь круг' : 'Всё дерево');

    return Tooltip(
      message: hasBranchFocus
          ? (_isFriendsTree ? 'Сбросить круг' : 'Сбросить ветку')
          : (_isFriendsTree ? 'Фильтр круга' : 'Фильтр ветки'),
      child: Material(
        color: hasBranchFocus ? accent.withValues(alpha: 0.12) : tokens.surface,
        borderRadius: tokens.chipRadius,
        child: InkWell(
          borderRadius: tokens.chipRadius,
          onTap: hasBranchFocus ? _resetBranchFocus : null,
          child: Container(
            constraints: BoxConstraints(maxWidth: compact ? 128 : 220),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: compact ? 8 : 9,
            ),
            decoration: BoxDecoration(
              borderRadius: tokens.chipRadius,
              border: Border.all(
                color: hasBranchFocus
                    ? accent.withValues(alpha: 0.42)
                    : tokens.surfaceLine,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hasBranchFocus
                      ? Icons.alt_route_outlined
                      : (_isFriendsTree
                          ? Icons.diversity_3_outlined
                          : Icons.account_tree_outlined),
                  size: 16,
                  color: hasBranchFocus ? accent : tokens.inkSecondary,
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: hasBranchFocus ? accent : tokens.inkSecondary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (hasBranchFocus) ...[
                  const SizedBox(width: 6),
                  Icon(Icons.close, size: 14, color: accent),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeToolbarIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool emphasized = false,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final background =
        emphasized ? tokens.accent : tokens.surface.withValues(alpha: 0.92);
    final foreground = emphasized ? tokens.accentInk : tokens.accentStrong;

    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: background,
          borderRadius: BorderRadius.circular(999),
          child: InkWell(
            borderRadius: BorderRadius.circular(999),
            onTap: onPressed,
            child: SizedBox(
              width: 42,
              height: 42,
              child: Icon(icon, size: 20, color: foreground),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTreeHeroPanel({
    required String treeName,
    required Color accent,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final graphSnapshot = _graphSnapshot;
    final personCount = _relativesData.length;
    final relationCount = _relationsData.length;
    final generationCount = graphSnapshot?.generationRows.length ?? 0;
    final branchCount = graphSnapshot?.branchBlocks.length ?? 0;

    if (compact) {
      final stats = <String>[
        '$personCount ${russianPluralForm(
          personCount,
          one: 'человек',
          few: 'человека',
          many: 'человек',
        )}',
        relationCount == 1 ? '1 связь' : '$relationCount связей',
        if (generationCount > 0)
          generationCount == 1 ? '1 поколение' : '$generationCount поколений',
        if (branchCount > 0)
          branchCount == 1 ? '1 ветка' : '$branchCount веток',
      ].join(' · ');

      return GlassPanel(
        padding: const EdgeInsets.all(12),
        borderRadius: BorderRadius.circular(22),
        color: theme.colorScheme.surface.withValues(alpha: 0.82),
        borderColor: accent.withValues(alpha: 0.14),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                _isFriendsTree
                    ? Icons.diversity_3_outlined
                    : Icons.account_tree_outlined,
                size: 20,
                color: accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    treeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stats,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return GlassPanel(
      padding: EdgeInsets.all(compact ? 16 : 20),
      borderRadius: BorderRadius.circular(30),
      color: theme.colorScheme.surface.withValues(alpha: 0.8),
      borderColor: accent.withValues(alpha: 0.16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isFriendsTree
                      ? Icons.diversity_3_outlined
                      : Icons.account_tree_outlined,
                  size: 18,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Text(
                  _isFriendsTree ? 'Круг общения' : 'Карта рода',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            treeName,
            style: (compact
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.headlineSmall)
                ?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildTreeStatChip(
                icon: Icons.people_outline,
                label: '$personCount ${russianPluralForm(
                  personCount,
                  one: 'человек',
                  few: 'человека',
                  many: 'человек',
                )}',
              ),
              _buildTreeStatChip(
                icon: Icons.alt_route_outlined,
                label: relationCount == 1 ? '1 связь' : '$relationCount связей',
              ),
              _buildTreeStatChip(
                icon: Icons.layers_outlined,
                label: generationCount == 0
                    ? 'Без уровней'
                    : generationCount == 1
                        ? '1 поколение'
                        : '$generationCount поколений',
              ),
              if (branchCount > 0)
                _buildTreeStatChip(
                  icon: Icons.hub_outlined,
                  label: branchCount == 1 ? '1 ветка' : '$branchCount веток',
                ),
              if (_manualNodePositions.isNotEmpty)
                _buildTreeStatChip(
                  icon: Icons.open_with_rounded,
                  label: 'Ручная раскладка',
                ),
            ],
          ),
          if (!_currentUserIsInTree) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(
                  Icons.person_search_outlined,
                  size: 15,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _isFriendsTree
                        ? 'Вашей карточки нет в круге — добавьте себя через связь.'
                        : 'Вашей карточки нет в дереве — добавьте себя через связь.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTreeQuickActionsPanel({
    required String selectedTreeId,
    required FamilyPerson? branchRootPerson,
    required bool compact,
  }) {
    // The "Добавить" tile that used to live here was a third copy of the
    // same action — top toolbar already has its own "+ Add person" green
    // circle, which is the primary entry point. The Quick Actions card
    // now starts with Чаты / Пост / Расставить — actions that DON'T
    // duplicate buttons from the toolbar.
    final actions = <Widget>[
      _buildTreeActionButton(
        icon: Icons.forum_outlined,
        label: 'Чаты',
        compact: compact,
        onPressed: () => context.go('/chats'),
      ),
      _buildTreeActionButton(
        icon: Icons.post_add_outlined,
        label: 'Пост',
        compact: compact,
        onPressed: () => context.push('/post/create'),
      ),
      _buildTreeActionButton(
        icon: _isEditMode ? Icons.edit_off_outlined : Icons.open_with_rounded,
        label: _isEditMode ? 'Готово' : 'Расставить',
        compact: compact,
        onPressed: () {
          _updateSectionState(() {
            _isEditMode = !_isEditMode;
            if (!_isEditMode) {
              _selectedEditPersonId = null;
            }
          });
        },
      ),
      if (branchRootPerson != null)
        _buildTreeActionButton(
          icon: Icons.alt_route_outlined,
          label: _isFriendsTree ? 'Чат круга' : 'Чат ветки',
          compact: compact,
          onPressed: () => _openBranchChat(selectedTreeId, branchRootPerson),
        ),
      if (_branchRootPersonId != null)
        _buildTreeActionButton(
          icon: Icons.clear_all,
          label: compact
              ? 'Всё'
              : (_isFriendsTree ? 'Показать весь граф' : 'Показать всё дерево'),
          compact: compact,
          onPressed: _resetBranchFocus,
        ),
      if (_manualNodePositions.isNotEmpty)
        _buildTreeActionButton(
          icon: Icons.restart_alt,
          label: compact ? 'Сброс' : 'Сбросить раскладку',
          compact: compact,
          onPressed: () => _resetManualTreeLayout(selectedTreeId),
        ),
      if (_currentTreeMeta?.isPublic == true)
        _buildTreeActionButton(
          icon: Icons.link_outlined,
          label: compact ? 'Ссылка' : 'Публичная ссылка',
          compact: compact,
          onPressed: _copyPublicTreeLink,
        ),
    ];

    return GlassPanel(
      padding: EdgeInsets.all(compact ? 8 : 16),
      borderRadius: BorderRadius.circular(compact ? 22 : 26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!compact) ...[
            Text(
              'Сразу к делу',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 10),
          ],
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var index = 0; index < actions.length; index++) ...[
                  actions[index],
                  if (index != actions.length - 1)
                    SizedBox(width: compact ? 8 : 10),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeFocusPanel({
    required FamilyPerson? branchRootPerson,
    required FamilyPerson? selectedEditPerson,
    required Color accent,
    required bool compact,
  }) {
    // No branch selected → don't waste screen space with a description panel;
    // the canvas itself already shows the full tree.  Show the panel only when
    // a branch is in focus or a person is being repositioned (edit mode).
    final hasFocusContent =
        branchRootPerson != null || selectedEditPerson != null;
    if (!hasFocusContent) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final branchVisibleCount = branchRootPerson == null
        ? _relativesData.length
        : _buildBranchVisiblePersonIds(branchRootPerson.id).length;

    return GlassPanel(
      padding: EdgeInsets.all(compact ? 14 : 16),
      borderRadius: BorderRadius.circular(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            branchRootPerson == null
                ? (_isFriendsTree ? 'Расстановка' : 'Расстановка')
                : (_isFriendsTree ? 'Фокус на круге' : 'Фокус на ветке'),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          if (branchRootPerson != null)
            _buildTreePersonHighlight(
              person: branchRootPerson,
              eyebrow: _isFriendsTree ? 'Корень круга' : 'Корень ветки',
              accent: accent,
              trailing: _buildMiniCountBadge('$branchVisibleCount узлов'),
            ),
          if (selectedEditPerson != null) ...[
            const SizedBox(height: 14),
            Divider(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
            ),
            const SizedBox(height: 12),
            Text(
              _isEditMode ? 'Карточка для расстановки' : 'Выбранная карточка',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            _buildTreePersonHighlight(
              person: selectedEditPerson,
              eyebrow: _isEditMode ? 'Режим перемещения' : 'Текущий выбор',
              accent: accent,
              trailing: _isEditMode
                  ? _buildMiniCountBadge('Двигайте по поколению')
                  : null,
            ),
          ] else if (_isEditMode) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: accent.withValues(alpha: 0.14)),
              ),
              child: Text(
                'Режим расстановки включён. Нажмите на карточку в дереве, чтобы подвигать её по своему поколению.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTreeHealthPanel({
    required List<TreeGraphWarning> warnings,
    required bool compact,
  }) {
    final theme = Theme.of(context);
    final warningPreview = warnings.take(compact ? 1 : 2).toList();
    final hasOperationalIssue =
        _appStatusService.hasVisibleStatus || _errorMessage.isNotEmpty;

    return GlassPanel(
      padding: EdgeInsets.all(compact ? 14 : 16),
      borderRadius: BorderRadius.circular(26),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Состояние дерева',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _buildMiniCountBadge(
                warnings.isEmpty
                    ? 'без предупреждений'
                    : warnings.length == 1
                        ? '1 предупреждение'
                        : '${warnings.length} предупреждений',
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (hasOperationalIssue) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer
                    .withValues(alpha: 0.42),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: theme.colorScheme.secondary.withValues(alpha: 0.14),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _appStatusService.hasSessionIssue
                        ? 'Сессия требует внимания'
                        : _appStatusService.isOffline
                            ? 'Есть проблемы с сетью'
                            : 'Есть что перепроверить',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _appStatusService.issue?.message ??
                        (_errorMessage.isNotEmpty
                            ? _errorMessage
                            : _appStatusService.isOffline
                                ? 'Дерево можно просматривать, но обновления и часть действий сейчас нестабильны.'
                                : 'Попробуйте обновить дерево, чтобы вернуть актуальное состояние.'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.32,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _appStatusService.hasSessionIssue
                            ? () => context.go('/login')
                            : () {
                                _appStatusService.requestRetry();
                                if (_currentTreeId != null) {
                                  _retryCurrentTree(_currentTreeId!);
                                }
                              },
                        icon: Icon(
                          _appStatusService.hasSessionIssue
                              ? Icons.login_outlined
                              : Icons.refresh_rounded,
                        ),
                        label: Text(
                          _appStatusService.hasSessionIssue
                              ? 'Войти снова'
                              : 'Обновить дерево',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (warnings.isEmpty)
            Text(
              _isFriendsTree
                  ? 'Граф выглядит чисто: можно открывать карточки, смотреть связи и писать людям без лишней навигации.'
                  : 'Схема выглядит чисто: поколения и связи собраны, дерево готово к работе и просмотру.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.38,
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: warningPreview
                  .map(
                    (warning) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.errorContainer
                              .withValues(alpha: 0.38),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: theme.colorScheme.error.withValues(
                              alpha: 0.14,
                            ),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              warning.message,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                            if ((warning.hint ?? '').isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                warning.hint!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onErrorContainer
                                      .withValues(alpha: 0.88),
                                  height: 1.32,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildTreePersonHighlight({
    required FamilyPerson person,
    required String eyebrow,
    required Color accent,
    Widget? trailing,
  }) {
    final theme = Theme.of(context);
    final photoUrl = person.primaryPhotoUrl;
    final avatarImage = buildAvatarImageProvider(photoUrl);
    final subtitleParts = <String>[
      if ((person.birthDate?.year ?? 0) > 0) 'р. ${person.birthDate!.year}',
      if (person.isAlive == false && (person.deathDate?.year ?? 0) > 0)
        'память ${person.deathDate!.year}',
      if ((person.birthPlace ?? '').trim().isNotEmpty)
        person.birthPlace!.trim(),
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.14)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: accent.withValues(alpha: 0.14),
            backgroundImage: avatarImage,
            child: avatarImage == null
                ? Text(
                    person.initials,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  eyebrow,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  person.displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitleParts.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitleParts.join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing,
          ],
        ],
      ),
    );
  }

  Widget _buildTreeStatChip({
    required IconData icon,
    required String label,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniCountBadge(String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _buildTreeActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
    bool emphasized = false,
    bool compact = false,
  }) {
    final minimumSize = compact ? const Size(0, 38) : null;
    final padding = EdgeInsets.symmetric(
      horizontal: compact ? 12 : 16,
      vertical: compact ? 9 : 12,
    );
    if (emphasized) {
      return FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: minimumSize,
          padding: padding,
          visualDensity: compact ? VisualDensity.compact : null,
          tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
        ),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: minimumSize,
        padding: padding,
        visualDensity: compact ? VisualDensity.compact : null,
        tapTargetSize: compact ? MaterialTapTargetSize.shrinkWrap : null,
      ),
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }

  void _retryCurrentTree(String treeId) {
    _appStatusService.requestRetry();
    unawaited(_loadData(treeId));
  }

  Widget _buildTreeCanvas() {
    final theme = Theme.of(context);
    final selectedPerson = _selectedPersonSheetPerson;
    final canvasAccent =
        _isFriendsTree ? const Color(0xFF0F9D8A) : theme.colorScheme.primary;
    // Full-bleed canvas: drop the GlassPanel wrapper that used to box the
    // tree inside a 30-radius card. The tree now paints directly on the
    // app backdrop (warm cream + radial highlights from `AppBackdrop`),
    // matching the reference design where the family graph IS the
    // background, not a contained widget. Toolbar / sidebar / sheet
    // float over this canvas.
    return Stack(
      fit: StackFit.expand,
      children: [
        // Soft accent halo behind the tree — pulls focus to the canvas
        // center without putting a hard frame around it.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0, -0.05),
                radius: 0.95,
                colors: [
                  canvasAccent.withValues(
                    alpha: _isFriendsTree ? 0.07 : 0.05,
                  ),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.75],
              ),
            ),
          ),
        ),
        Stack(
          fit: StackFit.expand,
          children: [
            InteractiveFamilyTree(
              peopleData: _relativesData,
              relations: _relationsData,
              graphSnapshot: _graphSnapshot,
              currentUserId: _authService.currentUserId,
              branchRootPersonId: _branchRootPersonId,
              selectedPersonId: _selectedPersonSheetId,
              onBranchFocusCleared: _resetBranchFocus,
              onPersonTap: (person) {
                debugPrint('Нажатие на узел: ${person.name} (${person.id})');
                _selectTreePerson(person);
                // In edit mode the same single tap also routes through
                // the inline edit selection so the bottom sheet's edit
                // action row knows which node to operate on.
                if (_isEditMode) {
                  _updateSectionState(() {
                    _selectedEditPersonId = person.id;
                    _personSheetExpanded = true;
                  });
                } else {
                  // Ship Q4 (2026-05-26): UX audit 2026-05-25 Critical #4 —
                  // tap on tree person теперь surface'ит modal action sheet
                  // (Профиль / Редактировать / Добавить / Связать / Удалить).
                  // Inline person sheet остаётся active для contextual
                  // selection в edit mode и для drag/zoom/PiP interactions.
                  _showTreePersonActionSheet(person);
                }
              },
              onPersonDoubleTap: (person) {
                // Double-click on a card = drill into full profile.
                // Single tap still opens the bottom sheet peek; double
                // is the shortcut for users who want the full page.
                _openPersonDetails(person);
              },
              onShowRelationPath: (person) =>
                  _openPersonDetails(person, action: 'path'),
              onShowOtherParents: (person) =>
                  _openPersonDetails(person, action: 'parents'),
              onFixPersonRelations: (person) =>
                  _openPersonDetails(person, action: 'relations'),
              onBranchFocusRequested: _focusBranch,
              isEditMode: _isEditMode,
              selectedEditPersonId: _selectedEditPersonId,
              onEditPersonSelected: (person) {
                _updateSectionState(() {
                  _selectedEditPersonId = person.id;
                });
              },
              onOpenPersonHistory: _showPersonHistorySheet,
              manualNodePositions: _manualNodePositions,
              onNodePositionsChanged: (positions) {
                _handleNodePositionsChanged(positions);
              },
              showGenerationGuides: !_isFriendsTree,
              graphLabel: _isFriendsTree ? 'дружеского графа' : 'дерева',
              hasManualLayout: _manualNodePositions.isNotEmpty,
              onResetLayout:
                  _manualNodePositions.isNotEmpty && _currentTreeId != null
                      ? () => _resetManualTreeLayout(_currentTreeId!)
                      : null,
              onAddRelativeTapWithType: _handleAddRelativeFromTree,
              currentUserIsInTree: _currentUserIsInTree,
              onAddSelfTapWithType: _handleAddSelfFromTree,
              // Edge-first connector — long-press a card, drag to
              // another, pick a relation type from the inline
              // 4-icon picker. The handler talks to family service
              // directly and reloads on success; no form involved.
              onConnectExistingPersons: _handleConnectExistingFromTree,
              // Blank-card creator — drop a person on the canvas
              // with no relation. The user fills name + gender in
              // a small dialog, we create them via the service,
              // and they then connect via the connector above.
              onAddBlankPerson: _handleAddBlankPersonFromTree,
              // Auto-recenter trigger: after addRelative succeeds
              // we stamp the new person id here, the tree picks
              // it up via didUpdateWidget and snaps to center.
              recenterOnPersonId: _recenterOnPersonIdAfterReload,
              // Phase 1.2 voltage indicator: counts come from the
              // background fetch in _loadData; tap callback opens
              // the suggestions sheet.
              identitySuggestionCounts: _identitySuggestionCounts,
              onShowIdentitySuggestions:
                  _handleShowIdentitySuggestionsForPerson,
              // Phase 1.3 conflict surfacing: same model as 💡 —
              // counts populated in the background, tap opens
              // the resolve sheet keyed off this person.
              identityConflictCounts: _identityConflictCounts,
              onShowIdentityConflicts: _handleShowIdentityConflictsForPerson,
              // UX-T1 FR3: на телефоне резерв отражает РЕАЛЬНУЮ высоту
              // хрома над канвасом. По умолчанию контекст-колонка свёрнута
              // (_compactChromeCollapsed=true) → над канвасом только
              // плавающий тулбар (~120 c отступом), а не устаревшие 290
              // (они зарезервированы под раскрытую колонку). Это и есть
              // canvas-first: дерево фитится в >=85% высоты. При раскрытии
              // колонки резерв снова ~290. Десктоп (>=1180) — 96, не трогаем.
              viewportReservedTop: MediaQuery.of(context).size.width >= 1180
                  ? 96
                  : (_compactChromeCollapsed ? 120 : 290),
              viewportReservedBottom: 120,
              // Edit actions live in the bottom sheet now — suppress
              // the floating inline panel so we don't have two action
              // surfaces over the same node.
              showInlineEditPanel: false,
              // Multi-select for bulk actions (Step 2). When the
              // host opens selection mode through the toolbar, the
              // canvas owns tap-to-toggle and shows accent rings;
              // a separate bottom toolbar (below) drives the
              // bulk-action choice.
              selectionMode: _isSelectionMode,
              selectedPersonIds: _selectedPersonIds,
              onPersonSelectionToggle: (person) {
                if (!_isSelectionMode) return;
                _updateSectionState(() {
                  if (_selectedPersonIds.contains(person.id)) {
                    _selectedPersonIds.remove(person.id);
                  } else {
                    _selectedPersonIds.add(person.id);
                  }
                });
              },
              viewMode:
                  _extendedNetworkController?.mode ?? ExtendedNetworkMode.mine,
              networkSlice: _extendedNetworkController?.slice,
              // Phase 4 chunk 4a: foreign node tap intercept.
              // Host owns sheet — `_handleForeignNodeTap` opens
              // ForeignNodeSheet через showModalBottomSheet.
              onForeignNodeTap: _extendedNetworkController?.isCapable == true
                  ? _handleForeignNodeTap
                  : null,
            ),
            Positioned(
              left: 12,
              right: 12,
              bottom: 12,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _isSelectionMode
                    ? _buildSelectionToolbar(
                        key: const ValueKey<String>('selection-toolbar'),
                        accent: canvasAccent,
                      )
                    : selectedPerson == null
                        ? const SizedBox.shrink()
                        : _buildTreePersonBottomSheet(
                            key: ValueKey<String>(
                              'tree-person-sheet-${selectedPerson.id}',
                            ),
                            person: selectedPerson,
                            accent: canvasAccent,
                          ),
              ),
            ),
            IgnorePointer(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Align(
                  alignment: Alignment.topRight,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: !_isEditMode
                        ? const SizedBox.shrink()
                        : Container(
                            key: const ValueKey<String>(
                              'tree-manual-layout-hint',
                            ),
                            constraints: const BoxConstraints(maxWidth: 280),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surface.withValues(
                                alpha: 0.96,
                              ),
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: canvasAccent.withValues(alpha: 0.18),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: theme.colorScheme.shadow.withValues(
                                    alpha: 0.08,
                                  ),
                                  blurRadius: 18,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.open_with_rounded,
                                  size: 18,
                                  color: canvasAccent,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Режим перемещения: зажмите карточку и тяните по своему поколению.',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurfaceVariant,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTreePersonBottomSheet({
    Key? key,
    required FamilyPerson person,
    required Color accent,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final avatarImage = buildAvatarImageProvider(person.primaryPhotoUrl);

    // Reference style sheet: collapsed peek bar (avatar + Lora fname + small
    // meta + chevron) that expands on tap to reveal full info + action row.
    final birthYear = person.birthDate?.year;
    final deathYear = person.deathDate?.year;
    final age = (birthYear != null && birthYear > 0)
        ? ((deathYear != null && deathYear > 0
                ? deathYear
                : DateTime.now().year) -
            birthYear)
        : null;
    final lifeRange = birthYear != null && birthYear > 0
        ? (deathYear != null && deathYear > 0
            ? '$birthYear–$deathYear'
            : '$birthYear · ${age ?? '?'} лет')
        : null;
    final place = (person.birthPlace ?? '').trim();
    final hasWarnings =
        _graphSnapshot?.warningsForPerson(person.id).isNotEmpty == true;

    final nameParts = person.displayName.trim().split(RegExp(r'\s+'));
    final fname = nameParts.isNotEmpty ? nameParts.first : person.displayName;
    final lname = nameParts.length > 1 ? nameParts.sublist(1).join(' ') : null;

    // Peek row — always visible. Tapping it toggles expansion. Drag handle
    // sits centered above so the surface reads as a sheet, not a card.
    final peekRow = Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: accent.withValues(alpha: 0.14),
            backgroundImage: avatarImage,
            child: avatarImage == null
                ? Text(
                    person.initials,
                    style: AppTheme.sans(
                      color: accent,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: fname,
                        style: AppTheme.serif(
                          color: tokens.ink,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      if (lname != null)
                        TextSpan(
                          text: ' $lname',
                          style: AppTheme.sans(
                            color: tokens.inkSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    if (lifeRange != null) lifeRange,
                    if (place.isNotEmpty) place,
                    if (hasWarnings && lifeRange == null && place.isEmpty)
                      'Нужна проверка',
                  ].whereType<String>().take(2).join(' · ').isEmpty
                      ? (_isFriendsTree ? 'Карточка круга' : 'Карточка дерева')
                      : [
                          if (lifeRange != null) lifeRange,
                          if (place.isNotEmpty) place,
                        ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          AnimatedRotation(
            turns: _personSheetExpanded ? 0.5 : 0.0,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut,
            child: Icon(
              Icons.keyboard_arrow_up_rounded,
              size: 20,
              color: tokens.inkSecondary,
            ),
          ),
          IconButton(
            tooltip: 'Закрыть карточку',
            iconSize: 18,
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.close, color: tokens.inkSecondary),
            onPressed: _clearSelectedTreePerson,
          ),
        ],
      ),
    );

    // Expanded body — shown when sheet is expanded. Action row + sundries.
    final expandedBody = AnimatedSize(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOut,
      alignment: Alignment.topCenter,
      child: !_personSheetExpanded
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    height: 0.6,
                    color: tokens.surfaceLine.withValues(alpha: 0.6),
                  ),
                  const SizedBox(height: 12),
                  if (age != null) ...[
                    Text(
                      person.isAlive == false
                          ? 'Прожил${person.gender == Gender.female ? 'а' : ''} $age ${_yearsLabel(age)}'
                          : '$age ${_yearsLabel(age)}',
                      style: AppTheme.sans(
                        color: tokens.inkSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Edit-mode shows a different action set focused on
                  // tree-editor flows: add parent / spouse / child / sibling
                  // shortcuts, plus profile + history. View-mode keeps the
                  // social actions (Профиль / Написать / История / Ветка /
                  // Связь). The split keeps each context surface clean.
                  if (_isEditMode) ...[
                    _buildEditModeActionBlock(
                      person: person,
                      hasWarnings: hasWarnings,
                    ),
                  ] else ...[
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildTreeSheetAction(
                            icon: Icons.open_in_new,
                            label: 'Профиль',
                            onPressed: () => _openPersonDetails(person),
                            emphasized: true,
                          ),
                          const SizedBox(width: 8),
                          _buildTreeSheetAction(
                            icon: Icons.chat_bubble_outline_rounded,
                            label: 'Написать',
                            onPressed: () => _openPersonDetails(
                              person,
                              action: 'chat',
                            ),
                          ),
                          const SizedBox(width: 8),
                          _buildTreeSheetAction(
                            icon: Icons.history_outlined,
                            label: 'История',
                            onPressed: () => _showPersonHistorySheet(person),
                          ),
                          const SizedBox(width: 8),
                          _buildTreeSheetAction(
                            icon: Icons.alt_route_outlined,
                            label: _isFriendsTree ? 'Круг' : 'Ветка',
                            onPressed: () => _focusBranch(person),
                          ),
                          const SizedBox(width: 8),
                          _buildTreeSheetAction(
                            icon: Icons.person_add_alt_1_outlined,
                            label: 'Связь',
                            onPressed: () =>
                                _showTreePersonRelationSheet(person),
                          ),
                          const SizedBox(width: 8),
                          // Phase 4: «Кем мы приходимся?» — BFS over the
                          // unified-graph blood-relation edges. Hidden
                          // when the viewer is selected (it's "you") or
                          // the viewer card isn't in the tree.
                          if (person.id != _graphSnapshot?.viewerPersonId &&
                              _graphSnapshot?.viewerPersonId != null)
                            _buildTreeSheetAction(
                              icon: Icons.account_tree_rounded,
                              label: 'Родство',
                              onPressed: () =>
                                  _showTreePersonBloodRelation(person),
                            ),
                          if (hasWarnings) ...[
                            const SizedBox(width: 8),
                            _buildTreeSheetAction(
                              icon: Icons.report_problem_outlined,
                              label: 'Проверить',
                              onPressed: () => _openPersonDetails(person,
                                  action: 'relations'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );

    // Drag handle pill — minimal indicator that the sheet is interactive.
    final dragHandle = Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Container(
        width: 38,
        height: 4,
        decoration: BoxDecoration(
          color: tokens.inkMuted.withValues(alpha: 0.42),
          borderRadius: BorderRadius.circular(999),
        ),
      ),
    );

    return Align(
      key: key,
      alignment: Alignment.bottomCenter,
      child: Semantics(
        label: 'tree-person-sheet',
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: GlassPanel(
            padding: EdgeInsets.zero,
            borderRadius: BorderRadius.circular(tokens.radiusLg),
            color: tokens.surfaceStrong.withValues(alpha: 0.94),
            borderColor: accent.withValues(alpha: 0.20),
            boxShadow: tokens.panelShadow(theme.brightness, floating: true),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Tap-to-toggle header (handle + peek row).
                Material(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(tokens.radiusLg),
                    bottom: Radius.circular(
                        _personSheetExpanded ? 0 : tokens.radiusLg),
                  ),
                  child: InkWell(
                    onTap: _togglePersonSheetExpansion,
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(tokens.radiusLg),
                      bottom: Radius.circular(
                          _personSheetExpanded ? 0 : tokens.radiusLg),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        dragHandle,
                        peekRow,
                      ],
                    ),
                  ),
                ),
                expandedBody,
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _yearsLabel(int years) {
    final mod10 = years % 10;
    final mod100 = years % 100;
    if (mod10 == 1 && mod100 != 11) return 'год';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'года';
    }
    return 'лет';
  }

  /// Edit-mode action block: when the user has tapped "Расставить" in the
  /// toolbar, the bottom sheet replaces the social action row with this
  /// edit-focused view. The four primary relation-add buttons sit on top,
  /// then a row of secondary actions (profile / photos / history / fix).
  /// Replaces the floating inline edit panel that used to live next to
  /// each card and consumed canvas real-estate.
  Widget _buildEditModeActionBlock({
    required FamilyPerson person,
    required bool hasWarnings,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final hasGallery = person.photoGallery.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Добавить связь',
          style: AppTheme.sans(
            color: tokens.inkSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildTreeSheetAction(
                icon: Icons.north_outlined,
                label: 'Родитель',
                emphasized: true,
                onPressed: () =>
                    _handleAddRelativeFromTree(person, RelationType.parent),
              ),
              const SizedBox(width: 8),
              _buildTreeSheetAction(
                icon: Icons.favorite_border,
                label: 'Супруг',
                onPressed: () =>
                    _handleAddRelativeFromTree(person, RelationType.spouse),
              ),
              const SizedBox(width: 8),
              _buildTreeSheetAction(
                icon: Icons.south_outlined,
                label: 'Ребёнок',
                onPressed: () =>
                    _handleAddRelativeFromTree(person, RelationType.child),
              ),
              const SizedBox(width: 8),
              _buildTreeSheetAction(
                icon: Icons.people_outline,
                label: 'Сиблинг',
                onPressed: () =>
                    _handleAddRelativeFromTree(person, RelationType.sibling),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Карточка',
          style: AppTheme.sans(
            color: tokens.inkSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _buildTreeSheetAction(
                icon: Icons.open_in_new,
                label: 'Открыть',
                onPressed: () => _openPersonDetails(person),
              ),
              const SizedBox(width: 8),
              _buildTreeSheetAction(
                icon: Icons.photo_library_outlined,
                label: hasGallery
                    ? 'Фото (${person.photoGallery.length})'
                    : 'Фото',
                onPressed: hasGallery
                    ? () => _openPersonDetails(person, action: 'gallery')
                    : null,
              ),
              const SizedBox(width: 8),
              _buildTreeSheetAction(
                icon: Icons.history_outlined,
                label: 'История',
                onPressed: () => _showPersonHistorySheet(person),
              ),
              if (hasWarnings) ...[
                const SizedBox(width: 8),
                _buildTreeSheetAction(
                  icon: Icons.report_problem_outlined,
                  label: 'Починить',
                  onPressed: () =>
                      _openPersonDetails(person, action: 'relations'),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTreeSheetAction({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool emphasized = false,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final isEnabled = onPressed != null;
    final background = emphasized
        ? tokens.accent
        : tokens.surface.withValues(alpha: isEnabled ? 0.95 : 0.5);
    final foreground = emphasized
        ? tokens.accentInk
        : (isEnabled
            ? tokens.accentStrong
            : tokens.accentStrong.withValues(alpha: 0.5));

    return Material(
      color: background,
      borderRadius: BorderRadius.circular(tokens.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minWidth: 86),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: foreground),
              const SizedBox(width: 7),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showTreePersonRelationSheet(FamilyPerson person) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Добавить связь',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 4),
                Text(
                  person.displayName,
                  style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                        color:
                            Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 12),
                _buildRelationSheetTile(
                  sheetContext: sheetContext,
                  person: person,
                  icon: Icons.arrow_upward,
                  label: 'Родителя',
                  type: RelationType.parent,
                ),
                _buildRelationSheetTile(
                  sheetContext: sheetContext,
                  person: person,
                  icon: Icons.favorite_border,
                  label: 'Супруга или партнёра',
                  type: RelationType.spouse,
                ),
                _buildRelationSheetTile(
                  sheetContext: sheetContext,
                  person: person,
                  icon: Icons.arrow_downward,
                  label: 'Ребёнка',
                  type: RelationType.child,
                ),
                _buildRelationSheetTile(
                  sheetContext: sheetContext,
                  person: person,
                  icon: Icons.people_outline,
                  label: 'Брата или сестру',
                  type: RelationType.sibling,
                ),
                if (!_currentUserIsInTree)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_add_alt_1),
                    title: const Text('Добавить себя рядом с этим человеком'),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _handleAddSelfFromTree(person, RelationType.sibling);
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRelationSheetTile({
    required BuildContext sheetContext,
    required FamilyPerson person,
    required IconData icon,
    required String label,
    required RelationType type,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(label),
      onTap: () {
        Navigator.of(sheetContext).pop();
        _handleAddRelativeFromTree(person, type);
      },
    );
  }

  Widget _buildTreeState({
    required IconData icon,
    required String title,
    required String message,
    List<Widget> actions = const [],
    bool showProgress = false,
  }) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassPanel(
            padding: const EdgeInsets.all(20),
            borderRadius: BorderRadius.circular(26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (showProgress)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 14),
                    child: CircularProgressIndicator(),
                  )
                else
                  Icon(icon, size: 48, color: theme.colorScheme.primary),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (actions.isNotEmpty) ...[
                  const SizedBox(height: 16),
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

  List<PopupMenuEntry<_TreeToolbarAction>> _buildTreeToolbarMenuItems({
    bool isPhone = false,
  }) {
    final branchRootPerson = _findBranchRootPerson();
    final items = <PopupMenuEntry<_TreeToolbarAction>>[];

    // UX-T1.2 FR-c: на телефоне вторичные контролы (undo/redo/поиск/фильтры)
    // переехали из постоянных пилюль топ-бара сюда, в overflow «•••».
    // На десктопе они остаются видимыми пилюлями, поэтому здесь их не дублируем.
    if (isPhone) {
      if (GetIt.I.isRegistered<TreeMutationHistory>()) {
        final history = GetIt.I<TreeMutationHistory>();
        items.add(_buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.undo,
          icon: Icons.undo_rounded,
          label: 'Отменить',
          enabled: history.canUndo,
        ));
        items.add(_buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.redo,
          icon: Icons.redo_rounded,
          label: 'Повторить',
          enabled: history.canRedo,
        ));
      }
      if (_shouldShowSearchButton()) {
        items.add(_buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.openSearch,
          icon: Icons.search_rounded,
          label: 'Поиск в расширенной сети',
        ));
      }
      if (_shouldShowFiltersButton()) {
        items.add(_buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.openFilters,
          icon: Icons.tune_rounded,
          label: 'Фильтры расширенной сети',
        ));
      }
      if (items.isNotEmpty) {
        items.add(const PopupMenuDivider());
      }
    }

    items.addAll([
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.refresh,
        icon: Icons.refresh,
        label: 'Обновить дерево',
      ),
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.openHistory,
        icon: Icons.history_outlined,
        label: 'История изменений',
      ),
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.sendDiagnostics,
        icon: Icons.bug_report_outlined,
        label: 'Отправить диагностику дерева',
      ),
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.openChats,
        icon: Icons.forum_outlined,
        label: 'Открыть чаты',
      ),
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.createPost,
        icon: Icons.post_add_outlined,
        label: _isFriendsTree ? 'Пост в круг' : 'Новый пост',
      ),
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.toggleEditMode,
        icon: _isEditMode ? Icons.edit_off_outlined : Icons.edit_outlined,
        label: _isEditMode
            ? 'Выключить перемещение карточек'
            : 'Включить перемещение карточек',
      ),
      _buildTreeToolbarMenuItem(
        value: _TreeToolbarAction.toggleSelectionMode,
        icon: _isSelectionMode
            ? Icons.check_box_outlined
            : Icons.check_box_outline_blank,
        label: _isSelectionMode
            ? 'Выйти из режима выбора'
            : 'Выбрать несколько человек',
      ),
    ]);

    if (branchRootPerson != null) {
      items.add(
        _buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.openBranchChat,
          icon: Icons.alt_route_outlined,
          label: _isFriendsTree ? 'Написать кругу' : 'Написать ветке',
        ),
      );
      items.add(
        _buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.openBranchDetails,
          icon: Icons.open_in_new,
          label: _isFriendsTree
              ? 'Открыть карточку круга'
              : 'Открыть карточку ветки',
        ),
      );
    }

    if (_branchRootPersonId != null) {
      items.add(
        _buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.resetBranchFocus,
          icon: Icons.clear_all,
          label: _isFriendsTree ? 'Показать весь граф' : 'Показать всё дерево',
        ),
      );
    }

    if (_currentTreeMeta?.isPublic == true) {
      items.add(
        _buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.copyPublicLink,
          icon: Icons.link_outlined,
          label: 'Скопировать публичную ссылку',
        ),
      );
    }

    if (_manualNodePositions.isNotEmpty) {
      items.add(
        _buildTreeToolbarMenuItem(
          value: _TreeToolbarAction.resetLayout,
          icon: Icons.restart_alt,
          label: 'Сбросить ручную раскладку',
        ),
      );
    }

    return items;
  }

  PopupMenuItem<_TreeToolbarAction> _buildTreeToolbarMenuItem({
    required _TreeToolbarAction value,
    required IconData icon,
    required String label,
    bool enabled = true,
  }) {
    return PopupMenuItem<_TreeToolbarAction>(
      value: value,
      enabled: enabled,
      child: Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(label)),
        ],
      ),
    );
  }

  /// Bulk «Add to branch» action: opens a bottom sheet listing every
  /// other branch the user belongs to, lets them pick one, and then
  /// copies each selected person into that branch via the existing
  /// cross-tree create-person flow (one POST per person, each with
  /// `sourcePersonId` so the new card shares an `identityId` with
  /// the original — we get identity propagation across trees as a
  /// side-effect of copying).
  ///
  /// Failures fall through to a snackbar with a count of successes
  /// so the user knows what landed and what didn't. Selection is
  /// cleared on success only — partial failures keep the unfinished
  /// people selected so the user can retry.
  Future<void> _openBulkAddToBranchSheet() async {
    if (!_isSelectionMode) return;
    if (_selectedPersonIds.isEmpty) return;
    final sourceTreeId = _currentTreeId;
    if (sourceTreeId == null) return;

    final messenger = ScaffoldMessenger.of(context);
    // Fetch the user's trees fresh from the service. TreeProvider
    // caches availableTrees but only fills the cache after the
    // user explicitly opens the BranchSwitcher / hits the
    // selector — and bulk-add can fire before either of those,
    // which would falsely report "Нужна вторая ветка". Going
    // straight to the service guarantees we see every branch the
    // viewer actually owns.
    List<FamilyTree> allTrees;
    try {
      allTrees = await _familyService.getUserTrees();
    } catch (error) {
      debugPrint('Bulk add-to-branch: failed to fetch user trees: $error');
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content:
              Text('Не удалось загрузить список веток. Попробуйте ещё раз.'),
        ),
      );
      return;
    }
    if (!mounted) return;
    // Side-effect: keep TreeProvider's cache in sync so the next
    // BranchSwitcher open is instant.
    Provider.of<TreeProvider>(context, listen: false).refreshAvailableTrees();
    final candidates = allTrees
        .where((tree) => tree.id != sourceTreeId)
        .toList(growable: false);
    if (candidates.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Нужна вторая ветка — создайте её сначала.'),
        ),
      );
      return;
    }

    final FamilyTree? target = await showModalBottomSheet<FamilyTree>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(sheetContext).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Добавить ${_selectedPersonIds.length} в ветку',
                  style: Theme.of(sheetContext).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Эти люди появятся в выбранной ветке как карточки. '
                  'Связи между ними нужно будет соединить вручную.',
                  style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                        color:
                            Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 14),
                for (final tree in candidates)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor:
                          Theme.of(sheetContext).colorScheme.primary,
                      child: Icon(
                        tree.isFriendsTree
                            ? Icons.diversity_3_outlined
                            : Icons.account_tree,
                        color: Colors.white,
                      ),
                    ),
                    title: Text(
                      tree.name,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      tree.isPrivate ? 'Приватная' : 'Публичная',
                      style: Theme.of(sheetContext).textTheme.bodySmall,
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(sheetContext).pop(tree),
                  ),
              ],
            ),
          ),
        );
      },
    );

    if (target == null || !mounted) return;
    await _runBulkAddToBranch(targetTree: target);
  }

  Future<void> _runBulkAddToBranch({required FamilyTree targetTree}) async {
    final messenger = ScaffoldMessenger.of(context);
    final sourceTreeId = _currentTreeId;
    if (sourceTreeId == null) return;
    final selectedIds = List<String>.from(_selectedPersonIds);

    final service = _familyService;
    if (service is! BulkImportCapableFamilyTreeService) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Этот сервис пока не умеет переносить нескольких людей сразу.',
          ),
        ),
      );
      return;
    }
    // Explicit local cast — the `is!` check above is enough at the
    // type-system level, but extension-method scopes don't always
    // promote a final-field reference, so an explicit binding makes
    // the call sites work uniformly across compilers.
    final bulkImporter = service as BulkImportCapableFamilyTreeService;

    try {
      final result = await bulkImporter.bulkImportPersonsToTree(
        sourceTreeId: sourceTreeId,
        targetTreeId: targetTree.id,
        sourcePersonIds: selectedIds,
      );
      if (!mounted) return;
      _updateSectionState(() {
        _selectedPersonIds.clear();
        _isSelectionMode = false;
      });
      final relations = result.bridgedRelationCount;
      final personsLanded = result.persons.length;
      // Two cases worth distinguishing:
      // - Everyone was already in target via identity (personsLanded
      //   == 0): say so explicitly. Otherwise the user pokes the
      //   button, sees "0", and assumes failure.
      // - Some landed and some relations bridged: surface both
      //   counts so the «связь со мной» case feels visible.
      String message;
      if (personsLanded == 0 && relations == 0) {
        message = 'Эти люди уже есть в «${targetTree.name}» — там та же родня.';
      } else if (relations > 0) {
        message =
            'Добавлено в «${targetTree.name}»: $personsLanded • связей подтянулось: $relations';
      } else {
        message = 'Добавлено в «${targetTree.name}»: $personsLanded';
      }
      messenger.showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      debugPrint('Bulk import to ${targetTree.id} failed: $error');
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Не удалось перенести людей в «${targetTree.name}». Попробуйте ещё раз.',
          ),
        ),
      );
    }
  }

  /// Bottom toolbar shown over the canvas while the user is in
  /// multi-select mode. Surfaces the selection count and the bulk
  /// action ("Add to branch…") + a "Done" exit button. Replaces the
  /// regular per-person bottom sheet so the user always sees a
  /// single coherent action surface — never both at once.
  Widget _buildSelectionToolbar({
    required Key key,
    required Color accent,
  }) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final count = _selectedPersonIds.length;
    final hasSelection = count > 0;
    return Material(
      key: key,
      elevation: 6,
      borderRadius: BorderRadius.circular(20),
      color: tokens.surface.withValues(alpha: 0.96),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.18),
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(Icons.check_box_outlined, size: 20, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    hasSelection ? 'Выбрано: $count' : 'Режим выбора',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: tokens.ink,
                    ),
                  ),
                  Text(
                    hasSelection
                        ? 'Тап — добавить/убрать. Палочка — расширить по линии.'
                        : 'Тап — выбрать одну карточку. Drag по пустому холсту — выделить лассо.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: tokens.inkSecondary,
                      height: 1.3,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // «Расширить» — smart selection. Tap once on Mama,
            // tap «По её линии» → toolbar swallows all of mama's
            // ancestors + their descendants into the selection
            // set. Saves the user from individually tapping ~30
            // relatives when they want a slice like «мамина линия».
            // Disabled when the selection is empty (nothing to
            // expand from); always enabled when ≥1 person picked.
            PopupMenuButton<_SelectionExpand>(
              tooltip: 'Расширить выбор',
              enabled: hasSelection,
              onSelected: _handleSelectionExpand,
              itemBuilder: (_) => const <PopupMenuEntry<_SelectionExpand>>[
                PopupMenuItem<_SelectionExpand>(
                  value: _SelectionExpand.ancestors,
                  child: Row(
                    children: [
                      Icon(Icons.arrow_upward_rounded, size: 18),
                      SizedBox(width: 10),
                      Expanded(child: Text('Все предки выделенных')),
                    ],
                  ),
                ),
                PopupMenuItem<_SelectionExpand>(
                  value: _SelectionExpand.descendants,
                  child: Row(
                    children: [
                      Icon(Icons.arrow_downward_rounded, size: 18),
                      SizedBox(width: 10),
                      Expanded(child: Text('Все потомки выделенных')),
                    ],
                  ),
                ),
                PopupMenuItem<_SelectionExpand>(
                  value: _SelectionExpand.lineage,
                  child: Row(
                    children: [
                      Icon(Icons.account_tree_outlined, size: 18),
                      SizedBox(width: 10),
                      Expanded(child: Text('Вся эта линия')),
                    ],
                  ),
                ),
              ],
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: hasSelection
                      ? accent.withValues(alpha: 0.18)
                      : tokens.surfaceLine,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.auto_fix_high_outlined,
                  size: 20,
                  color: hasSelection ? accent : tokens.inkMuted,
                ),
              ),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: hasSelection ? _openBulkAddToBranchSheet : null,
              icon: const Icon(Icons.account_tree_outlined, size: 18),
              label: const Text('В ветку…'),
            ),
            const SizedBox(width: 6),
            IconButton(
              tooltip: 'Закрыть режим выбора',
              onPressed: () {
                _updateSectionState(() {
                  _isSelectionMode = false;
                  _selectedPersonIds.clear();
                });
              },
              icon: const Icon(Icons.close_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
