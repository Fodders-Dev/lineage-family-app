// Density invariant (чанк 24 — «Новый опрос»): на пустой форме CTA
// «Создать опрос» должен помещаться в верхние 800dp экрана 412×915,
// dpr 3 — тот же приём, что у CreateGatheringScreen (чанк 24): CTA —
// PillButton 52dp в конце прокручиваемой формы вместо AppBar-action,
// поля 50dp, варианты ответа — строки 50dp с «+ добавить вариант» 44dp.
//
// Promoted from a throwaway measurement probe used while redesigning
// lib/screens/create_poll_screen.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/circle_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/poll_service_interface.dart';
import 'package:rodnya/models/circle.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_tree.dart';
import 'package:rodnya/screens/create_poll_screen.dart';

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

class _NoopPollService implements PollServiceInterface {
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
    getIt.registerSingleton<PollServiceInterface>(_NoopPollService());
    getIt.registerSingleton<CircleServiceInterface>(_FakeCircleService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(_FakeTreeService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'CreatePollScreen (чанк 24): CTA на пустой форме ≤800dp на 412×915',
    (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: CreatePollScreen(treeId: 'tree-1')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final ctaRect = tester.getRect(find.byKey(const Key('poll-submit')));
      expect(
        ctaRect.bottom,
        lessThanOrEqualTo(800),
        reason: 'Низ CTA «Создать опрос» должен помещаться в верхние '
            '800dp экрана 412×915 на пустой форме — см. чанк 24. '
            'Замерено: ${ctaRect.bottom}.',
      );
    },
  );
}
