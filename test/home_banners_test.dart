// Чанк D: покрытие 2b-поведения условных баннеров home (виджеты имели
// ноль тестов): session-dismiss у OnboardingResumeBanner и закрываемая
// компактная BatteryOptimizationCard с гайдлайновым тап-таргетом.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:rodnya/backend/interfaces/auth_service_interface.dart';
import 'package:rodnya/backend/interfaces/family_tree_service_interface.dart';
import 'package:rodnya/backend/interfaces/onboarding_capable_family_tree_service.dart';
import 'package:rodnya/backend/models/onboarding_state.dart';
import 'package:rodnya/services/battery_optimization_advisor.dart';
import 'package:rodnya/widgets/battery_optimization_card.dart';
import 'package:rodnya/widgets/onboarding_resume_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuthService implements AuthServiceInterface {
  final StreamController<String?> _authController =
      StreamController<String?>.broadcast();

  @override
  String? get currentUserId => 'user-1';

  @override
  Stream<String?> get authStateChanges => _authController.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Сервис со skipped-визардом → баннер «Закончите настройку» показывается.
class _SkippedOnboardingFamilyService
    implements FamilyTreeServiceInterface, OnboardingCapableFamilyTreeService {
  @override
  Future<OnboardingState> getOnboardingState() async => const OnboardingState(
        userId: 'user-1',
        completed: false,
        currentStep: OnboardingStep.welcome,
        skipped: true,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Advisor, который всегда советует показать карточку, и фиксирует
/// дисмисс (в проде он персистится в SharedPreferences).
class _FakeBatteryAdvisor extends BatteryOptimizationAdvisor {
  _FakeBatteryAdvisor(SharedPreferences prefs) : super(preferences: prefs);

  bool dismissed = false;

  @override
  Future<bool> shouldShowOnboardingTip() async => !dismissed;

  @override
  Future<void> markOnboardingTipShown() async {
    dismissed = true;
  }
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await getIt.reset();
    OnboardingResumeBanner.debugResetSessionDismissal();
  });

  tearDown(() async {
    await getIt.reset();
    OnboardingResumeBanner.debugResetSessionDismissal();
  });

  group('OnboardingResumeBanner (2b session-dismiss)', () {
    Future<void> pumpBanner(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: OnboardingResumeBanner())),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('показывается при skipped-визарде и закрывается «Скрыть»',
        (tester) async {
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _SkippedOnboardingFamilyService(),
      );

      await pumpBanner(tester);
      expect(find.text('Закончите настройку дерева'), findsOneWidget);

      // Тап-таргет закрытия — гайдлайновые ≥44dp (2c-ритм).
      final closeSize = tester.getSize(find.byTooltip('Скрыть'));
      expect(closeSize.width, greaterThanOrEqualTo(44.0));
      expect(closeSize.height, greaterThanOrEqualTo(44.0));

      await tester.tap(find.byTooltip('Скрыть'));
      await tester.pumpAndSettle();
      expect(find.text('Закончите настройку дерева'), findsNothing);
    });

    testWidgets('после дисмисса не возвращается в той же сессии',
        (tester) async {
      getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
      getIt.registerSingleton<FamilyTreeServiceInterface>(
        _SkippedOnboardingFamilyService(),
      );

      await pumpBanner(tester);
      await tester.tap(find.byTooltip('Скрыть'));
      await tester.pumpAndSettle();

      // Полностью новый инстанс виджета (новый экран той же сессии) —
      // static-флаг держит баннер скрытым.
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpBanner(tester);

      expect(find.text('Закончите настройку дерева'), findsNothing);
    });
  });

  group('BatteryOptimizationCard (2b компактная, закрываемая)', () {
    testWidgets('видна на «агрессивном» девайсе; X ≥44dp; дисмисс персистится',
        (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final advisor = _FakeBatteryAdvisor(prefs);
      getIt.registerSingleton<BatteryOptimizationAdvisor>(advisor);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: BatteryOptimizationCard())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Разрешите автозапуск «Родне»'), findsOneWidget);
      // Плотность, чанк 17: полноширинная кнопка «Разрешить автозапуск» →
      // компактная «Настроить» в строке (тот же обработчик _openSettings).
      expect(find.text('Настроить'), findsOneWidget);

      final closeSize = tester.getSize(find.byTooltip('Скрыть'));
      expect(closeSize.width, greaterThanOrEqualTo(44.0));
      expect(closeSize.height, greaterThanOrEqualTo(44.0));

      await tester.tap(find.byTooltip('Скрыть'));
      await tester.pumpAndSettle();

      expect(find.text('Разрешите автозапуск «Родне»'), findsNothing);
      expect(advisor.dismissed, isTrue);
    });

    testWidgets('без зарегистрированного advisor — ничего не рендерит',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: BatteryOptimizationCard())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Разрешите автозапуск «Родне»'), findsNothing);
    });
  });
}
