import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/tree_change_record.dart';
import '../utils/date_parser.dart';

enum TreeHistoryFilter {
  all,
  people,
  relations,
  media,
}

class TreeHistorySheet extends StatefulWidget {
  const TreeHistorySheet({
    super.key,
    required this.historyFuture,
    required this.title,
    required this.subtitle,
    this.currentUserId,
    this.onOpenPerson,
    this.emptyMessage = 'Записей в журнале пока нет.',
    this.errorBuilder,
  });

  final Future<List<TreeChangeRecord>> historyFuture;
  final String title;
  final String subtitle;
  final String? currentUserId;
  final ValueChanged<String>? onOpenPerson;
  final String emptyMessage;
  final String Function(Object error)? errorBuilder;

  @override
  State<TreeHistorySheet> createState() => _TreeHistorySheetState();
}

class _TreeHistorySheetState extends State<TreeHistorySheet> {
  TreeHistoryFilter _selectedFilter = TreeHistoryFilter.all;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: FutureBuilder<List<TreeChangeRecord>>(
          future: widget.historyFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const SizedBox(
                height: 260,
                child: Center(child: CircularProgressIndicator()),
              );
            }

            if (snapshot.hasError) {
              final error = snapshot.error!;
              return SizedBox(
                height: 260,
                child: Center(
                  child: Text(
                    widget.errorBuilder?.call(error) ??
                        'Не удалось загрузить историю.',
                    textAlign: TextAlign.center,
                  ),
                ),
              );
            }

            final records = snapshot.data ?? const <TreeChangeRecord>[];
            final filteredRecords = records
                .where((record) => _matchesFilter(record, _selectedFilter))
                .toList();

            return ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.subtitle,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildFilterChip(
                        context: context,
                        filter: TreeHistoryFilter.all,
                        label: 'Все',
                      ),
                      _buildFilterChip(
                        context: context,
                        filter: TreeHistoryFilter.people,
                        label: 'Люди',
                      ),
                      _buildFilterChip(
                        context: context,
                        filter: TreeHistoryFilter.relations,
                        label: 'Связи',
                      ),
                      _buildFilterChip(
                        context: context,
                        filter: TreeHistoryFilter.media,
                        label: 'Фото',
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  if (filteredRecords.isEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: theme.colorScheme.outlineVariant,
                        ),
                      ),
                      child: Text(
                        _selectedFilter == TreeHistoryFilter.all
                            ? widget.emptyMessage
                            : 'Под выбранный фильтр записей пока нет.',
                        style: TextStyle(color: Colors.grey[700]),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: filteredRecords.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final record = filteredRecords[index];
                          final relatedPersonId = _resolvePersonId(record);
                          return Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: theme.colorScheme.outlineVariant,
                              ),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer
                                        .withValues(alpha: 0.72),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    _historyIcon(record),
                                    size: 18,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _historyTitle(record),
                                        style: theme.textTheme.bodyMedium
                                            ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _historySubtitle(
                                          record,
                                          currentUserId: widget.currentUserId,
                                        ),
                                        style: TextStyle(
                                          color: Colors.grey[700],
                                          fontSize: 12,
                                          height: 1.3,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (widget.onOpenPerson != null &&
                                    relatedPersonId != null) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Открыть карточку',
                                    onPressed: () =>
                                        widget.onOpenPerson!(relatedPersonId),
                                    icon: const Icon(Icons.open_in_new),
                                    // Без compact-плотности: 48dp тач-таргет, как у
                                    // restore/purge в DeletedItemRow (планка 50+ ≥44).
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFilterChip({
    required BuildContext context,
    required TreeHistoryFilter filter,
    required String label,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: _selectedFilter == filter,
      onSelected: (_) {
        setState(() {
          _selectedFilter = filter;
        });
      },
    );
  }

  bool _matchesFilter(TreeChangeRecord record, TreeHistoryFilter filter) {
    switch (filter) {
      case TreeHistoryFilter.all:
        return true;
      case TreeHistoryFilter.people:
        return record.type.startsWith('person.');
      case TreeHistoryFilter.relations:
        return record.type.startsWith('relation.');
      case TreeHistoryFilter.media:
        return record.type.startsWith('person_media.');
    }
  }

  String? _resolvePersonId(TreeChangeRecord record) {
    final personId = record.personId;
    if (personId != null && personId.isNotEmpty) {
      return personId;
    }

    for (final value in record.personIds) {
      if (value.isNotEmpty) {
        return value;
      }
    }

    return null;
  }

  IconData _historyIcon(TreeChangeRecord record) {
    switch (record.type) {
      case 'person_media.created':
        return Icons.add_photo_alternate_outlined;
      case 'person_media.updated':
        return Icons.star_outline;
      case 'person_media.deleted':
        return Icons.delete_outline;
      case 'person.created':
        return Icons.person_add_alt_1_outlined;
      case 'person.updated':
        return Icons.edit_outlined;
      case 'person.deleted':
        return Icons.person_remove_outlined;
      case 'relation.created':
        return Icons.link_outlined;
      case 'relation.updated':
        return Icons.alt_route_outlined;
      case 'relation.deleted':
        return Icons.link_off_outlined;
      default:
        return Icons.history_outlined;
    }
  }

  String _historyTitle(TreeChangeRecord record) {
    switch (record.type) {
      case 'person_media.created':
        return 'Добавлено фото';
      case 'person_media.updated':
        return 'Обновлено фото';
      case 'person_media.deleted':
        return 'Удалено фото';
      case 'person.created':
        return 'Добавлен человек';
      case 'person.updated':
        return 'Обновлён профиль';
      case 'person.deleted':
        return 'Удалён профиль';
      case 'relation.created':
        return 'Добавлена связь';
      case 'relation.updated':
        return 'Изменена связь';
      case 'relation.deleted':
        return 'Удалена связь';
      default:
        return 'Изменение в дереве';
    }
  }

  String _historySubtitle(
    TreeChangeRecord record, {
    required String? currentUserId,
  }) {
    final actorLabel = record.actorId == null || record.actorId!.isEmpty
        ? 'Действие в дереве'
        : record.actorId == currentUserId
            ? 'Вы'
            : 'Участник дерева';
    final formattedDate = _formatDate(record.createdAt);
    return '$actorLabel · $formattedDate';
  }

  String _formatDate(DateTime date) {
    try {
      return DateFormat('d MMM, HH:mm', 'ru').format(toLocalForDisplay(date));
    } catch (_) {
      return date.toIso8601String();
    }
  }
}
