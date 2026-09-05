import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../theme/app_theme.dart';

/// "О приложении" — двухколоночный layout на десктопе (бренд-блок
/// слева, ссылки/контакты справа), компактный одностолбцовый на phone.
/// Использует RodnyaDesignTokens вместо generic Material grey/primary
/// чтобы попасть в дизайн-систему остальных экранов.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Future<String> _loadVersionLabel() async {
    final packageInfo = await PackageInfo.fromPlatform();
    return 'Версия ${packageInfo.version} (сборка ${packageInfo.buildNumber})';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    return Scaffold(
      appBar: AppBar(title: const Text('О приложении')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 1180 совпадает с home/profile breakpoint — wide layout
            // показывается на десктопе/планшетных альбомных размерах.
            final isWide = constraints.maxWidth >= 1180;
            return Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isWide ? 1100 : 720),
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isWide ? 24 : 20,
                    vertical: 24,
                  ),
                  child: isWide
                      ? _buildWideLayout(context, theme, tokens)
                      : _buildNarrowLayout(context, theme, tokens),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildNarrowLayout(
    BuildContext context,
    ThemeData theme,
    RodnyaDesignTokens tokens,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BrandBlock(tokens: tokens, theme: theme, future: _loadVersionLabel()),
        const SizedBox(height: 20),
        _DescriptionBlock(theme: theme, tokens: tokens),
        const SizedBox(height: 16),
        _LinksList(),
        const SizedBox(height: 16),
        _CopyrightLine(theme: theme, tokens: tokens),
      ],
    );
  }

  Widget _buildWideLayout(
    BuildContext context,
    ThemeData theme,
    RodnyaDesignTokens tokens,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 5,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _BrandBlock(
                tokens: tokens,
                theme: theme,
                future: _loadVersionLabel(),
              ),
              const SizedBox(height: 24),
              _DescriptionBlock(theme: theme, tokens: tokens),
              const SizedBox(height: 24),
              _CopyrightLine(theme: theme, tokens: tokens),
            ],
          ),
        ),
        const SizedBox(width: 32),
        Expanded(
          flex: 6,
          child: _LinksList(),
        ),
      ],
    );
  }
}

class _BrandBlock extends StatelessWidget {
  const _BrandBlock({
    required this.tokens,
    required this.theme,
    required this.future,
  });
  final RodnyaDesignTokens tokens;
  final ThemeData theme;
  final Future<String> future;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Плотность: 140dp — чисто декоративный круг без единой строки
        // информации; на телефоне это пятая часть первого экрана «О
        // приложении». 96dp по-прежнему заметно, но не съедает попусту.
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: tokens.accentSoft,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.eco_outlined,
            size: 44,
            color: tokens.accentStrong,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          'Родня',
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w800,
            color: tokens.ink,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 6),
        FutureBuilder<String>(
          future: future,
          builder: (context, snapshot) {
            final label = snapshot.data ?? 'Версия загружается…';
            return Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: tokens.inkMuted,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _DescriptionBlock extends StatelessWidget {
  const _DescriptionBlock({required this.theme, required this.tokens});
  final ThemeData theme;
  final RodnyaDesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Text(
        'Родня — приложение для семейного древа: дерево по веткам, '
        'истории и посты в кругу близких, чаты, кружочки и общий '
        'календарь. Без алгоритмических лент и шумных уведомлений.',
        style: theme.textTheme.bodyLarge?.copyWith(
          height: 1.5,
          color: tokens.inkSecondary,
        ),
      ),
    );
  }
}

class _LinksList extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);

    final links = <_LinkItem>[
      const _LinkItem(
        icon: Icons.privacy_tip_outlined,
        title: 'Политика конфиденциальности',
        path: '/privacy',
      ),
      const _LinkItem(
        icon: Icons.description_outlined,
        title: 'Условия использования',
        path: '/terms',
      ),
      const _LinkItem(
        icon: Icons.support_agent_outlined,
        title: 'Поддержка',
        subtitle: 'ahjkuio@gmail.com',
        path: '/support',
      ),
      const _LinkItem(
        icon: Icons.delete_outline_rounded,
        title: 'Удаление аккаунта',
        subtitle: 'Публичная инструкция для RuStore',
        path: '/account-deletion',
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
        border: Border.all(color: tokens.surfaceLine),
      ),
      child: Column(
        children: [
          _StaticRow(
            icon: Icons.code,
            title: 'Разработчики',
            subtitle: 'Artem Kuznetsov',
            tokens: tokens,
            theme: theme,
          ),
          for (var i = 0; i < links.length; i++) ...[
            Divider(height: 1, color: tokens.surfaceLine),
            _LinkRow(item: links[i], tokens: tokens, theme: theme),
          ],
        ],
      ),
    );
  }
}

class _LinkItem {
  const _LinkItem({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.path,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final String path;
}

class _StaticRow extends StatelessWidget {
  const _StaticRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tokens,
    required this.theme,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final RodnyaDesignTokens tokens;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: tokens.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: tokens.accentStrong),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: tokens.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: tokens.inkMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.item,
    required this.tokens,
    required this.theme,
  });
  final _LinkItem item;
  final RodnyaDesignTokens tokens;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push(item.path),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: tokens.accentSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(item.icon, size: 20, color: tokens.accentStrong),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: tokens.ink,
                    ),
                  ),
                  if (item.subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      item.subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: tokens.inkMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: tokens.inkMuted,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyrightLine extends StatelessWidget {
  const _CopyrightLine({required this.theme, required this.tokens});
  final ThemeData theme;
  final RodnyaDesignTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '© 2026 Родня. Все права защищены.',
        style: theme.textTheme.bodySmall?.copyWith(color: tokens.inkMuted),
      ),
    );
  }
}
