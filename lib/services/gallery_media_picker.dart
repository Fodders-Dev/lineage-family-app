import 'package:image_picker/image_picker.dart';

/// Сколько медиа влезает в один пост. Ровно столько же принимает бэкенд
/// (`enforceArrayCap(imageUrls, max: 30)` в routes/post-routes.js) — клиент
/// раньше резал на 5 и заставлял разбивать поездку на восемь постов.
/// Каждый файл уходит своим запросом `/v1/media/upload`, поэтому лимит тела
/// (50 МБ) считается ПОФАЙЛОВО и пачкой не набирается.
const int kMaxPostMedia = 30;

/// Общий мультивыбор медиа из галереи для ленты и «Альбома семьи».
///
/// Раньше эта логика жила только в composer'е ленты, и альбом остался без
/// точки входа: чтобы фото попали в альбом, приходилось идти через создание
/// поста. Теперь оба экрана зовут один пикер с одинаковым сжатием
/// (`imageQuality: 80`, `maxWidth: 1080` — ~150-400 КБ на фото) и одинаковым
/// фолбэком там, где мультивыбор медиа не поддерживается.
class GalleryMediaPicker {
  const GalleryMediaPicker({ImagePicker? picker}) : _injected = picker;

  final ImagePicker? _injected;

  ImagePicker get _picker => _injected ?? ImagePicker();

  /// Возвращает выбранные файлы (пустой список — если человек передумал).
  ///
  /// [limit] — сколько файлов оставить; лишние отбрасываются вызывающим
  /// экраном вместе с показом уведомления (у ленты и альбома разный UI).
  Future<List<XFile>> pickMultiple() async {
    try {
      // pickMultipleMedia даёт выбрать фото И видео за один заход галереи —
      // ближе к тому, как это делают Telegram/Instagram.
      return await _picker.pickMultipleMedia(
        imageQuality: 80,
        maxWidth: 1080,
      );
    } on UnsupportedError {
      // На macOS/web мультивыбор медиа не поддержан — падаем на
      // фото-только путь. Сюда же попадает MissingPluginException
      // (подтип UnsupportedError на платформах без канала).
      return _picker.pickMultiImage(
        imageQuality: 80,
        maxWidth: 1080,
      );
    }
  }
}
