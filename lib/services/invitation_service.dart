// lib/services/invitation_service.dart
import 'package:flutter/foundation.dart';

/// Сервис для временного хранения данных из ссылки-приглашения
class InvitationService extends ChangeNotifier {
  static final InvitationService _instance = InvitationService._internal();
  factory InvitationService() => _instance;
  InvitationService._internal();

  String? _pendingTreeId;
  String? _pendingPersonId;

  String? get pendingTreeId => _pendingTreeId;
  String? get pendingPersonId => _pendingPersonId;

  bool get hasPendingInvitation =>
      _pendingTreeId != null && _pendingPersonId != null;

  void setPendingInvitation({
    required String treeId,
    required String personId,
  }) {
    print(
      '[InvitationService] Setting pending invitation: treeId=$treeId, personId=$personId',
    );
    _pendingTreeId = treeId;
    _pendingPersonId = personId;
    notifyListeners(); // Уведомляем слушателей, если используем Provider
  }

  void clearPendingInvitation() {
    print('[InvitationService] Clearing pending invitation.');
    _pendingTreeId = null;
    _pendingPersonId = null;
    notifyListeners();
  }
}
