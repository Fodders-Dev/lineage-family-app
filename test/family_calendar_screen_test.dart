// Calendar v1 (A): the month grid renders, a day with an event surfaces
// its EventCard on selection, an empty day shows the hint.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/models/app_event.dart';
import 'package:rodnya/models/family_person.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/screens/family_calendar_screen.dart';
import 'package:rodnya/services/event_service.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/utils/moon_phase.dart';
import 'package:rodnya/widgets/event_card.dart';

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService({required this.relatives});

  final List<FamilyPerson> relatives;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async => relatives;

  @override
  Future<List<FamilyRelation>> getRelations(String treeId) async =>
      const <FamilyRelation>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// EventService whose month fetch always throws — drives the CP-2 error
/// state (the real service now lets errors propagate).
class _ThrowingEventService extends EventService {
  _ThrowingEventService()
      : super(familyTreeService: _FakeFamilyTreeService(relatives: const []));

  @override
  Future<List<AppEvent>> getEventsForMonth(String t, int y, int m) async {
    throw Exception('network down');
  }
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  Widget host(EventService service) => MaterialApp(
        theme: AppTheme.lightTheme,
        home: FamilyCalendarScreen(
          serviceOverride: service,
          treeId: 'tree-1',
          initialMonth: DateTime(2026, 4, 15),
        ),
      );

  testWidgets(
    'renders the month grid; tapping a day with an event shows its EventCard',
    (tester) async {
      final service = EventService(
        familyTreeService: _FakeFamilyTreeService(
          relatives: [
            FamilyPerson(
              id: 'p1',
              treeId: 'tree-1',
              name: 'Иван Петров',
              gender: Gender.male,
              birthDate: DateTime(1990, 4, 3), // birthday on April 3
              isAlive: true,
              createdAt: DateTime(2024, 1, 1),
              updatedAt: DateTime(2024, 1, 1),
            ),
          ],
        ),
      );

      await tester.pumpWidget(host(service));
      await tester.pumpAndSettle();

      // Grid present.
      expect(find.byType(TableCalendar<AppEvent>), findsOneWidget);
      // Apr 15 is selected initially and has no event → hint, no card.
      expect(find.text('В этот день событий нет'), findsOneWidget);
      expect(find.byType(EventCard), findsNothing);

      // Tap April 3 (the birthday). outsideDaysVisible:false → «3» is the
      // single April-3 cell.
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();

      expect(find.byType(EventCard), findsOneWidget);
      expect(find.text('День рождения'), findsOneWidget);
    },
  );

  // ── CP-a: tap a holiday → info; family event → profile (unchanged) ──

  Widget routerHost(EventService service, {required DateTime initialMonth}) {
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => FamilyCalendarScreen(
            serviceOverride: service,
            treeId: 'tree-1',
            initialMonth: initialMonth,
          ),
        ),
        GoRoute(
          path: '/relative/details/:id',
          builder: (_, state) => Scaffold(
            body: Text('profile-${state.pathParameters['id']}'),
          ),
        ),
      ],
    );
    return MaterialApp.router(theme: AppTheme.lightTheme, routerConfig: router);
  }

  testWidgets('tapping a holiday shows its info bottom-sheet', (tester) async {
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );
    await tester.pumpWidget(
      routerHost(service, initialMonth: DateTime(2026, 5, 9)),
    );
    await tester.pumpAndSettle();

    // May 9 selected → «День Победы» card.
    expect(find.text('День Победы'), findsOneWidget);
    await tester.tap(find.text('День Победы'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('holiday-info-sheet')), findsOneWidget);
    expect(find.textContaining('Великой Отечественной'), findsOneWidget);
  });

  testWidgets(
    'tapping a family event opens the profile, not a holiday sheet',
    (tester) async {
      final service = EventService(
        familyTreeService: _FakeFamilyTreeService(
          relatives: [
            FamilyPerson(
              id: 'p1',
              treeId: 'tree-1',
              name: 'Иван Петров',
              gender: Gender.male,
              birthDate: DateTime(1990, 5, 9), // birthday on May 9
              isAlive: true,
              createdAt: DateTime(2024, 1, 1),
              updatedAt: DateTime(2024, 1, 1),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        routerHost(service, initialMonth: DateTime(2026, 5, 9)),
      );
      await tester.pumpAndSettle();

      expect(find.text('День рождения'), findsOneWidget);
      await tester.tap(find.text('День рождения'));
      await tester.pumpAndSettle();

      // Navigated to the profile; no holiday sheet.
      expect(find.text('profile-p1'), findsOneWidget);
      expect(find.byKey(const Key('holiday-info-sheet')), findsNothing);
    },
  );

  testWidgets('empty tree shows the no-events hint', (tester) async {
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );
    await tester.pumpWidget(host(service));
    await tester.pumpAndSettle();

    expect(find.byType(TableCalendar<AppEvent>), findsOneWidget);
    expect(find.text('В этот день событий нет'), findsOneWidget);
    expect(find.byType(EventCard), findsNothing);
    // M1: постоянная легенда фаз убрана — фаза дня живёт в tip-полосе.
    expect(find.text('🌑 Новолуние'), findsNothing);
    expect(find.text('🌕 Полнолуние'), findsNothing);
    // Moon gardening tip (CP-b) for the selected day is shown.
    expect(find.byKey(const Key('moon-tip')), findsOneWidget);
    final tip = gardeningTip(moonPhaseFor(DateTime(2026, 4, 15)));
    expect(find.text(tip), findsOneWidget);
  });

  // ── K2: тумблер Месяц|Список, agenda, «Сегодня», создание встречи ──

  testWidgets('K2: тумблер переключает на agenda-список с группировкой',
      (tester) async {
    final now = DateTime.now();
    // День рождения через ~5 дней — гарантированно в окне 90 дней.
    final birthday = now.add(const Duration(days: 5));
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(
        relatives: [
          FamilyPerson(
            id: 'p1',
            treeId: 'tree-1',
            name: 'Иван Петров',
            gender: Gender.male,
            birthDate: DateTime(1955, birthday.month, birthday.day),
            isAlive: true,
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
          ),
        ],
      ),
    );

    await tester.pumpWidget(host(service));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('calendar-view-month')), findsOneWidget);
    expect(find.byKey(const Key('calendar-view-list')), findsOneWidget);

    await tester.tap(find.byKey(const Key('calendar-view-list')));
    await tester.pumpAndSettle();

    // Agenda на месте: сетки нет, список с днём рождения и бейджем
    // категории; «исполнится N» — возраст.
    expect(find.byType(TableCalendar<AppEvent>), findsNothing);
    expect(find.byKey(const Key('calendar-agenda-list')), findsOneWidget);
    expect(find.text('Иван Петров'), findsOneWidget);
    expect(find.textContaining('исполнится'), findsOneWidget);
    expect(find.text('Родня'), findsWidgets);
    // K3: в окно 90 дней всегда попадает хотя бы один праздник каждой
    // «народной» волны — бейджи категорий различимы в списке.
    expect(
      find.text('Народный').evaluate().isNotEmpty ||
          find.text('Россия').evaluate().isNotEmpty ||
          find.text('Православие').evaluate().isNotEmpty,
      isTrue,
      reason: 'в agenda должны быть бейджи праздничных категорий',
    );

    // Назад в месяц.
    await tester.tap(find.byKey(const Key('calendar-view-month')));
    await tester.pumpAndSettle();
    expect(find.byType(TableCalendar<AppEvent>), findsOneWidget);
  });

  testWidgets('K2: кнопка «Сегодня» возвращает из чужого месяца к текущему',
      (tester) async {
    final now = DateTime.now();
    final farMonth = DateTime(now.year, now.month - 2, 15);
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FamilyCalendarScreen(
          serviceOverride: service,
          treeId: 'tree-1',
          initialMonth: farMonth,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Юзер «ушёл» от текущего месяца → кнопка видна.
    final todayButton = find.byKey(const Key('calendar-today'));
    expect(todayButton, findsOneWidget);

    await tester.tap(todayButton);
    await tester.pumpAndSettle();

    // Вернулись к текущему месяцу: кнопка исчезла (фокус снова «сегодня»).
    expect(find.byKey(const Key('calendar-today')), findsNothing);
  });

  testWidgets(
      'K2: «Создать встречу» из дня (включая пустой) открывает композер с датой',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    String? pushedLocation;
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => FamilyCalendarScreen(
            serviceOverride: service,
            treeId: 'tree-1',
            initialMonth: DateTime(2026, 4, 15),
          ),
        ),
        GoRoute(
          path: '/gathering/create',
          builder: (_, state) {
            pushedLocation = state.uri.toString();
            return const Scaffold(body: Text('composer-stub'));
          },
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.lightTheme, routerConfig: router),
    );
    await tester.pumpAndSettle();

    // Пустой день: вход в создание есть и здесь.
    expect(find.text('В этот день событий нет'), findsOneWidget);
    final createButton = find.byKey(const Key('calendar-create-gathering'));
    expect(createButton, findsOneWidget);

    await tester.ensureVisible(createButton);
    await tester.pumpAndSettle();
    await tester.tap(createButton);
    await tester.pumpAndSettle();

    expect(find.text('composer-stub'), findsOneWidget);
    expect(pushedLocation, '/gathering/create?date=2026-04-15');
  });

  testWidgets('K2: создание встречи не перекрывает события', (tester) async {
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );
    await tester.pumpWidget(host(service));
    await tester.pumpAndSettle();

    final createAction = find.byKey(const Key('calendar-create-gathering'));
    expect(createAction, findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(
      find.ancestor(of: createAction, matching: find.byType(AppBar)),
      findsOneWidget,
    );
    final bodyRect = tester.getRect(find.byKey(const Key('calendar-body')));
    final appBarRect = tester.getRect(find.byType(AppBar));
    expect(appBarRect.bottom <= bodyRect.top, isTrue);
    expect(bodyRect.overlaps(appBarRect), isFalse);
  });

  testWidgets(
      'M1: число дня на принципиальный лунный день читаемо, эмодзи в сетке нет',
      (tester) async {
    // Дни месяца считаем той же чистой функцией, что и прод — тест
    // детерминирован без зашитых эфемерид.
    final days = List.generate(30, (i) => DateTime(2026, 4, i + 1));
    final lunarDay = days.firstWhere(isPrincipalMoonDay);
    // Выбранный день — обычный (не лунный) и с ДРУГОЙ фазой, чтобы глиф
    // лунного дня не мог прийти из tip-полосы.
    final plainDay = days.firstWhere(
      (d) =>
          !isPrincipalMoonDay(d) && moonPhaseFor(d) != moonPhaseFor(lunarDay),
    );

    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FamilyCalendarScreen(
          serviceOverride: service,
          treeId: 'tree-1',
          initialMonth: plainDay,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Число лунного дня в сетке — одно и читаемое (раньше эмодзи-глиф на
    // Samsung закрашивал его).
    expect(find.text('${lunarDay.day}'), findsOneWidget);
    // Эмодзи-глифа лунной фазы в ячейках больше нет (tip показывает фазу
    // plainDay — другую по построению).
    expect(find.text(moonPhaseFor(lunarDay).glyph), findsNothing);
  });

  testWidgets('shows error + «Повторить» when the month fails to load (CP-2)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FamilyCalendarScreen(
          serviceOverride: _ThrowingEventService(),
          treeId: 'tree-1',
          initialMonth: DateTime(2026, 4, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Не удалось загрузить'), findsOneWidget);
    expect(find.byKey(const Key('calendar-retry')), findsOneWidget);
  });

  testWidgets('shows «Выберите дерево» when no tree is bound (CP-2)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FamilyCalendarScreen(
          serviceOverride: EventService(
            familyTreeService: _FakeFamilyTreeService(relatives: const []),
          ),
          treeId: '', // no tree bound
          initialMonth: DateTime(2026, 4, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Выберите дерево'), findsOneWidget);
    expect(find.byKey(const Key('calendar-no-tree-cta')), findsOneWidget);
  });

  testWidgets('day with more than 3 events shows a «+N» marker (CP-6)',
      (tester) async {
    // Four people share an April-3 birthday → 4 events that day.
    final relatives = [
      for (var i = 0; i < 4; i++)
        FamilyPerson(
          id: 'p$i',
          treeId: 'tree-1',
          name: 'Человек $i',
          gender: Gender.male,
          birthDate: DateTime(1990 - i, 4, 3),
          isAlive: true,
          createdAt: DateTime(2024, 1, 1),
          updatedAt: DateTime(2024, 1, 1),
        ),
    ];
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: relatives),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: FamilyCalendarScreen(
          serviceOverride: service,
          treeId: 'tree-1',
          initialMonth: DateTime(2026, 4, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 3 dots + «+1» overflow hint on April 3.
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('renders in dark theme without error (CP-1 legibility)',
      (tester) async {
    final service = EventService(
      familyTreeService: _FakeFamilyTreeService(relatives: const []),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: FamilyCalendarScreen(
          serviceOverride: service,
          treeId: 'tree-1',
          initialMonth: DateTime(2026, 4, 15),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TableCalendar<AppEvent>), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
