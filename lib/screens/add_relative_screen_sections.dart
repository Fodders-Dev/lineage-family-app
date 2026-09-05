part of 'add_relative_screen.dart';

extension _AddRelativeScreenSections on _AddRelativeScreenState {
  Widget _buildEditMediaAndHistoryCard() {
    final theme = Theme.of(context);
    final person = widget.person!;
    final mediaCount = person.photoGallery.length;
    final hasPrimaryPhoto = person.primaryPhotoUrl != null;
    final photoActionLabel = mediaCount == 0 ? 'Медиа' : 'Медиа ($mediaCount)';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.perm_media_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Медиа и история',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _QuickInfoChip(
                icon: Icons.photo_library_outlined,
                label: mediaCount == 0 ? 'Без медиа' : '$mediaCount в карточке',
              ),
              _QuickInfoChip(
                icon: hasPrimaryPhoto
                    ? Icons.star_outline
                    : Icons.image_not_supported_outlined,
                label: hasPrimaryPhoto
                    ? 'Основное фото есть'
                    : 'Основное фото не выбрано',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            _draftMedia.isEmpty
                ? 'Основные факты редактируются здесь, а карточка и журнал открываются отдельными действиями.'
                : 'После сохранения в карточку уйдут и новые поля, и добавленные фото/видео.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Открыть карточку'),
                onPressed: _openEditingPersonCard,
              ),
              ActionChip(
                avatar: const Icon(Icons.photo_library_outlined, size: 18),
                label: Text(photoActionLabel),
                onPressed: _openEditingPersonCard,
              ),
              ActionChip(
                avatar: const Icon(Icons.history_outlined, size: 18),
                label: const Text('История'),
                onPressed: () => _showEditingPersonHistorySheet(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _buildScreenTitle() {
    if (widget.isEditing) {
      return 'Редактирование родственника';
    }
    if (_isCreatingFirstPerson) {
      return 'Первый человек в дереве';
    }
    if (widget.relatedTo != null) {
      return 'Добавление родственника к ${widget.relatedTo!.name}';
    }
    return 'Добавление родственника';
  }

  /// Плотность (чанк 13): заголовок секции формы («Пол», «Родственная
  /// связь») — тот же стиль, что и заголовок секции в карточке человека
  /// (AppTheme.serif 18 w700), с компактными отступами 12 сверху / 6
  /// снизу вместо прежних SizedBox(24) до и после ad-hoc bold-текста.
  Widget _buildFormSectionHeader(String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 6),
      child: Text(
        text,
        style: AppTheme.serif(
          color: theme.colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// F1: одна компактная строка контекста вместо трёх карточек-простыней
  /// (intro + «Что нужно сейчас» + «Режим заполнения»). Показывается
  /// только когда несёт смысл; обычное добавление обходится без неё —
  /// заголовок экрана уже всё говорит.
  Widget _buildContextLine() {
    final theme = Theme.of(context);
    final anchorPerson = _anchorPerson;
    final relationType = _resolvedRelationType;

    final String? line = _isCreatingFirstPerson
        ? 'Сначала достаточно имени и пола — остальное можно добавить позже.'
        : (anchorPerson != null && relationType != null)
            ? 'Связь с ${anchorPerson.name} уже выбрана: '
                '${_relationTypeToActionObject(relationType)}.'
            : _canUseQuickAddLoop
                ? 'Серия добавлений: после сохранения можно сразу внести следующего.'
                : null;
    if (line == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              line,
              style: TextStyle(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// F2: даты союза — «Дата свадьбы» для всех союзных типов, «Дата
  /// развода» сразу для бывших (ex_spouse/ex_partner) или по «+ Дата
  /// развода» для текущих (брак был — закончился, тип менять не надо).
  List<Widget> _buildUnionDateFields() {
    final type = _resolvedRelationType;
    final bool isUnion = type == RelationType.spouse ||
        type == RelationType.partner ||
        type == RelationType.ex_spouse ||
        type == RelationType.ex_partner;
    if (!isUnion) return const [];

    final bool isPastUnion =
        type == RelationType.ex_spouse || type == RelationType.ex_partner;
    // B2 (ревью FR7): в узловом флоу для ТЕКУЩИХ союзов (spouse/partner)
    // дату расставания вводит селектор статуса союза
    // (_buildUnionStatusSelector). Чтобы не было ДВУХ входов для одной
    // даты — здесь поле даты развода не рисуем (оставляем только свадьбу).
    final bool statusSelectorOwnsSeparation = _isUnionStatusSelectorShown;
    final bool showDivorceField = !statusSelectorOwnsSeparation &&
        (isPastUnion || _showDivorceDateField || _divorceDate != null);

    return [
      const SizedBox(height: 16),
      InkWell(
        onTap: _pickMarriageDate,
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Дата свадьбы',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.favorite_outline),
            helperText: 'Попадёт в семейный календарь',
          ),
          child: Text(
            _marriageDate != null
                ? DateFormat('dd.MM.yyyy').format(_marriageDate!)
                : 'Не указано',
          ),
        ),
      ),
      if (!statusSelectorOwnsSeparation) ...[
        const SizedBox(height: 16),
        if (showDivorceField)
          InkWell(
            key: const Key('divorce-date-field'),
            onTap: _pickDivorceDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Дата развода',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.heart_broken_outlined),
              ),
              child: Text(
                _divorceDate != null
                    ? DateFormat('dd.MM.yyyy').format(_divorceDate!)
                    : 'Не указано',
              ),
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('divorce-date-add'),
              onPressed: () {
                _updateSectionState(() {
                  _showDivorceDateField = true;
                });
              },
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Дата развода'),
            ),
          ),
      ],
    ];
  }

  /// F1: дата смерти — в основном потоке рядом с датой рождения (раньше
  /// пряталась в «Расширенно», и владельцу приходилось её искать).
  Widget _buildDeathDateField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_deathDateYearOnly)
          TextFormField(
            key: const Key('death-year-field'),
            controller: _deathYearController,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(
              labelText: 'Год смерти',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.event_outlined),
              counterText: '',
              helperText: 'Если человек жив — оставьте пустым',
            ),
            validator: (value) => _validateYearInput(value, required: false),
          )
        else
          InkWell(
            onTap: () => _pickDate(false),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Дата смерти',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.event_outlined),
                helperText: 'Если человек жив — оставьте пустым',
              ),
              child: Text(
                _deathDate != null
                    ? DateFormat('dd.MM.yyyy').format(_deathDate!)
                    : 'Не указано',
              ),
            ),
          ),
        _buildYearOnlyToggle(
          key: const Key('death-year-only-toggle'),
          value: _deathDateYearOnly,
          onChanged: (checked) {
            _updateSectionState(() {
              _deathDateYearOnly = checked;
              if (checked && _deathDate != null) {
                _deathYearController.text = _deathDate!.year.toString();
              }
            });
          },
        ),
      ],
    );
  }

  Widget _buildBirthDateField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_birthDateYearOnly)
          TextFormField(
            key: const Key('birth-year-field'),
            controller: _birthYearController,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(
              labelText: 'Год рождения',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.cake_outlined),
              counterText: '',
              helperText: 'Точный день неизвестен — достаточно года',
            ),
            validator: (value) => _validateYearInput(value, required: false),
          )
        else
          InkWell(
            onTap: () => _pickDate(true),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Дата рождения',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.cake_outlined),
                helperText: 'Нужна для дней рождения на главной',
              ),
              child: Text(
                _birthDate != null
                    ? DateFormat('dd.MM.yyyy').format(_birthDate!)
                    : 'Выберите дату',
              ),
            ),
          ),
        _buildYearOnlyToggle(
          key: const Key('birth-year-only-toggle'),
          value: _birthDateYearOnly,
          onChanged: (checked) {
            _updateSectionState(() {
              _birthDateYearOnly = checked;
              if (checked && _birthDate != null) {
                _birthYearController.text = _birthDate!.year.toString();
              }
            });
          },
        ),
      ],
    );
  }

  /// F5: компактный тумблер «Знаю только год» — у части предков известен
  /// только год, и заставлять выбирать фейковое 1 января нельзя (от него
  /// шумят календарь и карточки).
  Widget _buildYearOnlyToggle({
    required Key key,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return InkWell(
      key: key,
      borderRadius: BorderRadius.circular(10),
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: Checkbox(
                value: value,
                onChanged: (checked) => onChanged(checked ?? false),
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'Знаю только год',
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  /// F5: валидация года (4 цифры, 1000..текущий).
  String? _validateYearInput(String? value, {required bool required}) {
    final trimmed = value?.trim() ?? '';
    if (trimmed.isEmpty) {
      return required ? 'Укажите год' : null;
    }
    final year = int.tryParse(trimmed);
    if (year == null || year < 1000 || year > DateTime.now().year) {
      return 'Год от 1000 до ${DateTime.now().year}';
    }
    return null;
  }

  Widget _buildMediaSection() {
    final theme = Theme.of(context);
    final existingCount = _existingMediaEntries.length;
    final queuedCount = _draftMedia.length;
    final hasExistingPrimary = _existingMediaEntries.any(
      (entry) => entry['isPrimary'] == true,
    );
    final summary = <String>[
      if (existingCount > 0) '$existingCount в карточке',
      if (queuedCount > 0) '$queuedCount в очереди',
      if (existingCount == 0 && queuedCount == 0) 'пока пусто',
    ].join(' · ');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.36),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.perm_media_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Фото и видео',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (_isUpdatingMedia)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _QuickInfoChip(
                icon: Icons.photo_library_outlined,
                label: summary,
              ),
              _QuickInfoChip(
                icon: hasExistingPrimary ||
                        _draftMedia.any((entry) => entry.isPrimary)
                    ? Icons.star_outline
                    : Icons.image_not_supported_outlined,
                label: hasExistingPrimary ||
                        _draftMedia.any((entry) => entry.isPrimary)
                    ? 'Основное медиа выбрано'
                    : 'Основное медиа ещё не выбрано',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: _isUpdatingMedia
                    ? null
                    : () => _pickRelativeMedia(video: false),
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Фото'),
              ),
              FilledButton.tonalIcon(
                onPressed: _isUpdatingMedia
                    ? null
                    : () => _pickRelativeMedia(video: true),
                icon: const Icon(Icons.video_library_outlined),
                label: const Text('Видео'),
              ),
              if (widget.isEditing && widget.person != null)
                ActionChip(
                  avatar: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Открыть карточку'),
                  onPressed: _openEditingPersonCard,
                ),
            ],
          ),
          if (_draftMedia.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _draftMedia
                  .map(
                    (entry) => InputChip(
                      avatar: Icon(entry.icon, size: 18),
                      label: Text(
                        '${entry.label}: ${entry.file.name}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onDeleted: () => _removeDraftMedia(entry.id),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAdvancedHintCard() {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.library_add_check_outlined,
              color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // F1: один короткий тизер вместо перечисления.
              'Биография, места и события',
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(width: 10),
          TextButton(
            onPressed: () {
              _updateSectionState(() {
                _editorMode = _RelativeEditorMode.advanced;
              });
            },
            child: const Text('Показать'),
          ),
        ],
      ),
    );
  }

  Widget _buildImportantEventsSection() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Важные события',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _addImportantEventDraft,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Событие'),
            ),
          ],
        ),
        if (_importantEventDrafts.isEmpty)
          Text(
            'Сюда можно добавить семейные даты, которые должны появляться на главной.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          )
        else
          Column(
            children: _importantEventDrafts.map((draft) {
              return Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: Column(
                    children: [
                      TextFormField(
                        controller: draft.titleController,
                        decoration: InputDecoration(
                          labelText: 'Название события',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.event_note_outlined),
                          suffixIcon: IconButton(
                            tooltip: 'Удалить событие',
                            onPressed: () => _removeImportantEventDraft(draft),
                            icon: const Icon(Icons.close),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        onTap: () => _pickImportantEventDate(draft),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Дата события',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.calendar_today_outlined),
                          ),
                          child: Text(
                            draft.date != null
                                ? DateFormat('dd.MM.yyyy').format(draft.date!)
                                : 'Выберите дату',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  Widget _buildOptionalDetailsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Расширенные сведения',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        const SizedBox(height: 16),
        if (_selectedGender == Gender.female) ...[
          TextFormField(
            controller: _maidenNameController,
            decoration: const InputDecoration(
              labelText: 'Девичья фамилия',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
            ),
          ),
          const SizedBox(height: 16),
        ],
        ..._buildUnionDateFields(),
        const SizedBox(height: 16),
        TextFormField(
          controller: _birthPlaceController,
          decoration: const InputDecoration(
            labelText: 'Место рождения',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.location_on_outlined),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _educationController,
          decoration: const InputDecoration(
            labelText: 'Образование',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.school_outlined),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _bioController,
          decoration: const InputDecoration(
            labelText: 'Семейная справка',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.badge_outlined),
          ),
          maxLines: 4,
        ),
        const SizedBox(height: 20),
        _buildImportantEventsSection(),
      ],
    );
  }

  // ── Phase 0 cross-tree person picker ───────────────────────────────
  // Surfaces relatives the user already entered on any of their other
  // trees so they don't have to re-key the same human. Pick → form
  // pre-fills + we stash the source person id for the create POST.

  bool get _isOtherTreesPickerAvailable {
    if (widget.isEditing) return false;
    return _familyService is CrossTreePersonSearchCapableFamilyTreeService;
  }

  void _onOtherTreesSearchChanged(String value) {
    _otherTreesSearchDebounce?.cancel();
    final trimmed = value.trim();
    if (trimmed == _otherTreesSearchQuery) {
      // No semantic change (e.g. trailing-space tweak) — skip.
      return;
    }
    _otherTreesSearchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _runOtherTreesSearch(trimmed),
    );
  }

  Future<void> _runOtherTreesSearch(String query) async {
    if (!mounted) return;
    final service = _familyService;
    if (service is! CrossTreePersonSearchCapableFamilyTreeService) return;
    // Explicit cast — Dart's flow analyzer doesn't promote field
    // accesses across `await`, and this is an extension method so
    // the local `is`-narrowing isn't preserved either.
    final searchService =
        service as CrossTreePersonSearchCapableFamilyTreeService;

    _updateSectionState(() {
      _otherTreesSearchQuery = query;
      _isSearchingOtherTrees = true;
    });

    try {
      final results = await searchService.searchPersonsAcrossOwnTrees(
        query: query,
        excludeTreeId: widget.treeId,
      );
      if (!mounted) return;
      // Drop late results if the user has typed past this query — we
      // only care about the latest. Cheap optimistic check.
      if (query != _otherTreesSearchQuery) return;
      _updateSectionState(() {
        _otherTreesSearchResults = results;
        _isSearchingOtherTrees = false;
      });
    } catch (error) {
      if (!mounted) return;
      _updateSectionState(() {
        _isSearchingOtherTrees = false;
        _otherTreesSearchResults = const <CrossTreePersonSuggestion>[];
      });
      // Soft-fail: the picker is an aid, not a critical path. Show
      // a toast so the user knows search didn't land, but don't
      // block them from filling the form by hand.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(humanizeError(error,
              fallback: 'Не удалось загрузить родственников.')),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _onPickOtherTreePerson(CrossTreePersonSuggestion picked) {
    // Source persons store a composed display name "Фамилия Имя
    // Отчество" — split into form fields the same way the editing
    // path does (initState block in the main class).
    final parts = picked.displayName.trim().split(RegExp(r'\s+'));
    final lastName = parts.isNotEmpty ? parts[0] : '';
    final firstName = parts.length >= 2 ? parts[1] : '';
    final middleName = parts.length >= 3 ? parts.sublist(2).join(' ') : '';

    _updateSectionState(() {
      _sourcePersonId = picked.id;
      _sourcePersonTreeName = picked.treeName;
      _lastNameController.text = lastName;
      _firstNameController.text = firstName;
      _middleNameController.text = middleName;
      if (picked.gender == 'female') {
        _selectedGender = Gender.female;
      } else if (picked.gender == 'male') {
        _selectedGender = Gender.male;
      }
      if (picked.birthDate != null && picked.birthDate!.isNotEmpty) {
        _birthDate = DateTime.tryParse(picked.birthDate!);
      }
      // Collapse the picker so the user can focus on the form
      // fields. The "linked" chip stays visible above to remind
      // them what they did and let them undo.
      _otherTreesSearchResults = const <CrossTreePersonSuggestion>[];
      _otherTreesSearchController.clear();
      _otherTreesSearchQuery = '';
      _otherTreesPickerExpanded = false;
    });

    // UX shortcut: when the user is adding a relative WITH a known
    // relation context (came in via "+ Add as parent / spouse /
    // child / sibling" on a tree node), pick = ONE TAP commit. No
    // need to make them tap save again — they've already told us
    // who this is AND the relation. Schedule the save on the next
    // microtask so the setState above has flushed and the form
    // controllers see the new values when validate() runs.
    if (_isContextualAdd && _resolvedRelationType != null) {
      Future<void>.microtask(() {
        if (!mounted) return;
        _savePerson();
      });
    }
  }

  void _clearOtherTreesPick() {
    _updateSectionState(() {
      _sourcePersonId = null;
      _sourcePersonTreeName = null;
      // We DON'T clear the form fields — the user might still want
      // the pre-filled values, just without the cross-tree link.
    });
  }

  Widget _buildOtherTreesPickerCard() {
    if (!_isOtherTreesPickerAvailable) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // When a source is already linked, the card collapses into a
    // single-row "linked from {treeName}" chip with an X. Reduces
    // visual weight after the user has made their choice.
    if (_sourcePersonId != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.link, size: 18, color: scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _sourcePersonTreeName == null || _sourcePersonTreeName!.isEmpty
                    ? 'Связан с человеком из вашего другого дерева'
                    : 'Связан с человеком из «$_sourcePersonTreeName»',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurface,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Отвязать',
              onPressed: _clearOtherTreesPick,
              icon: const Icon(Icons.close_rounded, size: 18),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      );
    }

    // No source picked yet — collapsible search section. Default
    // collapsed because the form below is still the primary path
    // for users with a single tree.
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () {
              _updateSectionState(() {
                _otherTreesPickerExpanded = !_otherTreesPickerExpanded;
              });
              if (_otherTreesPickerExpanded &&
                  _otherTreesSearchResults.isEmpty &&
                  !_isSearchingOtherTrees) {
                // Lazy initial fetch on first expand — shows the
                // picker as already-populated for users with other
                // trees, while users with no other trees see the
                // "ничего не найдено" empty state on first try.
                _runOtherTreesSearch('');
              }
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree_outlined,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 10),
                  // F1: компактная строка-ссылка — второстепенный сценарий
                  // не встречает пользователя простынёй.
                  Expanded(
                    child: Text(
                      'Уже есть в другом дереве?',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    'Найти',
                    style: TextStyle(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Icon(
                    _otherTreesPickerExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (_otherTreesPickerExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _otherTreesSearchController,
                    onChanged: _onOtherTreesSearchChanged,
                    decoration: InputDecoration(
                      hintText: 'Имя или фамилия',
                      prefixIcon: const Icon(Icons.search),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_isSearchingOtherTrees)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (_otherTreesSearchResults.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _otherTreesSearchQuery.isEmpty
                            ? 'У вас пока нет родственников в других деревьях. Добавьте их из формы ниже.'
                            : 'Никого не нашлось. Добавьте новую карточку из формы ниже.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    )
                  else
                    Column(
                      children: [
                        for (final suggestion in _otherTreesSearchResults)
                          _OtherTreesPickerRow(
                            suggestion: suggestion,
                            onTap: () => _onPickOtherTreePerson(suggestion),
                          ),
                      ],
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _disposeExtractedControllers() {
    _lastNameController.removeListener(_updateRelationshipWidget);
    _firstNameController.removeListener(_updateRelationshipWidget);
    _lastNameController.dispose();
    _firstNameController.dispose();
    _middleNameController.dispose();
    _maidenNameController.dispose();
    _birthPlaceController.dispose();
    _educationController.dispose();
    _bioController.dispose();
    _notesController.dispose();
    _birthYearController.dispose();
    _deathYearController.dispose();
    _otherTreesSearchController.dispose();
    _otherTreesSearchDebounce?.cancel();
    for (final draft in _importantEventDrafts) {
      draft.dispose();
    }
  }

  Widget _buildRelationshipSelector() {
    // Используем _contextPerson если он есть, иначе widget.relatedTo
    final FamilyPerson? anchorPerson = _anchorPerson;
    final bool addingFromContext = _contextPerson != null;
    final bool isEditingMode = widget.isEditing;
    final bool isAddingToSelf = anchorPerson == null && !isEditingMode;
    final RelationType? fixedRelationType =
        _contextRelationType ?? widget.predefinedRelation;
    final bool hasFixedRelation =
        anchorPerson != null && fixedRelationType != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFormSectionHeader('Родственная связь'),

        // ---- Виджет связи с КОНКРЕТНЫМ человеком (контекстным или relatedTo) ----
        if (anchorPerson != null)
          hasFixedRelation
              ? _buildFixedRelationshipCard(
                  anchorPerson: anchorPerson,
                  relationType: fixedRelationType,
                  addingFromContext: addingFromContext,
                )
              : _buildEditableRelationshipCard(anchorPerson: anchorPerson),

        SizedBox(height: 24),

        // ---- Виджет связи с ТЕКУЩИМ ПОЛЬЗОВАТЕЛЕМ (если нет anchorPerson ИЛИ режим редактирования) ----
        // Плотность (чанк 13): раньше здесь дублировался вопрос «Кем этот
        // человек является для вас?» ПРЯМО над полем с подписью
        // «Родственная связь с вами» — одна и та же мысль дважды. Подпись
        // самого поля уже несёт этот смысл, отдельный вопрос убран.
        if (anchorPerson == null || isEditingMode)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<RelationType>(
                initialValue: _selectedRelationType,
                decoration: InputDecoration(
                  labelText: _isCreatingFirstPerson
                      ? 'Связь с вами, если хотите указать сразу'
                      : 'Родственная связь с вами',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.family_restroom),
                  helperText: _isCreatingFirstPerson
                      ? 'Поле необязательное. Связать себя с деревом можно позже прямо из схемы.'
                      : null,
                ),
                // Передаем пол ТЕКУЩЕГО пользователя для фильтрации
                items: _getRelationTypeItems(_gender), // Используем _gender
                onChanged: (newValue) {
                  _updateSectionState(() {
                    _selectedRelationType = newValue;
                    _clearStaleSeparationOnTypeChange(newValue);
                    // Предзаполняем пол нового на основе связи с пользователем
                    // Создаем временный объект FamilyPerson для текущего пользователя
                    final currentUserAsPerson = FamilyPerson(
                      id: _authService.currentUserId ?? '',
                      treeId: widget.treeId,
                      name: 'Вы', // Имя не так важно здесь
                      gender: _gender,
                      isAlive: true, // Предполагаем
                      createdAt: DateTime.now(),
                      updatedAt: DateTime.now(),
                    );
                    _prefillGenderBasedOnRelation(
                      currentUserAsPerson,
                      newValue,
                    );
                  });
                },
                validator: (value) {
                  // Валидация нужна только если добавляем к себе
                  if (isAddingToSelf &&
                      !_isCreatingFirstPerson &&
                      value == null) {
                    return 'Пожалуйста, выберите родственную связь';
                  }
                  return null;
                },
              ),
              SizedBox(height: 24), // Добавим отступ
            ],
          ),
      ],
    );
  }

  // Обновляем _getRelationTypeDescription для использования FamilyRelation
  String _getRelationTypeDescription(RelationType type) {
    // Используем пол НОВОГО человека (_selectedGender)
    return FamilyRelation.getRelationDescription(type, _selectedGender);
  }

  Widget _buildFixedRelationshipCard({
    required FamilyPerson anchorPerson,
    required RelationType relationType,
    required bool addingFromContext,
  }) {
    final theme = Theme.of(context);
    final relationText = _getRelationTypeDescription(relationType);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.family_restroom, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Связь уже определена',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  relationText,
                  style: TextStyle(
                    color: theme.colorScheme.onPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              CircleAvatar(
                backgroundColor: anchorPerson.gender == Gender.male
                    ? Colors.blue.shade100
                    : Colors.pink.shade100,
                child: Icon(
                  Icons.person,
                  color: anchorPerson.gender == Gender.male
                      ? Colors.blue
                      : Colors.pink,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      anchorPerson.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      addingFromContext
                          ? 'Новый человек будет добавлен относительно этой карточки'
                          : 'Связь для нового человека уже выбрана',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            addingFromContext
                ? 'После сохранения схема обновится автоматически.'
                : 'Если нужно другое родство, вернитесь и выберите другое действие из дерева.',
            style: TextStyle(
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
          // B2: для союзных связей (супруг/партнёр) — статус союза прямо в
          // узловом флоу, чтобы можно было добавить БЫВШЕГО супруга/
          // партнёра любому узлу, не плодя типы в пикере. Условие держим в
          // общем геттере — им же гасим дубль даты развода в блоке дат
          // союза (ревью FR7).
          if (_isUnionStatusSelectorShown) _buildUnionStatusSelector(),
        ],
      ),
    );
  }

  /// B2: статус союза + необязательная дата расставания. Пишем в
  /// существующее поле unionStatus: current/past/ended_by_death.
  /// Виден только для союзных связей.
  Widget _buildUnionStatusSelector() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        Text(
          'Статус союза',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ChoiceChip(
              key: const Key('union-status-together'),
              label: const Text('Вместе'),
              selected: _unionStatus == _UnionStatusDraft.current,
              onSelected: (_) => _updateSectionState(() {
                // B2 (ревью FR6): возврат в «Вместе» сбрасывает дату
                // расставания и статус — иначе остаточная дата заставит
                // бэк нормализовать unionStatus в 'past' и записать
                // текущего супруга бывшим.
                _unionStatus = _UnionStatusDraft.current;
                _divorceDate = null;
              }),
            ),
            ChoiceChip(
              key: const Key('union-status-separated'),
              label: const Text('Расстались'),
              selected: _unionStatus == _UnionStatusDraft.separated,
              onSelected: (_) => _updateSectionState(() {
                _unionStatus = _UnionStatusDraft.separated;
              }),
            ),
            ChoiceChip(
              key: const Key('union-status-ended-by-death'),
              label: const Text('До смерти'),
              selected: _unionStatus == _UnionStatusDraft.endedByDeath,
              onSelected: (_) => _updateSectionState(() {
                _unionStatus = _UnionStatusDraft.endedByDeath;
                _divorceDate = null;
              }),
            ),
          ],
        ),
        if (_unionStatusNeedsSeparationDate) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            key: const Key('union-divorce-date'),
            onPressed: _pickDivorceDate,
            icon: const Icon(Icons.event_outlined),
            label: Text(
              _divorceDate == null
                  ? 'Дата расставания (необязательно)'
                  : 'Расстались: ${_divorceDate!.day.toString().padLeft(2, '0')}.'
                      '${_divorceDate!.month.toString().padLeft(2, '0')}.'
                      '${_divorceDate!.year}',
            ),
          ),
        ],
      ],
    );
  }

  // F1: «Режим быстрого ввода»-карточка удалена — её смысл (серия
  // добавлений + якорь + связь) ужат в одну контекст-строку сверху, а
  // кнопки серии и так живут в submit-блоке.

  /// P1b: главный «Сохранить» переехал в закреплённый нижний бар
  /// ([_buildPinnedSubmitBar]) — виден всегда, а не за скроллом. Здесь
  /// остаются альтернативные quick-add действия + подсказка.
  Widget _buildSubmitSection() {
    return Column(
      children: [
        if (_canUseQuickAddLoop)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _isBusy
                    ? null
                    : () => _savePerson(action: _PostSaveAction.stayInQuickAdd),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Добавить ещё одного'),
              ),
              OutlinedButton.icon(
                onPressed: _isBusy
                    ? null
                    : () => _savePerson(action: _PostSaveAction.openInTree),
                icon: const Icon(Icons.account_tree_outlined),
                label: const Text('Добавить и открыть на дереве'),
              ),
            ],
          ),
        const SizedBox(height: 12),
        Text(
          _buildPrimaryActionHint(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// P1b: закреплённый бар с главным действием — «Сохранить» всегда на
  /// экране (старшим не нужно догадываться проскроллить вниз). Кнопка
  /// 52dp (≥44dp таргет), текст крупный.
  Widget _buildPinnedSubmitBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            key: const Key('add-relative-submit'),
            onPressed: _isBusy ? null : () => _savePerson(),
            child: Text(
              _buildPrimaryActionLabel(),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEditableRelationshipCard({
    required FamilyPerson anchorPerson,
  }) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: anchorPerson.gender == Gender.male
                    ? Colors.blue.shade100
                    : Colors.pink.shade100,
                child: Icon(
                  Icons.person,
                  color: anchorPerson.gender == Gender.male
                      ? Colors.blue
                      : Colors.pink,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Связь с ${anchorPerson.name}',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Выберите, кем будет новый человек для этой карточки.',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<RelationType>(
            initialValue: _selectedRelationType,
            decoration: const InputDecoration(
              labelText: 'Связь с этим человеком',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.family_restroom),
            ),
            items: _getRelationTypeItems(_selectedGender),
            onChanged: (newValue) {
              _updateSectionState(() {
                _selectedRelationType = newValue;
                _clearStaleSeparationOnTypeChange(newValue);
                _prefillGenderBasedOnRelation(anchorPerson, newValue);
              });
            },
          ),
        ],
      ),
    );
  }

  String _buildPrimaryActionLabel() {
    if (widget.isEditing) {
      return 'Сохранить изменения';
    }
    if (_isCreatingFirstPerson) {
      return 'Добавить первого человека';
    }

    final relationType = _contextRelationType ??
        widget.predefinedRelation ??
        _selectedRelationType;
    if (relationType != null) {
      return 'Добавить ${_relationTypeToActionObject(relationType)}';
    }
    return 'Добавить родственника';
  }

  String _buildPrimaryActionHint() {
    if (widget.isEditing) {
      return 'После сохранения карточка обновится, и вы вернётесь назад.';
    }
    if (_isCreatingFirstPerson) {
      return 'Этого достаточно, чтобы начать дерево. Остальные данные можно заполнить позже.';
    }
    if (_contextPerson != null || widget.relatedTo != null) {
      return 'Связь будет создана автоматически, и новый человек сразу появится в схеме.';
    }
    return 'После сохранения человек появится в дереве, а связь сохранится в профиле.';
  }

  String _relationTypeToActionObject(RelationType type) {
    switch (type) {
      case RelationType.parent:
        return 'родителя';
      case RelationType.child:
        return 'ребёнка';
      case RelationType.spouse:
      case RelationType.partner:
        return 'супруга или партнёра';
      case RelationType.sibling:
        return 'брата или сестру';
      // Винительный падеж для одушевлённых — default отдаёт именительный
      // («Добавить друг», смоук 2026-07-04).
      case RelationType.friend:
        return 'друга';
      case RelationType.colleague:
        return 'коллегу';
      default:
        return FamilyRelation.getGenericRelationTypeStringRu(type)
            .toLowerCase();
    }
  }
}
