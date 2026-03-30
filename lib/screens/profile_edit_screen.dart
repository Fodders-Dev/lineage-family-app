import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:country_picker/country_picker.dart';
import 'package:phone_number/phone_number.dart';
import '../models/family_person.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';
import '../backend/models/profile_form_data.dart';

class ProfileEditScreen extends StatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  State<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends State<ProfileEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _cityController = TextEditingController();
  final _maidenNameController = TextEditingController();

  DateTime? _birthDate;
  String? _countryCode;
  String? _countryName;
  String? _profileImageUrl;
  bool _isLoading = false;
  bool _isPhoneVerified = false;
  Gender _gender = Gender.unknown;

  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _middleNameController.dispose();
    _usernameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _cityController.dispose();
    _maidenNameController.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    setState(() {
      _isLoading = true;
    });

    try {
      if (_authService.currentUserId == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка: пользователь не авторизован')),
        );
        Navigator.pop(context);
        return;
      }

      final data = await _profileService.getCurrentUserProfileFormData();
      if (!mounted) return;

      // Разделяем displayName на компоненты, если отдельные поля не заполнены
      String displayName = data.displayName;
      List<String> nameParts = displayName.split(' ');

      setState(() {
        // Используем отдельные поля, если они есть
        _firstNameController.text = data.firstName.isNotEmpty
            ? data.firstName
            : (nameParts.isNotEmpty ? nameParts[0] : '');
        _lastNameController.text = data.lastName.isNotEmpty
            ? data.lastName
            : (nameParts.length > 1 ? nameParts.last : '');

        // Если есть отчество в отдельном поле или можно предположить из displayName
        _middleNameController.text = data.middleName.isNotEmpty
            ? data.middleName
            : (nameParts.length > 2
                ? nameParts.sublist(1, nameParts.length - 1).join(' ')
                : '');

        _usernameController.text = data.username;

        _emailController.text = data.email ?? '';
        _phoneController.text = data.phoneNumber;
        _cityController.text = data.city;
        _countryCode = data.countryCode;
        _countryName = data.countryName;
        _profileImageUrl = data.photoUrl;
        _isPhoneVerified = data.isPhoneVerified;

        _gender = data.gender;

        _birthDate = data.birthDate;

        if (_gender == Gender.female) {
          _maidenNameController.text = data.maidenName;
        }
      });
    } catch (e) {
      debugPrint('Ошибка при загрузке данных пользователя: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка при загрузке данных: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery);

    if (image != null) {
      setState(() {
        _isLoading = true;
      });

      try {
        final imageUrl = await _profileService.uploadProfilePhoto(image);
        if (!mounted) return;

        if (imageUrl != null) {
          setState(() {
            _profileImageUrl = imageUrl;
          });
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Не удалось получить URL изображения после загрузки.',
              ),
            ),
          );
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка загрузки изображения: $e')),
        );
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _pickDate() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _birthDate ?? DateTime(1990),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      locale: const Locale('ru', 'RU'),
    );

    if (pickedDate != null) {
      setState(() {
        _birthDate = pickedDate;
      });
    }
  }

  Future<void> _selectCountry() async {
    showCountryPicker(
      context: context,
      showPhoneCode: true,
      countryListTheme: CountryListThemeData(
        flagSize: 25,
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        textStyle: TextStyle(
          fontSize: 16,
          color: Theme.of(context).textTheme.bodyLarge?.color,
        ),
        bottomSheetHeight: 500,
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20.0),
          topRight: Radius.circular(20.0),
        ),
        inputDecoration: InputDecoration(
          labelText: 'Поиск',
          hintText: 'Начните вводить название страны',
          prefixIcon: const Icon(Icons.search),
          border: OutlineInputBorder(
            borderSide: BorderSide(
              color: Theme.of(context).primaryColor.withValues(alpha: 0.2),
            ),
          ),
        ),
      ),
      onSelect: (Country country) {
        setState(() {
          _countryCode = country.countryCode;
          _countryName = country.name;
        });
      },
    );
  }

  Future<void> _verifyPhoneNumber() async {
    if (_phoneController.text.isEmpty || _countryCode == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Введите номер телефона и выберите страну')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final phoneUtil = PhoneNumberUtil();
      bool isValid = false;

      final phoneNumberWithCode = '+$_countryCode${_phoneController.text}';

      try {
        isValid = await phoneUtil.validate(phoneNumberWithCode);
      } catch (e) {
        isValid = false;
        debugPrint('Ошибка валидации номера: $e');
      }

      if (!isValid) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Неверный формат номера телефона')),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      await _profileService.verifyCurrentUserPhone(
        phoneNumber: _phoneController.text,
        countryCode: _countryCode!,
      );

      if (!mounted) return;
      setState(() {
        _isPhoneVerified = true;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Номер телефона проверен')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveProfile({String? newPhotoUrl}) async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final userId = _authService.currentUserId;
      if (userId == null) throw Exception('Пользователь не авторизован');

      // Создаем displayName из компонентов
      String displayName = [
        _firstNameController.text.trim(),
        _middleNameController.text.trim(),
        _lastNameController.text.trim(),
      ].where((part) => part.isNotEmpty).join(' ');

      await _profileService.saveCurrentUserProfileFormData(
        ProfileFormData(
          userId: userId,
          email: _emailController.text.trim(),
          firstName: _firstNameController.text.trim(),
          lastName: _lastNameController.text.trim(),
          middleName: _middleNameController.text.trim(),
          displayName: displayName,
          username: _usernameController.text.trim(),
          phoneNumber: _phoneController.text.trim(),
          countryCode: _countryCode,
          countryName: _countryName,
          city: _cityController.text.trim(),
          photoUrl: newPhotoUrl ?? _profileImageUrl,
          isPhoneVerified: _isPhoneVerified,
          gender: _gender,
          maidenName:
              _gender == Gender.female ? _maidenNameController.text.trim() : '',
          birthDate: _birthDate,
        ),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Профиль успешно обновлен')));

      Navigator.pop(context, true);
    } catch (e) {
      debugPrint('Ошибка при сохранении профиля: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка при сохранении: $e')));
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
    final dateFormat = DateFormat.yMMMMd('ru');

    return Scaffold(
      appBar: AppBar(title: Text('Редактирование профиля')),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: EdgeInsets.all(16.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: GestureDetector(
                        onTap: _pickImage,
                        child: Stack(
                          alignment: Alignment.bottomRight,
                          children: [
                            CircleAvatar(
                              radius: 60,
                              backgroundImage: _profileImageUrl != null
                                  ? NetworkImage(_profileImageUrl!)
                                  : null,
                              child: _profileImageUrl == null
                                  ? Icon(Icons.person, size: 60)
                                  : null,
                            ),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(4.0),
                                child: Icon(
                                  Icons.camera_alt,
                                  color: Colors.white,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(height: 24),
                    Text(
                      'Личная информация',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 16),
                    TextFormField(
                      controller: _firstNameController,
                      decoration: InputDecoration(
                        labelText: 'Имя',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Введите имя';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 16),
                    TextFormField(
                      controller: _lastNameController,
                      decoration: InputDecoration(
                        labelText: 'Фамилия',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Введите фамилию';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 16),
                    TextFormField(
                      controller: _middleNameController,
                      decoration: InputDecoration(
                        labelText: 'Отчество (если есть)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 16),
                    TextFormField(
                      controller: _usernameController,
                      decoration: InputDecoration(
                        labelText: 'Username',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 16),
                    TextFormField(
                      controller: _emailController,
                      decoration: InputDecoration(
                        labelText: 'Email',
                        border: OutlineInputBorder(),
                        suffixIcon: Icon(Icons.lock),
                      ),
                      readOnly: true,
                    ),
                    SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 16.0,
                        top: 16.0,
                        bottom: 8.0,
                      ),
                      child: Text('Пол', style: TextStyle(fontSize: 16)),
                    ),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        ChoiceChip(
                          label: const Text('Мужской'),
                          avatar: const Icon(Icons.male, size: 18),
                          selected: _gender == Gender.male,
                          selectedColor: Colors.blue.shade100,
                          onSelected: (_) {
                            setState(() {
                              _gender = Gender.male;
                            });
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Женский'),
                          avatar: const Icon(Icons.female, size: 18),
                          selected: _gender == Gender.female,
                          selectedColor: Colors.pink.shade100,
                          onSelected: (_) {
                            setState(() {
                              _gender = Gender.female;
                            });
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: 16),
                    ListTile(
                      title: Text('Дата рождения'),
                      subtitle: Text(
                        _birthDate != null
                            ? dateFormat.format(_birthDate!)
                            : 'Не указана',
                      ),
                      trailing: Icon(Icons.calendar_today),
                      onTap: _pickDate,
                    ),
                    SizedBox(height: 16),
                    ListTile(
                      title: Text('Страна'),
                      subtitle: Text(_countryName ?? 'Не указана'),
                      trailing: Icon(Icons.arrow_forward_ios),
                      onTap: _selectCountry,
                    ),
                    SizedBox(height: 16),
                    TextFormField(
                      controller: _cityController,
                      decoration: InputDecoration(
                        labelText: 'Город',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _phoneController,
                            decoration: InputDecoration(
                              labelText: 'Номер телефона',
                              border: OutlineInputBorder(),
                              prefixText: _countryCode != null ? '+' : '',
                              suffixIcon: _isPhoneVerified
                                  ? Icon(Icons.verified, color: Colors.green)
                                  : null,
                            ),
                            keyboardType: TextInputType.phone,
                          ),
                        ),
                        SizedBox(width: 8),
                        if (!_isPhoneVerified)
                          ElevatedButton(
                            onPressed: _verifyPhoneNumber,
                            child: Text('Проверить'),
                          ),
                      ],
                    ),
                    SizedBox(height: 16),
                    if (_gender == Gender.female)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16.0),
                        child: TextFormField(
                          controller: _maidenNameController,
                          decoration: InputDecoration(
                            labelText: 'Девичья фамилия',
                            hintText:
                                'Введите девичью фамилию (если применимо)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    SizedBox(height: 24),
                  ],
                ),
              ),
            ),
      bottomNavigationBar: Padding(
        padding: EdgeInsets.all(16.0),
        child: ElevatedButton(
          onPressed: _isLoading ? null : _saveProfile,
          style: ElevatedButton.styleFrom(
            minimumSize: Size(double.infinity, 50),
          ),
          child: _isLoading
              ? SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : Text('Сохранить'),
        ),
      ),
    );
  }
}
