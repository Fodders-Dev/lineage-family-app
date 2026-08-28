import 'dart:async';

import 'package:image_picker/image_picker.dart';

import '../backend/interfaces/post_service_interface.dart';
import '../models/media_upload_progress.dart';
import '../models/pending_post_publish.dart';
import '../models/post.dart';
import 'custom_api_auth_service.dart';
import 'pending_send_queue.dart';

/// Фоновая очередь публикации постов (шаг 5 bulk-upload): «Опубликовать»
/// ставит пост сюда и сразу отпускает человека; пачка грузится в фоне
/// (createPost внутри держит пул из 4 воркеров), при возврате сети упавшие
/// публикации уходят сами, kill приложения переживается через Hive.
///
/// Отличие от чатовой очереди: у постов нет серверного echo с
/// clientMessageId, поэтому успешно опубликованный элемент убирается сразу
/// ([onItemSent]) — подтверждение для человека — сам пост в ленте.
/// Оставшееся окно двойной публикации (kill строго между ACK сервера и
/// Hive-персистом удаления) — миллисекунды; честный фикс — идемпотентный
/// ключ на бэкенде, отложен сознательно.
class PostPublishQueue extends PendingSendQueue<PendingPostPublish> {
  PostPublishQueue({
    required PostServiceInterface postService,
    super.appStatusService,
    String boxName = 'post_publish_queue_v1',
  })  : _postService = postService,
        super(boxName: boxName);

  PostPublishQueue.memory({
    required PostServiceInterface postService,
    super.appStatusService,
  })  : _postService = postService,
        super(boxName: null);

  /// Посты не шардируются по чатам — одна корзина на всё приложение.
  static const String _bucket = 'posts';

  final PostServiceInterface _postService;

  /// Сколько постов дошло до сервера за сессию — слушатели ленты
  /// перечитывают её, когда счётчик растёт (сам элемент к этому моменту
  /// уже убран из очереди).
  int get publishedCount => _publishedCount;
  int _publishedCount = 0;

  List<PendingPostPublish> get items => itemsFor(_bucket);

  bool get hasWork => items.isNotEmpty;

  /// Восстановить очередь из Hive (вызывается на старте приложения);
  /// pending-посты уходят сами. Осиротевшие sent (kill в окне между ACK и
  /// персистом удаления) убираются — пост уже на сервере.
  Future<void> restore() async {
    await restoreKey(_bucket);
    for (final item in items) {
      if (item.status == PendingPostPublishStatus.sent) {
        unawaited(removeItem(_bucket, item.localId));
      }
    }
  }

  Future<PendingPostPublish> enqueue({
    required String treeId,
    required String content,
    List<XFile> files = const <XFile>[],
    bool isPublic = false,
    TreeContentScopeType scopeType = TreeContentScopeType.wholeTree,
    List<String> anchorPersonIds = const <String>[],
    String? circleId,
    List<String>? branchIds,
  }) async {
    final normalizedTreeId = treeId.trim();
    if (normalizedTreeId.isEmpty) {
      throw StateError('Дерево недоступно');
    }
    if (content.trim().isEmpty && files.isEmpty) {
      throw StateError('Запись не должна быть пустой');
    }

    await restore();

    final post = PendingPostPublish(
      localId: newLocalId(),
      treeId: normalizedTreeId,
      content: content,
      timestamp: DateTime.now(),
      files: List<XFile>.from(files),
      status: PendingPostPublishStatus.pending,
      isPublic: isPublic,
      scopeType: scopeType,
      anchorPersonIds: List<String>.from(anchorPersonIds),
      circleId: circleId,
      branchIds: branchIds,
      progress: files.isNotEmpty
          ? MediaUploadProgress(
              stage: MediaUploadStage.preparing,
              completed: 0,
              total: files.length,
            )
          : const MediaUploadProgress(
              stage: MediaUploadStage.publishing,
              completed: 1,
              total: 1,
            ),
    );
    addAndSend(post);
    return post;
  }

  Future<void> retry(String localId) => retryItem(_bucket, localId);

  Future<void> remove(String localId) => removeItem(_bucket, localId);

  @override
  String itemKey(PendingPostPublish item) => _bucket;

  @override
  String itemId(PendingPostPublish item) => item.localId;

  @override
  DateTime itemTimestamp(PendingPostPublish item) => item.timestamp;

  @override
  bool isItemPending(PendingPostPublish item) =>
      item.status == PendingPostPublishStatus.pending;

  @override
  bool isItemFailed(PendingPostPublish item) =>
      item.status == PendingPostPublishStatus.failed;

  @override
  PendingPostPublish markItemSent(PendingPostPublish item) => item.copyWith(
        status: PendingPostPublishStatus.sent,
        errorText: null,
      );

  @override
  PendingPostPublish markItemFailed(
    PendingPostPublish item,
    String errorText,
  ) =>
      item.copyWith(
        status: PendingPostPublishStatus.failed,
        errorText: errorText,
      );

  @override
  PendingPostPublish prepareItemForRetry(PendingPostPublish item) =>
      item.copyWith(
        status: PendingPostPublishStatus.pending,
        progress: item.files.isNotEmpty
            ? MediaUploadProgress(
                stage: MediaUploadStage.preparing,
                completed: 0,
                total: item.files.length,
              )
            : const MediaUploadProgress(
                stage: MediaUploadStage.publishing,
                completed: 1,
                total: 1,
              ),
        errorText: null,
      );

  @override
  Map<String, dynamic> itemToJson(PendingPostPublish item) => item.toJson();

  @override
  PendingPostPublish itemFromJson(Map<String, dynamic> json) =>
      PendingPostPublish.fromJson(json);

  @override
  Future<void> performSend(PendingPostPublish item) {
    return _postService.createPost(
      treeId: item.treeId,
      content: item.content,
      images: item.files,
      isPublic: item.isPublic,
      scopeType: item.scopeType,
      anchorPersonIds: item.anchorPersonIds,
      circleId: item.circleId,
      branchIds: item.branchIds,
      onProgress: (progress) {
        transformItem(
          _bucket,
          item.localId,
          (post) => post.copyWith(progress: progress),
        );
      },
    );
  }

  /// Потолок честности «публикуем…»: базовые 45с как у чата с вложениями
  /// плюс запас на каждый файл (пул из 4 воркеров, но сеть может быть
  /// медленной), не больше 10 минут.
  @override
  Duration sendTimeoutFor(PendingPostPublish item) {
    final seconds = 45 + 15 * item.files.length;
    return Duration(seconds: seconds > 600 ? 600 : seconds);
  }

  @override
  String errorTextFor(Object error) {
    if (error is TimeoutException) {
      return 'Не дождались ответа сервера. Нажмите, чтобы повторить.';
    }
    if (error is CustomApiException && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    if (error is UnsupportedError && error.message?.trim().isNotEmpty == true) {
      return error.message!.trim();
    }
    return 'Не удалось опубликовать запись.';
  }

  @override
  String get perfTraceLabel => 'post.publish-to-ack';

  @override
  void onItemSent(PendingPostPublish item) {
    _publishedCount += 1;
    // removeItem сам делает notify+persist — слушатели увидят и рост
    // publishedCount, и опустевшую очередь одним кадром.
    unawaited(removeItem(_bucket, item.localId));
  }
}
