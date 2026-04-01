import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart'; // Импортируем Provider
import '../models/family_tree.dart';
import '../models/user_profile.dart';
import '../models/profile_note.dart'; // Импортируем модель заметки
import '../providers/tree_provider.dart'; // Импортируем TreeProvider
import 'dart:async'; // Для Future
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';

// Примерный виджет для отображения статистики (можно вынести в отдельный файл)
class _ProfileStatItem extends StatelessWidget {
  final String label;
  final String value;

  const _ProfileStatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey)),
      ],
    );
  }
}

// Функция для безопасного формирования отображаемого имени
String _getSafeDisplayName(UserProfile profile) {
  // Если displayName существует и не является мусором, используем его
  if (profile.displayName != null && profile.displayName!.isNotEmpty) {
    final displayName = profile.displayName!;
    
    final trimmed = displayName.trim();
    
    // Проверяем на пустоту или простые служебные значения
    if (trimmed.isEmpty) return 'Профиль';
    
    // Слишком длинная строка
    if (trimmed.length > 100) return 'Профиль';
    
    // Строка из цифр или спецсимволов
    if (RegExp(r'^[0-9!@#$%^&*()_+\-=\[\]{};\'"\\|,.<>\/?]+$').hasMatch(trimmed)) {
      return 'Профиль';
    }
    
    // Содержит известные мусорные слова
    final lower = trimmed.toLowerCase();
    if (lower.contains('example.com') || 
        lower.contains('test123') || 
        lower.contains('codex') || 
        lower.contains('mcp') ||
        lower.contains('2026')) {
      return 'Профиль';
    }
    
    // Слишком много цифр подряд
    final digitCount = trimmed.replaceAll(RegExp(r'[^0-9]'), '').length;
    if (digitCount > 5 && digitCount > trimmed.length * 0.7) {
      return 'Профиль';
    }
    
    // Строка почти полностью из цифр/спецсимволов
    final nonAlphaCount = trimmed.replaceAll(RegExp(r'[a-zA-Zа-яА-ЯёЁ]'), '').length;
    if (nonAlphaCount > trimmed.length * 0.8) {
      return 'Профиль';
    }
    
    // Если всё нормально, возвращаем оригинальное имя
    return displayName;
  }
  
  // Если displayName отсутствует, пытаемся собрать из компонентов
  final parts = <String>[];
  if (profile.firstName != null && profile.firstName!.isNotEmpty) {
    parts.add(profile.firstName!);
  }
  if (profile.middleName != null && profile.middleName!.isNotEmpty) {
    parts.add(profile.middleName!);
  }
  if (profile.lastName != null && profile.lastName!.isNotEmpty) {
    parts.add(profile.lastName!);
  }
  
  if (parts.isNotEmpty) {
    return parts.join(' ');
  }
  
  // Если нет компонентов, пытаемся использовать username
  if (profile.username != null && profile.username!.isNotEmpty) {
    return profile.username!;
  }
  
  // Если нет username, используем email без мусора
  if (profile.email != null && profile.email!.isNotEmpty) {
    final email = profile.email!;
    // Удаляем мусорные части из email (если он выглядит как мусор)
    if (email.contains('@') && 
        email.length > 10 && 
        email.contains('example.com')) {
      return 'Профиль';
    }
    return email;
  }
  
  // Если всё не удалось, возвращаем стандартное значение
  return 'Профиль';
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  UserProfile? _userProfile;
  String? _currentUserId; // Храним ID текущего пользователя
  int _treeCount = 0;
  int _relativeCount = 0;
  bool _isLoading = true;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadUserData();
  }

  Future<void> _signOut() async {
    await _authService.signOut();
    if (GetIt.I.isRegistered<TreeProvider>()) {
      await GetIt.I<TreeProvider>().clearSelection();
    }
    if (mounted) {
      context.go('/login');
    }
  }

  Future<void> _loadUserData() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final userId = _authService.currentUserId;
      if (userId == null) {
        throw Exception("Пользователь не авторизован");
      }
      _currentUserId = userId; // Сохраняем ID

      // Загружаем профиль пользователя ИСПОЛЬЗУЯ СЕРВИС
      _userProfile = await _profileService.getUserProfile(_currentUserId!);
      if (_userProfile == null) {
        throw Exception("Профиль пользователя не найден");
      }

      // Загружаем количество деревьев
      final trees = await _familyService.getUserTrees();
      _treeCount = trees.length;
      _relativeCount = await _loadRelativeCount(
        currentUserId: userId,
        trees: trees,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Ошибка загрузки данных: $e';
        });
      }
      debugPrint('Ошибка при загрузке данных пользователя: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<int> _loadRelativeCount({
    required String currentUserId,
    required List<FamilyTree> trees,
  }) async {
    final relativeIds = <String>{};

    for (final tree in trees) {
      try {
        final relatives = await _familyService.getRelatives(tree.id);
        for (final person in relatives) {
          if (person.userId == currentUserId) {
            continue;
          }
          relativeIds.add(person.id);
        }
      } catch (e) {
        debugPrint('Ошибка при загрузке родственников для профиля: $e');
      }
    }

    return relativeIds.length;
  }

  // Функция для показа диалога добавления/редактирования заметки
  void _showAddEditNoteDialog({ProfileNote? note}) {
    final titleController = TextEditingController(text: note?.title ?? '');
    final contentController = TextEditingController(text: note?.content ?? '');
    final formKey = GlobalKey<FormState>();
    final bool isEditing = note != null;

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isEditing ? 'Редактировать заметку' : 'Добавить заметку'),
          content: Form(
            key: formKey,
            child: SingleChildScrollView(
              // Добавим прокрутку на случай длинного контента
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: titleController,
                    decoration: InputDecoration(labelText: 'Заголовок'),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Пожалуйста, введите заголовок';
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: 16),
                  TextFormField(
                    controller: contentController,
                    decoration: InputDecoration(
                      labelText: 'Содержание',
                      alignLabelWithHint: true, // Выравниваем метку по верху
                    ),
                    maxLines: 5, // Больше строк для удобства
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Пожалуйста, введите содержание';
                      }
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            if (isEditing) // Кнопка удаления только при редактировании
              TextButton(
                child: Text('Удалить', style: TextStyle(color: Colors.red)),
                onPressed: () async {
                  // Запрос подтверждения перед удалением
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Подтверждение'),
                      content: Text(
                        'Вы уверены, что хотите удалить эту заметку?',
                      ),
                      actions: [
                        TextButton(
                          child: Text('Отмена'),
                          onPressed: () => Navigator.of(context).pop(false),
                        ),
                        TextButton(
                          child: Text('Удалить'),
                          onPressed: () => Navigator.of(context).pop(true),
                        ),
                      ],
                    ),
                  );

                  if (confirm == true && _currentUserId != null) {
                    try {
                      await _profileService.deleteProfileNote(
                        _currentUserId!,
                        note.id,
                      );
                      if (!context.mounted) return;
                      Navigator.of(
                        context,
                      ).pop(); // Закрываем диалог редактирования
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Заметка удалена')),
                      );
                    } catch (e) {
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Ошибка удаления: $e')),
                      );
                    }
                  }
                },
              ),
            TextButton(
              child: Text('Отмена'),
              onPressed: () => Navigator.of(context).pop(),
            ),
            TextButton(
              child: Text(isEditing ? 'Сохранить' : 'Добавить'),
              onPressed: () async {
                if (formKey.currentState!.validate() &&
                    _currentUserId != null) {
                  try {
                    if (isEditing) {
                      // Создаем обновленную заметку (со старым id и createdAt)
                      final updatedNote = ProfileNote(
                        id: note.id,
                        title: titleController.text,
                        content: contentController.text,
                        createdAt:
                            note.createdAt, // Сохраняем исходную дату создания
                      );
                      await _profileService.updateProfileNote(
                        _currentUserId!,
                        updatedNote,
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Заметка обновлена')),
                      );
                    } else {
                      await _profileService.addProfileNote(
                        _currentUserId!,
                        titleController.text,
                        contentController.text,
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Заметка добавлена')),
                      );
                    }
                    Navigator.of(context).pop(); // Закрываем диалог
                  } catch (e) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Ошибка сохранения: $e')),
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Получаем TreeProvider, НЕ слушаем изменения здесь, только для нажатия кнопки
    final treeProvider = Provider.of<TreeProvider>(context, listen: false);

    return Scaffold(
      appBar: AppBar(
        title: Text(_getSafeDisplayName(_userProfile!) ?? 'Профиль'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/');
            }
          },
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'settings') {
                context.push('/profile/settings');
              } else if (value == 'about') {
                context.push('/profile/about');
              } else if (value == 'logout') {
                _signOut();
              }
            },
            itemBuilder: (BuildContext context) {
              return [
                PopupMenuItem<String>(
                  value: 'settings',
                  child: Text('Настройки'),
                ),
                PopupMenuItem<String>(
                  value: 'about',
                  child: Text('О приложении'),
                ),
                PopupMenuItem<String>(value: 'logout', child: Text('Выйти')),
              ];
            },
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _errorMessage.isNotEmpty
              ? Center(
                  child: Padding(
                    // Добавим отступы для ошибки
                    padding: const EdgeInsets.all(16.0),
                    child: Text(_errorMessage, textAlign: TextAlign.center),
                  ),
                )
              : _userProfile == null ||
                      _currentUserId == null // Проверяем и userId
                  ? Center(child: Text('Не удалось загрузить профиль.'))
                  : RefreshIndicator(
                      onRefresh: _loadUserData,
                      child: CustomScrollView(
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                children: [
                                  CircleAvatar(
                                    radius: 50,
                                    backgroundImage: _userProfile!.photoURL !=
                                            null
                                        ? NetworkImage(_userProfile!.photoURL!)
                                        : null,
                                    child: _userProfile!.photoURL == null
                                        ? Icon(Icons.person, size: 50)
                                        : null,
                                  ),
                                  SizedBox(height: 16),
                                  Text(
                                    _getSafeDisplayName(_userProfile!),
                                    style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(height: 4),
                                  if ((_userProfile!.city != null &&
                                          _userProfile!.city!.isNotEmpty) ||
                                      (_userProfile!.country != null &&
                                          _userProfile!.country!.isNotEmpty))
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Icon(
                                          Icons.location_on,
                                          size: 16,
                                          color: Colors.grey,
                                        ),
                                        SizedBox(width: 4),
                                        Text(
                                          '${_userProfile!.city ?? ''}${(_userProfile!.city != null && _userProfile!.city!.isNotEmpty && _userProfile!.country != null && _userProfile!.country!.isNotEmpty) ? ', ' : ''}${_userProfile!.country ?? ''}',
                                          style: TextStyle(color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  SizedBox(height: 16),
                                  // Статистика
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      _ProfileStatItem(
                                          label: 'Постов', value: '0'),
                                      _ProfileStatItem(
                                        label: 'Родственники',
                                        value: _relativeCount.toString(),
                                      ),
                                      _ProfileStatItem(
                                        label: 'Деревья',
                                        value: _treeCount.toString(),
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 24),
                                  // Кнопки
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton(
                                          onPressed: () {
                                            // Получаем ID выбранного дерева из провайдера
                                            final currentSelectedTreeId =
                                                treeProvider.selectedTreeId;

                                            if (currentSelectedTreeId == null) {
                                              // Показываем сообщение, если дерево не выбрано
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Сначала выберите активное дерево на вкладке "Дерево" или "Родные"',
                                                  ),
                                                  action: SnackBarAction(
                                                    label: 'Выбрать',
                                                    onPressed: () => context.go(
                                                      '/tree',
                                                    ), // Предлагаем перейти к выбору
                                                  ),
                                                ),
                                              );
                                            } else {
                                              // Переходим на новый экран
                                              context.push(
                                                  '/profile/offline_profiles');
                                            }
                                          },
                                          child: Text('Ваши профили'),
                                        ),
                                      ),
                                      SizedBox(width: 16),
                                      Expanded(
                                        child: ElevatedButton(
                                          onPressed: () =>
                                              context.push('/profile/edit'),
                                          child: Text('Редактировать'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // --- НАЧАЛО: Секция для заметок ---
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                              16.0,
                              16.0,
                              16.0,
                              0,
                            ), // Уменьшим нижний отступ
                            sliver: SliverToBoxAdapter(
                              child: Row(
                                // Используем Row для заголовка и кнопки
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Заметки',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  IconButton(
                                    icon: Icon(Icons.add_circle_outline),
                                    tooltip: 'Добавить заметку',
                                    onPressed: () =>
                                        _showAddEditNoteDialog(), // Вызываем диалог добавления
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // Используем StreamBuilder для отображения заметок
                          StreamBuilder<List<ProfileNote>>(
                            stream: _profileService.getProfileNotesStream(
                              _currentUserId!,
                            ),
                            builder: (context, snapshot) {
                              if (snapshot.connectionState ==
                                  ConnectionState.waiting) {
                                // Показываем индикатор загрузки только для секции заметок
                                return SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Center(
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  ),
                                );
                              }
                              if (snapshot.hasError) {
                                return SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Text(
                                      'Ошибка загрузки заметок: ${snapshot.error}',
                                    ),
                                  ),
                                );
                              }
                              if (!snapshot.hasData || snapshot.data!.isEmpty) {
                                return SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16.0,
                                      vertical: 40.0,
                                    ), // Добавим отступы
                                    child: Center(
                                      child: Text(
                                        'У вас пока нет заметок. Нажмите "+", чтобы добавить первую.',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(color: Colors.grey),
                                      ),
                                    ),
                                  ),
                                );
                              }

                              final notes = snapshot.data!;

                              // Используем SliverGrid для отображения заметок
                              return SliverPadding(
                                padding: const EdgeInsets.all(16.0),
                                sliver: SliverGrid(
                                  gridDelegate:
                                      SliverGridDelegateWithMaxCrossAxisExtent(
                                    maxCrossAxisExtent:
                                        200.0, // Макс. ширина элемента
                                    mainAxisSpacing: 10.0,
                                    crossAxisSpacing: 10.0,
                                    childAspectRatio:
                                        1.0, // Делаем карточки квадратными
                                  ),
                                  delegate: SliverChildBuilderDelegate((
                                    BuildContext context,
                                    int index,
                                  ) {
                                    final note = notes[index];
                                    return InkWell(
                                      // Делаем карточку кликабельной
                                      onTap: () => _showAddEditNoteDialog(
                                        note: note,
                                      ), // Открываем диалог редактирования
                                      child: Card(
                                        elevation: 2,
                                        child: Padding(
                                          padding: const EdgeInsets.all(12.0),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                note.title,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              SizedBox(height: 8),
                                              Expanded(
                                                child: Text(
                                                  note.content,
                                                  style: TextStyle(
                                                    color: Colors.grey[700],
                                                  ),
                                                  overflow: TextOverflow
                                                      .ellipsis, // Обрезаем длинный текст
                                                  maxLines:
                                                      4, // Ограничиваем количество строк
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    );
                                  }, childCount: notes.length),
                                ),
                              );
                            },
                          ),
                          // --- КОНЕЦ: Секция для заметок ---
                        ],
                      ),
                    ),
    );
  }
}
