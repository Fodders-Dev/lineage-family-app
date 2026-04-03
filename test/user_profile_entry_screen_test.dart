import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/backend/interfaces/family_tree_service_interface.dart';
import 'package:lineage/backend/interfaces/profile_service_interface.dart';
import 'package:lineage/models/chat_details.dart';
import 'package:lineage/models/family_person.dart';
import 'package:lineage/models/family_tree.dart';
import 'package:lineage/models/chat_send_progress.dart';
import 'package:lineage/models/user_profile.dart';
import 'package:lineage/screens/user_profile_entry_screen.dart';

class _FakeAuthService implements AuthServiceInterface {
  _FakeAuthService(this._currentUserId);

  final String? _currentUserId;

  @override
  String? get currentUserId => _currentUserId;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProfileService implements ProfileServiceInterface {
  _FakeProfileService(this.profiles, {this.currentUserId});

  final Map<String, UserProfile> profiles;
  final String? currentUserId;

  @override
  Future<UserProfile?> getUserProfile(String userId) async => profiles[userId];

  @override
  Future<UserProfile?> getCurrentUserProfile() async =>
      currentUserId == null ? null : profiles[currentUserId!];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeFamilyTreeService implements FamilyTreeServiceInterface {
  _FakeFamilyTreeService({
    required this.trees,
    required this.peopleByTree,
  });

  final List<FamilyTree> trees;
  final Map<String, List<FamilyPerson>> peopleByTree;

  @override
  Future<List<FamilyTree>> getUserTrees() async => trees;

  @override
  Future<List<FamilyPerson>> getRelatives(String treeId) async =>
      peopleByTree[treeId] ?? const <FamilyPerson>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService implements ChatServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  Future<String?> getOrCreateChat(String otherUserId) async =>
      'chat-user-1-$otherUserId';

  @override
  Future<void> sendMessageToChat({
    required String chatId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
    void Function(ChatSendProgress progress)? onProgress,
  }) async {}

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) async =>
      'chat-group-1';

  @override
  Future<String?> createBranchChat({
    required String treeId,
    required List<String> branchRootPersonIds,
    String? title,
  }) async =>
      'chat-branch-1';

  @override
  Future<ChatDetails> getChatDetails(String chatId) async => const ChatDetails(
        chatId: 'chat-group-1',
        type: 'group',
        title: 'Группа',
        participantIds: ['user-1', 'user-2'],
        participants: [
          ChatParticipantSummary(userId: 'user-1', displayName: 'Артем'),
          ChatParticipantSummary(userId: 'user-2', displayName: 'Иван'),
        ],
        branchRoots: [],
      );

  @override
  Future<ChatDetails> renameGroupChat({
    required String chatId,
    required String title,
  }) async =>
      getChatDetails(chatId);

  @override
  Future<ChatDetails> addGroupParticipants({
    required String chatId,
    required List<String> participantIds,
  }) async =>
      getChatDetails(chatId);

  @override
  Future<ChatDetails> removeGroupParticipant({
    required String chatId,
    required String participantId,
  }) async =>
      getChatDetails(chatId);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final getIt = GetIt.instance;

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('shows direct actions when profile exists in current trees',
      (tester) async {
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService('user-1'));
    getIt.registerSingleton<ProfileServiceInterface>(
      _FakeProfileService(
        {
          'user-2': UserProfile.create(
            id: 'user-2',
            email: 'user-2@example.com',
            displayName: 'Мария Романова',
            username: 'romanova',
            phoneNumber: '',
            city: 'Москва',
            country: 'Россия',
          ),
        },
        currentUserId: 'user-2',
      ),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
        trees: [
          FamilyTree(
            id: 'tree-1',
            name: 'Историческое дерево',
            description: '',
            creatorId: 'user-1',
            memberIds: const ['user-1'],
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            isPrivate: false,
            members: const ['user-1'],
          ),
        ],
        peopleByTree: {
          'tree-1': [
            FamilyPerson(
              id: 'person-2',
              treeId: 'tree-1',
              userId: 'user-2',
              name: 'Мария Романова',
              gender: Gender.female,
              isAlive: true,
              createdAt: DateTime(2024, 1, 1),
              updatedAt: DateTime(2024, 1, 1),
            ),
          ],
        },
      ),
    );
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());

    await tester.pumpWidget(
      const MaterialApp(
        home: UserProfileEntryScreen(userId: 'user-2'),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Мария Романова'), findsOneWidget);
    expect(find.text('Написать'), findsOneWidget);
    expect(find.text('Карточка в дереве'), findsOneWidget);
    expect(find.text('Историческое дерево'), findsOneWidget);
  });

  testWidgets('shows self-profile action for current user route',
      (tester) async {
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService('user-1'));
    getIt.registerSingleton<ProfileServiceInterface>(
      _FakeProfileService(
        {
          'user-1': UserProfile.create(
            id: 'user-1',
            email: 'user-1@example.com',
            displayName: 'Алексей Петров',
            username: 'petrov',
            phoneNumber: '',
          ),
        },
        currentUserId: 'user-1',
      ),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
          trees: const <FamilyTree>[], peopleByTree: const {}),
    );
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());

    await tester.pumpWidget(
      const MaterialApp(
        home: UserProfileEntryScreen(userId: 'user-1'),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Открыть мой профиль'), findsOneWidget);
  });

  testWidgets('falls back to tree card when app profile is missing',
      (tester) async {
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService('user-1'));
    getIt.registerSingleton<ProfileServiceInterface>(
      _FakeProfileService(const <String, UserProfile>{},
          currentUserId: 'user-1'),
    );
    getIt.registerSingleton<FamilyTreeServiceInterface>(
      _FakeFamilyTreeService(
        trees: [
          FamilyTree(
            id: 'tree-1',
            name: 'Историческое дерево',
            description: '',
            creatorId: 'user-1',
            memberIds: const ['user-1'],
            createdAt: DateTime(2024, 1, 1),
            updatedAt: DateTime(2024, 1, 1),
            isPrivate: false,
            members: const ['user-1'],
          ),
        ],
        peopleByTree: {
          'tree-1': [
            FamilyPerson(
              id: 'person-2',
              treeId: 'tree-1',
              userId: 'user-2',
              name: 'Мария Романова',
              gender: Gender.female,
              isAlive: true,
              notes: 'Историческая персона в дереве',
              createdAt: DateTime(2024, 1, 1),
              updatedAt: DateTime(2024, 1, 1),
            ),
          ],
        },
      ),
    );
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());

    await tester.pumpWidget(
      const MaterialApp(
        home: UserProfileEntryScreen(userId: 'user-2'),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Мария Романова'), findsOneWidget);
    expect(
      find.text(
          'Профиль в приложении ещё не заполнен. Открыта карточка человека из дерева.'),
      findsOneWidget,
    );
    expect(find.text('Историческое дерево'), findsOneWidget);
    expect(find.text('Карточка в дереве'), findsOneWidget);
  });
}
