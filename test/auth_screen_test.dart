import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/models/auth_providers_availability.dart';
import 'package:rodnya/screens/auth_screen.dart';
import 'package:rodnya/screens/privacy_policy_screen.dart';
import 'package:rodnya/services/app_status_service.dart';

class _FakeAuthService implements AuthServiceInterface {
  String? _currentUserId;

  @override
  String? get currentUserId => _currentUserId;

  @override
  String? get currentUserEmail => null;

  @override
  String? get currentUserDisplayName => null;

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const ['password'];

  @override
  bool get currentRequiresOnboarding => false;

  @override
  Stream<String?> get authStateChanges => const Stream.empty();

  @override
  String describeError(Object error) => error.toString();

  @override
  Future<Object?> loginWithEmail(String email, String password) async {
    _currentUserId = 'user-1';
    return null;
  }

  // Ship Q3a (2026-05-26): auth_screen.initState fires
  // fetchAuthProvidersAvailability. Return null = «availability data
  // not loaded» — auth_screen falls back на legacy render-all behavior,
  // matching existing test expectations (Telegram/VK visible, MAX absent).
  @override
  Future<AuthProvidersAvailability?> fetchAuthProvidersAvailability() async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<AppStatusService>(AppStatusService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('AuthScreen shows public product entry on wide layouts',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: AuthScreen(),
      ),
    );

    await tester.pumpAndSettle();

    // Tagline now rendered as Text("Семья —") + RichText("это живое")
    // + Text("дерево.") so the italic accent on "живое" works. The
    // RichText's TextSpan isn't matched by find.text — use the bare
    // Text pieces as the smoke proof.
    expect(find.text('Семья —'), findsOneWidget);
    expect(find.text('дерево.'), findsOneWidget);
    expect(find.text('Войти'), findsWidgets);
    expect(find.text('Создать аккаунт'), findsWidgets);
    expect(find.text('Stories'), findsWidgets);
    expect(find.text('Вход'), findsWidgets);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Telegram'), findsOneWidget);
    expect(find.text('VK ID'), findsOneWidget);
    // MAX provider is hidden until the OAuth handshake actually
    // ships — see auth_screen.dart row of social buttons.
    expect(find.text('MAX'), findsNothing);
  });

  testWidgets(
    'UX audit Screen 1.1: hero visible с simulated Android call-pill viewPadding',
    (tester) async {
      // Galaxy S20 FE compact viewport.
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // Simulate active call pill — top viewPadding ~80dp (status bar
      // 24 + call pill 56). Without SafeArea minimum floor, hero
      // would clip; audit fix verifies «Семья —» wordmark rendered
      // visibly outside the system overlay area.
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            padding: EdgeInsets.only(top: 80),
            viewPadding: EdgeInsets.only(top: 80),
          ),
          child: const MaterialApp(
            home: AuthScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Hero headline pieces rendered. Tree rendering successful —
      // confirms layout не crashed под viewPadding stress AND text
      // actually present (find.text matches even if off-screen, но
      // missing widget would fail).
      expect(find.text('Семья —'), findsOneWidget);
      expect(find.text('дерево.'), findsOneWidget);

      // Verify «Семья —» вертикальный offset > 80dp (i.e., below
      // simulated call-pill area). Если SafeArea floor работает,
      // hero text starts at либо ниже top inset.
      final heroRect = tester.getRect(find.text('Семья —'));
      expect(
        heroRect.top,
        greaterThanOrEqualTo(80),
        reason: 'Hero «Семья —» должен render ниже simulated '
            'system overlay (call pill + status bar = 80dp) per '
            'SafeArea + minimum top floor fix',
      );
    },
  );

  testWidgets(
    'UX audit Screen 1.2: password field decoration allows error wrap',
    (tester) async {
      // Mobile-narrow layout — original truncation surface.
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        const MaterialApp(
          home: AuthScreen(),
        ),
      );
      await tester.pumpAndSettle();

      // Verify InputDecorator (Flutter's internal widget for each
      // TextFormField) carrying labelText='Пароль' has errorMaxLines
      // ≥ 2. Это самый прямой assert на fix surface: _fieldDecoration
      // sets errorMaxLines: 2, so validator error («Пароль должен
      // содержать не менее 6 символов» — 42 chars Cyrillic) wraps
      // вместо truncate'нуться с ellipsis.
      final decorators = tester.widgetList<InputDecorator>(
        find.byType(InputDecorator),
      );
      final passwordDecorator = decorators.firstWhere(
        (d) => d.decoration.labelText == 'Пароль',
      );
      expect(
        passwordDecorator.decoration.errorMaxLines,
        greaterThanOrEqualTo(2),
        reason: 'UX audit Screen 1.2 fix — error wraps across lines '
            'instead of ellipsis-truncating',
      );

      // Same invariant applies к Email field (any future long
      // validator copy там too will wrap).
      final emailDecorator = decorators.firstWhere(
        (d) => d.decoration.labelText == 'Email',
      );
      expect(
        emailDecorator.decoration.errorMaxLines,
        greaterThanOrEqualTo(2),
      );
    },
  );

  testWidgets('wide CTA switches auth screen into registration mode',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: AuthScreen(),
      ),
    );

    await tester.pumpAndSettle();
    await tester.tap(find.text('Создать аккаунт').first);
    await tester.pumpAndSettle();

    expect(find.text('Новый аккаунт'), findsOneWidget);
    expect(find.text('Имя'), findsOneWidget);
    expect(find.text('Создать аккаунт'), findsWidgets);
  });

  testWidgets(
      'согласие: чекбокс гейтит «Создать аккаунт», ссылка открывает /terms',
      (tester) async {
    // Мобильная раскладка — единственная форма с auth-submit ключом.
    await tester.binding.setSurfaceSize(const Size(390, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final router = GoRouter(
      initialLocation: '/auth',
      routes: [
        GoRoute(path: '/auth', builder: (context, state) => const AuthScreen()),
        GoRoute(
          path: '/terms',
          builder: (context, state) => const TermsOfUseScreen(),
        ),
        GoRoute(
          path: '/privacy',
          builder: (context, state) => const PrivacyPolicyScreen(),
        ),
      ],
    );

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();

    // В режиме входа чекбокса нет, кнопка живая.
    expect(find.byKey(const Key('auth-consent-toggle')), findsNothing);

    // Таб «Регистрация» переключает форму.
    await tester.tap(find.text('Регистрация'));
    await tester.pumpAndSettle();

    // Режим регистрации: чекбокс есть, кнопка неактивна без отметки.
    await tester.ensureVisible(find.byKey(const Key('auth-consent-toggle')));
    expect(find.textContaining('Я принимаю'), findsOneWidget);
    final submitBefore = tester.widget<FilledButton>(
      find.byKey(const Key('auth-submit')),
    );
    expect(submitBefore.onPressed, isNull,
        reason: 'без согласия регистрация заблокирована');

    // Отметка — кнопка оживает. Целимся в сам Checkbox: центр строки
    // занят tap-ссылками на документы.
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    final submitAfter = tester.widget<FilledButton>(
      find.byKey(const Key('auth-submit')),
    );
    expect(submitAfter.onPressed, isNotNull);

    // Ссылка в тексте согласия ведёт на /terms — экран соглашения
    // открывается (10 разделов, заголовок совпадает).
    final richText = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('auth-consent-toggle')),
            matching: find.byType(Text),
          )
          .first,
    );
    // Тапаем по координате начала ссылки «Пользовательское соглашение» —
    // надёжнее через recognizer напрямую: ищем span и дергаем onTap.
    final span = richText.textSpan! as TextSpan;
    final termsSpan = span.children!
        .whereType<TextSpan>()
        .firstWhere((s) => s.text == 'Пользовательское соглашение');
    (termsSpan.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pumpAndSettle();

    expect(find.text('1. Общие положения'), findsOneWidget);
    expect(find.text('7. Соблюдение законодательства РФ'), findsOneWidget);
  });

  testWidgets('AuthScreen keeps login form first on mobile layouts',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      const MaterialApp(
        home: AuthScreen(),
      ),
    );

    await tester.pumpAndSettle();

    // Tagline now rendered as Text("Семья —") + RichText("это живое")
    // + Text("дерево.") so the italic accent on "живое" works. The
    // RichText's TextSpan isn't matched by find.text — use the bare
    // Text pieces as the smoke proof.
    expect(find.text('Семья —'), findsOneWidget);
    expect(find.text('дерево.'), findsOneWidget);
    expect(find.text('Вход'), findsWidgets);
    expect(find.text('Регистрация'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    // Density chunk 18: compact hero subtitle collapsed to a single
    // line (was a forced 2-line "\n" string) so the hero fits ≤170dp —
    // wide/desktop keeps the original 2-line copy (see the wide-layout
    // test above for that string).
    expect(
      find.text('Истории, лица и даты — всё в одном месте.'),
      findsOneWidget,
    );
    expect(find.text('Дерево, родные и чат в одном аккаунте.'), findsNothing);
    // Feature cards (Дерево / Родные / Чат / Stories) used to live in
    // the compact hero too. Reference design intentionally keeps the
    // mobile hero minimal — just brand + tagline + subtitle — so they
    // are now wide-layout only. The auth form below carries the social
    // CTAs which are the actionable surface.
    //
    // Ship Q3 (2026-05-26): Google button HIDDEN когда provider не
    // configured (UX audit 2026-05-25 Critical #3). _FakeAuthService
    // не is CustomApiAuthService → _supportsGoogleAuth=false → no button.
    expect(find.text('Google'), findsNothing);
    expect(find.text('Telegram'), findsOneWidget);
  });

  testWidgets('AuthScreen respects deferred route after successful login',
      (tester) async {
    final authService = getIt<AuthServiceInterface>() as _FakeAuthService;

    final router = GoRouter(
      initialLocation: '/login?from=%2Fchats',
      routes: [
        GoRoute(
          path: '/login',
          builder: (context, state) => AuthScreen(
            redirectAfterLogin: state.uri.queryParameters['from'],
          ),
        ),
        GoRoute(
          path: '/chats',
          builder: (context, state) => const Text('chats-screen'),
        ),
        GoRoute(
          path: '/',
          builder: (context, state) => const Text('home-screen'),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp.router(routerConfig: router),
    );

    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).at(0), 'user@test.dev');
    await tester.enterText(find.byType(TextFormField).at(1), 'password123');
    final submitButton = find.descendant(
      of: find.byType(Form),
      matching: find.widgetWithText(FilledButton, 'Войти'),
    );
    await tester.ensureVisible(submitButton);
    await tester.tap(submitButton);
    await tester.pumpAndSettle();

    expect(authService.currentUserId, 'user-1');
    expect(find.text('chats-screen'), findsOneWidget);
    expect(find.text('home-screen'), findsNothing);
  });

  testWidgets('AuthScreen clears stale session banner on reauth input',
      (tester) async {
    final appStatusService = getIt<AppStatusService>();
    appStatusService.reportSessionExpired();

    await tester.pumpWidget(
      const MaterialApp(
        home: AuthScreen(),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Сессия истекла. Войдите снова.'), findsOneWidget);
    expect(appStatusService.hasSessionIssue, isTrue);

    await tester.enterText(find.byType(TextFormField).at(0), 'user@test.dev');
    await tester.pump();

    expect(appStatusService.hasSessionIssue, isFalse);
    expect(find.text('Сессия истекла. Войдите снова.'), findsNothing);
  });
}
