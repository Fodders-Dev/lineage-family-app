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
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      children: [
        // Плотность (чанк 25): пояснение — не абзац, а одна вводная
        // строка (maxLines 2 — страховка для узких экранов), 14sp вместо
        // bodyMedium по умолчанию (14-15).
        Text(
          'Укажите контакт, чтобы подписать приглашение. Родня создаст '
          'персональную ссылку — отправить её нужно будет самостоятельно.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
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
        const SizedBox(height: 10),
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
        const SizedBox(height: 10),
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
        const SizedBox(height: 16),
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
          const SizedBox(height: 10),
        ],
        // Плотность (чанк 25): CTA — фиксированные 52dp вместо
        // FilledButton с двойным вертикальным паддингом (тема даёт 14
        // сверху/снизу + был ещё Padding(vertical: 12) внутри — вместе
        // ~70dp на кнопку одной строки). SizedBox снаружи держит высоту,
        // Center внутри — спиннер/текст по центру той же коробки.
        SizedBox(
          height: 52,
          child: FilledButton(
            key: const Key('semya-invite-submit'),
            onPressed: controller.isSending ? null : _submit,
            child: Center(
              child: controller.isSending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Создать ссылку'),
            ),
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

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: _shareLink));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ссылка скопирована')),
      );
    }
  }

  Future<void> _shareLinkNow() async {
    await SharePlus.instance.share(
      ShareParams(text: 'Приглашение в семью на Rodnya: $_shareLink'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Плотность (чанк 25): было — иконка 64dp + заголовок headlineSmall +
    // пояснение + отдельный блок ссылки + строка из 2 полноширинных
    // кнопок (Скопировать/Поделиться) — «вступление» одно съедало
    // страницы. Стало — компактная иконка+заголовок в одну группу,
    // пояснение ≤2 строк 14sp, ссылка одной строкой 50dp со
    // встроенной кнопкой копирования 44dp, «Поделиться» — пилюля 46dp
    // (как соцвход на экране входа, _SocialAuthChip) — всё умещается
    // на первом экране без прокрутки.
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        Icon(
          Icons.check_circle_outline,
          size: 40,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 10),
        Text(
          'Ссылка для приглашения готова',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
        Text(
          'Отправьте ссылку родственнику — после открытия он войдёт и '
          'примет приглашение.',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 16),
        Container(
          height: 50,
          padding: const EdgeInsets.only(left: 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _shareLink,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontSize: 14,
                  ),
                ),
              ),
              SizedBox(
                width: 44,
                height: 44,
                child: IconButton(
                  key: const Key('semya-invite-copy'),
                  tooltip: 'Скопировать',
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  onPressed: () => _copyLink(context),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _InviteActionPill(
              key: const Key('semya-invite-share'),
              label: 'Поделиться',
              icon: Icons.share_outlined,
              onTap: _shareLinkNow,
            ),
          ],
        ),
        const SizedBox(height: 20),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Закрыть'),
        ),
      ],
    );
  }
}

/// Плотность (чанк 25): визуальный близнец `_SocialAuthChip` со
/// экрана входа (density chunk 18) — icon+label пилюля 46dp высотой.
/// Здесь только реальные действия (Поделиться); Telegram/WhatsApp/QR
/// пиктограммы в макете не добавлены — под них нет отдельных каналов
/// шаринга в сервисном слое (SharePlus открывает системный лист, где
/// Telegram/WhatsApp уже доступны как приложения получателя).
class _InviteActionPill extends StatelessWidget {
  const _InviteActionPill({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: Colors.transparent,
      shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant, width: 1.2)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: scheme.onSurface),
              const SizedBox(width: 8),
              Text(
                label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
