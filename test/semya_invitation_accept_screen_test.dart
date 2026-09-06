// Density chunk 25: smoke + invariant tests for the invitation
// deep-link accept screen. No test existed for this screen before —
// it's the first thing an invited relative sees after tapping the
// link, so it's worth a permanent regression guard even though this
// chunk only touched layout (auto-accept-on-mount logic is untouched,
// see the comment in semya_invitation_accept_screen.dart build()).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:rodnya/backend/interfaces/semya_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/deleted_person.dart';
import 'package:rodnya/backend/models/deleted_post.dart';
import 'package:rodnya/backend/models/semya.dart';
import 'package:rodnya/backend/models/semya_browse_token.dart';
import 'package:rodnya/backend/models/semya_invitation.dart';
import 'package:rodnya/backend/models/semya_pull_person_result.dart';
import 'package:rodnya/screens/semya_invitation_accept_screen.dart';
import 'package:rodnya/services/semya_invitation_deep_link_service.dart';

class _FakeSemyaService implements SemyaCapableFamilyTreeService {
  _FakeSemyaService({this.acceptError});

  SemyaError? acceptError;

  /// Never completes when [acceptError] is null — used by the
  /// "processing state" test, which only needs the spinner to still
  /// be up after the first frame (a fake that resolves/throws
  /// synchronously would race the microtask queue against `pump()`).
  final Completer<SemyaInvitationAcceptResult> _pending = Completer();

  @override
  Future<SemyaInvitationAcceptResult> acceptInvitation(String token) async {
    if (acceptError != null) throw acceptError!;
    return _pending.future;
  }

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
      const <SemyaInvitation>[];

  @override
  Future<SemyaInvitation> revokeInvitation({
    required String semyaId,
    required String invitationId,
  }) async =>
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
  Future<SemyaMembership> addMembership({
    required String semyaId,
    required String userId,
    required SemyaRole role,
    bool hasInviteGrant = false,
  }) async =>
      throw UnimplementedError();

  @override
  Future<List<DeletedPerson>> listMyDeletedPersons() async =>
      const <DeletedPerson>[];

  @override
  Future<List<DeletedPerson>> listDeletedPersonsForSemya(
    String semyaId,
  ) async =>
      const <DeletedPerson>[];

  @override
  Future<void> restoreDeletedPerson(String deletedPersonId) async {}

  @override
  Future<void> permanentlyDeletePerson(String deletedPersonId) async {}

  @override
  Future<List<DeletedPost>> listMyDeletedPosts() async =>
      const <DeletedPost>[];

  @override
  Future<void> restoreDeletedPost(String deletedPostId) async {}

  @override
  Future<void> permanentlyDeletePost(String deletedPostId) async {}
}

class _FakeDeepLinkService implements SemyaInvitationDeepLinkService {
  int clearCalls = 0;

  @override
  void clearPendingToken() {
    clearCalls += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

GoRouter _buildRouter(Widget accept) {
  return GoRouter(
    initialLocation: '/invite/tok',
    routes: [
      GoRoute(
        path: '/invite/tok',
        builder: (context, state) => accept,
      ),
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: Text('Главный экран')),
      ),
    ],
  );
}

void main() {
  testWidgets(
    'density chunk 25: error state — icon/text/CTA fit compactly, CTA is 52dp',
    (tester) async {
      final service = _FakeSemyaService(
        acceptError: const SemyaError(
          code: 'INVITATION_NOT_FOUND',
          message: 'not found',
        ),
      );
      final deepLink = _FakeDeepLinkService();
      final router = _buildRouter(
        SemyaInvitationAcceptScreen(
          token: 'tok',
          serviceOverride: service,
          deepLinkServiceOverride: deepLink,
        ),
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      // Both the body text and the transient SnackBar carry this
      // message — at least one (the body copy) must be present.
      expect(find.text('Приглашение не найдено'), findsWidgets);
      expect(deepLink.clearCalls, 1);

      final cta =
          tester.getRect(find.byKey(const Key('invitation-accept-go-home')));
      expect(
        cta.height,
        52,
        reason: 'CTA «Вернуться на главную» — фиксированные 52dp.',
      );
      expect(
        cta.bottom,
        lessThanOrEqualTo(500),
        reason: 'Ошибка + CTA должны помещаться в верхние 500dp экрана.',
      );

      await tester.tap(find.byKey(const Key('invitation-accept-go-home')));
      await tester.pumpAndSettle();
      expect(find.text('Главный экран'), findsOneWidget);
    },
  );

  testWidgets('processing state renders spinner + label', (tester) async {
    // Never resolves — keeps the screen in the processing state.
    final service = _FakeSemyaService();
    final router = _buildRouter(
      SemyaInvitationAcceptScreen(
        token: 'tok',
        serviceOverride: service,
        deepLinkServiceOverride: _FakeDeepLinkService(),
      ),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Проверяем приглашение...'), findsOneWidget);
  });
}
