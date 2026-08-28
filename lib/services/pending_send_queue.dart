import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import 'app_status_service.dart';
import '../utils/perf_log.dart';

/// Генерик-ядро исходящей очереди «положил — ушло само»: in-memory списки
/// по ключу (у чата ключ — chatId, у постов — одна корзина), Hive как
/// recovery-файл, дедуп in-flight отправок и автоповтор упавших элементов
/// при возврате сети.
///
/// Извлечено из [ChatSendQueue] ровно в том виде, в каком его механика
/// прожила в чате (SPEED-1 и оффлайн-ретрай): поведение чата обязано
/// оставаться байт-в-байт прежним, поэтому здесь сохранены и тонкости:
/// - notify ДО дисковой записи (пузырь появляется в кадре тапа; Hive — не
///   источник правды для UI, last-write-wins);
/// - success/failure апсертят ИСХОДНЫЙ элемент (не последний прогресс) —
///   так делал чат, и UI на это рассчитан;
/// - существование элемента перепроверяется после каждого await (элемент
///   могли удалить, пока шла отправка).
///
/// Подкласс отвечает за модель: доступ к полям ([itemKey]/[itemId]/
/// [itemTimestamp]), статусные переходы ([markItemSent]/[markItemFailed]/
/// [prepareItemForRetry]), сериализацию и саму отправку ([performSend]).
abstract class PendingSendQueue<T> extends ChangeNotifier {
  PendingSendQueue({
    required this.boxName,
    AppStatusService? appStatusService,
  }) : _appStatusService = appStatusService {
    _bindAppStatusService();
  }

  /// null — только память, без Hive (экран без залогиненного бэкенда).
  final String? boxName;
  final AppStatusService? _appStatusService;

  final Map<String, List<T>> _itemsByKey = <String, List<T>>{};
  final Map<String, Future<void>> _restoreTasks = <String, Future<void>>{};
  final Set<String> _inFlightIds = <String>{};
  Future<Box<String>>? _openTask;
  int _localCounter = 0;
  bool _isDisposed = false;
  bool _wasOffline = false;

  // ---- контракт подкласса -------------------------------------------------

  /// Корзина элемента (chatId / константа очереди постов).
  @protected
  String itemKey(T item);

  /// Локальный id элемента (он же clientMessageId у чата).
  @protected
  String itemId(T item);

  @protected
  DateTime itemTimestamp(T item);

  /// pending — элемент ждёт отправки (авто-досыл при restore).
  @protected
  bool isItemPending(T item);

  /// failed — кандидат на автоповтор при возврате сети.
  @protected
  bool isItemFailed(T item);

  @protected
  T markItemSent(T item);

  @protected
  T markItemFailed(T item, String errorText);

  /// Сбросить статус/прогресс перед повторной отправкой.
  @protected
  T prepareItemForRetry(T item);

  @protected
  Map<String, dynamic> itemToJson(T item);

  @protected
  T itemFromJson(Map<String, dynamic> json);

  /// Сама отправка (сервисный вызов). Прогресс подкласс прокидывает через
  /// [transformItem] из своего onProgress-колбэка.
  @protected
  Future<void> performSend(T item);

  @protected
  Duration sendTimeoutFor(T item);

  /// Человекочитаемый текст ошибки для [markItemFailed].
  @protected
  String errorTextFor(Object error);

  /// Метка PerfTrace для замера send-to-ack.
  @protected
  String get perfTraceLabel;

  /// Хук после успешной отправки (элемент уже помечен sent, notify и
  /// persist сделаны). База — no-op: чат держит sent-элементы до серверного
  /// echo (confirmRemoteMessages); очередь постов, где echo нет, убирает
  /// элемент сразу.
  @protected
  void onItemSent(T item) {}

  /// Пропускать ли элемент в отправку. База — всегда да; очередь постов
  /// отвечает «нет» для элементов чужого пользователя (общее устройство:
  /// A вышел, B вошёл — черновики A молча ждут возвращения A, авто-ретраи
  /// и restore не должны публиковать их под токеном B).
  @protected
  bool shouldSendItem(T item) => true;

  // ---- связь с сетевым статусом ------------------------------------------

  /// Binds to [AppStatusService] (when supplied) so we can auto-retry
  /// failed messages the moment connectivity is restored. Without this
  /// the user has to manually tap "Повторить" on each failed bubble
  /// after the network returns — which is what the user noticed
  /// during the offline test.
  void _bindAppStatusService() {
    final svc = _appStatusService;
    if (svc == null) return;
    _wasOffline = svc.isOffline;
    svc.addListener(_handleAppStatusChanged);
  }

  void _handleAppStatusChanged() {
    final svc = _appStatusService;
    if (svc == null || _isDisposed) return;
    final isOffline = svc.isOffline;
    final cameBackOnline = _wasOffline && !isOffline;
    _wasOffline = isOffline;
    if (cameBackOnline) {
      // Connectivity restored — retry every failed message across
      // every bucket we've touched in this session. sendItem() handles
      // the in-flight de-dup, so racing this with a manual retry
      // is safe.
      for (final entry in _itemsByKey.entries) {
        for (final item in entry.value) {
          if (isItemFailed(item)) {
            unawaited(retryItem(itemKey(item), itemId(item)));
          }
        }
      }
    }
  }

  // ---- хранилище ----------------------------------------------------------

  Future<Box<String>?> _box() {
    final resolvedBoxName = boxName;
    if (resolvedBoxName == null) {
      return Future<Box<String>?>.value(null);
    }
    if (Hive.isBoxOpen(resolvedBoxName)) {
      return Future<Box<String>?>.value(Hive.box<String>(resolvedBoxName));
    }
    return (_openTask ??= Hive.openBox<String>(resolvedBoxName))
        .then<Box<String>?>((box) => box);
  }

  List<T> itemsFor(String key) {
    return List<T>.unmodifiable(_itemsByKey[key] ?? <T>[]);
  }

  /// Восстановить корзину из Hive (однократно на ключ) и досослать pending.
  ///
  /// Возвращает Future ПЕРВОЙ загрузки ключа: повторный вызов ждёт её
  /// завершения, а не выходит сразу. Иначе гонка: enqueue во время
  /// незавершённого restore добавлял элемент в память, а догнавшая загрузка
  /// присваивала список из Hive поверх — свежий элемент терялся из памяти и
  /// из следующего персиста (латентно жило и в чате с самого начала).
  Future<void> restoreKey(String key) {
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) {
      return Future<void>.value();
    }
    return _restoreTasks.putIfAbsent(
      normalizedKey,
      () => _restoreKeyOnce(normalizedKey),
    );
  }

  Future<void> _restoreKeyOnce(String normalizedKey) async {
    Box<String>? box;
    try {
      box = await _box();
    } catch (_) {
      // Битый box-файл или недоступное хранилище (web в приватном режиме):
      // очередь честно деградирует в memory-only. Ошибку не пробрасываем —
      // restore зовут и unawaited на старте, необработанный reject уронил бы
      // zone; персисты и так best-effort (_persistKeySafely).
      _itemsByKey.putIfAbsent(normalizedKey, () => <T>[]);
      return;
    }
    final rawValue = box?.get(normalizedKey);
    if (rawValue == null || rawValue.trim().isEmpty) {
      _itemsByKey.putIfAbsent(normalizedKey, () => <T>[]);
      return;
    }

    try {
      final decoded = jsonDecode(rawValue);
      if (decoded is List<dynamic>) {
        final items = _sortedItems(
          decoded
              .whereType<Map>()
              .map((entry) => itemFromJson(Map<String, dynamic>.from(entry)))
              .where((item) =>
                  itemKey(item) == normalizedKey &&
                  itemId(item).trim().isNotEmpty)
              .toList(growable: false),
        );
        _itemsByKey[normalizedKey] = items;
        _notify();
        for (final item in items) {
          if (isItemPending(item)) {
            unawaited(sendItem(item));
          }
        }
      }
    } catch (_) {
      _itemsByKey[normalizedKey] = <T>[];
    }
  }

  // ---- жизненный цикл элемента -------------------------------------------

  /// Поставить уже сконструированный элемент в очередь и запустить отправку.
  /// Вызывающий обязан сначала await [restoreKey] (как делал enqueue чата:
  /// restore → построение элемента → постановка, чтобы timestamp нового
  /// элемента был позже восстановленных).
  @protected
  void addAndSend(T item) {
    _upsert(item);
    // SPEED-1: пузырь должен появиться в кадре тапа — notify ДО дисковой
    // записи. Hive здесь — только recovery-файл (переживает kill приложения),
    // не источник правды для UI: in-memory состояние уже консистентно, а
    // _persistKey кодирует свежайшее состояние в момент выполнения, так что
    // unawaited-персисты безопасны (last-write-wins).
    _notify();
    unawaited(_persistKeySafely(itemKey(item)));
    unawaited(sendItem(item));
  }

  Future<void> retryItem(String key, String id) async {
    final item = findItem(key, id);
    if (item == null || !shouldSendItem(item)) {
      // Чужой элемент не переводим в pending: авто-ретрай при возврате
      // сети не должен ни отправлять его, ни маскировать failed-статус —
      // автор вернётся и увидит честное «Повторить».
      return;
    }
    final nextItem = prepareItemForRetry(item);
    _upsert(nextItem);
    _notify();
    unawaited(_persistKeySafely(key));
    await sendItem(nextItem);
  }

  Future<void> removeItem(String key, String id) async {
    final items = List<T>.from(_itemsByKey[key] ?? <T>[])
      ..removeWhere((item) => itemId(item) == id);
    _itemsByKey[key] = _sortedItems(items);
    _notify();
    unawaited(_persistKeySafely(key));
  }

  /// Заменить корзину как есть (без пересортировки) — для серверного
  /// echo-дедупа чата. notify+persist как у прочих мутаций.
  @protected
  void replaceItems(String key, List<T> items) {
    _itemsByKey[key] = items;
    _notify();
    unawaited(_persistKeySafely(key));
  }

  /// Точечно преобразовать элемент (прогресс из onProgress-колбэка).
  /// Элемента нет — no-op.
  @protected
  void transformItem(String key, String id, T Function(T item) transform) {
    final item = findItem(key, id);
    if (item == null) {
      return;
    }
    _upsert(transform(item));
    _notify();
    unawaited(_persistKeySafely(key));
  }

  @protected
  Future<void> sendItem(T item) async {
    final key = itemKey(item);
    final id = itemId(item);
    if (!itemExists(key, id) ||
        !shouldSendItem(item) ||
        !_inFlightIds.add(id)) {
      return;
    }

    // S1: отправка до ACK сервера.
    final sendTrace = PerfTrace(perfTraceLabel);
    try {
      await performSend(item).timeout(sendTimeoutFor(item));
      sendTrace.finish();
      if (!itemExists(key, id)) {
        return;
      }
      _upsert(markItemSent(item));
      _notify();
      unawaited(_persistKeySafely(key));
      onItemSent(item);
    } catch (error) {
      sendTrace.cancel();
      if (!itemExists(key, id)) {
        return;
      }
      _upsert(markItemFailed(item, errorTextFor(error)));
      _notify();
      unawaited(_persistKeySafely(key));
    } finally {
      _inFlightIds.remove(id);
    }
  }

  @protected
  T? findItem(String key, String id) {
    for (final item in _itemsByKey[key] ?? <T>[]) {
      if (itemId(item) == id) {
        return item;
      }
    }
    return null;
  }

  @protected
  bool itemExists(String key, String id) {
    return findItem(key, id) != null;
  }

  void _upsert(T item) {
    final items = List<T>.from(_itemsByKey[itemKey(item)] ?? <T>[]);
    final index = items.indexWhere(
      (existing) => itemId(existing) == itemId(item),
    );
    if (index == -1) {
      items.add(item);
    } else {
      items[index] = item;
    }
    _itemsByKey[itemKey(item)] = _sortedItems(items);
  }

  /// SPEED-1: обёртка для unawaited-персистов — ошибка диска не должна
  /// уронить zone (Hive тут recovery-файл, не источник правды для UI).
  Future<void> _persistKeySafely(String key) async {
    try {
      await _persistKey(key);
    } catch (_) {
      // Best-effort: очередь уже консистентна в памяти; recovery-файл
      // догонит на следующем персисте.
    }
  }

  Future<void> _persistKey(String key) async {
    final box = await _box();
    if (box == null) {
      return;
    }
    final items = _itemsByKey[key] ?? <T>[];
    if (items.isEmpty) {
      await box.delete(key);
      return;
    }
    await box.put(
      key,
      jsonEncode(items.map(itemToJson).toList()),
    );
  }

  @protected
  String newLocalId() {
    _localCounter += 1;
    return 'local-${DateTime.now().microsecondsSinceEpoch}-$_localCounter';
  }

  List<T> _sortedItems(List<T> items) {
    final sortedItems = items.toList();
    sortedItems.sort((left, right) {
      final timestampCompare =
          itemTimestamp(right).compareTo(itemTimestamp(left));
      if (timestampCompare != 0) {
        return timestampCompare;
      }
      return itemId(right).compareTo(itemId(left));
    });
    return sortedItems;
  }

  void _notify() {
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _appStatusService?.removeListener(_handleAppStatusChanged);
    super.dispose();
  }
}
