import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:get_it/get_it.dart';
import '../services/local_storage_service.dart';
import '../models/family_tree.dart';
import '../models/user_profile.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../providers/tree_provider.dart';

class SyncService {
  final LocalStorageService _localStorage;
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  StreamSubscription? _connectivitySubscription;
  bool _isOnline = true; // Начальное предположение
  // Добавляем StreamController
  final _connectionStatusController = StreamController<bool>.broadcast();

  // Приватный конструктор
  SyncService._({
    required LocalStorageService localStorage,
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  })  : _localStorage = localStorage,
        _firestore = firestore,
        _auth = auth;

  // Асинхронный статический метод для создания и инициализации экземпляра
  static Future<SyncService> createInstance({
    required LocalStorageService localStorage,
    required FirebaseFirestore firestore,
    required FirebaseAuth auth,
  }) async {
    // Создаем экземпляр через приватный конструктор
    final instance = SyncService._(
      localStorage: localStorage,
      firestore: firestore,
      auth: auth,
    );
    // Ожидаем завершения асинхронной инициализации
    await instance._initializeConnectivityListener();
    // Возвращаем полностью готовый экземпляр
    return instance;
  }

  // Переименовываем в приватный и убеждаемся, что он async
  Future<void> _initializeConnectivityListener() async {
    try {
      var initialResult = await Connectivity().checkConnectivity();
      _updateConnectionStatus(initialResult);
    } catch (e) {
      debugPrint('Error getting initial connectivity: $e. Assuming online.');
      _updateConnectionStatus([
        ConnectivityResult.wifi,
      ]); // Предполагаем онлайн в случае ошибки
    }

    // Слушаем изменения
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(
          _updateConnectionStatus,
        );
  }

  // Новый метод для обновления статуса и оповещения слушателей
  void _updateConnectionStatus(List<ConnectivityResult> result) {
    // Обновляем тип параметра
    _isOnline = !result.contains(
      ConnectivityResult.none,
    ); // Проверяем, если хотя бы одно соединение не 'none'
    // Добавляем новое состояние в поток
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(_isOnline);
    }
    debugPrint(
        "Connection Status Updated: ${_isOnline ? 'Online' : 'Offline'}");
    if (_isOnline) {
      // Синхронизируем данные при восстановлении соединения
      syncData();
    }
  }

  bool get isOnline => _isOnline;
  // Добавляем getter для потока
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;

  // Синхронизация всех данных
  Future<void> syncData() async {
    if (!_isOnline) {
      debugPrint('Sync skipped: Offline');
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      debugPrint('Sync skipped: User not logged in');
      return;
    }

    debugPrint('Starting data synchronization for user: ${user.uid}');
    try {
      // Синхронизируем профиль пользователя
      await syncUserProfile(user.uid);

      // Синхронизируем деревья, к которым имеет доступ пользователь
      await syncUserTrees(user.uid);

      // Синхронизируем родственников из этих деревьев
      await syncFamilyPersons();

      // Синхронизируем отношения
      await syncFamilyRelations();

      // <<< NEW: Выбираем дерево по умолчанию ПОСЛЕ успешной синхронизации >>>
      await GetIt.I<TreeProvider>().selectDefaultTreeIfNeeded();

      debugPrint('Synchronization completed successfully');
    } catch (e) {
      debugPrint('Error during data synchronization: $e');
    }
  }

  // Синхронизация профиля пользователя
  Future<void> syncUserProfile(String userId) async {
    debugPrint('Syncing user profile for: $userId');
    try {
      final userDoc = await _firestore.collection('users').doc(userId).get();

      if (userDoc.exists) {
        final userProfile = UserProfile.fromMap(userDoc.data()!, userId);
        await _localStorage.saveUser(userProfile);
        debugPrint('User profile synced and saved locally.');
      } else {
        debugPrint('User profile document does not exist in Firestore.');
      }
    } catch (e) {
      debugPrint('Error syncing user profile: $e');
    }
  }

  // Синхронизация деревьев пользователя
  Future<void> syncUserTrees(String userId) async {
    debugPrint('Syncing user trees for: $userId');
    try {
      // --- NEW: Загружаем деревья из UserProfile ---
      final userProfileDoc =
          await _firestore.collection('users').doc(userId).get();
      if (!userProfileDoc.exists) {
        debugPrint('UserProfile for $userId not found during tree sync.');
        return;
      }
      final userProfile = UserProfile.fromMap(userProfileDoc.data()!, userId);

      final List<String> createdTreeIds = userProfile.creatorOfTreeIds ?? [];
      final List<String> accessibleTreeIds =
          userProfile.accessibleTreeIds ?? [];
      final Set<String> allTreeIdsSet = {
        ...createdTreeIds,
        ...accessibleTreeIds,
      };
      final List<String> uniqueTreeIds = allTreeIdsSet.toList();

      debugPrint(
          '[SyncService] Found tree IDs for user $userId: $uniqueTreeIds');

      if (uniqueTreeIds.isEmpty) {
        debugPrint('[SyncService] No trees to sync for user $userId.');
        // Опционально: Очистить локальные деревья, если список пуст?
        // await _localStorage.clearTrees();
        return;
      }

      // Загружаем данные деревьев из Firestore
      List<FamilyTree> treesToCache = [];
      for (var i = 0; i < uniqueTreeIds.length; i += 10) {
        final chunkIds = uniqueTreeIds.sublist(
          i,
          i + 10 > uniqueTreeIds.length ? uniqueTreeIds.length : i + 10,
        );
        debugPrint('[SyncService] Fetching tree data for chunk: $chunkIds');
        final treesSnapshot = await _firestore
            .collection('family_trees')
            .where(FieldPath.documentId, whereIn: chunkIds)
            .get();

        for (var treeDoc in treesSnapshot.docs) {
          if (treeDoc.exists) {
            final tree = FamilyTree.fromFirestore(treeDoc);
            treesToCache.add(tree);
          }
        }
      }

      // Сохраняем все загруженные деревья в локальный кэш
      if (treesToCache.isNotEmpty) {
        await _localStorage.saveTrees(
          treesToCache,
        ); // Предполагаем наличие метода saveTrees
        debugPrint(
          '[SyncService] Synced and saved ${treesToCache.length} trees locally for user $userId.',
        );
      } else {
        debugPrint(
          '[SyncService] No valid tree documents found in Firestore for the obtained IDs.',
        );
      }
      // --- END NEW ---
    } catch (e) {
      debugPrint('Error syncing user trees: $e');
    }
  }

  // Добавим метод для определения новизны данных
  bool _isNewerData(DateTime? localTime, DateTime? serverTime) {
    if (serverTime == null) {
      return true; // Если на сервере нет времени, локальные новее (для отправки)
    }
    if (localTime == null) {
      return false; // Если локального времени нет, серверные новее
    }
    return localTime.isAfter(serverTime);
  }

  // Метод для синхронизации с разрешением конфликтов
  Future<void> syncWithConflictResolution<T>(
    String id,
    Future<T?> Function(String) getLocalData,
    Future<T?> Function(String) getServerData,
    Future<void> Function(T) saveLocalData,
    Future<void> Function(T) saveServerData,
    DateTime? Function(T) getTimestamp,
    T Function(T, T) mergeData,
  ) async {
    try {
      // Получаем данные локально и с сервера
      final localData = await getLocalData(id);
      final serverData = await getServerData(id);

      // Если локальных данных нет, просто сохраняем серверные
      if (localData == null) {
        if (serverData != null) {
          await saveLocalData(serverData);
        }
        return;
      }

      // Если серверных данных нет, отправляем локальные на сервер
      if (serverData == null) {
        await saveServerData(localData);
        return;
      }

      // Если есть оба источника данных, сравниваем их время обновления
      final localTime = getTimestamp(localData);
      final serverTime = getTimestamp(serverData);

      if (_isNewerData(localTime, serverTime)) {
        // Локальные данные новее - обновляем серверные
        await saveServerData(localData);
      } else if (_isNewerData(serverTime, localTime)) {
        // Серверные данные новее - обновляем локальные
        await saveLocalData(serverData);
      } else {
        // Данные обновлялись параллельно - выполняем слияние
        final mergedData = mergeData(localData, serverData);
        await saveLocalData(mergedData);
        await saveServerData(mergedData);
      }
    } catch (e) {
      debugPrint('Ошибка при синхронизации с разрешением конфликтов: $e');
    }
  }

  // Методы слияния данных для разных типов
  FamilyTree mergeFamilyTrees(FamilyTree local, FamilyTree server) {
    // Пример реализации:
    // В реальном приложении логика слияния будет более сложной
    return FamilyTree(
      id: local.id,
      name: local.name, // Сохраняем локальное название
      description: local.description, // Сохраняем локальное описание
      creatorId: local.creatorId,
      createdAt: local.createdAt,
      updatedAt: DateTime.now(), // Обновляем время изменения
      members: [
        ...{...local.members, ...server.members},
      ], // Объединяем списки, удаляя дубликаты
      isPrivate: local.isPrivate, // Сохраняем локальные настройки приватности
      memberIds: [
        ...{...local.memberIds, ...server.memberIds},
      ], // Объединяем списки, удаляя дубликаты
    );
  }

  // Синхронизация персон (родственников)
  Future<void> syncFamilyPersons() async {
    final user = _auth.currentUser;
    if (user == null) return;
    debugPrint('Syncing family persons for user: ${user.uid}');
    try {
      // 1. Получаем ID деревьев пользователя из локального кэша
      final List<FamilyTree> userTrees = await _localStorage.getAllTrees();
      final List<String> treeIds = userTrees.map((tree) => tree.id).toList();

      if (treeIds.isEmpty) {
        debugPrint('No trees found locally for user. Skipping person sync.');
        return;
      }

      debugPrint('Syncing persons for trees: $treeIds');

      // 2. Загружаем персон для каждого дерева из Firestore
      List<FamilyPerson> allPersons = [];
      for (String treeId in treeIds) {
        debugPrint('Fetching persons for tree: $treeId');
        final personsQuery = await _firestore
            .collection('family_persons')
            .where('treeId', isEqualTo: treeId)
            .get();

        final persons = personsQuery.docs
            .map((doc) => FamilyPerson.fromFirestore(doc))
            .toList();
        allPersons.addAll(persons);
        debugPrint('Fetched ${persons.length} persons for tree $treeId');
      }

      // 3. Сохраняем всех загруженных персон в локальное хранилище
      if (allPersons.isNotEmpty) {
        await _localStorage.savePersons(allPersons);
        debugPrint('Synced and saved ${allPersons.length} persons locally.');
      } else {
        debugPrint('No persons found in Firestore for the user\'s trees.');
      }
    } catch (e) {
      debugPrint('Error syncing family persons: $e');
    }
  }

  // Синхронизация отношений
  Future<void> syncFamilyRelations() async {
    final user = _auth.currentUser;
    if (user == null) return;
    debugPrint('Syncing family relations for user: ${user.uid}');
    try {
      // 1. Получаем ID деревьев пользователя из локального кэша
      final List<FamilyTree> userTrees = await _localStorage.getAllTrees();
      final List<String> treeIds = userTrees.map((tree) => tree.id).toList();

      if (treeIds.isEmpty) {
        debugPrint('No trees found locally for user. Skipping relation sync.');
        return;
      }

      debugPrint('Syncing relations for trees: $treeIds');

      // 2. Загружаем отношения для каждого дерева из Firestore
      List<FamilyRelation> allRelations = [];
      for (String treeId in treeIds) {
        debugPrint('Fetching relations for tree: $treeId');
        final relationsQuery = await _firestore
            .collection(
              'family_relations',
            ) // Убедитесь, что имя коллекции верное
            .where('treeId', isEqualTo: treeId)
            .get();

        final relations = relationsQuery.docs
            .map((doc) => FamilyRelation.fromFirestore(doc))
            .toList();
        allRelations.addAll(relations);
        debugPrint('Fetched ${relations.length} relations for tree $treeId');
      }

      // 3. Сохраняем все загруженные отношения в локальное хранилище
      if (allRelations.isNotEmpty) {
        await _localStorage.saveRelations(allRelations);
        debugPrint(
            'Synced and saved ${allRelations.length} relations locally.');
      } else {
        debugPrint('No relations found in Firestore for the user\'s trees.');
      }
    } catch (e) {
      debugPrint('Error syncing family relations: $e');
    }
  }

  // Другие методы синхронизации...

  void dispose() {
    _connectivitySubscription?.cancel();
    // Закрываем StreamController
    _connectionStatusController.close();
    debugPrint('SyncService disposed.');
  }
}
