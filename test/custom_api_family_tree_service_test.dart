import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rodnya/backend/backend_runtime_config.dart';
import 'package:rodnya/models/family_relation.dart';
import 'package:rodnya/models/relation_request.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/custom_api_family_tree_service.dart';
import 'package:rodnya/services/invitation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('CustomApiFamilyTreeService removes tree via backend route', () async {
    var deleteCalls = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-1' &&
          request.method == 'DELETE') {
        deleteCalls += 1;
        expect(request.headers['authorization'], 'Bearer access-token');
        return http.Response('', 204);
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
        'email': 'dev@rodnya.app',
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

    await treeService.removeTree('tree-1');

    expect(deleteCalls, 1);
  });

  test('CustomApiFamilyTreeService parses duplicate suggestions', () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-1/duplicates' &&
          request.method == 'GET') {
        expect(request.headers['authorization'], 'Bearer access-token');
        return http.Response(
          jsonEncode({
            'suggestions': [
              {
                'id': 'tree-1:person-a:person-b',
                'treeId': 'tree-1',
                'score': 0.95,
                'confidence': 'high',
                'reasons': ['Совпадает ФИО', 'Совпадает дата рождения'],
                'personA': {
                  'id': 'person-a',
                  'treeId': 'tree-1',
                  'identityId': 'identity-a',
                  'name': 'Петров Иван Сергеевич',
                  'gender': 'male',
                  'birthDate': '1975-05-10T00:00:00.000Z',
                  'isAlive': true,
                },
                'personB': {
                  'id': 'person-b',
                  'treeId': 'tree-1',
                  'identityId': 'identity-b',
                  'name': 'Петров Иван Сергеевич',
                  'gender': 'male',
                  'birthDate': '1975-05-10T00:00:00.000Z',
                  'isAlive': true,
                },
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
        'email': 'dev@rodnya.app',
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

    final suggestions = await treeService.getDuplicateSuggestions('tree-1');

    expect(suggestions, hasLength(1));
    expect(suggestions.first.involves('person-a'), isTrue);
    expect(suggestions.first.otherPersonFor('person-a').id, 'person-b');
    expect(suggestions.first.reasons, contains('Совпадает ФИО'));
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
        'email': 'dev@rodnya.app',
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

  test('CustomApiFamilyTreeService round-trips custom relation labels',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-custom/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'persons': [
              {
                'id': 'person-a',
                'treeId': 'tree-custom',
                'name': 'Артем Кузнецов',
                'gender': 'male',
                'isAlive': true,
              },
              {
                'id': 'person-b',
                'treeId': 'tree-custom',
                'name': 'Павел Иванов',
                'gender': 'male',
                'isAlive': true,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-custom/relations' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['customRelationLabel1to2'], 'Побратим');
        expect(body['customRelationLabel2to1'], 'Побратим');
        return http.Response(
          jsonEncode({
            'relation': {
              'id': 'relation-custom',
              'treeId': 'tree-custom',
              'person1Id': body['person1Id'],
              'person2Id': body['person2Id'],
              'relation1to2': body['relation1to2'],
              'relation2to1': body['relation2to1'],
              'customRelationLabel1to2': body['customRelationLabel1to2'],
              'customRelationLabel2to1': body['customRelationLabel2to1'],
              'isConfirmed': true,
              'createdAt': '2026-04-18T09:00:00.000Z',
              'updatedAt': '2026-04-18T09:00:00.000Z',
              'createdBy': 'user-1',
            },
          }),
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
        'email': 'dev@rodnya.app',
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

    final relation = await treeService.createRelation(
      treeId: 'tree-custom',
      person1Id: 'person-a',
      person2Id: 'person-b',
      relation1to2: RelationType.other,
      isConfirmed: true,
      customRelationLabel1to2: 'Побратим',
      customRelationLabel2to1: 'Побратим',
    );

    expect(relation.relation1to2, RelationType.other);
    expect(relation.customRelationLabel1to2, 'Побратим');
    expect(relation.customRelationLabel2to1, 'Побратим');
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
        'email': 'dev@rodnya.app',
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
      'CustomApiFamilyTreeService round-trips marriage and divorce dates for spouse relations',
      () async {
    final persons = <Map<String, dynamic>>[
      {
        'id': 'person-a',
        'treeId': 'tree-wedding',
        'name': 'Ирина Смирнова',
        'gender': 'female',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T11:00:00.000Z',
        'updatedAt': '2026-03-27T11:00:00.000Z',
      },
      {
        'id': 'person-b',
        'treeId': 'tree-wedding',
        'name': 'Павел Смирнов',
        'gender': 'male',
        'isAlive': true,
        'creatorId': 'user-1',
        'createdAt': '2026-03-27T11:00:00.000Z',
        'updatedAt': '2026-03-27T11:00:00.000Z',
      },
    ];
    final relations = <Map<String, dynamic>>[];

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-wedding/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'persons': persons}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-wedding/relations' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['marriageDate'], '2014-07-12T00:00:00.000Z');
        expect(body['divorceDate'], '2020-02-10T00:00:00.000Z');

        final relation = <String, dynamic>{
          'id': 'relation-wedding',
          'treeId': 'tree-wedding',
          'person1Id': body['person1Id'],
          'person2Id': body['person2Id'],
          'relation1to2': body['relation1to2'],
          'relation2to1': body['relation2to1'],
          'isConfirmed': body['isConfirmed'],
          'marriageDate': body['marriageDate'],
          'divorceDate': body['divorceDate'],
          'createdAt': '2026-03-27T11:05:00.000Z',
          'updatedAt': '2026-03-27T11:05:00.000Z',
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

      if (request.url.path == '/v1/trees/tree-wedding/relations' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({'relations': relations}),
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
        'email': 'dev@rodnya.app',
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

    final createdRelation = await treeService.createRelation(
      treeId: 'tree-wedding',
      person1Id: 'person-a',
      person2Id: 'person-b',
      relation1to2: RelationType.spouse,
      isConfirmed: true,
      marriageDate: DateTime.utc(2014, 7, 12),
      divorceDate: DateTime.utc(2020, 2, 10),
    );

    expect(createdRelation.marriageDate, DateTime.utc(2014, 7, 12));
    expect(createdRelation.divorceDate, DateTime.utc(2020, 2, 10));

    final listedRelations = await treeService.getRelations('tree-wedding');
    expect(listedRelations, hasLength(1));
    expect(listedRelations.single.marriageDate, DateTime.utc(2014, 7, 12));
    expect(listedRelations.single.divorceDate, DateTime.utc(2020, 2, 10));
  });

  test(
      'CustomApiFamilyTreeService parses primaryPhotoUrl/photoGallery and normalizes nested payloads',
      () async {
    late Map<String, dynamic> lastPatchBody;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-3/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'persons': [
              {
                'id': 'person-gallery',
                'treeId': 'tree-3',
                'identityId': 'identity-anna',
                'name': 'Галерея Анна',
                'gender': 'female',
                'isAlive': true,
                'creatorId': 'user-1',
                'createdAt': '2026-03-27T12:00:00.000Z',
                'updatedAt': '2026-03-27T12:00:00.000Z',
                'primaryPhotoUrl': 'https://cdn.example.ru/anna-primary.jpg',
                'photoGallery': [
                  {
                    'id': 'media-1',
                    'url': 'https://cdn.example.ru/anna-primary.jpg',
                    'type': 'image',
                    'isPrimary': true,
                  },
                  {
                    'id': 'media-2',
                    'url': 'https://cdn.example.ru/anna-second.jpg',
                    'type': 'image',
                    'isPrimary': false,
                  },
                ],
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-3/persons/person-gallery' &&
          request.method == 'PATCH') {
        lastPatchBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'person': {
              'id': 'person-gallery',
              'treeId': 'tree-3',
              'name': 'Галерея Анна',
              'gender': 'female',
              'isAlive': true,
              'creatorId': 'user-1',
              'createdAt': '2026-03-27T12:00:00.000Z',
              'updatedAt': '2026-03-27T12:10:00.000Z',
              'primaryPhotoUrl': 'https://cdn.example.ru/anna-second.jpg',
              'photoGallery': lastPatchBody['photoGallery'],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees' && request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'trees': [
              {
                'id': 'tree-3',
                'name': 'Tree 3',
                'description': '',
                'creatorId': 'user-1',
                'memberIds': ['user-1'],
                'members': ['user-1'],
                'createdAt': '2026-03-27T12:00:00.000Z',
                'updatedAt': '2026-03-27T12:00:00.000Z',
                'isPrivate': true,
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
        'email': 'dev@rodnya.app',
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

    final relatives = await treeService.getRelatives('tree-3');
    expect(relatives, hasLength(1));
    expect(relatives.first.identityId, 'identity-anna');
    expect(relatives.first.photoUrl, 'https://cdn.example.ru/anna-primary.jpg');
    expect(relatives.first.primaryPhotoUrl,
        'https://cdn.example.ru/anna-primary.jpg');
    expect(relatives.first.photoGallery, hasLength(2));
    expect(relatives.first.photoGallery.first['isPrimary'], true);

    await treeService.updateRelative('person-gallery', {
      'name': 'Галерея Анна',
      'photoGallery': [
        {
          'id': 'media-2',
          'url': 'https://cdn.example.ru/anna-second.jpg',
          'type': 'image',
          'isPrimary': true,
          'updatedAt': DateTime.utc(2026, 3, 27, 12, 10),
        },
      ],
    });

    expect(lastPatchBody['photoGallery'], isA<List<dynamic>>());
    expect(
      (lastPatchBody['photoGallery'] as List<dynamic>).first['updatedAt'],
      '2026-03-27T12:10:00.000Z',
    );
  });

  test(
      'CustomApiFamilyTreeService maps extended viewer labels from graph snapshot to precise relation types',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-graph/graph' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'snapshot': {
              'treeId': 'tree-graph',
              'viewerPersonId': 'viewer-person',
              'people': [
                {
                  'id': 'viewer-person',
                  'treeId': 'tree-graph',
                  'userId': 'user-1',
                  'name': 'Артем Кузнецов',
                  'gender': 'male',
                },
                {
                  'id': 'stepmother',
                  'treeId': 'tree-graph',
                  'name': 'Ольга Кузнецова',
                  'gender': 'female',
                },
                {
                  'id': 'stepson',
                  'treeId': 'tree-graph',
                  'name': 'Максим Кузнецов',
                  'gender': 'male',
                },
                {
                  'id': 'uncle-in-law',
                  'treeId': 'tree-graph',
                  'name': 'Сергей Кузнецов',
                  'gender': 'male',
                },
                {
                  'id': 'aunt-in-law',
                  'treeId': 'tree-graph',
                  'name': 'Ирина Кузнецова',
                  'gender': 'female',
                },
                {
                  'id': 'niece',
                  'treeId': 'tree-graph',
                  'name': 'Мария Кузнецова',
                  'gender': 'female',
                },
                {
                  'id': 'mother-in-law',
                  'treeId': 'tree-graph',
                  'name': 'Анна Смирнова',
                  'gender': 'female',
                },
                {
                  'id': 'sister-in-law',
                  'treeId': 'tree-graph',
                  'name': 'Елена Смирнова',
                  'gender': 'female',
                },
                {
                  'id': 'ex-wife',
                  'treeId': 'tree-graph',
                  'name': 'Ольга Бывшая',
                  'gender': 'female',
                },
                {
                  'id': 'ex-partner',
                  'treeId': 'tree-graph',
                  'name': 'Игорь Бывший',
                  'gender': 'male',
                },
                {
                  'id': 'parent-in-law-wife',
                  'treeId': 'tree-graph',
                  'name': 'Борис Тестов',
                  'gender': 'male',
                },
                {
                  'id': 'sibling-in-law-husb',
                  'treeId': 'tree-graph',
                  'name': 'Олег Тестов',
                  'gender': 'male',
                },
                {
                  'id': 'bro-of-spouse',
                  'treeId': 'tree-graph',
                  'name': 'Пётр Тестов',
                  'gender': 'male',
                },
                {
                  'id': 'direct-wife',
                  'treeId': 'tree-graph',
                  'name': 'Мария Тестова',
                  'gender': 'female',
                },
                {
                  'id': 'direct-parent',
                  'treeId': 'tree-graph',
                  'name': 'Нина Тестова',
                  'gender': 'female',
                },
              ],
              'relations': const [],
              'familyUnits': const [],
              'branchBlocks': const [],
              'generationRows': const [],
              'viewerDescriptors': [
                {
                  'personId': 'stepmother',
                  'primaryRelationLabel': 'Мачеха',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'step',
                  'primaryPathPersonIds': ['viewer-person', 'stepmother'],
                },
                {
                  'personId': 'stepson',
                  'primaryRelationLabel': 'Пасынок',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'step',
                  'primaryPathPersonIds': ['viewer-person', 'stepson'],
                },
                {
                  'personId': 'uncle-in-law',
                  'primaryRelationLabel': 'Дядя',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'affinal',
                  'primaryPathPersonIds': ['viewer-person', 'uncle-in-law'],
                },
                {
                  'personId': 'aunt-in-law',
                  'primaryRelationLabel': 'Тетя',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'affinal',
                  'primaryPathPersonIds': ['viewer-person', 'aunt-in-law'],
                },
                {
                  'personId': 'niece',
                  'primaryRelationLabel': 'Племянница',
                  'isBlood': true,
                  'alternatePathCount': 0,
                  'pathSummary': 'blood',
                  'primaryPathPersonIds': ['viewer-person', 'niece'],
                },
                {
                  'personId': 'mother-in-law',
                  'primaryRelationLabel': 'Свекровь',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'in-law',
                  'primaryPathPersonIds': ['viewer-person', 'mother-in-law'],
                },
                {
                  'personId': 'sister-in-law',
                  'primaryRelationLabel': 'Золовка',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'in-law',
                  'primaryPathPersonIds': ['viewer-person', 'sister-in-law'],
                },
                {
                  'personId': 'ex-wife',
                  'primaryRelationLabel': 'Бывшая жена',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'union',
                  'primaryPathPersonIds': ['viewer-person', 'ex-wife'],
                },
                {
                  'personId': 'ex-partner',
                  'primaryRelationLabel': 'Бывший партнёр',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'union',
                  'primaryPathPersonIds': ['viewer-person', 'ex-partner'],
                },
                {
                  'personId': 'parent-in-law-wife',
                  'primaryRelationLabel': 'Родитель жены',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'in-law',
                  'primaryPathPersonIds': [
                    'viewer-person',
                    'parent-in-law-wife',
                  ],
                },
                {
                  'personId': 'sibling-in-law-husb',
                  'primaryRelationLabel': 'Родня мужа',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'in-law',
                  'primaryPathPersonIds': [
                    'viewer-person',
                    'sibling-in-law-husb',
                  ],
                },
                {
                  'personId': 'bro-of-spouse',
                  'primaryRelationLabel': 'Брат супруга',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'in-law',
                  'primaryPathPersonIds': ['viewer-person', 'bro-of-spouse'],
                },
                {
                  'personId': 'direct-wife',
                  'primaryRelationLabel': 'Жена',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'union',
                  'primaryPathPersonIds': ['viewer-person', 'direct-wife'],
                },
                {
                  'personId': 'direct-parent',
                  'primaryRelationLabel': 'Родитель',
                  'isBlood': true,
                  'alternatePathCount': 0,
                  'pathSummary': 'blood',
                  'primaryPathPersonIds': ['viewer-person', 'direct-parent'],
                },
              ],
            },
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
        'email': 'dev@rodnya.app',
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

    expect(
      await treeService.getRelationToUser('tree-graph', 'stepmother'),
      RelationType.stepparent,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'stepson'),
      RelationType.stepchild,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'uncle-in-law'),
      RelationType.uncle,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'aunt-in-law'),
      RelationType.aunt,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'niece'),
      RelationType.niece,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'mother-in-law'),
      RelationType.parentInLaw,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'sister-in-law'),
      RelationType.siblingInLaw,
    );
    // B2: гендерные метки бывшего союза должны резолвиться обратно в
    // союзный тип (а не в RelationType.other), иначе редактирование
    // экс-супруга предвыбирало бы «другое».
    expect(
      await treeService.getRelationToUser('tree-graph', 'ex-wife'),
      RelationType.ex_spouse,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'ex-partner'),
      RelationType.ex_partner,
    );
    // B2 (ревью FR5): притяжательные in-law метки НЕ должны мапиться в
    // spouse — genitive «жены»/«мужа»/«супруга» это не сам супруг.
    expect(
      await treeService.getRelationToUser('tree-graph', 'parent-in-law-wife'),
      RelationType.parentInLaw,
      reason: '«Родитель жены» — тесть/тёща, не супруг',
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'sibling-in-law-husb'),
      RelationType.siblingInLaw,
      reason: '«Родня мужа» — родня супруга, не супруг',
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'bro-of-spouse'),
      RelationType.siblingInLaw,
      reason: '«Брат супруга» — родня супруга, не супруг',
    );
    // Регресс: прямые метки союза/родителя по-прежнему резолвятся.
    expect(
      await treeService.getRelationToUser('tree-graph', 'direct-wife'),
      RelationType.spouse,
    );
    expect(
      await treeService.getRelationToUser('tree-graph', 'direct-parent'),
      RelationType.parent,
    );
  });

  test(
      'CustomApiFamilyTreeService parses parent-set and union metadata from graph snapshot relations',
      () async {
    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-meta/graph' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'snapshot': {
              'treeId': 'tree-meta',
              'viewerPersonId': 'viewer-person',
              'people': [
                {
                  'id': 'viewer-person',
                  'treeId': 'tree-meta',
                  'name': 'Артем Кузнецов',
                  'gender': 'male',
                },
                {
                  'id': 'child-person',
                  'treeId': 'tree-meta',
                  'name': 'Павел Кузнецов',
                  'gender': 'male',
                },
              ],
              'relations': [
                {
                  'id': 'relation-parent',
                  'treeId': 'tree-meta',
                  'person1Id': 'viewer-person',
                  'person2Id': 'child-person',
                  'relation1to2': 'parent',
                  'relation2to1': 'child',
                  'isConfirmed': true,
                  'createdAt': '2026-04-18T10:00:00.000Z',
                  'updatedAt': '2026-04-18T10:00:00.000Z',
                  'parentSetId': 'ps-1',
                  'parentSetType': 'guardian',
                  'isPrimaryParentSet': false,
                  'unionId': 'union-1',
                  'unionType': 'partner',
                  'unionStatus': 'past',
                },
              ],
              'familyUnits': const [],
              'branchBlocks': const [],
              'generationRows': const [],
              'warnings': [
                {
                  'id': 'warning-1',
                  'code': 'auto_repaired_parent_link',
                  'severity': 'info',
                  'message':
                      'Связь Артем Кузнецов -> Павел Кузнецов достроена автоматически по данным дерева.',
                  'hint':
                      'Проверьте, что этот родитель относится к правильному набору родителей.',
                  'personIds': ['viewer-person', 'child-person'],
                  'familyUnitIds': ['unit-meta'],
                  'relationIds': ['relation-parent'],
                },
              ],
              'viewerDescriptors': [
                {
                  'personId': 'child-person',
                  'primaryRelationLabel': 'Пасынок',
                  'isBlood': false,
                  'alternatePathCount': 0,
                  'pathSummary': 'viewer -> child',
                  'primaryPathPersonIds': ['viewer-person', 'child-person'],
                },
              ],
            },
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
        'email': 'dev@rodnya.app',
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

    final snapshot = await treeService.getTreeGraphSnapshot('tree-meta');
    final relation = snapshot.relations.single;

    expect(relation.parentSetId, 'ps-1');
    expect(relation.parentSetType, 'guardian');
    expect(relation.isPrimaryParentSet, isFalse);
    expect(relation.unionId, 'union-1');
    expect(relation.unionType, 'partner');
    expect(relation.unionStatus, 'past');
    expect(snapshot.warnings, hasLength(1));
    expect(snapshot.warnings.single.code, 'auto_repaired_parent_link');
    expect(snapshot.warnings.single.relationIds, contains('relation-parent'));
  });

  test(
      'CustomApiFamilyTreeService manages relative media and loads filtered tree history',
      () async {
    late Map<String, dynamic> addMediaBody;
    late Map<String, dynamic> updateMediaBody;
    final person = <String, dynamic>{
      'id': 'person-gallery',
      'treeId': 'tree-4',
      'name': 'Галерея Анна',
      'gender': 'female',
      'isAlive': true,
      'creatorId': 'user-1',
      'createdAt': '2026-03-27T12:00:00.000Z',
      'updatedAt': '2026-03-27T12:00:00.000Z',
      'photoUrl': 'https://cdn.example.ru/anna-primary.jpg',
      'primaryPhotoUrl': 'https://cdn.example.ru/anna-primary.jpg',
      'photoGallery': [
        {
          'id': 'media-1',
          'url': 'https://cdn.example.ru/anna-primary.jpg',
          'type': 'image',
          'isPrimary': true,
        },
      ],
    };

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-4/persons' &&
          request.method == 'GET') {
        return http.Response(
          jsonEncode({
            'persons': [person]
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-4/persons/person-gallery/media' &&
          request.method == 'POST') {
        addMediaBody = jsonDecode(request.body) as Map<String, dynamic>;
        person['updatedAt'] = '2026-03-27T12:05:00.000Z';
        person['photoGallery'] = [
          ...(person['photoGallery'] as List<dynamic>),
          {
            'id': 'media-2',
            'url': addMediaBody['url'],
            'type': addMediaBody['type'],
            'isPrimary': addMediaBody['isPrimary'] == true,
            'uploadedAt': addMediaBody['uploadedAt'],
          },
        ];
        return http.Response(
          jsonEncode({
            'person': person,
            'media': (person['photoGallery'] as List<dynamic>).last,
          }),
          201,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path ==
              '/v1/trees/tree-4/persons/person-gallery/media/media-2' &&
          request.method == 'PATCH') {
        updateMediaBody = jsonDecode(request.body) as Map<String, dynamic>;
        person['updatedAt'] = '2026-03-27T12:06:00.000Z';
        person['primaryPhotoUrl'] = 'https://cdn.example.ru/anna-second.jpg';
        person['photoUrl'] = 'https://cdn.example.ru/anna-second.jpg';
        person['photoGallery'] = [
          {
            'id': 'media-1',
            'url': 'https://cdn.example.ru/anna-primary.jpg',
            'type': 'image',
            'isPrimary': false,
          },
          {
            'id': 'media-2',
            'url': 'https://cdn.example.ru/anna-second.jpg',
            'type': 'image',
            'isPrimary': true,
            'caption': updateMediaBody['caption'],
          },
        ];
        return http.Response(
          jsonEncode({
            'person': person,
            'media': (person['photoGallery'] as List<dynamic>).last,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path ==
              '/v1/trees/tree-4/persons/person-gallery/media/media-1' &&
          request.method == 'DELETE') {
        person['updatedAt'] = '2026-03-27T12:07:00.000Z';
        person['photoGallery'] = [
          {
            'id': 'media-2',
            'url': 'https://cdn.example.ru/anna-second.jpg',
            'type': 'image',
            'isPrimary': true,
            'caption': 'Новая обложка',
          },
        ];
        person['primaryPhotoUrl'] = 'https://cdn.example.ru/anna-second.jpg';
        person['photoUrl'] = 'https://cdn.example.ru/anna-second.jpg';
        return http.Response(
          jsonEncode({
            'person': person,
            'deletedMediaId': 'media-1',
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }

      if (request.url.path == '/v1/trees/tree-4/history' &&
          request.method == 'GET') {
        expect(request.url.queryParameters['personId'], 'person-gallery');
        expect(request.url.queryParameters['actorId'], 'user-1');
        return http.Response(
          jsonEncode({
            'records': [
              {
                'id': 'change-1',
                'treeId': 'tree-4',
                'actorId': 'user-1',
                'type': 'person_media.created',
                'personId': 'person-gallery',
                'personIds': ['person-gallery'],
                'mediaId': 'media-2',
                'createdAt': '2026-03-27T12:05:00.000Z',
                'details': {
                  'media': {
                    'id': 'media-2',
                    'url': 'https://cdn.example.ru/anna-second.jpg',
                  },
                },
              },
              {
                'id': 'change-2',
                'treeId': 'tree-4',
                'actorId': 'user-1',
                'type': 'person_media.deleted',
                'personId': 'person-gallery',
                'personIds': ['person-gallery'],
                'mediaId': 'media-1',
                'createdAt': '2026-03-27T12:07:00.000Z',
                'details': {
                  'deletedMediaId': 'media-1',
                },
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
        'email': 'dev@rodnya.app',
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

    final relatives = await treeService.getRelatives('tree-4');
    expect(relatives, hasLength(1));
    expect(relatives.first.primaryPhotoUrl,
        'https://cdn.example.ru/anna-primary.jpg');

    final withAddedMedia = await treeService.addRelativeMedia(
      treeId: 'tree-4',
      personId: 'person-gallery',
      mediaData: {
        'url': 'https://cdn.example.ru/anna-second.jpg',
        'type': 'image',
        'uploadedAt': DateTime.utc(2026, 3, 27, 12, 5),
      },
    );
    expect(addMediaBody['uploadedAt'], '2026-03-27T12:05:00.000Z');
    expect(withAddedMedia.photoGallery, hasLength(2));
    expect(withAddedMedia.primaryPhotoUrl,
        'https://cdn.example.ru/anna-primary.jpg');

    final withUpdatedPrimary = await treeService.updateRelativeMedia(
      treeId: 'tree-4',
      personId: 'person-gallery',
      mediaId: 'media-2',
      mediaData: {
        'isPrimary': true,
        'caption': 'Новая обложка',
      },
    );
    expect(updateMediaBody['caption'], 'Новая обложка');
    expect(withUpdatedPrimary.primaryPhotoUrl,
        'https://cdn.example.ru/anna-second.jpg');
    expect(withUpdatedPrimary.photoGallery.first['isPrimary'], true);
    expect(withUpdatedPrimary.photoGallery.first['id'], 'media-2');

    final withDeletedLegacy = await treeService.deleteRelativeMedia(
      treeId: 'tree-4',
      personId: 'person-gallery',
      mediaId: 'media-1',
    );
    expect(
        withDeletedLegacy.photoUrl, 'https://cdn.example.ru/anna-second.jpg');
    expect(withDeletedLegacy.photoGallery, hasLength(1));

    final history = await treeService.getTreeHistory(
      treeId: 'tree-4',
      personId: 'person-gallery',
      actorId: 'user-1',
    );
    expect(history, hasLength(2));
    expect(history.first.type, 'person_media.created');
    expect(history.first.mediaId, 'media-2');
    expect(history.last.type, 'person_media.deleted');
    expect(history.last.details['deletedMediaId'], 'media-1');
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
        'email': 'dev@rodnya.app',
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
        expect(request.url.queryParameters['value'], 'invitee@rodnya.app');
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
        'email': 'dev@rodnya.app',
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
      email: 'invitee@rodnya.app',
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
        'email': 'dev@rodnya.app',
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

  test(
      'CustomApiFamilyTreeService shares pending tree invitations polling across listeners',
      () async {
    var pendingRequestsCount = 0;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/tree-invitations/pending' &&
          request.method == 'GET') {
        pendingRequestsCount++;
        return http.Response(
          jsonEncode({
            'invitations': [
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
        'email': 'dev@rodnya.app',
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

    final stream = treeService.getPendingTreeInvitations();
    final firstListener = stream.first;
    final secondListener = stream.first;

    final results = await Future.wait([firstListener, secondListener]);

    expect(results.first, hasLength(1));
    expect(results.last, hasLength(1));
    expect(pendingRequestsCount, 1);
  });

  group('perf(client): getRelatives short-TTL cache + single-flight', () {
    test('two calls back-to-back share one HTTP request', () async {
      final ctx = await _RelativesCacheTestContext.create();

      final first = await ctx.treeService.getRelatives('tree-relatives');
      final second = await ctx.treeService.getRelatives('tree-relatives');

      expect(first, hasLength(1));
      expect(second, hasLength(1));
      expect(ctx.requestCount, 1);
    });

    test('concurrent overlapping calls single-flight into one request',
        () async {
      final responseGate = Completer<void>();
      final ctx = await _RelativesCacheTestContext.create(
        responseGate: responseGate,
      );

      // Mirrors the startup scenario: «Сегодня для семьи» and
      // EventService.getUpcomingEvents both ask for the same tree's
      // relatives before either request has come back.
      final futures = [
        ctx.treeService.getRelatives('tree-relatives'),
        ctx.treeService.getRelatives('tree-relatives'),
      ];
      await Future<void>.delayed(Duration.zero);
      responseGate.complete();
      final results = await Future.wait(futures);

      expect(results.first, hasLength(1));
      expect(results.last, hasLength(1));
      expect(ctx.requestCount, 1);
    });

    test('cache expires after the TTL window', () async {
      final ctx = await _RelativesCacheTestContext.create();

      await ctx.treeService.getRelatives('tree-relatives');
      expect(ctx.requestCount, 1);

      ctx.now = DateTime(2026, 9, 7, 12, 0, 31);
      await ctx.treeService.getRelatives('tree-relatives');
      expect(ctx.requestCount, 2);
    });

    test('a person mutation invalidates the cache immediately', () async {
      final ctx = await _RelativesCacheTestContext.create();

      final before = await ctx.treeService.getRelatives('tree-relatives');
      expect(before, hasLength(1));
      expect(ctx.requestCount, 1);

      await ctx.treeService.addRelative('tree-relatives', {
        'firstName': 'Мария',
        'lastName': 'Петрова',
        'gender': 'female',
      });

      // Still well within the 30s TTL window — without invalidation
      // this would incorrectly serve the pre-mutation cached list.
      final after = await ctx.treeService.getRelatives('tree-relatives');
      expect(after, hasLength(2));
      expect(ctx.requestCount, 2);
    });

    test('invalidateRelativesCache forces a fresh fetch (tree_mutated hook)',
        () async {
      final ctx = await _RelativesCacheTestContext.create();

      await ctx.treeService.getRelatives('tree-relatives');
      expect(ctx.requestCount, 1);

      // Simulates another device's edit arriving as a realtime/push
      // `tree_mutated` event — CustomApiNotificationService calls this
      // via RelativesCacheCapableFamilyTreeService.
      ctx.treeService.invalidateRelativesCache('tree-relatives');

      await ctx.treeService.getRelatives('tree-relatives');
      expect(ctx.requestCount, 2);
    });
  });
}

/// Test harness for the getRelatives cache group above. Not a record —
/// this repo targets Dart <4.0 and stays off Dart 3 syntax (records,
/// patterns, class modifiers).
class _RelativesCacheTestContext {
  _RelativesCacheTestContext._(this.treeService);

  final CustomApiFamilyTreeService treeService;
  int requestCount = 0;
  DateTime now = DateTime(2026, 9, 7, 12);

  static Future<_RelativesCacheTestContext> create({
    Completer<void>? responseGate,
  }) async {
    final persons = <Map<String, dynamic>>[
      {
        'id': 'user-1',
        'treeId': 'tree-relatives',
        'userId': 'user-1',
        'name': 'Иван Петров',
        'gender': 'male',
        'isAlive': true,
      },
    ];

    late final _RelativesCacheTestContext context;

    final client = MockClient((request) async {
      if (request.url.path == '/v1/trees/tree-relatives/persons' &&
          request.method == 'GET') {
        context.requestCount += 1;
        if (responseGate != null) {
          await responseGate.future;
        }
        return http.Response(
          jsonEncode({'persons': persons}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.url.path == '/v1/trees/tree-relatives/persons' &&
          request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final person = <String, dynamic>{
          'id': 'person-new',
          'treeId': 'tree-relatives',
          'name': '${body['lastName']} ${body['firstName']}'.trim(),
          'gender': body['gender'],
          'isAlive': true,
        };
        persons.add(person);
        return http.Response(
          jsonEncode({'person': person}),
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
        'email': 'dev@rodnya.app',
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

    context = _RelativesCacheTestContext._(
      CustomApiFamilyTreeService(
        authService: authService,
        runtimeConfig: const BackendRuntimeConfig(
          apiBaseUrl: 'https://api.example.ru',
        ),
        httpClient: client,
        clock: () => context.now,
      ),
    );
    return context;
  }
}
