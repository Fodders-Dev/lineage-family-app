import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_dynamic_links/firebase_dynamic_links.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/dynamic_link_service_interface.dart';
import 'invitation_service.dart';

class NoopDynamicLinkService implements DynamicLinkServiceInterface {
  @override
  Future<void> startListening(GoRouter router) async {}

  @override
  void dispose() {}
}

class FirebaseDynamicLinkService implements DynamicLinkServiceInterface {
  FirebaseDynamicLinkService({GetIt? getIt}) : _getIt = getIt ?? GetIt.I;

  final GetIt _getIt;
  StreamSubscription<PendingDynamicLinkData>? _subscription;
  bool _started = false;

  @override
  Future<void> startListening(GoRouter router) async {
    if (_started) {
      return;
    }
    _started = true;

    try {
      final initialLink = await FirebaseDynamicLinks.instance.getInitialLink();
      if (initialLink != null) {
        debugPrint('[DynamicLinks] Initial link received: ${initialLink.link}');
        _handleDynamicLink(router, initialLink.link);
      }
    } catch (error) {
      debugPrint('[DynamicLinks] Error getting initial link: $error');
    }

    _subscription = FirebaseDynamicLinks.instance.onLink.listen(
      (dynamicLinkData) {
        debugPrint(
          '[DynamicLinks] Link received while app is running: ${dynamicLinkData.link}',
        );
        _handleDynamicLink(router, dynamicLinkData.link);
      },
      onError: (error) {
        debugPrint('[DynamicLinks] onLink error: $error');
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _started = false;
  }

  void _handleDynamicLink(GoRouter router, Uri deepLink) {
    if (deepLink.path != '/invite') {
      debugPrint(
        '[DynamicLinks] Received link with unknown path: ${deepLink.path}',
      );
      return;
    }

    final treeId = deepLink.queryParameters['treeId'];
    final personId = deepLink.queryParameters['personId'];
    if (treeId == null ||
        treeId.isEmpty ||
        personId == null ||
        personId.isEmpty) {
      debugPrint('[DynamicLinks] Error parsing invite link parameters.');
      return;
    }

    debugPrint(
      '[DynamicLinks] Parsed invite: treeId=$treeId, personId=$personId',
    );
    _getIt<InvitationService>().setPendingInvitation(
      treeId: treeId,
      personId: personId,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      router.go('/');
      debugPrint('[DynamicLinks] Handled /invite, navigating to /.');
    });

    final authService = _getIt<AuthServiceInterface>();
    if (authService.currentUserId != null) {
      debugPrint(
        '[DynamicLinks] User is already logged in. Triggering invitation check.',
      );
      Future.microtask(authService.processPendingInvitation);
    } else {
      debugPrint(
        '[DynamicLinks] User is not logged in. Linking will happen after auth.',
      );
    }
  }
}
