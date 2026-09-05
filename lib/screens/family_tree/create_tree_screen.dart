// ignore_for_file: use_build_context_synchronously
// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../backend/interfaces/cross_tree_person_search_capable_family_tree_service.dart';
import '../../backend/interfaces/family_tree_service_interface.dart';
import '../../backend/models/cross_tree_person_suggestion.dart';
import '../../backend/models/include_rules.dart';
import '../../models/family_tree.dart';
import '../../providers/tree_provider.dart';

class CreateTreeScreen extends StatefulWidget {
  const CreateTreeScreen({
    super.key,
    this.initialKind = TreeKind.family,
  });

  final TreeKind initialKind;

  @override
  _CreateTreeScreenState createState() => _CreateTreeScreenState();
}

class _CreateTreeScreenState extends State<CreateTreeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  bool _isLoading = false;
  bool _isPrivate = true; // Значение по умолчанию - приватное дерево
  late TreeKind _treeKind;
  String? _selectedTemplateKey;

  // Phase 3.4 (PHASE-3.4-UI-PROPOSAL §2.1): branch wizard rule
  // selector. Default — blood-from-me с maxHops=5 для family kind
  // (per Артёмовому DECISIONS.md ответу D), manual — для friends.
  // Wizard показывает rules-секцию только для family kind: для
  // друзей всегда manual (близкий круг — не BFS-кандидат).
  BranchRuleType _ruleType = BranchRuleType.bloodFromMe;
  int _maxHops = 5;

  // anchor для descendants-of / ancestors-of. `_anchorIdentityId`
  // — graphPerson.id (= identityId), который пишется в payload.
  // `_anchorDisplayName` хранится только для UI отображения «кого
  // выбрали» — не сериализуется.
  String? _anchorIdentityId;
  String? _anchorDisplayName;

  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();

  @override
  void initState() {
    super.initState();
    _treeKind = widget.initialKind;
  }

  // Pre-cooked branch ideas. Tap a chip → name + description
  // controllers fill in, и (Phase 3.4) выбирается соответствующий
  // BranchRuleType. The user can edit either field after, we just
  // save them from staring at a blank form. The keys are stable
  // identifiers so we can highlight the active chip without
  // comparing freeform text. Two parallel lists because the
  // friends-tree («Круг») use case has a totally different
  // vocabulary from blood family.
  static const List<_BranchTemplate> _familyTemplates = <_BranchTemplate>[
    _BranchTemplate(
      key: 'maternal',
      label: 'По маминой линии',
      name: 'По маминой линии',
      description: 'Мама и её родня — бабушка с дедом, тёти и дяди, кузены.',
      // Manual: «по маминой линии» обычно подразумевает выбрать
      // конкретного предка-якорь, а не BFS от self — потому что
      // self включит обе линии. Default manual; юзер может
      // переключить на ancestors-of-мама вручную.
      defaultRuleType: BranchRuleType.manual,
    ),
    _BranchTemplate(
      key: 'paternal',
      label: 'По папиной линии',
      name: 'По папиной линии',
      description: 'Папа и его родня — другая половина моего дерева.',
      defaultRuleType: BranchRuleType.manual,
    ),
    _BranchTemplate(
      key: 'spouse',
      label: 'Семья жены/мужа',
      name: 'Семья жены',
      description: 'Родные супруга — родители, братья и сёстры, племянники.',
      defaultRuleType: BranchRuleType.manual,
    ),
    _BranchTemplate(
      key: 'closeBlood',
      label: 'Кровная родня',
      name: 'Кровная родня',
      description: 'Только кровные родственники, без свойственников.',
      // Blood-from-me — exact match для этого шаблона: BFS от
      // self по кровным connections до 5 колен.
      defaultRuleType: BranchRuleType.bloodFromMe,
    ),
  ];

  static const List<_BranchTemplate> _friendsTemplates = <_BranchTemplate>[
    _BranchTemplate(
      key: 'closeFriends',
      label: 'Близкие друзья',
      name: 'Близкие друзья',
      description: 'Те, кому первому пишу о хороших и плохих новостях.',
    ),
    _BranchTemplate(
      key: 'school',
      label: 'Школа',
      name: 'Школа',
      description: 'Одноклассники и ребята со школьных лет.',
    ),
    _BranchTemplate(
      key: 'uni',
      label: 'Универ',
      name: 'Универ',
      description: 'Однокурсники, преподаватели, студенческая компания.',
    ),
    _BranchTemplate(
      key: 'work',
      label: 'Работа',
      name: 'Работа',
      description: 'Коллеги и партнёры, с которыми поддерживаю общение.',
    ),
  ];

  List<_BranchTemplate> get _activeTemplates =>
      _treeKind == TreeKind.friends ? _friendsTemplates : _familyTemplates;

  void _applyTemplate(_BranchTemplate template) {
    setState(() {
      _selectedTemplateKey = template.key;
      _nameController.text = template.name;
      _descriptionController.text = template.description;
      // Phase 3.4: template дополнительно выбирает rule type.
      // anchor-rule типы (descendants/ancestors) у шаблонов не
      // используются — те требуют выбора конкретного человека.
      if (template.defaultRuleType != null) {
        _ruleType = template.defaultRuleType!;
        // Сбрасываем anchor если template — не anchor-rule.
        if (!_ruleType.requiresAnchor) {
          _anchorIdentityId = null;
          _anchorDisplayName = null;
        }
      }
    });
    // Reset cursor positions to the END so the user can keep typing
    // without first pressing → (small UX win, big when they tap a
    // chip and immediately want to extend «По маминой линии» to «По
    // маминой линии Кузнецовых»).
    _nameController.selection = TextSelection.fromPosition(
      TextPosition(offset: _nameController.text.length),
    );
    _descriptionController.selection = TextSelection.fromPosition(
      TextPosition(offset: _descriptionController.text.length),
    );
  }

  void _clearTemplateSelection() {
    if (_selectedTemplateKey != null) {
      setState(() {
        _selectedTemplateKey = null;
      });
    }
  }

  /// Phase 3.4 (PHASE-3.4-UI-PROPOSAL §2.1): wizard собирает
  /// IncludeRules только для семейных веток. Кружки друзей всегда
  /// manual — для них rule selector скрыт. Также: для anchor-rule
  /// типов отказ submit'а если anchor не выбран.
  IncludeRules? _buildIncludeRulesForSubmit() {
    if (_treeKind != TreeKind.family) {
      // Friends — backend применит default manual.
      return null;
    }
    return IncludeRules(
      type: _ruleType,
      anchorPersonId: _ruleType.requiresAnchor ? _anchorIdentityId : null,
      maxHops: _maxHops,
    );
  }

  Future<void> _createTree() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_treeKind == TreeKind.family &&
        _ruleType.requiresAnchor &&
        (_anchorIdentityId == null || _anchorIdentityId!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Для этого правила выберите конкретного человека'),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final treeId = await _familyTreeService.createTree(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        isPrivate: _isPrivate,
        kind: _treeKind,
        includeRules: _buildIncludeRulesForSubmit(),
      );

      if (mounted) {
        final treeName = _nameController.text.trim();
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().selectTree(
            treeId,
            treeName,
            treeKind: _treeKind,
          );
        }
        final successLabel = _treeKind == TreeKind.friends
            ? 'Дерево друзей создано'
            : 'Семейное дерево создано';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successLabel)));
        final encodedName = Uri.encodeComponent(treeName);
        context.go('/tree/view/$treeId?name=$encodedName');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
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
      appBar: AppBar(title: const Text('Новая ветка')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'С чего начнём?',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              // Плотность (02.09.2026): по одной строке на объяснение —
              // экран был стеной текста до первого поля ввода.
              Text(
                _treeKind == TreeKind.friends
                    ? 'Назовите круг — людей добавите потом.'
                    : 'Назовите ветку — родных добавите потом.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              SegmentedButton<TreeKind>(
                segments: const [
                  ButtonSegment<TreeKind>(
                    value: TreeKind.family,
                    icon: Icon(Icons.family_restroom),
                    label: Text('Семья'),
                  ),
                  ButtonSegment<TreeKind>(
                    value: TreeKind.friends,
                    icon: Icon(Icons.diversity_3_outlined),
                    label: Text('Друзья'),
                  ),
                ],
                selected: <TreeKind>{_treeKind},
                onSelectionChanged: (selection) {
                  setState(() {
                    _treeKind = selection.first;
                    // Switching kind drops any previous template
                    // pick — the family templates don't make sense
                    // in the friends tab and vice versa.
                    _selectedTemplateKey = null;
                    // Phase 3.4: переключение на friends сбрасывает
                    // rule + anchor (rules-секция скрывается, friends
                    // = always manual). Обратно на family — default
                    // blood-from-me.
                    if (_treeKind == TreeKind.friends) {
                      _ruleType = BranchRuleType.manual;
                      _anchorIdentityId = null;
                      _anchorDisplayName = null;
                    } else {
                      _ruleType = BranchRuleType.bloodFromMe;
                    }
                  });
                },
              ),
              const SizedBox(height: 8),
              Text(
                _treeKind == TreeKind.friends
                    ? 'Близкий круг без родственных связей — раскладка вручную.'
                    : 'Ветка — срез общего дерева: «Кровная родня», «Семья жены», «Папина линия».',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              // Pre-cooked template chips. Tap one and the name +
              // description fields below get prefilled with a
              // sensible default — the user can edit either, the
              // chip just saves them from staring at a blank form
              // and inventing a name from scratch. Hidden when
              // the template list is empty (e.g. tomorrow when
              // somebody adds a new tree-kind without templates).
              if (_activeTemplates.isNotEmpty) ...[
                Text(
                  'Шаблоны',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final template in _activeTemplates)
                      ChoiceChip(
                        label: Text(template.label),
                        selected: _selectedTemplateKey == template.key,
                        onSelected: (selected) {
                          if (selected) {
                            _applyTemplate(template);
                          } else {
                            _clearTemplateSelection();
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              // Phase 3.4 (PHASE-3.4-UI-PROPOSAL §2.1): rule
              // selector — только для family kind. Друзья всегда
              // manual (близкий круг — не BFS-кандидат). Conditional
              // sub-blocks ниже (slider + anchor) — visible
              // согласно требованиям выбранного rule type.
              if (_treeKind == TreeKind.family) ...[
                Text(
                  'Какую ветку строим?',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                ),
                const SizedBox(height: 6),
                _BranchRuleSelector(
                  selected: _ruleType,
                  onChanged: (next) {
                    setState(() {
                      _ruleType = next;
                      // Switch out of anchor-rule → drop stale
                      // anchor selection.
                      if (!next.requiresAnchor) {
                        _anchorIdentityId = null;
                        _anchorDisplayName = null;
                      }
                    });
                  },
                ),
                if (_ruleType.usesBfs) ...[
                  const SizedBox(height: 12),
                  _MaxHopsSlider(
                    value: _maxHops,
                    onChanged: (next) {
                      setState(() {
                        _maxHops = next;
                      });
                    },
                  ),
                ],
                if (_ruleType.requiresAnchor) ...[
                  const SizedBox(height: 12),
                  _AnchorPersonPicker(
                    selectedDisplayName: _anchorDisplayName,
                    familyTreeService: _familyTreeService,
                    onPicked: (suggestion) {
                      setState(() {
                        _anchorIdentityId = suggestion.identityId;
                        _anchorDisplayName = suggestion.displayName;
                      });
                    },
                    onCleared: () {
                      setState(() {
                        _anchorIdentityId = null;
                        _anchorDisplayName = null;
                      });
                    },
                  ),
                ],
                const SizedBox(height: 16),
              ],
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _treeKind == TreeKind.friends
                      ? 'Название круга друзей'
                      : 'Название ветки',
                  hintText: _treeKind == TreeKind.friends
                      ? 'Например: Наш круг'
                      : 'Например: Семья Ивановых, Кровная родня, Папина линия',
                  prefixIcon: Icon(
                    _treeKind == TreeKind.friends
                        ? Icons.diversity_3_outlined
                        : Icons.family_restroom,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return _treeKind == TreeKind.friends
                        ? 'Введите название круга друзей'
                        : 'Введите название ветки';
                  }
                  return null;
                },
              ),
              // Плотность (чанк 12): поле рядом с полем — 10dp, не 16.
              const SizedBox(height: 10),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Описание, если нужно',
                  hintText:
                      'Например: близкие друзья, университет, рабочий круг',
                  prefixIcon: Icon(Icons.description),
                  alignLabelWithHint: true,
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _isPrivate,
                onChanged: (value) {
                  setState(() {
                    _isPrivate = value;
                  });
                },
                title:
                    Text(_isPrivate ? 'Приватная ветка' : 'Публичная ветка'),
                subtitle: Text(
                  _isPrivate
                      ? 'Её увидят только приглашённые участники.'
                      : 'Её можно будет открывать по ссылке.',
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _createTree,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Создать и открыть'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }
}

/// Pre-cooked branch idea surfaced as a ChoiceChip on the create
/// form. Tapping a chip prefills the name + description controllers
/// — the user can keep editing afterwards, this is just a head
/// start. `key` is a stable identifier for selection state so we
/// can highlight the active chip without comparing freeform text.
class _BranchTemplate {
  const _BranchTemplate({
    required this.key,
    required this.label,
    required this.name,
    required this.description,
    this.defaultRuleType,
  });

  /// Stable identifier used to mark a chip as selected. Survives
  /// renames of the localized `label` / `name` without breaking
  /// the highlight.
  final String key;

  /// Short copy shown on the chip itself.
  final String label;

  /// Default branch name written into the name controller when the
  /// chip is tapped. Often equal to `label`; kept separate so we
  /// can have «Семья жены/мужа» on the chip but seed the safer
  /// «Семья жены» as the actual name.
  final String name;

  /// Default description written into the description controller.
  final String description;

  /// Phase 3.4 (PHASE-3.4-UI-PROPOSAL §2.1): template can suggest
  /// matching includeRules.type. `null` = leave wizard's current
  /// rule alone (mostly for friends-templates which are always
  /// manual anyway).
  final BranchRuleType? defaultRuleType;
}

/// Phase 3.4: radio-style selector для BranchRuleType. Single-screen
/// wizard pattern (PHASE-3.4-UI-PROPOSAL §6.B): vertical list
/// RadioListTile'ов с label + sub-hint от enum'а. RadioGroup ancestor
/// (Material 3.32+) — `groupValue`/`onChanged` deprecated в пользу
/// этого паттерна.
class _BranchRuleSelector extends StatelessWidget {
  const _BranchRuleSelector({
    required this.selected,
    required this.onChanged,
  });

  final BranchRuleType selected;
  final ValueChanged<BranchRuleType> onChanged;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<BranchRuleType>(
      groupValue: selected,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final option in BranchRuleType.values)
            RadioListTile<BranchRuleType>(
              value: option,
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                option.russianLabel,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(option.russianHint),
            ),
        ],
      ),
    );
  }
}

/// Phase 3.4: slider 3..8 для maxHops. UI-range у́же server'ного
/// 1..20 — sensible UX bounds (1-2 hops редко имеют смысл, 9+
/// колен почти никто не помнит). Backend всё равно clamp'нет
/// out-of-range, но UI defаваt'ит discoverable вариант.
class _MaxHopsSlider extends StatelessWidget {
  const _MaxHopsSlider({
    required this.value,
    required this.onChanged,
  });

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Глубина обхода: $value ${_pluralizeKolen(value)}',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        Slider(
          value: value.toDouble(),
          min: 3,
          max: 8,
          divisions: 5,
          label: '$value',
          onChanged: (next) => onChanged(next.round()),
        ),
        Text(
          'Колено — шаг родства: родитель → ребёнок.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  static String _pluralizeKolen(int value) {
    final mod10 = value % 10;
    final mod100 = value % 100;
    if (mod10 == 1 && mod100 != 11) return 'колено';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'колена';
    }
    return 'колен';
  }
}

/// Phase 3.4: anchor-picker для descendants-of / ancestors-of.
/// Search-based bottom sheet, использует существующий
/// `/v1/persons/search` через `CrossTreePersonSearchCapableFamilyTreeService`.
/// Возвращает только результаты с `identityId` (== graphPerson.id);
/// без identityId backend старый или person ещё не sync'нут — UI
/// fallback'ом скрывает кнопку выбора.
class _AnchorPersonPicker extends StatelessWidget {
  const _AnchorPersonPicker({
    required this.selectedDisplayName,
    required this.familyTreeService,
    required this.onPicked,
    required this.onCleared,
  });

  final String? selectedDisplayName;
  final FamilyTreeServiceInterface familyTreeService;
  final ValueChanged<CrossTreePersonSuggestion> onPicked;
  final VoidCallback onCleared;

  @override
  Widget build(BuildContext context) {
    final hasService =
        familyTreeService is CrossTreePersonSearchCapableFamilyTreeService;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Якорный человек',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          'От кого считать потомков или предков?',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        if (selectedDisplayName != null && selectedDisplayName!.isNotEmpty)
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.person),
              title: Text(selectedDisplayName!),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Сбросить выбор',
                onPressed: onCleared,
              ),
            ),
          )
        else
          OutlinedButton.icon(
            icon: const Icon(Icons.person_search),
            label: const Text('Выбрать человека'),
            onPressed: hasService
                ? () => _openPicker(context)
                : null,
          ),
      ],
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    final picked = await showModalBottomSheet<CrossTreePersonSuggestion>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) {
        return _AnchorPickerSheet(
          familyTreeService: familyTreeService,
        );
      },
    );
    if (picked != null) {
      onPicked(picked);
    }
  }
}

class _AnchorPickerSheet extends StatefulWidget {
  const _AnchorPickerSheet({required this.familyTreeService});

  final FamilyTreeServiceInterface familyTreeService;

  @override
  State<_AnchorPickerSheet> createState() => _AnchorPickerSheetState();
}

class _AnchorPickerSheetState extends State<_AnchorPickerSheet> {
  final TextEditingController _queryController = TextEditingController();
  List<CrossTreePersonSuggestion> _results = const [];
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _runSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }
    final service = widget.familyTreeService;
    if (service is! CrossTreePersonSearchCapableFamilyTreeService) {
      setState(() {
        _error = 'Поиск недоступен для текущего бэкенда';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await (service as
              CrossTreePersonSearchCapableFamilyTreeService)
          .searchPersonsAcrossOwnTrees(query: trimmed, limit: 20);
      if (!mounted) return;
      setState(() {
        // Filter out results without identityId — wizard'у нужно
        // graphPerson.id для anchor. Старый backend без addendum'а
        // не вернёт identityId; в этом случае result row просто
        // не показывается (gracefully degraded).
        _results = results
            .where((r) => r.identityId != null && r.identityId!.isNotEmpty)
            .toList(growable: false);
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Ошибка поиска: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Кто будет якорем?',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _queryController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Имя или фамилия',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: _runSearch,
              ),
              const SizedBox(height: 12),
              if (_isLoading) const LinearProgressIndicator(),
              if (_error != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final suggestion = _results[index];
                    return ListTile(
                      leading: const Icon(Icons.person),
                      title: Text(suggestion.displayName),
                      subtitle: Text(
                        '${suggestion.treeName}'
                        '${suggestion.birthDate != null && suggestion.birthDate!.isNotEmpty ? ' • ${suggestion.birthDate!.split('T').first}' : ''}',
                      ),
                      onTap: () => Navigator.of(context).pop(suggestion),
                    );
                  },
                ),
              ),
              if (!_isLoading &&
                  _error == null &&
                  _results.isEmpty &&
                  _queryController.text.trim().isNotEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Никого не найдено'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
