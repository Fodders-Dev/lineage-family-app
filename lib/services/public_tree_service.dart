import 'dart:convert';

import 'package:http/http.dart' as http;

import '../backend/backend_runtime_config.dart';
import '../models/family_person.dart';
import '../models/family_relation.dart';
import '../models/family_tree.dart';

class PublicTreePreview {
  const PublicTreePreview({
    required this.tree,
    required this.peopleCount,
    required this.relationsCount,
  });

  final FamilyTree tree;
  final int peopleCount;
  final int relationsCount;
}

class PublicTreeSnapshot {
  const PublicTreeSnapshot({
    required this.tree,
    required this.persons,
    required this.relations,
  });

  final FamilyTree tree;
  final List<FamilyPerson> persons;
  final List<FamilyRelation> relations;

  int get peopleCount => persons.length;
  int get relationsCount => relations.length;
}

abstract class PublicTreeServiceInterface {
  Future<PublicTreePreview?> getPublicTreePreview(String publicTreeId);
  Future<PublicTreeSnapshot?> getPublicTreeSnapshot(String publicTreeId);
}

class PublicTreeService implements PublicTreeServiceInterface {
  PublicTreeService({
    http.Client? httpClient,
    BackendRuntimeConfig? runtimeConfig,
  })  : _httpClient = httpClient ?? http.Client(),
        _runtimeConfig = runtimeConfig ?? BackendRuntimeConfig.current;

  final http.Client _httpClient;
  final BackendRuntimeConfig _runtimeConfig;

  @override
  Future<PublicTreePreview?> getPublicTreePreview(String publicTreeId) async {
    final payload =
        await _requestJson('/v1/public/trees/${publicTreeId.trim()}');
    if (payload == null) {
      return null;
    }

    final treeJson = payload['tree'];
    if (treeJson is! Map<String, dynamic>) {
      return null;
    }

    final stats = payload['stats'] as Map<String, dynamic>? ?? const {};
    return PublicTreePreview(
      tree: FamilyTree.fromMap(treeJson, treeJson['id']?.toString() ?? ''),
      peopleCount: (stats['peopleCount'] as num?)?.toInt() ?? 0,
      relationsCount: (stats['relationsCount'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<PublicTreeSnapshot?> getPublicTreeSnapshot(String publicTreeId) async {
    final normalizedId = publicTreeId.trim();
    final previewPayload = await _requestJson('/v1/public/trees/$normalizedId');
    if (previewPayload == null) {
      return null;
    }

    final treeJson = previewPayload['tree'];
    if (treeJson is! Map<String, dynamic>) {
      return null;
    }

    final tree = FamilyTree.fromMap(treeJson, treeJson['id']?.toString() ?? '');
    final personsPayload =
        await _requestJson('/v1/public/trees/$normalizedId/persons');
    final relationsPayload = await _requestJson(
      '/v1/public/trees/$normalizedId/relations',
    );

    final rawPersons = personsPayload?['persons'];
    final rawRelations = relationsPayload?['relations'];

    return PublicTreeSnapshot(
      tree: tree,
      persons: rawPersons is List<dynamic>
          ? rawPersons
              .whereType<Map<String, dynamic>>()
              .map((person) => _personFromJson(person, tree.id))
              .toList()
          : const <FamilyPerson>[],
      relations: rawRelations is List<dynamic>
          ? rawRelations
              .whereType<Map<String, dynamic>>()
              .map((relation) => _relationFromJson(relation, tree.id))
              .toList()
          : const <FamilyRelation>[],
    );
  }

  Future<Map<String, dynamic>?> _requestJson(String path) async {
    final base = _runtimeConfig.apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$normalizedPath');
    final response = await _httpClient.get(uri);
    if (response.statusCode == 404) {
      return null;
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Не удалось загрузить публичное дерево.');
    }
    if (response.body.isEmpty) {
      return const <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return const <String, dynamic>{};
  }

  FamilyPerson _personFromJson(
      Map<String, dynamic> json, String fallbackTreeId) {
    final gender = _genderFromJson(json['gender']?.toString());
    return FamilyPerson(
      id: json['id']?.toString() ?? '',
      treeId: json['treeId']?.toString() ?? fallbackTreeId,
      userId: json['userId']?.toString(),
      name: json['name']?.toString() ?? '',
      maidenName: json['maidenName']?.toString(),
      photoUrl: json['photoUrl']?.toString(),
      gender: gender,
      birthDate: _dateFromJson(json['birthDate']),
      birthPlace: json['birthPlace']?.toString(),
      deathDate: _dateFromJson(json['deathDate']),
      deathPlace: json['deathPlace']?.toString(),
      bio: json['bio']?.toString(),
      isAlive: json['isAlive'] != false,
      creatorId: json['creatorId']?.toString(),
      createdAt: _dateFromJson(json['createdAt']) ?? DateTime.now(),
      updatedAt: _dateFromJson(json['updatedAt']) ?? DateTime.now(),
      notes: json['notes']?.toString(),
    );
  }

  FamilyRelation _relationFromJson(
    Map<String, dynamic> json,
    String fallbackTreeId,
  ) {
    return FamilyRelation(
      id: json['id']?.toString() ?? '',
      treeId: json['treeId']?.toString() ?? fallbackTreeId,
      person1Id: json['person1Id']?.toString() ?? '',
      person2Id: json['person2Id']?.toString() ?? '',
      relation1to2: FamilyRelation.stringToRelationType(
        json['relation1to2']?.toString(),
      ),
      relation2to1: FamilyRelation.stringToRelationType(
        json['relation2to1']?.toString(),
      ),
      isConfirmed: json['isConfirmed'] != false,
      createdAt: _dateFromJson(json['createdAt']) ?? DateTime.now(),
      updatedAt: _dateFromJson(json['updatedAt']),
      createdBy: json['createdBy']?.toString(),
    );
  }

  DateTime? _dateFromJson(dynamic value) {
    if (value == null) {
      return null;
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
    return null;
  }

  Gender _genderFromJson(String? value) {
    switch (value) {
      case 'male':
        return Gender.male;
      case 'female':
        return Gender.female;
      case 'other':
        return Gender.other;
      default:
        return Gender.unknown;
    }
  }
}
