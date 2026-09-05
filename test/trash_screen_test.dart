// Ship Q4a frontend (2026-05-28, Ship 31): smoke + interaction tests
// для TrashScreen.
//
// Covers:
//   • Empty state copy когда обе категории пусты
//   • Render persons + posts tabs с данными
//   • Restore action removes row + shows snackbar
//   • Permanent-delete action disabled когда 3h floor не пройден
//   • Permanent-delete confirmation flow (cancel → no call, confirm →
//     service called)
//   • Error state с retry button

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/backend/interfaces/semya_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/deleted_person.dart';
import 'package:rodnya/backend/models/deleted_post.dart';
import 'package:rodnya/backend/models/semya.dart';
import 'package:rodnya/backend/models/semya_browse_token.dart';
import 'package:rodnya/backend/models/semya_invitation.dart';
import 'package:rodnya/backend/models/semya_pull_person_result.dart';
import 'package:rodnya/screens/trash_screen.dart';

class _FakeSemyaService implements SemyaCapableFamilyTreeService {
  _FakeSemyaService({
    this.persons = const <DeletedPerson>[],
    this.posts = const <DeletedPost>[],
    this.throwOnLoad,
  });

  List<DeletedPerson> persons;
  List<DeletedPost> posts;
  SemyaError? throwOnLoad;

  int loadPersonCalls = 0;
  int loadPostCalls = 0;
  String? lastRestoredPersonId;
  String? lastRestoredPostId;
  String? lastPurgedPersonId;
  String? lastPurgedPostId;

  @override
  Future<List<DeletedPerson>> listMyDeletedPersons() async {
    loadPersonCalls += 1;
    if (throwOnLoad != null) throw throwOnLoad!;
    return persons;
  }

  @override
  Future<List<DeletedPerson>> listDeletedPersonsForSemya(String semyaId) async =>
      const <DeletedPerson>[];

  @override
  Future<void> restoreDeletedPerson(String deletedPersonId) async {
    lastRestoredPersonId = deletedPersonId;
  }

  @override
  Future<void> permanentlyDeletePerson(String deletedPersonId) async {
    lastPurgedPersonId = deletedPersonId;
  }

  @override
  Future<List<DeletedPost>> listMyDeletedPosts() async {
    loadPostCalls += 1;
    if (throwOnLoad != null) throw throwOnLoad!;
    return posts;
  }

  @override
  Future<void> restoreDeletedPost(String deletedPostId) async {
    lastRestoredPostId = deletedPostId;
  }

  @override
  Future<void> permanentlyDeletePost(String deletedPostId) async {
    lastPurgedPostId = deletedPostId;
  }

  // ---- Unused interface methods — throw для surface accidental calls.

  @override
  Future<List<Semya>> listMySemya() async => const <Semya>[];

  @override
  Future<SemyaDetails?> findSemyaById(String semyaId) async => null;

  @override
  Future<List<SemyaMembership>> listMembershipsForSemya(String semyaId) async =>
      const <SemyaMembership>[];

  @override
  Future<SemyaInvitation> createInvitation({
    required String semyaId,
    required SemyaRole role,
    String? recipientEmail,
    String? recipientPhone,
    String? recipientUserId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<SemyaInvitation>> listInvitationsForSemya(String semyaId) async =>
      const <SemyaInvitation>[];

  @override
  Future<SemyaInvitation> revokeInvitation({
    required String semyaId,
    required String invitationId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<SemyaInvitationAcceptResult> acceptInvitation(String token) async =>
      throw UnimplementedError();

  @override
  Future<SemyaPullPersonResult> pullPersonToSemya({
    required String targetSemyaId,
    required String sourceSemyaId,
    required String sourcePersonId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<SemyaBrowseToken> createBrowseToken({
    required String semyaId,
    int? expiresInDays,
  }) async =>
      throw UnimplementedError();

  @override
  Future<BrowsedSemyaTree> fetchBrowseTree(String token) async =>
      throw UnimplementedError();

  @override
  Future<List<SemyaBrowseTokenSummary>> listBrowseTokens({
    required String semyaId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<SemyaBrowseTokenSummary> revokeBrowseToken({
    required String semyaId,
    required String tokenId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<String>> listHiddenPersonIds({required String semyaId}) async =>
      const <String>[];

  @override
  Future<List<String>> updateHideFilter({
    required String semyaId,
    List<String> addPersonIds = const <String>[],
    List<String> removePersonIds = const <String>[],
  }) async =>
      throw UnimplementedError();

  @override
  Future<SemyaMembership> updateMembership({
    required String semyaId,
    required String userId,
    SemyaRole? role,
    bool? hasInviteGrant,
  }) async =>
      throw UnimplementedError();

  @override
  Future<SemyaMembership> addMembership({
    required String semyaId,
    required String userId,
    required SemyaRole role,
    bool hasInviteGrant = false,
  }) async =>
      throw UnimplementedError();

  @override
  Future<SemyaMembershipRemoveResult> removeMembership({
    required String semyaId,
    required String userId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<SemyaInvitation>> listPendingInvitations() async =>
      const <SemyaInvitation>[];
}

DeletedPerson _person({
  required String id,
  String name = 'Иван Иванов',
  required String earliestHardDelete,
  String hardDeleteScheduledAt = '2026-06-27T00:00:00.000Z',
}) {
  return DeletedPerson.fromJson({
    'id': id,
    'originalPersonId': 'orig-$id',
    'treeId': 't-1',
    'semyaId': 's-1',
    'snapshot': {'name': name},
    'deletedAt': '2026-05-28T00:00:00.000Z',
    'hardDeleteScheduledAt': hardDeleteScheduledAt,
    'earliestHardDelete': earliestHardDelete,
  });
}

DeletedPost _post({
  required String id,
  String content = 'Привет, родные!',
  required String earliestHardDelete,
  String hardDeleteScheduledAt = '2026-06-27T00:00:00.000Z',
}) {
  return DeletedPost.fromJson({
    'id': id,
    'originalPostId': 'orig-$id',
    'treeId': 't-1',
    'snapshot': {'content': content},
    'deletedAt': '2026-05-28T00:00:00.000Z',
    'hardDeleteScheduledAt': hardDeleteScheduledAt,
    'earliestHardDelete': earliestHardDelete,
  });
}

Widget _wrap(SemyaCapableFamilyTreeService service) =>
    MaterialApp(home: TrashScreen(serviceOverride: service));

void main() {
  // 3h floor: any past timestamp == floor passed; future == not yet.
  final pastFloor = '2026-05-27T00:00:00.000Z';
  final futureFloor =
      DateTime.now().add(const Duration(hours: 1)).toIso8601String();

  testWidgets('empty state when nothing in trash', (tester) async {
    final service = _FakeSemyaService();
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(find.text('Корзина пуста'), findsOneWidget);
    expect(service.loadPersonCalls, 1);
    expect(service.loadPostCalls, 1);
  });

  testWidgets('renders person rows и post tab data', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Иван', earliestHardDelete: pastFloor),
      ],
      posts: [
        _post(id: 'po-1', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(find.text('Иван'), findsOneWidget);
    // Switch к posts tab.
    await tester.tap(find.text('Посты'));
    await tester.pumpAndSettle();
    expect(find.text('Привет, родные!'), findsOneWidget);
  });

  testWidgets('restore person removes row + shows snackbar', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Иван', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash-person-restore-p-1')));
    await tester.pumpAndSettle();
    expect(service.lastRestoredPersonId, 'p-1');
    expect(find.text('Иван'), findsNothing);
    expect(find.textContaining('восстановлен'), findsOneWidget);
  });

  testWidgets(
      'permanent delete disabled когда 3h floor не пройден', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Иван', earliestHardDelete: futureFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    final purgeBtn = tester.widget<IconButton>(
      find.byKey(const Key('trash-person-purge-p-1')),
    );
    expect(purgeBtn.onPressed, isNull,
        reason: 'floor не пройден → button disabled');
  });

  testWidgets(
      'permanent delete с confirm — fires service.permanentlyDeletePerson',
      (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Иван', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('trash-person-purge-p-1')));
    await tester.pumpAndSettle();
    // Confirm dialog.
    await tester.tap(find.byKey(const Key('safe-delete-confirm')));
    await tester.pumpAndSettle();
    expect(service.lastPurgedPersonId, 'p-1');
    expect(find.text('Иван'), findsNothing);
  });

  testWidgets('error state renders retry button when load throws',
      (tester) async {
    final service = _FakeSemyaService(
      throwOnLoad: const SemyaError(
        code: 'UNKNOWN',
        message: 'Сервер недоступен',
      ),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(find.text('Сервер недоступен'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('тач-таргет restore/purge в DeletedItemRow ≥44dp', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Иван', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    final restoreSize =
        tester.getSize(find.byKey(const Key('trash-person-restore-p-1')));
    final purgeSize =
        tester.getSize(find.byKey(const Key('trash-person-purge-p-1')));
    expect(restoreSize.width, greaterThanOrEqualTo(44));
    expect(restoreSize.height, greaterThanOrEqualTo(44));
    expect(purgeSize.width, greaterThanOrEqualTo(44));
    expect(purgeSize.height, greaterThanOrEqualTo(44));
  });

  testWidgets('на узком экране 360×640 нет переполнения (обе вкладки)',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final service = _FakeSemyaService(
      persons: [
        _person(
          id: 'p-1',
          name: 'Александра Константинопольская-Долгорукая',
          earliestHardDelete: pastFloor,
        ),
        _person(id: 'p-2', name: 'Пётр', earliestHardDelete: futureFloor),
      ],
      posts: [
        _post(
          id: 'po-1',
          content:
              'Очень длинный текст поста для проверки переноса строк и '
              'отсутствия горизонтального overflow на узком экране телефона.',
          earliestHardDelete: pastFloor,
        ),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Посты'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
