// Шаг 5 bulk-upload: глобальный чип фоновой публикации — живой ход,
// «Повторить»/«Убрать» при провале, исчезает после успеха.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/media_upload_progress.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/post_publish_queue.dart';
import 'package:rodnya/theme/app_theme.dart';
import 'package:rodnya/widgets/post_publish_status_chip.dart';

/// createPost, которым управляет тест: завершается только по gate.
class _GatedPostService implements PostServiceInterface {
  Completer<void> gate = Completer<void>();
  Object? nextError;
  int calls = 0;

  @override
  Future<Post> createPost({
    required String treeId,
    required String content,
    List<XFile> images = const [],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const [],
    String? circleId,
    List<String>? branchIds,
    String? clientRequestId,
    void Function(MediaUploadProgress progress)? onProgress,
  }) async {
    calls += 1;
    await gate.future;
    final error = nextError;
    if (error != null) {
      throw error;
    }
    return Post(
      id: 'post-$calls',
      treeId: treeId,
      authorId: 'user-1',
      authorName: 'Автор',
      content: content,
      createdAt: DateTime(2026, 8, 28),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  tearDown(() {
    if (GetIt.I.isRegistered<PostPublishQueue>()) {
      GetIt.I<PostPublishQueue>().dispose();
      GetIt.I.unregister<PostPublishQueue>();
    }
  });

  Widget host() {
    return MaterialApp(
      theme: AppTheme.lightTheme,
      home: const Scaffold(
        body: Stack(children: [PostPublishStatusChip()]),
      ),
    );
  }

  testWidgets('без очереди в GetIt чип рисует пустоту', (tester) async {
    await tester.pumpWidget(host());
    expect(find.text('Публикуем запись…'), findsNothing);
  });

  testWidgets('живой ход → провал с «Повторить» → успех убирает чип',
      (tester) async {
    final service = _GatedPostService()
      ..nextError = const CustomApiException('Сеть недоступна');
    final queue = PostPublishQueue.memory(
        postService: service, currentUserId: () => 'user-1');
    GetIt.I.registerSingleton<PostPublishQueue>(queue);

    await tester.pumpWidget(host());
    unawaited(queue.enqueue(treeId: 'tree-1', content: 'Запись'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(find.text('Публикуем запись…'), findsOneWidget);

    // Провал: чип честно говорит, что случилось, и предлагает повторить.
    service.gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Сеть недоступна'), findsOneWidget);
    expect(find.text('Повторить'), findsOneWidget);

    // Повтор при вернувшейся сети — пост уходит, чип исчезает без следа.
    service.nextError = null;
    service.gate = Completer<void>()..complete();
    await tester.tap(find.text('Повторить'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(queue.publishedCount, 1);
    expect(service.calls, 2);
    expect(find.text('Публикуем запись…'), findsNothing);
    expect(find.text('Повторить'), findsNothing);
  });

  testWidgets('«Убрать» отпускает упавшую публикацию', (tester) async {
    final service = _GatedPostService()
      ..nextError = const CustomApiException('Сеть недоступна');
    final queue = PostPublishQueue.memory(
        postService: service, currentUserId: () => 'user-1');
    GetIt.I.registerSingleton<PostPublishQueue>(queue);

    await tester.pumpWidget(host());
    unawaited(queue.enqueue(treeId: 'tree-1', content: 'Запись'));
    service.gate.complete();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Повторить'), findsOneWidget);

    await tester.tap(find.byTooltip('Убрать'));
    await tester.pump(const Duration(milliseconds: 20));
    expect(queue.items, isEmpty);
    expect(find.text('Повторить'), findsNothing);
  });
}
