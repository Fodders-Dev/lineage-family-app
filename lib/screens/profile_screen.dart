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
import '../backend/interfaces/post_service_interface.dart';
import '../models/post.dart';
import '../widgets/post_card.dart';
import '../widgets/post_card_shimmer.dart';
import '../widgets/empty_state_widget.dart';
import '../services/custom_api_post_service.dart';

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

class _ProfileActionButton extends StatelessWidget {
  const _ProfileActionButton({
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    if (filled) {
      return FilledButton(
        onPressed: onPressed,
        child: Text(label),
      );
    }
    return OutlinedButton(
      onPressed: onPressed,
      child: Text(label),
    );
  }
}

String _getSafeDisplayName(UserProfile profile) {
  final rawDisplayName = profile.displayName.trim();

  // Если displayName пустой или равен "Профиль", используем альтернативные источники
  if (rawDisplayName.isEmpty || rawDisplayName == 'Профиль') {
    final parts = <String>[];
    final firstName = profile.firstName.trim();
    if (firstName.isNotEmpty) {
      parts.add(firstName);
    }

    final middleName = profile.middleName.trim();
    if (middleName.isNotEmpty) {
      parts.add(middleName);
    }

    final lastName = profile.lastName.trim();
    if (lastName.isNotEmpty) {
      parts.add(lastName);
    }

    if (parts.isNotEmpty) {
      return parts.join(' ');
    }

    final username = profile.username.trim();
    if (username.isNotEmpty) {
      return username;
    }

    final email = profile.email.trim();
    if (email.isNotEmpty) {
      return email;
    }
  } else {
    // Проверяем, является ли displayName мусорным
    bool looksBad(String value) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return true;
      if (trimmed.length > 80) return true;

      final badWords = ['example.com', 'test123', 'codex', 'mcp', '2026'];
      for (final word in badWords) {
        if (trimmed.toLowerCase().contains(word)) return true;
      }

      final digitCount = RegExp(r'\d').allMatches(trimmed).length;
      if (digitCount >= 6) return true;

      return false;
    }

    if (!looksBad(rawDisplayName)) {
      return rawDisplayName;
    }
  }

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
  final PostServiceInterface _postService = GetIt.I<PostServiceInterface>();
  UserProfile? _userProfile;
  String? _currentUserId; // Храним ID текущего пользователя
  int _treeCount = 0;
  int _relativeCount = 0;
  int _postCount = 0;
  List<Post> _userPosts = [];
  bool _isLoading = true;
  String _errorMessage = '';
  bool _postsUnavailable = false;

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1100;

  String get _appBarTitle {
    final profile = _userProfile;
    if (profile == null) {
      return 'Профиль';
    }

    final displayName = _getSafeDisplayName(profile).trim();
    return displayName.isEmpty ? 'Профиль' : displayName;
  }

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
      _postsUnavailable = false;
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

      try {
        _userPosts = await _postService.getPosts(authorId: userId);
        _postCount = _userPosts.length;
      } on CustomApiPostException catch (error) {
        if (error.statusCode == 404) {
          _userPosts = [];
          _postCount = 0;
          _postsUnavailable = true;
        } else {
          rethrow;
        }
      }
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
        title: Text(_appBarTitle),
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
                              child: ConstrainedBox(
                                constraints:
                                    const BoxConstraints(maxWidth: 1180),
                                child: Container(
                                  padding: const EdgeInsets.all(24),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).colorScheme.surface,
                                    borderRadius: BorderRadius.circular(28),
                                    border: Border.all(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outlineVariant
                                          .withValues(alpha: 0.45),
                                    ),
                                  ),
                                  child: _isWideLayout(context)
                                      ? Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              flex: 2,
                                              child: Column(
                                                children: [
                                                  CircleAvatar(
                                                    radius: 52,
                                                    backgroundImage:
                                                        _userProfile!
                                                                    .photoURL !=
                                                                null
                                                            ? NetworkImage(
                                                                _userProfile!
                                                                    .photoURL!,
                                                              )
                                                            : null,
                                                    child: _userProfile!
                                                                .photoURL ==
                                                            null
                                                        ? Icon(
                                                            Icons.person,
                                                            size: 52,
                                                          )
                                                        : null,
                                                  ),
                                                  const SizedBox(height: 16),
                                                  Text(
                                                    _getSafeDisplayName(
                                                      _userProfile!,
                                                    ),
                                                    textAlign: TextAlign.center,
                                                    style: const TextStyle(
                                                      fontSize: 24,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 24),
                                            Expanded(
                                              flex: 5,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if ((_userProfile!.city !=
                                                              null &&
                                                          _userProfile!.city!
                                                              .isNotEmpty) ||
                                                      (_userProfile!.country !=
                                                              null &&
                                                          _userProfile!.country!
                                                              .isNotEmpty))
                                                    Row(
                                                      children: [
                                                        Icon(
                                                          Icons.location_on,
                                                          size: 16,
                                                          color: Colors.grey,
                                                        ),
                                                        const SizedBox(
                                                            width: 4),
                                                        Text(
                                                          '${_userProfile!.city ?? ''}${(_userProfile!.city != null && _userProfile!.city!.isNotEmpty && _userProfile!.country != null && _userProfile!.country!.isNotEmpty) ? ', ' : ''}${_userProfile!.country ?? ''}',
                                                          style:
                                                              const TextStyle(
                                                            color: Colors.grey,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  const SizedBox(height: 20),
                                                  Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      _ProfileStatItem(
                                                        label: 'Постов',
                                                        value: _postCount
                                                            .toString(),
                                                      ),
                                                      _ProfileStatItem(
                                                        label: 'Родственники',
                                                        value: _relativeCount
                                                            .toString(),
                                                      ),
                                                      _ProfileStatItem(
                                                        label: 'Деревья',
                                                        value: _treeCount
                                                            .toString(),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 24),
                                                  Row(
                                                    children: [
                                                      Expanded(
                                                        child:
                                                            _ProfileActionButton(
                                                          label: 'Ваши профили',
                                                          onPressed: () {
                                                            final currentSelectedTreeId =
                                                                treeProvider
                                                                    .selectedTreeId;
                                                            if (currentSelectedTreeId ==
                                                                null) {
                                                              ScaffoldMessenger
                                                                  .of(
                                                                context,
                                                              ).showSnackBar(
                                                                SnackBar(
                                                                  content:
                                                                      const Text(
                                                                    'Сначала выберите активное дерево на вкладке "Дерево" или "Родные"',
                                                                  ),
                                                                  action:
                                                                      SnackBarAction(
                                                                    label:
                                                                        'Выбрать',
                                                                    onPressed: () =>
                                                                        context
                                                                            .go(
                                                                      '/tree',
                                                                    ),
                                                                  ),
                                                                ),
                                                              );
                                                            } else {
                                                              context.push(
                                                                '/profile/offline_profiles',
                                                              );
                                                            }
                                                          },
                                                        ),
                                                      ),
                                                      const SizedBox(width: 16),
                                                      Expanded(
                                                        child:
                                                            _ProfileActionButton(
                                                          label:
                                                              'Редактировать',
                                                          filled: true,
                                                          onPressed: () =>
                                                              context.push(
                                                            '/profile/edit',
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        )
                                      : Column(
                                          children: [
                                            CircleAvatar(
                                              radius: 50,
                                              backgroundImage:
                                                  _userProfile!.photoURL != null
                                                      ? NetworkImage(
                                                          _userProfile!
                                                              .photoURL!,
                                                        )
                                                      : null,
                                              child:
                                                  _userProfile!.photoURL == null
                                                      ? Icon(
                                                          Icons.person,
                                                          size: 50,
                                                        )
                                                      : null,
                                            ),
                                            const SizedBox(height: 16),
                                            Text(
                                              _getSafeDisplayName(
                                                  _userProfile!),
                                              style: const TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            if ((_userProfile!.city != null &&
                                                    _userProfile!
                                                        .city!.isNotEmpty) ||
                                                (_userProfile!.country !=
                                                        null &&
                                                    _userProfile!
                                                        .country!.isNotEmpty))
                                              Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    Icons.location_on,
                                                    size: 16,
                                                    color: Colors.grey,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    '${_userProfile!.city ?? ''}${(_userProfile!.city != null && _userProfile!.city!.isNotEmpty && _userProfile!.country != null && _userProfile!.country!.isNotEmpty) ? ', ' : ''}${_userProfile!.country ?? ''}',
                                                    style: const TextStyle(
                                                      color: Colors.grey,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            const SizedBox(height: 16),
                                            Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.spaceEvenly,
                                              children: [
                                                _ProfileStatItem(
                                                  label: 'Постов',
                                                  value: _postCount.toString(),
                                                ),
                                                _ProfileStatItem(
                                                  label: 'Родственники',
                                                  value:
                                                      _relativeCount.toString(),
                                                ),
                                                _ProfileStatItem(
                                                  label: 'Деревья',
                                                  value: _treeCount.toString(),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 24),
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: _ProfileActionButton(
                                                    label: 'Ваши профили',
                                                    onPressed: () {
                                                      final currentSelectedTreeId =
                                                          treeProvider
                                                              .selectedTreeId;
                                                      if (currentSelectedTreeId ==
                                                          null) {
                                                        ScaffoldMessenger.of(
                                                          context,
                                                        ).showSnackBar(
                                                          SnackBar(
                                                            content: const Text(
                                                              'Сначала выберите активное дерево на вкладке "Дерево" или "Родные"',
                                                            ),
                                                            action:
                                                                SnackBarAction(
                                                              label: 'Выбрать',
                                                              onPressed: () =>
                                                                  context.go(
                                                                '/tree',
                                                              ),
                                                            ),
                                                          ),
                                                        );
                                                      } else {
                                                        context.push(
                                                          '/profile/offline_profiles',
                                                        );
                                                      }
                                                    },
                                                  ),
                                                ),
                                                const SizedBox(width: 16),
                                                Expanded(
                                                  child: _ProfileActionButton(
                                                    label: 'Редактировать',
                                                    filled: true,
                                                    onPressed: () => context
                                                        .push('/profile/edit'),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                ),
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

                          // --- НАЧАЛО: Секция для постов пользователя ---
                          SliverPadding(
                            padding: const EdgeInsets.fromLTRB(
                                16.0, 24.0, 16.0, 8.0),
                            sliver: SliverToBoxAdapter(
                              child: Text(
                                'Ваши публикации',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                          if (_isLoading && _userPosts.isEmpty)
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) => const PostCardShimmer(),
                                childCount: 2,
                              ),
                            )
                          else if (_userPosts.isEmpty)
                            SliverToBoxAdapter(
                              child: EmptyStateWidget(
                                icon: Icons.post_add_outlined,
                                title: _postsUnavailable
                                    ? 'Публикации временно недоступны'
                                    : 'Публикаций пока нет',
                                message: _postsUnavailable
                                    ? 'Лента профиля появится, когда backend публикаций будет доступен для этого аккаунта.'
                                    : 'Ваши истории и фотографии появятся здесь.',
                                actionLabel:
                                    _postsUnavailable ? 'Обновить' : 'Создать',
                                onAction: () async {
                                  if (_postsUnavailable) {
                                    _loadUserData();
                                    return;
                                  }
                                  final result =
                                      await context.push('/post/create');
                                  if (result == true) {
                                    _loadUserData();
                                  }
                                },
                              ),
                            )
                          else
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  return PostCard(
                                    post: _userPosts[index],
                                    onDeleted: () => _loadUserData(),
                                  );
                                },
                                childCount: _userPosts.length,
                              ),
                            ),
                          const SliverToBoxAdapter(child: SizedBox(height: 40)),
                          // --- КОНЕЦ: Секция для постов пользователя ---
                        ],
                      ),
                    ),
    );
  }
}
