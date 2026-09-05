// Ship Audit 4.2 (2026-05-28): shared «Кем приходится?» relation
// picker sheet. Mama-friendly first step before name-form в add-
// relative flow.
//
// UX audit (ed62ba6) Screen 4.2 — текущий entry points (relatives
// screen FAB, find_relative_screen, action sheet «Добавить
// родственника») открывают AddRelativeScreen без explicit relation
// hint. Mama-сценарий: видит длинный form с relation dropdown,
// тыкается случайно. Этот picker делает relation FIRST step.
//
// Pattern mirrors EmptyTreeGuidedCta (Ship 11, 0dda6fe) which уже
// shipped relation-first для empty-tree state. Этот sheet extracts
// same idea для non-empty entry points.
//
// AddRelativeScreen reads `relationType` + `contextPersonId` extras
// (see its initState) — NOT `predefinedRelation`. Этот sheet just
// shims the navigation — no AddRelativeScreen refactor.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../models/family_person.dart';
import '../models/family_relation.dart';

/// Public picker result — relation + optional gender hint.
/// `relationType == null` означает user chose «Другое родство —
/// заполню сам» (signal к AddRelativeScreen use generic UI без
/// pre-fill).
class RelationPickerResult {
  const RelationPickerResult({this.relationType, this.gender});
  final RelationType? relationType;
  final Gender? gender;
}

/// Test-friendly low-level — shows picker sheet и returns chosen
/// relation. Returns null если sheet dismissed без selection.
/// Separated из navigation wrapper чтобы tests can verify picker
/// behavior без needing GoRouter scaffolding.
/// [anchorName] — имя узла, ОТ которого добавляем (node-anchored add).
/// Когда задано: заголовок «Кто это для {anchorName}?» и пикер
/// показывает ТОЛЬКО примитивы (Мама/Папа/Ребёнок/Супруг·Партнёр/
/// Брат·Сестра) — остальные родства граф выводит сам, сложные типы не
/// предлагаем. Когда null (FAB/seed-флоу) — прежний полный список.
/// [isFriendsCircle] — пикер открыт из круга друзей: вместо семейных
/// примитивов показываем «Друг»/«Коллега» (смоук 2026-07-04: круг
/// предлагал Маму/Папу без опции «Друг» на первом уровне).
Future<RelationPickerResult?> showRelationPickerSheet(
  BuildContext context, {
  String? anchorName,
  bool isFriendsCircle = false,
}) async {
  return showModalBottomSheet<RelationPickerResult>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetCtx) => _RelationPickerSheet(
      anchorName: anchorName,
      isFriendsCircle: isFriendsCircle,
    ),
  );
}

/// Shows relation picker sheet AND navigates к /relatives/add с
/// pre-filled relation extras. Returns navigation result от
/// AddRelativeScreen (null если user dismissed sheet без tap).
///
/// [contextPersonId] — anchor person. Когда provided, AddRelativeScreen
/// renders «Бабушка {anchor.name} — добавить» header. Null для FAB-
/// style entry points (anchor = caller's self person).
Future<dynamic> showRelationPickerAndNavigateAdd(
  BuildContext context, {
  required String treeId,
  String? contextPersonId,
  String? anchorName,
  bool isFriendsCircle = false,
}) async {
  final pick = await showRelationPickerSheet(
    context,
    anchorName: anchorName,
    isFriendsCircle: isFriendsCircle,
  );
  if (pick == null) return null;
  if (!context.mounted) return null;
  final extras = <String, dynamic>{
    if (contextPersonId != null) 'contextPersonId': contextPersonId,
    'quickAddMode': true,
    if (pick.relationType != null) 'relationType': pick.relationType,
    if (pick.gender != null) 'prefilledGender': pick.gender,
  };
  return context.push<dynamic>(
    '/relatives/add/$treeId',
    extra: extras,
  );
}

class _RelationPickerSheet extends StatefulWidget {
  const _RelationPickerSheet({this.anchorName, this.isFriendsCircle = false});

  /// Имя узла-якоря (node-anchored add). null → FAB/seed-флоу.
  final String? anchorName;

  /// Круг друзей: friends-first набор вместо семейных примитивов.
  final bool isFriendsCircle;

  @override
  State<_RelationPickerSheet> createState() => _RelationPickerSheetState();
}

class _RelationPickerSheetState extends State<_RelationPickerSheet> {
  bool _expanded = false;

  String? get _anchorName {
    final raw = widget.anchorName?.trim();
    return (raw == null || raw.isEmpty) ? null : raw;
  }

  /// Node-anchored: показываем только примитивы относительно узла.
  /// Сложные родства (бабушка, тётя, ин-ло, кузены, бывшие, сводные)
  /// граф выводит сам из примитивов — здесь их не предлагаем.
  bool get _isNodeAnchored => _anchorName != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final anchor = _anchorName;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Плотность (чанк 13): заголовок был на titleLarge (~22sp) с
              // крупными отступами — шесть кнопок столбиком ниже занимали
              // ~370dp. Заголовок ужат до 20sp, подзаголовок — явные 14sp
              // (helper-текст, не «читай меня внимательно»).
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
                child: Text(
                  anchor != null ? 'Кто это для $anchor?' : 'Кем приходится?',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  anchor != null
                      ? 'Выбери связь относительно $anchor. Остальные '
                          'родства дерево выведет само.'
                      : 'Выбери связь — потом заполнишь имя и дату.',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              // Круг друзей: friends-first (смоук 2026-07-04 — пикер
              // предлагал Маму/Папу, а «Друг» не существовал вовсе).
              // Плотность (чанк 13): основные варианты — сетка 2 колонки
              // по 48dp вместо столбика 52dp — тот же список кнопок
              // умещается в ~половину прежней высоты.
              if (widget.isFriendsCircle) ...[
                _PrimaryTileGrid(
                  tiles: [
                    _PrimaryTile(
                      key: const Key('relation-picker-friend'),
                      icon: Icons.emoji_people_outlined,
                      label: 'Друг',
                      onTap: () => _pick(context, RelationType.friend, null),
                    ),
                    _PrimaryTile(
                      key: const Key('relation-picker-colleague'),
                      icon: Icons.work_outline_rounded,
                      label: 'Коллега',
                      onTap: () =>
                          _pick(context, RelationType.colleague, null),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SecondaryTile(
                  keyName: 'friends-other',
                  label: 'Другая связь — заполню сам',
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: () =>
                      Navigator.of(context).pop(const RelationPickerResult()),
                ),
              ] else ...[
                // Primary CTAs (mirror EmptyTreeGuidedCta).
                _PrimaryTileGrid(
                  tiles: [
                    _PrimaryTile(
                      key: const Key('relation-picker-mama'),
                      icon: Icons.face_3_outlined,
                      label: 'Мама',
                      onTap: () => _pick(
                        context,
                        RelationType.parent,
                        Gender.female,
                      ),
                    ),
                    _PrimaryTile(
                      key: const Key('relation-picker-papa'),
                      icon: Icons.face_outlined,
                      label: 'Папа',
                      onTap: () => _pick(
                        context,
                        RelationType.parent,
                        Gender.male,
                      ),
                    ),
                    _PrimaryTile(
                      key: const Key('relation-picker-child'),
                      icon: Icons.child_care_outlined,
                      label: 'Ребёнок',
                      onTap: () => _pick(context, RelationType.child, null),
                    ),
                    _PrimaryTile(
                      key: const Key('relation-picker-partner'),
                      icon: Icons.favorite_outline_rounded,
                      label: 'Супруг / Партнёр',
                      onTap: () => _pick(context, RelationType.spouse, null),
                    ),
                    _PrimaryTile(
                      key: const Key('relation-picker-sibling'),
                      icon: Icons.group_outlined,
                      label: 'Брат / Сестра',
                      onTap: () => _pick(context, RelationType.sibling, null),
                    ),
                    // Node-anchored: только примитивы выше. Бабушка/тётя/
                    // ин-ло/кузены/бывшие/сводные граф выведет сам — здесь
                    // их не показываем (в seed/FAB-флоу оставляем как было).
                    if (!_isNodeAnchored)
                      _PrimaryTile(
                        key: const Key('relation-picker-grandparent'),
                        icon: Icons.elderly_outlined,
                        label: 'Дедушка / Бабушка',
                        onTap: () =>
                            _pick(context, RelationType.grandparent, null),
                      ),
                  ],
                ),
                if (!_isNodeAnchored) ...[
                  const SizedBox(height: 12),
                  // Expand secondary relations.
                  if (!_expanded)
                    TextButton.icon(
                      key: const Key('relation-picker-other-expand'),
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Другой родственник'),
                      onPressed: () => setState(() => _expanded = true),
                    )
                  else ...[
                    const Divider(),
                    _SecondaryTile(
                      keyName: 'aunt',
                      label: 'Тётя',
                      onTap: () =>
                          _pick(context, RelationType.aunt, Gender.female),
                    ),
                    _SecondaryTile(
                      keyName: 'uncle',
                      label: 'Дядя',
                      onTap: () =>
                          _pick(context, RelationType.uncle, Gender.male),
                    ),
                    _SecondaryTile(
                      keyName: 'nephew',
                      label: 'Племянник',
                      onTap: () =>
                          _pick(context, RelationType.nephew, Gender.male),
                    ),
                    _SecondaryTile(
                      keyName: 'niece',
                      label: 'Племянница',
                      onTap: () =>
                          _pick(context, RelationType.niece, Gender.female),
                    ),
                    _SecondaryTile(
                      keyName: 'cousin',
                      label: 'Кузен / Кузина',
                      onTap: () => _pick(context, RelationType.cousin, null),
                    ),
                    _SecondaryTile(
                      keyName: 'great-grandparent',
                      label: 'Прадед / Прабабка',
                      onTap: () =>
                          _pick(context, RelationType.greatGrandparent, null),
                    ),
                    _SecondaryTile(
                      keyName: 'parent-in-law',
                      label: 'Тесть / Тёща / Свёкр / Свекровь',
                      onTap: () =>
                          _pick(context, RelationType.parentInLaw, null),
                    ),
                    _SecondaryTile(
                      keyName: 'sibling-in-law',
                      label: 'Деверь / Золовка / Шурин',
                      onTap: () =>
                          _pick(context, RelationType.siblingInLaw, null),
                    ),
                    // F2: сложные семьи — бывшие союзы и сводные дети.
                    _SecondaryTile(
                      keyName: 'ex-spouse',
                      label: 'Бывший муж / жена',
                      onTap: () => _pick(context, RelationType.ex_spouse, null),
                    ),
                    _SecondaryTile(
                      keyName: 'unmarried-partner',
                      label: 'Партнёр (без брака)',
                      onTap: () => _pick(context, RelationType.partner, null),
                    ),
                    _SecondaryTile(
                      keyName: 'stepchild',
                      label: 'Сводный ребёнок',
                      onTap: () => _pick(context, RelationType.stepchild, null),
                    ),
                    _SecondaryTile(
                      keyName: 'other',
                      label: 'Другое родство — заполню сам',
                      trailing: const Icon(Icons.edit_outlined, size: 18),
                      onTap: () => Navigator.of(context)
                          .pop(const RelationPickerResult()),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _pick(BuildContext ctx, RelationType type, Gender? gender) {
    Navigator.of(ctx)
        .pop(RelationPickerResult(relationType: type, gender: gender));
  }
}

/// Плотность (чанк 13): раскладывает primary-плитки в сетку 2 колонки
/// вместо столбика. Шесть кнопок по 52dp столбиком занимали ≈370dp —
/// сетка 48dp-плиток укладывает тот же набор в 2-3 строки. Нечётный
/// «хвост» (например, узловой пикер с 5 примитивами) просто занимает
/// половину последней строки — не тянем его на всю ширину, чтобы не
/// плодить спецкейсы.
class _PrimaryTileGrid extends StatelessWidget {
  const _PrimaryTileGrid({required this.tiles});

  final List<Widget> tiles;

  @override
  Widget build(BuildContext context) {
    const spacing = 8.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final tileWidth = (constraints.maxWidth - spacing) / 2;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
          ],
        );
      },
    );
  }
}

/// Компактная плитка для сетки 2 колонки: иконка + подпись в ряд,
/// минимум 48dp высоты (было 52dp столбиком на всю ширину). Подпись
/// умещается в 1-2 строки — самые длинные варианты («Дедушка / Бабушка»,
/// «Супруг / Партнёр») переносятся, а не обрезаются: это точка входа в
/// форму, а не превью, отрезанное «...» здесь мешает выбору.
class _PrimaryTile extends StatelessWidget {
  const _PrimaryTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.onSecondaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.15,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SecondaryTile extends StatelessWidget {
  const _SecondaryTile({
    required this.keyName,
    required this.label,
    required this.onTap,
    this.trailing,
  });

  final String keyName;
  final String label;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      key: Key('relation-picker-$keyName'),
      title: Text(label),
      trailing: trailing ?? const Icon(Icons.chevron_right_rounded, size: 18),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}
