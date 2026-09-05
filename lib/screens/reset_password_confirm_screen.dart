// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../widgets/dismiss_keyboard.dart';
import '../widgets/glass_panel.dart';

/// Final step of the password-reset flow. The user lands here from
/// the deep-link in their email — the link carries `?token=<43-char
/// random>` which we forward to `confirmPasswordReset(...)` along
/// with the new password they type.
///
/// Backend invariants we rely on:
///   * Token is single-use — replay returns the same generic "ссылка
///     недействительна" error.
///   * Token is 24-hour TTL — expired returns the same generic error.
///   * Password length validation (8-1024) is server-side too, but we
///     pre-validate here so the round-trip is instant and the token
///     isn't burned on a malformed-password attempt.
///   * On success the backend rotates the password AND invalidates
///     all existing sessions — the user must re-login on every
///     device. We surface this with a snackbar + push to /login.
class ResetPasswordConfirmScreen extends StatefulWidget {
  const ResetPasswordConfirmScreen({super.key, required this.token});

  /// 32-byte base64url-encoded random token, ~43 characters.
  final String token;

  @override
  _ResetPasswordConfirmScreenState createState() =>
      _ResetPasswordConfirmScreenState();
}

class _ResetPasswordConfirmScreenState
    extends State<ResetPasswordConfirmScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();

  bool _isLoading = false;
  bool _isObscured = true;
  String? _errorMessage;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    if (widget.token.isEmpty) {
      setState(() {
        _errorMessage =
            'В ссылке не оказалось токена. Запросите новое письмо.';
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await _authService.confirmPasswordReset(
        token: widget.token,
        newPassword: _passwordController.text,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Пароль обновлён. Мы вышли из всех других устройств — войдите снова.',
          ),
          duration: Duration(seconds: 5),
        ),
      );
      // Backend invalidated every existing session, so we go to
      // /login regardless of whether this device was logged in.
      context.go('/login');
    } catch (error) {
      if (!mounted) return;
      // Backend returns the SAME generic error for invalid /
      // expired / replayed tokens — we mirror that here so we
      // don't leak which failure mode hit. "Не удалось — запросите
      // новую ссылку" works for all three cases.
      setState(() {
        _errorMessage =
            'Ссылка недействительна или истекла. Запросите новое письмо.';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Новый пароль')),
      body: DismissKeyboardOnTap(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                scheme.primary.withValues(alpha: 0.08),
                scheme.surface,
                scheme.secondary.withValues(alpha: 0.05),
              ],
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: GlassPanel(
                  padding: const EdgeInsets.all(22),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Density chunk 18: dropped the 52dp icon box —
                        // AppBar already carries a title ("Новый пароль")
                        // above, so this in-card headline is the only
                        // place that needs to spell out the actual step
                        // ("Установите новый пароль" — kept, tested); no
                        // reason to also reserve 68dp for an icon nobody
                        // reads.
                        Text(
                          'Установите новый пароль',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Минимум 8 символов. После сохранения мы выйдем со всех ваших устройств — войдите заново с новым паролем.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: _passwordController,
                          obscureText: _isObscured,
                          autofocus: true,
                          decoration: InputDecoration(
                            labelText: 'Новый пароль',
                            prefixIcon: const Icon(Icons.lock_outlined),
                            suffixIcon: IconButton(
                              tooltip: _isObscured
                                  ? 'Показать пароль'
                                  : 'Скрыть пароль',
                              icon: Icon(
                                _isObscured
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                              onPressed: () => setState(() {
                                _isObscured = !_isObscured;
                              }),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                            ),
                          ),
                          validator: (value) {
                            final v = value ?? '';
                            if (v.length < 8) {
                              return 'Минимум 8 символов';
                            }
                            if (v.length > 1024) {
                              // Mirrors the backend's upper bound,
                              // which exists to keep scrypt's
                              // wall-clock bounded under attack.
                              return 'Слишком длинный пароль';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: _confirmPasswordController,
                          obscureText: _isObscured,
                          decoration: InputDecoration(
                            labelText: 'Повторите пароль',
                            prefixIcon: const Icon(Icons.lock_outlined),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(22),
                            ),
                          ),
                          onFieldSubmitted: (_) => _submit(),
                          validator: (value) {
                            if ((value ?? '') != _passwordController.text) {
                              return 'Пароли не совпадают';
                            }
                            return null;
                          },
                        ),
                        if (_errorMessage != null) ...[
                          const SizedBox(height: 14),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: scheme.errorContainer.withValues(alpha: 0.7),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.error_outline,
                                    color: scheme.error,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      _errorMessage!,
                                      style: theme.textTheme.bodyMedium
                                          ?.copyWith(
                                        color: scheme.onErrorContainer,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 22),
                        FilledButton(
                          onPressed: _isLoading ? null : _submit,
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          child: _isLoading
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Сохранить пароль'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed:
                              _isLoading ? null : () => context.go('/login'),
                          child: const Text('Отмена'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
