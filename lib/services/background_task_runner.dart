import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import 'package:get_it/get_it.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:workmanager/workmanager.dart';

import '../firebase_options.dart';
import '../backend/backend_provider_config.dart';
import '../backend/backend_provider_registry.dart';
import '../backend/backend_runtime_config.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../backend/legacy_backend_runtime_policy.dart';
import '../models/chat_message.dart';
import '../models/family_person.dart' as lineage_models;
import '../models/family_relation.dart';
import '../models/family_tree.dart';
import '../models/user_profile.dart';
import 'local_storage_service.dart';
import 'custom_api_notification_service.dart';
import 'notification_service.dart';
import 'sync_service.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    late Box<lineage_models.FamilyPerson> personsBox;

    try {
      final providerConfig = BackendProviderConfig.current;
      final runtimeConfig = BackendRuntimeConfig.current;
      final needsFirebaseCore = LegacyBackendRuntimePolicy.requiresFirebaseCore(
        providerConfig: providerConfig,
        runtimeConfig: runtimeConfig,
      );
      WidgetsFlutterBinding.ensureInitialized();
      await Hive.initFlutter();

      if (!Hive.isAdapterRegistered(UserProfileAdapter().typeId)) {
        Hive.registerAdapter(UserProfileAdapter());
      }
      if (!Hive.isAdapterRegistered(FamilyTreeAdapter().typeId)) {
        Hive.registerAdapter(FamilyTreeAdapter());
      }
      if (!Hive.isAdapterRegistered(
        lineage_models.FamilyPersonAdapter().typeId,
      )) {
        Hive.registerAdapter(lineage_models.FamilyPersonAdapter());
      }
      if (!Hive.isAdapterRegistered(FamilyRelationAdapter().typeId)) {
        Hive.registerAdapter(FamilyRelationAdapter());
      }
      if (!Hive.isAdapterRegistered(ChatMessageAdapter().typeId)) {
        Hive.registerAdapter(ChatMessageAdapter());
      }
      if (!Hive.isAdapterRegistered(lineage_models.GenderAdapter().typeId)) {
        Hive.registerAdapter(lineage_models.GenderAdapter());
      }
      if (!Hive.isAdapterRegistered(RelationTypeAdapter().typeId)) {
        Hive.registerAdapter(RelationTypeAdapter());
      }

      personsBox = await Hive.openBox<lineage_models.FamilyPerson>(
        'personsBox',
      );
      if (needsFirebaseCore) {
        await Firebase.initializeApp(
          options: DefaultFirebaseOptions.currentPlatform,
        );
      }

      final localStorageService = await LocalStorageService.createInstance();
      if (!GetIt.I.isRegistered<LocalStorageService>()) {
        GetIt.I.registerSingleton<LocalStorageService>(localStorageService);
      }

      if ((providerConfig.notificationProvider ==
                  BackendProviderKind.firebase ||
              providerConfig.notificationProvider ==
                  BackendProviderKind.hybridLegacy) &&
          !GetIt.I.isRegistered<NotificationService>()) {
        final notificationService = NotificationService();
        await notificationService.initialize();
        GetIt.I.registerSingleton<NotificationService>(notificationService);
      }
      if (providerConfig.notificationProvider ==
              BackendProviderKind.customApi &&
          !GetIt.I.isRegistered<CustomApiNotificationService>()) {
        final notificationService = await CustomApiNotificationService.create();
        await notificationService.initialize();
        GetIt.I.registerSingleton<CustomApiNotificationService>(
          notificationService,
        );
        GetIt.I.registerSingleton<NotificationServiceInterface>(
          notificationService,
        );
      }

      BackendProviderRegistry.register(GetIt.I, config: providerConfig);

      if (needsFirebaseCore &&
          task == 'syncTask' &&
          !GetIt.I.isRegistered<SyncService>()) {
        final syncService = await SyncService.createInstance(
          localStorage: localStorageService,
          firestore: FirebaseFirestore.instance,
          auth: FirebaseAuth.instance,
        );
        GetIt.I.registerSingleton<SyncService>(syncService);
      }
    } catch (e, stackTrace) {
      debugPrint("Error initializing background services: $e\n$stackTrace");
      return Future.value(false);
    }

    try {
      switch (task) {
        case 'syncTask':
          if (GetIt.I.isRegistered<SyncService>()) {
            await GetIt.I<SyncService>().syncData();
          } else {
            debugPrint(
              'Background sync skipped: legacy sync provider is disabled.',
            );
          }
          break;
        case 'birthdayCheckTask':
          if (!personsBox.isOpen) {
            debugPrint('Error: Persons box is not open!');
            return Future.value(false);
          }
          final notificationService = GetIt.I<NotificationServiceInterface>();
          final relatives = personsBox.values.toList();
          final today = DateTime.now();

          for (final person in relatives) {
            if (person.birthDate != null &&
                person.birthDate!.day == today.day &&
                person.birthDate!.month == today.month) {
              debugPrint('Birthday found for: ${person.name}');
              await notificationService.showBirthdayNotification(person);
            }
          }
          break;
        case Workmanager.iOSBackgroundTask:
          break;
      }
      return Future.value(true);
    } catch (e, stackTrace) {
      debugPrint("Error executing background task $task: $e\n$stackTrace");
      return Future.value(false);
    }
  });
}
