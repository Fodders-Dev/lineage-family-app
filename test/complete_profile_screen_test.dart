import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/profile_service_interface.dart';
import 'package:lineage/backend/models/profile_form_data.dart';
import 'package:lineage/backend/models/tree_invitation.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/screens/complete_profile_screen.dart';

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
  ProfileFormData savedData = const ProfileFormData(
    userId: 'user-2',
    firstName: 'Анастасия',
    lastName: 'Шуфляк',
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
  Stream<List<TreeInvitation>> getPendingTreeInvitations() => Stream.value([
        TreeInvitation(
          invitationId: 'invite-1',
          tree: FamilyTree(
            id: 'tree-1',
            name: 'Rodnya QA Invite',
            description: '',
            creatorId: 'user-1',
            memberIds: const ['user-1'],
            createdAt: DateTime(2026, 4, 3),
            updatedAt: DateTime(2026, 4, 3),
            isPrivate: true,
            members: const ['user-1'],
          ),
        ),
      ]);

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

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'CompleteProfileScreen ведёт к приглашениям после сохранения профиля',
    (tester) async {
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

      await tester.enterText(
        find.bySemanticsLabel('Имя пользователя (username)'),
        'shuflyak.nastya',
      );
      await tester.enterText(
        find.bySemanticsLabel('Номер телефона'),
        '9010001122',
      );

      await tester.ensureVisible(find.text('Сохранить профиль'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить профиль'));
      await tester.pumpAndSettle();

      expect(find.text('trees invitations'), findsOneWidget);
    },
  );
}
