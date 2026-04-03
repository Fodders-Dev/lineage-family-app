import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:uuid/uuid.dart';
import 'dart:collection';
import 'package:collection/collection.dart'; // <<< Добавляем импорт
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/relation_request.dart';
import '../models/family_tree.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../services/local_storage_service.dart';
import 'package:get_it/get_it.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
// Добавляем импорт SyncService
import 'sync_service.dart';
import '../models/user_profile.dart'; // <<< Добавляем импорт UserProfile
import '../services/auth_service.dart'; // <<< Добавляем импорт AuthService
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/models/selectable_tree.dart';
import '../backend/models/tree_invitation.dart';

class FamilyService implements FamilyTreeServiceInterface {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;
  // Зависимости, получаемые через конструктор
  final LocalStorageService _localStorageService;
  final SyncService _syncService;

  // Конструктор, принимающий зависимости
  FamilyService({
    required LocalStorageService localStorageService,
    required SyncService syncService,
  })  : _localStorageService = localStorageService,
        _syncService = syncService;

  @override
  Future<String> createTree({
    required String name,
    required String description,
    required bool isPrivate,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    final treeId = Uuid().v4();
    final now = DateTime.now();
    final tree = FamilyTree(
      id: treeId,
      name: name,
      description: description,
      creatorId: user.uid,
      createdAt: now,
      updatedAt: now,
      isPrivate: isPrivate,
      members: [user.uid],
      memberIds: [user.uid],
    );

    await _firestore.collection('family_trees').doc(treeId).set(tree.toMap());
    await _firestore.collection('tree_members').doc().set({
      'treeId': treeId,
      'userId': user.uid,
      'role': 'owner',
      'addedAt': now,
      'acceptedAt': now,
    });
    await _firestore.collection('users').doc(user.uid).update({
      'creatorOfTreeIds': FieldValue.arrayUnion([treeId]),
    });

    return treeId;
  }

  // Создание нового offline-родственника
  Future<FamilyPerson> createOfflineRelative({
    required String treeId,
    required String name,
    String? maidenName,
    String? photoUrl,
    required Gender gender,
    DateTime? birthDate,
    String? birthPlace,
    DateTime? deathDate,
    String? deathPlace,
    String? bio,
    required bool isAlive,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    // Проверяем, что пользователь имеет право добавлять людей в это дерево
    final treeDoc =
        await _firestore.collection('family_trees').doc(treeId).get();
    if (!treeDoc.exists) {
      throw Exception('Дерево не найдено');
    }

    final memberDoc = await _firestore
        .collection('tree_members')
        .where('treeId', isEqualTo: treeId)
        .where('userId', isEqualTo: user.uid)
        .where('role', whereIn: ['owner', 'editor'])
        .limit(1)
        .get();

    if (memberDoc.docs.isEmpty) {
      throw Exception(
        'У вас нет прав для добавления родственников в это дерево',
      );
    }

    // Создаем новую запись о человеке
    final personId = Uuid().v4();
    final now = DateTime.now();

    final person = FamilyPerson(
      id: personId,
      treeId: treeId,
      userId: null, // offline-родственник
      name: name,
      maidenName: maidenName,
      photoUrl: photoUrl,
      gender: gender,
      birthDate: birthDate,
      birthPlace: birthPlace,
      deathDate: deathDate,
      deathPlace: deathPlace,
      bio: bio,
      isAlive: isAlive,
      creatorId: user.uid,
      createdAt: now,
      updatedAt: now,
    );

    // Сохраняем в Firestore
    await _firestore
        .collection('family_persons')
        .doc(personId)
        .set(person.toMap());

    return person;
  }

  // Создание новой родственной связи (с поддержкой оффлайн)
  Future<FamilyRelation> createRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
    required RelationType relation1to2,
    bool isConfirmed = true, // Оставим isConfirmed, т.к. это локальное создание
  }) async {
    final user = _auth.currentUser;
    // Убрал проверку прав, т.к. она требует Firestore.
    // Права проверяются в вызывающем коде (UI) или при синхронизации.
    // if (user == null) { throw Exception('Необходимо авторизоваться'); }
    // final memberDoc = await _firestore...; // Убрана проверка прав

    final relationId = Uuid().v4();
    final now = DateTime.now();

    // 1. Создаем объект FamilyRelation локально
    final relation = FamilyRelation(
      id: relationId,
      treeId: treeId,
      person1Id: person1Id,
      person2Id: person2Id,
      relation1to2: relation1to2,
      relation2to1: FamilyRelation.getMirrorRelation(relation1to2),
      createdAt: now,
      createdBy: user
          ?.uid, // Может быть null, если user == null (хотя выше должна быть проверка)
      isConfirmed: isConfirmed,
      updatedAt: now, // Добавим updatedAt
    );

    try {
      // 2. Сохраняем в ЛОКАЛЬНЫЙ кэш ВСЕГДА
      await _localStorageService.saveRelation(relation);
      print('Связь ${relation.id} сохранена локально.');

      // 3. Проверяем сеть и отправляем в Firestore, если онлайн
      if (_syncService.isOnline) {
        print('Сеть есть. Отправляем связь ${relation.id} в Firestore...');
        await _firestore
            .collection('family_relations')
            .doc(relationId)
            .set(relation.toMap());
        print('Связь ${relation.id} успешно добавлена в Firestore.');
      } else {
        print('Сети нет. Связь ${relation.id} сохранена только локально.');
        // TODO: Механизм отложенной синхронизации
      }
    } catch (e) {
      print('Ошибка при создании/сохранении связи ${relation.id}: $e');
      rethrow;
    }

    return relation; // Возвращаем локально созданный объект
  }

  // Получение запросов на родство для текущего пользователя
  @override
  Future<List<RelationRequest>> getRelationRequests({
    required String treeId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    // Получаем запросы, адресованные текущему пользователю
    final requestsSnapshot = await _firestore
        .collection('relation_requests')
        .where('treeId', isEqualTo: treeId)
        .where('recipientId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'pending')
        .orderBy('createdAt', descending: true)
        .get();

    return requestsSnapshot.docs
        .map((doc) => RelationRequest.fromFirestore(doc))
        .toList();
  }

  @override
  Future<List<RelationRequest>> getPendingRelationRequests({
    String? treeId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    Query<Map<String, dynamic>> query = _firestore
        .collection('relation_requests')
        .where('recipientId', isEqualTo: user.uid)
        .where('status', isEqualTo: 'pending');

    if (treeId != null && treeId.isNotEmpty) {
      query = query.where('treeId', isEqualTo: treeId);
    }

    final snapshot = await query.orderBy('createdAt', descending: true).get();
    return snapshot.docs
        .map((doc) => RelationRequest.fromFirestore(doc))
        .toList();
  }

  // Ответ на запрос родства
  @override
  Future<void> respondToRelationRequest({
    required String requestId,
    required RequestStatus response,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    // Проверяем запрос
    final requestDoc =
        await _firestore.collection('relation_requests').doc(requestId).get();

    if (!requestDoc.exists) {
      throw Exception('Запрос не найден');
    }

    final request = RelationRequest.fromFirestore(requestDoc);
    final requestData = requestDoc.data() as Map<String, dynamic>;

    // Проверяем, что запрос адресован текущему пользователю
    if (request.recipientId != user.uid) {
      throw Exception('У вас нет прав для ответа на этот запрос');
    }

    // Проверяем, что запрос в статусе ожидания
    if (request.status != RequestStatus.pending) {
      throw Exception('Этот запрос уже обработан');
    }

    final isLegacyOfflineReplacement =
        requestData.containsKey('offlineRelativeId') &&
            requestData['offlineRelativeId'] != null;

    if (response == RequestStatus.accepted && isLegacyOfflineReplacement) {
      await _acceptLegacyOfflineReplacementRequest(
        requestDoc: requestDoc,
        requestData: requestData,
        currentUserId: user.uid,
      );
      return;
    }

    // Обновляем статус запроса
    await _firestore.collection('relation_requests').doc(requestId).update({
      'status': RelationRequest.requestStatusToString(response),
      'respondedAt': Timestamp.fromDate(DateTime.now()),
    });

    // Если запрос принят, создаем связь ИЛИ обновляем офлайн-запись
    if (response == RequestStatus.accepted) {
      final targetPersonId = request.targetPersonId;

      if (targetPersonId != null) {
        // Есть офлайн-запись для связывания
        print(
          'Принятие запроса: Связывание офлайн-записи $targetPersonId с пользователем ${request.recipientId}',
        );
        try {
          // Обновляем userId в документе family_persons
          await _firestore
              .collection('family_persons')
              .doc(targetPersonId)
              .update({'userId': request.recipientId});

          // TODO: Опционально: Проверить и обновить существующие связи для targetPersonId
          // Можно, например, подтвердить все связи, где участвует targetPersonId
          // Query query1 = _firestore.collection('family_relations')
          //   .where('treeId', isEqualTo: request.treeId)
          //   .where('person1Id', isEqualTo: request.targetPersonId);
          // Query query2 = _firestore.collection('family_relations')
          //   .where('treeId', isEqualTo: request.treeId)
          //   .where('person2Id', isEqualTo: request.targetPersonId);
          // final results1 = await query1.get();
          // final results2 = await query2.get();
          // WriteBatch batch = _firestore.batch();
          // for (var doc in [...results1.docs, ...results2.docs]) {
          //   batch.update(doc.reference, {'isConfirmed': true});
          // }
          // await batch.commit();

          // Важно: Мы НЕ создаем новую связь через createRelation,
          // так как связь между отправителем и этой (теперь уже онлайн) записью
          // должна была быть создана ранее, когда создавалась офлайн-запись.
          // Если ее нет, это проблема логики отправки приглашения.
          // Возможно, нужно добавить проверку и создание связи здесь, если она отсутствует?
          // Пока оставим как есть, предполагая, что связь уже существует.
        } catch (e) {
          print('Ошибка при обновлении userId для $targetPersonId: $e');
          // Можно добавить логику отката или повторной попытки
        }
      } else {
        // Нет офлайн-записи для связывания, создаем новую связь между двумя пользователями
        print(
          'Принятие запроса: Создание новой связи между ${request.senderId} и ${request.recipientId}',
        );
        await createRelation(
          treeId: request.treeId,
          person1Id: request.senderId,
          person2Id: request.recipientId,
          relation1to2: request.senderToRecipient,
          isConfirmed: true, // Связь подтверждена, так как запрос принят
        );
      }
    }
  }

  // Отправка запроса на родство
  @override
  Future<void> sendRelationRequest({
    required String treeId,
    required String recipientId,
    required RelationType relationType,
    String? message,
  }) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) {
      throw Exception('Пользователь не авторизован');
    }

    final requestData = {
      'treeId': treeId,
      'senderId': currentUser.uid,
      'recipientId': recipientId,
      'senderToRecipient': FamilyRelation.relationTypeToString(relationType),
      'relationType': FamilyRelation.relationTypeToString(relationType),
      'status': 'pending',
      'message': message ?? 'Запрос на подтверждение родственной связи',
      'createdAt': Timestamp.now(),
      'updatedAt': Timestamp.now(),
    };

    await FirebaseFirestore.instance
        .collection('relation_requests')
        .add(requestData);
  }

  @override
  Future<void> sendTreeInvitation({
    required String treeId,
    String? recipientUserId,
    String? recipientEmail,
    String? relationToTree,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('Пользователь не авторизован');
    }

    var targetUserId = recipientUserId?.trim() ?? '';
    if (targetUserId.isEmpty) {
      final email = recipientEmail?.trim() ?? '';
      if (email.isEmpty) {
        throw Exception('Нужно выбрать пользователя Родни');
      }

      final userQuery = await _firestore
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();
      if (userQuery.docs.isEmpty) {
        throw Exception('Пользователь с таким email не найден');
      }
      targetUserId = userQuery.docs.first.id;
    }

    if (targetUserId == currentUser.uid) {
      throw Exception('Нельзя пригласить в дерево самого себя');
    }

    final existingMembership = await _firestore
        .collection('tree_members')
        .where('treeId', isEqualTo: treeId)
        .where('userId', isEqualTo: targetUserId)
        .limit(1)
        .get();
    if (existingMembership.docs.isNotEmpty) {
      throw Exception('Этот пользователь уже состоит в дереве');
    }

    await _firestore.collection('tree_members').add({
      'treeId': treeId,
      'userId': targetUserId,
      'role': 'pending',
      'addedBy': currentUser.uid,
      'relationToTree': relationToTree?.trim(),
      'addedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> sendOfflineRelationRequestByEmail({
    required String treeId,
    required String email,
    required String offlineRelativeId,
    required RelationType relationType,
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('Пользователь не авторизован');
    }

    final userQuery = await _firestore
        .collection('users')
        .where('email', isEqualTo: email.trim())
        .limit(1)
        .get();

    if (userQuery.docs.isEmpty) {
      throw Exception('Пользователь с таким email не найден');
    }

    final targetUserId = userQuery.docs.first.id;
    if (targetUserId == currentUser.uid) {
      throw Exception('Нельзя отправить запрос самому себе');
    }

    final relationTypeValue = FamilyRelation.relationTypeToString(relationType);
    await _firestore.collection('relation_requests').add({
      'senderId': currentUser.uid,
      'recipientId': targetUserId,
      'treeId': treeId,
      'offlineRelativeId': offlineRelativeId,
      'targetPersonId': offlineRelativeId,
      'senderToRecipient': relationTypeValue,
      'relationType': relationTypeValue,
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Добавьте этот метод в класс FamilyService
  Future<void> createRequiredIndexes() async {
    // Этот метод просто пустышка, в реальности индексы создаются через Firebase Console
    // или через вызов REST API Firebase
    print('Индексы должны быть созданы в Firebase Console');
    return;
  }

  // Добавляем метод для создания семейной связи
  Future<void> createFamilyRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
    required RelationType relation1to2,
    required RelationType relation2to1,
    bool isConfirmed = true,
  }) async {
    try {
      // Проверяем, существует ли уже связь
      final existingRelationQuery = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person1Id', isEqualTo: person1Id)
          .where('person2Id', isEqualTo: person2Id)
          .get();

      if (existingRelationQuery.docs.isNotEmpty) {
        // Обновляем существующую связь
        await _firestore
            .collection('family_relations')
            .doc(existingRelationQuery.docs.first.id)
            .update({
          'relation1to2': relation1to2.toString(),
          'relation2to1': relation2to1.toString(),
          'updatedAt': Timestamp.now(),
        });
      } else {
        // Создаем новую связь
        final relationData = {
          'treeId': treeId,
          'person1Id': person1Id,
          'person2Id': person2Id,
          'relation1to2': relation1to2.toString(),
          'relation2to1': relation2to1.toString(),
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'isConfirmed': isConfirmed,
        };

        await _firestore.collection('family_relations').add(relationData);
      }

      // Проверяем, нужно ли создать обратную связь
      final reverseRelationQuery = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person1Id', isEqualTo: person2Id)
          .where('person2Id', isEqualTo: person1Id)
          .get();

      if (reverseRelationQuery.docs.isEmpty) {
        // Создаем обратную связь
        final reverseRelationData = {
          'treeId': treeId,
          'person1Id': person2Id,
          'person2Id': person1Id,
          'relation1to2': relation2to1.toString(),
          'relation2to1': relation1to2.toString(),
          'createdAt': Timestamp.now(),
          'updatedAt': Timestamp.now(),
          'isConfirmed': isConfirmed,
        };

        await _firestore
            .collection('family_relations')
            .add(reverseRelationData);
      }
    } catch (e) {
      print('Ошибка при создании семейной связи: $e');
      throw e;
    }
  }

  // Обновим метод getUserTrees, чтобы он правильно искал деревья пользователя
  Future<List<FamilyTree>> getUserTrees() async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Необходимо авторизоваться');
      }

      // Проверяем соединение
      final connectivityResult = await Connectivity().checkConnectivity();
      final isOnline = connectivityResult != ConnectivityResult.none;

      if (isOnline) {
        // Получаем список всех членств в деревьях, где пользователь участвует
        final membershipQuery = await _firestore
            .collection('tree_members')
            .where('userId', isEqualTo: user.uid)
            .get();

        // Собираем ID всех деревьев
        List<String> treeIds = membershipQuery.docs
            .map((doc) => doc.data()['treeId'] as String)
            .toList();

        print('Найдено членств в деревьях: ${treeIds.length}');

        if (treeIds.isEmpty) return [];

        // Получаем деревья по их ID
        final List<FamilyTree> trees = [];

        // Используем chunked запросы, так как Firestore ограничивает количество ID в "where in"
        for (int i = 0; i < treeIds.length; i += 10) {
          final end = (i + 10 < treeIds.length) ? i + 10 : treeIds.length;
          final chunk = treeIds.sublist(i, end);

          final treesQuery = await _firestore
              .collection('family_trees')
              .where(FieldPath.documentId, whereIn: chunk)
              .get();

          for (var doc in treesQuery.docs) {
            final tree = FamilyTree.fromFirestore(doc);
            trees.add(tree);

            // Сохраняем в локальное хранилище
            await _localStorageService.saveTree(tree);
          }
        }

        print('Загружено деревьев: ${trees.length}');
        return trees;
      } else {
        // Если офлайн, используем данные из локального хранилища
        return await _localStorageService.getAllTrees();
      }
    } catch (e) {
      print('Ошибка при получении деревьев пользователя: $e');

      // В случае ошибки, пытаемся получить данные из локального хранилища
      try {
        return await _localStorageService.getAllTrees();
      } catch (e) {
        print('Ошибка при получении локальных данных: $e');
        return [];
      }
    }
  }

  @override
  Stream<List<TreeInvitation>> getPendingTreeInvitations() {
    final userId = _auth.currentUser?.uid;
    if (userId == null) {
      return Stream.value(const []);
    }

    return _firestore
        .collection('tree_members')
        .where('userId', isEqualTo: userId)
        .where('role', isEqualTo: 'pending')
        .snapshots()
        .asyncMap((snapshot) async {
      if (snapshot.docs.isEmpty) {
        return const <TreeInvitation>[];
      }

      final treeIds = snapshot.docs
          .map((doc) => doc.data()['treeId'] as String?)
          .whereType<String>()
          .toList();
      final trees = <FamilyTree>[];

      for (var i = 0; i < treeIds.length; i += 10) {
        final chunk = treeIds.sublist(
          i,
          i + 10 > treeIds.length ? treeIds.length : i + 10,
        );
        final treesSnapshot = await _firestore
            .collection('family_trees')
            .where(FieldPath.documentId, whereIn: chunk)
            .get();
        trees.addAll(treesSnapshot.docs.map(FamilyTree.fromFirestore));
      }

      return snapshot.docs.map((invitationDoc) {
        final treeId = invitationDoc.data()['treeId'] as String?;
        final tree = trees.firstWhere(
          (item) => item.id == treeId,
          orElse: () => FamilyTree(
            id: treeId ?? '',
            name: 'Без названия',
            creatorId: '',
            description: '',
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            members: const [],
            isPrivate: true,
            memberIds: const [],
          ),
        );
        return TreeInvitation(
          invitationId: invitationDoc.id,
          tree: tree,
          invitedBy: invitationDoc.data()['addedBy'] as String?,
        );
      }).toList();
    });
  }

  @override
  Future<void> respondToTreeInvitation(String invitationId, bool accept) async {
    if (accept) {
      await _firestore.collection('tree_members').doc(invitationId).update({
        'role': 'viewer',
        'acceptedAt': FieldValue.serverTimestamp(),
      });
      return;
    }

    await _firestore.collection('tree_members').doc(invitationId).delete();
  }

  @override
  Future<List<SelectableTree>> getSelectableTreesForCurrentUser() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Пользователь не авторизован');
    }

    final membershipSnapshot = await _firestore
        .collection('tree_members')
        .where('userId', isEqualTo: user.uid)
        .where('role', whereIn: ['owner', 'editor', 'viewer']).get();

    final treeIds =
        membershipSnapshot.docs.map((doc) => doc['treeId'] as String).toList();
    if (treeIds.isEmpty) {
      return const [];
    }

    final trees = <SelectableTree>[];
    for (var i = 0; i < treeIds.length; i += 10) {
      final chunkIds = treeIds.sublist(
        i,
        i + 10 > treeIds.length ? treeIds.length : i + 10,
      );
      final treesSnapshot = await _firestore
          .collection('family_trees')
          .where(FieldPath.documentId, whereIn: chunkIds)
          .get();

      for (final treeDoc in treesSnapshot.docs) {
        trees.add(
          SelectableTree(
            id: treeDoc.id,
            name: (treeDoc['name'] ?? 'Без названия').toString(),
            createdAt: treeDoc['createdAt'] is Timestamp
                ? (treeDoc['createdAt'] as Timestamp).toDate()
                : null,
          ),
        );
      }
    }

    trees.sort((a, b) => a.name.compareTo(b.name));
    return trees;
  }

  @override
  Future<bool> hasDirectRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
  }) async {
    final relationsQuery = await _firestore
        .collection('family_relations')
        .where('treeId', isEqualTo: treeId)
        .where('person1Id', isEqualTo: person1Id)
        .where('person2Id', isEqualTo: person2Id)
        .limit(1)
        .get();

    return relationsQuery.docs.isNotEmpty;
  }

  @override
  Future<bool> hasPendingRelationRequest({
    required String treeId,
    required String senderId,
    required String recipientId,
  }) async {
    final existingRequestsQuery = await _firestore
        .collection('relation_requests')
        .where('treeId', isEqualTo: treeId)
        .where('senderId', isEqualTo: senderId)
        .where('recipientId', isEqualTo: recipientId)
        .limit(1)
        .get();

    return existingRequestsQuery.docs.isNotEmpty;
  }

  // Добавляем метод удаления родственника (с поддержкой оффлайн)
  Future<void> deleteRelative(String treeId, String personId) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Необходимо авторизоваться');

    // Права на удаление лучше проверять в UI перед вызовом этого метода,
    // так как проверка требует Firestore.

    try {
      // 1. Удаляем данные из локального хранилища ВСЕГДА
      await _localStorageService.deleteRelative(
        personId,
      ); // Удаляем саму персону
      await _localStorageService.deleteRelationsByPersonId(
        treeId,
        personId,
      ); // Удаляем связанные отношения
      print('Родственник $personId и его связи удалены локально.');

      // 2. Если есть сеть, удаляем из Firestore
      if (_syncService.isOnline) {
        print('Сеть есть. Удаляем $personId и его связи из Firestore...');
        WriteBatch batch = _firestore.batch();

        // Удаляем родственника из КОРНЕВОЙ коллекции family_persons
        final personRef = _firestore.collection('family_persons').doc(personId);
        batch.delete(personRef);

        // Находим и удаляем все связи из КОРНЕВОЙ family_relations
        final relationsQuery = await _firestore
            .collection('family_relations')
            .where('treeId', isEqualTo: treeId)
            .where(
              Filter.or(
                Filter('person1Id', isEqualTo: personId),
                Filter('person2Id', isEqualTo: personId),
              ),
            )
            .get();

        for (var doc in relationsQuery.docs) {
          batch.delete(doc.reference);
        }

        await batch.commit();
        print(
          'Родственник $personId и его связи успешно удалены из Firestore.',
        );
      } else {
        print('Сети нет. Удаление $personId выполнено только локально.');
        // TODO: Механизм отложенной синхронизации для удаления
      }
    } catch (e) {
      print('Ошибка при удалении родственника $personId: $e');
      // Подумать о логике восстановления, если удаление в Firestore не удалось,
      // но локально уже удалено. Пока просто пробрасываем ошибку.
      rethrow;
    }
  }

  // Добавляем метод для создания связи между родителями
  Future<void> createParentsRelationIfNeeded(
    String treeId,
    String newParentId,
  ) async {
    try {
      final userId = _auth.currentUser?.uid;
      if (userId == null) return;

      // Ищем отношения типа "родитель" между пользователем и родителями
      final userParentRelations = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person2Id', isEqualTo: userId)
          .where('relation1to2', whereIn: ['parent', 'father', 'mother']).get();

      // Если найдено больше одного родителя, создаем между ними связь "супруги"
      if (userParentRelations.docs.length > 1) {
        // Ищем других родителей (не того, который был только что добавлен)
        final otherParents = userParentRelations.docs
            .where((doc) => doc['person1Id'] != newParentId)
            .toList();

        if (otherParents.isNotEmpty) {
          // Для каждого найденного родителя проверяем существующую связь
          for (var otherParent in otherParents) {
            final otherParentId = otherParent['person1Id'];

            // Проверяем, существует ли уже связь между родителями
            final existingRelation = await _firestore
                .collection('family_relations')
                .where('treeId', isEqualTo: treeId)
                .where('person1Id', whereIn: [
              newParentId,
              otherParentId
            ]).where('person2Id', whereIn: [newParentId, otherParentId]).get();

            if (existingRelation.docs.isEmpty) {
              // Создаем связь "супруги" между родителями
              await _createRelation(
                treeId: treeId,
                person1Id: newParentId,
                person2Id: otherParentId,
                relation1to2: RelationType.spouse,
                relation2to1: RelationType.spouse,
              );

              print(
                'Создана связь между родителями: $newParentId и $otherParentId',
              );
            }
          }
        }
      }
    } catch (e) {
      print('Ошибка при создании связи между родителями: $e');
    }
  }

  // Модифицируем метод addRelative для работы с КОРНЕВОЙ коллекцией family_persons
  // и для поддержки ОФФЛАЙН добавления
  Future<String> addRelative(
    String treeId,
    Map<String, dynamic> personData,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    final personId = Uuid().v4();
    final now = DateTime.now();

    final lastName = personData['lastName'] ?? '';
    final firstName = personData['firstName'] ?? '';
    final middleName = personData['middleName'] ?? '';
    final fullName = [
      lastName,
      firstName,
      middleName,
    ].where((part) => part.isNotEmpty).join(' ');

    // --- ИСПРАВЛЕНИЕ: Конвертируем Timestamp обратно в DateTime? ---
    DateTime? birthDateFromData;
    if (personData['birthDate'] != null &&
        personData['birthDate'] is Timestamp) {
      birthDateFromData = (personData['birthDate'] as Timestamp).toDate();
    }
    DateTime? deathDateFromData;
    if (personData['deathDate'] != null &&
        personData['deathDate'] is Timestamp) {
      deathDateFromData = (personData['deathDate'] as Timestamp).toDate();
    }
    // --- КОНЕЦ ИСПРАВЛЕНИЯ ---

    // 1. Создаем объект FamilyPerson локально
    final person = FamilyPerson(
      id: personId,
      treeId: treeId,
      userId: null, // Оффлайн запись
      name: fullName,
      gender: FamilyPerson.genderFromString(
        personData['gender'],
      ), // Используем хелпер для конвертации
      isAlive: deathDateFromData == null, // Используем конвертированную дату
      creatorId: user.uid,
      createdAt: now,
      updatedAt: now,
      // Добавляем опциональные поля
      birthDate: birthDateFromData, // Используем конвертированную дату
      deathDate: deathDateFromData, // Используем конвертированную дату
      birthPlace: personData['birthPlace'],
      notes: personData['notes'],
      maidenName: personData['maidenName'],
      photoUrl: personData['photoUrl'], // Добавим photoUrl, если передается
      bio: personData['bio'], // Добавим bio
    );

    try {
      // 2. Сохраняем в ЛОКАЛЬНЫЙ кэш ВСЕГДА
      await _localStorageService.savePerson(person);
      print('Офлайн-родственник сохранен локально: $personId');

      // 3. Проверяем сеть и отправляем в Firestore, если онлайн
      if (_syncService.isOnline) {
        print('Сеть есть. Отправляем $personId в Firestore...');
        // Используем toMap() модели для отправки в Firestore
        // toMap() снова корректно преобразует DateTime? в Timestamp
        await _firestore
            .collection('family_persons')
            .doc(personId)
            .set(person.toMap());
        print('Офлайн-родственник успешно добавлен в Firestore: $personId');
      } else {
        print('Сети нет. $personId сохранен только локально.');
        // TODO: Добавить механизм отложенной синхронизации для таких записей
      }
    } catch (e) {
      print('Ошибка при добавлении/сохранении родственника $personId: $e');
      rethrow; // Пробрасываем ошибку
    }

    return personId;
  }

  // Добавляем метод updateRelative (для работы с корневой коллекцией)
  // Обновляем метод updateRelative для работы с кэшем и оффлайн
  Future<void> updateRelative(
    String personId,
    Map<String, dynamic> personData,
  ) async {
    // treeId не нужен, так как ищем по personId
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    try {
      // 1. Получаем текущий объект FamilyPerson (сначала из кэша, потом из Firestore)
      FamilyPerson? currentPerson = await getFamilyPerson(
        personId,
      ); // Используем уже обновленный метод getFamilyPerson

      if (currentPerson == null) {
        throw Exception(
          'Не удалось найти редактируемого человека ни в кэше, ни в Firestore.',
        );
      }

      // 2. Создаем обновленный объект БЕЗ copyWith
      final lastName = personData['lastName'] ??
          currentPerson.name.split(' ').firstOrNull ??
          '';
      final firstName = personData['firstName'] ??
          currentPerson.name.split(' ').elementAtOrNull(1) ??
          '';
      final middleName = personData['middleName'] ??
          currentPerson.name.split(' ').sublist(2).join(' ');
      final fullName = [
        lastName,
        firstName,
        middleName,
      ].where((p) => p.isNotEmpty).join(' ');

      // <<< ИСПРАВЛЕНИЕ: Конвертируем Timestamp в DateTime перед созданием объекта >>>
      DateTime? birthDateToUpdate = currentPerson.birthDate;
      if (personData.containsKey('birthDate')) {
        final birthDateValue = personData['birthDate'];
        if (birthDateValue is Timestamp) {
          birthDateToUpdate = birthDateValue.toDate();
        } else if (birthDateValue is DateTime?) {
          // На случай если уже DateTime
          birthDateToUpdate = birthDateValue;
        } else {
          birthDateToUpdate = null; // Или обработать ошибку
        }
      }

      DateTime? deathDateToUpdate = currentPerson.deathDate;
      if (personData.containsKey('deathDate')) {
        final deathDateValue = personData['deathDate'];
        if (deathDateValue is Timestamp) {
          deathDateToUpdate = deathDateValue.toDate();
        } else if (deathDateValue is DateTime?) {
          deathDateToUpdate = deathDateValue;
        } else {
          deathDateToUpdate = null; // Или обработать ошибку
        }
      }
      // <<< КОНЕЦ ИСПРАВЛЕНИЯ >>>

      final updatedPerson = FamilyPerson(
        // Обязательные поля берем из currentPerson
        id: currentPerson.id,
        treeId: currentPerson.treeId,
        creatorId: currentPerson.creatorId, // Не меняем
        createdAt: currentPerson.createdAt, // Не меняем
        // Обновляемые поля
        name: fullName,
        gender: personData['gender'] != null
            ? FamilyPerson.genderFromString(personData['gender'])
            : currentPerson.gender,
        birthDate: birthDateToUpdate, // <<< Используем конвертированную дату
        deathDate: deathDateToUpdate, // <<< Используем конвертированную дату
        birthPlace: personData.containsKey('birthPlace')
            ? personData['birthPlace']
            : currentPerson.birthPlace,
        notes: personData.containsKey('notes')
            ? personData['notes']
            : currentPerson.notes,
        maidenName: personData.containsKey('maidenName')
            ? personData['maidenName']
            : currentPerson.maidenName,
        photoUrl: personData.containsKey('photoUrl')
            ? personData['photoUrl']
            : currentPerson.photoUrl,
        bio: personData.containsKey('bio')
            ? personData['bio']
            : currentPerson.bio,
        isAlive: deathDateToUpdate ==
            null, // <<< Обновляем isAlive на основе конвертированной даты
        updatedAt: DateTime.now(), // Новое время обновления
        // Поля, которые пока не редактируем через эту форму, берем из currentPerson
        userId: currentPerson.userId,
        relation: currentPerson.relation,
        parentIds: currentPerson.parentIds,
        childrenIds: currentPerson.childrenIds,
        spouseId: currentPerson.spouseId,
        siblingIds: currentPerson.siblingIds,
        details: currentPerson.details,
      );

      // 3. Сохраняем обновленный объект в ЛОКАЛЬНЫЙ кэш ВСЕГДА
      await _localStorageService.savePerson(updatedPerson);
      print('Родственник $personId обновлен локально.');

      // 4. Проверяем сеть и отправляем обновление в Firestore, если онлайн
      if (_syncService.isOnline) {
        print('Сеть есть. Обновляем $personId в Firestore...');
        // Готовим данные для Firestore (могут отличаться от локальных, если надо)
        final firestoreUpdateData = updatedPerson.toMap();
        // Удаляем поля, которые не должны обновляться напрямую (например, createdAt)
        firestoreUpdateData.remove('createdAt');
        firestoreUpdateData.remove('creatorId'); // Не меняем создателя
        firestoreUpdateData.remove('id'); // Не обновляем ID

        await _firestore
            .collection('family_persons')
            .doc(personId)
            .update(firestoreUpdateData);
        print('Родственник $personId успешно обновлен в Firestore.');
      } else {
        print('Сети нет. Обновление для $personId сохранено только локально.');
        // TODO: Механизм отложенной синхронизации
      }
    } catch (e) {
      print('Ошибка при обновлении родственника $personId: $e');
      rethrow;
    }
  }

  // Вспомогательный метод для преобразования Gender в строку
  String genderToString(Gender gender) {
    switch (gender) {
      case Gender.male:
        return 'male';
      case Gender.female:
        return 'female';
      case Gender.unknown:
        return 'unknown';
      default:
        return 'unknown';
    }
  }

  // Добавляем метод _createRelation
  Future<void> _createRelation({
    required String treeId,
    required String person1Id,
    required String person2Id,
    required RelationType relation1to2,
    required RelationType relation2to1,
  }) async {
    final relationId = Uuid().v4();
    final now = DateTime.now();

    await _firestore.collection('family_relations').doc(relationId).set({
      'id': relationId,
      'treeId': treeId,
      'person1Id': person1Id,
      'person2Id': person2Id,
      'relation1to2': relation1to2.toString().split('.').last,
      'relation2to1': relation2to1.toString().split('.').last,
      'createdAt': Timestamp.fromDate(now),
      'updatedAt': Timestamp.fromDate(now),
      'createdBy': _auth.currentUser!.uid,
      'isConfirmed': true,
    });
  }

  // <<< НАЧАЛО: НОВЫЕ МЕТОДЫ РАСЧЕТА СВЯЗЕЙ >>>

  // Основной метод для определения отношения между двумя людьми
  Future<RelationType> getRelationBetween(
    String treeId,
    String personAId,
    String personBId,
  ) async {
    // 0. Проверка на самого себя
    if (personAId == personBId)
      return RelationType.other; // Пока other, т.к. self не стандартный

    // Сначала пытаемся найти отношение в кэше
    RelationType? cachedRelation = _localStorageService
        .getCachedRelationBetween(treeId, personAId, personBId);
    if (cachedRelation != null) {
      print(
        'Relation between $personAId and $personBId found in cache: $cachedRelation',
      );
      return cachedRelation;
    }
    print(
      'Relation between $personAId and $personBId not in cache, calculating...',
    );

    // 2. Загружаем ВСЕ связи для данного дерева (оптимизация: кэшировать)
    // TODO: Оптимизировать загрузку связей, возможно, загружать только нужные?
    List<FamilyRelation> allRelations = await getRelations(
      treeId,
    ); // Используем существующий метод

    // 3. Проверяем, что оба пользователя существуют (опционально, если нужно)
    // final person1Exists = allRelations.any((r) => r.person1Id == personAId || r.person2Id == personAId);
    // final person2Exists = allRelations.any((r) => r.person1Id == personBId || r.person2Id == personBId);
    // if (!person1Exists || !person2Exists) {
    //   print('Один из пользователей ($personAId или $personBId) не найден в связях дерева $treeId');
    //   return RelationType.other; // Или бросить исключение?
    // }

    // 4. Ищем прямую связь (personAId -> personBId)
    final directRelation = allRelations.firstWhereOrNull(
      (rel) => rel.person1Id == personAId && rel.person2Id == personBId,
    );

    if (directRelation != null) {
      print(
        'Найдена прямая связь между $personAId и $personBId: ${directRelation.relation1to2}',
      );
      // Прямая связь найдена, возвращаем отношение personAId к personBId
      // Сохраняем в кеш перед возвратом
      _localStorageService.cacheRelationBetween(
        treeId,
        personAId,
        personBId,
        directRelation.relation1to2,
      );
      return directRelation.relation1to2;
    }

    // 5. Ищем обратную связь (personBId -> personAId)
    final reverseRelation = allRelations.firstWhereOrNull(
      (rel) => rel.person1Id == personBId && rel.person2Id == personAId,
    );

    if (reverseRelation != null) {
      // Найдена обратная связь (personBId -> personAId).
      // Поле reverseRelation.relation1to2 содержит отношение personBId к personAId.
      // Поле reverseRelation.relation2to1 содержит отношение personAId к personBId.
      print(
        'Найдена обратная связь: $personBId -> $personAId = ${reverseRelation.relation1to2}',
      );
      // <<< ИСПРАВЛЕНО: Возвращаем relation2to1 >>>
      final relation1to2 = reverseRelation.relation2to1;
      print(
        'Возвращаем отношение personAId ($personAId) к personBId ($personBId): $relation1to2',
      );
      // Сохраняем в кеш перед возвратом
      _localStorageService.cacheRelationBetween(
        treeId,
        personAId,
        personBId,
        relation1to2,
      );
      return relation1to2;
    }

    // 6. Если прямой или обратной связи нет, ищем путь
    print(
      'Прямая/обратная связь не найдена между $personAId и $personBId. Ищем путь...',
    );

    // 7. Построение графа смежности (Map<String, List<String>>)
    Map<String, List<String>> adjacencyList = _buildAdjacencyList(allRelations);

    // 8. Поиск пути (BFS)
    List<String>? path = _findShortestPathBFS(
      adjacencyList,
      personAId,
      personBId,
    );

    if (path == null || path.isEmpty) {
      print('Путь не найден между $personAId и $personBId');
      return RelationType.other; // Путь не найден
    }
    print('Найден путь: ${path.join(" -> ")}');

    // 9. Анализ пути для определения типа родства
    RelationType result = _analyzePath(path, allRelations);

    return result;
  }

  // Хелпер: Поиск прямой или обратной связи
  Future<RelationType?> _findDirectRelation(
    String treeId,
    String personAId,
    String personBId,
  ) async {
    try {
      // Прямая связь A -> B
      final directQuery = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person1Id', isEqualTo: personAId)
          .where('person2Id', isEqualTo: personBId)
          .limit(1)
          .get();

      if (directQuery.docs.isNotEmpty) {
        final relationStr = directQuery.docs.first['relation1to2'] as String?;
        if (relationStr != null) return _getRelationTypeFromString(relationStr);
      }

      // Обратная связь B -> A
      final reverseQuery = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person1Id', isEqualTo: personBId)
          .where('person2Id', isEqualTo: personAId)
          .limit(1)
          .get();

      if (reverseQuery.docs.isNotEmpty) {
        // Нам нужно отношение от A к B, поэтому берем relation2to1 из обратной связи
        final relationStr = reverseQuery.docs.first['relation2to1'] as String?;
        if (relationStr != null) return _getRelationTypeFromString(relationStr);
      }

      return null; // Связь не найдена
    } catch (e) {
      print('Ошибка при поиске прямой связи: $e');
      return null;
    }
  }

  // Хелпер: Построение графа смежности
  Map<String, List<String>> _buildAdjacencyList(
    List<FamilyRelation> relations,
  ) {
    Map<String, List<String>> adjList = {};
    for (var rel in relations) {
      // Добавляем ребро в обе стороны, так как ищем путь в неориентированном графе
      adjList.putIfAbsent(rel.person1Id, () => []).add(rel.person2Id);
      adjList.putIfAbsent(rel.person2Id, () => []).add(rel.person1Id);
    }
    // Удаляем дубликаты в списках смежности
    adjList.forEach((key, value) {
      adjList[key] = value.toSet().toList();
    });
    return adjList;
  }

  // Хелпер: Поиск кратчайшего пути (BFS)
  List<String>? _findShortestPathBFS(
    Map<String, List<String>> graph,
    String startNode,
    String endNode,
  ) {
    if (!graph.containsKey(startNode) || !graph.containsKey(endNode)) {
      return null; // Один из узлов отсутствует в графе
    }

    Queue<List<String>> queue = Queue(); // Очередь для хранения путей
    Set<String> visited = {}; // Множество посещенных узлов

    // Начинаем с пути, содержащего только начальный узел
    queue.add([startNode]);
    visited.add(startNode);

    while (queue.isNotEmpty) {
      List<String> currentPath = queue.removeFirst();
      String lastNode = currentPath.last;

      // Если достигли конечного узла, возвращаем путь
      if (lastNode == endNode) {
        return currentPath;
      }

      // Исследуем соседей последнего узла в текущем пути
      if (graph.containsKey(lastNode)) {
        for (String neighbor in graph[lastNode]!) {
          if (!visited.contains(neighbor)) {
            visited.add(neighbor);
            // Создаем новый путь, добавляя соседа
            List<String> newPath = List.from(currentPath)..add(neighbor);
            queue.add(newPath);
          }
        }
      }
    }

    return null; // Путь не найден
  }

  // Хелпер: Анализ пути для определения типа родства
  RelationType _analyzePath(
    List<String> path,
    List<FamilyRelation> allRelations,
  ) {
    if (path.length <= 1) return RelationType.other; // Путь слишком короткий

    // --- Вспомогательная функция для поиска связи между двумя ID ---
    FamilyRelation? findRelation(String id1, String id2) {
      try {
        return allRelations.firstWhere(
          (r) =>
              (r.person1Id == id1 && r.person2Id == id2) ||
              (r.person1Id == id2 && r.person2Id == id1),
        );
      } catch (e) {
        return null; // Связь не найдена
      }
    }
    // --- Конец вспомогательной функции ---

    if (path.length == 2) {
      // Прямая связь (A -> B)
      print('Анализ пути: Прямая связь (длина 2)');
      final relation = findRelation(path[0], path[1]);
      if (relation != null) {
        // Возвращаем отношение ОТ path[0] К path[1]
        return relation.person1Id == path[0]
            ? relation.relation1to2
            : relation.relation2to1;
      }
      print(
        'Предупреждение: Не найдена прямая связь для пути ${path.join(" -> ")}',
      );
      return RelationType.other;
    }

    if (path.length == 3) {
      // Путь через одного посредника (A -> B -> C)
      print('Анализ пути: Длина 3 (${path.join(" -> ")})');
      final relAB = findRelation(path[0], path[1]);
      final relBC = findRelation(path[1], path[2]);

      if (relAB == null || relBC == null) {
        print('Ошибка: Не удалось найти связи для анализа пути.');
        return RelationType.other;
      }

      // Определяем тип связи от A к B и от B к C
      RelationType typeAtoB =
          relAB.person1Id == path[0] ? relAB.relation1to2 : relAB.relation2to1;
      RelationType typeBtoC =
          relBC.person1Id == path[1] ? relBC.relation1to2 : relBC.relation2to1;

      print('Шаги пути: $typeAtoB -> $typeBtoC');
      // DEBUG ЛОГИРОВАНИЕ ДЛЯ ДЛИНЫ 3
      print(
        '[Debug _analyzePath L3] Comparing for sibling (child->parent): typeAtoB == RelationType.child (${typeAtoB == RelationType.child}) && typeBtoC == RelationType.parent (${typeBtoC == RelationType.parent})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for sibling (child->child): typeAtoB == RelationType.child (${typeAtoB == RelationType.child}) && typeBtoC == RelationType.child (${typeBtoC == RelationType.child})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for grandparent: typeAtoB == RelationType.parent (${typeAtoB == RelationType.parent}) && typeBtoC == RelationType.parent (${typeBtoC == RelationType.parent})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for grandchild: typeAtoB == RelationType.child (${typeAtoB == RelationType.child}) && typeBtoC == RelationType.child (${typeBtoC == RelationType.child})',
      ); // Повтор, но для наглядности
      print(
        '[Debug _analyzePath L3] Comparing for parent (parent->sibling): typeAtoB == RelationType.parent (${typeAtoB == RelationType.parent}) && typeBtoC == RelationType.sibling (${typeBtoC == RelationType.sibling})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for uncle (sibling->parent): typeAtoB == RelationType.sibling (${typeAtoB == RelationType.sibling}) && typeBtoC == RelationType.parent (${typeBtoC == RelationType.parent})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for nephew (child->sibling): typeAtoB == RelationType.child (${typeAtoB == RelationType.child}) && typeBtoC == RelationType.sibling (${typeBtoC == RelationType.sibling})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for uncle (sibling->child): typeAtoB == RelationType.sibling (${typeAtoB == RelationType.sibling}) && typeBtoC == RelationType.child (${typeBtoC == RelationType.child})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for stepparent (spouse->parent): typeAtoB == RelationType.spouse (${typeAtoB == RelationType.spouse}) && typeBtoC == RelationType.parent (${typeBtoC == RelationType.parent})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for parentInLaw (parent->spouse): typeAtoB == RelationType.parent (${typeAtoB == RelationType.parent}) && typeBtoC == RelationType.spouse (${typeBtoC == RelationType.spouse})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for childInLaw (spouse->child): typeAtoB == RelationType.spouse (${typeAtoB == RelationType.spouse}) && typeBtoC == RelationType.child (${typeBtoC == RelationType.child})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for child (child->spouse): typeAtoB == RelationType.child (${typeAtoB == RelationType.child}) && typeBtoC == RelationType.spouse (${typeBtoC == RelationType.spouse})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for siblingInLaw (spouse->sibling): typeAtoB == RelationType.spouse (${typeAtoB == RelationType.spouse}) && typeBtoC == RelationType.sibling (${typeBtoC == RelationType.sibling})',
      );
      print(
        '[Debug _analyzePath L3] Comparing for siblingInLaw (sibling->spouse): typeAtoB == RelationType.sibling (${typeAtoB == RelationType.sibling}) && typeBtoC == RelationType.spouse (${typeBtoC == RelationType.spouse})',
      );

      // --- Правила для пути A -> B -> C (определяем отношение A к C) ---

      // Ребенок родителя -> Брат/Сестра
      if (typeAtoB == RelationType.child && typeBtoC == RelationType.parent) {
        print('[Debug _analyzePath L3] Matched: child -> parent => sibling');
        return RelationType.sibling;
      }
      // Ребенок ребенка -> Внук/Внучка
      if (typeAtoB == RelationType.child && typeBtoC == RelationType.child) {
        print(
          '[Debug _analyzePath L3] Matched: child -> child => grandchild',
        ); // ИЗМЕНЕНО: grandchild вместо sibling
        return RelationType.grandchild;
      }
      // Родитель родителя -> Дедушка/Бабушка
      if (typeAtoB == RelationType.parent && typeBtoC == RelationType.parent) {
        print(
          '[Debug _analyzePath L3] Matched: parent -> parent => grandparent',
        );
        return RelationType.grandparent;
      }
      // Родитель брата/сестры -> Родитель
      if (typeAtoB == RelationType.parent && typeBtoC == RelationType.sibling) {
        print('[Debug _analyzePath L3] Matched: parent -> sibling => parent');
        return RelationType.parent;
      }
      // Брат/сестра родителя -> Дядя/Тетя
      if (typeAtoB == RelationType.sibling && typeBtoC == RelationType.parent) {
        print('[Debug _analyzePath L3] Matched: sibling -> parent => uncle');
        return RelationType.uncle;
      }
      // Ребенок брата/сестры -> Племянник/Племянница
      if (typeAtoB == RelationType.child && typeBtoC == RelationType.sibling) {
        print(
          '[Debug _analyzePath L3] Matched: child -> sibling => nephew',
        ); // <<< ИСПРАВЛЕНО: Вернул nephew
        return RelationType.nephew;
      }
      // Брат/сестра ребенка -> Ребенок (другой ребенок пользователя)
      if (typeAtoB == RelationType.sibling && typeBtoC == RelationType.child) {
        print(
          '[Debug _analyzePath L3] Matched: sibling -> child => nephew',
        ); // <<< ИСПРАВЛЕНО: Должно быть nephew, а не uncle
        return RelationType.nephew;
      }
      // Супруг родителя -> Отчим/Мачеха
      if (typeAtoB == RelationType.spouse && typeBtoC == RelationType.parent) {
        print(
          '[Debug _analyzePath L3] Matched: spouse -> parent => stepparent',
        );
        return RelationType.stepparent;
      }
      // Родитель супруга -> Тесть/Теща/Свекор/Свекровь
      if (typeAtoB == RelationType.parent && typeBtoC == RelationType.spouse) {
        print(
          '[Debug _analyzePath L3] Matched: parent -> spouse => parentInLaw',
        );
        return RelationType.parentInLaw;
      }
      // Супруг ребенка -> Зять/Невестка
      if (typeAtoB == RelationType.spouse && typeBtoC == RelationType.child) {
        print('[Debug _analyzePath L3] Matched: spouse -> child => childInLaw');
        return RelationType.childInLaw;
      }
      // Ребенок супруга -> Ребенок (пасынок/падчерица - частный случай ребенка)
      if (typeAtoB == RelationType.child && typeBtoC == RelationType.spouse) {
        print('[Debug _analyzePath L3] Matched: child -> spouse => child');
        return RelationType.child;
      }
      // Супруг брата/сестры -> Свояк/Свояченица
      if (typeAtoB == RelationType.spouse && typeBtoC == RelationType.sibling) {
        print(
          '[Debug _analyzePath L3] Matched: spouse -> sibling => siblingInLaw',
        );
        return RelationType.siblingInLaw;
      }
      // Брат/сестра супруга -> Свояк/Свояченица
      if (typeAtoB == RelationType.sibling && typeBtoC == RelationType.spouse) {
        print(
          '[Debug _analyzePath L3] Matched: sibling -> spouse => siblingInLaw',
        );
        return RelationType.siblingInLaw;
      }

      // Если ни одно правило не подошло для пути длиной 3
      print('Не найдено правило для комбинации $typeAtoB -> $typeBtoC');
      return RelationType.other;
    }

    if (path.length == 4) {
      // Путь A -> B -> C -> D (Анализируем связь A к D)
      print('Анализ пути: Длина 4 (${path.join(" -> ")})');
      final relAB = findRelation(path[0], path[1]);
      final relBC = findRelation(path[1], path[2]);
      final relCD = findRelation(path[2], path[3]);

      if (relAB == null || relBC == null || relCD == null) {
        print('Ошибка: Не удалось найти связи для анализа пути.');
        return RelationType.other;
      }

      RelationType typeAtoB =
          relAB.person1Id == path[0] ? relAB.relation1to2 : relAB.relation2to1;
      RelationType typeBtoC =
          relBC.person1Id == path[1] ? relBC.relation1to2 : relBC.relation2to1;
      RelationType typeCtoD =
          relCD.person1Id == path[2] ? relCD.relation1to2 : relCD.relation2to1;

      print('Шаги пути: $typeAtoB -> $typeBtoC -> $typeCtoD');

      // DEBUG ЛОГИРОВАНИЕ ДЛЯ ДЛИНЫ 4
      print(
        '[Debug _analyzePath L4] Comparing for cousin (parent->sibling->child): A($typeAtoB)==parent && B($typeBtoC)==sibling && C($typeCtoD)==child',
      );
      print(
        '[Debug _analyzePath L4] Comparing for grandNephew (sibling->child->child): A($typeAtoB)==sibling && B($typeBtoC)==child && C($typeCtoD)==child',
      );
      print(
        '[Debug _analyzePath L4] Comparing for sibling (child->parent->sibling): A($typeAtoB)==child && B($typeBtoC)==parent && C($typeCtoD)==sibling',
      );
      print(
        '[Debug _analyzePath L4] Comparing for siblingInLaw (child->parent->spouse): A($typeAtoB)==child && B($typeBtoC)==parent && C($typeCtoD)==spouse',
      );
      print(
        '[Debug _analyzePath L4] Comparing for nephew (child->parent->child): A($typeAtoB)==child && B($typeBtoC)==parent && C($typeCtoD)==child',
      );

      // --- Правила для пути A -> B -> C -> D (определяем отношение A к D) ---

      // Родитель -> Брат/Сестра -> Ребенок = Двоюродный брат/сестра (Кузен)
      if (typeAtoB == RelationType.parent &&
          typeBtoC == RelationType.sibling &&
          typeCtoD == RelationType.child) {
        print(
          '[Debug _analyzePath L4] Matched: parent->sibling->child => cousin',
        );
        return RelationType.cousin;
      }
      // Брат/Сестра -> Ребенок -> Ребенок = Двоюродный племянник/ца
      if (typeAtoB == RelationType.sibling &&
          typeBtoC == RelationType.child &&
          typeCtoD == RelationType.child) {
        print(
          "[Debug _analyzePath L4] Matched: sibling->child->child => grandNephew (returning other for now)",
        );
        return RelationType.other; // TODO: Добавить grandNephew?
      }
      // Ты -> Родитель -> Твой сиблинг -> Сестра/Брат этого сиблинга (A(child) -> B(parent) -> C(sibling) -> D(sibling)) = Сестра/брат
      if (typeAtoB == RelationType.child &&
          typeBtoC == RelationType.parent &&
          typeCtoD == RelationType.sibling) {
        print(
          '[Debug _analyzePath L4] Matched: child->parent->sibling => sibling',
        );
        return RelationType.sibling;
      }
      // Ты -> Родитель -> Сиблинг -> Супруг сиблинга (A(child) -> B(parent) -> C(sibling) -> D(spouse)) = Супруг свояка/свояченицы (не очень стандартно, вернем other)
      // if (typeAtoB == RelationType.child && typeBtoC == RelationType.parent && typeCtoD == RelationType.spouse) {
      //    print('[Debug _analyzePath L4] Matched: child->parent->sibling->spouse => other (spouse of sibling-in-law)');
      //    return RelationType.other; // Или создать новый тип?
      // }

      // Ты -> Родитель -> Супруг сиблинга (A(child) -> B(parent) -> C(spouse of B) -> D(sibling of C)) ??? Слишком сложно
      // Пересмотрел правило: Ты -> Мама -> Алина(дочь мамы) -> Владимир(супруг Алины)
      // Шаги: child -> parent -> spouse
      if (typeAtoB == RelationType.child &&
          typeBtoC == RelationType.parent &&
          typeCtoD == RelationType.spouse) {
        print(
          '[Debug _analyzePath L4] Matched: child->parent->spouse => siblingInLaw',
        );
        return RelationType.siblingInLaw;
      }
      // Ты -> Родитель -> Сиблинг -> Ребенок сиблинга (A(child) -> B(parent) -> C(parent)) => Племянник/Племянница
      // <<< ИСПРАВЛЕНИЕ: Условие должно быть child -> parent -> parent >>>
      if (typeAtoB == RelationType.child &&
          typeBtoC == RelationType.parent &&
          typeCtoD == RelationType.parent) {
        print(
          '[Debug _analyzePath L4] Matched: child->parent->parent => other (was nephew, but path is wrong)',
        );
        return RelationType
            .other; // Возвращаем other, т.к. семантика пути не соответствует племяннику
      }

      print(
        'Не найдено правило для комбинации $typeAtoB -> $typeBtoC -> $typeCtoD',
      );
      return RelationType.other;
    }

    // Если путь длиннее 4, пока считаем его слишком сложным
    print(
      '_analyzePath: Анализ пути пока не реализован для длины ${path.length}',
    );
    return RelationType.other;
  }

  // <<< КОНЕЦ: НОВЫЕ МЕТОДЫ РАСЧЕТА СВЯЗЕЙ >>>

  // Метод для определения отношения нового человека к текущему пользователю
  Future<RelationType> deduceRelation(
    String treeId,
    String newPersonId,
    String anchorPersonId,
  ) async {
    final currentUserId = _auth.currentUser?.uid;
    if (currentUserId == null) {
      print('Ошибка: deduceRelation вызван без авторизованного пользователя.');
      return RelationType
          .other; // Нет пользователя, не можем определить отношение
    }

    if (newPersonId == currentUserId) {
      // Если новый человек - это сам пользователь (маловероятно, но возможно)
      return RelationType.other; // Или можно ввести RelationType.self
    }

    print(
      'Вычисляем отношение между новым человеком ($newPersonId) и текущим пользователем ($currentUserId) в дереве $treeId',
    );
    // Используем существующий метод для расчета пути и отношения
    try {
      // Важно: Определяем отношение ОТ нового человека (newPersonId) К текущему пользователю (currentUserId)
      return await getRelationBetween(treeId, newPersonId, currentUserId);
    } catch (e) {
      print('Ошибка при вычислении отношения в deduceRelation: $e');
      return RelationType.other;
    }
  }

  // Обновляем старый метод getRelationToUser, чтобы он использовал новый
  Future<RelationType> getRelationToUser(
    String treeId,
    String relativeId,
  ) async {
    final userId = _auth.currentUser?.uid;
    if (userId == null) return RelationType.other;

    return await getRelationBetween(
      treeId,
      userId,
      relativeId,
    ); // Note: direction is user -> relative here
  }

  // Комментируем или удаляем старый рекурсивный метод
  /*
  Future<RelationType> _buildRelationPathToUser(String treeId, String relativeId, int maxDepth) async {
    // ... старый код ...
  }
  */

  // Добавляем метод для получения отношения к пользователю
  RelationType _getRelationTypeFromString(String relationStr) {
    try {
      return RelationType.values.firstWhere(
        (r) => r.toString().split('.').last == relationStr,
        orElse: () => RelationType.other,
      );
    } catch (e) {
      print('Ошибка при преобразовании отношения: $e');
      return RelationType.other;
    }
  }

  // Метод для добавления отношения между родственниками
  Future<void> addRelation(
    String treeId,
    String person1Id,
    String person2Id,
    RelationType relationType,
  ) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('Необходимо авторизоваться');
    }

    // Определяем обратное отношение
    RelationType reverseRelationType;
    switch (relationType) {
      case RelationType.parent:
        reverseRelationType = RelationType.child;
        break;
      case RelationType.child:
        reverseRelationType = RelationType.parent;
        break;
      case RelationType.spouse:
        reverseRelationType = RelationType.spouse;
        break;
      case RelationType.sibling:
        reverseRelationType = RelationType.sibling;
        break;
      default:
        reverseRelationType = RelationType.other;
    }

    // Создаем отношение в Firestore
    await createRelation(
      treeId: treeId,
      person1Id: person1Id,
      person2Id: person2Id,
      relation1to2: relationType,
      isConfirmed: true,
    );

    // Создаем обратное отношение
    await createRelation(
      treeId: treeId,
      person1Id: person2Id,
      person2Id: person1Id,
      relation1to2: reverseRelationType,
      isConfirmed: true,
    );

    // Обновляем поле relation в документах родственников
    try {
      // Получаем строковое представление типа отношения
      String relationString = FamilyRelation.relationTypeToString(relationType);
      String reverseRelationString = FamilyRelation.relationTypeToString(
        reverseRelationType,
      );

      print(
        'Обновляем связи: person1Id=$person1Id получает связь=$relationString, person2Id=$person2Id получает связь=$reverseRelationString',
      );

      // Проверяем существование документов перед обновлением
      // Обновляем поле relation для первого человека (person1Id) в коллекции relatives
      final relativesDoc1 = await _firestore
          .collection('family_trees')
          .doc(treeId)
          .collection('relatives')
          .doc(person1Id)
          .get();

      if (relativesDoc1.exists) {
        await _firestore
            .collection('family_trees')
            .doc(treeId)
            .collection('relatives')
            .doc(person1Id)
            .update({'relation': relationString});
      }

      // Обновляем поле relation для второго человека (person2Id) в коллекции relatives
      final relativesDoc2 = await _firestore
          .collection('family_trees')
          .doc(treeId)
          .collection('relatives')
          .doc(person2Id)
          .get();

      if (relativesDoc2.exists) {
        await _firestore
            .collection('family_trees')
            .doc(treeId)
            .collection('relatives')
            .doc(person2Id)
            .update({'relation': reverseRelationString});
      }

      // Проверяем существование документов в коллекции family_persons
      final familyPersonsDoc1 = await _firestore
          .collection('family_trees')
          .doc(treeId)
          .collection('family_persons')
          .doc(person1Id)
          .get();

      if (familyPersonsDoc1.exists) {
        await _firestore
            .collection('family_trees')
            .doc(treeId)
            .collection('family_persons')
            .doc(person1Id)
            .update({'relation': relationString});
      }

      final familyPersonsDoc2 = await _firestore
          .collection('family_trees')
          .doc(treeId)
          .collection('family_persons')
          .doc(person2Id)
          .get();

      if (familyPersonsDoc2.exists) {
        await _firestore
            .collection('family_trees')
            .doc(treeId)
            .collection('family_persons')
            .doc(person2Id)
            .update({'relation': reverseRelationString});
      }

      print('Отношения успешно обновлены между $person1Id и $person2Id');
    } catch (e) {
      print('Ошибка при обновлении поля relation: $e');
    }
  }

  // Метод для обновления типов отношений в документе family_relations
  Future<void> updateRelationTypes(
    String treeId,
    String relationId,
    RelationType relation1to2,
    RelationType relation2to1,
  ) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('Необходимо авторизоваться');
      }

      // Преобразуем типы отношений в строки
      final relation1to2Str = _relationTypeToString(relation1to2);
      final relation2to1Str = _relationTypeToString(relation2to1);

      // Обновляем документ в коллекции family_relations
      await _firestore.collection('family_relations').doc(relationId).update({
        'relation1to2': relation1to2Str,
        'relation2to1': relation2to1Str,
        'updatedAt': DateTime.now(),
      });

      print('Типы отношений успешно обновлены в документе $relationId');
    } catch (e) {
      print('Ошибка при обновлении типов отношений: $e');
      throw e;
    }
  }

  // Метод для преобразования RelationType в строку
  String _relationTypeToString(RelationType relationType) {
    return relationType.toString().split('.').last;
  }

  // НОВЫЙ метод для получения родственников дерева из корневой коллекции
  Future<List<FamilyPerson>> getRelatives(String treeId) async {
    try {
      // Проверяем соединение (можно убрать, если LocalStorage не используется для кеша)
      // final connectivityResult = await Connectivity().checkConnectivity();
      // final isOnline = connectivityResult != ConnectivityResult.none;

      // TODO: Реализовать чтение из кеша LocalStorageService, если офлайн?

      // Получаем всех людей для данного дерева из КОРНЕВОЙ коллекции
      final snapshot = await _firestore
          .collection('family_persons')
          .where('treeId', isEqualTo: treeId)
          .get();

      final relatives =
          snapshot.docs.map((doc) => FamilyPerson.fromFirestore(doc)).toList();

      print(
        'Загружено ${relatives.length} родственников для дерева $treeId из корневой коллекции.',
      );

      // TODO: Сохранить в кеш LocalStorageService?
      // for (var person in relatives) {
      //   await _localStorageService.savePerson(person);
      // }

      return relatives;
    } catch (e) {
      print('Ошибка при получении родственников для дерева $treeId: $e');
      return []; // Возвращаем пустой список в случае ошибки
    }
  }

  // Получение всех связей в указанном дереве
  Future<List<FamilyRelation>> getRelationsByTreeId(String treeId) async {
    List<FamilyRelation>? relationsFromFirestore;
    bool isOnline = _syncService.isOnline;

    if (isOnline) {
      try {
        // 1. Если онлайн, ВСЕГДА пытаемся загрузить из Firestore
        print('Relations for tree $treeId: Online, fetching from Firestore...');
        final relationsQuery = await _firestore
            .collection('family_relations')
            .where('treeId', isEqualTo: treeId)
            .get();

        relationsFromFirestore = relationsQuery.docs
            .map((doc) => FamilyRelation.fromFirestore(doc))
            .toList();

        // 4. Сохраняем свежие данные в кэш
        await _localStorageService.saveRelations(relationsFromFirestore);
        print(
          'Fetched ${relationsFromFirestore.length} relations for tree $treeId from Firestore and updated cache.',
        );
        return relationsFromFirestore; // Возвращаем свежие данные
      } catch (e) {
        print('Error fetching relations from Firestore for tree $treeId: $e');
        // Ошибка Firestore, попробуем вернуть из кэша ниже
        relationsFromFirestore = null; // Сбрасываем, чтобы использовать кэш
      }
    }

    // 2. Если ОФФЛАЙН или произошла ошибка Firestore, пробуем из кэша
    print(
      'Relations for tree $treeId: Offline or Firestore error, trying cache...',
    );
    try {
      final cachedRelations = await _localStorageService.getRelationsByTreeId(
        treeId,
      );
      print(
        'Found ${cachedRelations.length} relations for tree $treeId in cache.',
      );
      return cachedRelations;
    } catch (cacheError) {
      print('Error reading relations cache for tree $treeId: $cacheError');
      return []; // Возвращаем пустой список, если и кэш недоступен
    }
  }

  // Метод getRelations просто вызывает getRelationsByTreeId
  Future<List<FamilyRelation>> getRelations(String treeId) async {
    return await getRelationsByTreeId(treeId);
  }

  // <<< НАЧАЛО: АВТОМАТИЧЕСКОЕ СОЗДАНИЕ СВЯЗИ СУПРУГОВ >>>
  Future<void> checkAndCreateSpouseRelationIfNeeded(
    String treeId,
    String childId,
    String newParentId,
  ) async {
    print('Check Spouse: Start for child $childId, new parent $newParentId');
    try {
      // 1. Находим ВСЕ связи, где childId является ребенком (person2Id)
      print('Check Spouse: Querying parent relations for child $childId');
      final parentRelationsQuery = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person2Id', isEqualTo: childId)
          .where('relation1to2', isEqualTo: 'parent')
          .get();
      print(
        'Check Spouse: Found ${parentRelationsQuery.docs.length} parent relations.',
      );

      // 2. Собираем ID всех родителей этого ребенка
      final parentIds = parentRelationsQuery.docs.map((doc) {
        // Логируем данные документа перед извлечением ID
        print('Check Spouse: Parent relation doc data: ${doc.data()}');
        return doc['person1Id'] as String;
      }).toList();

      print('Check Spouse: Found parent IDs for $childId: $parentIds');

      // 3. Исключаем только что добавленного родителя
      final otherParentIds =
          parentIds.where((id) => id != newParentId).toList();
      print(
        'Check Spouse: Other parent IDs (excluding $newParentId): $otherParentIds',
      );

      // 4. Если есть ХОТЯ БЫ ОДИН другой родитель
      if (otherParentIds.isNotEmpty) {
        final otherParentId = otherParentIds.first;
        print(
          'Check Spouse: Found other parent $otherParentId. Checking spouse relation with $newParentId',
        );

        // 5. Проверяем, существует ли уже связь "spouse" между newParentId и otherParentId
        final existingSpouseRelationQuery = await _firestore
            .collection('family_relations')
            .where('treeId', isEqualTo: treeId)
            .where('person1Id', whereIn: [newParentId, otherParentId])
            .where('person2Id', whereIn: [newParentId, otherParentId])
            .where('relation1to2', isEqualTo: 'spouse')
            .limit(1)
            .get();
        print(
          'Check Spouse: Found ${existingSpouseRelationQuery.docs.length} existing spouse relations.',
        );

        // 6. Если связь "spouse" НЕ найдена, создаем ее
        if (existingSpouseRelationQuery.docs.isEmpty) {
          print('Check Spouse: Spouse relation not found. Creating...');
          await createRelation(
            treeId: treeId,
            person1Id: newParentId,
            person2Id: otherParentId,
            relation1to2: RelationType.spouse,
            isConfirmed: true,
          );
          print(
            'Check Spouse: Spouse relation created between $newParentId and $otherParentId.',
          );
        } else {
          print(
            'Check Spouse: Spouse relation already exists between $newParentId and $otherParentId.',
          );
        }
      } else {
        print('Check Spouse: No other parent found for $childId.');
      }
    } catch (e, s) {
      // Добавляем StackTrace в лог
      print('Check Spouse: Error: $e\n$s');
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'CheckSpouseRelationError',
      );
    }
    print('Check Spouse: End for child $childId, new parent $newParentId');
  }
  // <<< КОНЕЦ: АВТОМАТИЧЕСКОЕ СОЗДАНИЕ СВЯЗИ СУПРУГОВ >>>

  // <<< НАЧАЛО: АВТОМАТИЧЕСКОЕ СОЗДАНИЕ СВЯЗЕЙ РОДИТЕЛЬ-СИБЛИНГ >>>
  Future<void> checkAndCreateParentSiblingRelations(
    String treeId,
    String existingSiblingId,
    String newSiblingId,
  ) async {
    print(
      'Check ParentSibling: Start for new sibling $newSiblingId based on existing $existingSiblingId',
    );
    try {
      // 1. Находим всех родителей для existingSiblingId
      print('Check ParentSibling: Querying parents for $existingSiblingId');
      final parentRelationsQuery = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person2Id', isEqualTo: existingSiblingId)
          .where('relation1to2', isEqualTo: 'parent')
          .get();
      print(
        'Check ParentSibling: Found ${parentRelationsQuery.docs.length} parents for $existingSiblingId.',
      );

      final parentIds = parentRelationsQuery.docs.map((doc) {
        print('Check ParentSibling: Parent relation doc data: ${doc.data()}');
        return doc['person1Id'] as String;
      }).toList();
      print('Check ParentSibling: Found parent IDs: $parentIds');

      // 2. Для каждого найденного родителя создаем связь с newSiblingId
      for (var parentId in parentIds) {
        print(
          'Check ParentSibling: Processing parent $parentId for new sibling $newSiblingId',
        );
        // Проверяем, есть ли уже связь parentId -> parent -> newSiblingId
        final existingRelationQuery = await _firestore
            .collection('family_relations')
            .where('treeId', isEqualTo: treeId)
            .where('person1Id', isEqualTo: parentId)
            .where('person2Id', isEqualTo: newSiblingId)
            .where('relation1to2', isEqualTo: 'parent')
            .limit(1)
            .get();
        print(
          'Check ParentSibling: Found ${existingRelationQuery.docs.length} existing parent relations for $parentId -> $newSiblingId.',
        );

        if (existingRelationQuery.docs.isEmpty) {
          print(
            'Check ParentSibling: Creating parent relation between $parentId and $newSiblingId...',
          );
          await createRelation(
            treeId: treeId,
            person1Id: parentId,
            person2Id: newSiblingId,
            relation1to2: RelationType.parent,
            isConfirmed: true,
          );
          print(
            'Check ParentSibling: Parent/child relation created between $parentId and $newSiblingId.',
          );
        } else {
          print(
            'Check ParentSibling: Parent/child relation already exists between $parentId and $newSiblingId.',
          );
        }
      }
    } catch (e, s) {
      // Добавляем StackTrace
      print('Check ParentSibling: Error: $e\n$s');
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'CheckParentSiblingRelationsError',
      );
    }
    print('Check ParentSibling: End for new sibling $newSiblingId');
  }
  // <<< КОНЕЦ: АВТОМАТИЧЕСКОЕ СОЗДАНИЕ СВЯЗЕЙ РОДИТЕЛЬ-СИБЛИНГ >>>

  // --- НОВЫЕ STREAM МЕТОДЫ ---

  /// Возвращает поток списка родственников для указанного дерева.
  Stream<List<FamilyPerson>> getRelativesStream(String treeId) {
    print(
      '[Stream] Запрос родственников для дерева $treeId из корневой коллекции family_persons',
    );
    return _firestore
        // Запрашиваем из КОРНЕВОЙ коллекции
        .collection('family_persons')
        // Фильтруем по ID дерева
        .where('treeId', isEqualTo: treeId)
        .snapshots()
        .map((snapshot) {
      print(
        '[Stream] Получено ${snapshot.docs.length} документов родственников для дерева $treeId',
      );
      try {
        // Явно указываем тип при маппинге
        final relatives = snapshot.docs
            .map<FamilyPerson>((doc) => FamilyPerson.fromFirestore(doc))
            .toList();
        print(
          '[Stream] Успешно смаплено ${relatives.length} родственников',
        );
        return relatives;
      } catch (e, s) {
        print('[Stream] Ошибка маппинга родственников: $e');
        print(s); // Печатаем стек для отладки
        FirebaseCrashlytics.instance.recordError(
          e,
          s,
          reason: 'RelativesStreamMappingError',
        );
        return <FamilyPerson>[]; // Возвращаем пустой список при ошибке маппинга
      }
    }).handleError((error, stackTrace) {
      print('[Stream] Ошибка в потоке родственников: $error');
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        reason: 'RelativesStreamError',
      );
      // Возвращаем пустой список при ошибке самого потока
      return <FamilyPerson>[];
    });
  }

  /// Возвращает поток списка связей для указанного дерева.
  Stream<List<FamilyRelation>> getRelationsStream(String treeId) {
    print(
      '[Stream] Запрос связей для дерева $treeId из корневой коллекции family_relations',
    );
    return _firestore
        // Запрашиваем из КОРНЕВОЙ коллекции
        .collection('family_relations')
        // Фильтруем по ID дерева
        .where('treeId', isEqualTo: treeId)
        .snapshots()
        .map((snapshot) {
      print(
        '[Stream] Получено ${snapshot.docs.length} документов связей для дерева $treeId',
      );
      try {
        // Явно указываем тип при маппинге
        final relations = snapshot.docs
            .map<FamilyRelation>((doc) => FamilyRelation.fromFirestore(doc))
            .toList();
        print('[Stream] Успешно смаплено ${relations.length} связей');
        return relations;
      } catch (e, s) {
        print('[Stream] Ошибка маппинга связей: $e');
        print(s); // Печатаем стек для отладки
        FirebaseCrashlytics.instance.recordError(
          e,
          s,
          reason: 'RelationsStreamMappingError',
        );
        return <FamilyRelation>[]; // Возвращаем пустой список при ошибке маппинга
      }
    }).handleError((error, stackTrace) {
      print('[Stream] Ошибка в потоке связей: $error');
      FirebaseCrashlytics.instance.recordError(
        error,
        stackTrace,
        reason: 'RelationsStreamError',
      );
      // Возвращаем пустой список при ошибке самого потока
      return <FamilyRelation>[];
    });
  }

  // --- НОВЫЕ STREAM МЕТОДЫ ---

  /// Получает список оффлайн-профилей (FamilyPerson), созданных указанным
  /// пользователем (creatorId) в указанном дереве (treeId).
  /// Оффлайн-профили идентифицируются по отсутствию `userId`.
  Future<List<FamilyPerson>> getOfflineProfilesByCreator(
    String treeId,
    String creatorId,
  ) async {
    try {
      print(
        'FamilyService: Запрос оффлайн профилей для дерева $treeId, созданных $creatorId',
      );

      // Ищем в корневой коллекции family_persons
      final snapshot = await _firestore
          .collection('family_persons')
          .where('treeId', isEqualTo: treeId) // Фильтр по дереву
          .where('creatorId', isEqualTo: creatorId) // Фильтр по создателю
          // Фильтр для оффлайн-профилей: userId отсутствует или null.
          // Firestore не поддерживает прямой запрос на отсутствие поля или null в '!=' или 'not-in'.
          // Поэтому загружаем всех, созданных пользователем в этом дереве, и фильтруем локально.
          // Если бы оффлайн-профили имели специальный флаг (напр., isOffline: true), запрос был бы эффективнее.
          .get();

      final persons = snapshot.docs
          .map((doc) => FamilyPerson.fromFirestore(doc))
          .where(
            (person) => person.userId == null || person.userId!.isEmpty,
          ) // Локальная фильтрация
          .toList();

      print('FamilyService: Найдено ${persons.length} оффлайн профилей.');
      return persons;
    } catch (e, s) {
      // Изменяем вывод ошибки и стектрейса
      print('Ошибка получения оффлайн профилей: $e');
      print('Стек вызовов: $s');
      // Можно добавить логирование в AnalyticsService
      // GetIt.I<AnalyticsService>().logError('GetOfflineProfilesError', e.toString(), s);
      throw Exception('Не удалось загрузить список профилей.');
    }
  }

  /// Получает конкретного человека по его ID из корневой коллекции.
  Future<FamilyPerson> getPersonById(String treeId, String personId) async {
    print('FamilyService: Запрос данных для person $personId в дереве $treeId');
    try {
      final docSnapshot =
          await _firestore.collection('family_persons').doc(personId).get();

      if (docSnapshot.exists) {
        // Проверяем, принадлежит ли человек к запрашиваемому дереву
        final person = FamilyPerson.fromFirestore(docSnapshot);
        if (person.treeId == treeId) {
          print('FamilyService: Человек $personId найден.');
          return person;
        } else {
          print(
            'FamilyService: Ошибка - Человек $personId найден, но принадлежит другому дереву (${person.treeId}).',
          );
          // Возможно, стоит бросить специфическую ошибку?
          throw Exception(
            'Человек найден, но не принадлежит к указанному дереву.',
          );
        }
      } else {
        print('FamilyService: Ошибка - Человек с ID $personId не найден.');
        throw Exception('Человек не найден.');
      }
    } catch (e, s) {
      print('Ошибка при получении Person по ID: $e');
      print(s);
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'GetPersonByIdError',
      );
      throw Exception('Не удалось получить данные человека.');
    }
  }

  // Получение одного человека по ID
  Future<FamilyPerson?> getFamilyPerson(String personId) async {
    try {
      // 1. Пробуем из кэша
      final cachedPerson = await _localStorageService.getPerson(personId);
      if (cachedPerson != null) {
        print('FamilyPerson $personId found in cache.');
        return cachedPerson;
      }

      // 2. Проверяем сеть
      if (!_syncService.isOnline) {
        print(
          'FamilyPerson $personId not in cache and offline. Returning null.',
        );
        return null;
      }

      // 3. Загружаем из Firestore
      print('FamilyPerson $personId not in cache, fetching from Firestore...');
      final doc =
          await _firestore.collection('family_persons').doc(personId).get();

      if (doc.exists) {
        final personFromFirestore = FamilyPerson.fromFirestore(doc);
        // 4. Сохраняем в кэш
        await _localStorageService.savePerson(personFromFirestore);
        print(
          'FamilyPerson $personId fetched from Firestore and saved to cache.',
        );
        return personFromFirestore;
      } else {
        print('FamilyPerson $personId not found in Firestore.');
        return null;
      }
    } catch (e) {
      print('Error getting family person $personId: $e');
      // Попробуем вернуть из кэша в случае ошибки
      try {
        final cachedPerson = await _localStorageService.getPerson(personId);
        if (cachedPerson != null) {
          print('Returning cached person $personId after Firestore error.');
          return cachedPerson;
        }
      } catch (cacheError) {
        print('Error reading person cache after Firestore error: $cacheError');
      }
      return null;
    }
  }

  // Получение всех людей в указанном дереве
  Future<List<FamilyPerson>> getFamilyPersonsByTreeId(String treeId) async {
    try {
      // 1. Пробуем из кэша
      final cachedPersons = await _localStorageService.getPersonsByTreeId(
        treeId,
      );
      // Если кэш не пуст, возвращаем его (даже если оффлайн)
      if (cachedPersons.isNotEmpty) {
        print(
          'Found ${cachedPersons.length} persons for tree $treeId in cache.',
        );
        // Опционально: Если онлайн, можно в фоне запустить проверку обновлений из Firestore
        // if (_syncService.isOnline) { _checkForUpdatesAndRefreshCache(treeId); }
        return cachedPersons;
      }

      // 2. Если кэш пуст, проверяем сеть
      if (!_syncService.isOnline) {
        print(
          'Persons for tree $treeId not in cache and offline. Returning empty list.',
        );
        return []; // Кэш пуст и нет сети
      }

      // 3. Если есть сеть и кэш пуст, загружаем из Firestore
      print(
        'Persons for tree $treeId not in cache, fetching from Firestore...',
      );
      final personsQuery = await _firestore
          .collection('family_persons')
          .where('treeId', isEqualTo: treeId)
          .get();

      final personsFromFirestore = personsQuery.docs
          .map((doc) => FamilyPerson.fromFirestore(doc))
          .toList();

      // 4. Сохраняем в кэш (даже если список пуст, чтобы пометить, что мы проверили Firestore)
      await _localStorageService.savePersons(personsFromFirestore);
      print(
        'Fetched ${personsFromFirestore.length} persons for tree $treeId from Firestore and saved to cache.',
      );
      return personsFromFirestore;
    } catch (e) {
      print('Error getting family persons for tree $treeId: $e');
      // Попробуем вернуть из кэша в случае ошибки
      try {
        final cachedPersons = await _localStorageService.getPersonsByTreeId(
          treeId,
        );
        print(
          'Returning ${cachedPersons.length} cached persons for tree $treeId after Firestore error.',
        );
        return cachedPersons; // Возвращаем то, что есть в кэше (может быть пустым)
      } catch (cacheError) {
        print(
          'Error reading persons cache for tree $treeId after Firestore error: $cacheError',
        );
        return []; // Возвращаем пустой список в случае двойной ошибки
      }
    }
  }

  // <<< НАЧАЛО: ПОИСК СУПРУГА >>>
  /// Находит ID супруга для указанного человека в дереве.
  /// Возвращает null, если супруг не найден.
  Future<String?> findSpouseId(String treeId, String personId) async {
    print('Finding spouse for person $personId in tree $treeId...');
    try {
      // Ищем связь, где personId - первый участник и тип - spouse
      final query1 = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person1Id', isEqualTo: personId)
          .where(
            'relation1to2',
            isEqualTo: FamilyRelation.relationTypeToString(RelationType.spouse),
          )
          .limit(1)
          .get();

      if (query1.docs.isNotEmpty) {
        final spouseId = query1.docs.first.data()['person2Id'] as String?;
        print('Spouse found (query1): $spouseId');
        return spouseId;
      }

      // Ищем связь, где personId - второй участник и тип - spouse
      final query2 = await _firestore
          .collection('family_relations')
          .where('treeId', isEqualTo: treeId)
          .where('person2Id', isEqualTo: personId)
          // Используем relation2to1, т.к. spouse симметричен, но для единообразия проверим и это
          // Хотя достаточно было бы проверить relation1to2 == spouse в обоих запросах
          .where(
            'relation1to2',
            isEqualTo: FamilyRelation.relationTypeToString(RelationType.spouse),
          )
          .limit(1)
          .get();

      if (query2.docs.isNotEmpty) {
        final spouseId = query2.docs.first.data()['person1Id'] as String?;
        print('Spouse found (query2): $spouseId');
        return spouseId;
      }

      print('Spouse not found for person $personId.');
      return null;
    } catch (e, s) {
      print('Error finding spouse for person $personId: $e\n$s');
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'FindSpouseIdError',
      );
      return null; // В случае ошибки возвращаем null
    }
  }
  // <<< КОНЕЦ: ПОИСК СУПРУГА >>>

  // <<< НАЧАЛО: СВЯЗЫВАНИЕ ПРИГЛАШЕННОГО ПОЛЬЗОВАТЕЛЯ >>>
  /// Связывает реального пользователя (userId) с существующим профилем (personId) в дереве.
  Future<void> linkInvitedUser(
    String treeId,
    String personId,
    String userId,
  ) async {
    print('Linking user $userId to person $personId in tree $treeId...');
    try {
      // Получаем ссылку на документ FamilyPerson в КОРНЕВОЙ коллекции
      final personDocRef =
          _firestore.collection('family_persons').doc(personId);

      // Проверяем, что документ принадлежит нужному дереву (дополнительная проверка)
      final personDoc = await personDocRef.get();
      if (!personDoc.exists || personDoc.data()?['treeId'] != treeId) {
        print(
          'Error linking: Person $personId not found or does not belong to tree $treeId.',
        );
        // Можно выбросить исключение или просто завершить
        // throw Exception('Person not found in the specified tree.');
        return;
      }

      // Проверяем, не связан ли профиль уже с другим пользователем
      final existingUserId = personDoc.data()?['userId'] as String?;
      if (existingUserId != null &&
          existingUserId.isNotEmpty &&
          existingUserId != userId) {
        print(
          'Warning: Person $personId is already linked to a different user ($existingUserId). Cannot link to $userId.',
        );
        // Возможно, стоит показать ошибку пользователю
        // throw Exception('Этот профиль уже связан с другим пользователем.');
        return;
      }
      // Проверяем, не совпадает ли ID пользователя с уже существующим ID
      if (existingUserId == userId) {
        print(
          'Info: Person $personId is already linked to this user ($userId). No update needed.',
        );
        return;
      }

      // Обновляем поле userId в документе FamilyPerson
      await personDocRef.update({
        'userId': userId,
        'updatedAt': Timestamp.now(), // Обновляем дату изменения
      });

      print('Successfully linked user $userId to person $personId.');

      // --- NEW: Добавляем дерево в список доступных для пользователя ---
      print('Adding tree $treeId to accessible trees for user $userId');
      try {
        final userProfileRef = _firestore.collection('users').doc(userId);
        // Используем set с merge: true, чтобы создать поле, если его нет
        await userProfileRef.set({
          // Предполагаем, что поле называется accessibleTreeIds
          // Используем arrayUnion для безопасного добавления без дубликатов
          'accessibleTreeIds': FieldValue.arrayUnion([treeId]),
        }, SetOptions(merge: true)); // <-- Добавляем SetOptions
        print('Successfully added tree $treeId to user $userId profile.');

        // --- NEW: Инвалидируем локальный кеш профиля пользователя ---
        try {
          // Предполагаем, что LocalStorageService доступен как _localStorageService
          await _localStorageService.deleteUser(userId);
          print('Invalidated local cache for user $userId.');
        } catch (cacheError) {
          print('Error invalidating user cache for $userId: $cacheError');
          // Логируем, но не считаем критической ошибкой
          FirebaseCrashlytics.instance.recordError(
            cacheError,
            StackTrace.current,
            reason: 'InvalidateUserCacheError',
          );
        }
        // --- END NEW ---
      } catch (profileUpdateError) {
        print(
          'Error updating user profile ($userId) with tree $treeId: $profileUpdateError',
        );
        // Логируем ошибку, но не прерываем процесс, т.к. основное связывание прошло
        FirebaseCrashlytics.instance.recordError(
          profileUpdateError,
          StackTrace.current,
          reason: 'UpdateAccessibleTreesError',
        );
      }
      // --- END NEW ---
    } catch (e, s) {
      print('Error linking user $userId to person $personId: $e\n$s');
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'LinkInvitedUserError',
      );
      // Возможно, стоит передать ошибку выше
      // throw Exception('Failed to link user: $e');
    }
  }
  // <<< КОНЕЦ: СВЯЗЫВАНИЕ ПРИГЛАШЕННОГО ПОЛЬЗОВАТЕЛЯ >>>

  // <<< НОВЫЙ МЕТОД: Проверка, есть ли текущий пользователь в дереве >>>
  Future<bool> isCurrentUserInTree(String treeId) async {
    final user = _auth.currentUser;
    if (user == null)
      return false; // Неавторизованный пользователь не может быть в дереве

    try {
      // Сначала ищем в локальном кэше
      final relatives = await _localStorageService.getPersonsByTreeId(treeId);
      // <<< ИСПРАВЛЕНИЕ: Ищем конкретного человека по userId >>>
      final cachedPerson = relatives.firstWhere(
        (person) => person.userId == user.uid,
        orElse: () => FamilyPerson.empty,
      ); // Используем пустой объект, если не найден
      final bool foundLocally = cachedPerson.id !=
          FamilyPerson.empty.id; // Проверяем, нашелся ли реальный объект

      if (foundLocally) {
        print(
          'Текущий пользователь ${user.uid} (Person ID: ${cachedPerson.id}) найден локально в дереве $treeId.',
        );
        // Не возвращаем true сразу, сначала проверим Firestore, если онлайн
      }

      // Если не нашли локально и есть сеть, проверяем Firestore
      if (_syncService.isOnline) {
        print(
          'Проверяем Firestore для пользователя ${user.uid} в дереве $treeId...',
        );
        final querySnapshot = await _firestore
            .collection('family_persons')
            .where('treeId', isEqualTo: treeId)
            .where('userId', isEqualTo: user.uid)
            .limit(1) // Достаточно одного совпадения
            .get();
        final foundInFirestore = querySnapshot.docs.isNotEmpty;
        if (foundInFirestore) {
          print(
            'Текущий пользователь ${user.uid} найден в Firestore в дереве $treeId.',
          );
          // Опционально: можно сохранить найденную персону в кэш для консистентности
          // final person = FamilyPerson.fromFirestore(querySnapshot.docs.first);
          // await _localStorageService.savePerson(person);
        } else {
          print(
            'Текущий пользователь ${user.uid} НЕ найден в Firestore в дереве $treeId.',
          );
          // <<< НОВОЕ: Очистка кэша, если Firestore и кэш расходятся >>>
          if (foundLocally) {
            print(
              'Несоответствие Firestore и кэша! Удаляем устаревшую запись ${cachedPerson.id} из кэша...',
            );
            try {
              await _localStorageService.deleteRelative(cachedPerson.id);
            } catch (e) {
              print(
                'Ошибка при удалении устаревшей записи ${cachedPerson.id} из кэша: $e',
              );
              // Не критично, продолжаем
            }
          }
          // <<< КОНЕЦ ОЧИСТКИ КЭША >>>
        }
        return foundInFirestore;
      } else {
        // Если сети нет, возвращаем результат локального поиска
        print(
          'Сети нет. Результат проверки наличия пользователя ${user.uid} в дереве $treeId (локально): $foundLocally',
        );
        return foundLocally;
      }
    } catch (e, s) {
      print('Ошибка при проверке наличия пользователя $treeId: $e\\n$s');
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'isCurrentUserInTreeCheckFailed',
      );
      return false; // В случае ошибки считаем, что пользователя нет
    }
  }

  // <<< НОВЫЙ МЕТОД: Добавление текущего пользователя в дерево со связью >>>
  Future<void> addCurrentUserToTree({
    required String treeId,
    required String targetPersonId, // ID человека, к которому привязываемся
    required RelationType
        relationType, // Тип связи ОТ targetPerson К текущему пользователю
  }) async {
    final currentUser = _auth.currentUser;
    if (currentUser == null) {
      throw Exception('Пользователь не авторизован');
    }
    // <<< ИСПРАВЛЕНИЕ: Объявляем now один раз в начале >>>
    final now = DateTime.now();

    // 1. Проверяем, не добавлен ли пользователь уже
    if (await isCurrentUserInTree(treeId)) {
      print(
        'Пользователь ${currentUser.uid} уже добавлен в дерево $treeId. Добавление отменено.',
      );
      // Можно выбросить исключение или просто выйти
      // throw Exception('Пользователь уже добавлен в это дерево');
      return;
    }

    // 2. Получаем профиль текущего пользователя
    // <<< ИСПРАВЛЕНИЕ: Убираем вызов AuthService, получаем профиль здесь >>>
    // final authService = GetIt.I<AuthService>(); // Получаем AuthService через GetIt
    // UserProfile? userProfile = await authService.getUserProfile(currentUser.uid);
    UserProfile? userProfile;
    try {
      userProfile = await _localStorageService.getUser(currentUser.uid);
      if (userProfile == null && _syncService.isOnline) {
        print(
          'Профиль ${currentUser.uid} не найден локально, ищем в Firestore...',
        );
        final userDoc =
            await _firestore.collection('users').doc(currentUser.uid).get();
        if (userDoc.exists) {
          userProfile = UserProfile.fromFirestore(userDoc);
          await _localStorageService.saveUser(userProfile); // Сохраняем в кеш
        } else {
          print('Профиль ${currentUser.uid} не найден и в Firestore.');
        }
      }
    } catch (e, s) {
      print(
        'Ошибка при получении профиля пользователя ${currentUser.uid}: $e\\n$s',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'getUserProfileInAddCurrentUserFailed',
      );
      // Не прерываем, так как можем создать базовый профиль ниже
    }

    if (userProfile == null) {
      // Если профиль не найден (маловероятно, но возможно), создаем базовую запись
      print(
        'Профиль для ${currentUser.uid} не найден. Создается базовая запись UserProfile.',
      );
      userProfile = UserProfile(
        id: currentUser.uid,
        email: currentUser.email ?? '', // Берем из Auth, если есть
        // Заполняем минимально необходимым, остальное - null
        firstName: currentUser.displayName?.split(' ').first ??
            'Пользователь', // Имя из Auth или плейсхолдер
        // <<< ИСПРАВЛЕНИЕ: Добавляем скобки для правильного порядка операций >>>
        lastName: (currentUser.displayName?.split(' ').length ?? 0) > 1
            ? currentUser.displayName!.split(' ').sublist(1).join(' ')
            : '',
        username: currentUser.uid, // Используем UID как временный username
        gender: Gender.unknown, // Неизвестный пол по умолчанию
        // Остальные поля null или значения по умолчанию
        updatedAt: now, // Используем now для updatedAt
        // Остальные поля (bio, place и т.д.) можно добавить, если они есть в UserProfile
        // <<< ИСПРАВЛЕНИЕ: Убираем bio >>>
        // bio: userProfile.bio, // Оставляем bio, но если будут ошибки компиляции, значит его нет в модели
        phoneNumber: '', // Добавляем пустой номер телефона
        createdAt: now,
      );
    }

    // 3. Создаем объект FamilyPerson для текущего пользователя
    // <<< ИСПРАВЛЕНИЕ: Убираем повторное объявление now >>>
    // final personId = Uuid().v4(); // Генерируем новый ID для FamilyPerson
    // final now = DateTime.now();
    final personId = Uuid().v4();

    final selfPerson = FamilyPerson(
      id: personId,
      treeId: treeId,
      userId: currentUser.uid, // Связываем с ID пользователя
      // <<< ИСПРАВЛЕНИЕ: Используем firstName/lastName/displayName вместо name >>>
      name: (userProfile.firstName != null || userProfile.lastName != null)
          ? '${userProfile.firstName ?? ''} ${userProfile.lastName ?? ''}'
              .trim()
          : currentUser.displayName ?? 'Имя неизвестно',
      // Используем данные из профиля, если они есть
      gender: userProfile.gender ?? Gender.unknown,
      birthDate: userProfile.birthDate,
      // Остальные поля можно взять из userProfile, если они там есть
      // <<< ИСПРАВЛЕНИЕ: Используем photoURL вместо photoUrl >>>
      photoUrl: userProfile.photoURL ??
          currentUser.photoURL, // Фото из профиля или Auth
      isAlive: true, // Предполагаем, что пользователь жив
      creatorId: currentUser.uid, // Создатель - сам пользователь
      createdAt: now, // Используем now для createdAt
      updatedAt: now, // Используем now для updatedAt
      // Остальные поля (bio, place и т.д.) можно добавить, если они есть в UserProfile
      // <<< ИСПРАВЛЕНИЕ: Проверяем bio, если есть в UserProfile, иначе null >>>
      // bio: userProfile.bio, // Оставляем bio, но если будут ошибки компиляции, значит его нет в модели
    );

    // 4. Сохраняем новую FamilyPerson (локально и в Firestore, если онлайн)
    try {
      await _localStorageService.savePerson(selfPerson);
      print(
        'FamilyPerson для текущего пользователя ${selfPerson.id} сохранена локально.',
      );
      if (_syncService.isOnline) {
        print('Отправляем FamilyPerson ${selfPerson.id} в Firestore...');
        await _firestore
            .collection('family_persons')
            .doc(selfPerson.id)
            .set(selfPerson.toMap());
        print('FamilyPerson ${selfPerson.id} успешно добавлена в Firestore.');
      } else {
        print(
          'Сети нет. FamilyPerson ${selfPerson.id} сохранена только локально.',
        );
        // TODO: Отложенная синхронизация
      }
    } catch (e, s) {
      print(
        'Ошибка при сохранении FamilyPerson для текущего пользователя: $e\\n$s',
      );
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'addCurrentUserSavePersonFailed',
      );
      throw Exception(
        'Не удалось сохранить данные пользователя в дереве',
      ); // Прерываем операцию
    }

    // 5. Создаем связь между targetPersonId и новым selfPerson.id
    try {
      // Определяем обратную связь
      final RelationType reverseRelationType = FamilyRelation.getMirrorRelation(
        relationType,
      );

      print(
        'Создание связи: $targetPersonId -> ${selfPerson.id} ($relationType) / ${selfPerson.id} -> $targetPersonId ($reverseRelationType)',
      );

      await createRelation(
        treeId: treeId,
        person1Id: targetPersonId,
        person2Id: selfPerson.id,
        relation1to2: relationType,
        isConfirmed: true, // Связь подтверждена, т.к. создается пользователем
      );
      print('Связь успешно создана.');

      // Опционально: После добавления себя как ребенка, можно попробовать создать связь между родителями
      if (relationType == RelationType.child) {
        // Нужно найти другого родителя targetPersonId и создать связь spouse
        // Эта логика сложнее и требует поиска второго родителя, пока пропустим
        // await _createSpouseRelationForParentsIfNeeded(treeId, targetPersonId, selfPerson.id);
      }
    } catch (e, s) {
      print('Ошибка при создании связи для текущего пользователя: $e\\n$s');
      FirebaseCrashlytics.instance.recordError(
        e,
        s,
        reason: 'addCurrentUserCreateRelationFailed',
      );
      // ВАЖНО: Если связь не создалась, нужно ли откатывать добавление FamilyPerson?
      // Пока оставим FamilyPerson добавленной, но без связи.
      // Можно добавить логику удаления selfPerson в catch блоке.
      throw Exception('Не удалось создать родственную связь');
    }
  }

  Future<void> _acceptLegacyOfflineReplacementRequest({
    required DocumentSnapshot requestDoc,
    required Map<String, dynamic> requestData,
    required String currentUserId,
  }) async {
    final offlineRelativeId = requestData['offlineRelativeId'] as String;
    final treeId = requestData['treeId'] as String;
    final senderId = requestData['senderId'] as String;
    final relationType = _normalizeRelationTypeValue(
      requestData['relationType'] ?? requestData['senderToRecipient'],
    );

    final offlineRelativeDoc = await _firestore
        .collection('family_trees')
        .doc(treeId)
        .collection('relatives')
        .doc(offlineRelativeId)
        .get();

    if (!offlineRelativeDoc.exists) {
      throw Exception('Офлайн родственник не найден');
    }

    final currentUserDoc =
        await _firestore.collection('users').doc(currentUserId).get();
    if (!currentUserDoc.exists) {
      throw Exception('Данные пользователя не найдены');
    }

    final userData = currentUserDoc.data()!;
    final newRelative = FamilyPerson(
      id: currentUserId,
      treeId: treeId,
      userId: currentUserId,
      name: userData['displayName'] ?? 'Без имени',
      gender: FamilyPerson.genderFromString(userData['gender']),
      birthDate: userData['birthDate'] != null
          ? (userData['birthDate'] as Timestamp).toDate()
          : null,
      isAlive: true,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final relationsQuery = await _firestore
        .collection('family_relations')
        .where('treeId', isEqualTo: treeId)
        .get();

    final newRelations = <Map<String, dynamic>>[];
    final relationsToDelete = <String>[];

    for (final relationDoc in relationsQuery.docs) {
      final relationData = Map<String, dynamic>.from(relationDoc.data());
      var needsUpdate = false;

      if (relationData['person1Id'] == offlineRelativeId) {
        relationData['person1Id'] = currentUserId;
        needsUpdate = true;
      }

      if (relationData['person2Id'] == offlineRelativeId) {
        relationData['person2Id'] = currentUserId;
        needsUpdate = true;
      }

      if (needsUpdate) {
        newRelations.add(relationData);
        relationsToDelete.add(relationDoc.id);
      }
    }

    await _firestore.runTransaction((transaction) async {
      transaction.set(
        _firestore
            .collection('family_trees')
            .doc(treeId)
            .collection('relatives')
            .doc(currentUserId),
        newRelative.toMap(),
      );

      for (var i = 0; i < relationsToDelete.length; i++) {
        transaction.delete(
          _firestore.collection('family_relations').doc(relationsToDelete[i]),
        );
        transaction.set(
          _firestore.collection('family_relations').doc(),
          newRelations[i],
        );
      }

      transaction.delete(
        _firestore
            .collection('family_trees')
            .doc(treeId)
            .collection('relatives')
            .doc(offlineRelativeId),
      );

      transaction.set(_firestore.collection('family_relations').doc(), {
        'treeId': treeId,
        'person1Id': senderId,
        'person2Id': currentUserId,
        'relation1to2': relationType,
        'relation2to1': _inverseRelationType(relationType),
        'createdAt': FieldValue.serverTimestamp(),
      });

      transaction.update(requestDoc.reference, {
        'status': 'accepted',
        'respondedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  String _normalizeRelationTypeValue(dynamic rawValue) {
    return rawValue?.toString().split('.').last ?? 'other';
  }

  String _inverseRelationType(String relation) {
    switch (relation) {
      case 'parent':
        return 'child';
      case 'child':
        return 'parent';
      case 'spouse':
        return 'spouse';
      case 'sibling':
        return 'sibling';
      default:
        return 'other';
    }
  }
}
