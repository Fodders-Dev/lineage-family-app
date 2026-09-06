// Density chunk 21 invariant test — registration step 2
// (CompleteProfileScreen) must fit a 412x915 dp phone without the
// hero intro or the primary CTA eating the screen. Before this chunk
// the hero (gradient cover + «Добро пожаловать» badge + card-in-card)
// measured ~337dp tall and the empty-form primary CTA («Сохранить и
// продолжить») bottomed out at ~886dp — below the fold entirely, with
// the «Кто я» / «Как с вами связаться» sections needing a scroll just
// to reach them. See chunk 21 report for the full before/after table.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/profile_service_interface.dart';
import 'package:rodnya/backend/models/profile_form_data.dart';
import 'package:rodnya/backend/models/tree_invitation.dart';
import 'package:rodnya/screens/complete_profile_screen.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-2';

  @override
  String? get currentUserEmail => 'shuflyak.nastya@yandex.ru';

  @override
  String? get currentUserDisplayName => 'Анастасия Шуфляк';

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const ['password'];

  @override
  Stream<String?> get authStateChanges => const Stream.empty();

  @override
  String describeError(Object error) => error.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileService implements ProfileServiceInterface {
  // Empty form — the DoD target («главная кнопка ≤ 860dp») is measured
  // with a blank registration form, matching the real first-launch state.
  ProfileFormData savedData = const ProfileFormData(
    userId: 'user-2',
    firstName: '',
    lastName: '',
  );

  @override
  Future<ProfileFormData> getCurrentUserProfileFormData() async => savedData;

  @override
  Future<void> saveCurrentUserProfileFormData(ProfileFormData data) async {
    savedData = data;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  @override
  Stream<List<TreeInvitation>> getPendingTreeInvitations() =>
      Stream.value(const <TreeInvitation>[]);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ProfileServiceInterface>(_FakeProfileService());
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(),
    );
  });

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'density chunk 21: hero / sections / CTA fit above the fold on 412x915 (empty form)',
    (tester) async {
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final router = GoRouter(
        initialLocation: '/complete_profile',
        routes: [
          GoRoute(
            path: '/complete_profile',
            builder: (context, state) => const CompleteProfileScreen(),
          ),
          GoRoute(
            path: '/trees',
            builder: (context, state) => Scaffold(
              body: Text('trees ${state.uri.queryParameters['tab']}'),
            ),
          ),
        ],
      );

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      final heroRect =
          tester.getRect(find.byKey(const Key('complete-profile-hero')));
      expect(
        heroRect.height,
        lessThanOrEqualTo(90),
        reason: 'Hero-вступление не должно занимать больше 90dp (до чанка '
            '21 было ~337dp — градиент-кавер + плашка «Добро пожаловать» + '
            'карточка-в-карточке).',
      );

      final ctaRect = tester
          .getRect(find.byKey(const Key('complete-profile-save-cta')));
      expect(
        ctaRect.bottom,
        lessThanOrEqualTo(860),
        reason: 'Низ главной кнопки «Сохранить и продолжить» должен '
            'помещаться в верхние 860dp экрана 412×915 на пустой форме '
            '(до чанка 21 было ~886dp).',
      );

      // «Кто я» и «Как с вами связаться» должны быть видны без
      // прокрутки — оба заголовка секций должны попадать выше низа
      // главной кнопки (сама кнопка — граница «ниже сгиба» для этого
      // экрана).
      final identityHeaderRect = tester.getRect(find.text('КТО Я'));
      final contactsHeaderRect =
          tester.getRect(find.text('КАК С ВАМИ СВЯЗАТЬСЯ'));
      expect(identityHeaderRect.top, lessThanOrEqualTo(ctaRect.bottom));
      expect(contactsHeaderRect.top, lessThanOrEqualTo(ctaRect.bottom));

      // Строка телефона: «+7» и поле ввода должны сидеть на одной
      // базовой линии (одна и та же высота 50dp, тот же шрифт-токен).
      final phoneFieldRect = tester.getRect(
        find.widgetWithText(TextFormField, '999 123 45 67'),
      );
      final phonePlusRect = tester.getRect(find.text('+7').last);
      expect(
        (phoneFieldRect.top - phonePlusRect.top).abs(),
        lessThanOrEqualTo(2),
        reason: '«+7» и поле телефона должны быть на одной высоте — '
            'разъезжаться по вертикали им нельзя.',
      );
    },
  );
}
