// 4-step bottom-sheet that powers «Редактировать профиль» and
// «Редактировать карточку родственника».
//
// Steps (per Profile Redesign README):
//   0 — Кто я: avatar + first/last/patronymic + gender (with optional
//       maiden name on female) + bio.
//   1 — Жизнь: dates + city/country + education + work + languages +
//       hometown + religion + interests + family note.
//   2 — Медиа: photo gallery placeholder (full media-edit lives in
//       its own surface, see relative_details_screen).
//   3 — Приватность: 3 visibility scopes (Только я / Семья / Все)
//       per content block + contribution-policy toggle.
//
// The sheet is provider-agnostic: caller supplies a [ProfileEditDraft]
// snapshot and an `onSave` callback that gets the next draft. The
// host owns persistence (UserProfile vs FamilyPerson) and validation.

import '../utils/genealogy_dates.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../utils/photo_url.dart';

import '../models/family_person.dart';
import '../theme/app_theme.dart';
import 'profile_redesign.dart';

/// Source-of-truth shape passed to / returned from the edit sheet.
/// Maps cleanly onto both `UserProfile` and `FamilyPerson` because
/// the redesign keeps the field-set identical between «Мой профиль»
/// and «Карточка родственника».
class ProfileEditDraft {
  const ProfileEditDraft({
    this.firstName = '',
    this.lastName = '',
    this.patronymic = '',
    this.gender = Gender.unknown,
    this.maidenName = '',
    this.bio = '',
    this.birthDate,
    this.deathDate,
    this.city = '',
    this.country = '',
    this.hometown = '',
    this.education = '',
    this.work = '',
    this.languages = '',
    this.religion = '',
    this.interests = '',
    this.familyNote = '',
    this.bioVisibility = 'family',
    this.contactsVisibility = 'family',
    this.backgroundVisibility = 'family',
    this.allowsContributions = true,
    this.photoUrl,
    this.coverPhotoUrl,
  });

  final String firstName;
  final String lastName;
  final String patronymic;
  final Gender gender;
  final String maidenName;
  final String bio;
  final DateTime? birthDate;
  final DateTime? deathDate;
  final String city;
  final String country;
  final String hometown;
  final String education;
  final String work;
  final String languages;
  final String religion;
  final String interests;
  final String familyNote;
  final String bioVisibility;
  final String contactsVisibility;
  final String backgroundVisibility;
  final bool allowsContributions;
  final String? photoUrl;
  final String? coverPhotoUrl;

  ProfileEditDraft copyWith({
    String? firstName,
    String? lastName,
    String? patronymic,
    Gender? gender,
    String? maidenName,
    String? bio,
    DateTime? birthDate,
    DateTime? deathDate,
    bool clearDeathDate = false,
    String? city,
    String? country,
    String? hometown,
    String? education,
    String? work,
    String? languages,
    String? religion,
    String? interests,
    String? familyNote,
    String? bioVisibility,
    String? contactsVisibility,
    String? backgroundVisibility,
    bool? allowsContributions,
    String? photoUrl,
    String? coverPhotoUrl,
  }) {
    return ProfileEditDraft(
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      patronymic: patronymic ?? this.patronymic,
      gender: gender ?? this.gender,
      maidenName: maidenName ?? this.maidenName,
      bio: bio ?? this.bio,
      birthDate: birthDate ?? this.birthDate,
      deathDate: clearDeathDate ? null : (deathDate ?? this.deathDate),
      city: city ?? this.city,
      country: country ?? this.country,
      hometown: hometown ?? this.hometown,
      education: education ?? this.education,
      work: work ?? this.work,
      languages: languages ?? this.languages,
      religion: religion ?? this.religion,
      interests: interests ?? this.interests,
      familyNote: familyNote ?? this.familyNote,
      bioVisibility: bioVisibility ?? this.bioVisibility,
      contactsVisibility: contactsVisibility ?? this.contactsVisibility,
      backgroundVisibility: backgroundVisibility ?? this.backgroundVisibility,
      allowsContributions: allowsContributions ?? this.allowsContributions,
      photoUrl: photoUrl ?? this.photoUrl,
      coverPhotoUrl: coverPhotoUrl ?? this.coverPhotoUrl,
    );
  }
}

/// Open the edit sheet. Returns the saved draft on commit, null on
/// cancel. The host typically:
///   1. Builds an initial draft from current data.
///   2. Awaits this future.
///   3. If non-null, persists fields it cares about (UserProfile or
///      FamilyPerson) and refreshes UI.
Future<ProfileEditDraft?> showProfileEditSheet(
  BuildContext context, {
  required ProfileEditDraft initial,
  required bool isSelf,
  bool isMemorial = false,
  int initialStep = 0,
  String? title,
  Future<String?> Function()? onPickPhoto,
  Future<String?> Function()? onPickCoverPhoto,
}) {
  return showModalBottomSheet<ProfileEditDraft>(
    context: context,
    isScrollControlled: true,
    useRootNavigator: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return _ProfileEditSheet(
        initial: initial,
        isSelf: isSelf,
        isMemorial: isMemorial,
        initialStep: initialStep,
        title: title,
        onPickPhoto: onPickPhoto,
        onPickCoverPhoto: onPickCoverPhoto,
      );
    },
  );
}

class _ProfileEditSheet extends StatefulWidget {
  const _ProfileEditSheet({
    required this.initial,
    required this.isSelf,
    required this.isMemorial,
    required this.initialStep,
    required this.title,
    this.onPickPhoto,
    this.onPickCoverPhoto,
  });

  final ProfileEditDraft initial;
  final bool isSelf;
  final bool isMemorial;
  final int initialStep;
  final String? title;
  final Future<String?> Function()? onPickPhoto;
  final Future<String?> Function()? onPickCoverPhoto;

  @override
  State<_ProfileEditSheet> createState() => _ProfileEditSheetState();
}

class _ProfileEditSheetState extends State<_ProfileEditSheet> {
  static const _stepNames = ['Кто я', 'Жизнь', 'Медиа', 'Приватность'];

  late int _step = widget.initialStep.clamp(0, _stepNames.length - 1);
  late ProfileEditDraft _draft = widget.initial;

  late final _firstName = TextEditingController(text: widget.initial.firstName);
  late final _lastName = TextEditingController(text: widget.initial.lastName);
  late final _patronymic =
      TextEditingController(text: widget.initial.patronymic);
  late final _maidenName =
      TextEditingController(text: widget.initial.maidenName);
  late final _bio = TextEditingController(text: widget.initial.bio);
  late final _city = TextEditingController(text: widget.initial.city);
  late final _country = TextEditingController(text: widget.initial.country);
  late final _hometown = TextEditingController(text: widget.initial.hometown);
  late final _education = TextEditingController(text: widget.initial.education);
  late final _work = TextEditingController(text: widget.initial.work);
  late final _languages = TextEditingController(text: widget.initial.languages);
  late final _religion = TextEditingController(text: widget.initial.religion);
  late final _interests = TextEditingController(text: widget.initial.interests);
  late final _familyNote =
      TextEditingController(text: widget.initial.familyNote);

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _patronymic.dispose();
    _maidenName.dispose();
    _bio.dispose();
    _city.dispose();
    _country.dispose();
    _hometown.dispose();
    _education.dispose();
    _work.dispose();
    _languages.dispose();
    _religion.dispose();
    _interests.dispose();
    _familyNote.dispose();
    super.dispose();
  }

  ProfileEditDraft _collect() {
    return _draft.copyWith(
      firstName: _firstName.text.trim(),
      lastName: _lastName.text.trim(),
      patronymic: _patronymic.text.trim(),
      maidenName: _maidenName.text.trim(),
      bio: _bio.text.trim(),
      city: _city.text.trim(),
      country: _country.text.trim(),
      hometown: _hometown.text.trim(),
      education: _education.text.trim(),
      work: _work.text.trim(),
      languages: _languages.text.trim(),
      religion: _religion.text.trim(),
      interests: _interests.text.trim(),
      familyNote: _familyNote.text.trim(),
    );
  }

  void _commitAndContinue() {
    final next = _collect();
    setState(() {
      _draft = next;
      if (_step < _stepNames.length - 1) {
        _step += 1;
      }
    });
  }

  Future<void> _save() async {
    Navigator.of(context).pop(_collect());
  }

  Future<void> _pickAvatar() async {
    final picker = widget.onPickPhoto;
    if (picker == null) return;
    final next = await picker();
    if (next != null && mounted) {
      setState(() => _draft = _draft.copyWith(photoUrl: next));
    }
  }

  Future<void> _pickCover() async {
    final picker = widget.onPickCoverPhoto;
    if (picker == null) return;
    final next = await picker();
    if (next != null && mounted) {
      setState(() => _draft = _draft.copyWith(coverPhotoUrl: next));
    }
  }

  Future<void> _pickBirthDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.birthDate ?? DateTime(1990, 1, 1),
      firstDate: kGenealogyFirstDate,
      lastDate: DateTime.now(),
      helpText: 'Дата рождения',
    );
    if (picked != null) {
      setState(() => _draft = _draft.copyWith(birthDate: picked));
    }
  }

  Future<void> _pickDeathDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _draft.deathDate ?? DateTime.now(),
      firstDate: _draft.birthDate ?? kGenealogyFirstDate,
      lastDate: DateTime.now(),
      helpText: 'Дата смерти',
    );
    if (picked != null) {
      setState(() => _draft = _draft.copyWith(deathDate: picked));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final mediaQ = MediaQuery.of(context);
    final maxHeight = mediaQ.size.height * 0.92;
    final bottomContentPadding = 32 + mediaQ.viewPadding.bottom + 88;

    return Padding(
      padding: EdgeInsets.only(bottom: mediaQ.viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          color: tokens.bgBase,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(28),
          ),
          border: Border(
            top: BorderSide(color: tokens.surfaceLine),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: tokens.surfaceLine,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            _buildHeader(tokens),
            _buildStepIndicator(tokens),
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  18,
                  6,
                  18,
                  bottomContentPadding,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOut,
                  switchOutCurve: Curves.easeIn,
                  child: KeyedSubtree(
                    key: ValueKey<int>(_step),
                    child: _buildStep(tokens),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(RodnyaDesignTokens tokens) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 84,
            child: Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: _step == 0
                    ? () => Navigator.of(context).pop()
                    : () => setState(() {
                          _draft = _collect();
                          _step -= 1;
                        }),
                child: Text(
                  _step == 0 ? 'Отмена' : '← Назад',
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Text(
                  widget.title ?? _stepNames[_step],
                  style: AppTheme.serif(
                    color: tokens.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_step + 1} / ${_stepNames.length}',
                  style: AppTheme.sans(
                    color: tokens.inkMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: tokens.accentSoft,
            borderRadius: BorderRadius.circular(999),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: _step < _stepNames.length - 1 ? _commitAndContinue : _save,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  _step < _stepNames.length - 1 ? 'Далее →' : 'Сохранить',
                  style: AppTheme.sans(
                    color: tokens.accent,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStepIndicator(RodnyaDesignTokens tokens) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 14),
      child: Row(
        children: [
          for (var i = 0; i < _stepNames.length; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _step = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 4,
                  decoration: BoxDecoration(
                    color: i <= _step ? tokens.accent : tokens.surfaceLine,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStep(RodnyaDesignTokens tokens) {
    switch (_step) {
      case 0:
        return _buildStepWhoAmI(tokens);
      case 1:
        return _buildStepLife(tokens);
      case 2:
        return _buildStepMedia(tokens);
      case 3:
        return _buildStepPrivacy(tokens);
    }
    return const SizedBox.shrink();
  }

  Widget _buildStepWhoAmI(RodnyaDesignTokens tokens) {
    final isFemale = _draft.gender == Gender.female;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: GestureDetector(
            onTap: _pickAvatar,
            child: Stack(
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: const Alignment(-0.5, -0.5),
                      end: const Alignment(0.5, 0.5),
                      colors: [tokens.accent, tokens.accentStrong],
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _initialsFromDraft(_draft),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: tokens.accent,
                      border: Border.all(color: tokens.bgBase, width: 2.5),
                    ),
                    child: const Icon(
                      Icons.photo_camera_outlined,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: GestureDetector(
            onTap: _pickAvatar,
            child: Text(
              'Изменить фото',
              style: AppTheme.sans(
                color: tokens.accent,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _FieldGroup(
                label: 'Имя',
                child: _RodnyaInput(controller: _firstName),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _FieldGroup(
                label: 'Фамилия',
                child: _RodnyaInput(controller: _lastName),
              ),
            ),
          ],
        ),
        _FieldGroup(
          label: 'Отчество',
          child: _RodnyaInput(controller: _patronymic),
        ),
        _FieldGroup(
          label: 'Пол',
          child: Row(
            children: [
              Expanded(
                child: _GenderButton(
                  label: 'Мужской',
                  active: _draft.gender == Gender.male,
                  onTap: () => setState(
                      () => _draft = _draft.copyWith(gender: Gender.male)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _GenderButton(
                  label: 'Женский',
                  active: _draft.gender == Gender.female,
                  onTap: () => setState(
                      () => _draft = _draft.copyWith(gender: Gender.female)),
                ),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          child: isFemale
              ? _FieldGroup(
                  label: 'Девичья фамилия',
                  child: _RodnyaInput(
                    controller: _maidenName,
                    hint: 'Фамилия до замужества',
                  ),
                )
              : const SizedBox.shrink(),
        ),
        _FieldGroup(
          label: 'О себе',
          child: _RodnyaInput(
            controller: _bio,
            multi: true,
            hint: 'Несколько слов о себе…',
          ),
        ),
      ],
    );
  }

  Widget _buildStepLife(RodnyaDesignTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _FieldGroup(
          label: 'Дата рождения',
          child: Row(
            children: [
              Expanded(
                child: _DobChip(
                  label: _draft.birthDate == null
                      ? 'Не указана'
                      : _formatDate(_draft.birthDate!),
                  emphasised: _draft.birthDate != null,
                ),
              ),
              const SizedBox(width: 8),
              _PillEditButton(
                label: _draft.birthDate == null ? 'Добавить' : 'Изменить',
                onTap: _pickBirthDate,
              ),
            ],
          ),
        ),
        if (!widget.isSelf || widget.isMemorial)
          _FieldGroup(
            label: 'Дата смерти',
            child: Row(
              children: [
                Expanded(
                  child: _DobChip(
                    label: _draft.deathDate == null
                        ? 'Не указана'
                        : _formatDate(_draft.deathDate!),
                    emphasised: _draft.deathDate != null,
                  ),
                ),
                const SizedBox(width: 8),
                _PillEditButton(
                  label: _draft.deathDate == null ? 'Добавить' : 'Изменить',
                  onTap: _pickDeathDate,
                ),
                if (_draft.deathDate != null) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: 'Очистить',
                    onPressed: () => setState(
                        () => _draft = _draft.copyWith(clearDeathDate: true)),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ],
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _FieldGroup(
                label: 'Город',
                child: _RodnyaInput(controller: _city),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _FieldGroup(
                label: 'Страна',
                child: _RodnyaInput(controller: _country),
              ),
            ),
          ],
        ),
        _FieldGroup(
          label: 'Образование',
          child: _RodnyaInput(
            controller: _education,
            hint: 'Университет, специальность',
          ),
        ),
        _FieldGroup(
          label: 'Работа и дело',
          child: _RodnyaInput(
            controller: _work,
            hint: 'Компания, должность',
          ),
        ),
        _FieldGroup(
          label: 'Языки',
          child: _RodnyaInput(
            controller: _languages,
            hint: 'Русский, Английский…',
          ),
        ),
        _FieldGroup(
          label: 'Родной город',
          child: _RodnyaInput(
            controller: _hometown,
            hint: 'Где родились и выросли',
          ),
        ),
        _FieldGroup(
          label: 'Религия / Мировоззрение',
          child: _RodnyaInput(
            controller: _religion,
            hint: 'Православие, Ислам, Атеизм…',
          ),
        ),
        _FieldGroup(
          label: 'Интересы и хобби',
          child: _RodnyaInput(
            controller: _interests,
            multi: true,
            hint: 'Что любите? Чем занимаетесь…',
          ),
        ),
        _FieldGroup(
          label: 'Заметка для семьи',
          child: _RodnyaInput(
            controller: _familyNote,
            multi: true,
            hint: 'Что важно помнить…',
          ),
        ),
      ],
    );
  }

  Widget _buildStepMedia(RodnyaDesignTokens tokens) {
    final avatarUrl = _draft.photoUrl;
    final coverUrl = _draft.coverPhotoUrl;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'Главное фото — это аватар, обложка — фон карточки. '
            'Тапните по плитке, чтобы заменить.',
            style: AppTheme.sans(
              color: tokens.inkMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              height: 1.5,
            ),
          ),
        ),
        // Cover preview — bigger, clickable. Replaces the previous
        // generic "Управление фотогалереей" placeholder.
        _MediaSlot(
          tokens: tokens,
          imageUrl: coverUrl,
          height: 130,
          fallbackIcon: Icons.wallpaper_outlined,
          fallbackLabel: 'Добавьте обложку',
          isCover: true,
          onTap: widget.onPickCoverPhoto == null ? null : _pickCover,
        ),
        const SizedBox(height: 12),
        // Avatar preview — square, smaller, side-by-side with the
        // pick button so the user can see the current photo and
        // replace it without leaving the sheet.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _MediaSlot(
              tokens: tokens,
              imageUrl: avatarUrl,
              height: 96,
              width: 96,
              fallbackIcon: Icons.account_circle_outlined,
              fallbackLabel: 'Главное фото',
              isCover: false,
              onTap: widget.onPickPhoto == null ? null : _pickAvatar,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Главное фото',
                    style: AppTheme.sans(
                      color: tokens.ink,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    avatarUrl == null || avatarUrl.trim().isEmpty
                        ? 'Покажите близким своё лицо — фото видно семье и родным в дереве.'
                        : 'Тапните по фото, чтобы заменить. Ваше фото видно семье и родным в дереве.',
                    style: AppTheme.sans(
                      color: tokens.inkMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStepPrivacy(RodnyaDesignTokens tokens) {
    final blocks = [
      const _PrivacyBlock(key_: 'bio', title: 'О себе и биография'),
      const _PrivacyBlock(key_: 'background', title: 'Образование и работа'),
      const _PrivacyBlock(key_: 'contacts', title: 'Контакты'),
    ];

    String currentValueFor(String key_) {
      switch (key_) {
        case 'bio':
          return _draft.bioVisibility;
        case 'background':
          return _draft.backgroundVisibility;
        case 'contacts':
          return _draft.contactsVisibility;
      }
      return 'family';
    }

    void setValueFor(String key_, String value) {
      setState(() {
        switch (key_) {
          case 'bio':
            _draft = _draft.copyWith(bioVisibility: value);
            break;
          case 'background':
            _draft = _draft.copyWith(backgroundVisibility: value);
            break;
          case 'contacts':
            _draft = _draft.copyWith(contactsVisibility: value);
            break;
        }
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Text(
            'Выберите, кто видит каждый блок информации. По умолчанию — '
            'только семья.',
            style: AppTheme.sans(
              color: tokens.inkMuted,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              height: 1.5,
            ),
          ),
        ),
        for (final block in blocks)
          _FieldGroup(
            label: block.title,
            child: PrivacyScopeRow(
              value: currentValueFor(block.key_),
              onChanged: (v) => setValueFor(block.key_, v),
            ),
          ),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: tokens.bgTintWarm,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: tokens.surfaceLine),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Родные могут предлагать правки',
                      style: AppTheme.sans(
                        color: tokens.ink,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Правки приходят на одобрение вам',
                      style: AppTheme.sans(
                        color: tokens.inkMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0,
                      ),
                    ),
                  ],
                ),
              ),
              _ContributionToggle(
                value: _draft.allowsContributions,
                onChanged: (v) => setState(
                  () => _draft = _draft.copyWith(allowsContributions: v),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _initialsFromDraft(ProfileEditDraft d) {
    final parts = <String>[];
    if (d.firstName.trim().isNotEmpty) {
      parts.add(d.firstName.trim().substring(0, 1).toUpperCase());
    }
    if (d.lastName.trim().isNotEmpty) {
      parts.add(d.lastName.trim().substring(0, 1).toUpperCase());
    }
    return parts.isEmpty ? '?' : parts.join();
  }

  String _formatDate(DateTime date) {
    final months = [
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
    return '${date.day} ${months[date.month - 1]} ${date.year}';
  }
}

class _PrivacyBlock {
  const _PrivacyBlock({required this.key_, required this.title});
  final String key_;
  final String title;
}

class _FieldGroup extends StatelessWidget {
  const _FieldGroup({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              label.toUpperCase(),
              style: AppTheme.sans(
                color: tokens.inkMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _RodnyaInput extends StatelessWidget {
  const _RodnyaInput({
    required this.controller,
    this.hint,
    this.multi = false,
  });

  final TextEditingController controller;
  final String? hint;
  final bool multi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return TextField(
      controller: controller,
      maxLines: multi ? null : 1,
      minLines: multi ? 3 : 1,
      keyboardType: multi ? TextInputType.multiline : null,
      // M3 (50+): было 14.5 — ниже общей планки «ввод/подсказка ≥16sp».
      style: AppTheme.sans(
        color: tokens.ink,
        fontSize: AppTheme.formInputFontSize,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppTheme.sans(
          color: tokens.inkMuted,
          fontSize: AppTheme.formInputFontSize,
          fontWeight: FontWeight.w500,
          letterSpacing: 0,
        ),
        filled: true,
        fillColor: tokens.bgTintWarm,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: tokens.surfaceLine),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: tokens.surfaceLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: tokens.accent, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(
          horizontal: 14,
          vertical: multi ? 12 : 13,
        ),
      ),
    );
  }
}

class _GenderButton extends StatelessWidget {
  const _GenderButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 40,
        decoration: BoxDecoration(
          color: active ? tokens.accent : tokens.bgTintWarm,
          border: Border.all(
            color: active ? Colors.transparent : tokens.surfaceLine,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(999),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: tokens.accent.withValues(alpha: 0.45),
                    blurRadius: 12,
                    spreadRadius: -4,
                    offset: const Offset(0, 4),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTheme.sans(
            color: active ? Colors.white : tokens.inkMuted,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}

class _DobChip extends StatelessWidget {
  const _DobChip({required this.label, required this.emphasised});
  final String label;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Container(
      height: 46,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: tokens.bgTintWarm,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Row(
        children: [
          Icon(
            Icons.cake_outlined,
            size: 16,
            color: tokens.inkMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: AppTheme.sans(
                color: emphasised ? tokens.ink : tokens.inkMuted,
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PillEditButton extends StatelessWidget {
  const _PillEditButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(
              color: tokens.accent.withValues(alpha: 0.32),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            label,
            style: AppTheme.sans(
              color: tokens.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
            ),
          ),
        ),
      ),
    );
  }
}

class _ContributionToggle extends StatelessWidget {
  const _ContributionToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 26,
        decoration: BoxDecoration(
          color: value ? tokens.accent : tokens.surfaceLine,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 20,
            height: 20,
            margin: const EdgeInsets.symmetric(horizontal: 3),
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tap-to-replace media tile used by step 2 («Медиа») of the edit
/// sheet. Renders the current photo when one exists, otherwise a
/// dotted-outline placeholder with the design's icon + label. Clicks
/// route to the host-supplied picker.
class _MediaSlot extends StatelessWidget {
  const _MediaSlot({
    required this.tokens,
    required this.imageUrl,
    required this.height,
    this.width,
    required this.fallbackIcon,
    required this.fallbackLabel,
    required this.isCover,
    required this.onTap,
  });

  final RodnyaDesignTokens tokens;
  final String? imageUrl;
  final double height;
  final double? width;
  final IconData fallbackIcon;
  final String fallbackLabel;
  final bool isCover;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final hasImage = imageUrl != null && imageUrl!.trim().isNotEmpty;
    final radius = isCover ? 18.0 : 14.0;
    final url = hasImage ? (normalizePhotoUrl(imageUrl!) ?? imageUrl!) : null;
    final placeholder = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(fallbackIcon, color: tokens.inkMuted, size: 28),
          const SizedBox(height: 6),
          Text(
            fallbackLabel,
            textAlign: TextAlign.center,
            style: AppTheme.sans(
              color: tokens.inkMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      ),
    );
    final body = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        height: height,
        width: width,
        child: hasImage
            ? Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: url!,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(color: tokens.bgTintWarm),
                    errorWidget: (_, __, ___) => placeholder,
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.photo_camera_outlined,
                              color: Colors.white, size: 12),
                          SizedBox(width: 4),
                          Text(
                            'заменить',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              )
            : Container(
                decoration: BoxDecoration(
                  color: tokens.bgTintWarm,
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(
                    color: tokens.surfaceLine,
                    style: BorderStyle.solid,
                    width: 1.2,
                  ),
                ),
                child: placeholder,
              ),
      ),
    );

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(radius),
      child: body,
    );
  }
}
