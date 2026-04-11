import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math'; // <--- Добавляем импорт для функции min
import 'package:vector_math/vector_math_64.dart' as vector_math;
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/user_profile.dart';

// Структура для хранения информации о связях для отрисовки
class FamilyConnection {
  final String fromId;
  final String toId;
  final RelationType type; // Добавляем тип связи

  FamilyConnection({
    required this.fromId,
    required this.toId,
    required this.type,
  });
}

class InteractiveFamilyTree extends StatefulWidget {
  final List<Map<String, dynamic>>
      peopleData; // Теперь содержит {'person': FamilyPerson, 'userProfile': UserProfile?}
  final List<FamilyRelation> relations;
  final Function(FamilyPerson) onPersonTap; // Коллбэк при нажатии на узел
  final bool isEditMode; // Флаг режима редактирования
  final void Function(FamilyPerson person, RelationType type)
      onAddRelativeTapWithType; // Коллбэк для добавления
  final bool
      currentUserIsInTree; // <<< НОВЫЙ ПАРАМЕТР: Флаг, добавлен ли текущий пользователь
  final void Function(FamilyPerson targetPerson, RelationType relationType)
      onAddSelfTapWithType; // <<< НОВЫЙ ПАРАМЕТР: Коллбэк для добавления себя
  final String? currentUserId;
  final String? branchRootPersonId;
  final ValueChanged<FamilyPerson>? onBranchFocusRequested;
  final VoidCallback? onBranchFocusCleared;
  final String? selectedEditPersonId;
  final ValueChanged<FamilyPerson>? onEditPersonSelected;
  final Map<String, Offset>? manualNodePositions;
  final ValueChanged<Map<String, Offset>>? onNodePositionsChanged;
  final bool showGenerationGuides;
  final bool enableClusterHighlights;
  final String graphLabel;
  final bool hasManualLayout;
  final VoidCallback? onResetLayout;

  // Константы для размеров узлов и отступов - понадобятся для расчета layout
  static const double nodeWidth = 132; // Примерная ширина карточки
  static const double nodeHeight = 112; // Примерная высота карточки
  static const double levelSeparation =
      80; // Вертикальное расстояние между уровнями
  static const double siblingSeparation =
      40; // Горизонтальное расстояние между братьями/сестрами
  static const double spouseSeparation =
      20; // Горизонтальное расстояние между супругами
  static const double contentInsetHorizontal = 72;
  static const double contentInsetTop = 96;
  static const double contentInsetBottom = 56;

  const InteractiveFamilyTree({
    super.key,
    required this.peopleData,
    required this.relations,
    required this.onPersonTap,
    this.isEditMode = false, // По умолчанию выключен
    required this.onAddRelativeTapWithType,
    required this.currentUserIsInTree, // Делаем обязательным
    required this.onAddSelfTapWithType, // Делаем обязательным
    this.currentUserId,
    this.branchRootPersonId,
    this.onBranchFocusRequested,
    this.onBranchFocusCleared,
    this.selectedEditPersonId,
    this.onEditPersonSelected,
    this.manualNodePositions,
    this.onNodePositionsChanged,
    this.showGenerationGuides = true,
    this.enableClusterHighlights = true,
    this.graphLabel = 'дерева',
    this.hasManualLayout = false,
    this.onResetLayout,
  });

  @override
  State<InteractiveFamilyTree> createState() => _InteractiveFamilyTreeState();
}

class _InteractiveFamilyTreeState extends State<InteractiveFamilyTree> {
  static const double _viewportReservedTop = 112;
  static const double _viewportReservedBottom = 28;

  // Данные для CustomPainter
  Map<String, Offset> nodePositions = {}; // ID человека -> его позиция (центр)
  List<FamilyConnection> connections = []; // Список связей для отрисовки линий
  Size treeSize = Size.zero; // Общий размер дерева для CustomPaint и Stack
  final TransformationController _transformationController =
      TransformationController();
  Size? _viewportSize;
  bool _hasAppliedViewportFit = false;
  bool _showFamilyClusters = true;
  String? _selectedEditPersonId;
  String? _hoveredBranchPersonId;
  double _currentScale = 1.0;
  String? _draggingPersonId;

  @override
  void initState() {
    super.initState();
    _selectedEditPersonId = widget.selectedEditPersonId;
    _transformationController.addListener(_handleTransformChanged);
    _calculateLayout(); // Вызываем расчет layout
  }

  @override
  void didUpdateWidget(InteractiveFamilyTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.peopleData != widget.peopleData ||
        oldWidget.relations != widget.relations ||
        oldWidget.currentUserId != widget.currentUserId ||
        oldWidget.branchRootPersonId != widget.branchRootPersonId ||
        oldWidget.manualNodePositions != widget.manualNodePositions) {
      _hasAppliedViewportFit = false;
      _calculateLayout(); // Пересчитываем layout при изменении данных
    }
    if (oldWidget.selectedEditPersonId != widget.selectedEditPersonId) {
      _selectedEditPersonId = widget.selectedEditPersonId;
      if (_selectedEditPersonId != null && _selectedEditPersonId!.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focusOnPerson(_selectedEditPersonId!);
          }
        });
      }
    }
    if (!widget.isEditMode && _selectedEditPersonId != null) {
      _selectedEditPersonId = null;
    }
    if (widget.isEditMode && _hoveredBranchPersonId != null) {
      _hoveredBranchPersonId = null;
    }
  }

  @override
  void dispose() {
    _transformationController.removeListener(_handleTransformChanged);
    _transformationController.dispose();
    super.dispose();
  }

  void _handleTransformChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if ((scale - _currentScale).abs() < 0.01 || !mounted) {
      return;
    }
    setState(() {
      _currentScale = scale;
    });
  }

  // Метод для расчета позиций узлов и связей
  void _calculateLayout() {
    final modernLayout = _buildModernLayout();
    if (modernLayout != null) {
      final positions = _mergeManualNodePositions(modernLayout.nodePositions);
      setState(() {
        nodePositions = positions;
        connections = modernLayout.connections;
        treeSize = _calculateTreeSize(
          positions,
          minimumWidth: modernLayout.treeSize.width,
          minimumHeight: modernLayout.treeSize.height,
        );
      });
      _scheduleViewportFit();
      return;
    }

    if (widget.peopleData.isEmpty) {
      setState(() {
        nodePositions = {};
        connections = [];
        treeSize = Size.zero;
      });
      return;
    }

    // --- Шаг 1: Подготовка данных и определение поколений ---
    final Map<String, List<String>> parentToChildrenMap = {};
    final Map<String, List<String>> childToParentsMap = {};
    final Map<String, List<String>> spouseMap =
        {}; // Карта супругов (id -> список супругов)
    final Set<String> personIds =
        widget.peopleData.map((d) => (d['person'] as FamilyPerson).id).toSet();

    for (var relation in widget.relations) {
      final p1Id = relation.person1Id;
      final p2Id = relation.person2Id;

      // Убедимся, что оба ID существуют в peopleData
      if (!personIds.contains(p1Id) || !personIds.contains(p2Id)) continue;

      if (relation.relation1to2 == RelationType.parent) {
        // p1 родитель p2
        parentToChildrenMap.putIfAbsent(p1Id, () => []).add(p2Id);
        childToParentsMap.putIfAbsent(p2Id, () => []).add(p1Id);
      } else if (relation.relation1to2 == RelationType.child) {
        // p1 ребенок p2
        parentToChildrenMap.putIfAbsent(p2Id, () => []).add(p1Id);
        childToParentsMap.putIfAbsent(p1Id, () => []).add(p2Id);
      } else if (relation.relation1to2 == RelationType.spouse) {
        // Супруги
        spouseMap.putIfAbsent(p1Id, () => []).add(p2Id);
        spouseMap.putIfAbsent(p2Id, () => []).add(p1Id);
      }
    }

    // --- Улучшенная логика определения корней ---
    final List<String> roots = [];
    final Set<String> nonRoots = {};

    for (final id in personIds) {
      if (nonRoots.contains(id)) continue;

      bool hasParents = childToParentsMap.containsKey(id) &&
          childToParentsMap[id]!.isNotEmpty;
      bool hasSpouseWithParents = false;
      final spouses = spouseMap[id] ?? [];
      for (final spouseId in spouses) {
        if (childToParentsMap.containsKey(spouseId) &&
            childToParentsMap[spouseId]!.isNotEmpty) {
          hasSpouseWithParents = true;
          nonRoots.add(spouseId);
          break;
        }
      }

      if (!hasParents && !hasSpouseWithParents) {
        roots.add(id);
      } else {
        nonRoots.add(id);
      }
    }
    // --- Конец улучшенной логики ---

    final Map<String, int> nodeLevels = {}; // Объявляем здесь
    final Set<String> visited = {};
    final Map<String, int> queue = {};
    final Set<String> processing = {};

    // Начальная инициализация для корней
    for (final rootId in roots) {
      if (!processing.contains(rootId)) {
        queue[rootId] = 0;
        processing.add(rootId);
      }
    }

    // Добавляем все остальные узлы с высоким уровнем
    for (final personId in personIds) {
      if (!processing.contains(personId)) {
        queue[personId] = 10000;
        processing.add(personId);
      }
    }

    // BFS для определения уровней
    while (queue.isNotEmpty) {
      String currentId = '';
      int minLevelInQueue = 1000000;
      queue.forEach((id, level) {
        if (level < minLevelInQueue) {
          minLevelInQueue = level;
          currentId = id;
        }
      });

      if (currentId.isEmpty && queue.isNotEmpty) {
        break;
      }
      if (currentId.isEmpty) break;

      final currentLevel = queue.remove(currentId)!;
      nodeLevels[currentId] = currentLevel;
      visited.add(currentId);
      processing.remove(currentId);

      // --- Обрабатываем ДЕТЕЙ ---
      final children = parentToChildrenMap[currentId] ?? [];
      for (final childId in children) {
        final newChildLevel = currentLevel + 1;
        if (!visited.contains(childId)) {
          if (processing.contains(childId)) {
            if (newChildLevel < queue[childId]!) {
              queue[childId] = newChildLevel;
            }
          } else {
            queue[childId] = newChildLevel;
            processing.add(childId);
          }
        }
      }

      // --- Обрабатываем СУПРУГОВ ---
      final currentSpouses = spouseMap[currentId] ?? [];
      for (final spouseId in currentSpouses) {
        final newSpouseLevel = currentLevel;
        if (!visited.contains(spouseId)) {
          if (processing.contains(spouseId)) {
            if (newSpouseLevel < queue[spouseId]!) {
              queue[spouseId] = newSpouseLevel;
            } else if (newSpouseLevel > queue[spouseId]!) {}
          } else {
            queue[spouseId] = newSpouseLevel;
            processing.add(spouseId);
          }
        } else {}
      }
    }

    // --- Шаг 2: Расчет X и Y координат ---
    final Map<int, List<String>> nodesByLevel = {};
    int maxLevel = 0;
    nodeLevels.forEach((nodeId, level) {
      if (level < 0) {
        level = 0;
        nodeLevels[nodeId] = 0;
      }
      nodesByLevel.putIfAbsent(level, () => []).add(nodeId);
      if (level > maxLevel) {
        maxLevel = level;
      }
    });

    Map<String, Offset> currentPositions = _performInitialXLayout(
      maxLevel,
      nodesByLevel,
      spouseMap,
      nodeLevels,
      childToParentsMap,
    );

    // --- Итеративная корректировка для центрирования детей ---
    int iterations = 20; // Увеличиваем количество итераций
    double adjustmentFactor = 0.5; // Ослабляем корректировку

    for (int i = 0; i < iterations; i++) {
      Map<String, Offset> nextPositions = Map.from(currentPositions);
      for (int level = maxLevel - 1; level >= 0; level--) {
        final levelNodes = nodesByLevel[level] ?? [];
        for (final nodeId in levelNodes) {
          final parentPos = currentPositions[nodeId];
          if (parentPos == null) continue;

          final children = parentToChildrenMap[nodeId] ?? [];
          final childrenOnNextLevel = children
              .where(
                (childId) =>
                    nodeLevels.containsKey(childId) &&
                    nodeLevels[childId] == level + 1,
              )
              .toList();

          if (childrenOnNextLevel.isEmpty) continue;

          // --- Улучшенный расчет центра детей: среднее арифметическое ---
          double childrenSumX = 0;
          int validChildrenCount = 0;
          for (final childId in childrenOnNextLevel) {
            final childPos = currentPositions[childId];
            if (childPos != null) {
              childrenSumX += childPos.dx;
              validChildrenCount++;
            }
          }

          if (validChildrenCount > 0) {
            final childrenCenterX = childrenSumX / validChildrenCount;
            // --- Конец улучшенного расчета ---

            final parentGroupIds = _getNodeGroup(
              nodeId,
              level,
              currentPositions,
              spouseMap,
            );

            double minParentX = double.infinity;
            double maxParentX = double.negativeInfinity;
            for (final pId in parentGroupIds) {
              final pPos = currentPositions[pId];
              if (pPos != null) {
                minParentX = min(minParentX, pPos.dx);
                maxParentX = max(maxParentX, pPos.dx);
              }
            }

            if (minParentX.isFinite && maxParentX.isFinite) {
              final parentGroupCenterX = (minParentX + maxParentX) / 2;
              final targetShift = childrenCenterX - parentGroupCenterX;
              final shiftAmount = targetShift * adjustmentFactor;

              for (final pId in parentGroupIds) {
                final currentPPos = nextPositions[pId];
                if (currentPPos != null) {
                  nextPositions[pId] = Offset(
                    currentPPos.dx + shiftAmount,
                    currentPPos.dy,
                  );
                }
              }
            }
          }
        }
      }
      currentPositions = _resolveCollisions(
        maxLevel,
        nodesByLevel,
        nextPositions,
        spouseMap,
      );
    }

    // --- NEW: Add a second pass for centering children under parents ---
    for (int i = 0; i < iterations; i++) {
      // Используем то же кол-во итераций
      Map<String, Offset> nextPositions = Map.from(currentPositions);
      for (int level = 1; level <= maxLevel; level++) {
        // Идем снизу вверх
        final levelNodes = nodesByLevel[level] ?? [];
        for (final childId in levelNodes) {
          final childPos = currentPositions[childId];
          if (childPos == null) continue;

          final parents = childToParentsMap[childId] ?? [];
          final parentsOnPrevLevel = parents
              .where(
                (parentId) =>
                    nodeLevels.containsKey(parentId) &&
                    nodeLevels[parentId] == level - 1,
              )
              .toList();

          if (parentsOnPrevLevel.isEmpty) continue;

          double parentSumX = 0;
          int validParentCount = 0;
          for (final parentId in parentsOnPrevLevel) {
            final parentPos = currentPositions[parentId];
            if (parentPos != null) {
              parentSumX += parentPos.dx;
              validParentCount++;
            }
          }

          if (validParentCount > 0) {
            final parentCenterX = parentSumX / validParentCount;

            // Определяем группу ребенка (он сам + супруги на том же уровне)
            final childGroupIds = _getNodeGroup(
              childId,
              level,
              currentPositions,
              spouseMap,
            );

            double minChildGroupX = double.infinity;
            double maxChildGroupX = double.negativeInfinity;
            for (final cId in childGroupIds) {
              final cPos = currentPositions[cId];
              if (cPos != null) {
                minChildGroupX = min(minChildGroupX, cPos.dx);
                maxChildGroupX = max(maxChildGroupX, cPos.dx);
              }
            }

            if (minChildGroupX.isFinite && maxChildGroupX.isFinite) {
              final childGroupCenterX = (minChildGroupX + maxChildGroupX) / 2;
              final targetShift = parentCenterX - childGroupCenterX;
              final shiftAmount = targetShift *
                  adjustmentFactor; // Используем ослабленный adjustmentFactor

              for (final cId in childGroupIds) {
                final currentCPos = nextPositions[cId];
                if (currentCPos != null) {
                  nextPositions[cId] = Offset(
                    currentCPos.dx + shiftAmount,
                    currentCPos.dy,
                  );
                }
              }
            }
          }
        }
      }
      // Применяем разрешение коллизий после каждого шага центрирования детей
      currentPositions = _resolveCollisions(
        maxLevel,
        nodesByLevel,
        nextPositions,
        spouseMap,
      );
    }
    // --- END NEW PASS ---

    Map<String, Offset> finalPositions = currentPositions;

    double maxTreeWidth = 0;
    if (finalPositions.isNotEmpty) {
      double minX = double.infinity;
      double maxX = double.negativeInfinity;
      for (var pos in finalPositions.values) {
        minX = min(minX, pos.dx);
        maxX = max(maxX, pos.dx);
      }
      maxTreeWidth = (maxX + InteractiveFamilyTree.nodeWidth / 2) -
          (minX - InteractiveFamilyTree.nodeWidth / 2);

      double shiftX = 0;
      if (minX <
          InteractiveFamilyTree.nodeWidth / 2 +
              InteractiveFamilyTree.siblingSeparation) {
        shiftX = (InteractiveFamilyTree.nodeWidth / 2 +
                InteractiveFamilyTree.siblingSeparation) -
            minX;
        Map<String, Offset> shiftedPositions = {};
        finalPositions.forEach((key, value) {
          shiftedPositions[key] = Offset(value.dx + shiftX, value.dy);
        });
        finalPositions = shiftedPositions;
        maxTreeWidth += shiftX;
      }
    }

    // --- Шаг 4: Формирование связей (connections) ---
    final List<FamilyConnection> finalConnections = [];
    final Set<String> addedSpousePairs = {};

    for (var relation in widget.relations) {
      final p1Id = relation.person1Id;
      final p2Id = relation.person2Id;
      final type1to2 = relation.relation1to2;

      if (finalPositions.containsKey(p1Id) &&
          finalPositions.containsKey(p2Id)) {
        if (type1to2 == RelationType.parent || type1to2 == RelationType.child) {
          final parentId = (type1to2 == RelationType.parent) ? p1Id : p2Id;
          final childId = (type1to2 == RelationType.parent) ? p2Id : p1Id;
          if (nodeLevels.containsKey(parentId) &&
              nodeLevels.containsKey(childId) &&
              nodeLevels[parentId]! + 1 == nodeLevels[childId]!) {
            finalConnections.add(
              FamilyConnection(
                fromId: parentId,
                toId: childId,
                type: RelationType.parent,
              ),
            );
          }
        } else if (type1to2 == RelationType.spouse) {
          if (nodeLevels.containsKey(p1Id) &&
              nodeLevels.containsKey(p2Id) &&
              nodeLevels[p1Id] == nodeLevels[p2Id]) {
            final pairKey = [p1Id, p2Id]..sort();
            final pairString = pairKey.join('-');
            if (!addedSpousePairs.contains(pairString)) {
              finalConnections.add(
                FamilyConnection(
                  fromId: p1Id,
                  toId: p2Id,
                  type: RelationType.spouse,
                ),
              );
              addedSpousePairs.add(pairString);
            }
          }
        }
      }
    }

    // --- Шаг 5: Расчет общего размера (treeSize) ---
    double finalMaxY = (maxLevel *
            (InteractiveFamilyTree.nodeHeight +
                InteractiveFamilyTree.levelSeparation)) +
        InteractiveFamilyTree.nodeHeight;
    final mergedPositions = _mergeManualNodePositions(finalPositions);
    final Size finalTreeSize = _calculateTreeSize(
      mergedPositions,
      minimumWidth: max(maxTreeWidth, 300.0),
      minimumHeight: max(finalMaxY, 300.0),
    );

    setState(() {
      nodePositions = mergedPositions;
      connections = finalConnections;
      treeSize = finalTreeSize;
    });
    _scheduleViewportFit();
  }

  _TreeLayoutComputation? _buildModernLayout() {
    final visiblePeopleData = _buildVisiblePeopleData();
    if (visiblePeopleData.isEmpty) {
      return const _TreeLayoutComputation(
        nodePositions: <String, Offset>{},
        connections: <FamilyConnection>[],
        treeSize: Size.zero,
      );
    }

    final visibleIds = visiblePeopleData
        .map((entry) => (entry['person'] as FamilyPerson).id)
        .toSet();
    final visibleRelations = widget.relations.where((relation) {
      return visibleIds.contains(relation.person1Id) &&
          visibleIds.contains(relation.person2Id);
    }).toList();

    return _TreeLayoutEngine(
      peopleData: visiblePeopleData,
      relations: visibleRelations,
    ).compute();
  }

  List<Map<String, dynamic>> _buildVisiblePeopleData() {
    final branchRootPersonId = widget.branchRootPersonId;
    if (branchRootPersonId == null || branchRootPersonId.isEmpty) {
      return widget.peopleData;
    }

    final visibleIds = _buildBranchVisibleIds(branchRootPersonId);
    return widget.peopleData.where((entry) {
      final person = entry['person'];
      return person is FamilyPerson && visibleIds.contains(person.id);
    }).toList();
  }

  Set<String> _buildBranchVisibleIds(String branchRootPersonId) {
    final personIds = widget.peopleData
        .map((entry) => (entry['person'] as FamilyPerson).id)
        .toSet();
    if (!personIds.contains(branchRootPersonId)) {
      return personIds;
    }

    final childrenByParent = <String, Set<String>>{};
    final spousesByPerson = <String, Set<String>>{};
    for (final relation in widget.relations) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null && childId != null) {
        childrenByParent.putIfAbsent(parentId, () => <String>{}).add(childId);
      }
      if (_isSpouseRelation(relation)) {
        spousesByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        spousesByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
      }
    }

    final visibleIds = <String>{branchRootPersonId};
    final queue = <String>[branchRootPersonId];
    while (queue.isNotEmpty) {
      final currentId = queue.removeAt(0);
      for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
        if (visibleIds.add(spouseId)) {
          queue.add(spouseId);
        }
      }
      for (final childId in childrenByParent[currentId] ?? const <String>{}) {
        if (visibleIds.add(childId)) {
          queue.add(childId);
        }
      }
    }

    return visibleIds;
  }

  bool _isSpouseRelation(FamilyRelation relation) {
    return relation.relation1to2 == RelationType.spouse ||
        relation.relation2to1 == RelationType.spouse ||
        relation.relation1to2 == RelationType.partner ||
        relation.relation2to1 == RelationType.partner;
  }

  bool _isSiblingRelation(FamilyRelation relation) {
    return relation.relation1to2 == RelationType.sibling ||
        relation.relation2to1 == RelationType.sibling;
  }

  String? _parentIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person1Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person2Id;
    }
    return null;
  }

  String? _childIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person2Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person1Id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final stackWidth = treeSize.width;
    final stackHeight = treeSize.height;
    final familyClusters = widget.enableClusterHighlights
        ? _buildFamilyClusters()
        : const <_FamilyClusterOverlay>[];
    final interactionBoundary = max(stackWidth, stackHeight) + 160;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final viewportSize = Size(
            constraints.maxWidth,
            constraints.maxHeight,
          );
          if (_viewportSize != viewportSize) {
            _viewportSize = viewportSize;
            _hasAppliedViewportFit = false;
            _scheduleViewportFit();
          }

          return Stack(
            clipBehavior: Clip.none,
            children: [
              CallbackShortcuts(
                bindings: <ShortcutActivator, VoidCallback>{
                  const SingleActivator(LogicalKeyboardKey.equal): () =>
                      _zoomBy(1.2),
                  const SingleActivator(LogicalKeyboardKey.numpadAdd): () =>
                      _zoomBy(1.2),
                  const SingleActivator(LogicalKeyboardKey.minus): () =>
                      _zoomBy(1 / 1.2),
                  const SingleActivator(LogicalKeyboardKey.numpadSubtract):
                      () => _zoomBy(1 / 1.2),
                  const SingleActivator(LogicalKeyboardKey.digit0): () =>
                      _fitTreeToViewport(),
                },
                child: Focus(
                  autofocus: true,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      if (_hoveredBranchPersonId != null &&
                          !widget.isEditMode) {
                        setState(() {
                          _hoveredBranchPersonId = null;
                        });
                      }
                    },
                    onDoubleTap: _fitTreeToViewport,
                    child: InteractiveViewer(
                      transformationController: _transformationController,
                      constrained: false,
                      clipBehavior: Clip.none,
                      boundaryMargin: EdgeInsets.all(interactionBoundary),
                      panAxis: PanAxis.free,
                      panEnabled: _draggingPersonId == null,
                      scaleEnabled: true,
                      trackpadScrollCausesScale: true,
                      minScale: 0.08,
                      maxScale: 3.5,
                      child: SizedBox(
                        width: stackWidth,
                        height: stackHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            if (widget.showGenerationGuides)
                              ..._buildGenerationGuideWidgets(
                                stackWidth: stackWidth,
                              ),
                            if (widget.enableClusterHighlights &&
                                _showFamilyClusters)
                              IgnorePointer(
                                child: Stack(
                                  children: _buildFamilyClusterWidgets(
                                      familyClusters),
                                ),
                              ),
                            CustomPaint(
                              size: Size(stackWidth, stackHeight),
                              painter:
                                  FamilyTreePainter(nodePositions, connections),
                            ),
                            ..._buildPersonWidgets(),
                            if (widget.isEditMode)
                              _buildInlineEditPanel(
                                stackWidth: stackWidth,
                                stackHeight: stackHeight,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: _buildViewportControls(),
              ),
            ],
          );
        },
      ),
    );
  }

  void _selectEditPerson(FamilyPerson person) {
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedEditPersonId = person.id;
    });
    widget.onEditPersonSelected?.call(person);
  }

  Map<String, Offset> _mergeManualNodePositions(
    Map<String, Offset> automaticPositions,
  ) {
    final manualPositions = widget.manualNodePositions;
    if (manualPositions == null || manualPositions.isEmpty) {
      return automaticPositions;
    }

    final merged = Map<String, Offset>.from(automaticPositions);
    for (final entry in manualPositions.entries) {
      if (!merged.containsKey(entry.key)) {
        continue;
      }
      merged[entry.key] = _normalizeNodePosition(entry.value);
    }
    return merged;
  }

  Size _calculateTreeSize(
    Map<String, Offset> positions, {
    double minimumWidth = 300,
    double minimumHeight = 300,
  }) {
    if (positions.isEmpty) {
      return Size(
        max(minimumWidth, 300),
        max(minimumHeight, 300),
      );
    }

    double maxRight = 0;
    double maxBottom = 0;
    for (final position in positions.values) {
      maxRight = max(
        maxRight,
        position.dx +
            InteractiveFamilyTree.nodeWidth / 2 +
            InteractiveFamilyTree.contentInsetHorizontal,
      );
      maxBottom = max(
        maxBottom,
        position.dy +
            InteractiveFamilyTree.nodeHeight / 2 +
            InteractiveFamilyTree.contentInsetBottom,
      );
    }

    return Size(
      max(maxRight, max(minimumWidth, 300)),
      max(maxBottom, max(minimumHeight, 300)),
    );
  }

  Offset _normalizeNodePosition(Offset position) {
    final minDx = InteractiveFamilyTree.contentInsetHorizontal +
        InteractiveFamilyTree.nodeWidth / 2;
    final minDy = InteractiveFamilyTree.contentInsetTop +
        InteractiveFamilyTree.nodeHeight / 2;
    return Offset(
      max(position.dx, minDx),
      max(position.dy, minDy),
    );
  }

  void _handleNodePanStart(FamilyPerson person) {
    if (!widget.isEditMode) {
      return;
    }
    _selectEditPerson(person);
    setState(() {
      _draggingPersonId = person.id;
    });
  }

  void _handleNodePanUpdate(FamilyPerson person, DragUpdateDetails details) {
    if (!widget.isEditMode) {
      return;
    }

    final currentPosition = nodePositions[person.id];
    if (currentPosition == null) {
      return;
    }

    final effectiveScale = _currentScale <= 0 ? 1.0 : _currentScale;
    final delta = details.delta / effectiveScale;
    final nextPosition = _normalizeNodePosition(currentPosition + delta);
    final updatedPositions = Map<String, Offset>.from(nodePositions)
      ..[person.id] = nextPosition;

    setState(() {
      nodePositions = updatedPositions;
      treeSize = _calculateTreeSize(updatedPositions);
    });
  }

  void _handleNodePanEnd() {
    if (_draggingPersonId == null) {
      return;
    }

    final updatedPositions = Map<String, Offset>.from(nodePositions);
    setState(() {
      _draggingPersonId = null;
    });
    widget.onNodePositionsChanged?.call(updatedPositions);
  }

  List<_FamilyClusterOverlay> _buildFamilyClusters() {
    if (nodePositions.isEmpty) {
      return const <_FamilyClusterOverlay>[];
    }

    final peopleById = <String, FamilyPerson>{
      for (final entry in widget.peopleData)
        (entry['person'] as FamilyPerson).id: entry['person'] as FamilyPerson,
    };
    final parentToChildren = <String, Set<String>>{};
    final spousesByPerson = <String, Set<String>>{};
    final siblingsByPerson = <String, Set<String>>{};

    for (final relation in widget.relations) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null &&
          childId != null &&
          nodePositions.containsKey(parentId) &&
          nodePositions.containsKey(childId)) {
        parentToChildren.putIfAbsent(parentId, () => <String>{}).add(childId);
      }
      if (_isSpouseRelation(relation) &&
          nodePositions.containsKey(relation.person1Id) &&
          nodePositions.containsKey(relation.person2Id)) {
        spousesByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        spousesByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
      }
      if (_isSiblingRelation(relation) &&
          nodePositions.containsKey(relation.person1Id) &&
          nodePositions.containsKey(relation.person2Id)) {
        siblingsByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        siblingsByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
      }
    }

    final palette = <Color>[
      const Color(0xFF89C2D9),
      const Color(0xFFF6BD60),
      const Color(0xFF84A59D),
      const Color(0xFFF28482),
      const Color(0xFFA3C4BC),
      const Color(0xFF90BE6D),
    ];
    final overlays = <_FamilyClusterOverlay>[];
    final processedGroups = <String>{};
    final ids = peopleById.keys.toList()..sort();

    for (final personId in ids) {
      if (!nodePositions.containsKey(personId)) {
        continue;
      }
      final groupMembers = <String>{personId};
      final queue = <String>[personId];
      while (queue.isNotEmpty) {
        final currentId = queue.removeAt(0);
        for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
          if (groupMembers.add(spouseId)) {
            queue.add(spouseId);
          }
        }
        for (final siblingId
            in siblingsByPerson[currentId] ?? const <String>{}) {
          if (groupMembers.add(siblingId)) {
            queue.add(siblingId);
          }
        }
      }

      final groupKey = groupMembers.toList()..sort();
      final groupKeyString = groupKey.join('::');
      if (!processedGroups.add(groupKeyString)) {
        continue;
      }

      final childIds = <String>{};
      for (final memberId in groupMembers) {
        childIds.addAll(parentToChildren[memberId] ?? const <String>{});
      }

      final memberIds = <String>{...groupMembers, ...childIds}
          .where(nodePositions.containsKey)
          .toList();
      if (memberIds.length < 2) {
        continue;
      }

      final positions = memberIds.map((id) => nodePositions[id]!).toList();
      final minX = positions
          .map((pos) => pos.dx - InteractiveFamilyTree.nodeWidth / 2)
          .reduce(min);
      final maxX = positions
          .map((pos) => pos.dx + InteractiveFamilyTree.nodeWidth / 2)
          .reduce(max);
      final minY = positions
          .map((pos) => pos.dy - InteractiveFamilyTree.nodeHeight / 2)
          .reduce(min);
      final maxY = positions
          .map((pos) => pos.dy + InteractiveFamilyTree.nodeHeight / 2)
          .reduce(max);

      final familyName = _buildFamilyClusterLabel(
        parents: groupMembers
            .map((id) => peopleById[id])
            .whereType<FamilyPerson>()
            .toList(),
        children: childIds
            .map((id) => peopleById[id])
            .whereType<FamilyPerson>()
            .toList(),
      );
      final color = palette[groupKeyString.hashCode.abs() % palette.length];
      overlays.add(
        _FamilyClusterOverlay(
          rect: Rect.fromLTRB(minX - 18, minY - 34, maxX + 18, maxY + 18),
          label: familyName,
          color: color,
        ),
      );
    }

    return overlays;
  }

  String _buildFamilyClusterLabel({
    required List<FamilyPerson> parents,
    required List<FamilyPerson> children,
  }) {
    final candidates = [...parents, ...children];
    final surnameCounts = <String, int>{};
    for (final person in candidates) {
      final surname = _extractSurname(person.name);
      if (surname.isEmpty) {
        continue;
      }
      surnameCounts.update(surname, (value) => value + 1, ifAbsent: () => 1);
    }

    if (surnameCounts.isNotEmpty) {
      final topSurname = surnameCounts.entries.toList()
        ..sort((a, b) {
          final countCompare = b.value.compareTo(a.value);
          if (countCompare != 0) {
            return countCompare;
          }
          return a.key.compareTo(b.key);
        });
      if (topSurname.length > 1 &&
          topSurname[1].value == topSurname.first.value) {
        return 'Ветка ${topSurname.first.key} / ${topSurname[1].key}';
      }
      return 'Ветка ${topSurname.first.key}';
    }

    final anchor =
        parents.isNotEmpty ? parents.first.name : children.first.name;
    return 'Ветка $anchor';
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

  List<Widget> _buildFamilyClusterWidgets(
    List<_FamilyClusterOverlay> familyClusters,
  ) {
    return familyClusters
        .map(
          (cluster) => Positioned(
            left: cluster.rect.left,
            top: cluster.rect.top,
            width: cluster.rect.width,
            height: cluster.rect.height,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: cluster.color.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(
                    color: cluster.color.withValues(alpha: 0.35),
                    width: 1.2,
                  ),
                ),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    margin: const EdgeInsets.all(10),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: cluster.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      cluster.label,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        .toList();
  }

  List<Widget> _buildGenerationGuideWidgets({
    required double stackWidth,
  }) {
    if (nodePositions.isEmpty) {
      return const <Widget>[];
    }

    final levels = nodePositions.values
        .map((offset) => offset.dy)
        .toSet()
        .toList()
      ..sort();
    final guides = <Widget>[];

    for (var index = 0; index < levels.length; index++) {
      final levelY = levels[index];
      final labelTop = max(
        8.0,
        levelY - InteractiveFamilyTree.nodeHeight / 2 - 26,
      );
      guides.add(
        Positioned(
          left: 14,
          top: labelTop,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: 0.92),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
              ),
              child: Text(
                _generationLabel(index, levels.length),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
          ),
        ),
      );

      if (index < levels.length - 1) {
        final nextLevelY = levels[index + 1];
        final dividerY = (levelY + nextLevelY) / 2;
        guides.add(
          Positioned(
            left: 56,
            top: dividerY,
            width: stackWidth - 88,
            child: IgnorePointer(
              child: Container(
                height: 1,
                color: Theme.of(context)
                    .colorScheme
                    .outlineVariant
                    .withValues(alpha: 0.28),
              ),
            ),
          ),
        );
      }
    }

    return guides;
  }

  String _generationLabel(int index, int totalLevels) {
    if (totalLevels == 1) {
      return 'Центр дерева';
    }
    if (index == 0) {
      return 'Старшее поколение';
    }
    if (index == totalLevels - 1) {
      return 'Младшее поколение';
    }
    return 'Поколение ${index + 1}';
  }

  Widget _buildInlineEditPanel({
    required double stackWidth,
    required double stackHeight,
  }) {
    final selectedId = _selectedEditPersonId;
    if (selectedId == null) {
      return const SizedBox.shrink();
    }

    final position = nodePositions[selectedId];
    if (position == null) {
      return const SizedBox.shrink();
    }

    final person = widget.peopleData
        .map((entry) => entry['person'])
        .whereType<FamilyPerson>()
        .firstWhere(
          (candidate) => candidate.id == selectedId,
          orElse: () => FamilyPerson.empty,
        );
    if (person == FamilyPerson.empty) {
      return const SizedBox.shrink();
    }

    const panelWidth = 310.0;
    const panelHeight = 210.0;
    final preferredRight =
        position.dx + InteractiveFamilyTree.nodeWidth / 2 + 18;
    final preferredLeft =
        position.dx - InteractiveFamilyTree.nodeWidth / 2 - panelWidth - 18;
    final canPlaceRight = preferredRight + panelWidth <= stackWidth - 16;
    final canPlaceLeft = preferredLeft >= 16;

    late final double left;
    late final double top;
    if (canPlaceRight) {
      left = preferredRight;
      top = max(
        16.0,
        min(position.dy - panelHeight / 2, stackHeight - panelHeight - 16),
      );
    } else if (canPlaceLeft) {
      left = preferredLeft;
      top = max(
        16.0,
        min(position.dy - panelHeight / 2, stackHeight - panelHeight - 16),
      );
    } else {
      left = max(
        16.0,
        min(
          position.dx - panelWidth / 2,
          stackWidth - panelWidth - 16,
        ),
      );
      top = min(
        position.dy + InteractiveFamilyTree.nodeHeight / 2 + 14,
        stackHeight - panelHeight - 16,
      );
    }

    return Positioned(
      left: left,
      top: top,
      width: panelWidth,
      child: Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border:
                Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      person.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                  ),
                  IconButton(
                    onPressed: () {
                      setState(() {
                        _selectedEditPersonId = null;
                      });
                    },
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close),
                    tooltip: 'Скрыть быстрые действия',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Добавляйте родственников прямо из дерева без перехода в отдельный список действий.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildInlineActionButton(
                    icon: Icons.north_outlined,
                    label: 'Родитель',
                    onTap: () => widget.onAddRelativeTapWithType(
                      person,
                      RelationType.parent,
                    ),
                  ),
                  _buildInlineActionButton(
                    icon: Icons.favorite_border,
                    label: 'Супруг',
                    onTap: () => widget.onAddRelativeTapWithType(
                      person,
                      RelationType.spouse,
                    ),
                  ),
                  _buildInlineActionButton(
                    icon: Icons.south_outlined,
                    label: 'Ребёнок',
                    onTap: () => widget.onAddRelativeTapWithType(
                      person,
                      RelationType.child,
                    ),
                  ),
                  _buildInlineActionButton(
                    icon: Icons.people_outline,
                    label: 'Сиблинг',
                    onTap: () => widget.onAddRelativeTapWithType(
                      person,
                      RelationType.sibling,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => widget.onPersonTap(person),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Карточка'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _showEditActionsSheet(context, person),
                    icon: const Icon(Icons.more_horiz),
                    label: const Text('Ещё действия'),
                  ),
                  if (!widget.currentUserIsInTree)
                    OutlinedButton.icon(
                      onPressed: () =>
                          _showAddSelfRelationTypeDialog(context, person),
                      icon: const Icon(Icons.person_add_alt_1),
                      label: const Text('Вписать себя'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInlineActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }

  List<Widget> _buildPersonWidgets() {
    return nodePositions.entries.map((entry) {
      final personId = entry.key;
      final position = entry.value;
      var nodeData = widget.peopleData.firstWhere(
        (data) => (data['person'] as FamilyPerson).id == personId,
        orElse: () => <String, dynamic>{},
      );

      if (nodeData.isEmpty) return const SizedBox.shrink();

      final topLeftX = position.dx - InteractiveFamilyTree.nodeWidth / 2;
      final topLeftY = position.dy - InteractiveFamilyTree.nodeHeight / 2;

      return Positioned(
        left: topLeftX,
        top: topLeftY,
        width: InteractiveFamilyTree.nodeWidth,
        child: _buildPersonNode(nodeData),
      );
    }).toList();
  }

  Widget _buildPersonNode(Map<String, dynamic> nodeData) {
    final FamilyPerson person = nodeData['person'];
    final UserProfile? userProfile = nodeData['userProfile'];

    final String displayName = userProfile != null
        ? '${userProfile.firstName} ${userProfile.lastName}'.trim()
        : person.name;
    final String? displayPhotoUrl = userProfile?.photoURL ?? person.photoUrl;
    final Gender displayGender = person.gender;
    final isCurrentUserNode =
        widget.currentUserId != null && person.userId == widget.currentUserId;
    final isBranchRoot = widget.branchRootPersonId == person.id;
    final isSelectedInEditMode =
        widget.isEditMode && _selectedEditPersonId == person.id;
    final isDraggingNode = _draggingPersonId == person.id;
    final showBranchChip = !widget.isEditMode &&
        widget.onBranchFocusRequested != null &&
        (isBranchRoot || _hoveredBranchPersonId == person.id);

    final cardContent = Container(
      key: ValueKey<String>('tree-node-${person.id}'),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      decoration: BoxDecoration(
        color: isCurrentUserNode
            ? Theme.of(context).colorScheme.primaryContainer
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: isDraggingNode
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.32)
                : isSelectedInEditMode
                    ? Theme.of(context)
                        .colorScheme
                        .secondary
                        .withValues(alpha: 0.28)
                    : isCurrentUserNode
                        ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.22)
                        : Colors.black.withValues(alpha: 0.1),
            blurRadius: isDraggingNode
                ? 18
                : isSelectedInEditMode
                    ? 14
                    : (isCurrentUserNode ? 10 : 6),
            offset: Offset(0, isDraggingNode ? 5 : 2),
          ),
        ],
        border: Border.all(
          color: isDraggingNode
              ? Theme.of(context).colorScheme.primary
              : isSelectedInEditMode
                  ? Theme.of(context).colorScheme.secondary
                  : isCurrentUserNode
                      ? Theme.of(context).colorScheme.primary
                      : displayGender == Gender.male
                          ? Colors.blue.shade300
                          : Colors.pink.shade300,
          width: isDraggingNode
              ? 2.8
              : isSelectedInEditMode
                  ? 2.5
                  : (isCurrentUserNode ? 2 : 1.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            backgroundColor: displayGender == Gender.male
                ? Colors.blue.shade100
                : Colors.pink.shade100,
            backgroundImage:
                displayPhotoUrl != null && displayPhotoUrl.isNotEmpty
                    ? NetworkImage(displayPhotoUrl)
                    : null,
            radius: 22,
            child: displayPhotoUrl == null || displayPhotoUrl.isEmpty
                ? Icon(
                    displayGender == Gender.male
                        ? Icons.person
                        : Icons.person_outline,
                    size: 20,
                    color: displayGender == Gender.male
                        ? Colors.blue.shade800
                        : Colors.pink.shade800,
                  )
                : null,
          ),
          const SizedBox(height: 6),
          Text(
            displayName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 12,
              height: 1.15,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            _getLifeDates(person),
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w500,
              color: Colors.grey[700],
            ),
            textAlign: TextAlign.center,
          ),
          if (isCurrentUserNode) ...[
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                'Это вы',
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onPrimary,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.center,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart:
              widget.isEditMode ? (_) => _handleNodePanStart(person) : null,
          onPanUpdate: widget.isEditMode
              ? (details) => _handleNodePanUpdate(person, details)
              : null,
          onPanEnd: widget.isEditMode ? (_) => _handleNodePanEnd() : null,
          onPanCancel: widget.isEditMode ? _handleNodePanEnd : null,
          onTap: () {
            if (widget.isEditMode) {
              _selectEditPerson(person);
              return;
            }
            widget.onPersonTap(person);
          },
          onLongPress: widget.isEditMode
              ? () => _showEditActionsSheet(context, person)
              : widget.onBranchFocusRequested != null
                  ? () => widget.onBranchFocusRequested!(person)
                  : null,
          child: MouseRegion(
            onEnter: (_) {
              if (widget.isEditMode) {
                return;
              }
              setState(() {
                _hoveredBranchPersonId = person.id;
              });
            },
            onExit: (_) {
              if (widget.isEditMode ||
                  _hoveredBranchPersonId != person.id ||
                  isBranchRoot) {
                return;
              }
              setState(() {
                _hoveredBranchPersonId = null;
              });
            },
            child: cardContent,
          ),
        ),
        if (widget.isEditMode)
          Positioned(
            top: -8,
            right: -8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isSelectedInEditMode
                    ? Theme.of(context).colorScheme.secondary
                    : Theme.of(context).colorScheme.primary,
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: (isSelectedInEditMode
                            ? Theme.of(context).colorScheme.secondary
                            : Theme.of(context).colorScheme.primary)
                        .withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isDraggingNode
                        ? Icons.open_with
                        : isSelectedInEditMode
                            ? Icons.check
                            : Icons.touch_app_outlined,
                    size: 12,
                    color: isDraggingNode
                        ? Theme.of(context).colorScheme.onPrimary
                        : isSelectedInEditMode
                            ? Theme.of(context).colorScheme.onSecondary
                            : Theme.of(context).colorScheme.onPrimary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    isDraggingNode
                        ? 'Тяните'
                        : isSelectedInEditMode
                            ? 'Выбрано'
                            : 'Нажмите',
                    style: TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      color: isDraggingNode
                          ? Theme.of(context).colorScheme.onPrimary
                          : isSelectedInEditMode
                              ? Theme.of(context).colorScheme.onSecondary
                              : Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (showBranchChip)
          Positioned(
            top: -12,
            left: 10,
            child: Tooltip(
              message: isBranchRoot
                  ? 'Сейчас показана эта ветка'
                  : 'Сфокусироваться на ветке этого человека',
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => widget.onBranchFocusRequested!(person),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isBranchRoot
                          ? Theme.of(context).colorScheme.primaryContainer
                          : Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.96),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: isBranchRoot
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.outlineVariant,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isBranchRoot
                              ? Icons.account_tree_outlined
                              : Icons.alt_route_rounded,
                          size: 14,
                          color: isBranchRoot
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          isBranchRoot ? 'Фокус' : 'Ветка',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: isBranchRoot
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .colorScheme
                                    .onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  void _showEditActionsSheet(BuildContext context, FamilyPerson person) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetContext).size.height * 0.8,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    person.name,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Выберите действие для этого человека.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  _buildEditActionTile(
                    sheetContext: sheetContext,
                    icon: Icons.open_in_new,
                    title: 'Открыть профиль',
                    onTap: () => widget.onPersonTap(person),
                  ),
                  _buildEditActionTile(
                    sheetContext: sheetContext,
                    icon: Icons.arrow_upward,
                    title: 'Добавить родителя',
                    onTap: () => widget.onAddRelativeTapWithType(
                        person, RelationType.parent),
                  ),
                  _buildEditActionTile(
                    sheetContext: sheetContext,
                    icon: Icons.favorite_border,
                    title: 'Добавить супруга или партнёра',
                    onTap: () => widget.onAddRelativeTapWithType(
                        person, RelationType.spouse),
                  ),
                  _buildEditActionTile(
                    sheetContext: sheetContext,
                    icon: Icons.arrow_downward,
                    title: 'Добавить ребёнка',
                    onTap: () => widget.onAddRelativeTapWithType(
                        person, RelationType.child),
                  ),
                  _buildEditActionTile(
                    sheetContext: sheetContext,
                    icon: Icons.people_outline,
                    title: 'Добавить брата или сестру',
                    onTap: () => widget.onAddRelativeTapWithType(
                      person,
                      RelationType.sibling,
                    ),
                  ),
                  if (!widget.currentUserIsInTree)
                    _buildEditActionTile(
                      sheetContext: sheetContext,
                      icon: Icons.person_add_alt_1,
                      title: 'Добавить себя в это дерево',
                      onTap: () =>
                          _showAddSelfRelationTypeDialog(context, person),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEditActionTile({
    required BuildContext sheetContext,
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon),
      title: Text(title),
      onTap: () {
        Navigator.of(sheetContext).pop();
        onTap();
      },
    );
  }

  void _showAddSelfRelationTypeDialog(
    BuildContext context,
    FamilyPerson targetPerson,
  ) {
    showDialog(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: Text('Добавить себя как...'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: RelationType.values
                  .where(
                (type) =>
                    /* type != RelationType.unknown && */ type !=
                        RelationType.other &&
                    // <<< Дополнительный фильтр: Убираем слишком далекие/сложные связи для этого диалога >>>
                    ![
                      RelationType.greatGrandparent,
                      RelationType.greatGrandchild,
                      RelationType.cousin,
                      RelationType.parentInLaw,
                      RelationType.childInLaw,
                      RelationType.siblingInLaw,
                      RelationType.stepparent,
                      RelationType.stepchild,
                      RelationType.inlaw,
                      RelationType.ex_spouse,
                      RelationType.ex_partner,
                      RelationType.friend,
                      RelationType.colleague,
                    ].contains(type),
              ) // Фильтруем ненужные и сложные
                  .map((type) {
                // Определяем текст кнопки на основе типа связи
                String buttonText =
                    'Как ${FamilyRelation.getGenericRelationTypeStringRu(type).toLowerCase()}';
                IconData iconData = Icons.person; // Иконка по умолчанию
                switch (type) {
                  case RelationType.parent:
                    iconData = Icons.arrow_upward;
                    break;
                  case RelationType.child:
                    iconData = Icons.arrow_downward;
                    break;
                  case RelationType.spouse:
                    iconData = Icons.favorite;
                    break;
                  case RelationType.sibling:
                    iconData = Icons.people;
                    break;
                  default:
                    break;
                }

                return ListTile(
                  leading: Icon(iconData),
                  title: Text(buttonText),
                  onTap: () {
                    Navigator.of(dialogContext).pop(); // Закрываем диалог
                    // <<< ИСПРАВЛЕНИЕ: Вызываем коллбэк с ЗЕРКАЛЬНЫМ типом связи >>>
                    // Передаем отношение ОТ targetPerson К новому пользователю
                    widget.onAddSelfTapWithType(
                      targetPerson,
                      FamilyRelation.getMirrorRelation(type),
                    );
                  },
                );
              }).toList(),
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text('Отмена'),
              onPressed: () {
                Navigator.of(dialogContext).pop();
              },
            ),
          ],
        );
      },
    );
  }

  String _getLifeDates(FamilyPerson person) {
    final birthYear = person.birthDate?.year;
    final deathYear = person.deathDate?.year;

    if (birthYear == null && person.isAlive) {
      return 'Годы не указаны';
    }
    if (birthYear == null && deathYear != null) {
      return 'ум. $deathYear';
    }
    if (birthYear != null && person.isAlive) {
      return '$birthYear - н.в.';
    }
    if (birthYear != null && deathYear == null) {
      return '$birthYear - ?';
    }
    return '${birthYear ?? '?'} - ${deathYear ?? '?'}';
  }

  Widget _buildViewportControls() {
    final currentUserNodeId = _findCurrentUserNodeId();
    final branchRootPersonId = widget.branchRootPersonId;
    final selectedPersonId = _selectedEditPersonId;
    final familyClusters = widget.enableClusterHighlights
        ? _buildFamilyClusters()
        : const <_FamilyClusterOverlay>[];
    final generationCount =
        widget.showGenerationGuides ? _estimateGenerationCount() : 0;
    final zoomPercent = (_currentScale * 100).round();
    final helperText = widget.isEditMode
        ? 'Нажмите на карточку, чтобы открыть быстрые действия. Долгое нажатие открывает полное меню, а drag позволяет вручную собрать композицию ${widget.graphLabel}.'
        : branchRootPersonId != null && branchRootPersonId.isNotEmpty
            ? widget.showGenerationGuides
                ? 'Показана выбранная ветка. Используйте плашки на карточках, чтобы сменить фокус.'
                : 'Показан выбранный круг. Используйте плашки на карточках, чтобы сменить фокус.'
            : widget.showGenerationGuides
                ? 'Тяните схему в любую сторону, масштабируйте колесом или кнопками и открывайте карточки людей. Плашка «Ветка» или долгое нажатие на карточку фокусирует схему на выбранной семье. Горячие клавиши: +, -, 0.'
                : 'Тяните граф в любую сторону, масштабируйте колесом или кнопками и открывайте карточки людей. Плашка на карточке помогает сфокусироваться на выбранном круге. Горячие клавиши: +, -, 0.';

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 860;
        final statusChips = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildOverlayChip(
              icon: widget.showGenerationGuides
                  ? Icons.account_tree_outlined
                  : Icons.diversity_3_outlined,
              label:
                  widget.showGenerationGuides ? 'Режим семьи' : 'Режим друзей',
            ),
            _buildOverlayChip(
              icon: Icons.zoom_in_map_outlined,
              label: 'Масштаб $zoomPercent%',
            ),
            if (widget.hasManualLayout)
              _buildOverlayChip(
                icon: Icons.open_with,
                label: 'Ручной layout',
                highlighted: true,
              ),
            if (selectedPersonId != null && selectedPersonId.isNotEmpty)
              _buildOverlayChip(
                icon: Icons.ads_click_outlined,
                label: 'Выбран узел',
                highlighted: true,
              ),
          ],
        );
        final infoCard = Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              statusChips,
              const SizedBox(height: 10),
              Text(
                !widget.showGenerationGuides
                    ? '$helperText Это свободный сетевой режим без поколенческой сетки: связи читаются по линиям, а карточки можно раскладывать вручную.'
                    : familyClusters.isEmpty
                        ? '$helperText Поколений на экране: $generationCount. Синие карточки обозначают мужчин, розовые — женщин.'
                        : '$helperText Поколений на экране: $generationCount. Цветные рамки помогают увидеть отдельные семейные ветки, а подписи слева — уровни поколения.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        );
        final controls = Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _buildQuickControlStat(
              icon: Icons.open_with,
              label: widget.hasManualLayout ? 'Ручной layout' : 'Auto layout',
              highlighted: widget.hasManualLayout,
            ),
            _buildQuickControlStat(
              icon: Icons.layers_outlined,
              label: widget.showGenerationGuides
                  ? '$generationCount поколений'
                  : '${familyClusters.length} кластеров',
            ),
            IconButton.filledTonal(
              onPressed: () => _zoomBy(1.2),
              tooltip: 'Увеличить',
              icon: const Icon(Icons.add),
            ),
            IconButton.filledTonal(
              onPressed: () => _zoomBy(1 / 1.2),
              tooltip: 'Уменьшить',
              icon: const Icon(Icons.remove),
            ),
            if (widget.enableClusterHighlights)
              IconButton.filledTonal(
                onPressed: () {
                  setState(() {
                    _showFamilyClusters = !_showFamilyClusters;
                  });
                },
                tooltip: _showFamilyClusters
                    ? 'Скрыть семейные рамки'
                    : 'Показать семейные рамки',
                icon: Icon(
                  _showFamilyClusters
                      ? Icons.layers_clear_outlined
                      : Icons.layers_outlined,
                ),
              ),
            FilledButton.tonalIcon(
              onPressed: _fitTreeToViewport,
              icon: const Icon(Icons.fit_screen_outlined),
              label: const Text('Вписать'),
            ),
            if (branchRootPersonId != null && branchRootPersonId.isNotEmpty)
              FilledButton.tonalIcon(
                onPressed: () => _focusOnPerson(branchRootPersonId),
                icon: const Icon(Icons.alt_route),
                label:
                    Text(widget.showGenerationGuides ? 'К ветке' : 'К кругу'),
              ),
            if (branchRootPersonId != null &&
                branchRootPersonId.isNotEmpty &&
                widget.onBranchFocusCleared != null)
              FilledButton.tonalIcon(
                onPressed: widget.onBranchFocusCleared,
                icon: const Icon(Icons.clear_all),
                label: Text(
                  widget.showGenerationGuides
                      ? 'Сбросить ветку'
                      : 'Сбросить круг',
                ),
              ),
            if (currentUserNodeId != null)
              FilledButton.tonalIcon(
                onPressed: () => _focusOnPerson(currentUserNodeId),
                icon: const Icon(Icons.my_location_outlined),
                label: const Text('Ко мне'),
              ),
            if (selectedPersonId != null && selectedPersonId.isNotEmpty)
              FilledButton.tonalIcon(
                onPressed: () => _focusOnPerson(selectedPersonId),
                icon: const Icon(Icons.center_focus_strong_outlined),
                label: const Text('К выбранному'),
              ),
            if (widget.hasManualLayout && widget.onResetLayout != null)
              FilledButton.tonalIcon(
                onPressed: widget.onResetLayout,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Сбросить layout'),
              ),
          ],
        );

        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              infoCard,
              const SizedBox(height: 8),
              controls,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: infoCard),
            const SizedBox(width: 10),
            SizedBox(
              width: 260,
              child: Align(
                alignment: Alignment.topRight,
                child: controls,
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildQuickControlStat({
    required IconData icon,
    required String label,
    bool highlighted = false,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: highlighted
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverlayChip({
    required IconData icon,
    required String label,
    bool highlighted = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: highlighted ? colorScheme.primaryContainer : colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted ? colorScheme.primary : colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }

  String? _findCurrentUserNodeId() {
    final currentUserId = widget.currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return null;
    }

    for (final entry in widget.peopleData) {
      final person = entry['person'];
      if (person is FamilyPerson && person.userId == currentUserId) {
        return person.id;
      }
    }

    return null;
  }

  int _estimateGenerationCount() {
    final levels = nodePositions.values
        .map((offset) => offset.dy.toStringAsFixed(1))
        .toSet()
        .length;
    return max(levels, 1);
  }

  void _scheduleViewportFit() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _hasAppliedViewportFit) {
        return;
      }
      _fitTreeToViewport();
      final branchRootPersonId = widget.branchRootPersonId;
      if (branchRootPersonId != null && branchRootPersonId.isNotEmpty) {
        _focusOnPerson(branchRootPersonId);
      }
      _hasAppliedViewportFit = true;
    });
  }

  void _fitTreeToViewport() {
    final viewport = _viewportSize;
    if (viewport == null ||
        viewport.width <= 0 ||
        viewport.height <= 0 ||
        treeSize == Size.zero) {
      return;
    }

    final contentWidth = treeSize.width;
    final contentHeight = treeSize.height;
    final horizontalScale = (viewport.width - 48) / contentWidth;
    final verticalScale =
        (viewport.height - _viewportReservedTop - _viewportReservedBottom) /
            contentHeight;
    final targetScale =
        horizontalScale < verticalScale ? horizontalScale : verticalScale;
    final safeScale = targetScale.clamp(0.2, 1.0);

    final translateX = (viewport.width - contentWidth * safeScale) / 2;
    final availableHeight =
        viewport.height - _viewportReservedTop - _viewportReservedBottom;
    final translateY = _viewportReservedTop +
        (availableHeight - contentHeight * safeScale) / 2;

    _transformationController.value = vector_math.Matrix4.identity()
      ..translateByDouble(translateX, translateY, 0, 1)
      ..scaleByDouble(safeScale, safeScale, 1, 1);
  }

  void _focusOnPerson(String personId) {
    final viewport = _viewportSize;
    final targetPosition = nodePositions[personId];
    if (viewport == null ||
        viewport.width <= 0 ||
        viewport.height <= 0 ||
        targetPosition == null) {
      return;
    }

    const focusScale = 1.0;
    final translateX = viewport.width / 2 - targetPosition.dx * focusScale;
    final usableCenterY = _viewportReservedTop +
        (viewport.height - _viewportReservedTop - _viewportReservedBottom) / 2;
    final translateY = usableCenterY - targetPosition.dy * focusScale;

    _transformationController.value = vector_math.Matrix4.identity()
      ..translateByDouble(translateX, translateY, 0, 1)
      ..scaleByDouble(focusScale, focusScale, 1, 1);
  }

  void _zoomBy(double multiplier) {
    final viewport = _viewportSize;
    if (viewport == null || viewport.width <= 0 || viewport.height <= 0) {
      return;
    }

    final currentMatrix = _transformationController.value.clone();
    final currentScale = currentMatrix.getMaxScaleOnAxis();
    final targetScale = (currentScale * multiplier).clamp(0.08, 3.5);
    final appliedMultiplier = targetScale / currentScale;
    final viewportFocalPoint = Offset(
      viewport.width / 2,
      _viewportReservedTop +
          (viewport.height - _viewportReservedTop - _viewportReservedBottom) /
              2,
    );
    final sceneFocalPoint =
        _transformationController.toScene(viewportFocalPoint);

    _transformationController.value = currentMatrix
      ..translateByDouble(sceneFocalPoint.dx, sceneFocalPoint.dy, 0, 1)
      ..scaleByDouble(appliedMultiplier, appliedMultiplier, 1, 1)
      ..translateByDouble(-sceneFocalPoint.dx, -sceneFocalPoint.dy, 0, 1);
  }

  Map<String, Offset> _performInitialXLayout(
    int maxLevel,
    Map<int, List<String>> nodesByLevel,
    Map<String, List<String>> spouseMap,
    Map<String, int> nodeLevels,
    Map<String, List<String>> childToParentsMap,
  ) {
    final Map<String, Offset> initialPositions = {};
    double layoutMaxX = 0;

    for (int level = 0; level <= maxLevel; level++) {
      final levelNodes = nodesByLevel[level] ?? [];
      if (levelNodes.isEmpty) continue;

      // --- NEW: Sort nodes based on average parent X position ---
      Map<String, double> avgParentX =
          {}; // Карта для хранения среднего X родителя
      if (level > 0) {
        // Сортировка имеет смысл только для уровней > 0
        for (final nodeId in levelNodes) {
          final parents = childToParentsMap[nodeId] ?? [];
          double parentSumX = 0;
          int parentCount = 0;
          for (final parentId in parents) {
            // Проверяем, что родитель на предыдущем уровне и имеет позицию
            if (nodeLevels.containsKey(parentId) &&
                nodeLevels[parentId] == level - 1 &&
                initialPositions.containsKey(parentId)) {
              parentSumX += initialPositions[parentId]!.dx;
              parentCount++;
            }
          }
          // Используем среднее X родителей или 0.0, если родителей нет/не найдены
          avgParentX[nodeId] =
              (parentCount > 0) ? parentSumX / parentCount : 0.0;
        }
        // Сортируем узлы уровня по вычисленному среднему X родителей
        levelNodes.sort((a, b) => avgParentX[a]!.compareTo(avgParentX[b]!));
      } else {
        // Для уровня 0 оставляем простую сортировку (например, по ID)
        levelNodes.sort();
      }
      // --- END NEW ---

      double currentX = 0;
      final Set<String> placedNodesInLevel = {};

      // Используем отсортированный levelNodes
      for (final nodeId in levelNodes) {
        if (placedNodesInLevel.contains(nodeId)) continue;

        final yPos = level *
                (InteractiveFamilyTree.nodeHeight +
                    InteractiveFamilyTree.levelSeparation) +
            InteractiveFamilyTree.nodeHeight / 2;

        final List<String> spousesOnLevel = (spouseMap[nodeId] ?? [])
            // Снова используем where, т.к. nodeLevels теперь передается
            .where(
              (spouseId) =>
                  nodeLevels.containsKey(spouseId) &&
                  nodeLevels[spouseId] == level,
            )
            .toList();

        // --- Определяем членов группы (узел + супруги) ---
        final List<String> groupMembers = {
          nodeId,
          ...spousesOnLevel
        } // Удаляем дубликаты, если spouseMap двунаправленный
            .toList();

        // --- Place the sorted group members (Original logic before revision) ---
        double groupWidth = InteractiveFamilyTree.nodeWidth +
            (groupMembers.length - 1) *
                (InteractiveFamilyTree.spouseSeparation +
                    InteractiveFamilyTree.nodeWidth);

        double memberStartX = currentX;
        for (final memberId in groupMembers) {
          if (!placedNodesInLevel.contains(memberId)) {
            initialPositions[memberId] = Offset(
              memberStartX + InteractiveFamilyTree.nodeWidth / 2,
              yPos,
            );
            placedNodesInLevel.add(memberId);
          }
          // We always advance memberStartX even if placed, assuming standard widths/separations for the group block
          memberStartX += InteractiveFamilyTree.nodeWidth +
              InteractiveFamilyTree.spouseSeparation;
        }
        // Update currentX for the next group/node
        // The next node starts after the full block width + sibling separation
        currentX += groupWidth + InteractiveFamilyTree.siblingSeparation;
        // --- End Original Placement Logic ---
      }
      if (currentX > 0) {
        layoutMaxX = max(
          layoutMaxX,
          (currentX - InteractiveFamilyTree.siblingSeparation),
        );
      }
    }
    return initialPositions;
  }

  Map<String, Offset> _resolveCollisions(
    int maxLevel,
    Map<int, List<String>> nodesByLevel,
    Map<String, Offset> currentPositions,
    Map<String, List<String>> spouseMap,
  ) {
    Map<String, Offset> resolvedPositions = Map.from(currentPositions);
    final double minSeparation = InteractiveFamilyTree.siblingSeparation;
    final double nodeWidth = InteractiveFamilyTree.nodeWidth;

    for (int level = 0; level <= maxLevel; level++) {
      final levelNodes = nodesByLevel[level] ?? [];
      if (levelNodes.length < 2) continue;

      bool shifted;
      int maxPasses = levelNodes.length * levelNodes.length;
      int passes = 0;
      do {
        shifted = false;
        passes++;
        List<String> sortedLevelNodeIds = levelNodes
            .where((id) => resolvedPositions.containsKey(id))
            .toList();
        sortedLevelNodeIds.sort(
          (a, b) => (resolvedPositions[a]!.dx - nodeWidth / 2).compareTo(
            resolvedPositions[b]!.dx - nodeWidth / 2,
          ),
        );

        for (int i = 0; i < sortedLevelNodeIds.length - 1; i++) {
          final node1Id = sortedLevelNodeIds[i];
          final pos1 = resolvedPositions[node1Id];
          if (pos1 == null) continue;

          final group1Ids = _getNodeGroup(
            node1Id,
            level,
            resolvedPositions,
            spouseMap,
          );
          double group1RightEdge = double.negativeInfinity;
          for (final id in group1Ids) {
            final pos = resolvedPositions[id];
            if (pos != null) {
              group1RightEdge = max(group1RightEdge, pos.dx + nodeWidth / 2);
            }
          }
          if (group1RightEdge == double.negativeInfinity) continue;

          String? node2Id;
          int j = i + 1;
          while (j < sortedLevelNodeIds.length) {
            final potentialNode2Id = sortedLevelNodeIds[j];
            if (!group1Ids.contains(potentialNode2Id)) {
              node2Id = potentialNode2Id;
              break;
            }
            j++;
          }
          if (node2Id == null) continue;

          final pos2 = resolvedPositions[node2Id];
          if (pos2 == null) continue;

          final group2Ids = _getNodeGroup(
            node2Id,
            level,
            resolvedPositions,
            spouseMap,
          );
          double group2LeftEdge = double.infinity;
          for (final id in group2Ids) {
            final pos = resolvedPositions[id];
            if (pos != null) {
              group2LeftEdge = min(group2LeftEdge, pos.dx - nodeWidth / 2);
            }
          }
          if (group2LeftEdge == double.infinity) continue;

          final currentSeparation = group2LeftEdge - group1RightEdge;
          if (currentSeparation < minSeparation) {
            final shiftNeeded = minSeparation - currentSeparation;
            for (final idToShift in group2Ids) {
              final currentPos = resolvedPositions[idToShift];
              if (currentPos != null) {
                resolvedPositions[idToShift] = Offset(
                  currentPos.dx + shiftNeeded,
                  currentPos.dy,
                );
              }
            }
            shifted = true;
            break;
          }
        }
      } while (shifted && passes < maxPasses);
    }
    return resolvedPositions;
  }

  Set<String> _getNodeGroup(
    String nodeId,
    int level,
    Map<String, Offset> positions,
    Map<String, List<String>> spouseMap,
  ) {
    final group = {nodeId};
    final potentialSpouses = spouseMap[nodeId] ?? [];
    for (final spouseId in potentialSpouses) {
      if (positions.containsKey(spouseId) &&
          positions[spouseId]!.dy == positions[nodeId]!.dy &&
          !group.contains(spouseId)) {
        group.add(spouseId);
      }
    } // <- Добавляем недостающую скобку для закрытия цикла for
    return group;
  } // <- Конец функции _getNodeGroup
} // <- Закрывающая скобка для класса _InteractiveFamilyTreeState

class _TreeLayoutComputation {
  const _TreeLayoutComputation({
    required this.nodePositions,
    required this.connections,
    required this.treeSize,
  });

  final Map<String, Offset> nodePositions;
  final List<FamilyConnection> connections;
  final Size treeSize;
}

class _FamilyClusterOverlay {
  const _FamilyClusterOverlay({
    required this.rect,
    required this.label,
    required this.color,
  });

  final Rect rect;
  final String label;
  final Color color;
}

class _SpouseGroup {
  const _SpouseGroup({required this.memberIds});

  final List<String> memberIds;
}

class _TreeLayoutEngine {
  _TreeLayoutEngine({
    required this.peopleData,
    required this.relations,
  });

  final List<Map<String, dynamic>> peopleData;
  final List<FamilyRelation> relations;

  _TreeLayoutComputation compute() {
    final peopleById = <String, FamilyPerson>{
      for (final entry in peopleData)
        (entry['person'] as FamilyPerson).id: entry['person'] as FamilyPerson,
    };
    if (peopleById.isEmpty) {
      return const _TreeLayoutComputation(
        nodePositions: <String, Offset>{},
        connections: <FamilyConnection>[],
        treeSize: Size.zero,
      );
    }

    final parentToChildren = <String, Set<String>>{};
    final childToParents = <String, Set<String>>{};
    final spousesByPerson = <String, Set<String>>{};
    final siblingsByPerson = <String, Set<String>>{};
    final adjacency = <String, Set<String>>{
      for (final id in peopleById.keys) id: <String>{},
    };

    for (final relation in relations) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null && childId != null) {
        parentToChildren.putIfAbsent(parentId, () => <String>{}).add(childId);
        childToParents.putIfAbsent(childId, () => <String>{}).add(parentId);
        adjacency[parentId]!.add(childId);
        adjacency[childId]!.add(parentId);
      } else if (_isSpouseRelation(relation)) {
        spousesByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        spousesByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
        adjacency[relation.person1Id]!.add(relation.person2Id);
        adjacency[relation.person2Id]!.add(relation.person1Id);
      } else if (_isSiblingRelation(relation)) {
        siblingsByPerson
            .putIfAbsent(relation.person1Id, () => <String>{})
            .add(relation.person2Id);
        siblingsByPerson
            .putIfAbsent(relation.person2Id, () => <String>{})
            .add(relation.person1Id);
        adjacency[relation.person1Id]!.add(relation.person2Id);
        adjacency[relation.person2Id]!.add(relation.person1Id);
      }
    }

    final components = _buildComponents(adjacency, peopleById);
    final nodePositions = <String, Offset>{};
    var offsetX = InteractiveFamilyTree.contentInsetHorizontal +
        InteractiveFamilyTree.nodeWidth / 2 +
        InteractiveFamilyTree.siblingSeparation;
    var maxBottomY = 0.0;

    for (final component in components) {
      final levels = _assignLevels(
        component: component,
        peopleById: peopleById,
        childToParents: childToParents,
        parentToChildren: parentToChildren,
        spousesByPerson: spousesByPerson,
        siblingsByPerson: siblingsByPerson,
      );
      final groupsByLevel = _buildGroupsByLevel(
        component: component,
        levels: levels,
        spousesByPerson: spousesByPerson,
        siblingsByPerson: siblingsByPerson,
        peopleById: peopleById,
      );

      final componentPositions = <String, Offset>{};
      final levelOrder = groupsByLevel.keys.toList()..sort();
      for (final level in levelOrder) {
        final groups = groupsByLevel[level] ?? const <_SpouseGroup>[];
        var currentLeft = offsetX;
        for (final group in groups) {
          final requestedCenter = _desiredCenterForGroup(
            group: group,
            positions: componentPositions,
            childToParents: childToParents,
            parentToChildren: parentToChildren,
            siblingsByPerson: siblingsByPerson,
          );
          final groupWidth = _groupWidth(group.memberIds.length);
          final requestedLeft = requestedCenter == null
              ? currentLeft
              : requestedCenter - groupWidth / 2;
          final left = max(currentLeft, requestedLeft);
          final y = InteractiveFamilyTree.contentInsetTop +
              InteractiveFamilyTree.nodeHeight / 2 +
              level *
                  (InteractiveFamilyTree.nodeHeight +
                      InteractiveFamilyTree.levelSeparation);
          for (var index = 0; index < group.memberIds.length; index++) {
            final personId = group.memberIds[index];
            final x = left +
                InteractiveFamilyTree.nodeWidth / 2 +
                index *
                    (InteractiveFamilyTree.nodeWidth +
                        InteractiveFamilyTree.spouseSeparation);
            componentPositions[personId] = Offset(x, y);
            maxBottomY = max(
              maxBottomY,
              y + InteractiveFamilyTree.nodeHeight / 2,
            );
          }
          currentLeft =
              left + groupWidth + InteractiveFamilyTree.siblingSeparation;
        }
      }

      _centerParents(componentPositions, groupsByLevel, parentToChildren);
      _normalizeGroups(
        componentPositions,
        groupsByLevel,
        componentStartX: offsetX,
      );
      nodePositions.addAll(componentPositions);

      var rightEdge = offsetX;
      for (final position in componentPositions.values) {
        rightEdge = max(
          rightEdge,
          position.dx + InteractiveFamilyTree.nodeWidth / 2,
        );
      }
      offsetX = rightEdge + InteractiveFamilyTree.siblingSeparation * 3;
    }

    final connections = _buildConnections(relations, nodePositions);
    final maxRight = nodePositions.values.fold<double>(
      InteractiveFamilyTree.nodeWidth,
      (value, position) =>
          max(value, position.dx + InteractiveFamilyTree.nodeWidth / 2),
    );

    return _TreeLayoutComputation(
      nodePositions: nodePositions,
      connections: connections,
      treeSize: Size(
        max(
          maxRight + InteractiveFamilyTree.contentInsetHorizontal,
          300,
        ),
        max(
          maxBottomY + InteractiveFamilyTree.contentInsetBottom,
          300,
        ),
      ),
    );
  }

  List<Set<String>> _buildComponents(
    Map<String, Set<String>> adjacency,
    Map<String, FamilyPerson> peopleById,
  ) {
    final components = <Set<String>>[];
    final visited = <String>{};
    final ids = peopleById.keys.toList()
      ..sort((a, b) => _comparePersons(peopleById[a]!, peopleById[b]!));
    for (final id in ids) {
      if (!visited.add(id)) {
        continue;
      }
      final component = <String>{id};
      final queue = <String>[id];
      while (queue.isNotEmpty) {
        final currentId = queue.removeAt(0);
        for (final neighbour in adjacency[currentId] ?? const <String>{}) {
          if (visited.add(neighbour)) {
            component.add(neighbour);
            queue.add(neighbour);
          }
        }
      }
      components.add(component);
    }
    return components;
  }

  Map<String, int> _assignLevels({
    required Set<String> component,
    required Map<String, FamilyPerson> peopleById,
    required Map<String, Set<String>> childToParents,
    required Map<String, Set<String>> parentToChildren,
    required Map<String, Set<String>> spousesByPerson,
    required Map<String, Set<String>> siblingsByPerson,
  }) {
    final levels = <String, int>{};
    final roots = component
        .where(
          (id) => (childToParents[id] ?? const <String>{})
              .where(component.contains)
              .isEmpty,
        )
        .toList()
      ..sort((a, b) => _comparePersons(peopleById[a]!, peopleById[b]!));
    final queue = <String>[...(roots.isNotEmpty ? roots : component)];

    while (queue.isNotEmpty) {
      final currentId = queue.removeAt(0);
      final currentLevel = levels[currentId] ?? 0;
      levels[currentId] = currentLevel;

      for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
        if (!component.contains(spouseId)) {
          continue;
        }
        final existing = levels[spouseId];
        if (existing == null || existing != currentLevel) {
          levels[spouseId] = currentLevel;
          queue.add(spouseId);
        }
      }

      for (final childId in parentToChildren[currentId] ?? const <String>{}) {
        if (!component.contains(childId)) {
          continue;
        }
        final childLevel = currentLevel + 1;
        final existing = levels[childId];
        if (existing == null || childLevel > existing) {
          levels[childId] = childLevel;
          queue.add(childId);
        }
      }

      for (final siblingId in siblingsByPerson[currentId] ?? const <String>{}) {
        if (!component.contains(siblingId)) {
          continue;
        }
        final existing = levels[siblingId];
        if (existing == null || existing != currentLevel) {
          levels[siblingId] = currentLevel;
          queue.add(siblingId);
        }
      }
    }

    for (final id in component) {
      levels.putIfAbsent(id, () {
        final parentLevels = (childToParents[id] ?? const <String>{})
            .where(component.contains)
            .map((parentId) => levels[parentId])
            .whereType<int>()
            .toList();
        return parentLevels.isEmpty ? 0 : parentLevels.reduce(max) + 1;
      });
    }

    final minLevel = levels.values.reduce(min);
    if (minLevel != 0) {
      for (final entry in levels.entries.toList()) {
        levels[entry.key] = entry.value - minLevel;
      }
    }
    return levels;
  }

  Map<int, List<_SpouseGroup>> _buildGroupsByLevel({
    required Set<String> component,
    required Map<String, int> levels,
    required Map<String, Set<String>> spousesByPerson,
    required Map<String, Set<String>> siblingsByPerson,
    required Map<String, FamilyPerson> peopleById,
  }) {
    final groupsByLevel = <int, List<_SpouseGroup>>{};
    final grouped = <String>{};
    final ids = component.toList()
      ..sort((a, b) {
        final levelCompare = (levels[a] ?? 0).compareTo(levels[b] ?? 0);
        if (levelCompare != 0) {
          return levelCompare;
        }
        return _comparePersons(peopleById[a]!, peopleById[b]!);
      });

    for (final id in ids) {
      if (grouped.contains(id)) {
        continue;
      }
      final level = levels[id] ?? 0;
      final memberIds = <String>{id};
      final queue = <String>[id];
      while (queue.isNotEmpty) {
        final currentId = queue.removeAt(0);
        for (final spouseId in spousesByPerson[currentId] ?? const <String>{}) {
          if (!component.contains(spouseId) ||
              grouped.contains(spouseId) ||
              (levels[spouseId] ?? 0) != level) {
            continue;
          }
          if (memberIds.add(spouseId)) {
            queue.add(spouseId);
          }
        }
      }
      grouped.addAll(memberIds);
      final orderedIds = memberIds.toList()
        ..sort((a, b) => _comparePersons(peopleById[a]!, peopleById[b]!));
      groupsByLevel.putIfAbsent(level, () => <_SpouseGroup>[]).add(
            _SpouseGroup(memberIds: orderedIds),
          );
    }

    for (final groups in groupsByLevel.values) {
      groups.sort((a, b) => _comparePersons(
            peopleById[a.memberIds.first]!,
            peopleById[b.memberIds.first]!,
          ));
    }
    return groupsByLevel;
  }

  double? _desiredCenterForGroup({
    required _SpouseGroup group,
    required Map<String, Offset> positions,
    required Map<String, Set<String>> childToParents,
    required Map<String, Set<String>> parentToChildren,
    required Map<String, Set<String>> siblingsByPerson,
  }) {
    final referenceCenters = <double>[];
    for (final memberId in group.memberIds) {
      for (final parentId in childToParents[memberId] ?? const <String>{}) {
        final parentPosition = positions[parentId];
        if (parentPosition != null) {
          referenceCenters.add(parentPosition.dx);
        }
      }
      for (final siblingId in siblingsByPerson[memberId] ?? const <String>{}) {
        final siblingPosition = positions[siblingId];
        if (siblingPosition != null) {
          referenceCenters.add(siblingPosition.dx);
        }
      }
      for (final childId in parentToChildren[memberId] ?? const <String>{}) {
        final childPosition = positions[childId];
        if (childPosition != null) {
          referenceCenters.add(childPosition.dx);
        }
      }
    }
    if (referenceCenters.isEmpty) {
      return null;
    }
    return referenceCenters.reduce((a, b) => a + b) / referenceCenters.length;
  }

  void _centerParents(
    Map<String, Offset> positions,
    Map<int, List<_SpouseGroup>> groupsByLevel,
    Map<String, Set<String>> parentToChildren,
  ) {
    final levelOrder = groupsByLevel.keys.toList()
      ..sort((a, b) => b.compareTo(a));
    for (final level in levelOrder) {
      for (final group in groupsByLevel[level] ?? const <_SpouseGroup>[]) {
        final childCenters = <double>[];
        for (final memberId in group.memberIds) {
          for (final childId
              in parentToChildren[memberId] ?? const <String>{}) {
            final childPosition = positions[childId];
            if (childPosition != null) {
              childCenters.add(childPosition.dx);
            }
          }
        }
        if (childCenters.isEmpty) {
          continue;
        }
        final currentCenter = group.memberIds
                .map((memberId) => positions[memberId]!.dx)
                .reduce((a, b) => a + b) /
            group.memberIds.length;
        final childCenter =
            childCenters.reduce((a, b) => a + b) / childCenters.length;
        final shift = childCenter - currentCenter;
        for (final memberId in group.memberIds) {
          final current = positions[memberId]!;
          positions[memberId] = Offset(current.dx + shift, current.dy);
        }
      }
    }
  }

  void _normalizeGroups(
    Map<String, Offset> positions,
    Map<int, List<_SpouseGroup>> groupsByLevel, {
    required double componentStartX,
  }) {
    for (final entry in groupsByLevel.entries) {
      final groups = entry.value
        ..sort((a, b) {
          final aCenter = a.memberIds
                  .map((memberId) => positions[memberId]!.dx)
                  .reduce((x, y) => x + y) /
              a.memberIds.length;
          final bCenter = b.memberIds
                  .map((memberId) => positions[memberId]!.dx)
                  .reduce((x, y) => x + y) /
              b.memberIds.length;
          return aCenter.compareTo(bCenter);
        });

      double currentLeft = componentStartX;
      for (final group in groups) {
        final groupWidth = _groupWidth(group.memberIds.length);
        final currentCenter = group.memberIds
                .map((memberId) => positions[memberId]!.dx)
                .reduce((x, y) => x + y) /
            group.memberIds.length;
        final left = max(currentLeft, currentCenter - groupWidth / 2);
        for (var index = 0; index < group.memberIds.length; index++) {
          final memberId = group.memberIds[index];
          final current = positions[memberId]!;
          final x = left +
              InteractiveFamilyTree.nodeWidth / 2 +
              index *
                  (InteractiveFamilyTree.nodeWidth +
                      InteractiveFamilyTree.spouseSeparation);
          positions[memberId] = Offset(x, current.dy);
        }
        currentLeft =
            left + groupWidth + InteractiveFamilyTree.siblingSeparation;
      }
    }
  }

  List<FamilyConnection> _buildConnections(
    List<FamilyRelation> relations,
    Map<String, Offset> positions,
  ) {
    final connections = <FamilyConnection>[];
    final spousePairs = <String>{};

    for (final relation in relations) {
      final parentId = _parentIdFromRelation(relation);
      final childId = _childIdFromRelation(relation);
      if (parentId != null &&
          childId != null &&
          positions.containsKey(parentId) &&
          positions.containsKey(childId)) {
        connections.add(
          FamilyConnection(
            fromId: parentId,
            toId: childId,
            type: RelationType.parent,
          ),
        );
        continue;
      }
      if (_isSpouseRelation(relation) &&
          positions.containsKey(relation.person1Id) &&
          positions.containsKey(relation.person2Id)) {
        final pair = [relation.person1Id, relation.person2Id]..sort();
        final pairKey = pair.join('::');
        if (spousePairs.add(pairKey)) {
          connections.add(
            FamilyConnection(
              fromId: pair.first,
              toId: pair.last,
              type: RelationType.spouse,
            ),
          );
        }
      }
    }
    return connections;
  }

  bool _isSpouseRelation(FamilyRelation relation) {
    return relation.relation1to2 == RelationType.spouse ||
        relation.relation2to1 == RelationType.spouse ||
        relation.relation1to2 == RelationType.partner ||
        relation.relation2to1 == RelationType.partner;
  }

  bool _isSiblingRelation(FamilyRelation relation) {
    return relation.relation1to2 == RelationType.sibling ||
        relation.relation2to1 == RelationType.sibling;
  }

  String? _parentIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person1Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person2Id;
    }
    return null;
  }

  String? _childIdFromRelation(FamilyRelation relation) {
    if (relation.relation1to2 == RelationType.parent ||
        relation.relation2to1 == RelationType.child) {
      return relation.person2Id;
    }
    if (relation.relation2to1 == RelationType.parent ||
        relation.relation1to2 == RelationType.child) {
      return relation.person1Id;
    }
    return null;
  }

  int _comparePersons(FamilyPerson a, FamilyPerson b) {
    final nameCompare = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (nameCompare != 0) {
      return nameCompare;
    }
    return a.id.compareTo(b.id);
  }

  double _groupWidth(int membersCount) {
    return membersCount * InteractiveFamilyTree.nodeWidth +
        (membersCount - 1) * InteractiveFamilyTree.spouseSeparation;
  }
}

// Класс для отрисовки линий связей - ВНЕ класса _InteractiveFamilyTreeState
class FamilyTreePainter extends CustomPainter {
  final Map<String, Offset> nodePositions; // Центры узлов
  final List<FamilyConnection> connections;
  final Paint spouseLinePaint;
  final Paint familyLinePaint;
  final Paint junctionPaint;

  FamilyTreePainter(this.nodePositions, this.connections)
      : spouseLinePaint = Paint()
          ..color = Colors.grey.shade500
          ..strokeWidth = 1.5
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke,
        familyLinePaint = Paint()
          ..color = Colors.grey.shade700
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true
          ..style = PaintingStyle.stroke,
        junctionPaint = Paint()
          ..color = Colors.grey.shade500
          ..isAntiAlias = true
          ..style = PaintingStyle.fill;

  @override
  void paint(Canvas canvas, Size size) {
    final familyUnits = <String, _PaintFamilyUnit>{};
    final paintedFamilyKeys = <String>{};

    for (final connection in connections) {
      final startNodePos = nodePositions[connection.fromId];
      final endNodePos = nodePositions[connection.toId];
      if (startNodePos == null || endNodePos == null) {
        continue;
      }

      if (connection.type == RelationType.spouse) {
        _drawSpouseLine(canvas, startNodePos, endNodePos);
      } else if (connection.type == RelationType.parent) {
        final key = connection.toId;
        final unit = familyUnits.putIfAbsent(
          key,
          () => _PaintFamilyUnit(childId: connection.toId),
        );
        unit.parentIds.add(connection.fromId);
      }
    }

    for (final unit in familyUnits.values) {
      final parentIds = unit.parentIds.toList()
        ..sort((a, b) => nodePositions[a]!.dx.compareTo(nodePositions[b]!.dx));
      final childIds = <String>[unit.childId];
      final groupedKey = parentIds.join('::');
      final siblings = familyUnits.values
          .where((candidate) =>
              candidate.childId != unit.childId &&
              candidate.parentIds.length == unit.parentIds.length &&
              candidate.parentIds.toSet().containsAll(parentIds))
          .map((candidate) => candidate.childId)
          .toList()
        ..sort((a, b) => nodePositions[a]!.dx.compareTo(nodePositions[b]!.dx));
      childIds.addAll(siblings.where((id) => !childIds.contains(id)));

      if (groupedKey.isEmpty) {
        continue;
      }
      if (paintedFamilyKeys.add(groupedKey)) {
        _drawFamilyUnit(canvas, parentIds: parentIds, childIds: childIds);
      }
    }
  }

  // Метод для рисования линии между супругами
  void _drawSpouseLine(Canvas canvas, Offset pos1, Offset pos2) {
    // Просто рисуем горизонтальную линию между боковыми центрами
    final y = pos1.dy; // Супруги на одном уровне
    final x1 = pos1.dx +
        (pos1.dx < pos2.dx
            ? InteractiveFamilyTree.nodeWidth / 2
            : -InteractiveFamilyTree.nodeWidth / 2);
    final x2 = pos2.dx +
        (pos1.dx < pos2.dx
            ? -InteractiveFamilyTree.nodeWidth / 2
            : InteractiveFamilyTree.nodeWidth / 2);
    canvas.drawLine(Offset(x1, y), Offset(x2, y), spouseLinePaint);
  }

  void _drawFamilyUnit(
    Canvas canvas, {
    required List<String> parentIds,
    required List<String> childIds,
  }) {
    final parentAnchors = parentIds
        .map((id) => nodePositions[id])
        .whereType<Offset>()
        .map(
          (offset) => Offset(
            offset.dx,
            offset.dy + InteractiveFamilyTree.nodeHeight / 2,
          ),
        )
        .toList();
    final childAnchors = childIds
        .map((id) => nodePositions[id])
        .whereType<Offset>()
        .map(
          (offset) => Offset(
            offset.dx,
            offset.dy - InteractiveFamilyTree.nodeHeight / 2,
          ),
        )
        .toList();

    if (parentAnchors.isEmpty || childAnchors.isEmpty) {
      return;
    }

    final parentBarY =
        parentAnchors.map((anchor) => anchor.dy).reduce(max) + 18;
    final familyCenterX =
        parentAnchors.map((anchor) => anchor.dx).reduce((a, b) => a + b) /
            parentAnchors.length;

    if (parentAnchors.length > 1) {
      final minParentX = parentAnchors.map((anchor) => anchor.dx).reduce(min);
      final maxParentX = parentAnchors.map((anchor) => anchor.dx).reduce(max);
      for (final anchor in parentAnchors) {
        canvas.drawLine(
          anchor,
          Offset(anchor.dx, parentBarY),
          familyLinePaint,
        );
      }
      canvas.drawLine(
        Offset(minParentX, parentBarY),
        Offset(maxParentX, parentBarY),
        familyLinePaint,
      );
      _drawJunction(canvas, Offset(familyCenterX, parentBarY));
    } else {
      canvas.drawLine(
        parentAnchors.first,
        Offset(familyCenterX, parentBarY),
        familyLinePaint,
      );
      _drawJunction(canvas, Offset(familyCenterX, parentBarY));
    }

    final downwardChildren =
        childAnchors.where((anchor) => anchor.dy >= parentBarY).toList();
    final upwardChildren =
        childAnchors.where((anchor) => anchor.dy < parentBarY).toList();

    if (downwardChildren.isNotEmpty) {
      _drawChildAnchorGroup(
        canvas,
        familyCenterX: familyCenterX,
        parentBarY: parentBarY,
        anchors: downwardChildren,
        branchY: downwardChildren.map((anchor) => anchor.dy).reduce(min) - 18,
      );
    }

    if (upwardChildren.isNotEmpty) {
      _drawChildAnchorGroup(
        canvas,
        familyCenterX: familyCenterX,
        parentBarY: parentBarY,
        anchors: upwardChildren,
        branchY: upwardChildren.map((anchor) => anchor.dy).reduce(max) + 18,
      );
    }
  }

  void _drawChildAnchorGroup(
    Canvas canvas, {
    required double familyCenterX,
    required double parentBarY,
    required List<Offset> anchors,
    required double branchY,
  }) {
    if (anchors.isEmpty) {
      return;
    }

    if ((branchY - parentBarY).abs() > 0.1) {
      canvas.drawLine(
        Offset(familyCenterX, parentBarY),
        Offset(familyCenterX, branchY),
        familyLinePaint,
      );
    }

    final minChildX = anchors.map((anchor) => anchor.dx).reduce(min);
    final maxChildX = anchors.map((anchor) => anchor.dx).reduce(max);
    if ((maxChildX - minChildX).abs() > 0.1) {
      canvas.drawLine(
        Offset(minChildX, branchY),
        Offset(maxChildX, branchY),
        familyLinePaint,
      );
    }
    _drawJunction(canvas, Offset(familyCenterX, branchY));

    for (final anchor in anchors) {
      if ((anchor.dx - familyCenterX).abs() > 0.1) {
        canvas.drawLine(
          Offset(anchor.dx, branchY),
          anchor,
          familyLinePaint,
        );
      } else {
        canvas.drawLine(
          Offset(familyCenterX, branchY),
          anchor,
          familyLinePaint,
        );
      }
      _drawJunction(canvas, Offset(anchor.dx, branchY));
    }
  }

  void _drawJunction(Canvas canvas, Offset center) {
    canvas.drawCircle(center, 4.0, junctionPaint);
  }

  @override
  bool shouldRepaint(covariant FamilyTreePainter oldDelegate) {
    // Перерисовываем, если изменились позиции узлов или сами связи
    return oldDelegate.nodePositions != nodePositions ||
        oldDelegate.connections != connections;
  }
} // <- Скобка закрывает класс FamilyTreePainter

class _PaintFamilyUnit {
  _PaintFamilyUnit({required this.childId});

  final String childId;
  final Set<String> parentIds = <String>{};
}
