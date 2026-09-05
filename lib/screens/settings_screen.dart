// ignore_for_file: constant_identifier_names, unused_field, use_build_context_synchronously
// ignore_for_file: library_private_types_in_public_api
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../backend/backend_runtime_config.dart';
import '../providers/theme_provider.dart';
import '../theme/app_theme.dart';
import '../services/rustore_service.dart';
// Импортируем типы для биллинга
import 'package:flutter_rustore_billing/pigeons/rustore.dart' as billing;
import 'package:get_it/get_it.dart'; // Для доступа к RustoreService
import 'package:go_router/go_router.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/semya_capable_family_tree_service.dart';
import '../providers/tree_provider.dart';
import '../screens/semya_details_screen.dart';
import '../screens/trash_screen.dart';
import '../widgets/hidden_semya_picker_sheet.dart';
import '../services/custom_api_notification_service.dart';
import '../services/browser_notification_bridge.dart';
import '../services/app_status_service.dart';
import '../services/audio_route_service.dart';
import '../services/call_preferences.dart';
import '../config/storefront_config.dart';
import '../widgets/glass_panel.dart';
import '../widgets/flow_overlays.dart';
import '../widgets/sign_out_confirmation_dialog.dart';
import '../utils/user_facing_error.dart';

// --- ID нашего тестового продукта ---
const String PREMIUM_PRODUCT_ID = 'rodnya_premium';
// --- ID для разовой покупки ---
const String ONE_TIME_PRODUCT_ID = 'rodnya_premium_product';

class _LatestAndroidApk {
  const _LatestAndroidApk({
    required this.url,
    required this.versionCode,
    this.versionName,
  });

  final String url;
  final int versionCode;
  final String? versionName;

  String get label {
    final version = versionName?.trim();
    if (version != null && version.isNotEmpty) {
      return 'Версия $version (сборка $versionCode)';
    }
    return 'Сборка $versionCode';
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  // Получаем RustoreService из GetIt
  final RustoreService _rustoreService = GetIt.I<RustoreService>();
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();
  final StorefrontConfig _storefrontConfig = StorefrontConfig.current;
  late final CallPreferences _callPreferences =
      GetIt.I.isRegistered<CallPreferences>()
          ? GetIt.I<CallPreferences>()
          : MemoryCallPreferences();
  bool _isLoading = false;
  bool _notificationsEnabled = true;
  bool _profilePrivate = false;
  CallPreferencesSnapshot _callSettings = CallPreferencesSnapshot.defaults();
  bool _callSettingsLoading = true;
  bool _callSettingsSaving = false;

  // Состояние для премиума
  bool _isPremium = false;
  String? _lastPurchaseId; // Для возможности удаления тестовой покупки
  bool _billingLoading = true; // Индикатор загрузки статуса покупки
  // --- Состояние для разовой покупки ---
  bool _oneTimePurchaseLoading = false;
  String _appVersionLabel = 'Версия загружается...';
  bool _latestAndroidApkLoading = kIsWeb;
  _LatestAndroidApk? _latestAndroidApk;

  // --- Состояние для оценки приложения ---
  bool _hasRatedApp = false; // Изначально считаем, что не оценил
  bool _checkingRatingStatus = true; // Индикатор загрузки статуса оценки

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
    if (kIsWeb) {
      unawaited(_loadLatestAndroidApk());
    }
    _loadNotificationSettings();
    _loadCallPreferences();
    if (_showPremiumSection) {
      _checkPremiumStatus();
    } else {
      _billingLoading = false;
    }
    if (_showReviewSection) {
      _checkAppRatingStatus();
    } else {
      _checkingRatingStatus = false;
    }
  }

  CustomApiNotificationService? get _customNotificationService =>
      GetIt.I.isRegistered<CustomApiNotificationService>()
          ? GetIt.I<CustomApiNotificationService>()
          : null;

  bool get _showPremiumSection =>
      _storefrontConfig.isRustore && _storefrontConfig.enableRustoreBilling;

  bool get _showReviewSection =>
      _storefrontConfig.isRustore && _storefrontConfig.enableRustoreReview;

  Future<void> _loadAppVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    if (!mounted) {
      return;
    }
    setState(() {
      _appVersionLabel =
          'Версия ${packageInfo.version} (сборка ${packageInfo.buildNumber})';
    });
  }

  Future<void> _loadLatestAndroidApk() async {
    if (!kIsWeb) return;
    try {
      final runtimeConfig = GetIt.I.isRegistered<BackendRuntimeConfig>()
          ? GetIt.I<BackendRuntimeConfig>()
          : BackendRuntimeConfig.current;
      final base = runtimeConfig.apiBaseUrl.replaceFirst(RegExp(r'/$'), '');
      final response = await http
          .get(Uri.parse('$base/v1/app/latest'))
          .timeout(const Duration(seconds: 8));
      _LatestAndroidApk? latest;
      if (response.statusCode >= 200 &&
          response.statusCode < 300 &&
          response.body.trim().isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final versionCode =
              int.tryParse(decoded['versionCode']?.toString() ?? '');
          final apkUrl = decoded['apkUrl']?.toString().trim() ?? '';
          final uri = Uri.tryParse(apkUrl);
          if (versionCode != null &&
              versionCode > 0 &&
              uri != null &&
              uri.scheme.toLowerCase() == 'https' &&
              (uri.host.isNotEmpty)) {
            final rawVersionName = decoded['versionName']?.toString().trim();
            latest = _LatestAndroidApk(
              url: apkUrl,
              versionCode: versionCode,
              versionName: rawVersionName == null ||
                      rawVersionName.isEmpty ||
                      rawVersionName.toLowerCase() == 'null'
                  ? null
                  : rawVersionName,
            );
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _latestAndroidApk = latest;
        _latestAndroidApkLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _latestAndroidApk = null;
        _latestAndroidApkLoading = false;
      });
    }
  }

  Future<void> _openLatestAndroidApk() async {
    final latest = _latestAndroidApk;
    if (latest == null) {
      return;
    }
    final uri = Uri.parse(latest.url);
    final launched = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
    if (!launched && mounted) {
      _showMessage(
        'Не удалось открыть ссылку на APK.',
        backgroundColor: Theme.of(context).colorScheme.error,
      );
    }
  }

  Future<void> _loadNotificationSettings() async {
    final notificationService = _customNotificationService;
    if (notificationService == null || !mounted) {
      return;
    }

    setState(() {
      _notificationsEnabled = notificationService.notificationsEnabled;
    });
  }

  /// Ship FE7b (2026-05-26): hidden-persons entry point handler.
  /// Resolves caller's семья list → routes по count. Backend list call
  /// best-effort (network blip → snackbar). Picker shown только когда
  /// ≥2 семей; single-семя skips picker для меньшего trения.
  Future<void> _openHiddenPersonsEntry() async {
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Семьи временно недоступны')),
      );
      return;
    }
    final service = GetIt.I<FamilyTreeServiceInterface>();
    if (service is! SemyaCapableFamilyTreeService) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Семьи временно недоступны')),
      );
      return;
    }
    final capable = service as SemyaCapableFamilyTreeService;
    try {
      final semyi = await capable.listMySemya();
      if (!mounted) return;
      if (semyi.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'У вас пока нет семьи — список скрытых появится, когда '
              'присоединитесь к семье',
            ),
          ),
        );
        return;
      }
      if (semyi.length == 1) {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SemyaDetailsScreen(
              semyaId: semyi.first.id,
              scrollToHidden: true,
            ),
          ),
        );
        return;
      }
      // 2+ семей — picker sheet.
      await showHiddenSemyaPickerSheet(context, semyi: semyi);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Не удалось загрузить семьи: $error')),
      );
    }
  }

  Future<void> _toggleNotifications(bool value) async {
    final notificationService = _customNotificationService;

    // N3: на iOS-Safari вне установленного PWA запрашивать разрешение
    // бессмысленно (Safari молча проигнорирует) — подсказываем установку.
    if (value && (notificationService?.iosNeedsStandaloneForPush ?? false)) {
      _showMessage(
        'Чтобы получать уведомления, добавьте «Родню» на экран «Домой» '
        '(меню «Поделиться» → «На экран „Домой“»).',
      );
      return;
    }

    var nextValue = value;

    try {
      if (notificationService != null) {
        nextValue = await notificationService.setNotificationsEnabled(
          value,
          promptForBrowserPermission: value,
        );

        if (!mounted) {
          return;
        }

        if (value && !nextValue) {
          _showMessage(
            'Разрешите уведомления в браузере, чтобы не пропустить сообщения и приглашения.',
          );
        }
      }
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось обновить настройки уведомлений.',
      );
      if (!mounted) {
        return;
      }
      _showMessage(
        describeUserFacingError(
          authService: _authService,
          error: error,
          fallbackMessage: _appStatusService.isOffline
              ? 'Нет соединения. Настройка применится, когда интернет вернётся.'
              : 'Не удалось обновить настройки уведомлений. Попробуйте ещё раз.',
        ),
      );
      nextValue = _notificationsEnabled;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _notificationsEnabled = nextValue;
    });
  }

  Future<void> _loadCallPreferences() async {
    try {
      final snapshot = await _callPreferences.load();
      if (!mounted) {
        return;
      }
      setState(() {
        _callSettings = snapshot;
        _callSettingsLoading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _callSettings = CallPreferencesSnapshot.defaults();
        _callSettingsLoading = false;
      });
    }
  }

  Future<void> _saveCallPreferences(
    CallPreferencesSnapshot snapshot, {
    String? successMessage,
  }) async {
    setState(() {
      _callSettingsSaving = true;
    });
    try {
      await _callPreferences.save(snapshot);
      if (!mounted) {
        return;
      }
      setState(() {
        _callSettings = snapshot;
      });
      if (successMessage != null) {
        _showMessage(successMessage);
      }
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось сохранить настройки звонков.',
      );
      if (mounted) {
        _showMessage('Не удалось сохранить настройки звонков.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _callSettingsSaving = false;
        });
      }
    }
  }

  Future<void> _chooseDefaultMicrophone() async {
    final choices = <_CallSettingsChoice>[
      const _CallSettingsChoice(
        id: null,
        label: 'Системный микрофон',
        subtitle: 'Выбирать автоматически',
        icon: Icons.settings_voice_rounded,
      ),
    ];
    try {
      final devices = await Hardware.instance.audioInputs();
      for (final device in devices) {
        choices.add(_choiceFromMediaDevice(device, Icons.mic_rounded));
      }
    } catch (_) {}

    final choice = await _showCallChoiceSheet(
      title: 'Микрофон по умолчанию',
      choices: choices,
      selectedId: _callSettings.defaultMicrophoneDeviceId,
    );
    if (choice == null) {
      return;
    }
    await _saveCallPreferences(
      _callSettings.copyWith(defaultMicrophoneDeviceId: choice.id),
      successMessage: 'Микрофон по умолчанию обновлён.',
    );
  }

  Future<void> _chooseDefaultCamera() async {
    final choices = <_CallSettingsChoice>[
      const _CallSettingsChoice(
        id: null,
        label: 'Системная камера',
        subtitle: 'Выбирать автоматически',
        icon: Icons.videocam_rounded,
      ),
    ];
    try {
      final devices = await Hardware.instance.videoInputs();
      for (final device in devices) {
        choices.add(_choiceFromMediaDevice(device, Icons.videocam_rounded));
      }
    } catch (_) {}

    final choice = await _showCallChoiceSheet(
      title: 'Камера по умолчанию',
      choices: choices,
      selectedId: _callSettings.defaultCameraDeviceId,
    );
    if (choice == null) {
      return;
    }
    await _saveCallPreferences(
      _callSettings.copyWith(defaultCameraDeviceId: choice.id),
      successMessage: 'Камера по умолчанию обновлена.',
    );
  }

  Future<void> _chooseDefaultAudioOutput() async {
    // CA1 (ревью A): этому пикеру нужен только СПИСОК маршрутов — он не
    // ведёт звонок. Без enableNativeAudio:false он на Android создал бы
    // второй NativeCallAudio на общем канале rodnya/call_audio, перехватил
    // бы обработчик у живого синглтона звонка, а на dispose снял бы его
    // совсем — и внутризвонковое отражение смены устройств (FR5) сломалось
    // бы до конца сессии. Перечисление маршрутов идёт через LiveKit.
    final audioRouteService = AudioRouteService(enableNativeAudio: false);
    final choices = <_CallSettingsChoice>[
      const _CallSettingsChoice(
        id: null,
        label: 'Системный аудиовыход',
        subtitle: 'Выбирать автоматически',
        icon: Icons.spatial_audio_off_rounded,
      ),
    ];
    try {
      await audioRouteService.refreshRoutes();
      for (final route in audioRouteService.routes) {
        choices.add(
          _CallSettingsChoice(
            id: route.id,
            label: route.label,
            subtitle: _audioRouteTypeLabel(route.type),
            icon: _audioRouteIcon(route.type),
          ),
        );
      }
    } catch (_) {
      choices.addAll(const <_CallSettingsChoice>[
        _CallSettingsChoice(
          id: 'speaker',
          label: 'Динамик',
          subtitle: 'Громкая связь',
          icon: Icons.volume_up_rounded,
        ),
        _CallSettingsChoice(
          id: 'earpiece',
          label: 'Наушник',
          subtitle: 'Телефонный динамик',
          icon: Icons.phone_in_talk_rounded,
        ),
      ]);
    } finally {
      audioRouteService.dispose();
    }

    final choice = await _showCallChoiceSheet(
      title: 'Аудиовыход по умолчанию',
      choices: choices,
      selectedId: _callSettings.defaultAudioOutputId,
    );
    if (choice == null) {
      return;
    }
    await _saveCallPreferences(
      _callSettings.copyWith(defaultAudioOutputId: choice.id),
      successMessage: 'Аудиовыход по умолчанию обновлён.',
    );
  }

  Future<void> _chooseRingtone() async {
    final choices = callRingtonePresets
        .map(
          (preset) => _CallSettingsChoice(
            id: preset.id,
            label: preset.label,
            subtitle: preset.description,
            icon: preset.id == 'none'
                ? Icons.volume_off_rounded
                : Icons.notifications_active_rounded,
          ),
        )
        .toList(growable: false);

    final choice = await _showCallChoiceSheet(
      title: 'Мелодия входящего звонка',
      choices: choices,
      selectedId: _callSettings.ringtoneAsset,
    );
    if (choice == null || choice.id == null) {
      return;
    }
    await _saveCallPreferences(
      _callSettings.copyWith(ringtoneAsset: choice.id),
      successMessage: 'Мелодия звонка обновлена.',
    );
  }

  Future<void> _toggleCallVibration(bool value) {
    return _saveCallPreferences(
      _callSettings.copyWith(vibrationOnIncoming: value),
    );
  }

  IconData _audioRouteIcon(AudioRouteType type) {
    switch (type) {
      case AudioRouteType.speaker:
        return Icons.volume_up_rounded;
      case AudioRouteType.earpiece:
        return Icons.phone_in_talk_rounded;
      case AudioRouteType.bluetooth:
        return Icons.bluetooth_audio_rounded;
      case AudioRouteType.wired:
        return Icons.headphones_rounded;
      case AudioRouteType.device:
        return Icons.spatial_audio_off_rounded;
    }
  }

  String _audioRouteTypeLabel(AudioRouteType type) {
    switch (type) {
      case AudioRouteType.speaker:
        return 'Громкая связь';
      case AudioRouteType.earpiece:
        return 'Телефонный динамик';
      case AudioRouteType.bluetooth:
        return 'Bluetooth';
      case AudioRouteType.wired:
        return 'Проводные наушники';
      case AudioRouteType.device:
        return 'Устройство вывода';
    }
  }

  _CallSettingsChoice _choiceFromMediaDevice(
    MediaDevice device,
    IconData icon,
  ) {
    final label = device.label.trim().isEmpty
        ? 'Устройство ${device.deviceId}'
        : device.label.trim();
    return _CallSettingsChoice(
      id: device.deviceId,
      label: label,
      subtitle: device.deviceId,
      icon: icon,
    );
  }

  Future<_CallSettingsChoice?> _showCallChoiceSheet({
    required String title,
    required List<_CallSettingsChoice> choices,
    required String? selectedId,
  }) {
    return showModalBottomSheet<_CallSettingsChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final theme = Theme.of(context);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                ...choices.map(
                  (choice) {
                    final selected = choice.id == selectedId ||
                        (choice.id == null &&
                            (selectedId == null || selectedId.isEmpty));
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(choice.icon),
                      title: Text(choice.label),
                      subtitle: Text(choice.subtitle),
                      trailing: selected
                          ? Icon(
                              Icons.check_rounded,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(choice),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showMessage(String message, {Color? backgroundColor}) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
      ),
    );
  }

  // Функция для проверки статуса премиум
  Future<void> _checkPremiumStatus() async {
    setState(() {
      _billingLoading = true;
    });
    try {
      final purchases = await _rustoreService.checkPurchases();
      // Проверяем, есть ли среди покупок наш PREMIUM_PRODUCT_ID
      final premiumPurchase = purchases.firstWhere(
        (p) => p.productId == PREMIUM_PRODUCT_ID,
        // Возвращаем заглушку Purchase с purchaseState = null, если не найдено
        orElse: () => billing.Purchase(
          purchaseId: '',
          productId: '',
          purchaseTime: '',
          orderId: '',
          purchaseState: null,
        ),
      );

      setState(() {
        // Считаем премиумом, если покупка найдена и ее статус не null
        // (в API v8 статус может быть числом или отсутствовать? Проверяем на null)
        // Конкретные значения статусов (1=CREATED, 2=PAID, 3=CONFIRMED, 4=CANCELLED) предполагаются.
        // Пока будем считать активным, если статус не null (т.е. покупка существует).
        _isPremium = premiumPurchase.productId == PREMIUM_PRODUCT_ID &&
            premiumPurchase.purchaseState == '3';
        _lastPurchaseId = _isPremium ? premiumPurchase.purchaseId : null;
      });
    } catch (e) {
      debugPrint("Error checking premium status: $e");
      setState(() {
        _isPremium = false;
      }); // Считаем не премиумом при ошибке
    } finally {
      setState(() {
        _billingLoading = false;
      });
    }
  }

  // --- НОВАЯ ФУНКЦИЯ: Проверка, оставлял ли пользователь отзыв ---
  Future<void> _checkAppRatingStatus() async {
    setState(() {
      _checkingRatingStatus = true;
    });
    try {
      // Предполагаем, что в RustoreService есть метод, который может
      // косвенно определить, оставлял ли пользователь отзыв.
      // Например, если requestReview() больше не показывает диалог.
      // Или, если есть какой-то флаг в SharedPreferences, устанавливаемый после успешного запроса.
      // **ВАЖНО:** На данный момент у RuStore SDK нет прямого способа проверить,
      // был ли отзыв *фактически* оставлен. Мы можем только проверить,
      // был ли *запущен* процесс оценки (requestReview) и не вызвал ли он ошибку.
      // Будем использовать флаг в SharedPreferences как наиболее реалистичный вариант.
      final bool hasRequestedReview =
          await _rustoreService.checkIfReviewWasRequested(); // Пример метода
      // Исправлено: Проверяем mounted перед вызовом setState
      if (mounted) {
        setState(() {
          _hasRatedApp = hasRequestedReview;
        });
      }
    } catch (e) {
      debugPrint("Error checking app rating status: $e");
      // Оставляем _hasRatedApp = false при ошибке
    } finally {
      if (mounted) {
        setState(() {
          _checkingRatingStatus = false;
        });
      }
    }
  }

  // Функция покупки премиума
  Future<void> _purchasePremium() async {
    setState(() {
      _billingLoading = true;
    });
    try {
      // Сначала получим информацию о продукте
      final products = await _rustoreService.getProducts([PREMIUM_PRODUCT_ID]);
      if (products.isEmpty) {
        debugPrint("Product $PREMIUM_PRODUCT_ID not found in RuStore.");
        if (mounted) {
          _showMessage('Премиум сейчас недоступен. Попробуйте позже.');
        }
        setState(() {
          _billingLoading = false;
        });
        return;
      }

      final billing.PaymentResult? result =
          await _rustoreService.purchaseProduct(PREMIUM_PRODUCT_ID);

      // Временно упрощаем проверку из-за ошибок с полями PaymentResult
      if (result != null) {
        debugPrint("Purchase flow finished. Result: ${result.toString()}");
        debugPrint(
            "Purchase successful (assumed)! Now attempting to confirm...");

        // --- ДОБАВЛЯЕМ ПОДТВЕРЖДЕНИЕ ПОКУПКИ ---
        try {
          // Небольшая пауза, чтобы дать серверам RuStore обработать покупку
          await Future.delayed(const Duration(seconds: 2));

          debugPrint('Checking purchases again to find the one to confirm...');
          final purchases = await _rustoreService.checkPurchases();
          final purchaseToConfirm = purchases.firstWhere(
            (p) =>
                p.productId == PREMIUM_PRODUCT_ID &&
                p.purchaseState !=
                    '3', // Ищем НЕ подтвержденную (state 3 = CONFIRMED)
            orElse: () => billing.Purchase(
              purchaseId: '',
              productId: '',
              purchaseTime: '',
              orderId: '',
              purchaseState: null,
            ), // Заглушка
          );

          // --- ИСПРАВЛЕНИЕ NULL SAFETY ---
          final String? currentPurchaseId = purchaseToConfirm.purchaseId;
          if (currentPurchaseId != null && currentPurchaseId.isNotEmpty) {
            // Сначала проверка на null!
            debugPrint('Found purchase to confirm: $currentPurchaseId');
            await _rustoreService.confirmPurchase(
              currentPurchaseId,
            ); // Передаем не-null ID
            debugPrint('Purchase $currentPurchaseId confirmed successfully.');
            if (mounted) {
              _showMessage('Премиум успешно подключён.');
            }
          } else {
            debugPrint(
              'Could not find the new purchase to confirm (it might be already confirmed or in error state). Status will be checked.',
            );
            // Не показываем ошибку пользователю, просто проверим статус позже
          }
        } catch (confirmError) {
          debugPrint('Error confirming purchase: $confirmError');
          if (mounted) {
            _showMessage(
              'Платёж прошёл, но подтверждение ещё обрабатывается. Статус обновится автоматически.',
            );
          }
          // Продолжаем, чтобы обновить статус
        }
        // ------------------------------------

        await _checkPremiumStatus(); // Обновляем статус после покупки и попытки подтверждения
      } else {
        debugPrint(
          "Purchase flow returned null result (likely cancelled or failed).",
        );
        if (mounted) {
          _showMessage('Покупка отменена или не завершилась.');
        }
      }
    } catch (e) {
      debugPrint("Error during purchase process: $e");
      if (mounted) {
        _showMessage('Не удалось оформить премиум. Попробуйте ещё раз.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _billingLoading = false;
        });
      }
    }
  }

  // --- НОВАЯ ФУНКЦИЯ покупки РАЗОВОГО товара ---
  Future<void> _purchaseOneTimeProduct() async {
    setState(() {
      _oneTimePurchaseLoading = true;
    });
    try {
      debugPrint(
          'Attempting to get one-time product info: $ONE_TIME_PRODUCT_ID');
      final products = await _rustoreService.getProducts([ONE_TIME_PRODUCT_ID]);
      if (products.isEmpty) {
        debugPrint("Product $ONE_TIME_PRODUCT_ID not found in RuStore.");
        if (mounted) {
          _showMessage('Разовая покупка сейчас недоступна. Попробуйте позже.');
        }
        setState(() {
          _oneTimePurchaseLoading = false;
        });
        return;
      }
      // Добавим лог с информацией о продукте
      debugPrint('Product info found: ${products.first.toString()}');

      debugPrint(
          'Attempting to purchase one-time product: $ONE_TIME_PRODUCT_ID');
      final billing.PaymentResult? result =
          await _rustoreService.purchaseProduct(ONE_TIME_PRODUCT_ID);

      if (result != null) {
        debugPrint(
            "One-time purchase flow finished. Result: ${result.toString()}");
        debugPrint(
          "One-time purchase successful (assumed)! Now attempting to confirm/consume...",
        );

        // Подтверждение/Потребление разовой покупки (логика та же, что и для подписки)
        try {
          await Future.delayed(const Duration(seconds: 2));
          debugPrint(
            'Checking purchases again to find the one-time purchase to confirm...',
          );
          final purchases = await _rustoreService.checkPurchases();
          // Ищем по ID разового продукта, НЕ подтвержденную
          final purchaseToConfirm = purchases.firstWhere(
            (p) => p.productId == ONE_TIME_PRODUCT_ID && p.purchaseState != '3',
            orElse: () => billing.Purchase(
              purchaseId: '',
              productId: '',
              purchaseTime: '',
              orderId: '',
              purchaseState: null,
            ),
          );

          final String? currentPurchaseId = purchaseToConfirm.purchaseId;
          if (currentPurchaseId != null && currentPurchaseId.isNotEmpty) {
            debugPrint(
              'Found one-time purchase to confirm/consume: $currentPurchaseId',
            );
            await _rustoreService.confirmPurchase(currentPurchaseId);
            debugPrint(
              'One-time purchase $currentPurchaseId confirmed/consumed successfully.',
            );
            if (mounted) {
              _showMessage('Разовая покупка успешно завершена.');
            }
          } else {
            debugPrint(
              'Could not find the new one-time purchase to confirm/consume.',
            );
          }
        } catch (confirmError) {
          debugPrint(
              'Error confirming/consuming one-time purchase: $confirmError');
          if (mounted) {
            _showMessage(
              'Платёж прошёл, но подтверждение ещё обрабатывается. Проверьте статус чуть позже.',
            );
          }
        }
        // Статус премиума не обновляем, т.к. это разовая покупка
        // Можно добавить отдельную логику для отслеживания разовых покупок, если нужно
      } else {
        debugPrint(
          "One-time purchase flow returned null result (likely cancelled or failed).",
        );
        if (mounted) {
          _showMessage('Разовая покупка отменена или не завершилась.');
        }
      }
    } catch (e) {
      debugPrint("Error during one-time purchase process: $e");
      if (mounted) {
        _showMessage(
            'Не удалось оформить разовую покупку. Попробуйте ещё раз.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _oneTimePurchaseLoading = false;
        });
      }
    }
  }

  // Функция удаления тестовой покупки
  Future<void> _deleteTestPurchase() async {
    if (_lastPurchaseId != null) {
      setState(() {
        _billingLoading = true;
      });
      final success = await _rustoreService.deletePurchase(_lastPurchaseId!);
      if (success) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Тестовая покупка удалена.')));
        }
        _checkPremiumStatus(); // Обновляем статус
      } else {
        if (mounted) {
          _showMessage('Не удалось удалить тестовую покупку.');
        }
        setState(() {
          _billingLoading = false;
        });
      }
    }
  }

  // Функция для отображения диалога подтверждения удаления аккаунта
  Future<void> _showDeleteAccountConfirmation() async {
    final TextEditingController passwordController = TextEditingController();
    bool isPasswordVisible = false;

    return showGlassDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final theme = Theme.of(context);

            return GlassDialogFrame(
              icon: Icons.delete_forever,
              tint: theme.colorScheme.error,
              title: 'Удалить аккаунт',
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Это действие нельзя отменить.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Введите пароль для подтверждения.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 14),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLowest
                          .withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: TextField(
                      controller: passwordController,
                      obscureText: !isPasswordVisible,
                      decoration: InputDecoration(
                        hintText: 'Пароль',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                        suffixIcon: IconButton(
                          tooltip: isPasswordVisible
                              ? 'Скрыть пароль'
                              : 'Показать пароль',
                          icon: Icon(
                            isPasswordVisible
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                          onPressed: () {
                            setDialogState(() {
                              isPasswordVisible = !isPasswordVisible;
                            });
                          },
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Отмена'),
                ),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    if (passwordController.text.isNotEmpty) {
                      _deleteAccount(passwordController.text);
                    } else {
                      _showMessage(
                        'Введите пароль для удаления аккаунта.',
                        backgroundColor: theme.colorScheme.error,
                      );
                    }
                  },
                  child: const Text('Удалить'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Улучшенная функция для удаления аккаунта с надежным перенаправлением
  Future<void> _deleteAccount(String password) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await _authService.deleteAccount(password);
      if (GetIt.I.isRegistered<TreeProvider>()) {
        await GetIt.I<TreeProvider>().clearSelection();
      }

      if (mounted) {
        _showMessage(
          'Аккаунт удалён.',
          backgroundColor: Colors.green,
        );
        context.go('/login');
      }
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось удалить аккаунт.',
      );
      if (mounted) {
        _showMessage(
          describeUserFacingError(
            authService: _authService,
            error: error,
            fallbackMessage: _appStatusService.isOffline
                ? 'Нет соединения. Попробуйте удалить аккаунт, когда интернет вернётся.'
                : 'Не удалось удалить аккаунт. Проверьте пароль и попробуйте ещё раз.',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        );

        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: _isLoading
          ? _buildSettingsStateCard(
              icon: Icons.tune,
              title: 'Открываем настройки',
              message:
                  'Подтягиваем уведомления, внешний вид и параметры аккаунта.',
              showProgress: true,
            )
          : LayoutBuilder(
              builder: (context, constraints) {
                // 1180 совпадает с home/profile breakpoint — на десктопе
                // настройки расходятся в 2 колонки (управление слева,
                // справочные/сервисные секции справа), header остаётся
                // на всю ширину сверху.
                final isWide = constraints.maxWidth >= 1180;
                final primary = _buildPrimarySections(themeProvider);
                final secondary = _buildSecondarySections();
                return Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: isWide ? 1100 : 980),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (isWide)
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: _interleaveSpacing(primary),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: _interleaveSpacing(secondary),
                                  ),
                                ),
                              ],
                            )
                          else
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: _interleaveSpacing(
                                  [...primary, ...secondary]),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }

  /// 16dp gaps between sections — duplicated logic factored out so the
  /// narrow + 2 wide columns all share the same rhythm.
  List<Widget> _interleaveSpacing(List<Widget> sections) {
    final out = <Widget>[];
    for (var i = 0; i < sections.length; i++) {
      if (i > 0) out.add(const SizedBox(height: 16));
      out.add(sections[i]);
    }
    return out;
  }

  /// "Управляющие" секции: тема, уведомления, звонки. На wide уходят в
  /// левую колонку.
  List<Widget> _buildPrimarySections(ThemeProvider themeProvider) {
    return [
      _buildSectionCard('Внешний вид', [
        _buildThemePicker(themeProvider),
      ]),
      _buildSectionCard('Уведомления и доступ', [
        _buildNotificationsRow(),
        _buildSwitchRow(
          icon: Icons.lock_outline,
          title: 'Приватный профиль',
          subtitle: _profilePrivate
              ? 'Профиль доступен только приглашённым'
              : 'Профиль можно найти в Родне',
          value: _profilePrivate,
          onChanged: (value) {
            setState(() {
              _profilePrivate = value;
            });
          },
        ),
        _buildActionRow(
          icon: Icons.block_outlined,
          title: 'Заблокированные',
          subtitle: 'Личные блокировки',
          onTap: () => GoRouter.of(context).push('/profile/blocks'),
        ),
        // Phase 3.4 chunk 3: edit grants outgoing/incoming.
        // Subtitle намеренно privacy-first — outgoing-таб (контроль
        // прав на свои карточки) важнее incoming'а (списка где
        // тебе разрешено редактировать). Юзер открывает screen
        // ради защиты, а не discovery.
        _buildActionRow(
          icon: Icons.key_rounded,
          title: 'Доступы',
          subtitle: 'Кто редактирует ваши карточки',
          onTap: () => GoRouter.of(context).push('/profile/access'),
        ),
        _buildActionRow(
          icon: Icons.devices_rounded,
          title: 'Активные сеансы',
          subtitle: 'Управление устройствами и QR-вход',
          onTap: () => GoRouter.of(context).push('/profile/sessions'),
        ),
        // Ship FE7b (2026-05-26): entry point для HiddenPersonsSection в
        // FE2 семя details. Tap → fetch semyi → routing по count:
        //   0 → snackbar «Нет семей»
        //   1 → direct push к семя details с scroll
        //   2+ → picker sheet
        _buildActionRow(
          icon: Icons.visibility_off_outlined,
          title: 'Скрытые родственники',
          subtitle: 'Управлять списком в своей семье',
          onTap: _openHiddenPersonsEntry,
        ),
        // Ship Q4a frontend (2026-05-28, Ship 31): «Корзина» cross-семя.
        // Объединяет caller's удалённые карточки + посты с 30-дневным
        // окном восстановления. Push к dedicated TrashScreen — счётчик
        // намеренно отсутствует чтобы избежать extra round-trip при
        // открытии настроек (TrashScreen грузит сам).
        _buildActionRow(
          icon: Icons.delete_outline_rounded,
          title: 'Корзина',
          subtitle: 'Удалённые карточки и посты — 30 дней до удаления',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const TrashScreen(),
            ),
          ),
        ),
      ]),
      _buildCallSettingsSection(),
    ];
  }

  /// "Сервисные" секции: документы, RuStore, обратная связь, аккаунт,
  /// удаление. На wide уходят в правую колонку.
  List<Widget> _buildSecondarySections() {
    return [
      _buildSectionCard('Документы и поддержка', [
        _buildActionRow(
          icon: Icons.privacy_tip_outlined,
          title: 'Политика',
          subtitle: 'Конфиденциальность',
          onTap: () => GoRouter.of(context).push('/privacy'),
        ),
        _buildActionRow(
          icon: Icons.description_outlined,
          title: 'Условия',
          subtitle: 'Использование',
          onTap: () => GoRouter.of(context).push('/terms'),
        ),
        _buildActionRow(
          icon: Icons.support_agent_outlined,
          title: 'Поддержка',
          subtitle: 'Почта и страница',
          onTap: () => GoRouter.of(context).push('/support'),
        ),
        _buildActionRow(
          icon: Icons.delete_outline_rounded,
          title: 'Как удалить аккаунт',
          subtitle: 'Публичная инструкция',
          onTap: () => GoRouter.of(context).push('/account-deletion'),
        ),
        _buildActionRow(
          icon: Icons.info_outline,
          title: 'О приложении',
          subtitle: _appVersionLabel,
          onTap: () => context.push('/profile/about'),
        ),
      ]),
      if (kIsWeb)
        _buildSectionCard('Android-приложение', [
          _buildAndroidDownloadRow(),
        ]),
      if (_showPremiumSection)
        _buildSectionCard('RuStore', [
          _billingLoading
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                )
              : _buildPremiumRow(),
          if (_isPremium && _lastPurchaseId != null)
            _buildActionRow(
              icon: Icons.restart_alt_rounded,
              title: 'Сбросить тестовую покупку',
              subtitle: 'Только для dev-проверки',
              onTap: _deleteTestPurchase,
            ),
          _buildOneTimePurchaseRow(),
        ]),
      _buildSectionCard('Обратная связь', [
        if (_showReviewSection)
          _checkingRatingStatus
              ? const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(
                    child: CircularProgressIndicator(),
                  ),
                )
              : _buildReviewRow(),
        _buildActionRow(
          icon: Icons.support_agent_outlined,
          title: 'Связаться с поддержкой',
          subtitle: 'ahjkuio@gmail.com',
          onTap: () => GoRouter.of(context).push('/support'),
        ),
      ]),
      _buildSectionCard('Аккаунт', [
        _buildActionRow(
          icon: Icons.logout_rounded,
          title: 'Выйти',
          subtitle: 'Сменить аккаунт',
          onTap: () async {
            // Ship Q3 (2026-05-26): confirmation gate ПЕРЕД destructive
            // signOut. UX audit 2026-05-25 Critical #1.
            final confirmed = await showSignOutConfirmationDialog(
              context,
              _authService,
            );
            if (!confirmed || !mounted) return;
            await _authService.signOut();
            if (GetIt.I.isRegistered<TreeProvider>()) {
              await GetIt.I<TreeProvider>().clearSelection();
            }
            if (mounted) {
              context.go('/login');
            }
          },
        ),
      ]),
      GlassPanel(
        color:
            Theme.of(context).colorScheme.errorContainer.withValues(alpha: 0.6),
        borderColor:
            Theme.of(context).colorScheme.error.withValues(alpha: 0.35),
        child: _buildActionRow(
          icon: Icons.delete_forever,
          title: 'Удалить аккаунт',
          subtitle: 'Это действие нельзя отменить',
          onTap: _showDeleteAccountConfirmation,
          destructive: true,
        ),
      ),
    ];
  }

  Widget _buildCallSettingsSection() {
    if (_callSettingsLoading) {
      return _buildSectionCard('Звонки', const [
        Padding(
          padding: EdgeInsets.all(16),
          child: Center(child: CircularProgressIndicator()),
        ),
      ]);
    }

    final controlsEnabled = !_callSettingsSaving;
    return _buildSectionCard('Звонки', [
      _buildActionRow(
        icon: Icons.mic_rounded,
        title: 'Микрофон по умолчанию',
        subtitle: _callSettings.defaultMicrophoneDeviceId == null
            ? 'Системный выбор'
            : _callSettings.defaultMicrophoneDeviceId!,
        enabled: controlsEnabled,
        onTap: controlsEnabled ? _chooseDefaultMicrophone : null,
      ),
      _buildActionRow(
        icon: Icons.videocam_rounded,
        title: 'Камера по умолчанию',
        subtitle: _callSettings.defaultCameraDeviceId == null
            ? 'Системный выбор'
            : _callSettings.defaultCameraDeviceId!,
        enabled: controlsEnabled,
        onTap: controlsEnabled ? _chooseDefaultCamera : null,
      ),
      _buildActionRow(
        icon: Icons.spatial_audio_off_rounded,
        title: 'Аудиовыход по умолчанию',
        subtitle: _callSettings.defaultAudioOutputId == null
            ? 'Системный выбор'
            : _callSettings.defaultAudioOutputId!,
        enabled: controlsEnabled,
        onTap: controlsEnabled ? _chooseDefaultAudioOutput : null,
      ),
      _buildActionRow(
        icon: Icons.notifications_active_rounded,
        title: 'Мелодия входящего звонка',
        subtitle: _callSettings.ringtonePreset.label,
        enabled: controlsEnabled,
        onTap: controlsEnabled ? _chooseRingtone : null,
      ),
      _buildSwitchRow(
        icon: Icons.vibration_rounded,
        title: 'Вибрация при входящем',
        subtitle: _callSettings.vibrationOnIncoming ? 'Включена' : 'Выключена',
        value: _callSettings.vibrationOnIncoming,
        onChanged: controlsEnabled ? _toggleCallVibration : (_) {},
      ),
    ]);
  }

  Widget _buildAndroidDownloadRow() {
    if (_latestAndroidApkLoading) {
      return const ListTile(
        // Плотность −1 без dense: ~52dp и 16sp — планка для аудитории 50+.
        visualDensity: VisualDensity(vertical: -1),
        contentPadding: EdgeInsets.symmetric(horizontal: 4),
        leading: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text('Ищем последнюю сборку'),
        subtitle: Text('Проверяем сервер обновлений'),
      );
    }
    final latest = _latestAndroidApk;
    if (latest == null) {
      return _buildActionRow(
        icon: Icons.android_rounded,
        title: 'Скачать Android',
        subtitle: 'Сборка пока недоступна',
        enabled: false,
        onTap: null,
      );
    }
    return _buildActionRow(
      icon: Icons.android_rounded,
      title: 'Скачать Android',
      subtitle: latest.label,
      onTap: _openLatestAndroidApk,
    );
  }

  Widget _buildSettingsStateCard({
    required IconData icon,
    required String title,
    required String message,
    bool showProgress = false,
  }) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            borderRadius: BorderRadius.circular(30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: showProgress
                      ? const Padding(
                          padding: EdgeInsets.all(14),
                          child: CircularProgressIndicator(strokeWidth: 2.4),
                        )
                      : Icon(
                          icon,
                          size: 28,
                          color: theme.colorScheme.primary,
                        ),
                ),
                const SizedBox(height: 16),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.38,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Секция настроек — ОДНА рамка (эта GlassPanel), а не рамка на секцию
  /// плюс своя рамка на каждую строку внутри: раньше `_buildActionRow` /
  /// `_buildSwitchRow` красили каждую строку отдельным скруглённым фоном
  /// и разделяли их 10dp зазором — «Звонки» из 5 строк раздувались на
  /// ~350dp рамок-в-рамках. Строки теперь плоские, разделены тонкой
  /// hairline-чертой (как список, а не стопка карточек).
  Widget _buildSectionCard(String title, List<Widget> children) {
    final divider = Divider(
      height: 1,
      thickness: 0.7,
      indent: 52,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
    );
    final spacedChildren = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      spacedChildren.add(children[i]);
      if (i != children.length - 1) {
        spacedChildren.add(divider);
      }
    }

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
          ),
          ...spacedChildren,
        ],
      ),
    );
  }

  Widget _buildActionRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    bool enabled = true,
    bool destructive = false,
  }) {
    final theme = Theme.of(context);
    return ListTile(
      // Плотность −1 без dense: ~52dp и 16sp — планка для аудитории 50+.
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      enabled: enabled,
      onTap: onTap,
      leading: Icon(
        icon,
        color:
            destructive ? theme.colorScheme.error : theme.colorScheme.primary,
      ),
      title: Text(
        title,
        style: destructive ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      subtitle: Text(subtitle),
      trailing: destructive ? null : const Icon(Icons.chevron_right_rounded),
    );
  }

  /// Трёхвариантный selector темы: «как в системе / светлая / тёмная».
  /// Раньше был Switch «Тёмная тема» который не учитывал system mode
  /// и принудительно нормализовал любое значение в light/dark — юзер
  /// был заперт в чьём-то частном случае.
  Widget _buildThemePicker(ThemeProvider themeProvider) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    final mode = themeProvider.themeMode;

    final options = <_ThemePickerOption>[
      _ThemePickerOption(
        mode: ThemeMode.system,
        label: 'Как в системе',
        icon: Icons.brightness_auto_rounded,
      ),
      _ThemePickerOption(
        mode: ThemeMode.light,
        label: 'Светлая',
        icon: Icons.light_mode_rounded,
      ),
      _ThemePickerOption(
        mode: ThemeMode.dark,
        label: 'Тёмная',
        icon: Icons.dark_mode_rounded,
      ),
    ];

    String subtitle;
    switch (mode) {
      case ThemeMode.system:
        subtitle = 'Тема приложения совпадает с настройками телефона';
        break;
      case ThemeMode.light:
        subtitle = 'Всегда светлая, независимо от системы';
        break;
      case ThemeMode.dark:
        subtitle = 'Всегда тёмная, независимо от системы';
        break;
    }

    // Плотность: секция «Внешний вид» уже даёт рамку (GlassPanel) и
    // заголовок — свой скруглённый фон здесь был рамкой в рамке ради
    // единственной строки. tokens.space* больше не даёт лишний инсет:
    // горизонтальный отступ уже есть у секции.
    return Padding(
      padding: EdgeInsets.fromLTRB(4, 0, 4, tokens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.palette_outlined, color: scheme.primary, size: 20),
              const SizedBox(width: 10),
              Text(
                'Тема',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < options.length; i++) ...[
                Expanded(
                  child: _ThemePickerChip(
                    option: options[i],
                    selected: options[i].mode == mode,
                    onTap: () =>
                        unawaited(themeProvider.setThemeMode(options[i].mode)),
                  ),
                ),
                if (i != options.length - 1) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Notifications row, permission-aware. Reads the OS/browser
  /// permission status (read-only — requesting stays with the toggle,
  /// per scope) so a user who denied notifications at the OS level sees
  /// «разрешите в настройках телефона» instead of a misleading
  /// «Выключены» (Screen 7.5).
  Widget _buildNotificationsRow() {
    final service = _customNotificationService;
    final permission = service?.browserPermissionStatus;
    final osDenied = permission == BrowserNotificationPermissionStatus.denied;
    // N1: «включено» = реальное состояние, а не дефолтный prefs-флаг. На
    // web требует granted; тумблер не показывает ON, пока не granted.
    final effectivelyOn =
        service?.notificationsEffectivelyOn ?? _notificationsEnabled;
    final needsPermission = service?.needsBrowserPermission ?? false;
    final iosAddToHome = service?.iosNeedsStandaloneForPush ?? false;

    final String subtitle;
    if (osDenied) {
      subtitle = 'Разрешите уведомления в настройках браузера';
    } else if (iosAddToHome) {
      // N3: на iOS без установленного PWA запрос бессмысленен.
      subtitle =
          'Добавьте «Родню» на экран «Домой», чтобы получать уведомления';
    } else if (needsPermission) {
      // N1: default — НЕ «Включены», а явный CTA (тап тумблера = жест).
      subtitle = 'Нажмите, чтобы включить уведомления';
    } else {
      subtitle = effectivelyOn ? 'Включены' : 'Выключены';
    }

    return _buildSwitchRow(
      icon: Icons.notifications_outlined,
      title: 'Уведомления',
      subtitle: subtitle,
      value: effectivelyOn,
      onChanged: _toggleNotifications,
    );
  }

  Widget _buildSwitchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    final theme = Theme.of(context);
    return SwitchListTile(
      // Плотность −1 без dense: ~52dp и 16sp — планка для аудитории 50+.
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      secondary: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _buildPremiumRow() {
    return _buildActionRow(
      icon: _isPremium ? Icons.star : Icons.star_border,
      title: _isPremium ? 'Премиум активен' : 'Получить премиум',
      subtitle: _isPremium ? 'Спасибо за поддержку' : 'Разблокировать функции',
      onTap: _isPremium ? null : _purchasePremium,
      enabled: !_isPremium,
    );
  }

  Widget _buildOneTimePurchaseRow() {
    return ListTile(
      // Плотность −1 без dense: ~52dp и 16sp — планка для аудитории 50+.
      visualDensity: const VisualDensity(vertical: -1),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: const Icon(Icons.shopping_cart_outlined),
      title: const Text('Тестовая покупка'),
      subtitle: Text(ONE_TIME_PRODUCT_ID),
      trailing: _oneTimePurchaseLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : FilledButton.tonal(
              onPressed: _purchaseOneTimeProduct,
              child: const Text('Купить'),
            ),
    );
  }

  Widget _buildReviewRow() {
    return _buildActionRow(
      icon:
          _hasRatedApp ? Icons.thumb_up_alt_outlined : Icons.star_rate_outlined,
      title: _hasRatedApp ? 'Спасибо за отзыв' : 'Оценить приложение',
      subtitle: _hasRatedApp ? 'Отзыв уже оставлен' : 'Открыть RuStore',
      enabled: !_hasRatedApp,
      onTap: _hasRatedApp
          ? null
          : () async {
              final currentContext = context;
              final reviewStatus = await _rustoreService.requestReviewStatus();

              if (!currentContext.mounted) {
                return;
              }

              if (reviewStatus == RustoreReviewRequestStatus.shown ||
                  reviewStatus == RustoreReviewRequestStatus.alreadyExists) {
                ScaffoldMessenger.of(currentContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      reviewStatus == RustoreReviewRequestStatus.alreadyExists
                          ? 'Отзыв уже существует. Спасибо!'
                          : 'Запрос на оценку отправлен.',
                    ),
                  ),
                );
                setState(() {
                  _hasRatedApp = true;
                });
                return;
              }

              ScaffoldMessenger.of(currentContext).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Не удалось открыть окно оценки RuStore.',
                  ),
                ),
              );
            },
    );
  }
}

class _CallSettingsChoice {
  const _CallSettingsChoice({
    required this.id,
    required this.label,
    required this.subtitle,
    required this.icon,
  });

  final String? id;
  final String label;
  final String subtitle;
  final IconData icon;
}

class _ThemePickerOption {
  const _ThemePickerOption({
    required this.mode,
    required this.label,
    required this.icon,
  });

  final ThemeMode mode;
  final String label;
  final IconData icon;
}

class _ThemePickerChip extends StatelessWidget {
  const _ThemePickerChip({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _ThemePickerOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final activeColor = scheme.primary;
    return Material(
      color: selected
          ? activeColor.withValues(alpha: 0.16)
          : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? activeColor : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                option.icon,
                size: 22,
                color: selected ? activeColor : scheme.onSurfaceVariant,
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  option.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    // Selected: primary-on-tint (matches the icon) — was
                    // onPrimary (near-white) on a light tint → unreadable.
                    color: selected ? activeColor : scheme.onSurface,
                    letterSpacing: -0.1,
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
