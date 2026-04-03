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

    expect(
      find.text('Семейное дерево для близких, а не для дев-стенда'),
      findsOneWidget,
    );
    expect(find.text('Войти сейчас'), findsOneWidget);
    expect(find.text('Создать семейный круг'), findsOneWidget);
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
    await tester.tap(find.text('Создать семейный круг'));
    await tester.pumpAndSettle();

    expect(find.text('Создать аккаунт'), findsOneWidget);
    expect(find.text('Как вас зовут'), findsOneWidget);
    expect(find.text('Зарегистрироваться'), findsOneWidget);
  });
}
