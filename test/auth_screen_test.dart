import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/screens/auth_screen.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => null;

  @override
  String? get currentUserEmail => null;

  @override
  String? get currentUserDisplayName => null;

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

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
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

    expect(find.text('Семейное дерево и связи для близких'), findsOneWidget);
    expect(find.text('Войти сейчас'), findsOneWidget);
    expect(find.text('Зарегистрироваться'), findsOneWidget);
    expect(find.text('Публичный вход с web'), findsOneWidget);
    expect(find.text('Вход в Родню'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
  });

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
    await tester.tap(find.text('Зарегистрироваться'));
    await tester.pumpAndSettle();

    expect(find.text('Создать аккаунт'), findsOneWidget);
    expect(find.text('Как вас зовут'), findsOneWidget);
    expect(find.text('Зарегистрироваться'), findsWidgets);
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

    expect(find.text('Вход в Родню'), findsOneWidget);
    expect(find.text('Вход'), findsOneWidget);
    expect(find.text('Регистрация'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Дерево, родные и чат в одном аккаунте.'), findsOneWidget);
    expect(find.text('После входа'), findsNothing);
    expect(find.text('Дерево'), findsOneWidget);
    expect(find.text('Родные'), findsOneWidget);
    expect(find.text('Чат'), findsOneWidget);
    expect(find.text('Семейное дерево и связи для близких'), findsNothing);
  });
}
