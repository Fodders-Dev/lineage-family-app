import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lineage/backend/backend_runtime_config.dart';
import 'package:lineage/models/family_relation.dart';
import 'package:lineage/models/relation_request.dart';
import 'package:lineage/services/custom_api_auth_service.dart';
import 'package:lineage/services/custom_api_family_tree_service.dart';
import 'package:lineage/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiFamilyTreeService covers tree CRUD and direct relations',
      () async {
    final trees = <Map<String, dynamic>>[];
    final persons = <Map<String, dynamic>>[];
    final relations = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees' && request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['name'], 'Семья Петровых');

        final tree = <String, dynamic>{
          'id': 'tree-1',
          'name': body['name'],
          'description': body['description'],
          'creatorId': 'user-1',
          'memberIds': ['user-1'],
          'members': ['user-1'],
          'createdAt': '2026-03-27T10:00:00.000Z',
          'updatedAt': '2026-03-27T10:00:00.000Z',
          'isPrivate': body['isPrivate'],
        };
        trees
          ..clear()
          ..add(tree);
        persons
          ..clear()
          ..add({
            'id': 'person-self',
            'treeId': 'tree-1',
            'userId': 'user-1',
            'name': 'Петров Иван',
            'gender': 'male',
            'isAlive': true,
            'creatorId': 'user-1',
            'createdAt': '2026-03-27T10:00:00.000Z',
            'updatedAt': '2026-03-27T10:00:00.000Z',
          });

        return http.Response(
          jsonEncode({'tree': tree}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees' && request.method == 'GET') {
        return http.Response(
          jsonEncode({'trees': trees}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/selectable' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'trees': trees
                .map((tree) => {
                      'id': tree['id'],
                      'name': tree['name'],
                      'createdAt': tree['createdAt'],
                    })
                .toList(),
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'persons': persons}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/persons' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final person = <String, dynamic>{
          'id': 'person-child',
          'treeId': 'tree-1',
          'userId': body['userId'],
          'name': '${body['lastName']} ${body['firstName']}'.trim(),
          'gender': body['gender'],
          'isAlive': true,
          'creatorId': 'user-1',
          'createdAt': '2026-03-27T10:05:00.000Z',
          'updatedAt': '2026-03-27T10:05:00.000Z',
        };
        persons.add(person);
        return http.Response(
          jsonEncode({'person': person}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/persons/person-child' &&
          request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final personIndex =
            persons.indexWhere((person) => person['id'] == 'person-child');
        persons[personIndex] = {
          ...persons[personIndex],
          'name': '${body['lastName']} ${body['firstName']}'.trim(),
          'notes': body['notes'],
          'updatedAt': '2026-03-27T10:10:00.000Z',
        };

        return http.Response(
          jsonEncode({'person': persons[personIndex]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/persons/person-child' &&
          request.method == 'GET') {
        final person =
            persons.firstWhere((entry) => entry['id'] == 'person-child');
        return http.Response(
          jsonEncode({'person': person}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/persons/person-child' &&
          request.method == 'DELETE') {
        persons.removeWhere((entry) => entry['id'] == 'person-child');
        relations.removeWhere((entry) =>
            entry['person1Id'] == 'person-child' ||
            entry['person2Id'] == 'person-child');
        return http.Response('', 204);
      }

      if (request.url.path == '/v1/trees/tree-1/relations' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'relations': relations}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/relations' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final relation = <String, dynamic>{
          'id': 'relation-1',
          'treeId': 'tree-1',
          'person1Id': body['person1Id'],
          'person2Id': body['person2Id'],
          'relation1to2': body['relation1to2'],
          'relation2to1': body['relation2to1'],
          'isConfirmed': body['isConfirmed'],
          'createdAt': '2026-03-27T10:06:00.000Z',
          'updatedAt': '2026-03-27T10:06:00.000Z',
          'createdBy': 'user-1',
        };
        relations
          ..clear()
          ..add(relation);

        return http.Response(
          jsonEncode({'relation': relation}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@lineage.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final treeService = CustomApiFamilyTreeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final treeId = await treeService.createTree(
      name: 'Семья Петровых',
      description: 'Тестовое дерево',
      isPrivate: true,
    );
    expect(treeId, 'tree-1');

    final availableTrees = await treeService.getUserTrees();
    expect(availableTrees, hasLength(1));
    expect(availableTrees.first.name, 'Семья Петровых');

    final selectableTrees =
        await treeService.getSelectableTreesForCurrentUser();
    expect(selectableTrees, hasLength(1));

    final initialRelatives = await treeService.getRelatives('tree-1');
    expect(initialRelatives, hasLength(1));
    expect(await treeService.isCurrentUserInTree('tree-1'), isTrue);

    final childPersonId = await treeService.addRelative('tree-1', {
      'firstName': 'Мария',
      'lastName': 'Петрова',
      'gender': 'female',
    });
    expect(childPersonId, 'person-child');

    await treeService.updateRelative('person-child', {
      'firstName': 'Мария',
      'lastName': 'Сидорова',
      'notes': 'Обновлено',
    });

    final childPerson =
        await treeService.getPersonById('tree-1', 'person-child');
    expect(childPerson.name, 'Сидорова Мария');

    final relation = await treeService.createRelation(
      treeId: 'tree-1',
      person1Id: 'user-1',
      person2Id: 'person-child',
      relation1to2: RelationType.parent,
      isConfirmed: true,
    );
    expect(relation.relation1to2, RelationType.parent);

    final relationToChild = await treeService.getRelationBetween(
      'tree-1',
      'user-1',
      'person-child',
    );
    expect(relationToChild, RelationType.parent);
    expect(
      await treeService.hasDirectRelation(
        treeId: 'tree-1',
        person1Id: 'user-1',
        person2Id: 'person-child',
      ),
      isTrue,
    );

    final offlineProfiles =
        await treeService.getOfflineProfilesByCreator('tree-1', 'user-1');
    expect(offlineProfiles, hasLength(1));
    expect(offlineProfiles.first.id, 'person-child');

    await treeService.deleteRelative('tree-1', 'person-child');
    final remainingRelatives = await treeService.getRelatives('tree-1');
    expect(remainingRelatives, hasLength(1));
  });

  test('CustomApiFamilyTreeService adds current user into existing tree',
      () async {
    final persons = <Map<String, dynamic>>[
      {
        'id': 'person-anchor',
        'treeId': 'tree-2',
        'userId': null,
        'name': 'Иван Иванов',
        'gender': 'male',
        'isAlive': true,
        'creatorId': 'owner-1',
        'createdAt': '2026-03-27T11:00:00.000Z',
        'updatedAt': '2026-03-27T11:00:00.000Z',
      },
    ];
    final relations = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-2/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'persons': persons}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-2/persons' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final selfPerson = <String, dynamic>{
          'id': 'person-self',
          'treeId': 'tree-2',
          'userId': body['userId'],
          'name': body['name'] ?? 'Dev User',
          'gender': body['gender'],
          'isAlive': true,
          'creatorId': 'user-1',
          'createdAt': '2026-03-27T11:05:00.000Z',
          'updatedAt': '2026-03-27T11:05:00.000Z',
        };
        persons.add(selfPerson);
        return http.Response(
          jsonEncode({'person': selfPerson}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-2/relations' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'relations': relations}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-2/relations' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        relations.add({
          'id': 'relation-join',
          'treeId': 'tree-2',
          'person1Id': body['person1Id'],
          'person2Id': body['person2Id'],
          'relation1to2': body['relation1to2'],
          'relation2to1': body['relation2to1'],
          'isConfirmed': true,
          'createdAt': '2026-03-27T11:06:00.000Z',
          'updatedAt': '2026-03-27T11:06:00.000Z',
          'createdBy': 'user-1',
        });
        return http.Response(
          jsonEncode({'relation': relations.first}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@lineage.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final treeService = CustomApiFamilyTreeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    expect(await treeService.isCurrentUserInTree('tree-2'), isFalse);

    await treeService.addCurrentUserToTree(
      treeId: 'tree-2',
      targetPersonId: 'person-anchor',
      relationType: RelationType.parent,
    );

    expect(await treeService.isCurrentUserInTree('tree-2'), isTrue);
    expect(relations, hasLength(1));
    expect(relations.first['person1Id'], 'person-anchor');
    expect(relations.first['relation1to2'], 'parent');
  });

  test(
      'CustomApiFamilyTreeService links a new sibling to parents instead of siblings children',
      () async {
    final persons = <Map<String, dynamic>>[
      {
        'id': 'parent-1',
        'treeId': 'tree-3',
        'userId': null,
        'name': 'Родитель Один',
        'gender': 'male',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T10:00:00.000Z',
        'updatedAt': '2026-03-27T10:00:00.000Z',
      },
      {
        'id': 'parent-2',
        'treeId': 'tree-3',
        'userId': null,
        'name': 'Родитель Два',
        'gender': 'female',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T10:00:00.000Z',
        'updatedAt': '2026-03-27T10:00:00.000Z',
      },
      {
        'id': 'existing-sibling',
        'treeId': 'tree-3',
        'userId': null,
        'name': 'Существующий Сиблинг',
        'gender': 'male',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T10:00:00.000Z',
        'updatedAt': '2026-03-27T10:00:00.000Z',
      },
      {
        'id': 'existing-child',
        'treeId': 'tree-3',
        'userId': null,
        'name': 'Ребёнок Сиблинга',
        'gender': 'female',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T10:00:00.000Z',
        'updatedAt': '2026-03-27T10:00:00.000Z',
      },
      {
        'id': 'new-sibling',
        'treeId': 'tree-3',
        'userId': null,
        'name': 'Новый Сиблинг',
        'gender': 'female',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T10:00:00.000Z',
        'updatedAt': '2026-03-27T10:00:00.000Z',
      },
    ];

    final relations = <Map<String, dynamic>>[
      {
        'id': 'relation-parent-1',
        'treeId': 'tree-3',
        'person1Id': 'parent-1',
        'person2Id': 'existing-sibling',
        'relation1to2': 'parent',
        'relation2to1': 'child',
        'isConfirmed': true,
        'createdAt': '2026-03-27T11:00:00.000Z',
        'updatedAt': '2026-03-27T11:00:00.000Z',
        'createdBy': 'user-1',
      },
      {
        'id': 'relation-parent-2',
        'treeId': 'tree-3',
        'person1Id': 'parent-2',
        'person2Id': 'existing-sibling',
        'relation1to2': 'parent',
        'relation2to1': 'child',
        'isConfirmed': true,
        'createdAt': '2026-03-27T11:00:00.000Z',
        'updatedAt': '2026-03-27T11:00:00.000Z',
        'createdBy': 'user-1',
      },
      {
        'id': 'relation-child',
        'treeId': 'tree-3',
        'person1Id': 'existing-sibling',
        'person2Id': 'existing-child',
        'relation1to2': 'parent',
        'relation2to1': 'child',
        'isConfirmed': true,
        'createdAt': '2026-03-27T11:05:00.000Z',
        'updatedAt': '2026-03-27T11:05:00.000Z',
        'createdBy': 'user-1',
      },
    ];

    final createdRelations = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-3/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'persons': persons}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-3/relations' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'relations': [...relations, ...createdRelations]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-3/relations' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final relation = <String, dynamic>{
          'id': 'relation-created-${createdRelations.length + 1}',
          'treeId': 'tree-3',
          'person1Id': body['person1Id'],
          'person2Id': body['person2Id'],
          'relation1to2': body['relation1to2'],
          'relation2to1': body['relation2to1'],
          'isConfirmed': body['isConfirmed'],
          'createdAt': '2026-03-27T11:10:00.000Z',
          'updatedAt': '2026-03-27T11:10:00.000Z',
          'createdBy': 'user-1',
        };
        createdRelations.add(relation);
        return http.Response(
          jsonEncode({'relation': relation}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@lineage.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final treeService = CustomApiFamilyTreeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await treeService.checkAndCreateParentSiblingRelations(
      'tree-3',
      'existing-sibling',
      'new-sibling',
    );

    expect(createdRelations, hasLength(2));
    expect(
      createdRelations
          .where((relation) => relation['relation1to2'] == 'parent')
          .map((relation) => relation['person1Id'])
          .toSet(),
      equals({'parent-1', 'parent-2'}),
    );
    expect(
      createdRelations.every(
        (relation) => relation['person2Id'] == 'new-sibling',
      ),
      isTrue,
    );
  });

  test(
      'CustomApiFamilyTreeService covers relation requests and offline email flow',
      () async {
    final requests = <Map<String, dynamic>>[];
    final treeInvitations = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/relation-requests/pending' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'requests': requests}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/relation-requests' &&
          request.method == 'GET') {
        final senderId = request.url.queryParameters['senderId'];
        final recipientId = request.url.queryParameters['recipientId'];
        final status = request.url.queryParameters['status'];

        final filtered = requests.where((entry) {
          if (senderId != null && entry['senderId'] != senderId) {
            return false;
          }
          if (recipientId != null && entry['recipientId'] != recipientId) {
            return false;
          }
          if (status != null && entry['status'] != status) {
            return false;
          }
          return true;
        }).toList();

        return http.Response(
          jsonEncode({'requests': filtered}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/relation-requests' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final requestPayload = <String, dynamic>{
          'id': 'request-${requests.length + 1}',
          'treeId': 'tree-1',
          'senderId': 'user-1',
          'recipientId': body['recipientId'],
          'senderToRecipient': body['senderToRecipient'],
          'targetPersonId': body['targetPersonId'],
          'createdAt': '2026-03-27T12:00:00.000Z',
          'updatedAt': '2026-03-27T12:00:00.000Z',
          'respondedAt': null,
          'status': 'pending',
          'message': body['message'],
        };
        requests.add(requestPayload);
        return http.Response(
          jsonEncode({'request': requestPayload}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-1/invitations' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final invitationPayload = <String, dynamic>{
          'invitationId': 'invite-${treeInvitations.length + 1}',
          'treeId': 'tree-1',
          'invitedBy': 'user-1',
          'relationToTree': body['relationToTree'],
          'recipientUserId': body['recipientUserId'],
        };
        treeInvitations.add(invitationPayload);
        return http.Response(
          jsonEncode({'invitation': invitationPayload}),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/relation-requests/request-1/respond' &&
          request.method == 'POST') {
        requests[0] = {
          ...requests[0],
          'status': 'accepted',
          'respondedAt': '2026-03-27T12:10:00.000Z',
          'updatedAt': '2026-03-27T12:10:00.000Z',
        };
        return http.Response(
          jsonEncode({'request': requests[0]}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/users/search/by-field' &&
          request.method == 'GET') {
        expect(request.url.queryParameters['field'], 'email');
        expect(request.url.queryParameters['value'], 'invitee@lineage.app');
        return http.Response(
          jsonEncode({
            'users': [
              {
                'id': 'user-2',
                'displayName': 'Invitee',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@lineage.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final treeService = CustomApiFamilyTreeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    await treeService.sendTreeInvitation(
      treeId: 'tree-1',
      recipientUserId: 'user-2',
      relationToTree: 'родственник',
    );
    expect(treeInvitations, hasLength(1));
    expect(treeInvitations.single['recipientUserId'], 'user-2');

    await treeService.sendRelationRequest(
      treeId: 'tree-1',
      recipientId: 'user-2',
      relationType: RelationType.sibling,
      message: 'Подтверди родство',
    );

    expect(
      await treeService.hasPendingRelationRequest(
        treeId: 'tree-1',
        senderId: 'user-1',
        recipientId: 'user-2',
      ),
      isTrue,
    );

    final pendingRequests =
        await treeService.getPendingRelationRequests(treeId: 'tree-1');
    expect(pendingRequests, hasLength(1));
    expect(pendingRequests.first.senderToRecipient, RelationType.sibling);

    await treeService.respondToRelationRequest(
      requestId: 'request-1',
      response: RequestStatus.accepted,
    );
    expect(requests.first['status'], 'accepted');

    await treeService.sendOfflineRelationRequestByEmail(
      treeId: 'tree-1',
      email: 'invitee@lineage.app',
      offlineRelativeId: 'person-offline',
      relationType: RelationType.child,
    );
    expect(requests, hasLength(2));
    expect(requests.last['recipientId'], 'user-2');
    expect(requests.last['targetPersonId'], 'person-offline');
  });

  test('CustomApiFamilyTreeService loads and responds to tree invitations',
      () async {
    final invitations = <Map<String, dynamic>>[
      {
        'invitationId': 'invite-1',
        'treeId': 'tree-7',
        'invitedBy': 'owner-1',
        'tree': {
          'id': 'tree-7',
          'name': 'Семья Смирновых',
          'description': 'Приглашение в дерево',
          'creatorId': 'owner-1',
          'memberIds': ['owner-1'],
          'members': ['owner-1'],
          'createdAt': '2026-03-27T13:00:00.000Z',
          'updatedAt': '2026-03-27T13:00:00.000Z',
          'isPrivate': true,
        },
      },
    ];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/tree-invitations/pending' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'invitations': invitations}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/tree-invitations/invite-1/respond' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['accept'], true);
        invitations.clear();
        return http.Response(
          jsonEncode({'ok': true, 'accepted': true}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      return http.Response('{"message":"not found"}', 404);
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'custom_api_session_v1',
      jsonEncode({
        'accessToken': 'access-token',
        'refreshToken': 'refresh-token',
        'userId': 'user-1',
        'email': 'dev@lineage.app',
        'displayName': 'Dev User',
        'providerIds': ['password'],
        'isProfileComplete': true,
        'missingFields': const [],
      }),
    );

    final authService = await CustomApiAuthService.create(
      httpClient: client,
      preferences: prefs,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      invitationService: InvitationService(),
    );

    final treeService = CustomApiFamilyTreeService(
      authService: authService,
      runtimeConfig: const BackendRuntimeConfig(
        apiBaseUrl: 'https://api.example.ru',
      ),
      httpClient: client,
    );

    final pending = await treeService.getPendingTreeInvitations().first;
    expect(pending, hasLength(1));
    expect(pending.first.invitationId, 'invite-1');
    expect(pending.first.tree.name, 'Семья Смирновых');

    await treeService.respondToTreeInvitation('invite-1', true);
    expect(invitations, isEmpty);
  });
}
