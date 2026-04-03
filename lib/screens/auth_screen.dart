import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/backend_provider_config.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../providers/tree_provider.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _nameFocusNode = FocusNode();

  bool _isLogin = true;
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  bool _hasSubmitted = false;
  late final bool _supportsGoogleAuth;

  final List<_AuthFeature> _mvpHighlights = const [
    _AuthFeature(
      icon: Icons.account_tree_outlined,
      title: 'Семейное дерево',
      description:
          'Создавайте дерево, открывайте его сразу в интерактивной схеме и делитесь публичной ссылкой.',
    ),
    _AuthFeature(
      icon: Icons.people_alt_outlined,
      title: 'Родные и профиль',
      description:
          'Собирайте родственников, поддерживайте профиль и быстро переходите к карточкам людей.',
    ),
    _AuthFeature(
      icon: Icons.chat_bubble_outline,
      title: 'Личные сообщения',
      description:
          'Общайтесь с родственниками в 1:1 чате без лишних разделов и переключений.',
    ),
    _AuthFeature(
      icon: Icons.public_outlined,
      title: 'Публичный вход с web',
      description:
          'Веб уже подходит как основной публичный вход, при этом мобильный сценарий не ломается.',
    ),
  ];

  @override
  void initState() {
    super.initState();
    _supportsGoogleAuth = BackendProviderConfig.current.authProvider !=
        BackendProviderKind.customApi;
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _emailFocusNode.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _hasSubmitted = true;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      if (_isLogin) {
        await _authService.loginWithEmail(
          _emailController.text.trim(),
          _passwordController.text,
        );
      } else {
        await _authService.registerWithEmail(
          email: _emailController.text.trim(),
          password: _passwordController.text,
          name: _nameController.text.trim(),
        );
      }

      if (_authService.currentUserId != null) {
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().loadInitialTree();
        }

        if (!mounted) {
          return;
        }

        context.go('/');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isLogin
                  ? 'Вход выполнен успешно.'
                  : 'Регистрация успешна. Добро пожаловать в Родню.',
            ),
            backgroundColor: Colors.green,
          ),
        );
        return;
      }

      throw Exception('Ошибка авторизации: пользователь не найден');
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_authService.describeError(e)),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isGoogleLoading = true;
    });

    try {
      await _authService.signInWithGoogle();

      if (mounted && _authService.currentUserId != null) {
        context.go('/');
      }
    } catch (e) {
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Ошибка входа через Google: $e'),
          backgroundColor: Colors.red.shade800,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleLoading = false;
        });
      }
    }
  }

  void _setMode(bool isLogin) {
    setState(() {
      _isLogin = isLogin;
      _hasSubmitted = false;
    });
  }

  void _focusPrimaryField() {
    final focusNode = _isLogin ? _emailFocusNode : _nameFocusNode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      focusNode.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.14),
              const Color(0xFFF7F2E8),
              theme.colorScheme.secondary.withValues(alpha: 0.08),
            ],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 960;
              return Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: isWide ? 1180 : 520,
                  ),
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: isWide ? 24 : 16,
                      vertical: isWide ? 28 : 16,
                    ),
                    child: isWide
                        ? _buildWideLayout(theme)
                        : _buildCompactLayout(theme),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildWideLayout(ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 11,
          child: Padding(
            padding: const EdgeInsets.only(right: 20),
            child: _buildHeroPanel(theme, compact: false),
          ),
        ),
        Expanded(
          flex: 9,
          child: Align(
            alignment: Alignment.center,
            child: SingleChildScrollView(
              child: _buildAuthCard(theme, compact: false),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCompactLayout(ThemeData theme) {
    return SingleChildScrollView(
      child: _buildAuthCard(theme, compact: true),
    );
  }

  Widget _buildHeroPanel(ThemeData theme, {required bool compact}) {
    final colorScheme = theme.colorScheme;

    return Container(
      padding: EdgeInsets.all(compact ? 20 : 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary,
            const Color(0xFF155B52),
            const Color(0xFF2F7A63),
          ],
        ),
        borderRadius: BorderRadius.circular(32),
        boxShadow: [
          BoxShadow(
            color: colorScheme.primary.withValues(alpha: 0.18),
            blurRadius: 30,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Colors.white24),
              ),
              child: const Text(
                'Родня',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            SizedBox(height: compact ? 18 : 24),
            Text(
              'Семейное дерево и связи для близких',
              style: theme.textTheme.displaySmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
                height: 1.05,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Вход и регистрация открывают дерево семьи, профили родственников, личные сообщения и публичный просмотр дерева.',
              style: theme.textTheme.titleMedium?.copyWith(
                color: Colors.white.withValues(alpha: 0.9),
                fontWeight: FontWeight.w400,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 18),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: const [
                _HeroChip(label: 'Семейное дерево'),
                _HeroChip(label: 'Личные связи'),
                _HeroChip(label: 'Профиль семьи'),
                _HeroChip(label: 'Публичный просмотр дерева'),
              ],
            ),
            SizedBox(height: compact ? 18 : 26),
            if (!compact)
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  FilledButton.icon(
                    onPressed: _isLoading || _isGoogleLoading
                        ? null
                        : () {
                            _setMode(true);
                            _focusPrimaryField();
                          },
                    icon: const Icon(Icons.login),
                    label: const Text('Войти сейчас'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: colorScheme.primary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isLoading || _isGoogleLoading
                        ? null
                        : () {
                            _setMode(false);
                            _focusPrimaryField();
                          },
                    icon: const Icon(Icons.family_restroom_outlined),
                    label: const Text('Зарегистрироваться'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white38),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 16,
                      ),
                    ),
                  ),
                ],
              ),
            SizedBox(height: compact ? 18 : 26),
            ..._mvpHighlights.map(
              (feature) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _FeatureCard(
                  feature: feature,
                  compact: compact,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthCard(ThemeData theme, {required bool compact}) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 460),
      padding: EdgeInsets.all(compact ? 20 : 28),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.black12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 28,
            offset: const Offset(0, 14),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        autovalidateMode: _hasSubmitted
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (compact) ...[
              _buildModeToggle(theme),
              const SizedBox(height: 18),
            ],
            Text(
              _isLogin ? 'Вход в Родню' : 'Создать аккаунт',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              _isLogin
                  ? compact
                      ? 'Дерево, родные и чат в одном аккаунте.'
                      : 'Откройте дерево семьи, профиль и личные связи.'
                  : compact
                      ? 'Регистрация занимает меньше минуты.'
                      : 'Начните с аккаунта, затем создайте или выберите своё дерево.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.grey[700],
                height: 1.45,
              ),
              textAlign: TextAlign.center,
            ),
            SizedBox(height: compact ? 18 : 22),
            if (!compact) ...[
              _buildModeToggle(theme),
              const SizedBox(height: 22),
            ],
            if (!_isLogin) ...[
              TextFormField(
                controller: _nameController,
                focusNode: _nameFocusNode,
                decoration: const InputDecoration(
                  labelText: 'Как вас зовут',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                keyboardType: TextInputType.name,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                validator: (value) {
                  if (!_isLogin && (value == null || value.trim().length < 2)) {
                    return 'Имя должно содержать не менее 2 символов';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
            ],
            TextFormField(
              controller: _emailController,
              focusNode: _emailFocusNode,
              decoration: const InputDecoration(
                labelText: 'Email',
                prefixIcon: Icon(Icons.alternate_email),
              ),
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              validator: (value) {
                if (value == null ||
                    !value.contains('@') ||
                    !value.contains('.')) {
                  return 'Введите корректный email адрес';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'Пароль',
                prefixIcon: Icon(Icons.lock_outline),
              ),
              obscureText: true,
              textInputAction:
                  _isLogin ? TextInputAction.done : TextInputAction.next,
              onFieldSubmitted: (_) {
                if (_isLogin) {
                  _submit();
                }
              },
              validator: (value) {
                if (value == null || value.length < 6) {
                  return 'Пароль должен содержать не менее 6 символов';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _isLoading || _isGoogleLoading ? null : _submit,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : Text(_isLogin ? 'Войти' : 'Зарегистрироваться'),
            ),
            if (_supportsGoogleAuth) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      'или',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.grey[700],
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed:
                    _isLoading || _isGoogleLoading ? null : _signInWithGoogle,
                icon: _isGoogleLoading
                    ? SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: theme.colorScheme.primary,
                        ),
                      )
                    : const Icon(
                        Icons.g_mobiledata,
                        size: 28,
                        color: Colors.red,
                      ),
                label: const Text('Войти через Google'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              onPressed: _isLoading || _isGoogleLoading
                  ? null
                  : () {
                      _setMode(!_isLogin);
                      _focusPrimaryField();
                    },
              child: Text(
                _isLogin
                    ? 'Нет аккаунта? Зарегистрируйтесь'
                    : 'Уже есть аккаунт? Войдите',
              ),
            ),
            if (_isLogin)
              TextButton(
                onPressed:
                    _isLoading ? null : () => context.push('/password_reset'),
                child: const Text('Забыли пароль?'),
              ),
            if (compact) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 8,
                children: const [
                  _CompactFeatureChip(label: 'Дерево'),
                  _CompactFeatureChip(label: 'Родные'),
                  _CompactFeatureChip(label: 'Чат'),
                ],
              ),
            ],
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => GoRouter.of(context).push('/privacy'),
              child: Text(
                'Продолжая, вы соглашаетесь с Политикой конфиденциальности.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey[700],
                  decoration: TextDecoration.underline,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeToggle(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color:
                    _isLogin ? theme.colorScheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: TextButton(
                onPressed: _isLoading || _isGoogleLoading
                    ? null
                    : () {
                        _setMode(true);
                        _focusPrimaryField();
                      },
                child: Text(
                  'Вход',
                  style: TextStyle(
                    color: _isLogin ? Colors.white : theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(
                color:
                    !_isLogin ? theme.colorScheme.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: TextButton(
                onPressed: _isLoading || _isGoogleLoading
                    ? null
                    : () {
                        _setMode(false);
                        _focusPrimaryField();
                      },
                child: Text(
                  'Регистрация',
                  style: TextStyle(
                    color: !_isLogin ? Colors.white : theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.feature,
    required this.compact,
  });

  final _AuthFeature feature;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: compact ? 0.1 : 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(feature.icon, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  feature.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  feature.description,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    height: 1.45,
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

class _CompactFeatureChip extends StatelessWidget {
  const _CompactFeatureChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _AuthFeature {
  const _AuthFeature({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}
