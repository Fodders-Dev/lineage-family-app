// Ship Q4a frontend (2026-05-28, Ship 31b): per-семя deleted-persons
// screen tests. Mirror trash_screen_test scenarios scoped к одной семье
// via listDeletedPersonsForSemya.
//
// Covers:
//   • Empty state copy когда нет deleted
//   • Render rows + restore action (row removed + snackbar)
//   • Permanent-delete disabled пока 3h floor не пройден
//   • Permanent-delete confirm flow fires service
//   • Error state с retry button
//   • semyaId передаётся в service call

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rodnya/backend/interfaces/semya_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/deleted_person.dart';
import 'package:rodnya/backend/models/deleted_post.dart';
import 'package:rodnya/backend/models/semya.dart';
import 'package:rodnya/backend/models/semya_browse_token.dart';
import 'package:rodnya/backend/models/semya_invitation.dart';
import 'package:rodnya/backend/models/semya_pull_person_result.dart';
import 'package:rodnya/screens/semya_deleted_persons_screen.dart';

class _FakeSemyaService implements SemyaCapableFamilyTreeService {
  _FakeSemyaService({
    this.persons = const <DeletedPerson>[],
    this.throwOnLoad,
  });

  List<DeletedPerson> persons;
  SemyaError? throwOnLoad;

  int loadCalls = 0;
  String? lastLoadedSemyaId;
  String? lastRestoredId;
  String? lastPurgedId;

  @override
  Future<List<DeletedPerson>> listDeletedPersonsForSemya(String semyaId) async {
    loadCalls += 1;
    lastLoadedSemyaId = semyaId;
    if (throwOnLoad != null) throw throwOnLoad!;
    return persons;
  }

  @override
  Future<void> restoreDeletedPerson(String deletedPersonId) async {
    lastRestoredId = deletedPersonId;
  }

  @override
  Future<void> permanentlyDeletePerson(String deletedPersonId) async {
    lastPurgedId = deletedPersonId;
  }

  @override
  Future<List<DeletedPerson>> listMyDeletedPersons() async =>
      const <DeletedPerson>[];

  @override
  Future<List<DeletedPost>> listMyDeletedPosts() async =>
      const <DeletedPost>[];

  @override
  Future<void> restoreDeletedPost(String deletedPostId) async =>
      throw UnimplementedError();

  @override
  Future<void> permanentlyDeletePost(String deletedPostId) async =>
      throw UnimplementedError();

  // ---- Unused interface surface.

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
  String name = 'Бабушка Лидия',
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

Widget _wrap(SemyaCapableFamilyTreeService service, {String? name}) =>
    MaterialApp(
      home: SemyaDeletedPersonsScreen(
        semyaId: 's-1',
        semyaName: name,
        serviceOverride: service,
      ),
    );

void main() {
  final pastFloor = '2026-05-27T00:00:00.000Z';
  final futureFloor =
      DateTime.now().add(const Duration(hours: 1)).toIso8601String();

  testWidgets('empty state when семья has no deleted persons',
      (tester) async {
    final service = _FakeSemyaService();
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(
      find.text('В этой семье нет удалённых родственников'),
      findsOneWidget,
    );
    expect(service.loadCalls, 1);
    expect(service.lastLoadedSemyaId, 's-1');
  });

  testWidgets('semyaName renders в AppBar title', (tester) async {
    final service = _FakeSemyaService();
    await tester.pumpWidget(_wrap(service, name: 'Ивановых'));
    await tester.pumpAndSettle();
    expect(find.text('Удалённые · Ивановых'), findsOneWidget);
  });

  testWidgets('renders person rows', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Бабушка Лидия', earliestHardDelete: pastFloor),
        _person(id: 'p-2', name: 'Дед Пётр', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(find.text('Бабушка Лидия'), findsOneWidget);
    expect(find.text('Дед Пётр'), findsOneWidget);
  });

  testWidgets('restore removes row + shows snackbar', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Бабушка Лидия', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('semya-trash-restore-p-1')));
    await tester.pumpAndSettle();
    expect(service.lastRestoredId, 'p-1');
    expect(find.text('Бабушка Лидия'), findsNothing);
    expect(find.textContaining('восстановлен'), findsOneWidget);
  });

  testWidgets('permanent delete disabled когда 3h floor не пройден',
      (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', earliestHardDelete: futureFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    final purgeBtn = tester.widget<IconButton>(
      find.byKey(const Key('semya-trash-purge-p-1')),
    );
    expect(purgeBtn.onPressed, isNull);
  });

  testWidgets('permanent delete confirm fires permanentlyDeletePerson',
      (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('semya-trash-purge-p-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('safe-delete-confirm')));
    await tester.pumpAndSettle();
    expect(service.lastPurgedId, 'p-1');
  });

  testWidgets('error state renders retry button', (tester) async {
    final service = _FakeSemyaService(
      throwOnLoad: const SemyaError(
        code: 'FORBIDDEN',
        message: 'Нет доступа',
      ),
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();
    expect(find.text('Нет доступа'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('тач-таргет restore/purge в DeletedItemRow ≥44dp', (tester) async {
    final service = _FakeSemyaService(
      persons: [
        _person(id: 'p-1', name: 'Бабушка Лидия', earliestHardDelete: pastFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service));
    await tester.pumpAndSettle();

    final restoreSize =
        tester.getSize(find.byKey(const Key('semya-trash-restore-p-1')));
    final purgeSize =
        tester.getSize(find.byKey(const Key('semya-trash-purge-p-1')));
    expect(restoreSize.width, greaterThanOrEqualTo(44));
    expect(restoreSize.height, greaterThanOrEqualTo(44));
    expect(purgeSize.width, greaterThanOrEqualTo(44));
    expect(purgeSize.height, greaterThanOrEqualTo(44));
  });

  testWidgets('на узком экране 360×640 нет переполнения', (tester) async {
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
        _person(id: 'p-2', name: 'Дед Пётр', earliestHardDelete: futureFloor),
      ],
    );
    await tester.pumpWidget(_wrap(service, name: 'Очень длинное имя семьи для проверки AppBar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
