// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../widgets/dismiss_keyboard.dart';
import '../widgets/glass_panel.dart';

class PasswordResetScreen extends StatefulWidget {
  const PasswordResetScreen({super.key});

  @override
  _PasswordResetScreenState createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();

  bool _isLoading = false;
  String? _message;
  bool _isSuccess = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _resetPassword() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
      _message = null;
    });

    try {
      await _authService.resetPassword(_emailController.text.trim());

      // Anti-enumeration: backend returns 202 regardless of whether
      // the email is registered. We mirror that here — saying
      // "Письмо отправлено" would leak that the email exists.
      setState(() {
        _isSuccess = true;
        _message =
            'Если такой email зарегистрирован, мы отправили инструкцию по сбросу пароля. Проверьте почту.';
      });
    } catch (e) {
      setState(() {
        _isSuccess = false;
        _message = 'Не удалось отправить запрос. Проверьте интернет и попробуйте ещё раз.';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Сброс пароля')),
      body: DismissKeyboardOnTap(
        child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.primary.withValues(alpha: 0.08),
              theme.colorScheme.surface,
              theme.colorScheme.secondary.withValues(alpha: 0.05),
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
                      // Density chunk 18: AppBar title already says
                      // «Сброс пароля» — the 52dp icon box + a second,
                      // identical headline underneath it duplicated that
                      // (~106dp of card height for nothing new). One
                      // explanatory line is enough; field + button follow
                      // immediately (no card-in-card).
                      Text(
                        'Введите email, на который вы регистрировались. Если такой адрес есть в системе, мы пришлём ссылку на сброс пароля. Ссылка действительна 24 часа.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _emailController,
                        decoration: InputDecoration(
                          labelText: 'Email',
                          hintText: 'name@example.com',
                          prefixIcon: const Icon(Icons.email_outlined),
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerLowest
                              .withValues(alpha: 0.9),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(22),
                            borderSide: BorderSide(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.3),
                            ),
                          ),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        validator: (value) {
                          if (value == null ||
                              !value.contains('@') ||
                              !value.contains('.')) {
                            return 'Введите корректный email';
                          }
                          return null;
                        },
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: 16),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: (_isSuccess
                                    ? theme.colorScheme.primaryContainer
                                    : theme.colorScheme.errorContainer)
                                .withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Row(
                              children: [
                                Icon(
                                  _isSuccess
                                      ? Icons.mark_email_read_outlined
                                      : Icons.error_outline,
                                  color: _isSuccess
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.error,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    _message!,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      color: _isSuccess
                                          ? theme.colorScheme.onPrimaryContainer
                                          : theme.colorScheme.onErrorContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (_isSuccess) ...[
                          const SizedBox(height: 10),
                          TextButton.icon(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(Icons.arrow_back),
                            label: const Text('К входу'),
                          ),
                        ],
                      ],
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _isLoading ? null : _resetPassword,
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
                            : const Text('Отправить'),
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
