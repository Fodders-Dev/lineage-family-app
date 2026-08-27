/// Прогресс пакетной загрузки медиа (посты, альбом семьи).
///
/// Пофайловый счётчик нужен там, где пользователь ждёт долго и без обратной
/// связи начинает думать, что приложение зависло: 30 фото поездки грузятся
/// заметно дольше одной аватарки.
///
/// Чат считает свой прогресс через [ChatSendProgress] (`chat_send_progress.dart`)
/// — модель-двойник. Объединить их предстоит в шаге 5 плана массовой загрузки,
/// когда очередь отправки чата станет общим `MediaUploadQueue`; до тех пор
/// посты не тянут за собой чатовую модель.
enum MediaUploadStage {
  /// Файлы выбраны, загрузка ещё не началась.
  preparing,

  /// Часть файлов уже на сервере — `completed` из `total`.
  uploading,

  /// Файлы загружены, публикуется сама запись.
  publishing,
}

class MediaUploadProgress {
  const MediaUploadProgress({
    required this.stage,
    required this.completed,
    required this.total,
  });

  final MediaUploadStage stage;
  final int completed;
  final int total;

  /// Доля для детерминированного бара, либо null — когда честнее показать
  /// неопределённый (анимированный) индикатор.
  ///
  /// Как и в чате: у одного файла нет гранулярности (он висит на нуле до
  /// самого конца), а `completed == 0` выглядит замершим прогрессом.
  double? get value {
    if (total <= 1 || completed <= 0) {
      return null;
    }
    final normalized = completed.clamp(0, total);
    return normalized / total;
  }

  @override
  String toString() =>
      'MediaUploadProgress(${stage.name}, $completed/$total)';
}
