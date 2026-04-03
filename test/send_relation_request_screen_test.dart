import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/profile_service_interface.dart';
import 'package:lineage/models/user_profile.dart';
import 'package:lineage/screens/send_relation_request_screen.dart';

class _FakeProfileService implements ProfileServiceInterface {
  _FakeProfileService(this.results);

  final List<UserProfile> results;

  @override
  Future<List<UserProfile>> searchUsers(String query, {int limit = 10}) async {
    return results;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  String? invitedTreeId;
  String? invitedUserId;

  @override
  Future<void> sendTreeInvitation({
    required String treeId,
    String? recipientUserId,
    String? recipientEmail,
    String? relationToTree,
  }) async {
    invitedTreeId = treeId;
    invitedUserId = recipientUserId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets(
    'SendRelationRequestScreen sends a tree invitation to an existing Rodnya user',
    (tester) async {
      final familyService = _FakeFamilyTreeService();
      getIt.registerSingleton<ProfileServiceInterface>(
        _FakeProfileService([
          UserProfile(
            id: 'user-2',
            email: 'shuflyak.nastya@yandex.ru',
            displayName: 'Анастасия Шуфляк',
            username: 'nastya',
            phoneNumber: '',
            createdAt: DateTime(2026, 4, 3),
          ),
        ]),
      );
      getIt.registerSingleton<FamilyTreeServiceInterface>(familyService);

      await tester.pumpWidget(
        const MaterialApp(
          home: SendRelationRequestScreen(treeId: 'tree-1'),
        ),
      );

      expect(find.text('Пригласить в дерево'), findsOneWidget);
      expect(
        find.textContaining('именно приглашение в дерево'),
        findsOneWidget,
      );

      await tester.enterText(find.byType(TextField), 'настя');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.text('Анастасия Шуфляк'), findsWidgets);

      await tester.tap(find.text('Анастасия Шуфляк').first);
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Отправить приглашение'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отправить приглашение'));
      await tester.pumpAndSettle();

      expect(familyService.invitedTreeId, 'tree-1');
      expect(familyService.invitedUserId, 'user-2');
    },
  );
}
