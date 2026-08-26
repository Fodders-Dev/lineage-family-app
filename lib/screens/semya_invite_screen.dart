import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../backend/models/semya.dart';
import '../backend/models/semya_invitation.dart';
import '../providers/semya_invitations_controller.dart';

/// Ship FE3 (2026-05-26): «отправить приглашение» screen.
/// Owner либо editor с invite-grant создаёт pending invitation.
///
/// Form fields:
///   • Recipient identifier — email либо phone (mutually exclusive,
///     один required)
///   • Role selector — editor либо viewer (default viewer per
///     CIRCLE-EXTENSION decisions Q1)
///
/// Success state: show invitation token + copy/share buttons.
class SemyaInviteScreen extends StatefulWidget {
  const SemyaInviteScreen({super.key, required this.semyaId});

  final String semyaId;

  @override
  State<SemyaInviteScreen> createState() => _SemyaInviteScreenState();
}

class _SemyaInviteScreenState extends State<SemyaInviteScreen> {
  late final SemyaInvitationsController _controller;
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  SemyaRole _selectedRole = SemyaRole.viewer;

  @override
  void initState() {
    super.initState();
    _controller = SemyaInvitationsController(semyaId: widget.semyaId);
  }

  @override
  void dispose() {
    _controller.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    final phone = _phoneController.text.trim();
    if (email.isEmpty && phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Укажите email либо телефон получателя'),
        ),
      );
      return;
    }
    final ok = await _controller.sendInvitation(
      role: _selectedRole,
      recipientEmail: email.isNotEmpty ? email : null,
      recipientPhone: phone.isNotEmpty ? phone : null,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_controller.errorMessage ?? 'Не удалось'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SemyaInvitationsController>.value(
      value: _controller,
      child: Consumer<SemyaInvitationsController>(
        builder: (context, controller, _) {
          return Scaffold(
            appBar: AppBar(title: const Text('Пригласить в семью')),
            body: controller.lastCreated != null
                ? _SuccessView(invitation: controller.lastCreated!)
                : _buildForm(controller),
          );
        },
      ),
    );
  }

  Widget _buildForm(SemyaInvitationsController controller) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      children: [
        Text(
          'Укажите контакт, чтобы подписать приглашение. Родня создаст '
          'персональную ссылку — отправить её нужно будет самостоятельно.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('semya-invite-email'),
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.alternate_email),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('semya-invite-phone'),
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Телефон',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Роль',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<SemyaRole>(
          segments: const [
            ButtonSegment<SemyaRole>(
              value: SemyaRole.viewer,
              label: Text('Просмотр'),
              icon: Icon(Icons.visibility_outlined),
            ),
            ButtonSegment<SemyaRole>(
              value: SemyaRole.editor,
              label: Text('Редактирование'),
              icon: Icon(Icons.edit_outlined),
            ),
          ],
          selected: {_selectedRole},
          onSelectionChanged: (set) {
            setState(() => _selectedRole = set.first);
          },
        ),
        const SizedBox(height: 8),
        Text(
          _selectedRole == SemyaRole.editor
              ? 'Можно добавлять и менять людей в дереве.'
              : 'Можно смотреть дерево и переписываться.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        if (controller.errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              controller.errorMessage!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        FilledButton(
          key: const Key('semya-invite-submit'),
          onPressed: controller.isSending ? null : _submit,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: controller.isSending
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Создать ссылку'),
          ),
        ),
      ],
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({required this.invitation});

  final SemyaInvitation invitation;

  String get _shareLink => 'https://rodnya-tree.ru/invite/${invitation.token}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 64,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          'Ссылка для приглашения готова',
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          'Отправьте ссылку родственнику любым удобным способом — после '
          'открытия он сможет войти и принять приглашение.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            _shareLink,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                key: const Key('semya-invite-copy'),
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: _shareLink),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Ссылка скопирована')),
                    );
                  }
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Скопировать'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                key: const Key('semya-invite-share'),
                onPressed: () async {
                  await SharePlus.instance.share(
                    ShareParams(
                      text: 'Приглашение в семью на Rodnya: $_shareLink',
                    ),
                  );
                },
                icon: const Icon(Icons.share_outlined),
                label: const Text('Поделиться'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}
