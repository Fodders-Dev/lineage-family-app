import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:lineage/backend/interfaces/auth_service_interface.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/models/chat_message.dart';
import 'package:lineage/models/chat_preview.dart';
import 'package:lineage/screens/chats_list_screen.dart';
import 'package:image_picker/image_picker.dart';

class _FakeAuthService implements AuthServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String? get currentUserEmail => 'user@example.com';

  @override
  String? get currentUserDisplayName => 'Артем';

  @override
  String? get currentUserPhotoUrl => null;

  @override
  List<String> get currentProviderIds => const ['password'];

  @override
  Stream<String?> get authStateChanges => const Stream.empty();

  @override
  String describeError(Object error) => error.toString();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeChatService implements ChatServiceInterface {
  @override
  String? get currentUserId => 'user-1';

  @override
  String buildChatId(String otherUserId) => 'chat-$otherUserId';

  @override
  Stream<List<ChatPreview>> getUserChatsStream(String userId) {
    return Stream.value(const <ChatPreview>[]);
  }

  @override
  Stream<int> getTotalUnreadCountStream(String userId) {
    return Stream.value(0);
  }

  @override
  Stream<List<ChatMessage>> getMessagesStream(String chatId) {
    return Stream.value(const <ChatMessage>[]);
  }

  @override
  Future<void> sendMessage({
    required String otherUserId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) async {}

  @override
  Future<void> sendMessageToChat({
    required String chatId,
    String text = '',
    List<XFile> attachments = const <XFile>[],
  }) async {}

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) async {}

  @override
  Future<void> markChatAsRead(String chatId, String userId) async {}

  @override
  Future<String?> getOrCreateChat(String otherUserId) async =>
      'chat-$otherUserId';

  @override
  Future<String?> createGroupChat({
    required List<String> participantIds,
    String? title,
    String? treeId,
  }) async =>
      'chat-group-1';
}

void main() {
  final getIt = GetIt.instance;

  setUp(() async {
    await getIt.reset();
    getIt.registerSingleton<AuthServiceInterface>(_FakeAuthService());
    getIt.registerSingleton<ChatServiceInterface>(_FakeChatService());
  });

  tearDown(() async {
    await getIt.reset();
  });

  GoRouter buildRouter() {
    return GoRouter(
      initialLocation: '/chats',
      routes: [
        GoRoute(
          path: '/chats',
          builder: (context, state) => const ChatsListScreen(),
        ),
        GoRoute(
          path: '/relatives',
          builder: (context, state) => const Text('relatives-screen'),
        ),
        GoRoute(
          path: '/tree',
          builder: (context, state) => const Text('tree-screen'),
        ),
      ],
    );
  }

  testWidgets('ChatsListScreen показывает CTA в пустом состоянии',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: buildRouter()),
    );

    await tester.pumpAndSettle();

    expect(find.text('Пока нет чатов'), findsOneWidget);
    expect(find.text('Создать групповой чат'), findsOneWidget);
    expect(find.text('Открыть родных'), findsOneWidget);
    expect(find.text('Открыть дерево'), findsOneWidget);
  });

  testWidgets('Пустое состояние чатов ведет в родных и дерево', (tester) async {
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: buildRouter()),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.text('Открыть родных'));
    await tester.pumpAndSettle();
    expect(find.text('relatives-screen'), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp.router(routerConfig: buildRouter()),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Открыть дерево'));
    await tester.pumpAndSettle();
    expect(find.text('tree-screen'), findsOneWidget);
  });
}
