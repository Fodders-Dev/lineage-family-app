bool looksLikeRecoverableSessionIssue(Object error) {
  final normalized = error.toString().toLowerCase();
  return normalized.contains('сесс') ||
      normalized.contains('session') ||
      normalized.contains('unauthorized') ||
      normalized.contains('401') ||
      normalized.contains('403') ||
      normalized.contains('typeerror');
}

String startupFailureMessageFor(
  Object error, {
  required bool canResetSession,
}) {
  if (canResetSession) {
    return 'Сохранённая сессия входа больше не подходит. Сбросьте её и откройте экран входа заново.';
  }

  return 'Не удалось открыть Родню. Попробуйте ещё раз. Если проблема повторится, проверьте интернет и повторите позже.';
}
