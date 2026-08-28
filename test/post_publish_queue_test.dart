// Шаг 5 bulk-upload: фоновая очередь публикации постов поверх
// PendingSendQueue (извлечённого из чата ядра). Проверяем контракт очереди:
// enqueue → createPost со всеми параметрами composer'а, живой прогресс,
// авто-удаление после успеха, failed+retry с тем же снимком, автоповтор
// при возврате сети и восстановление из Hive после «kill приложения».
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:image_picker/image_picker.dart';
import 'package:rodnya/backend/interfaces/post_service_interface.dart';
import 'package:rodnya/models/media_upload_progress.dart';
import 'package:rodnya/models/pending_post_publish.dart';
import 'package:rodnya/models/post.dart';
import 'package:rodnya/services/app_status_service.dart';
import 'package:rodnya/services/custom_api_auth_service.dart';
import 'package:rodnya/services/post_publish_queue.dart';

class _CreatePostRequest {
  const _CreatePostRequest({
    required this.treeId,
    required this.content,
    required this.images,
    required this.isPublic,
    required this.scopeType,
    required this.anchorPersonIds,
    required this.circleId,
    required this.branchIds,
  });

  final String treeId;
  final String content;
  final List<XFile> images;
  final bool isPublic;
  final TreeContentScopeType scopeType;
  final List<String> anchorPersonIds;
  final String? circleId;
  final List<String>? branchIds;
}

class _FakePostService implements PostServiceInterface {
  final List<_CreatePostRequest> requests = <_CreatePostRequest>[];
  Object? nextError;
  int progressSteps = 0;

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
    void Function(MediaUploadProgress progress)? onProgress,
  }) async {
    requests.add(_CreatePostRequest(
      treeId: treeId,
      content: content,
      images: images,
      isPublic: isPublic,
      scopeType: scopeType,
      anchorPersonIds: anchorPersonIds,
      circleId: circleId,
      branchIds: branchIds,
    ));
    for (var i = 1; i <= progressSteps; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
      onProgress?.call(MediaUploadProgress(
        stage: MediaUploadStage.uploading,
        completed: i,
        total: progressSteps,
      ));
    }
    final error = nextError;
    if (error != null) {
      throw error;
    }
    return Post(
      id: 'post-${requests.length}',
      treeId: treeId,
      authorId: 'user-1',
      authorName: 'Автор',
      content: content,
      imageUrls: List<String>.generate(
        images.length,
        (i) => 'https://cdn/img-$i.jpg',
      ),
      createdAt: DateTime(2026, 8, 28),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('условие не выполнилось за 5 секунд');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory hiveDirectory;
  var boxCounter = 0;

  setUpAll(() {
    hiveDirectory = Directory.systemTemp.createTempSync(
      'rodnya_post_publish_queue_test_',
    );
    Hive.init(hiveDirectory.path);
  });

  tearDownAll(() async {
    await Hive.close();
    if (hiveDirectory.existsSync()) {
      await hiveDirectory.delete(recursive: true);
    }
  });

  String nextBoxName() {
    boxCounter += 1;
    final boxName = 'post_publish_queue_test_$boxCounter';
    addTearDown(() async {
      if (Hive.isBoxOpen(boxName)) {
        await Hive.box<String>(boxName).close();
      }
      try {
        await Hive.deleteBoxFromDisk(boxName);
      } catch (_) {
        // The box may not have been opened by a failed test.
      }
    });
    return boxName;
  }

  test('успешная публикация: полный снимок composer\'а доходит до createPost, '
      'элемент убирается, publishedCount растёт', () async {
    final service = _FakePostService();
    final queue = PostPublishQueue.memory(postService: service);
    addTearDown(queue.dispose);

    final post = await queue.enqueue(
      treeId: 'tree-1',
      content: 'Отпуск!',
      files: [XFile('/tmp/a.jpg'), XFile('/tmp/b.jpg')],
      isPublic: true,
      scopeType: TreeContentScopeType.branches,
      anchorPersonIds: const ['p-1'],
      circleId: 'circle-1',
      branchIds: const ['tree-1', 'tree-2'],
    );
    expect(post.status, PendingPostPublishStatus.pending);
    expect(queue.hasWork, isTrue);

    await _waitUntil(() => queue.publishedCount == 1);
    await _waitUntil(() => queue.items.isEmpty);

    final request = service.requests.single;
    expect(request.treeId, 'tree-1');
    expect(request.content, 'Отпуск!');
    expect(request.images, hasLength(2));
    expect(request.isPublic, isTrue);
    expect(request.scopeType, TreeContentScopeType.branches);
    expect(request.anchorPersonIds, ['p-1']);
    expect(request.circleId, 'circle-1');
    expect(request.branchIds, ['tree-1', 'tree-2']);
  });

  test('прогресс из createPost виден на элементе очереди', () async {
    final service = _FakePostService()..progressSteps = 3;
    final queue = PostPublishQueue.memory(postService: service);
    addTearDown(queue.dispose);

    final seen = <int>[];
    queue.addListener(() {
      final items = queue.items;
      if (items.isNotEmpty && items.single.progress != null) {
        seen.add(items.single.progress!.completed);
      }
    });

    await queue.enqueue(
      treeId: 'tree-1',
      content: '',
      files: [XFile('/tmp/a.jpg'), XFile('/tmp/b.jpg'), XFile('/tmp/c.jpg')],
    );
    await _waitUntil(() => queue.publishedCount == 1);

    expect(seen.where((completed) => completed > 0), containsAllInOrder([1, 2, 3]));
  });

  test('провал → failed с текстом; retry переиспользует тот же снимок',
      () async {
    final service = _FakePostService()
      ..nextError = const CustomApiException('Сеть недоступна');
    final queue = PostPublishQueue.memory(postService: service);
    addTearDown(queue.dispose);

    final post = await queue.enqueue(
      treeId: 'tree-1',
      content: 'Не уйдёт',
      files: [XFile('/tmp/a.jpg')],
    );
    await _waitUntil(
      () =>
          queue.items.isNotEmpty &&
          queue.items.single.status == PendingPostPublishStatus.failed,
    );
    expect(queue.items.single.errorText, 'Сеть недоступна');

    service.nextError = null;
    await queue.retry(post.localId);
    await _waitUntil(() => queue.publishedCount == 1);

    expect(service.requests, hasLength(2));
    expect(service.requests.last.content, 'Не уйдёт');
    expect(queue.items, isEmpty);
  });

  test('S4-паттерн: офлайн кладёт в очередь, возврат сети публикует сам',
      () async {
    final appStatus = AppStatusService();
    addTearDown(appStatus.dispose);
    appStatus.debugSetOffline(true);

    final service = _FakePostService()
      ..nextError = const CustomApiException('Сеть недоступна');
    final queue = PostPublishQueue.memory(
      postService: service,
      appStatusService: appStatus,
    );
    addTearDown(queue.dispose);

    await queue.enqueue(treeId: 'tree-1', content: 'Из самолёта');
    await _waitUntil(
      () =>
          queue.items.isNotEmpty &&
          queue.items.single.status == PendingPostPublishStatus.failed,
    );
    expect(service.requests, hasLength(1));

    service.nextError = null;
    appStatus.debugSetOffline(false);
    await _waitUntil(() => queue.publishedCount == 1);
    expect(service.requests, hasLength(2));
    expect(queue.items, isEmpty);
  });

  test('kill приложения: pending-пост восстанавливается из Hive и уходит сам',
      () async {
    final boxName = nextBoxName();
    final failingService = _FakePostService()
      ..nextError = const CustomApiException('offline');
    final firstQueue = PostPublishQueue(
      postService: failingService,
      boxName: boxName,
    );

    await firstQueue.enqueue(
      treeId: 'tree-1',
      content: 'Переживу перезапуск',
      files: [XFile('/tmp/a.jpg')],
    );
    await _waitUntil(
      () =>
          firstQueue.items.isNotEmpty &&
          firstQueue.items.single.status == PendingPostPublishStatus.failed,
    );
    // Дождаться unawaited-персиста failed-состояния.
    await _waitUntil(
      () =>
          Hive.isBoxOpen(boxName) &&
          (Hive.box<String>(boxName).get('posts') ?? '').contains('failed'),
    );
    firstQueue.dispose();

    // «Перезапуск»: новая очередь над тем же box'ом. failed не автостартует
    // (нет pending и нет события сети) — но retry доступен и доносит пост.
    final service = _FakePostService();
    final queue = PostPublishQueue(postService: service, boxName: boxName);
    addTearDown(queue.dispose);
    await queue.restore();

    expect(queue.items, hasLength(1));
    final restored = queue.items.single;
    expect(restored.status, PendingPostPublishStatus.failed);
    expect(restored.content, 'Переживу перезапуск');
    expect(restored.files.single.path, '/tmp/a.jpg');

    await queue.retry(restored.localId);
    await _waitUntil(() => queue.publishedCount == 1);
    expect(service.requests.single.content, 'Переживу перезапуск');
    expect(queue.items, isEmpty);
  });
}
