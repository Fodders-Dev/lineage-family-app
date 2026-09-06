// Ship FE3 (2026-05-26): smoke tests для invitations list screen.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/semya_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/semya.dart';
import 'package:rodnya/backend/models/semya_browse_token.dart';
import 'package:rodnya/backend/models/semya_invitation.dart';
import 'package:rodnya/backend/models/semya_pull_person_result.dart';
import 'package:rodnya/screens/semya_invitations_list_screen.dart';

class _FakeService
    implements FamilyTreeServiceInterface, SemyaCapableFamilyTreeService {
  _FakeService({this.invitations = const <SemyaInvitation>[]});

  List<SemyaInvitation> invitations;
  int revokeCalls = 0;

  @override
  Future<List<Semya>> listMySemya() async => const <Semya>[];

  @override
  Future<SemyaDetails?> findSemyaById(String semyaId) async => null;

  @override
  Future<List<SemyaMembership>> listMembershipsForSemya(
    String semyaId,
  ) async =>
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
  Future<List<SemyaInvitation>> listInvitationsForSemya(
    String semyaId,
  ) async =>
      invitations;

  @override
  Future<SemyaInvitation> revokeInvitation({
    required String semyaId,
    required String invitationId,
  }) async {
    revokeCalls += 1;
    return SemyaInvitation(
      id: invitationId,
      token: 'tok',
      semyaId: semyaId,
      inviterUserId: 'u',
      role: SemyaRole.viewer,
      status: SemyaInvitationStatus.revoked,
      createdAt: '2026-05-26T00:00:00.000Z',
      expiresAt: '2026-06-25T00:00:00.000Z',
    );
  }

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
  Future<SemyaMembershipRemoveResult> removeMembership({
    required String semyaId,
    required String userId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<SemyaInvitation>> listPendingInvitations() async =>
      const <SemyaInvitation>[];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

SemyaInvitation _invitation({
  String id = 'inv-x',
  String? email = 'recipient@example.com',
  SemyaInvitationStatus status = SemyaInvitationStatus.pending,
}) {
  return SemyaInvitation(
    id: id,
    token: 'tok-$id',
    semyaId: 'semya-1',
    inviterUserId: 'user-1',
    role: SemyaRole.viewer,
    status: status,
    createdAt: '2026-05-26T00:00:00.000Z',
    expiresAt: '2026-06-25T00:00:00.000Z',
    recipientEmail: email,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('empty state когда no invitations + canInvite=true показывает CTA',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(_FakeService());
    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaInvitationsListScreen(
          semyaId: 'semya-1',
          canInvite: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Пока нет приглашений'), findsOneWidget);
    expect(find.text('Отправьте первое приглашение родственнику.'),
        findsOneWidget);
    expect(find.byKey(const Key('semya-invitations-empty-cta')),
        findsOneWidget);
  });

  testWidgets('empty state когда canInvite=false скрывает CTA',
      (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(_FakeService());
    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaInvitationsListScreen(
          semyaId: 'semya-1',
          canInvite: false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('semya-invitations-empty-cta')), findsNothing);
    expect(
      find.text('Когда владелец отправит приглашения — вы увидите их здесь.'),
      findsOneWidget,
    );
  });

  testWidgets('renders all statuses с appropriate badges', (tester) async {
    final service = _FakeService(invitations: [
      _invitation(id: 'p', status: SemyaInvitationStatus.pending),
      _invitation(id: 'a', status: SemyaInvitationStatus.accepted),
      _invitation(id: 'r', status: SemyaInvitationStatus.revoked),
      _invitation(id: 'e', status: SemyaInvitationStatus.expired),
    ]);
    getIt.registerSingleton<FamilyTreeServiceInterface>(service);
    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaInvitationsListScreen(
          semyaId: 'semya-1',
          canInvite: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ожидает'), findsOneWidget);
    expect(find.text('Принято'), findsOneWidget);
    expect(find.text('Отозвано'), findsOneWidget);
    expect(find.text('Истекло'), findsOneWidget);
  });

  testWidgets(
    'revoke + copy actions only visible для pending invitations',
    (tester) async {
      final service = _FakeService(invitations: [
        _invitation(id: 'p', status: SemyaInvitationStatus.pending),
        _invitation(id: 'a', status: SemyaInvitationStatus.accepted),
      ]);
      getIt.registerSingleton<FamilyTreeServiceInterface>(service);
      await tester.pumpWidget(
        const MaterialApp(
          home: SemyaInvitationsListScreen(
            semyaId: 'semya-1',
            canInvite: true,
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Pending — has both buttons.
      expect(find.byKey(const Key('semya-invitation-copy-p')), findsOneWidget);
      expect(find.byKey(const Key('semya-invitation-revoke-p')), findsOneWidget);
      // Accepted — no actions.
      expect(find.byKey(const Key('semya-invitation-copy-a')), findsNothing);
      expect(find.byKey(const Key('semya-invitation-revoke-a')), findsNothing);
    },
  );

  testWidgets('revoke tap → confirm dialog → service call', (tester) async {
    final service = _FakeService(invitations: [
      _invitation(id: 'p'),
    ]);
    getIt.registerSingleton<FamilyTreeServiceInterface>(service);
    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaInvitationsListScreen(
          semyaId: 'semya-1',
          canInvite: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('semya-invitation-revoke-p')));
    await tester.pumpAndSettle();
    expect(find.text('Отозвать приглашение?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('semya-invitation-revoke-confirm')));
    await tester.pumpAndSettle();
    expect(service.revokeCalls, 1);
    expect(find.text('Приглашение отозвано'), findsOneWidget);
  });

  testWidgets(
    'density chunk 25: row height ~56-64dp + ≥10 rows visible on 412x915',
    (tester) async {
      // Regression guard for chunk 25 (invitations list). Before: ListTile
      // rows at 72dp each → 12 rows visible on a 412×915 screen. After:
      // custom 56-64dp row (icon-avatar + name/time + status/role) под
      // группами «Ожидают»/«История» → ≥10 rows visible even with the
      // extra 28dp group header.
      tester.view.physicalSize = const Size(412 * 3, 915 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);

      final invitations =
          List.generate(20, (i) => _invitation(id: '$i', email: 'u$i@x.io'));
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _FakeService(invitations: invitations),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: SemyaInvitationsListScreen(
            semyaId: 'semya-1',
            canInvite: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row0 =
          tester.getRect(find.byKey(const Key('semya-invitation-tile-0')));
      expect(
        row0.height,
        inInclusiveRange(56, 64),
        reason: 'Строка приглашения должна быть 56-64dp (до чанка 25 было '
            '72dp у ListTile).',
      );

      var visible = 0;
      for (var i = 0; i < invitations.length; i++) {
        final finder = find.byKey(Key('semya-invitation-tile-$i'));
        if (finder.evaluate().isEmpty) break;
        if (tester.getRect(finder).top < 915) visible++;
      }
      expect(
        visible,
        greaterThanOrEqualTo(10),
        reason: 'На первом экране 412×915 должно помещаться ≥10 строк '
            '(до чанка 25 — 12 строк без секций; после — с заголовком '
            'группы поместилось 14).',
      );
    },
  );
}
