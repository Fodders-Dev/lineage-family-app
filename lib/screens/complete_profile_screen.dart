import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:country_picker/country_picker.dart';
import '../models/family_person.dart';
import '../models/user_profile.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/models/profile_form_data.dart';

class CompleteProfileScreen extends StatefulWidget {
  final UserProfile? initialData;
  final Map<String, bool>? requiredFields;

  const CompleteProfileScreen({
    super.key,
    this.initialData,
    this.requiredFields,
  });

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _phoneController = TextEditingController();

  Gender _selectedGender = Gender.unknown;
  DateTime? _birthDate;
  String? _selectedCountry;
  String? _countryCode = '+7'; // По умолчанию российский код

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadExistingData();
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
        _selectedCountry = data.countryName;

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
        SnackBar(content: Text('Ошибка при загрузке данных пользователя')),
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
      final fullPhoneNumber = _countryCode! + _phoneController.text.trim();
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Профиль успешно обновлен')));

      context.go('/');
    } catch (e) {
      debugPrint('Ошибка при сохранении профиля: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка при сохранении профиля: $e')),
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
    return Scaffold(
      appBar: AppBar(title: Text('Завершение регистрации')),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Заполните профиль',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),

                    // Имя
                    TextFormField(
                      controller: _firstNameController,
                      decoration: InputDecoration(
                        labelText: 'Имя',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person),
                        hintText: 'Введите ваше имя',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Введите имя';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 16),

                    // Фамилия
                    TextFormField(
                      controller: _lastNameController,
                      decoration: InputDecoration(
                        labelText: 'Фамилия',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person),
                        hintText: 'Введите вашу фамилию',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Введите фамилию';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 16),

                    // Отчество (опционально)
                    TextFormField(
                      controller: _middleNameController,
                      decoration: InputDecoration(
                        labelText: 'Отчество (если есть)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person_outline),
                        hintText: 'Введите ваше отчество',
                      ),
                    ),

                    // Username (обязательно)
                    TextFormField(
                      controller: _usernameController,
                      decoration: InputDecoration(
                        labelText: 'Имя пользователя (username)',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.alternate_email),
                        hintText: 'Введите уникальное имя пользователя',
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Введите имя пользователя';
                        }
                        if (value.contains(' ')) {
                          // Проверка на пробелы
                          return 'Имя пользователя не должно содержать пробелов';
                        }
                        // Можно добавить другие проверки (длина, символы)
                        return null;
                      },
                    ),
                    SizedBox(height: 16),

                    // Телефон (обязательно)
                    Row(
                      children: [
                        // Выбор кода страны (можно оставить как есть или улучшить)
                        ElevatedButton(
                          onPressed: _selectCountry,
                          style: ElevatedButton.styleFrom(
                            padding: EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 16,
                            ),
                          ),
                          child: Text(_countryCode ?? '+?'),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: TextFormField(
                            controller: _phoneController,
                            decoration: InputDecoration(
                              labelText: 'Номер телефона',
                              border: OutlineInputBorder(),
                              prefixIcon: Icon(Icons.phone),
                              hintText: 'Введите номер телефона',
                            ),
                            keyboardType: TextInputType.phone,
                            validator: (value) {
                              if (value == null || value.trim().isEmpty) {
                                return 'Введите номер телефона';
                              }
                              // Можно добавить более строгую валидацию номера
                              return null;
                            },
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 16),

                    // Пол (опционально)
                    DropdownButtonFormField<Gender>(
                      initialValue: _selectedGender,
                      decoration: InputDecoration(
                        labelText: 'Пол',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.wc),
                      ),
                      items: Gender.values.map((Gender gender) {
                        String genderText;
                        switch (gender) {
                          case Gender.male:
                            genderText = 'Мужской';
                            break;
                          case Gender.female:
                            genderText = 'Женский';
                            break;
                          case Gender.other:
                            genderText = 'Другой';
                            break;
                          case Gender.unknown:
                            genderText = 'Не указан';
                            break;
                        }
                        return DropdownMenuItem<Gender>(
                          value: gender,
                          child: Text(genderText),
                        );
                      }).toList(),
                      onChanged: (Gender? newValue) {
                        setState(() {
                          _selectedGender = newValue ?? Gender.unknown;
                        });
                      },
                    ),
                    SizedBox(height: 16),

                    // Дата рождения (опционально)
                    InkWell(
                      onTap: _selectDate,
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: 'Дата рождения',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.calendar_today),
                        ),
                        child: Text(
                          _birthDate == null
                              ? 'Выберите дату'
                              : DateFormat.yMMMMd('ru').format(_birthDate!),
                        ),
                      ),
                    ),
                    SizedBox(height: 16),

                    // Страна (опционально)
                    _buildCountryPicker(), // Используем существующий виджет выбора страны

                    SizedBox(height: 32),

                    // Кнопка сохранения
                    _isLoading
                        ? Center(child: CircularProgressIndicator())
                        : Center(
                            child: ElevatedButton(
                              onPressed: _saveProfile,
                              style: ElevatedButton.styleFrom(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 50,
                                  vertical: 15,
                                ),
                                textStyle: TextStyle(fontSize: 16),
                              ),
                              child: Text('Сохранить профиль'),
                            ),
                          ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildCountryPicker() {
    return GestureDetector(
      onTap: _selectCountry,
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 15, horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          children: [
            Icon(Icons.flag, color: Colors.grey[700]),
            SizedBox(width: 12),
            Text(_selectedCountry ?? 'Выберите страну'),
            Spacer(),
            Text(
              _countryCode ?? '+7',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  void _selectCountry() {
    showCountryPicker(
      context: context,
      showPhoneCode: true,
      onSelect: (Country country) {
        setState(() {
          _countryCode = country.phoneCode;
          _selectedCountry = country.name;
        });
      },
    );
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime.now(),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      locale: const Locale('ru', 'RU'),
    );

    if (picked != null && picked != _birthDate) {
      setState(() {
        _birthDate = picked;
      });
    }
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
}
