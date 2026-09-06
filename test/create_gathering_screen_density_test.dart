// Density invariant (чанк 24 — «Новая встреча»): на пустой форме CTA
// «Создать встречу» должен помещаться в верхние 800dp экрана 412×915,
// dpr 3. До чанка 24 «Создать» жило в AppBar-action (всегда видимо, но
// без явного CTA) — теперь это PillButton 52dp внизу прокручиваемой
// формы, как в CompleteProfileScreen (чанк 21) / AuthScreen (чанк 18);
// межсекционные зазоры сжаты до 10/8dp (не эталонных 14 — AudiencePicker
// в «Кого зовём?» сам по себе держит ~106dp даже без кругов), иначе CTA
// не укладывался в бюджет.
//
// Promoted from a throwaway measurement probe used while redesigning
// lib/screens/create_gathering_screen.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/circle_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/gathering_service_interface.dart';
import 'package:rodnya/models/circle.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/screens/create_gathering_screen.dart';

class _FakeCircleService implements CircleServiceInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<List<FamilyCircle>> getCircles(String treeId) async => const [];
}

class _FakeTreeService implements FamilyTreeServiceInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => const [];
  @override
  Future<List<FamilyTree>> getUserTrees() async => const [];
}

class _NoopGatheringService implements GatheringServiceInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<GatheringServiceInterface>(_NoopGatheringService());
    getIt.registerSingleton<CircleServiceInterface>(_FakeCircleService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(_FakeTreeService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'CreateGatheringScreen (чанк 24): CTA на пустой форме ≤800dp на 412×915',
    (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: CreateGatheringScreen(treeId: 'tree-1')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final ctaRect =
          tester.getRect(find.byKey(const Key('gathering-submit')));
      expect(
        ctaRect.bottom,
        lessThanOrEqualTo(800),
        reason: 'Низ CTA «Создать встречу» должен помещаться в верхние '
            '800dp экрана 412×915 на пустой форме — см. чанк 24. '
            'Замерено: ${ctaRect.bottom}.',
      );
    },
  );
}
