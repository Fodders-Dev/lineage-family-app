import 'package:image_picker/image_picker.dart';

import 'media_upload_progress.dart';
import 'post.dart';

enum PendingPostPublishStatus { pending, sent, failed }

/// Пост, поставленный в фоновую очередь публикации (шаг 5 bulk-upload):
/// «Опубликовать» больше не держит человека на экране — снимок всех
/// параметров composer'а уезжает сюда и переживает kill приложения
/// (Hive хранит пути к файлам, как у чата).
class PendingPostPublish {
  const PendingPostPublish({
    required this.localId,
    required this.userId,
    required this.treeId,
    required this.content,
    required this.timestamp,
    required this.files,
    required this.status,
    this.isPublic = false,
    this.scopeType = TreeContentScopeType.wholeTree,
    this.anchorPersonIds = const <String>[],
    this.circleId,
    this.branchIds,
    this.progress,
    this.errorText,
  });

  final String localId;

  /// Кто ставил в очередь. Очередь общая на устройство, а публикация идёт
  /// под текущим токеном — без этого поля пост юзера A мог уйти под B
  /// после смены аккаунта (авто-ретрай/restore). Чужие элементы не
  /// отправляются и не показываются, пока их автор не вернётся.
  final String userId;
  final String treeId;
  final String content;
  final DateTime timestamp;
  final List<XFile> files;
  final PendingPostPublishStatus status;
  final bool isPublic;
  final TreeContentScopeType scopeType;
  final List<String> anchorPersonIds;
  final String? circleId;

  /// Phase 3.4: null — легаси-дефолт одной ветки (см. createPost).
  final List<String>? branchIds;
  final MediaUploadProgress? progress;
  final String? errorText;

  /// Семантика как у ChatPendingMessage.copyWith: errorText присваивается
  /// напрямую (null очищает ошибку), статус/прогресс — с фолбэком.
  PendingPostPublish copyWith({
    PendingPostPublishStatus? status,
    MediaUploadProgress? progress,
    String? errorText,
  }) {
    return PendingPostPublish(
      localId: localId,
      userId: userId,
      treeId: treeId,
      content: content,
      timestamp: timestamp,
      files: files,
      status: status ?? this.status,
      isPublic: isPublic,
      scopeType: scopeType,
      anchorPersonIds: anchorPersonIds,
      circleId: circleId,
      branchIds: branchIds,
      progress: progress ?? this.progress,
      errorText: errorText,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'localId': localId,
      'userId': userId,
      'treeId': treeId,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'files': files.map(_xFileToJson).toList(growable: false),
      'status': status.name,
      'isPublic': isPublic,
      'scopeType': scopeType.name,
      'anchorPersonIds': anchorPersonIds,
      if (circleId != null) 'circleId': circleId,
      if (branchIds != null) 'branchIds': branchIds,
      if (progress != null) 'progress': _progressToJson(progress!),
      if (errorText != null && errorText!.trim().isNotEmpty)
        'errorText': errorText,
    };
  }

  factory PendingPostPublish.fromJson(Map<String, dynamic> json) {
    final status = PendingPostPublishStatus.values.firstWhere(
      (value) => value.name == json['status']?.toString(),
      orElse: () => PendingPostPublishStatus.failed,
    );
    final scopeType = TreeContentScopeType.values.firstWhere(
      (value) => value.name == json['scopeType']?.toString(),
      orElse: () => TreeContentScopeType.wholeTree,
    );
    return PendingPostPublish(
      localId: json['localId']?.toString() ?? '',
      userId: json['userId']?.toString() ?? '',
      treeId: json['treeId']?.toString() ?? '',
      content: json['content']?.toString() ?? '',
      timestamp: DateTime.tryParse(json['timestamp']?.toString() ?? '') ??
          DateTime.now(),
      files: _xFilesFromJson(json['files']),
      status: status,
      isPublic: json['isPublic'] == true,
      scopeType: scopeType,
      anchorPersonIds: _stringList(json['anchorPersonIds']),
      circleId: json['circleId']?.toString(),
      branchIds:
          json['branchIds'] is List ? _stringList(json['branchIds']) : null,
      progress: _progressFromJson(json['progress']),
      errorText: json['errorText']?.toString(),
    );
  }

  // XFile-сериализация — тот же формат, что у ChatPendingMessage (пути в
  // Hive, mimeType опционален); хелперы там приватные, поэтому продублированы.
  static Map<String, dynamic> _xFileToJson(XFile file) {
    return <String, dynamic>{
      'path': file.path,
      'name': file.name,
      if (file.mimeType != null && file.mimeType!.isNotEmpty)
        'mimeType': file.mimeType,
    };
  }

  static List<XFile> _xFilesFromJson(dynamic raw) {
    if (raw is! List<dynamic>) {
      return const <XFile>[];
    }
    return raw
        .whereType<Map>()
        .map((entry) => Map<String, dynamic>.from(entry))
        .map((entry) {
          final filePath = entry['path']?.toString() ?? '';
          if (filePath.trim().isEmpty) {
            return null;
          }
          return XFile(
            filePath,
            name: entry['name']?.toString(),
            mimeType: entry['mimeType']?.toString(),
          );
        })
        .whereType<XFile>()
        .toList(growable: false);
  }

  static Map<String, dynamic> _progressToJson(MediaUploadProgress progress) {
    return <String, dynamic>{
      'stage': progress.stage.name,
      'completed': progress.completed,
      'total': progress.total,
    };
  }

  static MediaUploadProgress? _progressFromJson(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(raw);
    final stage = MediaUploadStage.values.firstWhere(
      (value) => value.name == map['stage']?.toString(),
      orElse: () => MediaUploadStage.publishing,
    );
    return MediaUploadProgress(
      stage: stage,
      completed: _asInt(map['completed']) ?? 0,
      total: _asInt(map['total']) ?? 1,
    );
  }

  static List<String> _stringList(dynamic raw) {
    if (raw is! List<dynamic>) {
      return const <String>[];
    }
    return raw
        .map((entry) => entry?.toString() ?? '')
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  static int? _asInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '');
  }
}
