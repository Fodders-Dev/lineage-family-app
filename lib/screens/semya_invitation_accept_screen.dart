// Ship FE3b (2026-05-28): семя invitation deep-link accept screen.
//
// Route entry: GoRoute path `/invite/:token` (added в
// app_overlay_route_module). User reaches здесь via:
//   • Verified App Link tap (Android https://rodnya-tree.ru/invite/X)
//   • In-app navigation (rare — обычно invitation acceptance происходит
//     через FE9 wizard либо future settings tile)
//
// Behavior:
//   • Logged out — guard redirects к /login?from=/invite/{token} ПЕРЕД
//     reaching этого screen (handled in app_router_guards.dart). После
//     login router re-resolves /invite/{token} с authed user.
//   • Logged in — этот screen mount calls service.acceptInvitation(token),
//     surfaces snackbar feedback, navigates к /.
//
// Error mapping (per backend Ship 4):
//   • TOKEN_NOT_FOUND   → «Приглашение не найдено»
//   • WRONG_RECIPIENT   → «Приглашение оформлено на другого пользователя»
//   • INVITATION_NOT_PENDING → может означать accepted (already member)
//                              либо revoked. Differentiate via message keyword.
//   • Прочие (network etc.) → generic «Не удалось принять приглашение»

import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/semya_capable_family_tree_service.dart';
import '../backend/models/semya.dart';
import '../services/semya_invitation_deep_link_service.dart';

class SemyaInvitationAcceptScreen extends StatefulWidget {
  const SemyaInvitationAcceptScreen({
    super.key,
    required this.token,
    this.serviceOverride,
    this.deepLinkServiceOverride,
  });

  final String token;

  /// Test seam.
  final SemyaCapableFamilyTreeService? serviceOverride;
  final SemyaInvitationDeepLinkService? deepLinkServiceOverride;

  @override
  State<SemyaInvitationAcceptScreen> createState() =>
      _SemyaInvitationAcceptScreenState();
}

class _SemyaInvitationAcceptScreenState
    extends State<SemyaInvitationAcceptScreen> {
  bool _processing = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _processAccept());
  }

  SemyaCapableFamilyTreeService? _resolveService() {
    if (widget.serviceOverride != null) return widget.serviceOverride;
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) return null;
    final svc = GetIt.I<FamilyTreeServiceInterface>();
    if (svc is SemyaCapableFamilyTreeService) {
      return svc as SemyaCapableFamilyTreeService;
    }
    return null;
  }

  Future<void> _processAccept() async {
    final service = _resolveService();
    final deepLinkSvc =
        widget.deepLinkServiceOverride ?? SemyaInvitationDeepLinkService();

    if (service == null) {
      setState(() {
        _processing = false;
        _errorMessage = 'Сервис недоступен';
      });
      return;
    }

    final trimmed = widget.token.trim();
    if (trimmed.isEmpty) {
      setState(() {
        _processing = false;
        _errorMessage = 'Некорректное приглашение';
      });
      return;
    }

    try {
      final result = await service.acceptInvitation(trimmed);
      // Clear persisted token — accepted successfully.
      deepLinkSvc.clearPendingToken();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Вы присоединились к семье. Роль: '
            '${result.role.displayLabel.toLowerCase()}',
          ),
        ),
      );
      context.go('/');
    } on SemyaError catch (error) {
      // Clear persisted token only on terminal errors — keep если
      // network blip (user retries via different entry point).
      final terminalCodes = {
        'INVITATION_NOT_FOUND',
        'INVITATION_NOT_PENDING',
        'WRONG_RECIPIENT',
        'SEMYA_NOT_FOUND',
      };
      if (terminalCodes.contains(error.code)) {
        deepLinkSvc.clearPendingToken();
      }
      if (!mounted) return;
      final friendly = _friendlyMessage(error);
      setState(() {
        _processing = false;
        _errorMessage = friendly;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendly)));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _processing = false;
        _errorMessage = 'Не удалось принять приглашение: $error';
      });
    }
  }

  String _friendlyMessage(SemyaError error) {
    switch (error.code) {
      case 'INVITATION_NOT_FOUND':
        return 'Приглашение не найдено';
      case 'INVITATION_NOT_PENDING':
        // Backend lazy-expires + flips status on accept/revoke. Hard
        // discriminate невозможен без extra round-trip; surface
        // backend's localized message (e.g. «приглашение не активно»)
        // verbatim — оно уже differentiates accepted vs revoked
        // в практике.
        return error.message;
      case 'WRONG_RECIPIENT':
        return 'Приглашение оформлено на другого пользователя';
      case 'SEMYA_NOT_FOUND':
        return 'Семья больше недоступна';
      default:
        return 'Не удалось принять приглашение: ${error.message}';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Плотность (чанк 25): у этого экрана нет отдельного шага
    // подтверждения — mount сразу вызывает acceptInvitation (см. комментарий
    // класса выше и initState); поэтому здесь нет hero «кто приглашает +
    // в какую семью» и CTA «Присоединиться» — их пришлось бы городить
    // поверх нового confirm-шага, а это уже логика принятия приглашения
    // (запрещено правкой только вёрстки). Плотность применена к двум
    // реальным состояниям: обработка и ошибка.
    return Scaffold(
      appBar: AppBar(
        title: const Text('Приглашение в семью'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _processing
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    CircularProgressIndicator(),
                    SizedBox(height: 12),
                    Text('Проверяем приглашение...'),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.error_outline_rounded,
                      size: 40,
                      color: theme.colorScheme.error,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _errorMessage ?? 'Не удалось обработать приглашение',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontSize: 15,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        key: const Key('invitation-accept-go-home'),
                        onPressed: () => context.go('/'),
                        child: const Center(
                          child: Text('Вернуться на главную'),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
