// Registration / first-launch profile completion card.
//
// Visually mirrors Step 0 («Кто я») of the Profile Redesign edit
// sheet — teal+honey palette, info-card sections, pill gender
// selector, accent CTA — so the user lands on the same surface
// language they will see again every time they open «Редактировать
// профиль» later. Form-validation and persistence semantics are
// unchanged from the previous version.

import '../utils/user_facing_error.dart';
import '../utils/genealogy_dates.dart';
import 'package:country_picker/country_picker.dart';
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/models/profile_form_data.dart';
import '../models/family_person.dart';
import '../models/user_profile.dart';
import '../theme/app_theme.dart';
import '../widgets/dismiss_keyboard.dart';
import '../widgets/flow_overlays.dart';
import '../widgets/profile_redesign.dart';

class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({
    super.key,
    this.initialData,
    this.requiredFields,
  });

  final UserProfile? initialData;
  final Map<String, bool>? requiredFields;

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  static const List<String> _priorityCountryCodes = [
    'RU',
    'BY',
    'KZ',
    'AM',
    'KG',
    'UZ',
    'TJ',
    'AZ',
    'GE',
    'MD',
  ];

  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _phoneController = TextEditingController();

  Gender _selectedGender = Gender.unknown;
  DateTime? _birthDate;
  String? _selectedCountry = 'Россия';
  String? _countryCode = '+7';

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadExistingData();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _middleNameController.dispose();
    _usernameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      if (_authService.currentUserId == null) {
        if (!mounted) return;
        context.go('/login');
        return;
      }

      final data = await _profileService.getCurrentUserProfileFormData();
      if (!mounted) return;

      setState(() {
        _firstNameController.text = data.firstName;
        _lastNameController.text = data.lastName;
        _middleNameController.text = data.middleName;
        _usernameController.text = data.username;
        _selectedGender = data.gender;
        _birthDate = data.birthDate;
        final countryName = data.countryName?.trim() ?? '';
        _selectedCountry = countryName.isNotEmpty ? countryName : 'Россия';

        if (data.phoneNumber.isNotEmpty) {
          final phoneNumber = data.phoneNumber;
          if (phoneNumber.startsWith('+') && phoneNumber.length > 2) {
            final separatorIndex = phoneNumber.length > 11 ? 2 : 1;
            _countryCode = phoneNumber.substring(0, separatorIndex + 1);
            _phoneController.text = phoneNumber.substring(separatorIndex + 1);
          } else {
            _phoneController.text = phoneNumber;
          }
        }
      });
    } catch (e) {
      debugPrint('Error loading user data: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось загрузить профиль.')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final normalizedPhone = _phoneController.text.trim();
      final fullPhoneNumber = normalizedPhone.isEmpty
          ? ''
          : '${_countryCode ?? '+7'}$normalizedPhone';
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) {
        throw Exception('Пользователь не авторизован');
      }

      await _profileService.saveCurrentUserProfileFormData(
        ProfileFormData(
          userId: currentUserId,
          email: _authService.currentUserEmail,
          firstName: _firstNameController.text.trim(),
          lastName: _lastNameController.text.trim(),
          middleName: _middleNameController.text.trim(),
          username: _usernameController.text.trim(),
          phoneNumber: fullPhoneNumber,
          gender: _selectedGender,
          birthDate: _birthDate,
          countryName: _selectedCountry ?? 'Россия',
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Профиль сохранён.')),
      );
      context.go(await _resolvePostSaveLocation());
    } catch (e) {
      debugPrint('Ошибка при сохранении профиля: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(humanizeError(e,
                fallback:
                    'Не удалось сохранить профиль. Попробуйте ещё раз.'))),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Scaffold(
      backgroundColor: tokens.bgBase,
      appBar: AppBar(
        backgroundColor: tokens.bgBase,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          'Профиль',
          style: AppTheme.serif(
            color: tokens.ink,
            fontSize: 22,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.22,
          ),
        ),
      ),
      body: DismissKeyboardOnTap(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 980;
                  final dateFormat = DateFormat.yMMMd('ru');

                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildHeroIntro(tokens),
                              if (isWide)
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(child: _buildIdentitySection()),
                                    const SizedBox(width: 12),
                                    Expanded(child: _buildContactsSection()),
                                  ],
                                )
                              else ...[
                                _buildIdentitySection(),
                                _buildContactsSection(),
                              ],
                              _buildPersonalSection(dateFormat),
                              const SizedBox(height: 22),
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 12),
                                child: PillButton(
                                  label: _isLoading
                                      ? 'Сохраняем…'
                                      : 'Сохранить и продолжить',
                                  icon: Icons.check_rounded,
                                  expanded: true,
                                  onPressed: _isLoading ? null : _saveProfile,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Widget _buildHeroIntro(RodnyaDesignTokens tokens) {
    // Плотность (чанк 21): убрали иллюстративный градиент-кавер +
    // плашку «Добро пожаловать» и карточку-в-карточке (surfaceStrong +
    // рамка) — это первый экран после регистрации, а не витрина, и он
    // не должен занимать треть 412×915 до полей. Заголовок + одна
    // строка подписи прямо на фоне скаффолда, как у экрана входа
    // (чанк 18).
    return Padding(
      key: const Key('complete-profile-hero'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Расскажите о себе',
            style: AppTheme.serif(
              color: tokens.ink,
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              height: 1.12,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Эти данные увидит только семья',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.sans(
              color: tokens.inkSecondary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
              letterSpacing: 0,
              height: 1.2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIdentitySection() {
    return ProfileSection(
      title: 'Кто я',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FieldLabel(label: 'Фамилия и имя'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _RegistrationInput(
                      controller: _lastNameController,
                      hint: 'Фамилия',
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Введите фамилию'
                              : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RegistrationInput(
                      controller: _firstNameController,
                      hint: 'Имя',
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Введите имя'
                              : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _RegistrationInput(
                controller: _middleNameController,
                hint: 'Отчество (необязательно)',
              ),
              const SizedBox(height: 14),
              _FieldLabel(label: 'Username'),
              const SizedBox(height: 8),
              _RegistrationInput(
                controller: _usernameController,
                hint: 'username',
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Введите username';
                  }
                  if (value.contains(' ')) {
                    return 'Без пробелов';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContactsSection() {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return ProfileSection(
      title: 'Как с вами связаться',
      subtitle: 'Канал входа можно подключить позже',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FieldLabel(label: 'Страна'),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _selectCountry,
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: tokens.bgTintWarm,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: tokens.surfaceLine),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.flag_outlined, size: 18, color: tokens.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _selectedCountry ?? 'Выберите страну',
                          style: AppTheme.sans(
                            color: _selectedCountry == null
                                ? tokens.inkMuted
                                : tokens.ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                      Text(
                        _countryCode ?? '+7',
                        style: AppTheme.sans(
                          color: tokens.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: tokens.inkMuted,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _FieldLabel(label: 'Телефон (необязательно)'),
              const SizedBox(height: 8),
              Container(
                height: 50,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: tokens.bgTintWarm,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: tokens.surfaceLine),
                ),
                child: Row(
                  children: [
                    Text(
                      _countryCode ?? '+7',
                      // M3 (50+): держим тот же размер, что и у поля
                      // телефона рядом — иначе «+7» выглядит мельче ввода.
                      style: AppTheme.sans(
                        color: tokens.ink,
                        fontSize: AppTheme.formInputFontSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _phoneController,
                        keyboardType: TextInputType.phone,
                        // M3 (50+): было 14.5 — ниже общей планки ≥16sp.
                        style: AppTheme.sans(
                          color: tokens.ink,
                          fontSize: AppTheme.formInputFontSize,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0,
                        ),
                        decoration: InputDecoration(
                          hintText: '999 123 45 67',
                          hintStyle: AppTheme.sans(
                            color: tokens.inkMuted,
                            fontSize: AppTheme.formInputFontSize,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPersonalSection(DateFormat dateFormat) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return ProfileSection(
      title: 'Личное',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _FieldLabel(label: 'Пол'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _RegistrationGenderButton(
                      label: 'Мужской',
                      icon: Icons.male_rounded,
                      isSelected: _selectedGender == Gender.male,
                      onTap: () =>
                          setState(() => _selectedGender = Gender.male),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RegistrationGenderButton(
                      label: 'Женский',
                      icon: Icons.female_rounded,
                      isSelected: _selectedGender == Gender.female,
                      onTap: () =>
                          setState(() => _selectedGender = Gender.female),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RegistrationGenderButton(
                      label: 'Не указан',
                      icon: Icons.circle_outlined,
                      isSelected: _selectedGender == Gender.unknown,
                      onTap: () =>
                          setState(() => _selectedGender = Gender.unknown),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _FieldLabel(label: 'Дата рождения'),
              const SizedBox(height: 8),
              GestureDetector(
                onTap: _selectDate,
                child: Container(
                  height: 50,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: tokens.bgTintWarm,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: tokens.surfaceLine),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.calendar_today_outlined,
                        size: 18,
                        color: tokens.warm,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _birthDate == null
                              ? 'Когда родились'
                              : dateFormat.format(_birthDate!),
                          style: AppTheme.sans(
                            color: _birthDate == null
                                ? tokens.inkMuted
                                : tokens.ink,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
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
            ],
          ),
        ),
      ],
    );
  }

  Future<String> _resolvePostSaveLocation() async {
    try {
      final pendingInvitations =
          await _familyTreeService.getPendingTreeInvitations().first;
      if (pendingInvitations.isNotEmpty) {
        return '/trees?tab=invitations';
      }
    } catch (_) {
      // Do not block navigation after save.
    }
    return '/';
  }

  void _selectCountry() {
    showCountryPicker(
      context: context,
      showPhoneCode: true,
      favorite: _priorityCountryCodes,
      useRootNavigator: true,
      useSafeArea: true,
      countryListTheme: CountryListThemeData(
        backgroundColor:
            Theme.of(context).colorScheme.surface.withValues(alpha: 0.98),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(28),
          topRight: Radius.circular(28),
        ),
        bottomSheetHeight: 560,
        inputDecoration: InputDecoration(
          labelText: 'Поиск',
          hintText: 'Страна или код',
          prefixIcon: const Icon(Icons.search),
          filled: true,
          fillColor: Theme.of(context)
              .colorScheme
              .surfaceContainerLowest
              .withValues(alpha: 0.9),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      onSelect: (Country country) {
        setState(() {
          _countryCode = '+${country.phoneCode}';
          _selectedCountry = country.nameLocalized?.trim().isNotEmpty == true
              ? country.nameLocalized!.trim()
              : country.name;
        });
      },
    );
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showRodnyaDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime.now(),
      firstDate: kGenealogyFirstDate,
      lastDate: DateTime.now(),
    );

    if (picked != null && picked != _birthDate) {
      setState(() {
        _birthDate = picked;
      });
    }
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return Text(
      label.toUpperCase(),
      style: AppTheme.sans(
        color: tokens.inkMuted,
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.9,
      ),
    );
  }
}

class _RegistrationInput extends StatelessWidget {
  const _RegistrationInput({
    required this.controller,
    this.hint,
    this.validator,
  });

  final TextEditingController controller;
  final String? hint;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return TextFormField(
      controller: controller,
      validator: validator,
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
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.redAccent.shade100, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.redAccent.shade400, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }
}

class _RegistrationGenderButton extends StatelessWidget {
  const _RegistrationGenderButton({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<RodnyaDesignTokens>() ??
        RodnyaDesignTokens.light;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? tokens.accentSoft : tokens.bgTintWarm,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? tokens.accent : tokens.surfaceLine,
            width: 1.5,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? tokens.accent : tokens.inkMuted,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.sans(
                  color: isSelected ? tokens.accent : tokens.inkMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
