// Ship FE2 (2026-05-26): SemyaDetailsScreen smoke + content tests.
// Builds screen с injected fake service (via GetIt registration since
// screen creates its own controller internally that resolves through
// FamilyTreeServiceInterface). Tests verify header, members rendering,
// role chips, owner-only tile disabled fallback.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/semya_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/semya.dart';
import 'package:rodnya/backend/models/semya_browse_token.dart';
import 'package:rodnya/backend/models/semya_invitation.dart';
import 'package:rodnya/backend/models/semya_pull_person_result.dart';
import 'package:rodnya/screens/semya_details_screen.dart';

class _FakeFamilyTreeService
    implements FamilyTreeServiceInterface, SemyaCapableFamilyTreeService {
  _FakeFamilyTreeService({
    this.details,
    this.memberships = const <SemyaMembership>[],
  });

  SemyaDetails? details;
  List<SemyaMembership> memberships;

  @override
  Future<List<Semya>> listMySemya() async => const <Semya>[];

  @override
  Future<SemyaDetails?> findSemyaById(String semyaId) async => details;

  @override
  Future<List<SemyaMembership>> listMembershipsForSemya(
    String semyaId,
  ) async =>
      memberships;

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
      const <SemyaBrowseTokenSummary>[];

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

  // FamilyTreeServiceInterface has широкий surface — все остальные
  // методы falling through к noSuchMethod (тесты SemyaDetailsScreen
  // не trigger'ят их).
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

SemyaDetails _details({
  String name = 'Семья Кузнецовых',
  SemyaRole role = SemyaRole.owner,
  String? description,
}) {
  return SemyaDetails(
    semya: Semya(
      id: 'semya-1',
      name: name,
      ownerId: 'user-1',
      treeId: 'tree-1',
      description: description,
      createdAt: '2026-05-22T00:00:00.000Z',
      updatedAt: '2026-05-22T00:00:00.000Z',
    ),
    membership: SemyaMembership(
      id: 'm-1',
      semyaId: 'semya-1',
      userId: 'user-1',
      role: role,
      joinedAt: '2026-05-22T00:00:00.000Z',
    ),
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

  testWidgets('renders header с name + member count + role chip',
      (tester) async {
    final fake = _FakeFamilyTreeService(
      details: _details(description: 'Тестовая семья'),
      memberships: [
        SemyaMembership(
          id: 'm-2',
          semyaId: 'semya-1',
          userId: 'editor-a',
          role: SemyaRole.editor,
          joinedAt: '2026-05-22T00:00:00.000Z',
        ),
        SemyaMembership(
          id: 'm-3',
          semyaId: 'semya-1',
          userId: 'viewer-b',
          role: SemyaRole.viewer,
          joinedAt: '2026-05-22T00:00:00.000Z',
        ),
      ],
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(fake);

    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaDetailsScreen(semyaId: 'semya-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Семья Кузнецовых'), findsWidgets);
    expect(find.text('Тестовая семья'), findsOneWidget);
    expect(find.text('2 участника'), findsOneWidget);
    expect(find.text('Владелец'), findsOneWidget);
  });

  testWidgets('renders empty state когда no other members', (tester) async {
    final fake = _FakeFamilyTreeService(
      details: _details(),
      memberships: const <SemyaMembership>[],
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(fake);

    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaDetailsScreen(semyaId: 'semya-1'),
      ),
    );
    await tester.pumpAndSettle();

    // Phase B polish D: warm empty state + «Пригласить» CTA (owner → canInvite).
    expect(find.byKey(const Key('semya-members-empty')), findsOneWidget);
    expect(find.text('Пока вы здесь одни.'), findsOneWidget);
    expect(
      find.byKey(const Key('semya-members-empty-invite')),
      findsOneWidget,
    );
    expect(find.text('Пригласить'), findsOneWidget);
  });

  testWidgets('renders error state с retry button when details null',
      (tester) async {
    final fake = _FakeFamilyTreeService(details: null);
    getIt.registerSingleton<FamilyTreeServiceInterface>(fake);

    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaDetailsScreen(semyaId: 'unknown'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Не удалось загрузить семью'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);
  });

  testWidgets('owner-only management tile remains locked placeholder; '
      'invitations tile now active (FE3)', (tester) async {
    final fake = _FakeFamilyTreeService(details: _details());
    getIt.registerSingleton<FamilyTreeServiceInterface>(fake);

    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaDetailsScreen(semyaId: 'semya-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Управление семьёй'), findsOneWidget);
    expect(find.text('Приглашения'), findsOneWidget);
    // FE3 (2026-05-26): «Приглашения» tile changed from disabled
    // placeholder к active ListTile → only «Управление семьёй»
    // remains locked placeholder. One lock icon expected (was 2).
    expect(find.byIcon(Icons.lock_outline_rounded), findsOneWidget);
    // Invitations tile теперь shows chevron (navigable).
    expect(find.byKey(const Key('semya-details-invitations')), findsOneWidget);
  });

  testWidgets('viewer role surfaces correctly', (tester) async {
    final fake = _FakeFamilyTreeService(
      details: _details(role: SemyaRole.viewer),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(fake);

    await tester.pumpWidget(
      const MaterialApp(
        home: SemyaDetailsScreen(semyaId: 'semya-1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Зритель'), findsOneWidget);
  });

  testWidgets(
    'density chunk 25: member row ~56dp, section header ~28dp',
    (tester) async {
      // Regression guard for chunk 25 (семья card). Before: _MemberRow
      // was a ListTile (title+subtitle+leading+trailing default padding)
      // measured at 88dp; _SectionHeader container measured at ~44dp
      // (16/8 padding around titleSmall). After: custom 56dp row with a
      // 40dp avatar, and a 28dp section header (same pattern as the
      // invitations list groups).
      final fake = _FakeFamilyTreeService(
        details: _details(),
        memberships: [
          SemyaMembership(
            id: 'm-2',
            semyaId: 'semya-1',
            userId: 'editor-a',
            role: SemyaRole.editor,
            joinedAt: '2026-05-22T00:00:00.000Z',
          ),
        ],
      );
      getIt.registerSingleton<FamilyTreeServiceInterface>(fake);

      await tester.pumpWidget(
        const MaterialApp(home: SemyaDetailsScreen(semyaId: 'semya-1')),
      );
      await tester.pumpAndSettle();

      final rowRect = tester.getRect(
        find.byKey(const ValueKey('semya-member-row-editor-a')),
      );
      expect(
        rowRect.height,
        inInclusiveRange(52, 64),
        reason: 'Строка участника должна быть ~56dp (до чанка 25 — 88dp '
            'у ListTile).',
      );

      final headerRect = tester.getRect(find.text('Участники'));
      // Заголовок секции — текстовая строка внутри контейнера с
      // паддингом 8/4; сам текст ~16dp, контейнер — 28dp.
      expect(
        headerRect.height,
        lessThanOrEqualTo(20),
        reason: 'Текст заголовка секции компактный (до чанка 25 контейнер '
            'заголовка был ~44dp, стал ~28dp).',
      );
    },
  );
}
