import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/tree_graph_snapshot.dart';
import 'package:rodnya/widgets/interactive_family_tree.dart';

final Uint8List _transparentImageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9WlH0X8AAAAASUVORK5CYII=',
);

class _TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return _TestHttpClient();
  }
}

class _TestHttpClient implements HttpClient {
  bool _autoUncompress = true;

  @override
  bool get autoUncompress => _autoUncompress;

  @override
  set autoUncompress(bool value) {
    _autoUncompress = value;
  }

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _TestHttpClientRequest();

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _TestHttpClientRequest();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpClientRequest implements HttpClientRequest {
  @override
  HttpHeaders headers = _TestHttpHeaders();

  @override
  bool followRedirects = false;

  @override
  int maxRedirects = 5;

  @override
  Future<HttpClientResponse> close() async => _TestHttpClientResponse();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  final HttpHeaders headers = _TestHttpHeaders();

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _transparentImageBytes.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  bool get persistentConnection => false;

  @override
  bool get isRedirect => false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_transparentImageBytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TestHttpHeaders implements HttpHeaders {
  @override
  void add(
    String name,
    Object value, {
    bool preserveHeaderCase = false,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final originalHttpOverrides = HttpOverrides.current;

  setUpAll(() {
    HttpOverrides.global = _TestHttpOverrides();
  });

  tearDownAll(() {
    HttpOverrides.global = originalHttpOverrides;
  });

  testWidgets('InteractiveFamilyTree does not introduce a nested Scaffold',
      (tester) async {
    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      userId: 'user-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {
                'person': person,
                'userProfile': null,
              },
            ],
            relations: <FamilyRelation>[],
            onPersonTap: (_) {},
            isEditMode: false,
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            currentUserId: 'user-1',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byType(Scaffold), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    final viewport = tester.widget<Stack>(
      find.byKey(const Key('interactive-family-tree-viewport')),
    );
    expect(viewport.clipBehavior, Clip.hardEdge);
    expect(
      find.byKey(const Key('interactive-family-tree-canvas-clip')),
      findsOneWidget,
    );
    // Card now splits the name: 'Иван' (first name, Lora) + 'Петров' (last
    // name, Manrope smaller). Assert both pieces render.
    expect(find.text('Иван'), findsOneWidget);
    expect(find.text('Петров'), findsOneWidget);
    // Control dock is now collapsed by default — tap the chevron to
    // expand it before asserting individual zoom buttons render.
    await tester.tap(find.byTooltip('Настройки вида'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Вписать дерево'), findsOneWidget);
    expect(find.byTooltip('Ко мне'), findsOneWidget);
    expect(find.byTooltip('Увеличить'), findsOneWidget);
    expect(find.byTooltip('Уменьшить'), findsOneWidget);
    expect(find.text('Это вы'), findsOneWidget);
  });

  testWidgets('InteractiveFamilyTree shows inline edit actions in edit mode',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.reset();
    });

    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      userId: 'user-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {
                'person': person,
                'userProfile': null,
              },
            ],
            relations: <FamilyRelation>[],
            onPersonTap: (_) {},
            isEditMode: true,
            selectedEditPersonId: person.id,
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: false,
            onAddSelfTapWithType: (_, __) async {},
            currentUserId: 'user-2',
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Без фото'), findsOneWidget);
    expect(find.text('Родитель'), findsOneWidget);
    expect(find.text('Супруг'), findsOneWidget);
    expect(find.text('Ребёнок'), findsOneWidget);
    expect(find.text('Сиблинг'), findsOneWidget);
    expect(find.text('Карточка'), findsOneWidget);
    expect(find.text('Фото'), findsOneWidget);
    expect(find.text('История'), findsOneWidget);
    expect(find.text('Ещё'), findsOneWidget);
    expect(
        find.bySemanticsLabel('tree-inspector-open-gallery'), findsOneWidget);
    expect(
        find.bySemanticsLabel('tree-inspector-open-history'), findsOneWidget);
    expect(
        find.bySemanticsLabel('tree-inspector-more-actions'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
      'InteractiveFamilyTree bottom sheet exposes gallery and history quick actions',
      (tester) async {
    final semantics = tester.ensureSemantics();
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.reset();
    });

    var historyOpened = false;
    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      photoUrl: 'https://example.com/photo-1.jpg',
      photoGallery: const [
        {
          'id': 'media-1',
          'url': 'https://example.com/photo-1.jpg',
          'isPrimary': true,
        },
        {
          'id': 'media-2',
          'url': 'https://example.com/photo-2.jpg',
          'isPrimary': false,
        },
      ],
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {
                'person': person,
                'userProfile': null,
              },
            ],
            relations: <FamilyRelation>[],
            onPersonTap: (_) {},
            isEditMode: true,
            selectedEditPersonId: person.id,
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            currentUserId: 'user-1',
            onOpenPersonHistory: (_) {
              historyOpened = true;
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    tester
        .widget<ActionChip>(find.widgetWithText(ActionChip, 'Ещё'))
        .onPressed!
        .call();
    await tester.pumpAndSettle();

    expect(find.text('Быстрые переходы'), findsOneWidget);
    expect(find.text('2 фото'), findsWidgets);
    expect(find.text('Основное фото есть'), findsWidgets);
    expect(find.text('Открыть фото'), findsOneWidget);
    expect(find.text('История изменений'), findsOneWidget);
    expect(find.bySemanticsLabel('tree-sheet-open-gallery'), findsOneWidget);
    expect(find.bySemanticsLabel('tree-sheet-open-history'), findsOneWidget);

    tester
        .widget<ListTile>(find.widgetWithText(ListTile, 'История изменений'))
        .onTap!
        .call();
    await tester.pumpAndSettle();

    expect(historyOpened, isTrue);
    semantics.dispose();
  });

  testWidgets(
      'InteractiveFamilyTree touch long press opens direct relative add sheet',
      (tester) async {
    RelationType? capturedRelationType;
    FamilyPerson? capturedPerson;

    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {
                'person': person,
                'userProfile': null,
              },
            ],
            relations: const <FamilyRelation>[],
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (targetPerson, relationType) {
              capturedPerson = targetPerson;
              capturedRelationType = relationType;
            },
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            onShowRelationPath: (_) {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey<String>('tree-node-person-1')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Добавить к карточке'), findsOneWidget);
    expect(find.text('Добавить ребёнка'), findsOneWidget);

    await tester.tap(find.text('Добавить ребёнка'));
    await tester.pumpAndSettle();

    expect(capturedPerson?.id, person.id);
    expect(capturedRelationType, RelationType.child);
  });

  testWidgets(
      'InteractiveFamilyTree shows hover plus button for desktop add flow',
      (tester) async {
    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {
                'person': person,
                'userProfile': null,
              },
            ],
            relations: const <FamilyRelation>[],
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('tree-node-add-relative-person-1')),
      findsNothing,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer();
    await gesture.moveTo(
      tester
          .getCenter(find.byKey(const ValueKey<String>('tree-node-person-1'))),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('tree-node-add-relative-person-1')),
      findsOneWidget,
    );

    await gesture.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey<String>('tree-node-add-relative-person-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('tree-node-add-relative-person-1')),
      findsOneWidget,
    );
  });

  testWidgets(
      'InteractiveFamilyTree keeps canvas minimal without branch overlays',
      (tester) async {
    final father = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Иванов Иван',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final mother = FamilyPerson(
      id: 'person-2',
      treeId: 'tree-1',
      name: 'Иванова Мария',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final child = FamilyPerson(
      id: 'person-3',
      treeId: 'tree-1',
      name: 'Иванов Пётр',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final relations = [
      FamilyRelation(
        id: 'relation-1',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: mother.id,
        relation1to2: RelationType.spouse,
        relation2to1: RelationType.spouse,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'relation-2',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: child.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': father, 'userProfile': null},
              {'person': mother, 'userProfile': null},
              {'person': child, 'userProfile': null},
            ],
            relations: relations,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // Card splits name: lname (first word) + fname (rest). For "Иванов Иван":
    // 'Иванов' big (Lora), 'Иван' small (Manrope). Assert by first-word
    // segments which are unique within this fixture.
    expect(find.text('Иванов'), findsNWidgets(2)); // Иванов Иван + Иванов Пётр
    expect(find.text('Иванова'), findsOneWidget);
    expect(find.text('Иван'), findsOneWidget);
    expect(find.text('Мария'), findsOneWidget);
    expect(find.text('Пётр'), findsOneWidget);
    expect(find.text('Ветка Иванов'), findsNothing);
  });

  testWidgets(
      'InteractiveFamilyTree keeps sibling-only relation in same visual band',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final father = FamilyPerson(
      id: 'father',
      treeId: 'tree-1',
      name: 'Иванов Иван',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final mother = FamilyPerson(
      id: 'mother',
      treeId: 'tree-1',
      name: 'Иванова Мария',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final anchorChild = FamilyPerson(
      id: 'anchor-child',
      treeId: 'tree-1',
      name: 'Иванов Пётр',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final siblingOnly = FamilyPerson(
      id: 'sibling-only',
      treeId: 'tree-1',
      name: 'Иванова Анна',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final relations = [
      FamilyRelation(
        id: 'relation-1',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: mother.id,
        relation1to2: RelationType.spouse,
        relation2to1: RelationType.spouse,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'relation-2',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: anchorChild.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'relation-3',
        treeId: 'tree-1',
        person1Id: anchorChild.id,
        person2Id: siblingOnly.id,
        relation1to2: RelationType.sibling,
        relation2to1: RelationType.sibling,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': father, 'userProfile': null},
              {'person': mother, 'userProfile': null},
              {'person': anchorChild, 'userProfile': null},
              {'person': siblingOnly, 'userProfile': null},
            ],
            relations: relations,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final anchorOffset = painter.nodePositions[anchorChild.id]!;
    final siblingOffset = painter.nodePositions[siblingOnly.id]!;

    expect((anchorOffset.dy - siblingOffset.dy).abs(), lessThan(0.1));
    expect((anchorOffset.dx - siblingOffset.dx).abs(), lessThan(260));
  });

  testWidgets(
      'InteractiveFamilyTree keeps spouse on the same generation as a person with parents',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final father = FamilyPerson(
      id: 'father',
      treeId: 'tree-1',
      name: 'Отец',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final mother = FamilyPerson(
      id: 'mother',
      treeId: 'tree-1',
      name: 'Мать',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final person = FamilyPerson(
      id: 'person',
      treeId: 'tree-1',
      name: 'Иван',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final spouse = FamilyPerson(
      id: 'spouse',
      treeId: 'tree-1',
      name: 'Елена',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final child = FamilyPerson(
      id: 'child',
      treeId: 'tree-1',
      name: 'Ребёнок',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final relations = [
      FamilyRelation(
        id: 'p1',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: person.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'p2',
        treeId: 'tree-1',
        person1Id: mother.id,
        person2Id: person.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'sp',
        treeId: 'tree-1',
        person1Id: spouse.id,
        person2Id: person.id,
        relation1to2: RelationType.spouse,
        relation2to1: RelationType.spouse,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'c1',
        treeId: 'tree-1',
        person1Id: person.id,
        person2Id: child.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'c2',
        treeId: 'tree-1',
        person1Id: spouse.id,
        person2Id: child.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': father, 'userProfile': null},
              {'person': mother, 'userProfile': null},
              {'person': person, 'userProfile': null},
              {'person': spouse, 'userProfile': null},
              {'person': child, 'userProfile': null},
            ],
            relations: relations,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final personOffset = painter.nodePositions[person.id]!;
    final spouseOffset = painter.nodePositions[spouse.id]!;
    final childOffset = painter.nodePositions[child.id]!;

    expect((personOffset.dy - spouseOffset.dy).abs(), lessThan(0.1));
    expect(childOffset.dy, greaterThan(personOffset.dy));
  });

  testWidgets(
      'InteractiveFamilyTree does not let graph generation rows split spouses',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final grandpa = FamilyPerson(
      id: 'grandpa',
      treeId: 'tree-1',
      name: 'Дед',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final grandma = FamilyPerson(
      id: 'grandma',
      treeId: 'tree-1',
      name: 'Бабушка',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final father = FamilyPerson(
      id: 'father',
      treeId: 'tree-1',
      name: 'Отец',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final mother = FamilyPerson(
      id: 'mother',
      treeId: 'tree-1',
      name: 'Мать',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final child = FamilyPerson(
      id: 'child',
      treeId: 'tree-1',
      name: 'Ребёнок',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final relations = [
      FamilyRelation(
        id: 'grand-union',
        treeId: 'tree-1',
        person1Id: grandpa.id,
        person2Id: grandma.id,
        relation1to2: RelationType.spouse,
        relation2to1: RelationType.spouse,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'grand-parent-1',
        treeId: 'tree-1',
        person1Id: grandpa.id,
        person2Id: father.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'grand-parent-2',
        treeId: 'tree-1',
        person1Id: grandma.id,
        person2Id: father.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'parents-union',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: mother.id,
        relation1to2: RelationType.spouse,
        relation2to1: RelationType.spouse,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'child-parent-1',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: child.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'child-parent-2',
        treeId: 'tree-1',
        person1Id: mother.id,
        person2Id: child.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
    ];

    final snapshot = TreeGraphSnapshot(
      treeId: 'tree-1',
      viewerPersonId: child.id,
      people: [grandpa, grandma, father, mother, child],
      relations: relations,
      familyUnits: const <TreeGraphFamilyUnit>[],
      viewerDescriptors: const <TreeGraphViewerDescriptor>[],
      branchBlocks: const <TreeGraphBranchBlock>[],
      generationRows: const <TreeGraphGenerationRow>[
        TreeGraphGenerationRow(
          row: 0,
          label: 'Старшее поколение',
          personIds: ['grandpa', 'grandma'],
          familyUnitIds: <String>[],
        ),
        TreeGraphGenerationRow(
          row: 1,
          label: 'Отец',
          personIds: ['father'],
          familyUnitIds: <String>[],
        ),
        TreeGraphGenerationRow(
          row: 2,
          label: 'Мать',
          personIds: ['mother'],
          familyUnitIds: <String>[],
        ),
        TreeGraphGenerationRow(
          row: 3,
          label: 'Младшее поколение',
          personIds: ['child'],
          familyUnitIds: <String>[],
        ),
      ],
      warnings: const <TreeGraphWarning>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': grandpa, 'userProfile': null},
              {'person': grandma, 'userProfile': null},
              {'person': father, 'userProfile': null},
              {'person': mother, 'userProfile': null},
              {'person': child, 'userProfile': null},
            ],
            relations: relations,
            graphSnapshot: snapshot,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final fatherOffset = painter.nodePositions[father.id]!;
    final motherOffset = painter.nodePositions[mother.id]!;
    final childOffset = painter.nodePositions[child.id]!;

    expect((fatherOffset.dy - motherOffset.dy).abs(), lessThan(0.1));
    expect(childOffset.dy, greaterThan(fatherOffset.dy));
  });

  testWidgets(
      'InteractiveFamilyTree keeps a divorced couple adjacent when an in-law '
      'parent shares their row (no unrelated node between them)',
      (tester) async {
    // Repro for the reported bug: Галина÷Владимир are a DIVORCED couple with
    // children Мария + Николай. Екатерина married Николай (married-in), and
    // her father Марат gets pulled into the grandparent row through that
    // marriage — landing BETWEEN Галина and Владимир, so Мария's parent
    // connector crosses Екатерина's drop line («Екатерина соприкасается
    // линией с Владимиром»). The divorced couple must stay adjacent.
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    FamilyPerson p(String id, String name, Gender gender) => FamilyPerson(
          id: id,
          treeId: 'tree-1',
          name: name,
          gender: gender,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
    final gfather = p('gfather', 'Дед', Gender.male);
    final gmother = p('gmother', 'Баба', Gender.female);
    final galina = p('galina', 'Галина', Gender.female);
    final vladimir = p('vladimir', 'Владимир', Gender.male);
    final marat = p('marat', 'Марат', Gender.male);
    final maria = p('maria', 'Мария', Gender.female);
    final nikolai = p('nikolai', 'Николай', Gender.male);
    final ekaterina = p('ekaterina', 'Екатерина', Gender.female);
    final people = [
      gfather,
      gmother,
      galina,
      vladimir,
      marat,
      maria,
      nikolai,
      ekaterina,
    ];

    FamilyRelation rel(
      String id,
      String a,
      String b,
      RelationType ab,
      RelationType ba, {
      String? unionStatus,
    }) =>
        FamilyRelation(
          id: id,
          treeId: 'tree-1',
          person1Id: a,
          person2Id: b,
          relation1to2: ab,
          relation2to1: ba,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
          unionStatus: unionStatus,
        );
    final relations = [
      rel('gf', 'gfather', 'galina', RelationType.parent, RelationType.child),
      rel('gm', 'gmother', 'galina', RelationType.parent, RelationType.child),
      // Галина's CURRENT union (remarried) — pulls Марат adjacent.
      rel('marat-galina', 'marat', 'galina', RelationType.spouse,
          RelationType.spouse,
          unionStatus: 'current'),
      // Галина's PAST union (divorced) — shared child Мария.
      rel('vladimir-galina', 'vladimir', 'galina', RelationType.spouse,
          RelationType.spouse,
          unionStatus: 'past'),
      rel('g-maria', 'galina', 'maria', RelationType.parent,
          RelationType.child),
      rel('v-maria', 'vladimir', 'maria', RelationType.parent,
          RelationType.child),
      rel('m-ekat', 'marat', 'ekaterina', RelationType.parent,
          RelationType.child),
      rel('nik-maria', 'nikolai', 'maria', RelationType.spouse,
          RelationType.spouse,
          unionStatus: 'current'),
    ];

    final snapshot = TreeGraphSnapshot(
      treeId: 'tree-1',
      viewerPersonId: maria.id,
      people: people,
      relations: relations,
      familyUnits: const <TreeGraphFamilyUnit>[],
      viewerDescriptors: const <TreeGraphViewerDescriptor>[],
      branchBlocks: const <TreeGraphBranchBlock>[],
      generationRows: const <TreeGraphGenerationRow>[
        TreeGraphGenerationRow(
          row: 0,
          label: 'Деды',
          personIds: ['gfather', 'gmother'],
          familyUnitIds: <String>[],
        ),
        TreeGraphGenerationRow(
          row: 1,
          label: 'Старшие',
          personIds: ['galina', 'marat', 'vladimir'],
          familyUnitIds: <String>[],
        ),
        TreeGraphGenerationRow(
          row: 2,
          label: 'Дети',
          personIds: ['maria', 'nikolai', 'ekaterina'],
          familyUnitIds: <String>[],
        ),
      ],
      warnings: const <TreeGraphWarning>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              for (final person in people)
                {'person': person, 'userProfile': null},
            ],
            relations: relations,
            graphSnapshot: snapshot,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final galinaX = painter.nodePositions[galina.id]!.dx;
    final vladimirX = painter.nodePositions[vladimir.id]!.dx;
    final maratX = painter.nodePositions[marat.id]!.dx;

    // The divorced couple must stay contiguous: no unrelated node (Марат)
    // may sit horizontally between Галина and Владимир.
    final lo = galinaX < vladimirX ? galinaX : vladimirX;
    final hi = galinaX < vladimirX ? vladimirX : galinaX;
    expect(
      maratX < lo || maratX > hi,
      isTrue,
      reason: 'Марат ($maratX) splits the divorced couple '
          'Галина ($galinaX)–Владимир ($vladimirX)',
    );
  });

  testWidgets(
      'InteractiveFamilyTree places partners outside the sibling rail for child groups',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final father = FamilyPerson(
      id: 'father',
      treeId: 'tree-1',
      name: 'Отец',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final mother = FamilyPerson(
      id: 'mother',
      treeId: 'tree-1',
      name: 'Мать',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final leftChild = FamilyPerson(
      id: 'left-child',
      treeId: 'tree-1',
      name: 'Алексей',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final leftPartner = FamilyPerson(
      id: 'left-partner',
      treeId: 'tree-1',
      name: 'Анна',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final rightChild = FamilyPerson(
      id: 'right-child',
      treeId: 'tree-1',
      name: 'Виктор',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final rightPartner = FamilyPerson(
      id: 'right-partner',
      treeId: 'tree-1',
      name: 'Вера',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final relations = [
      FamilyRelation(
        id: 'parent-left-f',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: leftChild.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'parent-left-m',
        treeId: 'tree-1',
        person1Id: mother.id,
        person2Id: leftChild.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'parent-right-f',
        treeId: 'tree-1',
        person1Id: father.id,
        person2Id: rightChild.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'parent-right-m',
        treeId: 'tree-1',
        person1Id: mother.id,
        person2Id: rightChild.id,
        relation1to2: RelationType.parent,
        relation2to1: RelationType.child,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'spouse-left',
        treeId: 'tree-1',
        person1Id: leftChild.id,
        person2Id: leftPartner.id,
        relation1to2: RelationType.partner,
        relation2to1: RelationType.partner,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      FamilyRelation(
        id: 'spouse-right',
        treeId: 'tree-1',
        person1Id: rightChild.id,
        person2Id: rightPartner.id,
        relation1to2: RelationType.partner,
        relation2to1: RelationType.partner,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': father, 'userProfile': null},
              {'person': mother, 'userProfile': null},
              {'person': leftChild, 'userProfile': null},
              {'person': leftPartner, 'userProfile': null},
              {'person': rightChild, 'userProfile': null},
              {'person': rightPartner, 'userProfile': null},
            ],
            relations: relations,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final leftChildOffset = painter.nodePositions[leftChild.id]!;
    final leftPartnerOffset = painter.nodePositions[leftPartner.id]!;
    final rightChildOffset = painter.nodePositions[rightChild.id]!;
    final rightPartnerOffset = painter.nodePositions[rightPartner.id]!;

    expect(leftPartnerOffset.dx, lessThan(leftChildOffset.dx));
    expect(rightPartnerOffset.dx, greaterThan(rightChildOffset.dx));
    expect((leftPartnerOffset.dy - leftChildOffset.dy).abs(), lessThan(0.1));
    expect((rightPartnerOffset.dy - rightChildOffset.dy).abs(), lessThan(0.1));
  });

  testWidgets(
      'InteractiveFamilyTree keeps connected grandparents above the correct parent side',
      (tester) async {
    tester.view.physicalSize = const Size(1800, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    FamilyPerson person(String id, String name, Gender gender) => FamilyPerson(
          id: id,
          treeId: 'tree-1',
          name: name,
          gender: gender,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

    final gennady = person('gennady', 'Мочалкин Геннадий', Gender.male);
    final lydia = person('lydia', 'Мочалкина Лидия', Gender.female);
    final anatoly = person('anatoly', 'Кузнецов Анатолий', Gender.male);
    final valentina = person('valentina', 'Кузнецова Валентина', Gender.female);
    final natalia = person('natalia', 'Кузнецова Наталья', Gender.female);
    final andrey = person('andrey', 'Кузнецов Андрей', Gender.male);
    final evgeniy = person('evgeniy', 'Мочалкин Евгений', Gender.male);
    final artem = person('artem', 'Кузнецов Артем', Gender.male);

    FamilyRelation parentRelation(String id, String parentId, String childId) =>
        FamilyRelation(
          id: id,
          treeId: 'tree-1',
          person1Id: parentId,
          person2Id: childId,
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );

    FamilyRelation unionRelation(String id, String leftId, String rightId) =>
        FamilyRelation(
          id: id,
          treeId: 'tree-1',
          person1Id: leftId,
          person2Id: rightId,
          relation1to2: RelationType.spouse,
          relation2to1: RelationType.spouse,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': gennady, 'userProfile': null},
              {'person': lydia, 'userProfile': null},
              {'person': anatoly, 'userProfile': null},
              {'person': valentina, 'userProfile': null},
              {'person': natalia, 'userProfile': null},
              {'person': andrey, 'userProfile': null},
              {'person': evgeniy, 'userProfile': null},
              {'person': artem, 'userProfile': null},
            ],
            relations: [
              unionRelation('paternal-union', anatoly.id, valentina.id),
              unionRelation('maternal-union', gennady.id, lydia.id),
              unionRelation('parents-union', andrey.id, natalia.id),
              parentRelation('paternal-child-1', anatoly.id, andrey.id),
              parentRelation('paternal-child-2', valentina.id, andrey.id),
              parentRelation('maternal-child-1', gennady.id, natalia.id),
              parentRelation('maternal-child-2', lydia.id, natalia.id),
              parentRelation('maternal-child-3', gennady.id, evgeniy.id),
              parentRelation('maternal-child-4', lydia.id, evgeniy.id),
              parentRelation('child-1', andrey.id, artem.id),
              parentRelation('child-2', natalia.id, artem.id),
            ],
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;

    final gennadyOffset = painter.nodePositions[gennady.id]!;
    final lydiaOffset = painter.nodePositions[lydia.id]!;
    final anatolyOffset = painter.nodePositions[anatoly.id]!;
    final valentinaOffset = painter.nodePositions[valentina.id]!;
    final nataliaOffset = painter.nodePositions[natalia.id]!;
    final andreyOffset = painter.nodePositions[andrey.id]!;
    final evgeniyOffset = painter.nodePositions[evgeniy.id]!;
    final artemOffset = painter.nodePositions[artem.id]!;

    expect(gennadyOffset.dx, lessThan(lydiaOffset.dx));
    expect(anatolyOffset.dx, lessThan(valentinaOffset.dx));

    final paternalCenter = (anatolyOffset.dx + valentinaOffset.dx) / 2;
    final maternalCenter = (gennadyOffset.dx + lydiaOffset.dx) / 2;
    final parentsCenter = (andreyOffset.dx + nataliaOffset.dx) / 2;

    expect(
      (andreyOffset.dx - paternalCenter).abs(),
      lessThan((andreyOffset.dx - maternalCenter).abs()),
    );
    expect(
      (nataliaOffset.dx - maternalCenter).abs(),
      lessThan((nataliaOffset.dx - paternalCenter).abs()),
    );
    expect(
      (evgeniyOffset.dx - maternalCenter).abs(),
      lessThan((evgeniyOffset.dx - paternalCenter).abs()),
    );
    expect((artemOffset.dx - parentsCenter).abs(), lessThan(120));
  });

  testWidgets(
      'InteractiveFamilyTree keeps the current Kuznetsov tree partners on the right generations',
      (tester) async {
    tester.view.physicalSize = const Size(1900, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    FamilyPerson person(
      String id,
      String name,
      Gender gender, {
      DateTime? birthDate,
      bool isAlive = true,
    }) =>
        FamilyPerson(
          id: id,
          treeId: 'tree-1',
          name: name,
          gender: gender,
          birthDate: birthDate,
          isAlive: isAlive,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

    FamilyRelation parentRelation(String id, String parentId, String childId) =>
        FamilyRelation(
          id: id,
          treeId: 'tree-1',
          person1Id: parentId,
          person2Id: childId,
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );

    FamilyRelation unionRelation(
      String id,
      String leftId,
      String rightId, {
      RelationType relationType = RelationType.spouse,
    }) =>
        FamilyRelation(
          id: id,
          treeId: 'tree-1',
          person1Id: leftId,
          person2Id: rightId,
          relation1to2: relationType,
          relation2to1: relationType,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );

    final alexander =
        person('alexander', 'Супрунов Александр', Gender.male, isAlive: false);
    final maria = person('maria', 'Супрунова Мария', Gender.female);
    final gennady = person('gennady', 'Мочалкин Геннадий Иванович', Gender.male,
        isAlive: false);
    final lydia = person(
        'lydia', 'Мочалкина Лидия Александровна', Gender.female,
        isAlive: false);
    final anatoly = person(
      'anatoly',
      'Кузнецов Анатолий Степанович',
      Gender.male,
    );
    final valentina = person(
      'valentina',
      'Кузнецова Валентина',
      Gender.female,
    );
    final andrey = person(
      'andrey',
      'Кузнецов Андрей Анатольевич',
      Gender.male,
      birthDate: DateTime(1971, 12, 16),
    );
    final natalia = person(
      'natalia',
      'Кузнецова Наталья Геннадьевна',
      Gender.female,
      birthDate: DateTime(1974, 5, 25),
    );
    final evgeniy = person(
      'evgeniy',
      'Мочалкин Евгений Геннадьевич',
      Gender.male,
      birthDate: DateTime(1971, 5, 25),
    );
    final artem = person(
      'artem',
      'Кузнецов Артем Андреевич',
      Gender.male,
      birthDate: DateTime(2002, 9, 24),
    );
    final anastasia = person(
      'anastasia',
      'Шуфляк Анастасия Эдуардовна',
      Gender.female,
      birthDate: DateTime(2000, 5, 16),
    );
    final darya = person(
      'darya',
      'Понькина Дарья Андреевна',
      Gender.female,
      birthDate: DateTime(1996, 1, 5),
    );
    final sergey = person(
      'sergey',
      'Понькин Сергей Леонидович',
      Gender.male,
      birthDate: DateTime(1987, 6, 13),
    );
    final pavel = person(
      'pavel',
      'Понькин Павел Сергеевич',
      Gender.male,
      birthDate: DateTime(2024, 2, 14),
    );

    final relations = [
      parentRelation('r1', andrey.id, artem.id),
      parentRelation('r2', natalia.id, artem.id),
      unionRelation('r3', andrey.id, natalia.id),
      unionRelation(
        'r4',
        anastasia.id,
        artem.id,
        relationType: RelationType.partner,
      ),
      FamilyRelation(
        id: 'r5',
        treeId: 'tree-1',
        person1Id: darya.id,
        person2Id: artem.id,
        relation1to2: RelationType.sibling,
        relation2to1: RelationType.sibling,
        isConfirmed: true,
        createdAt: DateTime(2024, 1, 1),
      ),
      parentRelation('r6', andrey.id, darya.id),
      parentRelation('r7', natalia.id, darya.id),
      unionRelation('r8', sergey.id, darya.id),
      parentRelation('r9', darya.id, pavel.id),
      parentRelation('r10', sergey.id, pavel.id),
      parentRelation('r11', anatoly.id, andrey.id),
      parentRelation('r12', valentina.id, andrey.id),
      parentRelation('r13', gennady.id, natalia.id),
      parentRelation('r14', lydia.id, natalia.id),
      parentRelation('r15', gennady.id, evgeniy.id),
      parentRelation('r16', lydia.id, evgeniy.id),
      parentRelation('r17', alexander.id, lydia.id),
      parentRelation('r18', maria.id, lydia.id),
      unionRelation('r19', anatoly.id, valentina.id),
      unionRelation('r20', gennady.id, lydia.id),
      unionRelation('r21', alexander.id, maria.id),
    ];
    final graphSnapshot = TreeGraphSnapshot(
      treeId: 'tree-1',
      viewerPersonId: artem.id,
      people: [
        alexander,
        maria,
        gennady,
        lydia,
        anatoly,
        valentina,
        andrey,
        natalia,
        evgeniy,
        artem,
        anastasia,
        darya,
        sergey,
        pavel,
      ],
      relations: relations,
      familyUnits: [
        TreeGraphFamilyUnit(
          id: 'fu-1',
          rootParentSetId: 'lydia-parents',
          adultIds: [alexander.id, maria.id],
          childIds: [lydia.id],
          relationIds: ['r17', 'r18', 'r21'],
          unionId: 'r21',
          unionType: 'spouse',
          unionStatus: 'current',
          parentSetType: 'biological',
          isPrimaryParentSet: true,
          label: 'Семья Супруновых',
        ),
        TreeGraphFamilyUnit(
          id: 'fu-2',
          rootParentSetId: 'mochalkin-parents',
          adultIds: [gennady.id, lydia.id],
          childIds: [natalia.id, evgeniy.id],
          relationIds: ['r13', 'r14', 'r15', 'r16', 'r20'],
          unionId: 'r20',
          unionType: 'spouse',
          unionStatus: 'current',
          parentSetType: 'biological',
          isPrimaryParentSet: true,
          label: 'Семья Мочалкиных',
        ),
        TreeGraphFamilyUnit(
          id: 'fu-3',
          rootParentSetId: 'andrey-parents',
          adultIds: [anatoly.id, valentina.id],
          childIds: [andrey.id],
          relationIds: ['r11', 'r12', 'r19'],
          unionId: 'r19',
          unionType: 'spouse',
          unionStatus: 'current',
          parentSetType: 'biological',
          isPrimaryParentSet: true,
          label: 'Семья Кузнецовых',
        ),
        TreeGraphFamilyUnit(
          id: 'fu-4',
          rootParentSetId: 'children-parents',
          adultIds: [andrey.id, natalia.id],
          childIds: [artem.id, darya.id],
          relationIds: ['r1', 'r2', 'r3', 'r5', 'r6', 'r7'],
          unionId: 'r3',
          unionType: 'spouse',
          unionStatus: 'current',
          parentSetType: 'biological',
          isPrimaryParentSet: true,
          label: 'Семья Андрея и Натальи',
        ),
        TreeGraphFamilyUnit(
          id: 'fu-5',
          rootParentSetId: null,
          adultIds: [artem.id, anastasia.id],
          childIds: const [],
          relationIds: ['r4'],
          unionId: 'r4',
          unionType: 'partner',
          unionStatus: 'current',
          parentSetType: null,
          isPrimaryParentSet: false,
          label: 'Артем и Анастасия',
        ),
        TreeGraphFamilyUnit(
          id: 'fu-6',
          rootParentSetId: 'pavel-parents',
          adultIds: [sergey.id, darya.id],
          childIds: [pavel.id],
          relationIds: ['r8', 'r9', 'r10'],
          unionId: 'r8',
          unionType: 'spouse',
          unionStatus: 'current',
          parentSetType: 'biological',
          isPrimaryParentSet: true,
          label: 'Семья Понькиных',
        ),
      ],
      viewerDescriptors: const [],
      branchBlocks: const [],
      generationRows: [
        TreeGraphGenerationRow(
          row: 0,
          label: 'Старшее поколение',
          personIds: [alexander.id, maria.id],
          familyUnitIds: const ['fu-1'],
        ),
        TreeGraphGenerationRow(
          row: 1,
          label: 'Поколение 2',
          personIds: [gennady.id, lydia.id, anatoly.id, valentina.id],
          familyUnitIds: const ['fu-1', 'fu-2', 'fu-3'],
        ),
        TreeGraphGenerationRow(
          row: 2,
          label: 'Поколение 3',
          personIds: [andrey.id, natalia.id, evgeniy.id],
          familyUnitIds: const ['fu-2', 'fu-3', 'fu-4'],
        ),
        TreeGraphGenerationRow(
          row: 3,
          label: 'Поколение 4',
          personIds: [artem.id, anastasia.id, darya.id, sergey.id],
          familyUnitIds: const ['fu-4', 'fu-5', 'fu-6'],
        ),
        TreeGraphGenerationRow(
          row: 4,
          label: 'Младшее поколение',
          personIds: [pavel.id],
          familyUnitIds: const ['fu-6'],
        ),
      ],
      warnings: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': alexander, 'userProfile': null},
              {'person': maria, 'userProfile': null},
              {'person': gennady, 'userProfile': null},
              {'person': lydia, 'userProfile': null},
              {'person': anatoly, 'userProfile': null},
              {'person': valentina, 'userProfile': null},
              {'person': andrey, 'userProfile': null},
              {'person': natalia, 'userProfile': null},
              {'person': evgeniy, 'userProfile': null},
              {'person': artem, 'userProfile': null},
              {'person': anastasia, 'userProfile': null},
              {'person': darya, 'userProfile': null},
              {'person': sergey, 'userProfile': null},
              {'person': pavel, 'userProfile': null},
            ],
            relations: relations,
            graphSnapshot: graphSnapshot,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;

    final artemOffset = painter.nodePositions[artem.id]!;
    final anastasiaOffset = painter.nodePositions[anastasia.id]!;
    final daryaOffset = painter.nodePositions[darya.id]!;
    final sergeyOffset = painter.nodePositions[sergey.id]!;
    final andreyOffset = painter.nodePositions[andrey.id]!;
    final nataliaOffset = painter.nodePositions[natalia.id]!;
    final gennadyOffset = painter.nodePositions[gennady.id]!;
    final lydiaOffset = painter.nodePositions[lydia.id]!;
    final alexanderOffset = painter.nodePositions[alexander.id]!;
    final mariaOffset = painter.nodePositions[maria.id]!;
    final anatolyOffset = painter.nodePositions[anatoly.id]!;
    final valentinaOffset = painter.nodePositions[valentina.id]!;

    expect((artemOffset.dy - anastasiaOffset.dy).abs(), lessThan(0.1));
    expect((daryaOffset.dy - sergeyOffset.dy).abs(), lessThan(0.1));
    expect((andreyOffset.dy - nataliaOffset.dy).abs(), lessThan(0.1));
    expect((gennadyOffset.dy - lydiaOffset.dy).abs(), lessThan(0.1));
    expect((gennadyOffset.dy - anatolyOffset.dy).abs(), lessThan(0.1));
    expect((lydiaOffset.dy - valentinaOffset.dy).abs(), lessThan(0.1));
    expect((alexanderOffset.dy - mariaOffset.dy).abs(), lessThan(0.1));
    expect(alexanderOffset.dy, lessThan(gennadyOffset.dy));
    expect(mariaOffset.dy, lessThan(lydiaOffset.dy));
    expect(andreyOffset.dy, lessThan(artemOffset.dy));
    expect(nataliaOffset.dy, lessThan(daryaOffset.dy));
  });

  testWidgets('InteractiveFamilyTree keeps branch focus as secondary action',
      (tester) async {
    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': person, 'userProfile': null},
            ],
            relations: const <FamilyRelation>[],
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            branchRootPersonId: person.id,
            onBranchFocusRequested: (_) {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Фокус'), findsNothing);
    // Control dock starts collapsed — expand before checking the
    // branch-focus tooltip.
    await tester.tap(find.byTooltip('Настройки вида'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('К ветке'), findsOneWidget);
  });

  testWidgets(
      'InteractiveFamilyTree shows generation guides, zoom indicator and branch reset',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final parent = FamilyPerson(
      id: 'parent',
      treeId: 'tree-1',
      name: 'Родитель',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final child = FamilyPerson(
      id: 'child',
      treeId: 'tree-1',
      name: 'Ребёнок',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    var clearCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': parent, 'userProfile': null},
              {'person': child, 'userProfile': null},
            ],
            relations: [
              FamilyRelation(
                id: 'rel-1',
                treeId: 'tree-1',
                person1Id: parent.id,
                person2Id: child.id,
                relation1to2: RelationType.parent,
                relation2to1: RelationType.child,
                isConfirmed: true,
                createdAt: DateTime(2024, 1, 1),
              ),
            ],
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            branchRootPersonId: parent.id,
            onBranchFocusRequested: (_) {},
            onBranchFocusCleared: () => clearCalls += 1,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final zoomIndicatorFinder = find.byWidgetPredicate(
      (widget) => widget is Text && (widget.data?.endsWith('%') ?? false),
      description: 'zoom indicator',
    );

    expect(find.text('Старшее поколение'), findsOneWidget);
    expect(find.text('Младшее поколение'), findsOneWidget);
    // Expand the dock to access zoom + branch controls.
    await tester.tap(find.byTooltip('Настройки вида'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Сбросить ветку'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Старшее поколение')).dx,
      greaterThan(20),
    );

    // Zoom HUD is transient now (C1): a «%» surfaces after a zoom action
    // then fades, rather than sitting there persistently. Tap «Увеличить»
    // and confirm it appears.
    await tester.tap(find.byTooltip('Увеличить'));
    await tester.pump();
    expect(zoomIndicatorFinder, findsOneWidget);
    // Let the ~1.1s auto-hide timer fire so it isn't pending at test end.
    await tester.pump(const Duration(milliseconds: 1200));

    await tester.tap(find.byTooltip('Сбросить ветку'));
    await tester.pumpAndSettle();
    expect(clearCalls, 1);
  });

  testWidgets(
      'InteractiveFamilyTree shows warning badge and quick actions from graph snapshot',
      (tester) async {
    final person = FamilyPerson(
      id: 'person-1',
      treeId: 'tree-1',
      name: 'Иван Петров',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    final snapshot = TreeGraphSnapshot(
      treeId: 'tree-1',
      viewerPersonId: 'person-1',
      people: [person],
      relations: const <FamilyRelation>[],
      familyUnits: const <TreeGraphFamilyUnit>[],
      viewerDescriptors: const <TreeGraphViewerDescriptor>[
        TreeGraphViewerDescriptor(
          personId: 'person-1',
          primaryRelationLabel: 'Это вы',
          isBlood: true,
          alternatePathCount: 0,
          pathSummary: 'Это вы',
          primaryPathPersonIds: ['person-1'],
        ),
      ],
      branchBlocks: const <TreeGraphBranchBlock>[],
      generationRows: const <TreeGraphGenerationRow>[
        TreeGraphGenerationRow(
          row: 0,
          label: 'Поколение 1',
          personIds: ['person-1'],
          familyUnitIds: <String>[],
        ),
      ],
      warnings: const <TreeGraphWarning>[
        TreeGraphWarning(
          id: 'warning-1',
          code: 'conflicting_direct_links',
          severity: 'warning',
          message: 'Нужна проверка связей.',
          hint: 'Откройте инструменты исправления.',
          personIds: ['person-1'],
          familyUnitIds: <String>[],
          relationIds: <String>[],
        ),
      ],
    );

    var fixCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': person, 'userProfile': null},
            ],
            relations: const <FamilyRelation>[],
            graphSnapshot: snapshot,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            onShowRelationPath: (_) {},
            onFixPersonRelations: (_) => fixCalls += 1,
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final badgeFinder =
        find.byKey(const ValueKey<String>('tree-warning-badge-person-1'));
    expect(badgeFinder, findsOneWidget);

    tester.widget<InkWell>(badgeFinder).onTap!.call();
    await tester.pumpAndSettle();

    expect(find.text('Предупреждения'), findsOneWidget);
    expect(find.text('Исправить связи'), findsWidgets);

    await tester.tap(find.text('Исправить связи').last);
    await tester.pumpAndSettle();

    expect(fixCalls, 1);
  });

  testWidgets(
      'InteractiveFamilyTree clamps stale manual vertical positions to generation rows',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final parent = FamilyPerson(
      id: 'parent',
      treeId: 'tree-1',
      name: 'Родитель',
      gender: Gender.male,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final child = FamilyPerson(
      id: 'child',
      treeId: 'tree-1',
      name: 'Ребёнок',
      gender: Gender.female,
      isAlive: true,
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': parent, 'userProfile': null},
              {'person': child, 'userProfile': null},
            ],
            relations: [
              FamilyRelation(
                id: 'rel-1',
                treeId: 'tree-1',
                person1Id: parent.id,
                person2Id: child.id,
                relation1to2: RelationType.parent,
                relation2to1: RelationType.child,
                isConfirmed: true,
                createdAt: DateTime(2024, 1, 1),
              ),
            ],
            manualNodePositions: const <String, Offset>{
              'parent': Offset(260, 900),
            },
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final parentOffset = painter.nodePositions[parent.id]!;
    final childOffset = painter.nodePositions[child.id]!;

    expect(parentOffset.dy, lessThan(childOffset.dy));
    expect(childOffset.dy - parentOffset.dy, greaterThan(120));
  });

  testWidgets(
      'InteractiveFamilyTree keeps long-press drag inside generation row bounds',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Map<String, Offset>? reportedPositions;

    final left = FamilyPerson(
      id: 'left',
      treeId: 'tree-1',
      name: 'Левый',
      gender: Gender.male,
      isAlive: true,
      birthDate: DateTime(1971, 1, 1),
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final right = FamilyPerson(
      id: 'right',
      treeId: 'tree-1',
      name: 'Правый',
      gender: Gender.female,
      isAlive: true,
      birthDate: DateTime(1974, 1, 1),
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final child = FamilyPerson(
      id: 'child',
      treeId: 'tree-1',
      name: 'Ребёнок',
      gender: Gender.female,
      isAlive: true,
      birthDate: DateTime(2002, 1, 1),
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': left, 'userProfile': null},
              {'person': right, 'userProfile': null},
              {'person': child, 'userProfile': null},
            ],
            relations: [
              FamilyRelation(
                id: 'union',
                treeId: 'tree-1',
                person1Id: left.id,
                person2Id: right.id,
                relation1to2: RelationType.spouse,
                relation2to1: RelationType.spouse,
                isConfirmed: true,
                createdAt: DateTime(2024, 1, 1),
              ),
              FamilyRelation(
                id: 'child-left',
                treeId: 'tree-1',
                person1Id: left.id,
                person2Id: child.id,
                relation1to2: RelationType.parent,
                relation2to1: RelationType.child,
                isConfirmed: true,
                createdAt: DateTime(2024, 1, 1),
              ),
              FamilyRelation(
                id: 'child-right',
                treeId: 'tree-1',
                person1Id: right.id,
                person2Id: child.id,
                relation1to2: RelationType.parent,
                relation2to1: RelationType.child,
                isConfirmed: true,
                createdAt: DateTime(2024, 1, 1),
              ),
            ],
            isEditMode: true,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
            onNodePositionsChanged: (value) {
              reportedPositions = Map<String, Offset>.from(value);
            },
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paintBefore = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painterBefore = paintBefore.painter! as FamilyTreePainter;
    final leftBefore = painterBefore.nodePositions[left.id]!;
    final rightBefore = painterBefore.nodePositions[right.id]!;

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('tree-node-left'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 80));
    await gesture.moveBy(const Offset(320, 240));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final leftAfter = reportedPositions![left.id]!;
    expect(leftAfter.dy, closeTo(leftBefore.dy, 0.1));
    expect(leftAfter.dx, greaterThan(leftBefore.dx));
    // Drag stays within the row's reorder window — at most one
    // node-width past the rightmost sibling, which is the budget
    // _snapNodePositionWithinGeneration uses (nodeWidth * 0.85).
    // Earlier this tested for an exact snap to rightBefore.dx,
    // which depended on a 36px snap radius being reachable from
    // the candidate position; that radius depends on screen-pixel
    // → canvas-pixel scaling and breaks when the canvas inset
    // changes. The semantic check — "didn't escape the row" — is
    // what we actually care about.
    expect(
      leftAfter.dx,
      lessThanOrEqualTo(
        rightBefore.dx + InteractiveFamilyTree.nodeWidth * 0.85 + 0.1,
      ),
    );
  });

  testWidgets(
      'InteractiveFamilyTree shows cohort subtitles on generation guides',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final zoomer = FamilyPerson(
      id: 'zoomer',
      treeId: 'tree-1',
      name: 'Зумер',
      gender: Gender.male,
      isAlive: true,
      birthDate: DateTime(2002, 1, 1),
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );
    final alpha = FamilyPerson(
      id: 'alpha',
      treeId: 'tree-1',
      name: 'Ребёнок',
      gender: Gender.female,
      isAlive: true,
      birthDate: DateTime(2024, 1, 1),
      createdAt: DateTime(2024, 1, 1),
      updatedAt: DateTime(2024, 1, 1),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': zoomer, 'userProfile': null},
              {'person': alpha, 'userProfile': null},
            ],
            relations: [
              FamilyRelation(
                id: 'rel-1',
                treeId: 'tree-1',
                person1Id: zoomer.id,
                person2Id: alpha.id,
                relation1to2: RelationType.parent,
                relation2to1: RelationType.child,
                isConfirmed: true,
                createdAt: DateTime(2024, 1, 1),
              ),
            ],
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Зумеры'), findsOneWidget);
    expect(find.text('Альфа'), findsOneWidget);
  });

  testWidgets(
    'InteractiveFamilyTree anchors a cousin without explicit parent edges via the family unit',
    (tester) async {
      // Regression: adding a cousin (daughter of an aunt that's
      // already in the tree) used to drift to the far right of her
      // row with no visible parent line, because the layout only
      // consumed literal RelationType.parent / spouse / sibling
      // edges. The fix re-projects the snapshot's family units back
      // into the adjacency maps so distant relatives — cousin / aunt
      // / uncle / niece / in-law — get the same parent/child edges
      // the backend already inferred.

      tester.view.physicalSize = const Size(2000, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final grandpa = FamilyPerson(
        id: 'grandpa',
        treeId: 'tree-1',
        name: 'Дедушка',
        gender: Gender.male,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
      final grandma = FamilyPerson(
        id: 'grandma',
        treeId: 'tree-1',
        name: 'Бабушка',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
      final mother = FamilyPerson(
        id: 'mother',
        treeId: 'tree-1',
        name: 'Мама',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
      final aunt = FamilyPerson(
        id: 'aunt',
        treeId: 'tree-1',
        name: 'Тётя',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
      final me = FamilyPerson(
        id: 'me',
        treeId: 'tree-1',
        name: 'Я',
        gender: Gender.male,
        userId: 'user-1',
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
      final cousin = FamilyPerson(
        id: 'cousin',
        treeId: 'tree-1',
        name: 'Двоюродная сестра',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );

      // Explicit relations only carry parent edges to mother (the
      // user's parent) — the cousin and the aunt are anchored
      // EXCLUSIVELY through the family unit snapshot, mimicking the
      // shape the backend hands us when the user adds a cousin via
      // the "Двоюродная сестра" relation type without manually
      // setting up parent links.
      final relations = <FamilyRelation>[
        FamilyRelation(
          id: 'r1',
          treeId: 'tree-1',
          person1Id: mother.id,
          person2Id: me.id,
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        ),
      ];

      final snapshot = TreeGraphSnapshot(
        treeId: 'tree-1',
        viewerPersonId: me.id,
        people: [grandpa, grandma, mother, aunt, me, cousin],
        relations: relations,
        familyUnits: [
          // Grandparents → mother + aunt as siblings.
          TreeGraphFamilyUnit(
            id: 'fu-grandparents',
            rootParentSetId: 'gp-parents',
            adultIds: [grandpa.id, grandma.id],
            childIds: [mother.id, aunt.id],
            relationIds: const [],
            unionId: null,
            unionType: 'spouse',
            unionStatus: 'current',
            parentSetType: 'biological',
            isPrimaryParentSet: true,
            label: 'Семья дедушки и бабушки',
          ),
          // Aunt → cousin (single-parent unit, no spouse known).
          TreeGraphFamilyUnit(
            id: 'fu-cousin',
            rootParentSetId: 'cousin-parents',
            adultIds: [aunt.id],
            childIds: [cousin.id],
            relationIds: const [],
            unionId: null,
            unionType: null,
            unionStatus: null,
            parentSetType: 'biological',
            isPrimaryParentSet: true,
            label: 'Семья тёти',
          ),
        ],
        viewerDescriptors: const [],
        branchBlocks: const [],
        generationRows: [
          TreeGraphGenerationRow(
            row: 0,
            label: 'Старшее поколение',
            personIds: [grandpa.id, grandma.id],
            familyUnitIds: const ['fu-grandparents'],
          ),
          TreeGraphGenerationRow(
            row: 1,
            label: 'Поколение родителей',
            personIds: [mother.id, aunt.id],
            familyUnitIds: const ['fu-grandparents', 'fu-cousin'],
          ),
          TreeGraphGenerationRow(
            row: 2,
            label: 'Моё поколение',
            personIds: [me.id, cousin.id],
            familyUnitIds: const ['fu-cousin'],
          ),
        ],
        warnings: const [],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InteractiveFamilyTree(
              peopleData: [
                {'person': grandpa, 'userProfile': null},
                {'person': grandma, 'userProfile': null},
                {'person': mother, 'userProfile': null},
                {'person': aunt, 'userProfile': null},
                {'person': me, 'userProfile': null},
                {'person': cousin, 'userProfile': null},
              ],
              relations: relations,
              graphSnapshot: snapshot,
              onPersonTap: (_) {},
              onAddRelativeTapWithType: (_, __) {},
              currentUserIsInTree: true,
              onAddSelfTapWithType: (_, __) async {},
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      final paint = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is FamilyTreePainter,
        ),
      );
      final painter = paint.painter! as FamilyTreePainter;
      final positions = painter.nodePositions;

      final motherY = positions[mother.id]!.dy;
      final auntY = positions[aunt.id]!.dy;
      final meY = positions[me.id]!.dy;
      final cousinY = positions[cousin.id]!.dy;
      final auntX = positions[aunt.id]!.dx;
      final cousinX = positions[cousin.id]!.dx;
      final meX = positions[me.id]!.dx;

      // Mother and aunt share the parent generation row.
      expect((motherY - auntY).abs(), lessThan(0.1));
      // The cousin sits a generation below — same Y as the user.
      expect((meY - cousinY).abs(), lessThan(0.1));
      expect(cousinY, greaterThan(auntY));

      // The cousin's horizontal position should track her mother
      // (the aunt) — within roughly two card widths. Without the
      // family-unit fix she'd drift to far-right of her row with
      // no anchor.
      expect((cousinX - auntX).abs(),
          lessThan(InteractiveFamilyTree.nodeWidth * 2.5));

      // And — crucially — the cousin must NOT collide with the user.
      // Before the fix the singleton group landed wherever currentLeft
      // happened to be, sometimes overlapping siblings.
      expect((cousinX - meX).abs(),
          greaterThan(InteractiveFamilyTree.nodeWidth * 0.5));

      // Connection line aunt → cousin must be present even though
      // there's no explicit RelationType.parent relation between
      // them — _buildConnections has to project it from the family
      // unit snapshot.
      final hasAuntCousinLine = painter.connections.any(
        (connection) =>
            connection.fromId == aunt.id &&
            connection.toId == cousin.id &&
            connection.type == RelationType.parent,
      );
      expect(hasAuntCousinLine, isTrue,
          reason: 'cousin should have a visible parent line to the aunt');
    },
  );

  // ── Edge-first connector tests ──────────────────────────────────────
  // Long-press one card → drag to another → 4-icon picker → relation
  // type chosen → onConnectExistingPersons fires with the right
  // (source, target, type) tuple. These tests don't go through the
  // service layer — they pin the WIDGET's contract.

  // Regression test for the user-reported "Витя branch shifts up
  // one generation" bug. When an uncle-by-marriage is in the
  // graph WITHOUT an explicit spouse relation to the blood-aunt,
  // and his only structural anchor is "parent of cousin", the
  // BFS used to place him at grandparents' row and his cousin
  // child at parents' row — both one generation too high. The
  // viewer-relation anchor pass now uses the backend-supplied
  // primaryRelationLabel ("Дядя", "Двоюродная сестра", etc.) to
  // pull these weakly-anchored nodes back to the correct rows.
  group('Layout: viewer-relation generation anchor', () {
    testWidgets(
      'uncle-by-marriage with no spouse edge lands on parents row, his daughter on viewer row',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.reset());

        // Cast: 4 generations.
        //   Grandfather + Grandmother (gen 1)
        //   ├─ Father (gen 2, viewer's parent)
        //   │  ├─ Viewer (gen 3) — currentUserId is wired here
        //   ├─ Aunt — Lena (gen 2, sister of father)
        //   ?  Uncle — Vitya (no explicit spouse-of-Lena edge,
        //              no explicit parent-of-cousin relation here
        //              either; the BACKEND graph supplies the
        //              "Дядя" descriptor that should anchor him).
        //   ?  Cousin — Nastya (Vitya's daughter, no explicit
        //              parent edge; descriptor says "Двоюродная
        //              сестра" → same gen as viewer).
        final grandpa = FamilyPerson(
          id: 'grandpa',
          treeId: 'tree-1',
          name: 'Анатолий Степанович',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final grandma = FamilyPerson(
          id: 'grandma',
          treeId: 'tree-1',
          name: 'Валентина',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final father = FamilyPerson(
          id: 'father',
          treeId: 'tree-1',
          name: 'Андрей Анатольевич',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final viewer = FamilyPerson(
          id: 'viewer',
          treeId: 'tree-1',
          userId: 'user-viewer',
          name: 'Артём Андреевич',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final aunt = FamilyPerson(
          id: 'aunt',
          treeId: 'tree-1',
          name: 'Лена Анатольевна',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final uncle = FamilyPerson(
          id: 'uncle',
          treeId: 'tree-1',
          name: 'Виктор',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final cousin = FamilyPerson(
          id: 'cousin',
          treeId: 'tree-1',
          name: 'Анастасия Викторовна',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

        // Explicit relations — note the GAPS:
        //   * No spouse edge between aunt + uncle (the bug case).
        //   * No parent edge from aunt to cousin (data is incomplete).
        //   * The ONLY edge that anchors uncle is "parent of cousin".
        // This recreates the exact data shape that triggered the bug.
        final relations = <FamilyRelation>[
          FamilyRelation(
            id: 'r1',
            treeId: 'tree-1',
            person1Id: 'grandpa',
            person2Id: 'grandma',
            relation1to2: RelationType.spouse,
            relation2to1: RelationType.spouse,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r2',
            treeId: 'tree-1',
            person1Id: 'grandpa',
            person2Id: 'father',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r3',
            treeId: 'tree-1',
            person1Id: 'grandma',
            person2Id: 'father',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r4',
            treeId: 'tree-1',
            person1Id: 'father',
            person2Id: 'viewer',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r5',
            treeId: 'tree-1',
            person1Id: 'grandpa',
            person2Id: 'aunt',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r6',
            treeId: 'tree-1',
            person1Id: 'grandma',
            person2Id: 'aunt',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          // Uncle's only structural anchor — parent of cousin.
          // Without the viewer-relation anchor pass, this drops
          // him to gen 1 (with cousin at gen 2) instead of gen 2
          // (with cousin at gen 3 alongside viewer).
          FamilyRelation(
            id: 'r7',
            treeId: 'tree-1',
            person1Id: 'uncle',
            person2Id: 'cousin',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
        ];

        // Backend-supplied descriptors. The viewer-relation anchor
        // pass uses these to derive "uncle should be at viewer-1,
        // cousin at viewer-0" and overrides the BFS.
        final descriptors = [
          TreeGraphViewerDescriptor(
            personId: 'father',
            primaryRelationLabel: 'Отец',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['father'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'aunt',
            primaryRelationLabel: 'Тётя',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['aunt'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'uncle',
            primaryRelationLabel: 'Дядя',
            isBlood: false,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['uncle'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'cousin',
            primaryRelationLabel: 'Двоюродная сестра',
            isBlood: false,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['cousin'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'grandpa',
            primaryRelationLabel: 'Дедушка',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['grandpa'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'grandma',
            primaryRelationLabel: 'Бабушка',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['grandma'],
          ),
        ];
        final snapshot = TreeGraphSnapshot(
          treeId: 'tree-1',
          viewerPersonId: 'viewer',
          people: const [],
          relations: const [],
          generationRows: const [],
          familyUnits: const [],
          branchBlocks: const [],
          warnings: const [],
          viewerDescriptors: descriptors,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InteractiveFamilyTree(
                peopleData: [
                  for (final p in [
                    grandpa,
                    grandma,
                    father,
                    viewer,
                    aunt,
                    uncle,
                    cousin,
                  ])
                    {'person': p, 'userProfile': null},
                ],
                relations: relations,
                graphSnapshot: snapshot,
                onPersonTap: (_) {},
                isEditMode: false,
                onAddRelativeTapWithType: (_, __) {},
                currentUserIsInTree: true,
                onAddSelfTapWithType: (_, __) async {},
                currentUserId: 'user-viewer',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Read the layout result from the rendered Positioned cards.
        // Each card has a key 'tree-node-position-<id>'; we read its
        // resolved top-Y to compare rows.
        double topYFor(String personId) {
          final finder =
              find.byKey(ValueKey<String>('tree-node-position-$personId'));
          expect(finder, findsOneWidget,
              reason: 'card for $personId should be on the canvas');
          final renderBox = tester.renderObject<RenderBox>(finder);
          final origin = renderBox.localToGlobal(Offset.zero);
          return origin.dy;
        }

        final viewerY = topYFor('viewer');
        final fatherY = topYFor('father');
        final grandpaY = topYFor('grandpa');
        final auntY = topYFor('aunt');
        final uncleY = topYFor('uncle');
        final cousinY = topYFor('cousin');

        // Sanity check: father is one row above viewer; grandpa
        // one above father.
        expect(fatherY < viewerY, isTrue,
            reason: 'father must be above viewer in the layout');
        expect(grandpaY < fatherY, isTrue,
            reason: 'grandpa must be above father');

        // The bug: uncle-by-marriage lands on grandparents' row.
        // The fix: the viewer-relation anchor pulls him to
        // father's row (parents' generation = -1 from viewer).
        // We compare against the *father*'s Y (his blood-relative
        // anchor) so the test is robust to layout-engine row-
        // height tweaks.
        expect(
          (uncleY - fatherY).abs() < 5,
          isTrue,
          reason:
              'uncle (Дядя by descriptor) should sit on the same row as father / aunt',
        );
        expect(
          (auntY - fatherY).abs() < 5,
          isTrue,
          reason: 'aunt should also be on parents\' row',
        );

        // Cousin (Двоюродная сестра by descriptor) should land on
        // viewer's row, not on father's row.
        expect(
          (cousinY - viewerY).abs() < 5,
          isTrue,
          reason: 'cousin should be on the same row as viewer',
        );
      },
    );

    // Regression for the live-prod bug: when uncle-by-marriage is
    // structurally connected to the viewer's MAIN component (e.g.,
    // because his daughter is also linked as the viewer's blood
    // aunt's daughter, OR because his daughter has a sibling-of-
    // viewer edge somewhere), the cross-component shift doesn't
    // touch him — the within-component anchor pass must.
    testWidgets(
      'in-law inside the viewer main component lands on partner row, his daughter on viewer row',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1100);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.reset());

        // Cast — same as the previous test BUT with one extra
        // parent edge from grandma → cousin. That edge bridges
        // uncle's branch into the viewer's main component, which
        // is what triggered the production bug.
        final grandpa = FamilyPerson(
          id: 'grandpa',
          treeId: 'tree-1',
          name: 'Анатолий Степанович',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final grandma = FamilyPerson(
          id: 'grandma',
          treeId: 'tree-1',
          name: 'Валентина',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final father = FamilyPerson(
          id: 'father',
          treeId: 'tree-1',
          name: 'Андрей Анатольевич',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final viewer = FamilyPerson(
          id: 'viewer',
          treeId: 'tree-1',
          userId: 'user-viewer',
          name: 'Артём Андреевич',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final aunt = FamilyPerson(
          id: 'aunt',
          treeId: 'tree-1',
          name: 'Лена Анатольевна',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final uncle = FamilyPerson(
          id: 'uncle',
          treeId: 'tree-1',
          name: 'Виктор',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final cousin = FamilyPerson(
          id: 'cousin',
          treeId: 'tree-1',
          name: 'Анастасия Викторовна',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

        // Cousin has BOTH the aunt AND the uncle as parents in
        // this case → uncle joins the viewer's main component
        // through cousin's parent edges. No spouse-of-aunt edge
        // for the uncle. Same data shape as production.
        final relations = <FamilyRelation>[
          FamilyRelation(
            id: 'r1',
            treeId: 'tree-1',
            person1Id: 'grandpa',
            person2Id: 'grandma',
            relation1to2: RelationType.spouse,
            relation2to1: RelationType.spouse,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r2',
            treeId: 'tree-1',
            person1Id: 'grandpa',
            person2Id: 'father',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r3',
            treeId: 'tree-1',
            person1Id: 'grandma',
            person2Id: 'father',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r4',
            treeId: 'tree-1',
            person1Id: 'father',
            person2Id: 'viewer',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r5',
            treeId: 'tree-1',
            person1Id: 'grandpa',
            person2Id: 'aunt',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          FamilyRelation(
            id: 'r6',
            treeId: 'tree-1',
            person1Id: 'grandma',
            person2Id: 'aunt',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          // Uncle parent of cousin.
          FamilyRelation(
            id: 'r7',
            treeId: 'tree-1',
            person1Id: 'uncle',
            person2Id: 'cousin',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
          // *** Bridge to viewer's main component ***: aunt is
          // ALSO a parent of cousin. This is what makes uncle
          // and cousin show up in the viewer's main component
          // (not their own isolated component).
          FamilyRelation(
            id: 'r8',
            treeId: 'tree-1',
            person1Id: 'aunt',
            person2Id: 'cousin',
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          ),
        ];

        final descriptors = [
          TreeGraphViewerDescriptor(
            personId: 'father',
            primaryRelationLabel: 'Отец',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['father'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'aunt',
            primaryRelationLabel: 'Тётя',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['aunt'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'uncle',
            primaryRelationLabel: 'Дядя',
            isBlood: false,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['uncle'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'cousin',
            primaryRelationLabel: 'Двоюродная сестра',
            isBlood: false,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['cousin'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'grandpa',
            primaryRelationLabel: 'Дедушка',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['grandpa'],
          ),
          TreeGraphViewerDescriptor(
            personId: 'grandma',
            primaryRelationLabel: 'Бабушка',
            isBlood: true,
            alternatePathCount: 0,
            pathSummary: null,
            primaryPathPersonIds: const ['grandma'],
          ),
        ];
        final snapshot = TreeGraphSnapshot(
          treeId: 'tree-1',
          viewerPersonId: 'viewer',
          people: const [],
          relations: const [],
          generationRows: const [],
          familyUnits: const [],
          branchBlocks: const [],
          warnings: const [],
          viewerDescriptors: descriptors,
        );

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InteractiveFamilyTree(
                peopleData: [
                  for (final p in [
                    grandpa,
                    grandma,
                    father,
                    viewer,
                    aunt,
                    uncle,
                    cousin,
                  ])
                    {'person': p, 'userProfile': null},
                ],
                relations: relations,
                graphSnapshot: snapshot,
                onPersonTap: (_) {},
                isEditMode: false,
                onAddRelativeTapWithType: (_, __) {},
                currentUserIsInTree: true,
                onAddSelfTapWithType: (_, __) async {},
                currentUserId: 'user-viewer',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        double topYFor(String personId) {
          final finder =
              find.byKey(ValueKey<String>('tree-node-position-$personId'));
          expect(finder, findsOneWidget);
          final renderBox = tester.renderObject<RenderBox>(finder);
          return renderBox.localToGlobal(Offset.zero).dy;
        }

        final viewerY = topYFor('viewer');
        final fatherY = topYFor('father');
        final auntY = topYFor('aunt');
        final uncleY = topYFor('uncle');
        final cousinY = topYFor('cousin');

        expect(
          (uncleY - fatherY).abs() < 5,
          isTrue,
          reason: 'in-law uncle in main component should land on parents row, '
              'NOT on grandparents row',
        );
        expect(
          (auntY - fatherY).abs() < 5,
          isTrue,
          reason: 'aunt should be on parents row',
        );
        expect(
          (cousinY - viewerY).abs() < 5,
          isTrue,
          reason: 'cousin in main component should land on viewer row, '
              'NOT on parents row',
        );
      },
    );

    testWidgets(
      'blended family keeps current spouse and prior-child branch on the right generation',
      (tester) async {
        tester.view.physicalSize = const Size(1800, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.reset());

        FamilyPerson person(
          String id,
          String name,
          Gender gender, {
          String? userId,
        }) {
          return FamilyPerson(
            id: id,
            treeId: 'tree-1',
            userId: userId,
            name: name,
            gender: gender,
            isAlive: true,
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
          );
        }

        FamilyRelation parent(String id, String parentId, String childId) {
          return FamilyRelation(
            id: id,
            treeId: 'tree-1',
            person1Id: parentId,
            person2Id: childId,
            relation1to2: RelationType.parent,
            relation2to1: RelationType.child,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          );
        }

        FamilyRelation union(
          String id,
          String leftId,
          String rightId,
          RelationType type, {
          String? unionStatus,
        }) {
          return FamilyRelation(
            id: id,
            treeId: 'tree-1',
            person1Id: leftId,
            person2Id: rightId,
            relation1to2: type,
            relation2to1: type,
            unionStatus: unionStatus,
            isConfirmed: true,
            createdAt: DateTime(2024, 1, 1),
          );
        }

        final greatGrandpa = person('great-grandpa', 'Прадед', Gender.male);
        final greatGrandma =
            person('great-grandma', 'Прабабушка', Gender.female);
        final galina = person('galina', 'Курбатова Галина', Gender.female);
        final vladimir = person('vladimir', 'Курбатов Владимир', Gender.male);
        final maria = person('maria', 'Бетехтина Мария', Gender.female);
        final viewer = person(
          'viewer',
          'Артём',
          Gender.male,
          userId: 'user-viewer',
        );
        final marat = person('marat', 'Назмутдинов Марат', Gender.male);
        final katya = person('katya', 'Назмутдинова Екатерина', Gender.female);

        final relations = <FamilyRelation>[
          union(
              'u-older', greatGrandpa.id, greatGrandma.id, RelationType.spouse),
          parent('p-1', greatGrandpa.id, galina.id),
          parent('p-2', greatGrandma.id, galina.id),
          union(
            'u-past',
            galina.id,
            vladimir.id,
            RelationType.ex_spouse,
            unionStatus: 'past',
          ),
          parent('p-3', galina.id, maria.id),
          parent('p-4', vladimir.id, maria.id),
          parent('p-5', maria.id, viewer.id),
          union('u-current', galina.id, marat.id, RelationType.spouse),
          parent('p-6', marat.id, katya.id),
        ];

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: InteractiveFamilyTree(
                peopleData: [
                  for (final p in [
                    greatGrandpa,
                    greatGrandma,
                    galina,
                    vladimir,
                    maria,
                    viewer,
                    marat,
                    katya,
                  ])
                    {'person': p, 'userProfile': null},
                ],
                relations: relations,
                onPersonTap: (_) {},
                isEditMode: false,
                onAddRelativeTapWithType: (_, __) {},
                currentUserIsInTree: true,
                onAddSelfTapWithType: (_, __) async {},
                currentUserId: 'user-viewer',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        double topYFor(String personId) {
          final finder =
              find.byKey(ValueKey<String>('tree-node-position-$personId'));
          expect(finder, findsOneWidget,
              reason: 'card for $personId should be on the canvas');
          final renderBox = tester.renderObject<RenderBox>(finder);
          return renderBox.localToGlobal(Offset.zero).dy;
        }

        final galinaY = topYFor(galina.id);
        final vladimirY = topYFor(vladimir.id);
        final maratY = topYFor(marat.id);
        final mariaY = topYFor(maria.id);
        final katyaY = topYFor(katya.id);

        expect(
          (vladimirY - galinaY).abs() < 5,
          isTrue,
          reason: 'former spouse should stay on Galina row',
        );
        expect(
          (maratY - galinaY).abs() < 5,
          isTrue,
          reason:
              'current spouse with a child from prior marriage should not fly to an older row',
        );
        expect(
          (katyaY - mariaY).abs() < 5,
          isTrue,
          reason: 'Marat daughter from prior marriage should sit on Maria row',
        );
      },
    );
  });

  group('Edge-first connector', () {
    Future<void> pumpTwoPersonTree(
      WidgetTester tester, {
      required void Function(String, String, RelationType)?
          onConnectExistingPersons,
      Future<void> Function(Map<String, dynamic>)? onAddBlankPerson,
    }) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.reset());

      final personA = FamilyPerson(
        id: 'person-a',
        treeId: 'tree-1',
        name: 'Анна Кузнецова',
        gender: Gender.female,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );
      final personB = FamilyPerson(
        id: 'person-b',
        treeId: 'tree-1',
        name: 'Борис Кузнецов',
        gender: Gender.male,
        isAlive: true,
        createdAt: DateTime(2024, 1, 1),
        updatedAt: DateTime(2024, 1, 1),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InteractiveFamilyTree(
              peopleData: [
                {'person': personA, 'userProfile': null},
                {'person': personB, 'userProfile': null},
              ],
              relations: const <FamilyRelation>[],
              onPersonTap: (_) {},
              isEditMode: false,
              onAddRelativeTapWithType: (_, __) {},
              currentUserIsInTree: false,
              onAddSelfTapWithType: (_, __) async {},
              onConnectExistingPersons: onConnectExistingPersons,
              onAddBlankPerson: onAddBlankPerson,
              currentUserId: 'user-1',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Convenience: shape that turns on the blank-card FAB but
    // leaves the connector callback null so unrelated assertions
    // don't fight LongPressDraggable.
    Future<void> pumpTwoPersonTreeWithBlankPerson(
      WidgetTester tester, {
      required Future<void> Function(Map<String, dynamic>) onAddBlankPerson,
    }) async {
      await pumpTwoPersonTree(
        tester,
        onConnectExistingPersons: (_, __, ___) {},
        onAddBlankPerson: onAddBlankPerson,
      );
    }

    testWidgets(
      'is fully disabled when host did not wire onConnectExistingPersons',
      (tester) async {
        await pumpTwoPersonTree(tester, onConnectExistingPersons: null);

        // No DragTarget / LongPressDraggable should be present —
        // when the callback is null the widget falls back to the
        // legacy GestureDetector tree without drag wiring.
        expect(find.byType(LongPressDraggable<String>), findsNothing);
        expect(find.byType(DragTarget<String>), findsNothing);
      },
    );

    testWidgets(
      'long-press starts connecting → pill shows source name → ESC cancels',
      (tester) async {
        bool wasCalled = false;
        await pumpTwoPersonTree(
          tester,
          onConnectExistingPersons: (_, __, ___) {
            wasCalled = true;
          },
        );

        // Card "Анна" rendered → long-press starts the connect drag.
        // The connector wiring requires LongPressDraggable to fire
        // onDragStarted, which sets _connectingFromPersonId. We
        // verify the pill appears with the source name.
        expect(
            find.byType(LongPressDraggable<String>), findsAtLeastNWidgets(1));
        expect(find.byType(DragTarget<String>), findsAtLeastNWidgets(1));

        // Trigger the long-press on the source card.
        final cardFinder = find.text('Анна').first;
        final cardCenter = tester.getCenter(cardFinder);
        final gesture = await tester.startGesture(cardCenter);
        // Wait past the LongPressDraggable delay (we tightened to
        // 320 ms in the connector wrapper).
        await tester.pump(const Duration(milliseconds: 380));
        // Move slightly to nudge into "drag" state (some platforms
        // require movement after the long-press to start the drag).
        await gesture.moveBy(const Offset(40, 40));
        await tester.pump();

        // Pill is rendered with the source name in it.
        expect(
          find.textContaining('Перетащите «Анна'),
          findsOneWidget,
          reason: 'Connecting pill should show with the source person name',
        );

        // Drop in empty space → cancel via the onDragEnd handler;
        // pill disappears.
        await gesture.up();
        await tester.pumpAndSettle();
        expect(find.textContaining('Перетащите'), findsNothing);
        expect(wasCalled, isFalse);
      },
    );

    testWidgets(
      'picker fires onConnectExistingPersons with chosen relation type',
      (tester) async {
        String? capturedSource;
        String? capturedTarget;
        RelationType? capturedType;
        await pumpTwoPersonTree(
          tester,
          onConnectExistingPersons: (sourceId, targetId, type) {
            capturedSource = sourceId;
            capturedTarget = targetId;
            capturedType = type;
          },
        );

        // Drag from card A onto card B.
        final sourceCenter = tester.getCenter(find.text('Анна').first);
        final targetCenter = tester.getCenter(find.text('Борис').first);

        final gesture = await tester.startGesture(sourceCenter);
        await tester.pump(const Duration(milliseconds: 380));
        // Move in two hops so the LongPressDraggable feedback
        // tracks correctly across the canvas.
        await gesture.moveTo(
          Offset((sourceCenter.dx + targetCenter.dx) / 2,
              (sourceCenter.dy + targetCenter.dy) / 2),
        );
        await tester.pump();
        await gesture.moveTo(targetCenter);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        // Picker dialog should be visible with all 4 options.
        expect(find.text('Кто такие друг другу?'), findsOneWidget);
        expect(find.text('Супруги'), findsOneWidget);
        expect(find.text('Брат/сестра'), findsOneWidget);
        expect(find.text('Другая связь'), findsOneWidget);

        // Tap "Супруги" — should fire the callback with spouse type.
        await tester.tap(find.text('Супруги'));
        await tester.pumpAndSettle();

        expect(capturedSource, 'person-a');
        expect(capturedTarget, 'person-b');
        expect(capturedType, RelationType.spouse);

        // Pill is gone after the picker resolves.
        expect(find.textContaining('Перетащите'), findsNothing);
      },
    );

    testWidgets(
      'blank-card FAB is hidden when host did not wire onAddBlankPerson',
      (tester) async {
        await pumpTwoPersonTree(tester, onConnectExistingPersons: null);
        expect(find.byTooltip('Добавить карточку'), findsNothing);
      },
    );

    testWidgets(
      'blank-card FAB opens dialog → save fires onAddBlankPerson with name + gender',
      (tester) async {
        Map<String, dynamic>? captured;
        await pumpTwoPersonTreeWithBlankPerson(
          tester,
          onAddBlankPerson: (data) async {
            captured = data;
          },
        );

        // FAB visible with the right tooltip.
        expect(find.byTooltip('Добавить карточку'), findsOneWidget);

        await tester.tap(find.byTooltip('Добавить карточку'));
        await tester.pumpAndSettle();

        // Dialog renders with both name fields and the 3 gender chips.
        expect(find.text('Новый человек'), findsOneWidget);
        expect(find.widgetWithText(TextFormField, 'Имя'), findsOneWidget);
        expect(find.text('Мужской'), findsOneWidget);
        expect(find.text('Женский'), findsOneWidget);
        expect(find.text('Не указан'), findsOneWidget);

        // Empty save → validation message; callback NOT fired.
        await tester.tap(find.text('Добавить'));
        await tester.pumpAndSettle();
        expect(find.text('Введите имя'), findsOneWidget);
        expect(captured, isNull);

        // Type a name + flip to female → save fires the callback.
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Имя'),
          'Анна',
        );
        await tester.tap(find.text('Женский'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Добавить'));
        await tester.pumpAndSettle();

        expect(captured, isNotNull);
        expect(captured!['firstName'], 'Анна');
        expect(captured!['gender'], 'female');
        // Empty lastName → omitted from payload (don't send blanks).
        expect(captured!.containsKey('lastName'), isFalse);
      },
    );

    testWidgets(
      'recenterOnPersonId triggers _focusOnPerson via TransformationController',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 1000);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(() => tester.view.reset());

        final personA = FamilyPerson(
          id: 'person-a',
          treeId: 'tree-1',
          name: 'Анна',
          gender: Gender.female,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );
        final personB = FamilyPerson(
          id: 'person-b',
          treeId: 'tree-1',
          name: 'Борис',
          gender: Gender.male,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

        // Stabilize peopleData / relations across rebuilds so the
        // tree's didUpdateWidget doesn't see them as "changed" and
        // recompute layout (which would reset the transform we're
        // trying to assert on).
        final stablePeopleData = [
          {'person': personA, 'userProfile': null},
          {'person': personB, 'userProfile': null},
        ];
        const stableRelations = <FamilyRelation>[];

        Widget buildTree(String? recenterId) => MaterialApp(
              home: Scaffold(
                body: InteractiveFamilyTree(
                  peopleData: stablePeopleData,
                  relations: stableRelations,
                  onPersonTap: (_) {},
                  isEditMode: false,
                  onAddRelativeTapWithType: (_, __) {},
                  currentUserIsInTree: false,
                  onAddSelfTapWithType: (_, __) async {},
                  recenterOnPersonId: recenterId,
                  currentUserId: 'user-1',
                ),
              ),
            );

        // Initial mount with no recenter — viewport sits in
        // whatever default state the layout engine produces.
        await tester.pumpWidget(buildTree(null));
        await tester.pumpAndSettle();

        // Capture the initial transformation matrix so we can
        // detect a change. We don't pin its exact value — the
        // layout engine's output depends on the viewport size and
        // could change with future polish — we just verify that
        // setting recenterOnPersonId DOES move the viewport.
        final viewerWidgetBefore =
            tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        final controllerBefore =
            viewerWidgetBefore.transformationController!.value.clone();

        // Now rebuild with recenterOnPersonId set to person-b.
        // The tree's didUpdateWidget should schedule a post-frame
        // _focusOnPerson which mutates the TransformationController.
        await tester.pumpWidget(buildTree('person-b'));
        await tester.pumpAndSettle();

        final viewerWidgetAfter =
            tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        final controllerAfter =
            viewerWidgetAfter.transformationController!.value;

        expect(
          controllerAfter == controllerBefore,
          isFalse,
          reason:
              'Setting recenterOnPersonId should move the viewport via _focusOnPerson',
        );

        // Setting the SAME id again is a no-op (only fires on
        // change). We use that to make sure rebuilds with the
        // same prop value don't keep re-centering — important
        // because tree_view_screen leaves the prop in place
        // after the initial set.
        final controllerStable = controllerAfter.clone();
        await tester.pumpWidget(buildTree('person-b'));
        await tester.pumpAndSettle();
        final viewerWidgetAgain =
            tester.widget<InteractiveViewer>(find.byType(InteractiveViewer));
        expect(
          viewerWidgetAgain.transformationController!.value == controllerStable,
          isTrue,
          reason: 'Same recenterOnPersonId should not re-trigger focus',
        );
      },
    );

    testWidgets(
      'blank-card dialog cancel → callback NOT called, dialog closes',
      (tester) async {
        bool wasCalled = false;
        await pumpTwoPersonTreeWithBlankPerson(
          tester,
          onAddBlankPerson: (_) async {
            wasCalled = true;
          },
        );

        await tester.tap(find.byTooltip('Добавить карточку'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Имя'),
          'Кто-то',
        );
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();

        expect(find.text('Новый человек'), findsNothing);
        expect(wasCalled, isFalse);
      },
    );

    testWidgets(
      'picker dismissed without choosing → callback NOT called, state cleared',
      (tester) async {
        bool wasCalled = false;
        await pumpTwoPersonTree(
          tester,
          onConnectExistingPersons: (_, __, ___) {
            wasCalled = true;
          },
        );

        final sourceCenter = tester.getCenter(find.text('Анна').first);
        final targetCenter = tester.getCenter(find.text('Борис').first);

        final gesture = await tester.startGesture(sourceCenter);
        await tester.pump(const Duration(milliseconds: 380));
        await gesture.moveTo(targetCenter);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();

        expect(find.text('Кто такие друг другу?'), findsOneWidget);

        // Hit "Отмена" — picker resolves with null, no relation
        // is created, pill goes away.
        await tester.tap(find.text('Отмена'));
        await tester.pumpAndSettle();

        expect(wasCalled, isFalse);
        expect(find.text('Кто такие друг другу?'), findsNothing);
        expect(find.textContaining('Перетащите'), findsNothing);
      },
    );
  });

  testWidgets(
      'UX-T2: нынешний супруг + единственный родитель ставится рядом с супругом, не в угол',
      (tester) async {
    // Кейс Марат: Марат — нынешний супруг Гали (та заякорена своими
    // родителями в поколении-N), и при этом единственный родитель Кати
    // (N+1, без со-родителя). До фикса группа Марата не имела ни одного
    // reference-center (родители/сиблинги отсутствуют, дочь ещё не
    // размещена) и улетала в левый край. Якорь к супругу тянет Марата к Гале.
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    FamilyPerson person(String id, String name, Gender gender) => FamilyPerson(
          id: id,
          treeId: 'tree-1',
          name: name,
          gender: gender,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

    final galyaFather = person('galya-father', 'Отец Гали', Gender.male);
    final galyaMother = person('galya-mother', 'Мать Гали', Gender.female);
    final galya = person('galya', 'Галя', Gender.female);
    // Линия Гали уходит вниз (ребёнок → внук), чтобы из-за породнившихся
    // поколений Марат оказался в ОТДЕЛЬНОЙ группе на один уровень ниже Гали
    // (нынешние супруги одного уровня всегда группируются вместе — тогда
    // тест был бы пустым). Именно в таком разрыве проявлялся баг.
    final galyaKid = person('galya-kid', 'Ребёнок Гали', Gender.male);
    final galyaGrandkid = person('galya-grandkid', 'Внук Гали', Gender.male);
    final marat = person('marat', 'Марат', Gender.male);
    final katya = person('katya', 'Катя', Gender.female);

    FamilyRelation rel(
      String id,
      String a,
      String b,
      RelationType r1to2,
      RelationType r2to1,
    ) =>
        FamilyRelation(
          id: id,
          treeId: 'tree-1',
          person1Id: a,
          person2Id: b,
          relation1to2: r1to2,
          relation2to1: r2to1,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );

    final relations = [
      // Галя — дочь своих родителей (это её якорь в поколении-N).
      rel('gf', galyaFather.id, galya.id, RelationType.parent,
          RelationType.child),
      rel('gm', galyaMother.id, galya.id, RelationType.parent,
          RelationType.child),
      // Родители Гали — пара (поколение N-1).
      rel('gp', galyaFather.id, galyaMother.id, RelationType.spouse,
          RelationType.spouse),
      // Линия Гали: ребёнок (N+1) → внук (N+2).
      rel('gk', galya.id, galyaKid.id, RelationType.parent, RelationType.child),
      rel('gg', galyaKid.id, galyaGrandkid.id, RelationType.parent,
          RelationType.child),
      // Марат — нынешний супруг Гали.
      rel('sp', marat.id, galya.id, RelationType.spouse, RelationType.spouse),
      // Катя — ребёнок ТОЛЬКО Марата (без со-родителя) …
      rel('mk', marat.id, katya.id, RelationType.parent, RelationType.child),
      // … и замужем за внуком Гали — это роднит поколения и роняет Марата
      // на уровень N+1 в отдельную группу (нынешний супруг без своего
      // якоря), где раньше он улетал в левый край.
      rel('kg', katya.id, galyaGrandkid.id, RelationType.spouse,
          RelationType.spouse),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              {'person': galyaFather, 'userProfile': null},
              {'person': galyaMother, 'userProfile': null},
              {'person': galya, 'userProfile': null},
              {'person': galyaKid, 'userProfile': null},
              {'person': galyaGrandkid, 'userProfile': null},
              {'person': marat, 'userProfile': null},
              {'person': katya, 'userProfile': null},
            ],
            relations: relations,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (widget) =>
            widget is CustomPaint && widget.painter is FamilyTreePainter,
      ),
    );
    final painter = paint.painter! as FamilyTreePainter;
    final galyaOffset = painter.nodePositions[galya.id]!;
    final maratOffset = painter.nodePositions[marat.id]!;
    final katyaOffset = painter.nodePositions[katya.id]!;

    // Стабильность раскладки запутанной смешанной семьи: Марат (нынешний
    // супруг Гали + единственный родитель Кати, породнившейся с внуком Гали)
    // остаётся рядом с колонкой Гали, а не уезжает в дальний левый угол.
    // NB: на чисто синтетическом графе явные супруги всегда сводятся в одну
    // группу parity'ем _assignLevels, поэтому это guard стабильности; сам
    // разрыв на отдельные группы (где spouse-anchor и спасает от угла)
    // воспроизводится лишь на реальном backend-graphSnapshot.
    expect(
      (maratOffset.dx - galyaOffset.dx).abs(),
      lessThan(InteractiveFamilyTree.nodeWidth * 2),
    );
    // Катя — поколением ниже своего родителя Марата.
    expect(katyaOffset.dy, greaterThan(maratOffset.dy));
  });

  // B1 (adversarial-review regression): the real «Родня» shape that exposed
  // branch interleaving — Козловы pair → several children (each blood child +
  // married-in spouse) → grandchildren of varying subtree width. Asserts the
  // permanent invariant: for EVERY parent pair, no FOREIGN (non-spouse) child
  // of another pair has its dx inside that pair's child-bus span.
  testWidgets(
      'Layout: no foreign child sits inside another pair child-bus span (Родня)',
      (tester) async {
    tester.view.physicalSize = const Size(2600, 1500);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    FamilyPerson person(String id, Gender gender) => FamilyPerson(
          id: id,
          treeId: 'tree-1',
          name: id,
          gender: gender,
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        );

    var relId = 0;
    FamilyRelation parentRel(String parent, String child) => FamilyRelation(
          id: 'p${relId++}',
          treeId: 'tree-1',
          person1Id: parent,
          person2Id: child,
          relation1to2: RelationType.parent,
          relation2to1: RelationType.child,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );
    FamilyRelation spouseRel(String a, String b) => FamilyRelation(
          id: 's${relId++}',
          treeId: 'tree-1',
          person1Id: a,
          person2Id: b,
          relation1to2: RelationType.spouse,
          relation2to1: RelationType.spouse,
          isConfirmed: true,
          createdAt: DateTime(2024, 1, 1),
        );

    // L0 Козловы. L1 blood children + married-in spouses. L2/L3 grandchildren.
    final ids = <String, Gender>{
      'kozlovAA': Gender.male,
      'kozlovaA': Gender.female,
      'hodusT': Gender.female,
      'hodusA': Gender.male,
      'suprunovV': Gender.male,
      'suprunovaA': Gender.female,
      'kurbatovaG': Gender.female,
      'kurbatovV': Gender.male,
      'nazmutdinovM': Gender.male,
      'chegodaevaA': Gender.female,
      'chegodaevV': Gender.male,
      'suprunovAlex': Gender.male,
      'betehtinaM': Gender.female,
      'dmitrovaT': Gender.female,
      'dmitrovE': Gender.male,
      'nazmutdinovaE': Gender.female,
      'chegodaevVen': Gender.male,
      'chegodaevaArina': Gender.female,
      'chegodaevaAlex': Gender.female,
      'dmitrovS': Gender.male,
    };
    final relations = <FamilyRelation>[
      spouseRel('kozlovAA', 'kozlovaA'),
      // Козловы children (blood) + their married-in spouses.
      for (final c in [
        'hodusT',
        'suprunovV',
        'kurbatovaG',
        'nazmutdinovM'
      ]) ...[
        parentRel('kozlovAA', c),
        parentRel('kozlovaA', c),
      ],
      spouseRel('hodusT', 'hodusA'),
      spouseRel('suprunovV', 'suprunovaA'),
      spouseRel('kurbatovaG', 'kurbatovV'),
      // Супруновы grandchildren (a married daughter + a single son).
      for (final c in ['chegodaevaA', 'suprunovAlex']) ...[
        parentRel('suprunovV', c),
        parentRel('suprunovaA', c),
      ],
      spouseRel('chegodaevaA', 'chegodaevV'),
      // Курбатовы grandchildren incl. Бетехтина (single) + a married daughter.
      for (final c in ['betehtinaM', 'dmitrovaT']) ...[
        parentRel('kurbatovaG', c),
        parentRel('kurbatovV', c),
      ],
      spouseRel('dmitrovaT', 'dmitrovE'),
      // Назмутдинов grandchild.
      parentRel('nazmutdinovM', 'nazmutdinovaE'),
      // Great-grandchildren (Чегодаевы wide, Дмитровы narrow).
      for (final c in [
        'chegodaevVen',
        'chegodaevaArina',
        'chegodaevaAlex'
      ]) ...[
        parentRel('chegodaevaA', c),
        parentRel('chegodaevV', c),
      ],
      parentRel('dmitrovaT', 'dmitrovS'), parentRel('dmitrovE', 'dmitrovS'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InteractiveFamilyTree(
            peopleData: [
              for (final e in ids.entries)
                {'person': person(e.key, e.value), 'userProfile': null},
            ],
            relations: relations,
            onPersonTap: (_) {},
            onAddRelativeTapWithType: (_, __) {},
            currentUserIsInTree: true,
            onAddSelfTapWithType: (_, __) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final painter = tester
        .widget<CustomPaint>(find.byWidgetPredicate(
          (widget) =>
              widget is CustomPaint && widget.painter is FamilyTreePainter,
        ))
        .painter! as FamilyTreePainter;
    final pos = painter.nodePositions;

    // Invariant (ported from the throwaway topology battery): for every
    // parent pair, no foreign non-spouse child of a DIFFERENT pair sits inside
    // [min(childX)-w/2, max(childX)+w/2] at that child level.
    const w = InteractiveFamilyTree.nodeWidth;
    final childToParents = <String, Set<String>>{};
    final spouseOf = <String, Set<String>>{};
    for (final r in relations) {
      if (r.relation1to2 == RelationType.parent) {
        childToParents
            .putIfAbsent(r.person2Id, () => <String>{})
            .add(r.person1Id);
      } else if (r.relation1to2 == RelationType.spouse) {
        spouseOf.putIfAbsent(r.person1Id, () => <String>{}).add(r.person2Id);
        spouseOf.putIfAbsent(r.person2Id, () => <String>{}).add(r.person1Id);
      }
    }
    final familyChildren = <String, List<String>>{};
    childToParents.forEach((child, parents) {
      final key = (parents.toList()..sort()).join('+');
      familyChildren.putIfAbsent(key, () => <String>[]).add(child);
    });

    familyChildren.forEach((familyKey, children) {
      final placed = children.where((c) => pos[c] != null).toList();
      if (placed.isEmpty) return;
      final xs = placed.map((c) => pos[c]!.dx);
      final minX = xs.reduce((a, b) => a < b ? a : b) - w / 2;
      final maxX = xs.reduce((a, b) => a > b ? a : b) + w / 2;
      final childY = pos[placed.first]!.dy;
      for (final entry in pos.entries) {
        final id = entry.key;
        if (children.contains(id)) continue; // own child
        if ((entry.value.dy - childY).abs() > 1) continue; // other level
        // Allowed: a spouse of one of this family's children sits in-row.
        final isSpouseOfChild = placed.any(
          (c) => (spouseOf[c] ?? const <String>{}).contains(id),
        );
        if (isSpouseOfChild) continue;
        // Only foreign CHILDREN (of another pair) are interleave violations.
        if (!childToParents.containsKey(id)) continue;
        expect(
          entry.value.dx > minX && entry.value.dx < maxX,
          isFalse,
          reason:
              'foreign child "$id" (dx=${entry.value.dx.toStringAsFixed(1)}) '
              'falls inside pair [$familyKey] bus span '
              '[${minX.toStringAsFixed(1)}..${maxX.toStringAsFixed(1)}]',
        );
      }
    });
  });
}
