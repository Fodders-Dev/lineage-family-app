// Ship FE3 (2026-05-26): smoke + interaction tests для invite screen.
// Verify form fields, submit button, success view с share link.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/semya_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/semya.dart';
import 'package:rodnya/backend/models/semya_browse_token.dart';
import 'package:rodnya/backend/models/semya_invitation.dart';
import 'package:rodnya/backend/models/semya_pull_person_result.dart';
import 'package:rodnya/screens/semya_invite_screen.dart';

class _FakeService
    implements FamilyTreeServiceInterface, SemyaCapableFamilyTreeService {
  _FakeService({this.createResult});

  SemyaInvitation? createResult;
  String? lastEmail;
  String? lastPhone;
  SemyaRole? lastRole;
  int createCalls = 0;

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
  }) async {
    createCalls += 1;
    lastEmail = recipientEmail;
    lastPhone = recipientPhone;
    lastRole = role;
    if (createResult == null) {
      throw const SemyaError(code: 'UNKNOWN', message: 'fake');
    }
    return createResult!;
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SemyaInvitation _invitation() {
  return const SemyaInvitation(
    id: 'inv-1',
    token: 'tok-abc-xyz',
    semyaId: 'semya-1',
    inviterUserId: 'user-1',
    role: SemyaRole.viewer,
    status: SemyaInvitationStatus.pending,
    createdAt: '2026-05-26T00:00:00.000Z',
    expiresAt: '2026-06-25T00:00:00.000Z',
    recipientEmail: 'a@b.c',
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

  testWidgets('renders form fields + role selector', (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(_FakeService());
    await tester.pumpWidget(
      const MaterialApp(home: SemyaInviteScreen(semyaId: 'semya-1')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Пригласить в семью'), findsOneWidget);
    expect(find.byKey(const Key('semya-invite-email')), findsOneWidget);
    expect(find.byKey(const Key('semya-invite-phone')), findsOneWidget);
    expect(find.text('Просмотр'), findsOneWidget);
    expect(find.text('Редактирование'), findsOneWidget);
    expect(find.text('Создать ссылку'), findsOneWidget);
    expect(find.byKey(const Key('semya-invite-submit')), findsOneWidget);
  });

  testWidgets('submit empty form shows error snackbar', (tester) async {
    getIt.registerSingleton<FamilyTreeServiceInterface>(_FakeService());
    await tester.pumpWidget(
      const MaterialApp(home: SemyaInviteScreen(semyaId: 'semya-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('semya-invite-submit')));
    await tester.pump();
    expect(find.text('Укажите email либо телефон получателя'), findsOneWidget);
  });

  testWidgets('successful submit shows share link + copy/share buttons',
      (tester) async {
    final service = _FakeService(createResult: _invitation());
    getIt.registerSingleton<FamilyTreeServiceInterface>(service);
    await tester.pumpWidget(
      const MaterialApp(home: SemyaInviteScreen(semyaId: 'semya-1')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('semya-invite-email')),
      'recipient@example.com',
    );
    await tester.tap(find.byKey(const Key('semya-invite-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Ссылка для приглашения готова'), findsOneWidget);
    expect(find.textContaining('tok-abc-xyz'), findsOneWidget);
    expect(find.byKey(const Key('semya-invite-copy')), findsOneWidget);
    expect(find.byKey(const Key('semya-invite-share')), findsOneWidget);
    expect(service.createCalls, 1);
    expect(service.lastEmail, 'recipient@example.com');
    expect(service.lastRole, SemyaRole.viewer);
  });

  testWidgets('role selector toggles между viewer и editor', (tester) async {
    final service = _FakeService(createResult: _invitation());
    getIt.registerSingleton<FamilyTreeServiceInterface>(service);
    await tester.pumpWidget(
      const MaterialApp(home: SemyaInviteScreen(semyaId: 'semya-1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Редактирование'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('semya-invite-email')),
      'x@y.z',
    );
    await tester.tap(find.byKey(const Key('semya-invite-submit')));
    await tester.pumpAndSettle();
    expect(service.lastRole, SemyaRole.editor);
  });
}
