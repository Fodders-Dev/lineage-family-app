import 'package:flutter_test/flutter_test.dart';
import 'package:lineage/startup/startup_failure_policy.dart';

void main() {
  test('offers session reset copy for session-like startup failures', () {
    expect(
      looksLikeRecoverableSessionIssue(
        const FormatException('Сессия не найдена или истекла'),
      ),
      isTrue,
    );
    expect(
      startupFailureMessageFor(
        TypeError(),
        canResetSession: true,
      ),
      'Сохранённая сессия входа больше не подходит. Сбросьте её и откройте экран входа заново.',
    );
  });

  test('keeps generic startup copy without persisted session recovery', () {
    expect(
      startupFailureMessageFor(
        StateError('network timeout'),
        canResetSession: false,
      ),
      'Не удалось открыть Родню. Попробуйте ещё раз. Если проблема повторится, проверьте интернет и повторите позже.',
    );
  });
}
