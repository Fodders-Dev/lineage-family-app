import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lineage/backend/interfaces/chat_service_interface.dart';
import 'package:lineage/models/chat_message.dart';
import 'package:lineage/models/chat_preview.dart';
import 'package:lineage/models/chat_send_progress.dart';
import 'package:lineage/screens/chat_screen.dart';

class _FakeChatService implements ChatServiceInterface {
  final Completer<void> sendCompleter = Completer<void>();
  final StreamController<List<ChatMessage>> _messagesController =
      StreamController<List<ChatMessage>>.broadcast();

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
    return _messagesController.stream;
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
    void Function(ChatSendProgress progress)? onProgress,
  }) async {
    onProgress?.call(
      const ChatSendProgress(
        stage: ChatSendProgressStage.sending,
        completed: 1,
        total: 1,
      ),
    );
    await sendCompleter.future;
  }

  @override
  Future<void> sendTextMessage({
    required String otherUserId,
    required String text,
  }) async {}

  @override
  Future<void> markChatAsRead(String chatId, String userId) async {}

  @override
  Future<String?> getOrCreateChat(String otherUserId) async => 'chat-1';

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
}

void main() {
  final getIt = GetIt.instance;

  setUpAll(() async {
    await initializeDateFormatting('ru');
  });

  setUp(() async {
    await getIt.reset();
  });

  tearDown(() async {
    await getIt.reset();
  });

  testWidgets('ChatScreen shows sending and sent states for optimistic message',
      (tester) async {
    final chatService = _FakeChatService();
    getIt.registerSingleton<ChatServiceInterface>(chatService);

    await tester.pumpWidget(
      const MaterialApp(
        home: ChatScreen(
          chatId: 'chat-1',
          title: 'Тестовый чат',
        ),
      ),
    );

    chatService._messagesController.add(const <ChatMessage>[]);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Привет!');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();

    expect(find.text('Привет!'), findsOneWidget);
    expect(find.text('Отправляется...'), findsOneWidget);

    chatService.sendCompleter.complete();
    await tester.pump();

    expect(find.text('Отправлено'), findsOneWidget);
  });
}
