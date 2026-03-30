import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';

enum _PostSaveAction { close, stayInQuickAdd, openInTree }

class AddRelativeScreen extends StatefulWidget {
  final String treeId;
  final FamilyPerson? person;
  final FamilyPerson? relatedTo;
  final bool isEditing;
  final RelationType? predefinedRelation;
  final bool quickAddMode;

  const AddRelativeScreen({
    super.key,
    required this.treeId,
    this.person,
    this.relatedTo,
    this.isEditing = false,
    this.predefinedRelation,
    this.quickAddMode = false,
  });

  @override
  State<AddRelativeScreen> createState() => _AddRelativeScreenState();
}

class _AddRelativeScreenState extends State<AddRelativeScreen> {
  final _formKey = GlobalKey<FormState>();
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();

  // Контроллеры для полей формы
  final _lastNameController = TextEditingController();
  final _firstNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _maidenNameController = TextEditingController();
  final _birthPlaceController = TextEditingController();
  final _notesController = TextEditingController();

  // Состояние формы
  DateTime? _birthDate;
  DateTime? _deathDate;
  Gender? _selectedGender;
  RelationType? _selectedRelationType;
  RelationType? _initialRelationType;
  Gender _gender = Gender.unknown; // Пол текущего пользователя
  bool _isLoading = false;
  bool _isCheckingTreeState = true;
  bool _isFirstPersonInTree = false;

  // Переменные для контекста из дерева
  FamilyPerson? _contextPerson;
  RelationType? _contextRelationType;
  bool _isLoadingContext = false;
  bool _isQuickAddMode = false;

  @override
  void initState() {
    super.initState();
    _isQuickAddMode = widget.quickAddMode;
    _loadUserGender();
    _loadTreeState();

    // Если редактируем существующего человека, заполняем форму его данными
    if (widget.isEditing && widget.person != null) {
      final nameParts = widget.person!.name.split(' ');
      String lastName = '';
      String firstName = '';
      String? middleName;
      if (nameParts.isNotEmpty) lastName = nameParts[0];
      if (nameParts.length >= 2) firstName = nameParts[1];
      if (nameParts.length >= 3) middleName = nameParts.sublist(2).join(' ');
      // -------------------------------------------------------------------
      _lastNameController.text = lastName;
      _firstNameController.text = firstName;
      _middleNameController.text = middleName ?? '';
      _maidenNameController.text = widget.person!.maidenName ?? '';
      _birthPlaceController.text = widget.person!.birthPlace ?? '';
      _notesController.text = widget.person!.notes ?? '';
      _selectedGender = widget.person!.gender;
      _birthDate = widget.person!.birthDate;
      _deathDate = widget.person!.deathDate;

      // Загружаем текущий тип отношения (правильно)
      _loadCurrentRelationType();
    }

    // Если добавляем к существующему родственнику, но не редактируем
    if (widget.relatedTo != null && !widget.isEditing) {
      // Используем predefinedRelation, если он есть
      if (widget.predefinedRelation != null) {
        setState(() {
          _selectedRelationType = widget.predefinedRelation;
          // Опционально: можно попытаться угадать пол на основе связи,
          // но это может быть не всегда точно (например, для spouse/sibling).
          // Пока оставим пол неопределенным.
          _selectedGender = null;
        });
      } else {
        // Если predefinedRelation нет, предлагаем тип по умолчанию (например, ребенок)
        _loadRelationType(); // Старая логика для RelationType по умолчанию
      }
    }

    // Обновляем виджет связи при изменении имени/фамилии или пола
    _firstNameController.addListener(_updateRelationshipWidget);
    _lastNameController.addListener(_updateRelationshipWidget);

    // Сначала проверяем контекст из GoRouter
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final extra = GoRouterState.of(context).extra;
      debugPrint('AddRelativeScreen initState: extra = $extra');
      if (extra is Map<String, dynamic> &&
          extra.containsKey('contextPersonId') &&
          extra.containsKey('relationType')) {
        final quickAddMode = extra['quickAddMode'] == true;
        final String contextPersonId = extra['contextPersonId'];
        final RelationType relationType = extra['relationType'];
        debugPrint(
          "AddRelativeScreen initState: Found context from tree. Person ID: $contextPersonId, Relation: $relationType",
        );
        if (quickAddMode != _isQuickAddMode) {
          setState(() {
            _isQuickAddMode = quickAddMode;
          });
        }
        _loadContextPerson(contextPersonId, relationType);
      } else if (widget.relatedTo != null) {
        // Используем relatedTo и predefinedRelation, если они переданы (из Details)
        debugPrint(
          "AddRelativeScreen initState: Using relatedTo from widget: ${widget.relatedTo!.id}",
        );
        setState(() {
          _selectedRelationType = widget.predefinedRelation;
          // Предзаполнение пола на основе predefinedRelation и пола relatedTo
          _prefillGenderBasedOnRelation(
            widget.relatedTo!,
            widget.predefinedRelation,
          );
          _prefillLastNameFromAnchor(
            widget.relatedTo,
            widget.predefinedRelation,
          );
        });
      } else {
        // Добавление родственника к текущему пользователю
        debugPrint(
          'AddRelativeScreen initState: Adding relative to current user.',
        );
        // Оставляем _selectedRelationType = null, пользователь выберет сам
      }
    });
  }

  bool get _isCreatingFirstPerson =>
      !widget.isEditing &&
      widget.relatedTo == null &&
      _contextPerson == null &&
      _isFirstPersonInTree;

  bool get _isBusy => _isLoading || _isLoadingContext || _isCheckingTreeState;

  bool get _isContextualAdd =>
      !widget.isEditing && (_contextPerson != null || widget.relatedTo != null);

  FamilyPerson? get _anchorPerson => _contextPerson ?? widget.relatedTo;

  RelationType? get _resolvedRelationType =>
      _contextRelationType ??
      widget.predefinedRelation ??
      _selectedRelationType;

  bool get _canUseQuickAddLoop => _isQuickAddMode && _isContextualAdd;

  Future<void> _loadTreeState() async {
    try {
      final relatives = await _familyService.getRelatives(widget.treeId);
      if (!mounted) return;
      setState(() {
        _isFirstPersonInTree = relatives.isEmpty;
        _isCheckingTreeState = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isCheckingTreeState = false;
      });
      debugPrint('Ошибка при определении состояния дерева: $e');
    }
  }

  void _updateRelationshipWidget() {
    // Перерисовываем виджет связи, чтобы обновить имя "Новый родственник"
    setState(() {});
  }

  Future<void> _pickDate(bool isBirthDate) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: isBirthDate
          ? (_birthDate ?? DateTime.now())
          : (_deathDate ?? DateTime.now()),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      locale: const Locale('ru', 'RU'),
    );

    if (picked != null) {
      setState(() {
        if (isBirthDate) {
          _birthDate = picked;
        } else {
          _deathDate = picked;
        }
      });
    }
  }

  Future<void> _savePerson({
    _PostSaveAction action = _PostSaveAction.close,
  }) async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        String? createdPersonId;

        // Создаем объект с данными из формы
        final Map<String, dynamic> personData = {
          'firstName': _firstNameController.text.trim(),
          'lastName': _lastNameController.text.trim(),
          'middleName': _middleNameController.text.trim(),
          'gender': _selectedGender != null
              ? _genderToString(_selectedGender!)
              : 'unknown',
          'birthPlace': _birthPlaceController.text.trim(),
          'notes': _notesController.text.trim(),
        };

        // Добавляем даты, если они указаны
        if (_birthDate != null) {
          personData['birthDate'] = _birthDate;
        }

        if (_deathDate != null) {
          personData['deathDate'] = _deathDate;
        }

        // Добавляем девичью фамилию для женщин
        if (_selectedGender == Gender.female &&
            _maidenNameController.text.isNotEmpty) {
          personData['maidenName'] = _maidenNameController.text.trim();
        }

        // Если редактируем существующего человека
        if (widget.isEditing) {
          if (widget.person != null) {
            // 1. Обновляем данные самого человека
            debugPrint('Сохранение редактирования: ID=${widget.person!.id}');
            debugPrint(
              'Значение _selectedGender перед сохранением: $_selectedGender',
            );
            debugPrint('Данные для сохранения (personData): $personData');
            await _familyService.updateRelative(widget.person!.id, personData);

            // 2. Обновляем связь, если она изменилась
            final userId = _authService.currentUserId;
            if (userId != null &&
                _selectedRelationType != null &&
                _selectedRelationType != RelationType.other &&
                _selectedRelationType != _initialRelationType) {
              debugPrint(
                'Обновляем связь: $_selectedRelationType между ${widget.person!.id} и $userId',
              );
              try {
                // Вызываем addRelation с позиционными аргументами
                await _familyService.addRelation(
                  widget.treeId,
                  widget.person!.id, // Редактируемый человек
                  userId, // Текущий пользователь
                  _selectedRelationType!, // Новое отношение person1 -> person2
                );
                // Обновляем _initialRelationType после успешного сохранения
                _initialRelationType = _selectedRelationType;
                debugPrint('Связь успешно обновлена.');
              } catch (e) {
                debugPrint('Ошибка при обновлении связи: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Не удалось обновить связь: $e')),
                  );
                }
                // Не выходим из функции, так как данные человека могли обновиться
              }
            } else if (_selectedRelationType == _initialRelationType) {
              debugPrint('Связь не изменилась, обновление не требуется.');
            } else {
              debugPrint(
                'Связь не выбрана или не изменилась, обновление связи не выполняется.',
              );
            }

            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Информация о родственнике обновлена')),
              );
            }
          } else {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Ошибка: Не удалось определить ID редактируемого родственника',
                  ),
                ),
              );
            }
            return; // Выходим, если некого редактировать
          }
        } else {
          // 2. Добавление нового родственника
          // addRelative теперь принимает только treeId и personData
          final newPersonId = await _familyService.addRelative(
            widget.treeId,
            personData,
          );
          createdPersonId = newPersonId;

          // Получаем ID текущего пользователя
          final userId = _authService.currentUserId;
          if (userId == null) {
            throw Exception('Не удалось получить ID текущего пользователя.');
          }

          // Получаем выбранный тип отношения
          final relationType = _getRelationType();

          // Проверяем, что тип отношения выбран
          if (relationType != RelationType.other) {
            // Определяем ID второго человека в связи (КОГО связываем с новым)
            final String person2Id;
            if (_contextPerson != null) {
              person2Id = _contextPerson!.id; // Приоритет: контекст из дерева
            } else if (widget.relatedTo != null) {
              person2Id =
                  widget.relatedTo!.id; // Приоритет: переданный relatedTo
            } else {
              person2Id = userId; // По умолчанию: текущий пользователь
            }

            // Если добавляем не к себе и не к текущему пользователю,
            // то создаем связь между новым человеком и тем, к кому добавляли (или с пользователем)
            if (newPersonId != person2Id) {
              try {
                // Создаем основную связь (например, newPersonId -> relationType -> person2Id)
                await _familyService.createRelation(
                  treeId: widget.treeId,
                  person1Id: newPersonId,
                  person2Id: person2Id,
                  relation1to2: relationType,
                  isConfirmed: true,
                );
                debugPrint(
                  'Основная связь создана: $newPersonId ($relationType) -> $person2Id',
                );

                // --- Автоматическое доопределение связей ---
                if (relationType == RelationType.parent) {
                  // Если ДОБАВИЛИ РОДИТЕЛЯ (newPersonId) к ребенку (person2Id)
                  await _familyService.checkAndCreateSpouseRelationIfNeeded(
                    widget.treeId,
                    person2Id,
                    newPersonId,
                  );
                  // TODO: Добавить вызов для создания связи дедушка/бабушка-внук/внучка
                } else if (relationType == RelationType.child) {
                  // Если ДОБАВИЛИ РЕБЕНКА (newPersonId) к родителю (person2Id)
                  // --- NEW: Проверяем, есть ли супруг у родителя, к которому добавили ребенка ---
                  final String parentId =
                      person2Id; // Родитель, к которому добавили
                  final String childId = newPersonId; // Добавленный ребенок

                  final spouseId = await _familyService.findSpouseId(
                    widget.treeId,
                    parentId,
                  );
                  debugPrint(
                    'Проверка супруга для родителя $parentId: найден spouseId = $spouseId',
                  );

                  if (mounted && spouseId != null) {
                    // Проверяем mounted перед асинхронными операциями
                    // Загружаем данные родителя, супруга и ребенка для диалога
                    final FamilyPerson parentPerson =
                        await _familyService.getPersonById(
                      widget.treeId,
                      parentId,
                    ); // Нужен метод getPersonById
                    final FamilyPerson spousePerson = await _familyService
                        .getPersonById(widget.treeId, spouseId);
                    final FamilyPerson childPerson = await _familyService
                        .getPersonById(widget.treeId, childId);

                    if (mounted) {
                      // Проверяем mounted снова
                      // Показываем диалог
                      bool? confirmSecondParent = await showDialog<bool>(
                        context: context,
                        builder: (BuildContext context) {
                          return AlertDialog(
                            title: Text('Подтвердить второго родителя?'),
                            content: Text(
                              'Является ли ${spousePerson.name} (${_getRelationNameForDialog(RelationType.spouse, spousePerson.gender)}) для ${parentPerson.name}) также родителем для ${childPerson.name}?',
                            ),
                            actions: <Widget>[
                              TextButton(
                                child: Text('Нет'),
                                onPressed: () {
                                  Navigator.of(
                                    context,
                                  ).pop(false); // Возвращаем false
                                },
                              ),
                              TextButton(
                                child: Text('Да'),
                                onPressed: () {
                                  Navigator.of(
                                    context,
                                  ).pop(true); // Возвращаем true
                                },
                              ),
                            ],
                          );
                        },
                      );

                      debugPrint(
                        'Результат диалога подтверждения второго родителя: $confirmSecondParent',
                      );

                      // Если пользователь подтвердил, создаем вторую связь
                      if (confirmSecondParent == true) {
                        debugPrint(
                          'Создание второй родительской связи: $spouseId (parent) -> $childId',
                        );
                        try {
                          await _familyService.createRelation(
                            treeId: widget.treeId,
                            person1Id: spouseId,
                            person2Id: childId,
                            relation1to2: RelationType.parent,
                            isConfirmed: true,
                          );
                          debugPrint(
                              'Вторая родительская связь успешно создана.');
                        } catch (e) {
                          debugPrint(
                            'Ошибка создания второй родительской связи: $e',
                          );
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  'Не удалось создать связь с ${spousePerson.name}: $e',
                                ),
                              ),
                            );
                          }
                        }
                      }
                    } else {
                      debugPrint(
                        'Не удалось загрузить данные для диалога подтверждения второго родителя.',
                      );
                    }
                  }
                  // --- END NEW ---
                } else if (relationType == RelationType.sibling) {
                  // Если ДОБАВИЛИ СИБЛИНГА (newPersonId) к другому сиблингу (person2Id)
                  await _familyService.checkAndCreateParentSiblingRelations(
                    widget.treeId,
                    person2Id,
                    newPersonId,
                  );
                }
                // --- Конец автоматического доопределения ---
              } catch (e) {
                debugPrint('Ошибка создания связи: $e');
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Не удалось создать связь: $e')),
                  );
                }
              }
            } else {
              debugPrint(
                "Попытка создать связь человека с самим собой проигнорирована.",
              );
            }
          } else {
            debugPrint(
                "Тип отношения не выбран или 'other', связь не создается.");
            // Опционально: показать сообщение пользователю
          }
        }

        if (!mounted) {
          return;
        }

        if (!widget.isEditing &&
            createdPersonId != null &&
            action == _PostSaveAction.stayInQuickAdd &&
            _canUseQuickAddLoop) {
          _prepareForNextQuickAddCycle();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Человек добавлен. Можно сразу заполнить следующую карточку.',
              ),
            ),
          );
          return;
        }

        if (!widget.isEditing &&
            createdPersonId != null &&
            action == _PostSaveAction.openInTree) {
          Navigator.pop(context, <String, dynamic>{
            'updated': true,
            'createdPersonId': createdPersonId,
            'focusPersonId': createdPersonId,
            'keepEditMode': true,
          });
          return;
        }

        Navigator.pop(
          context,
          true,
        ); // Возвращаем true для обновления предыдущего экрана
      } catch (e) {
        debugPrint('Ошибка при сохранении: $e');
        if (mounted) {
          // Проверяем mounted перед показом SnackBar
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Произошла ошибка: $e')));
        }
      } finally {
        if (mounted) {
          // Проверяем mounted перед setState
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  void _prepareForNextQuickAddCycle() {
    _firstNameController.clear();
    _middleNameController.clear();
    _maidenNameController.clear();
    _birthPlaceController.clear();
    _notesController.clear();
    _birthDate = null;
    _deathDate = null;
    _selectedGender = null;
    if (_lastNameController.text.trim().isEmpty) {
      _prefillLastNameFromAnchor(_anchorPerson, _resolvedRelationType);
    }
    final anchorPerson = _anchorPerson;
    if (anchorPerson != null) {
      _prefillGenderBasedOnRelation(anchorPerson, _resolvedRelationType);
    }
    _formKey.currentState?.reset();
    setState(() {});
  }

  void _prefillLastNameFromAnchor(
    FamilyPerson? anchorPerson,
    RelationType? relationType,
  ) {
    if (anchorPerson == null || _lastNameController.text.trim().isNotEmpty) {
      return;
    }
    if (relationType == RelationType.spouse ||
        relationType == RelationType.partner) {
      return;
    }
    final surname = _extractSurname(anchorPerson.name);
    if (surname.isNotEmpty) {
      _lastNameController.text = surname;
    }
  }

  String _extractSurname(String fullName) {
    final parts = fullName
        .split(' ')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      return '';
    }
    return parts.first;
  }

  List<DropdownMenuItem<RelationType>> _getRelationTypeItems(
    Gender? anchorGender,
  ) {
    // Используем статический метод из FamilyRelation для получения и фильтрации связей
    return FamilyRelation.getAvailableRelationTypes(anchorGender)
        .map(
          (type) => DropdownMenuItem(
            value: type,
            // Используем статический метод для получения описания
            // Передаем пол *нового* человека (_selectedGender)
            child: Text(
              FamilyRelation.getRelationDescription(type, _selectedGender),
            ),
          ),
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_buildScreenTitle()),
        actions: [
          if (widget.isEditing)
            IconButton(
              icon: Icon(Icons.person_add),
              tooltip: 'Добавить родственника',
              onPressed: () {
                _showAddRelativeDialog();
              },
            ),
          if (widget.isEditing)
            IconButton(
              icon: Icon(Icons.delete),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text('Удаление родственника'),
                    content: Text(
                      'Вы уверены, что хотите удалить этого родственника?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text('Отмена'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _deletePerson();
                        },
                        child: Text(
                          'Удалить',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
      body: _isBusy
          ? Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: SingleChildScrollView(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!widget.isEditing) _buildIntroCard(),

                    if (!widget.isEditing) SizedBox(height: 16),

                    if (!widget.isEditing) _buildRequiredNowCard(),

                    SizedBox(height: 24),

                    if (!widget.isEditing && _canUseQuickAddLoop) ...[
                      _buildQuickAddToolbar(),
                      SizedBox(height: 24),
                    ],

                    // Основная информация
                    Text(
                      'Основная информация',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    SizedBox(height: 16),

                    // Фамилия
                    TextFormField(
                      controller: _lastNameController,
                      decoration: InputDecoration(
                        labelText: 'Фамилия',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Пожалуйста, введите фамилию';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 16),

                    // Имя
                    TextFormField(
                      controller: _firstNameController,
                      autofocus: !widget.isEditing,
                      decoration: InputDecoration(
                        labelText: 'Имя',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Пожалуйста, введите имя';
                        }
                        return null;
                      },
                    ),
                    SizedBox(height: 16),

                    // Отчество
                    TextFormField(
                      controller: _middleNameController,
                      decoration: InputDecoration(
                        labelText: 'Отчество',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                    SizedBox(height: 24),

                    // Пол
                    Text(
                      'Пол',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        ChoiceChip(
                          label: const Text('Мужской'),
                          avatar: const Icon(Icons.male, size: 18),
                          selected: _selectedGender == Gender.male,
                          selectedColor: Colors.blue.shade100,
                          onSelected: (_) {
                            setState(() {
                              _selectedGender = Gender.male;
                            });
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Женский'),
                          avatar: const Icon(Icons.female, size: 18),
                          selected: _selectedGender == Gender.female,
                          selectedColor: Colors.pink.shade100,
                          onSelected: (_) {
                            setState(() {
                              _selectedGender = Gender.female;
                            });
                          },
                        ),
                      ],
                    ),
                    SizedBox(height: 24),

                    // Виджет выбора родственной связи
                    _buildRelationshipSelector(),
                    SizedBox(height: 24),

                    _buildOptionalDetailsSection(),
                    SizedBox(height: 24),

                    _buildSubmitSection(),
                    SizedBox(height: 32),
                  ],
                ),
              ),
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

  Widget _buildIntroCard() {
    final theme = Theme.of(context);
    final bool isContextAdd = _isContextualAdd;

    final String title = _isCreatingFirstPerson
        ? 'Начните дерево с одного человека'
        : _canUseQuickAddLoop
            ? 'Быстрое добавление в ветку'
            : isContextAdd
                ? 'Вы добавляете родственника к ${_anchorPerson!.name}'
                : 'Вы добавляете нового родственника в своё дерево';

    final String description = _isCreatingFirstPerson
        ? 'Сначала достаточно имени и пола. Родственную связь можно указать позже, когда в дереве появится опорный человек.'
        : _canUseQuickAddLoop
            ? 'Форма упрощена под серию добавлений. После сохранения можно сразу заполнить следующую карточку или вернуться на дерево к новому человеку.'
            : isContextAdd
                ? 'Заполните данные и проверьте связь. После сохранения человек сразу появится в схеме.'
                : 'Заполните карточку и укажите, кем этот человек является для вас.';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.blue.shade100),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _isCreatingFirstPerson
                      ? Icons.account_tree
                      : Icons.info_outline,
                  color: Colors.blue,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              description,
              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequiredNowCard() {
    final theme = Theme.of(context);
    final relationType = _resolvedRelationType;
    final anchorPerson = _anchorPerson;
    final helperItems = [
      if (_isCreatingFirstPerson) 'Достаточно заполнить имя, фамилию и пол',
      if (anchorPerson != null && relationType != null)
        'Связь с ${anchorPerson.name} уже выбрана: ${_relationTypeToActionObject(relationType)}',
      if (_canUseQuickAddLoop)
        'После добавления можно сразу создать ещё одного родственника в этой же ветке',
      if (anchorPerson == null && !_isCreatingFirstPerson)
        'Связь можно указать после заполнения основной информации',
      _canUseQuickAddLoop
          ? 'Когда нужно вернуться к схеме, используйте кнопку "Добавить и открыть на дереве"'
          : 'После сохранения вы вернётесь обратно в дерево',
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Что нужно сейчас',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              _RequiredChip(label: 'Фамилия'),
              _RequiredChip(label: 'Имя'),
              _RequiredChip(label: 'Пол'),
            ],
          ),
          const SizedBox(height: 12),
          ...helperItems.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.arrow_right_alt,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOptionalDetailsSection() {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      initiallyExpanded: widget.isEditing && !_canUseQuickAddLoop,
      title: const Text(
        'Дополнительные сведения',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
      ),
      subtitle: Text(
        _isCreatingFirstPerson
            ? 'Можно заполнить позже: даты, место рождения, заметки'
            : 'Даты жизни, место рождения и заметки',
      ),
      children: [
        const SizedBox(height: 8),
        if (_selectedGender == Gender.female) ...[
          TextFormField(
            controller: _maidenNameController,
            decoration: const InputDecoration(
              labelText: 'Девичья фамилия',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person_outline),
              helperText: 'Фамилия до замужества',
            ),
          ),
          const SizedBox(height: 16),
        ],
        InkWell(
          onTap: () => _pickDate(true),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Дата рождения',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.cake),
            ),
            child: Text(
              _birthDate != null
                  ? DateFormat('dd.MM.yyyy').format(_birthDate!)
                  : 'Выберите дату',
            ),
          ),
        ),
        const SizedBox(height: 16),
        InkWell(
          onTap: () => _pickDate(false),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Дата смерти',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.event),
              helperText: 'Оставьте пустым, если человек жив',
            ),
            child: Text(
              _deathDate != null
                  ? DateFormat('dd.MM.yyyy').format(_deathDate!)
                  : 'Не указано',
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _birthPlaceController,
          decoration: const InputDecoration(
            labelText: 'Место рождения',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.location_on),
          ),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _notesController,
          decoration: const InputDecoration(
            labelText: 'Заметки',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.note),
            helperText: 'Дополнительная информация о человеке',
          ),
          maxLines: 3,
        ),
      ],
    );
  }

  @override
  void dispose() {
    _lastNameController.removeListener(_updateRelationshipWidget);
    _firstNameController.removeListener(_updateRelationshipWidget);
    _lastNameController.dispose();
    _firstNameController.dispose();
    _middleNameController.dispose();
    _maidenNameController.dispose();
    _birthPlaceController.dispose();
    _notesController.dispose();
    super.dispose();
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
        Text(
          'Родственная связь',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        SizedBox(height: 16),

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
        if (anchorPerson == null || isEditingMode)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _isCreatingFirstPerson
                    ? 'Связь с вами'
                    : isAddingToSelf
                        ? 'Кем этот человек является для вас?'
                        : 'Кем этот человек является для вас?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              SizedBox(height: 8),
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
                  setState(() {
                    _selectedRelationType = newValue;
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
        ],
      ),
    );
  }

  Widget _buildQuickAddToolbar() {
    if (!_canUseQuickAddLoop) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final anchorPerson = _anchorPerson;
    final relationType = _resolvedRelationType;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
            color: theme.colorScheme.secondary.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.bolt, color: theme.colorScheme.secondary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Режим быстрого ввода',
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
              if (anchorPerson != null)
                _QuickInfoChip(
                  icon: Icons.person_pin_circle_outlined,
                  label: anchorPerson.name,
                ),
              if (relationType != null)
                _QuickInfoChip(
                  icon: Icons.family_restroom,
                  label: _relationTypeToActionObject(relationType),
                ),
              const _QuickInfoChip(
                icon: Icons.restart_alt,
                label: 'Серия добавлений',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Подходит для сценария, когда вы по очереди вносите детей, братьев, родителей или всю ветку одной семьи.',
            style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildSubmitSection() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 50,
          child: ElevatedButton(
            onPressed: _isBusy ? null : () => _savePerson(),
            child: Text(
              _buildPrimaryActionLabel(),
              style: const TextStyle(fontSize: 16),
            ),
          ),
        ),
        if (_canUseQuickAddLoop) ...[
          const SizedBox(height: 12),
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
        ],
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
              setState(() {
                _selectedRelationType = newValue;
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
      default:
        return FamilyRelation.getGenericRelationTypeStringRu(type)
            .toLowerCase();
    }
  }

  Future<void> _deletePerson() async {
    if (widget.person == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      // Удаляем человека и все его связи
      await _familyService.deleteRelative(widget.treeId, widget.person!.id);
      if (!mounted) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Родственник удален')));

      Navigator.pop(context, true);
    } catch (e) {
      debugPrint('Ошибка при удалении: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка при удалении: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadUserGender() async {
    try {
      final currentUserProfile = await _profileService.getCurrentUserProfile();
      final genderStr = currentUserProfile?.gender;
      if (genderStr != null) {
        setState(() {
          _gender = genderStr;
        });
      }
    } catch (e) {
      debugPrint('Ошибка при загрузке пола пользователя: $e');
    }
  }

  Future<void> _loadRelationType() async {
    if (widget.relatedTo == null) return;

    try {
      // Если есть начальный тип отношения, используем его
      if (widget.predefinedRelation != null) {
        setState(() {
          _selectedRelationType = widget.predefinedRelation;

          // Автоматически определяем пол на основе выбранной связи
          if (_selectedRelationType == RelationType.spouse) {
            // Для супруга/супруги определяем противоположный пол
            _selectedGender = widget.relatedTo!.gender == Gender.male
                ? Gender.female
                : Gender.male;
          } else {
            // Для других типов связей не предполагаем конкретный пол
            _selectedGender = null;
          }
        });
      } else if (widget.relatedTo != null) {
        // Если нет начального типа отношения, предлагаем наиболее вероятный
        setState(() {
          // По умолчанию предлагаем "ребенок" для добавления к родственнику
          _selectedRelationType = RelationType.child;

          // Автоматически определяем пол на основе выбранной связи
          // Для ребенка не предполагаем конкретный пол
          _selectedGender = null;
        });
        _prefillLastNameFromAnchor(widget.relatedTo, RelationType.child);
      }
    } catch (e) {
      debugPrint('Ошибка при загрузке типа отношения: $e');
    }
  }

  // Метод для загрузки текущего типа отношения при редактировании
  Future<void> _loadCurrentRelationType() async {
    final userId = _authService.currentUserId;
    if (userId == null || widget.person == null || !widget.isEditing) return;

    try {
      // Получаем отношение пользователя к редактируемому человеку
      final relationUserToPerson = await _familyService.getRelationToUser(
        widget.treeId,
        widget.person!.id, // ID редактируемого человека
      );

      // Получаем обратное отношение (редактируемого человека к пользователю)
      final relationPersonToUser = FamilyRelation.getMirrorRelation(
        relationUserToPerson,
      );

      debugPrint(
        'Загружен текущий тип отношения (от ${widget.person!.id} к $userId): $relationPersonToUser',
      );

      if (mounted) {
        setState(() {
          _selectedRelationType = relationPersonToUser;
          _initialRelationType =
              relationPersonToUser; // Сохраняем для сравнения
        });
      }
    } catch (e) {
      debugPrint('Ошибка при загрузке типа текущего отношения: $e');
      if (mounted) {
        setState(() {
          _selectedRelationType =
              RelationType.other; // Ставим other в случае ошибки
          _initialRelationType = RelationType.other;
        });
      }
    }
  }

  // Метод для показа диалога добавления родственника
  void _showAddRelativeDialog() {
    if (widget.person == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Добавить родственника'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Кого вы хотите добавить для ${widget.person!.name}?'),
            SizedBox(height: 15),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _navigateToAddRelative(RelationType.parent);
              },
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 40),
              ),
              child: Text('Родителя'),
            ),
            SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _navigateToAddRelative(RelationType.child);
              },
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 40),
              ),
              child: Text('Ребенка'),
            ),
            SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _navigateToAddRelative(RelationType.spouse);
              },
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 40),
              ),
              child: Text('Супруга/Супругу'),
            ),
            SizedBox(height: 10),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _navigateToAddRelative(RelationType.sibling);
              },
              style: ElevatedButton.styleFrom(
                minimumSize: Size(double.infinity, 40),
              ),
              child: Text('Брата/Сестру'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Отмена'),
          ),
        ],
      ),
    );
  }

  // Метод для перехода на экран добавления родственника
  Future<void> _navigateToAddRelative(RelationType relationType) async {
    final success = await context.push(
      '/relatives/add/${widget.treeId}',
      extra: {
        'contextPersonId': widget.person!.id,
        'relationType': relationType,
        'quickAddMode': true,
      },
    );
    if (!mounted) return;

    if (success == true ||
        (success is Map<String, dynamic> && success['updated'] == true)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Родственник успешно добавлен'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // Вспомогательный метод для преобразования Gender в строку
  String _genderToString(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'male';
      case Gender.female:
        return 'female';
      case Gender.other:
        return 'other';
      case Gender.unknown:
        return 'unknown';
    }
  }

  // Добавляем недостающий метод
  RelationType _getRelationType() {
    return _selectedRelationType ?? RelationType.other;
  }

  // Загрузка данных Person из контекста дерева
  Future<void> _loadContextPerson(
    String personId,
    RelationType relationType,
  ) async {
    if (!mounted) return;
    setState(() {
      _isLoadingContext = true;
      _contextRelationType = relationType;
      _selectedRelationType = relationType; // Сразу выбираем отношение
    });
    debugPrint(
        'AddRelativeScreen _loadContextPerson: Loading person $personId');
    try {
      final person = await _familyService.getPersonById(
        widget.treeId,
        personId,
      );
      if (!mounted) return;
      setState(() {
        _contextPerson = person;
        _isLoadingContext = false;
        // Предзаполнение пола на основе relationType и пола _contextPerson
        _prefillGenderBasedOnRelation(_contextPerson!, _contextRelationType);
        _prefillLastNameFromAnchor(_contextPerson, _contextRelationType);
      });
      debugPrint(
        'AddRelativeScreen _loadContextPerson: Loaded person ${_contextPerson?.name}',
      );
    } catch (e) {
      debugPrint('Ошибка при загрузке Person из контекста: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingContext = false;
        // TODO: Показать ошибку пользователю?
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Не удалось загрузить данные родственника для контекста.',
          ),
        ),
      );
    }
  }

  // Предзаполнение пола на основе существующего родственника и типа связи
  void _prefillGenderBasedOnRelation(
    FamilyPerson anchorPerson,
    RelationType? relation,
  ) {
    if (relation == null) return;

    Gender? prefilledGender;
    // Логика определения пола нового родственника
    switch (relation) {
      case RelationType.parent:
      case RelationType.child:
      case RelationType.sibling:
      case RelationType.grandparent:
      case RelationType.grandchild:
        // Для этих связей пол не очевиден
        prefilledGender = null;
        break;
      case RelationType.spouse:
      case RelationType.partner: // Добавлено
      case RelationType.ex_spouse: // Добавлено
      case RelationType.ex_partner: // Добавлено
        // Пол противоположный
        prefilledGender =
            (anchorPerson.gender == Gender.male) ? Gender.female : Gender.male;
        break;
      // Для других типов (friend, colleague, other) пол не определяем
      default:
        prefilledGender = null;
    }

    // Устанавливаем только если пол еще не выбран
    if (_selectedGender == null && prefilledGender != null) {
      debugPrint(
        "AddRelativeScreen _prefillGenderBasedOnRelation: Pre-filling gender to $prefilledGender based on relation $relation and anchor person gender ${anchorPerson.gender}",
      );
      _selectedGender = prefilledGender;
    }
  }

  // Вспомогательный метод для получения названия связи для диалога
  String _getRelationNameForDialog(RelationType type, Gender? gender) {
    return FamilyRelation.getRelationName(type, gender);
  }
}

class _RequiredChip extends StatelessWidget {
  final String label;

  const _RequiredChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.check_circle_outline, size: 18),
      label: Text(label),
    );
  }
}

class _QuickInfoChip extends StatelessWidget {
  const _QuickInfoChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 6),
          Text(label),
        ],
      ),
    );
  }
}
