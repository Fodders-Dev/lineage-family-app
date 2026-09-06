// ignore_for_file: unused_field
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../utils/user_facing_error.dart';
import '../utils/date_parser.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';

import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/safety_service_interface.dart';
import '../controllers/chat_attachments_controller.dart';
import '../controllers/chat_recording_controller.dart';
import '../controllers/chat_search_controller.dart';
import '../controllers/chat_selection_controller.dart';
import '../controllers/chat_timeline_controller.dart';
import '../models/call_media_mode.dart';
import '../models/chat_attachment.dart';
import '../models/chat_details.dart';
import '../models/chat_message.dart';
import '../models/chat_message_search_result.dart';
import '../models/chat_send_progress.dart';
import '../models/family_tree.dart';
import '../providers/tree_provider.dart';
import '../backend/interfaces/notification_service_interface.dart';
import '../services/active_chat_tracker.dart';
import '../services/app_status_service.dart';
import '../services/call_coordinator_service.dart';
import '../services/chat_auto_delete_store.dart';
import '../services/chat_clipboard_image_paste.dart';
import '../services/chat_details_cache.dart';
import '../services/chat_draft_suppression.dart';
import '../services/chat_draft_store.dart';
import '../services/chat_notification_settings_store.dart';
import '../services/chat_pin_store.dart';
import '../services/chat_send_queue.dart';
import '../services/custom_api_auth_service.dart';
import '../services/custom_api_realtime_service.dart';
import '../theme/app_theme.dart';
import '../widgets/attachment_picker_sheet.dart';
import '../widgets/kruzhok_recorder_screen.dart';
import '../widgets/swipe_to_reply.dart';
import '../utils/chat_attachment_download.dart';
import '../utils/photo_url.dart';
import '../utils/perf_log.dart';
import '../utils/snackbar.dart';
import '../utils/url_utils.dart';
import '../widgets/glass_panel.dart';
import '../widgets/offline_indicator.dart';

part 'chat_screen_state_models.dart';
part 'chat_screen_sections.dart';
part 'chat_screen_supporting_widgets.dart';

typedef OpenDirectChatCallback = void Function({
  required String chatId,
  required String title,
  String? photoUrl,
  String? otherUserId,
});

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    this.chatId,
    this.otherUserId,
    this.title = 'Чат',
    this.photoUrl,
    this.relativeId,
    this.chatType = 'direct',
    this.pickImages,
    this.pickVideo,
    this.draftStore,
    this.pinStore,
    this.notificationSettingsStore,
    this.autoDeleteStore,
    this.initialChatDetails,
    this.recordingController,
    this.embedded = false,
    this.onOpenDirectChat,
    this.clipboardImages,
    this.autoStartCall,
  }) : assert(
          (chatId != null && chatId != '') ||
              (otherUserId != null && otherUserId != ''),
          'Нужен chatId или otherUserId',
        );

  final String? chatId;
  final String? otherUserId;
  final String title;
  final String? photoUrl;
  final String? relativeId;
  final String chatType;
  // GP2: when opened from a chats-list «Позвонить» action, auto-trigger the
  // group-call flow once chat details (candidates) have loaded.
  final CallMediaMode? autoStartCall;
  final Future<List<XFile>> Function()? pickImages;
  final Future<XFile?> Function()? pickVideo;
  final ChatDraftStore? draftStore;
  final ChatPinStore? pinStore;
  final ChatNotificationSettingsStore? notificationSettingsStore;
  final ChatAutoDeleteStore? autoDeleteStore;
  final ChatDetails? initialChatDetails;

  /// C2/тестируемость: позволяет внедрить контроллер записи (с фейковым
  /// рекордером) — тогда recording-бар и его живую волну можно проверить
  /// виджет-тестом. В проде null → создаётся свой.
  final ChatRecordingController? recordingController;

  /// Desktop master-detail: when true the screen is hosted inside the
  /// «Чаты» tab's right pane (not a pushed route), so it must NOT render a
  /// «назад» leading that would pop the whole shell route. The chat list
  /// stays visible to the left; switching chats just swaps this pane.
  final bool embedded;

  /// Desktop master-detail hook: lets the parent chat list swap the right pane
  /// to a direct chat opened from a group message/member row.
  final OpenDirectChatCallback? onOpenDirectChat;

  /// Test hook for web clipboard-image paste. Production uses the browser
  /// paste listener from [ChatClipboardImagePasteService].
  final Stream<ChatClipboardImage>? clipboardImages;

  bool get isGroup => chatType == 'group' || chatType == 'branch';

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const int _maxAttachments = 6;
  static const List<String> _quickReactionEmoji = <String>[
    '👍',
    '❤️',
    '😂',
    '😮',
    '🙏',
    '🔥',
  ];

  // GP2: guards the one-shot auto-start-call trigger (widget.autoStartCall)
  // against _loadChatDetails running more than once (cache + API).
  bool _autoStartCallConsumed = false;

  final TextEditingController _messageController = TextEditingController();
  final FocusNode _messageFocusNode = FocusNode();
  final CallCoordinatorService _callCoordinator =
      GetIt.I<CallCoordinatorService>();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  // Optional details cache — when registered we hydrate the chat
  // header (title / participants / branch roots) from disk so the
  // user sees the chat fully populated even if the API is offline.
  ChatDetailsCache? get _chatDetailsCache =>
      GetIt.I.isRegistered<ChatDetailsCache>()
          ? GetIt.I<ChatDetailsCache>()
          : null;
  final AppStatusService _appStatusService = GetIt.I<AppStatusService>();
  final SafetyServiceInterface? _safetyService =
      GetIt.I.isRegistered<SafetyServiceInterface>()
          ? GetIt.I<SafetyServiceInterface>()
          : null;
  final ImagePicker _imagePicker = ImagePicker();
  final CustomApiRealtimeService? _realtimeService =
      GetIt.I.isRegistered<CustomApiRealtimeService>()
          ? GetIt.I<CustomApiRealtimeService>()
          : null;

  String? _currentUserId;
  String? _chatId;
  ChatDetails? _chatDetails;
  String? _bootstrapError;
  bool _isBootstrapping = true;
  bool _isLoadingChatDetails = false;
  bool _isMarkingRead = false;
  late String _resolvedTitle;
  final ChatAttachmentsController _attachmentsController =
      ChatAttachmentsController(maxAttachments: _maxAttachments);
  ChatClipboardImagePasteService? _clipboardImagePasteService;
  StreamSubscription<ChatClipboardImage>? _clipboardImagePasteSubscription;
  late final ChatSendQueue _sendQueue;
  bool _ownsSendQueue = false;
  // S1: открытие чата до первого кадра с сообщениями.
  PerfTrace? _chatOpenTrace;
  // S5: heartbeat активного чата (сервер протухает запись через 60с).
  Timer? _activeChatHeartbeat;
  // S5: видимый статус соединения — «Подключение…» в шапке при разрыве.
  bool _isRealtimeReconnecting = false;
  final Set<String> _reportedSendFailureIds = <String>{};
  final Set<String> _handledVoiceSendIds = <String>{};
  // SPEED-5: отпечаток видимого оптимистичного списка — ребилд только на
  // реальное изменение (см. _handleSendQueueChanged).
  String? _lastSendQueueFingerprint;
  Timer? _draftSaveTimer;
  bool _isApplyingDraft = false;
  int _draftPersistenceVersion = 0;
  String? _lastPersistedDraftKey;
  final ScrollController _messagesScrollController = ScrollController();
  final GlobalKey _unreadDividerKey = GlobalKey();
  bool _showJumpToLatestButton = false;
  bool _didInitialUnreadJump = false;
  String? _unreadAnchorMessageId;
  // Sticky unread (UX-аудит P1): сколько НОВЫХ входящих пришло снизу,
  // пока юзер отскроллен вверх — бейдж на jump-FAB (Telegram-паттерн).
  // Серверный unreadCount мёртв для этого: _markChatAsRead гасит его
  // через секунды после прихода независимо от скролла — считаем
  // клиентской сессией. Леджер прихода отдельный от
  // _seenRemoteMessageIds (тот заполняется только для ПОСТРОЕННЫХ
  // бабблов и пропускает всё за cacheExtent).
  int _newBelowViewportCount = 0;
  final Set<String> _arrivalLedgerIds = <String>{};
  // База «самое свежее сообщение, что мы видели» — чтобы старые
  // сообщения, доехавшие смёрдженной страницей на реконнекте, не
  // считались «новыми снизу» (ревью батча).
  DateTime? _newestArrivalSeen;
  // Плавающий чип «N новых»: разделитель непрочитанного выше вьюпорта
  // (включая случай за cacheExtent, где initial-jump молча не сработал).
  bool _unreadDividerAboveViewport = false;
  // Верхний видимый баббл — стэшится в _updateFloatingDayHeader, чтобы
  // чип непрочитанного не обходил ключи повторно (ревью батча).
  ChatMessage? _topmostVisibleRemoteMessage;
  ChatReplyReference? _selectedReply;
  _ForwardDraft? _selectedForward;
  _ForwardBatchDraft? _selectedForwardBatch;
  _EditDraft? _selectedEdit;
  final ChatSearchController _searchController = ChatSearchController();
  final ChatSelectionController _selectionController =
      ChatSelectionController();
  bool _browserContextMenuWasEnabled = false;
  bool _isDirectChatBlocked = false;
  String? _directChatBlockedLabel;
  late final ChatRecordingController _recordingController;
  late final bool _ownsRecordingController;
  ChatTimelineController? _timelineController;
  ChatDraftStore get _draftStore =>
      widget.draftStore ??
      (GetIt.I.isRegistered<ChatDraftStore>()
          ? GetIt.I<ChatDraftStore>()
          : const SharedPreferencesChatDraftStore());
  ChatNotificationSettingsStore get _notificationSettingsStore =>
      widget.notificationSettingsStore ??
      const SharedPreferencesChatNotificationSettingsStore();
  ChatPinStore get _pinStore =>
      widget.pinStore ??
      (GetIt.I.isRegistered<ChatPinStore>()
          ? GetIt.I<ChatPinStore>()
          : const SharedPreferencesChatPinStore());
  ChatAutoDeleteStore get _autoDeleteStore =>
      widget.autoDeleteStore ?? const SharedPreferencesChatAutoDeleteStore();
  ChatNotificationSettingsSnapshot _notificationSettings =
      ChatNotificationSettingsSnapshot.defaults();
  String? _lastPersistedNotificationSettingsKey;
  ChatAutoDeleteSnapshot _autoDeleteSettings =
      ChatAutoDeleteSnapshot.defaults();
  String? _lastPersistedAutoDeleteKey;
  ChatPinnedMessageSnapshot? _pinnedMessage;
  String? _lastPersistedPinKey;
  List<ChatMessage> _latestRemoteMessages = const <ChatMessage>[];
  final Map<String, GlobalKey> _remoteMessageKeys = <String, GlobalKey>{};

  /// Day of the topmost-visible message — drives the floating
  /// "Сегодня / Вчера / 12 марта" pill at the top of the messages
  /// area while the user is scrolling history.
  DateTime? _floatingDayHeader;
  bool _floatingHeaderVisible = false;
  Timer? _floatingHeaderHideTimer;

  /// Message ids that have already been rendered at least once. Used
  /// to gate the bubble enter animation: ids in this set render in
  /// their rest state, ids NOT in the set get a one-shot
  /// slide-up + fade-in TweenAnimationBuilder. We populate the set
  /// with the entire first history batch (so opening a chat doesn't
  /// animate every message) and only skip-add on subsequent
  /// snapshots — meaning only newly arrived messages animate.
  final Set<String> _seenRemoteMessageIds = <String>{};
  bool _remoteHistoryHydrated = false;
  Timer? _pinnedMessageHighlightTimer;
  String? _highlightedPinnedMessageId;
  Timer? _serverSearchDebounce;
  List<ChatMessageSearchResult> _serverSearchResults =
      const <ChatMessageSearchResult>[];
  String _serverSearchQuery = '';
  bool _isServerSearchLoading = false;
  bool _serverSearchAvailable = true;
  Object? _serverSearchError;
  StreamSubscription<CustomApiRealtimeEvent>? _realtimeIndicatorsSubscription;
  Timer? _typingHeartbeatTimer;
  Timer? _typingDecayTimer;
  bool _typingHeartbeatActive = false;
  final Map<String, DateTime> _typingUsers = <String, DateTime>{};
  final Set<String> _onlineUserIds = <String>{};

  /// Last-seen timestamps per peer userId. Populated from chat-details
  /// participants on chat open and updated by realtime `presence.updated`
  /// events when a peer goes offline. Drives the "был(а) N минут назад"
  /// subtitle on direct chats.
  final Map<String, DateTime> _peerLastSeenAt = <String, DateTime>{};
  static const double _recordingLockThreshold = 52;
  static const double _recordingCancelThreshold = 72;
  // Voice-cancel зона (UX-аудит P1): визуальный отклик слайда-влево.
  // ValueNotifier вместо setState — плавные per-move перерисовки только
  // внутри recording-бара; контроллер записи остаётся platform-pure.
  final ValueNotifier<double> _recordingDragDx = ValueNotifier<double>(0);

  // C3a/V1 (ревью): персистентный pointer-трекинг press-hold. Цикл записи
  // (move/lock/cancel/release) ведём raw-Listener'ом на СТАБИЛЬНОМ слое над
  // AnimatedSwitcher'ом композер↔бар. Иначе при ребилде (старт записи меняет
  // поддерево) LongPress-recognizer композера размонтируется, а recognizer
  // in-bar мика не видел pointer-down → onLongPressEnd не приходил на lift,
  // и запись не завершалась. Listener остаётся в hit-тесте указателя с
  // момента down, поэтому надёжно получает move/up несмотря на ребилд.
  int? _recordingPointerId;
  Offset? _recordingPointerOrigin;
  // FX1/C3a (ревью): id пальца, опущенного именно НА микрофон (локальный
  // Listener вокруг мик-кнопки). Запись привязываем к нему, а НЕ к любому
  // pointer-down в зоне композера — иначе второе касание TextField во время
  // long-press перебивало бы привязку и реальное отпускание не завершало
  // запись (stuck-recording).
  int? _micPointerId;
  // FX1/C3a FR3: палец отпущен, пока шёл старт (диалог разрешения микрофона)
  // — не оставляем осиротевшую запись без пальца и без Send.
  bool _recordingPointerReleased = false;

  // C3d/V2 (ревью FR8): запись кружка инлайн-оверлеем поверх чата (чат
  // виден), вместо отдельного fullscreen-роута. true → оверлей-рекордер
  // в Stack тела чата.
  bool _showInlineKruzhok = false;

  /// Telegram-style toggle for the composer's primary action button.
  /// Tap flips between voice (false) and kruzhok / video-note (true);
  /// long-press starts the corresponding recording flow. Was hard-
  /// coded to «tap = kruzhok» before, which forced users to long-
  /// press for a voice message every time. The user reported:
  /// «нажимаю на голосувуху - открывается запись кружочка... по тапу
  /// они должны меняться (как в тг), а вот при удержании
  /// записываться».
  bool _voiceModeIsKruzhok = false;

  @override
  void initState() {
    super.initState();
    _recordingController =
        widget.recordingController ?? ChatRecordingController();
    _ownsRecordingController = widget.recordingController == null;
    _chatOpenTrace = PerfTrace('chat.open-to-messages');
    _ownsSendQueue = !GetIt.I.isRegistered<ChatSendQueue>();
    _sendQueue = _ownsSendQueue
        ? ChatSendQueue.memory(chatService: _chatService)
        : GetIt.I<ChatSendQueue>();
    _sendQueue.addListener(_handleSendQueueChanged);
    _attachmentsController.addListener(_handleAttachmentsChanged);
    _chatDetails = widget.initialChatDetails;
    _resolvedTitle =
        widget.initialChatDetails?.displayTitleFor(_currentUserId) ??
            widget.title;
    _messageController.addListener(_handleDraftChanged);
    _searchController.addListener(_handleSearchChanged);
    // Global key handler — more reliable than Focus.onKeyEvent on Flutter web.
    HardwareKeyboard.instance.addHandler(_handleGlobalKeyEvent);
    _messagesScrollController.addListener(_handleMessagesScroll);
    _recordingController.addListener(_handleRecordingControllerChanged);
    _configureBrowserContextMenu();
    _bindClipboardImagePaste();
    // Defer the chat bootstrap until AFTER the first frame paints.
    // The bootstrap awaits getOrCreateChat / SharedPreferences /
    // notification-settings store reads, all of which compete with
    // the slide-transition that's animating this screen in. On
    // Samsung mid-range that competition shows up as a 150–300 ms
    // freeze where the chat header pops in late. addPostFrameCallback
    // gives the route transition a clean first frame and starts the
    // actual data-loading work right after — net latency is the same
    // but perceived smoothness is much better.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _bootstrapChat();
    });
  }

  @override
  void dispose() {
    // Снимаем активность чата ДО прочих очисток. Pass `_chatId` —
    // если пользователь свайпнулся в другой чат, и его initState
    // уже выставил новый id, наш expected mismatch'нется и мы
    // не затрём его флажок.
    final activeChatIdToClear = _chatId;
    if (activeChatIdToClear != null && activeChatIdToClear.isNotEmpty) {
      ActiveChatTracker.instance.clearActive(activeChatIdToClear);
      unawaited(
        _realtimeService?.clearActiveChat(chatId: activeChatIdToClear),
      );
    }
    _draftSaveTimer?.cancel();
    _activeChatHeartbeat?.cancel();
    _pinnedMessageHighlightTimer?.cancel();
    _serverSearchDebounce?.cancel();
    _floatingHeaderHideTimer?.cancel();
    _messageController.removeListener(_handleDraftChanged);
    _searchController.removeListener(_handleSearchChanged);
    HardwareKeyboard.instance.removeHandler(_handleGlobalKeyEvent);
    _messagesScrollController.removeListener(_handleMessagesScroll);
    _messagesScrollController.dispose();
    _messageController.dispose();
    _searchController.dispose();
    // Обнуляем pointer-привязку ДО dispose нотифаера: палец мог остаться
    // опущенным на записи (юзер свернул чат вторым пальцем), а
    // persistent-Listener продолжает слать move/up на down-time hit-path
    // и после unmount — ранний выход в _handleRecordingPointer* по
    // null id не даст записать в disposed ValueNotifier (ревью батча).
    _recordingPointerId = null;
    _recordingPointerOrigin = null;
    _recordingDragDx.dispose();
    _messageFocusNode.dispose();
    _typingHeartbeatTimer?.cancel();
    _typingDecayTimer?.cancel();
    unawaited(_setTypingActive(false, force: true));
    final realtimeSubscription = _realtimeIndicatorsSubscription;
    _realtimeIndicatorsSubscription = null;
    if (realtimeSubscription != null) {
      unawaited(realtimeSubscription.cancel());
    }
    _restoreBrowserContextMenu();
    unawaited(_clipboardImagePasteSubscription?.cancel());
    _clipboardImagePasteSubscription = null;
    _clipboardImagePasteService?.dispose();
    _clipboardImagePasteService = null;
    _sendQueue.removeListener(_handleSendQueueChanged);
    _attachmentsController.removeListener(_handleAttachmentsChanged);
    _attachmentsController.dispose();
    _recordingController.removeListener(_handleRecordingControllerChanged);
    if (_ownsRecordingController) {
      _recordingController.dispose();
    }
    if (_ownsSendQueue) {
      _sendQueue.dispose();
    }
    _selectionController.dispose();
    _timelineController?.dispose();
    super.dispose();
  }

  bool get _isSelectionMode => _selectionController.isSelectionMode;

  bool get _isSearchMode => _searchController.isSearchMode;

  int get _selectedMessageCount => _selectionController.selectedMessageCount;

  List<XFile> get _selectedAttachments => _attachmentsController.attachments;

  void _handleAttachmentsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  void _bindClipboardImagePaste() {
    final injectedStream = widget.clipboardImages;
    if (injectedStream != null) {
      _clipboardImagePasteSubscription =
          injectedStream.listen(_handleClipboardImagePaste);
      return;
    }

    if (!kIsWeb) {
      return;
    }

    final service = ChatClipboardImagePasteService();
    _clipboardImagePasteService = service;
    _clipboardImagePasteSubscription = service.images.listen(
      _handleClipboardImagePaste,
      onError: (Object error, StackTrace stackTrace) {
        debugPrint(
          'ChatScreen: не удалось прочитать изображение из буфера: '
          '$error\n$stackTrace',
        );
      },
    );
  }

  void _handleClipboardImagePaste(ChatClipboardImage image) {
    if (!mounted || image.bytes.isEmpty) {
      return;
    }
    if (_selectedAttachments.length >= _maxAttachments) {
      showAppSnackBar(
        context,
        'Можно прикрепить не более 6 вложений.',
        isError: true,
      );
      return;
    }

    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }

    final hasAudio = _selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    );
    if (hasAudio) {
      _attachmentsController.clear();
    }

    final hasHeavyMedia = _selectedAttachments.any((file) {
      final kind = _attachmentKindFromXFile(file);
      return kind == _ChatAttachmentKind.video ||
          kind == _ChatAttachmentKind.audio;
    });
    if (hasHeavyMedia) {
      _attachmentsController.clear();
    }

    final addedCount = _attachmentsController.addAll(
      <XFile>[
        XFile.fromData(
          image.bytes,
          name: image.name,
          mimeType: image.mimeType,
        ),
      ],
    );
    if (addedCount == 0) {
      showAppSnackBar(
        context,
        'Не удалось прикрепить изображение из буфера.',
        isError: true,
      );
      return;
    }

    _messageFocusNode.requestFocus();
  }

  List<_OutgoingMessage> get _optimisticMessages {
    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return const <_OutgoingMessage>[];
    }
    return _sendQueue.messagesFor(chatId);
  }

  void _handleSendQueueChanged() {
    if (!mounted) {
      return;
    }

    String? failureMessageToShow;
    var shouldMarkDirectChatBlocked = false;
    final optimisticMessages = _optimisticMessages;
    for (final message in optimisticMessages) {
      if (message.attachments.any(_isRecordedVoiceAttachment) &&
          _handledVoiceSendIds.add('${message.localId}-${message.status}')) {
        if (message.status == _OutgoingMessageStatus.sent) {
          _recordingController.completeSend();
        } else if (message.status == _OutgoingMessageStatus.failed) {
          _recordingController.markSendFailed(
            message.errorText ?? 'Не удалось отправить сообщение.',
          );
        }
      }

      if (message.status != _OutgoingMessageStatus.failed ||
          !_reportedSendFailureIds.add(message.localId)) {
        continue;
      }
      final errorText = message.errorText ?? 'Не удалось отправить сообщение.';
      failureMessageToShow ??= errorText;
      if (errorText.toLowerCase().contains('заблокирован') &&
          _isCurrentDirectChat) {
        shouldMarkDirectChatBlocked = true;
      }
    }

    // SPEED-5: очередь нотифицирует по ЛЮБОМУ чату и на каждый переход —
    // ребилдим экран только когда видимый оптимистичный список ЭТОГО чата
    // реально изменился (или надо проставить blocked-флаг). При rapid-fire
    // это срезает лишние полные ребилды списка сообщений.
    final fingerprint = optimisticMessages
        .map((message) => '${message.localId}:${message.status}:'
            '${message.progress?.stage}:${message.progress?.completed}:'
            '${message.errorText != null}')
        .join('|');
    final fingerprintChanged = fingerprint != _lastSendQueueFingerprint;
    _lastSendQueueFingerprint = fingerprint;
    if (!fingerprintChanged && !shouldMarkDirectChatBlocked) {
      if (failureMessageToShow != null) {
        final pendingFailureText = failureMessageToShow;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) {
            return;
          }
          showAppSnackBar(context, pendingFailureText, isError: true);
        });
      }
      return;
    }

    setState(() {
      if (shouldMarkDirectChatBlocked) {
        _isDirectChatBlocked = true;
        _directChatBlockedLabel ??=
            _participantLabelForUserId(_currentDirectPeerUserId ?? '');
      }
    });

    if (failureMessageToShow != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        showAppSnackBar(context, failureMessageToShow!, isError: true);
      });
    }
  }

  void _configureBrowserContextMenu() {
    if (!kIsWeb) {
      return;
    }
    _browserContextMenuWasEnabled = BrowserContextMenu.enabled;
    if (_browserContextMenuWasEnabled) {
      unawaited(BrowserContextMenu.disableContextMenu());
    }
  }

  void _restoreBrowserContextMenu() {
    if (!kIsWeb ||
        !_browserContextMenuWasEnabled ||
        BrowserContextMenu.enabled) {
      return;
    }
    unawaited(BrowserContextMenu.enableContextMenu());
  }

  ChatRecordingState? _lastRecordingState;

  void _handleRecordingControllerChanged() {
    if (!mounted) {
      return;
    }

    // C2: живая волна шлёт notify каждые ~120мс. Состав вложений и
    // composer↔бар свап нужны только на СМЕНЕ состояния — amplitude-only
    // нотификации пропускаем, чтобы не дёргать весь экран setState'ом.
    // Сам recording-бар перерисовывает волну/таймер через свой
    // AnimatedBuilder на том же контроллере.
    final state = _recordingController.state;
    if (state == _lastRecordingState) {
      return;
    }
    _lastRecordingState = state;

    final previewFile = _recordingController.previewFile;
    final shouldKeepPreview = state == ChatRecordingState.preview ||
        state == ChatRecordingState.failed;

    _attachmentsController.removeWhere(_isRecordedVoiceAttachment);
    if (shouldKeepPreview && previewFile != null) {
      _attachmentsController.replaceAll(<XFile>[previewFile]);
    }
    setState(() {});
  }

  bool _isRecordedVoiceAttachment(XFile file) {
    final rawName = file.name.trim().isNotEmpty
        ? file.name.trim()
        : path.basename(file.path);
    final normalizedName = rawName.toLowerCase();
    return normalizedName.startsWith('voice_note_') ||
        normalizedName.startsWith('voice-note-');
  }

  bool _isVideoNoteFile(XFile file) {
    final rawName = file.name.trim().isNotEmpty
        ? file.name.trim()
        : path.basename(file.path);
    final normalizedName = rawName.toLowerCase();
    return normalizedName.startsWith('video_note_') ||
        normalizedName.startsWith('video-note-');
  }

  Future<void> _openAttachmentPreviewGallery(
    List<_AttachmentPreviewItem> items, {
    int initialIndex = 0,
  }) async {
    if (items.isEmpty) {
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => _AttachmentViewerDialog(
        items: items,
        initialIndex: initialIndex.clamp(0, items.length - 1),
        onOpenExternally: _openAttachmentExternally,
        onDownload: _downloadAttachmentToDevice,
      ),
    );
  }

  void _showEmptyAttachmentCategorySnackBar(String text) {
    showAppSnackBar(context, text);
  }

  Future<void> _openChatMediaGallery() async {
    final mediaItems = _remoteAttachmentGalleryItems()
        .where((item) => item.isVisual)
        .toList(growable: false);
    if (mediaItems.isEmpty) {
      _showEmptyAttachmentCategorySnackBar('В этом чате пока нет медиа.');
      return;
    }

    await _openAttachmentPreviewGallery(mediaItems);
  }

  Future<void> _openChatFilesGallery() async {
    final fileItems = _remoteAttachmentGalleryItems()
        .where((item) => !item.isVisual)
        .toList(growable: false);
    if (fileItems.isEmpty) {
      _showEmptyAttachmentCategorySnackBar(
        'В этом чате пока нет документов и голосовых.',
      );
      return;
    }

    await _openAttachmentPreviewGallery(fileItems);
  }

  Future<XFile> _renamePickedVideoAsVideoNote(XFile file) async {
    final originalName = file.name.trim().isNotEmpty
        ? file.name.trim()
        : path.basename(file.path);
    final extension = path.extension(originalName).trim().isNotEmpty
        ? path.extension(originalName).trim()
        : ((file.mimeType ?? '').toLowerCase().contains('webm')
            ? '.webm'
            : '.mp4');
    final nextName =
        'video_note_${DateTime.now().millisecondsSinceEpoch}$extension';
    if (file.path.trim().isNotEmpty) {
      return XFile(
        file.path,
        name: nextName,
        mimeType: file.mimeType,
      );
    }

    return XFile.fromData(
      await file.readAsBytes(),
      name: nextName,
      mimeType: file.mimeType,
    );
  }

  Future<void> _handleRecordingLongPressStart(
      LongPressStartDetails details) async {
    // FX1/C3a FR1: привязываем запись к пальцу, опущенному именно НА микрофон
    // (_micPointerId от локального Listener'а мик-кнопки), а не к любому
    // pointer-down в композере. Сам цикл move/release дальше ведёт
    // персистентный Listener — см. _handleRecordingPointer*.
    final micPointer = _micPointerId;
    if (micPointer == null) {
      // Нет валидного down на микрофоне — не стартуем (FR3-страховка).
      return;
    }
    _recordingPointerId = micPointer;
    _recordingPointerOrigin = details.globalPosition;
    _recordingPointerReleased = false;
    _recordingDragDx.value = 0;
    await _startRecording();
    // FX1/C3a FR3: палец отпустили, пока шёл старт (диалог разрешения) —
    // не оставляем осиротевшую запись без пальца: отменяем (discard).
    if (_recordingPointerReleased) {
      _recordingPointerId = null;
      _recordingPointerOrigin = null;
      _recordingPointerReleased = false;
      if (_recordingController.state == ChatRecordingState.recording) {
        unawaited(_cancelRecording());
      }
    }
  }

  /// C3a/V1: смещение указателя относительно точки старта — слайд-влево
  /// отменяет, слайд-вверх фиксирует (hands-free). Работает на raw-указателе
  /// со стабильного слоя, поэтому не зависит от ребилда композер↔бар.
  void _handleRecordingPointerMove(PointerMoveEvent event) {
    if (!mounted ||
        _recordingPointerId == null ||
        event.pointer != _recordingPointerId) {
      return;
    }
    if (_recordingController.state != ChatRecordingState.recording) {
      return;
    }
    final origin = _recordingPointerOrigin;
    if (origin == null) {
      return;
    }
    final dx = event.position.dx - origin.dx;
    final dy = event.position.dy - origin.dy;
    // Визуальный отклик слайда: бар следит за пальцем (0..-порог).
    _recordingDragDx.value =
        dx.clamp(-_recordingCancelThreshold, 0.0).toDouble();

    if (dx <= -_recordingCancelThreshold) {
      // C2: тактильный фидбек на слайд-влево (отмена).
      HapticFeedback.mediumImpact();
      // Указатель больше не ведёт запись — отпускание не должно отправить.
      _recordingPointerId = null;
      _recordingPointerOrigin = null;
      // dx НЕ сбрасываем в 0: _cancelRecording асинхронно рвёт рекордер,
      // бар живёт ещё кадры до смены state — при сбросе он мигал бы в
      // rest-визуал (полная волна, простой крестик). Оставляем взведённое
      // красное; следующая запись обнулит dx в longPressStart (ревью).
      _recordingDragDx.value = -_recordingCancelThreshold;
      unawaited(_cancelRecording());
      return;
    }

    if (dy <= -_recordingLockThreshold) {
      // C2: тактильный фидбек на слайд-вверх (фиксация). FR2: порог 52px —
      // осознанный заметный свайп, обычное отпускание (указатель почти на
      // месте) его не достигает, поэтому ложного lock на lift нет.
      HapticFeedback.mediumImpact();
      _recordingController.lock();
      // Зафиксировано (hands-free): отпускание пальца больше НЕ завершает —
      // отправка/отмена идут кнопками locked-бара.
      _recordingPointerId = null;
      _recordingPointerOrigin = null;
      _recordingDragDx.value = 0;
    }
  }

  /// C3a/V1 (FR1): надёжный конец press-hold — отпускание пальца завершает
  /// и ОТПРАВЛЯЕТ запись, даже после ребилда композер→бар.
  void _handleRecordingPointerUp(PointerUpEvent event) {
    if (!mounted ||
        _recordingPointerId == null ||
        event.pointer != _recordingPointerId) {
      return;
    }
    if (_recordingController.state == ChatRecordingState.recording) {
      _recordingPointerId = null;
      _recordingPointerOrigin = null;
      _recordingDragDx.value = 0;
      unawaited(_stopAndSendRecording());
      return;
    }
    // FX1/C3a FR3: запись ещё не активна (идёт старт/диалог разрешения), а
    // палец уже отпущен — помечаем, чтобы старт отменил осиротевшую запись.
    _recordingPointerReleased = true;
  }

  /// FX1/C3a FR2: прерванный жест (систему перехватили / pointer cancel) —
  /// это НЕ отправка. Отменяем запись (discard), а не шлём голосовое.
  void _handleRecordingPointerCancel(PointerCancelEvent event) {
    if (!mounted ||
        _recordingPointerId == null ||
        event.pointer != _recordingPointerId) {
      return;
    }
    if (_recordingController.state == ChatRecordingState.recording) {
      _recordingPointerId = null;
      _recordingPointerOrigin = null;
      _recordingDragDx.value = 0;
      unawaited(_cancelRecording());
      return;
    }
    _recordingPointerReleased = true;
  }

  void _bindTimelineController(String chatId) {
    final currentController = _timelineController;
    if (currentController != null && currentController.chatId == chatId) {
      return;
    }

    currentController?.dispose();
    final nextController = ChatTimelineController(
      chatId: chatId,
      chatService: _chatService,
    );
    _timelineController = nextController;
    unawaited(nextController.start());
    unawaited(_ensureCallRuntimeReady(chatId));
  }

  Future<void> _ensureCallRuntimeReady(String chatId) async {
    await _callCoordinator.ensureRuntimeReady();
    await _callCoordinator.resync(chatId: chatId);
  }

  Future<void> _startCall(
    CallMediaMode mediaMode, {
    List<String>? participantIds,
  }) async {
    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    try {
      await _callCoordinator.startCall(
        chatId: chatId,
        mediaMode: mediaMode,
        participantIds: participantIds,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        humanizeError(error, fallback: 'Не удалось начать звонок.'),
        isError: true,
      );
    }
  }

  Future<void> _startCallFromHeader(CallMediaMode mediaMode) async {
    // GP2/GP5 discovery: if a call is already live in this chat, JOIN it
    // instead of starting a duplicate. requestForegroundPresentation surfaces
    // the CallScreen with «Войти» (chat-membership-gated /join) even if the
    // user had minimized this call — so a late member joins in one more tap
    // rather than spawning a second room the others aren't in.
    final chatId = _chatId;
    if (chatId != null && chatId.isNotEmpty) {
      try {
        final active = await _callCoordinator.getActiveCall(chatId: chatId);
        if (!mounted) {
          return;
        }
        if (active != null && !active.state.isTerminal) {
          await _callCoordinator.requestForegroundPresentation(active);
          return;
        }
        // getActiveCall resolved to null/terminal → genuinely no live call in
        // this chat; fall through to start a fresh one.
      } catch (_) {
        if (!mounted) {
          return;
        }
        // A TRANSIENT failure while checking for a live call — do NOT silently
        // start a duplicate room (that 409s if a call is actually live). Offer
        // a retry instead.
        showAppSnackBar(
          context,
          'Не удалось проверить активный звонок. Попробуйте ещё раз.',
          isError: true,
        );
        return;
      }
    }

    if (!widget.isGroup) {
      await _startCall(mediaMode);
      return;
    }

    final candidates = _groupCallInviteCandidates();
    if (candidates.isEmpty) {
      showAppSnackBar(
        context,
        'В этом чате пока некого позвать на звонок.',
        isError: true,
      );
      return;
    }
    if (candidates.length == 1) {
      await _startCall(
        mediaMode,
        participantIds: <String>[candidates.single.userId],
      );
      return;
    }

    final selectedParticipantIds = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _GroupCallParticipantPicker(
        mediaMode: mediaMode,
        participants: candidates,
      ),
    );
    if (!mounted ||
        selectedParticipantIds == null ||
        selectedParticipantIds.isEmpty) {
      return;
    }
    await _startCall(
      mediaMode,
      participantIds: selectedParticipantIds,
    );
  }

  List<ChatParticipantSummary> _groupCallInviteCandidates() {
    final details = _chatDetails;
    final currentUserId = _currentUserId?.trim();
    if (details == null || currentUserId == null || currentUserId.isEmpty) {
      return const <ChatParticipantSummary>[];
    }
    final participantsById = <String, ChatParticipantSummary>{
      for (final participant in details.participants)
        if (participant.userId.trim().isNotEmpty)
          participant.userId.trim(): participant,
    };

    final ids = details.participantIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty && id != currentUserId)
        .toSet()
        .toList(growable: false);
    return ids
        .map(
          (id) =>
              participantsById[id] ??
              ChatParticipantSummary(
                userId: id,
                displayName: _participantLabelForUserId(id),
              ),
        )
        .toList(growable: false);
  }

  void _exitSelectionMode() {
    _selectionController.clear();
  }

  void _selectRemoteMessage(ChatMessage message) {
    if (_isSearchMode) {
      _closeSearch();
    }
    setState(() {
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
    });
    _selectionController.selectRemote(message.id);
  }

  void _selectOutgoingMessage(_OutgoingMessage message) {
    if (_isSearchMode) {
      _closeSearch();
    }
    setState(() {
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
    });
    _selectionController.selectOutgoing(message.localId);
  }

  void _toggleRemoteMessageSelection(ChatMessage message) {
    _selectionController.toggleRemote(message.id);
  }

  void _toggleOutgoingMessageSelection(_OutgoingMessage message) {
    _selectionController.toggleOutgoing(message.localId);
  }

  List<_SelectedMessageEntry> _selectedMessagesSnapshot() {
    final selectedMessages = <_SelectedMessageEntry>[
      ..._latestRemoteMessages
          .where((message) => _selectionController.isRemoteSelected(message.id))
          .map(
            (message) => _SelectedMessageEntry.remote(
              message: message,
              displayName: _senderDisplayNameForMessage(
                senderId: message.senderId,
                senderName: message.senderName,
              ),
            ),
          ),
      ..._optimisticMessages
          .where((message) =>
              _selectionController.isOutgoingSelected(message.localId))
          .map(
            (message) => _SelectedMessageEntry.outgoing(
              message: message,
              displayName: _senderDisplayNameForMessage(
                senderId: message.senderId,
                senderName: null,
              ),
              normalizedAttachments: _normalizedOutgoingAttachments(message),
            ),
          ),
    ];
    selectedMessages.sort(
      (left, right) => left.timestamp.compareTo(right.timestamp),
    );
    return selectedMessages;
  }

  String _senderDisplayNameForMessage({
    required String senderId,
    required String? senderName,
  }) {
    final normalizedSenderName = senderName?.trim();
    if (normalizedSenderName != null && normalizedSenderName.isNotEmpty) {
      return normalizedSenderName;
    }
    return _participantLabelForUserId(senderId);
  }

  List<ChatAttachment> _normalizedOutgoingAttachments(
      _OutgoingMessage message) {
    if (message.forwardedAttachments.isNotEmpty) {
      return List<ChatAttachment>.from(message.forwardedAttachments);
    }
    return message.attachments
        .map(
          (file) => ChatAttachment(
            type: _attachmentTypeForDraft(file),
            url: file.path,
            mimeType: file.mimeType,
            fileName: file.name,
          ),
        )
        .toList();
  }

  String _selectedMessagesTranscript(List<_SelectedMessageEntry> messages) {
    final formatter = DateFormat('dd.MM.yyyy H:mm', 'ru');
    return messages.map((message) {
      final body = message.text.trim().isNotEmpty
          ? message.text.trim()
          : _transcriptAttachmentLabel(message.attachments);
      return '[${formatter.format(toLocalForDisplay(message.timestamp))}] ${message.displayName}: $body';
    }).join('\n');
  }

  String _transcriptAttachmentLabel(List<ChatAttachment> attachments) {
    if (attachments.isEmpty) {
      return 'Сообщение';
    }

    final counts = <ChatAttachmentType, int>{};
    for (final attachment in attachments) {
      counts.update(attachment.type, (value) => value + 1, ifAbsent: () => 1);
    }

    final labels = <String>[];
    void addLabel(ChatAttachmentType type, String singular, String plural) {
      final count = counts[type];
      if (count == null || count == 0) {
        return;
      }
      labels.add('$count ${count == 1 ? singular : plural}');
    }

    addLabel(ChatAttachmentType.image, 'фото', 'фото');
    addLabel(ChatAttachmentType.video, 'видео', 'видео');
    addLabel(ChatAttachmentType.audio, 'голосовое', 'голосовых');
    addLabel(ChatAttachmentType.file, 'файл', 'файлов');
    return '[вложение: ${labels.join(', ')}]';
  }

  Future<void> _copySelectedMessages() async {
    final selectedMessages = _selectedMessagesSnapshot();
    if (selectedMessages.isEmpty) {
      return;
    }

    await Clipboard.setData(
      ClipboardData(text: _selectedMessagesTranscript(selectedMessages)),
    );
    if (!mounted) {
      return;
    }
    _exitSelectionMode();
    showAppSnackBar(
      context,
      selectedMessages.length == 1
          ? 'Сообщение скопировано'
          : 'Скопировано ${selectedMessages.length} сообщений',
    );
  }

  Future<void> _forwardSelectedMessages() async {
    final selectedMessages = _selectedMessagesSnapshot();
    if (selectedMessages.isEmpty) {
      return;
    }

    setState(() {
      _selectedReply = null;
      _selectedEdit = null;
      _selectedForward = null;
      _selectedForwardBatch = _ForwardBatchDraft(
        items: selectedMessages
            .map(
              (message) => _ForwardDraft(
                senderName: message.displayName,
                text: message.text,
                attachments: message.attachments,
              ),
            )
            .toList(),
      );
    });
    _selectionController.clear();
  }

  Future<void> _deleteSelectedMessages() async {
    final selectedMessages = _selectedMessagesSnapshot();
    if (selectedMessages.isEmpty) {
      return;
    }
    final currentUserId = _currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }
    final hasForbiddenMessages = selectedMessages.any(
      (message) => !message.canDelete(currentUserId),
    );
    if (hasForbiddenMessages) {
      showAppSnackBar(
        context,
        'Пока можно удалять только свои сообщения и локальную очередь.',
        isError: true,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          selectedMessages.length == 1
              ? 'Удалить сообщение'
              : 'Удалить ${selectedMessages.length} сообщений',
        ),
        content: const Text('Это действие нельзя отменить.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }

    final outgoingIdsToRemove = <String>{};
    for (final message in selectedMessages) {
      if (message.remoteMessageId != null) {
        await _chatService.deleteChatMessage(
          chatId: chatId,
          messageId: message.remoteMessageId!,
        );
        continue;
      }
      if (message.outgoingLocalId != null) {
        outgoingIdsToRemove.add(message.outgoingLocalId!);
      }
    }

    if (!mounted) {
      return;
    }
    for (final outgoingId in outgoingIdsToRemove) {
      await _sendQueue.remove(chatId, outgoingId);
    }
    _selectionController.clear();
  }

  Future<void> _bootstrapChat() async {
    setState(() {
      _isBootstrapping = true;
      _bootstrapError = null;
      _didInitialUnreadJump = false;
      _unreadAnchorMessageId = null;
      _newBelowViewportCount = 0;
      _arrivalLedgerIds.clear();
      _newestArrivalSeen = null;
      _unreadDividerAboveViewport = false;
    });

    try {
      final currentUserId = _chatService.currentUserId;
      if (currentUserId == null || currentUserId.isEmpty) {
        throw StateError('Сессия недоступна');
      }

      String? resolvedChatId = widget.chatId;
      if (resolvedChatId == null || resolvedChatId.isEmpty) {
        final otherUserId = widget.otherUserId;
        if (otherUserId == null || otherUserId.isEmpty) {
          throw StateError('Не удалось определить чат');
        }
        resolvedChatId = await _chatService.getOrCreateChat(otherUserId);
      }
      if (resolvedChatId == null || resolvedChatId.isEmpty) {
        throw StateError('Не удалось определить чат');
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _currentUserId = currentUserId;
        _chatId = resolvedChatId;
        _isBootstrapping = false;
      });

      // Помечаем чат активным — пуши и system-replays для входящих
      // от этого чата теперь будут глушиться, пока юзер тут.
      // dispose() снимет флажок (с защитой от race с другим экраном
      // чата, открытым подряд).
      ActiveChatTracker.instance.setActive(resolvedChatId);

      // Сообщаем серверу через WS чтобы он тоже не слал пуш для
      // сообщений из этого чата — без этого пуш улетал в VKPNS до
      // того как WS-doставка успевала, и на телефоне раздавался buzz
      // даже при открытом окне чата.
      unawaited(_realtimeService?.setActiveChat(resolvedChatId));
      // S5: heartbeat активности раз в 30с — серверная запись протухает
      // через 60с idle. Свёрнутое приложение замораживает таймер →
      // флажок гаснет → пуши снова доходят (раньше открытый-но-свёрнутый
      // чат глушил их бесконечно).
      _activeChatHeartbeat?.cancel();
      final heartbeatChatId = resolvedChatId;
      _activeChatHeartbeat = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaited(_realtimeService?.setActiveChat(heartbeatChatId)),
      );

      // Очищаем шторку от прошлых нотификаций этого чата — юзер
      // зашёл сам, читать он начнёт прямо сейчас.
      if (GetIt.I.isRegistered<NotificationServiceInterface>()) {
        unawaited(
          GetIt.I<NotificationServiceInterface>()
              .dismissChatNotifications(resolvedChatId),
        );
      }

      unawaited(_sendQueue.restoreChat(resolvedChatId));
      _bindTimelineController(resolvedChatId);
      _bindRealtimeIndicators();
      unawaited(_restoreBootstrapUiState());
      if (_shouldPrefetchChatDetails()) {
        unawaited(_loadChatDetails());
      }
      unawaited(_markChatAsRead());
      if (_searchController.hasQuery) {
        _scheduleServerSearch(_searchController.query, resolvedChatId);
      }
    } catch (error) {
      _appStatusService.reportError(
        error,
        fallbackMessage: 'Не удалось открыть чат.',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrapError = _appStatusService.isOffline
            ? 'Нет соединения. Откройте чат снова, когда интернет вернётся.'
            : 'Не удалось открыть чат. Проверьте соединение и попробуйте снова.';
        _isBootstrapping = false;
      });
    }
  }

  bool _shouldPrefetchChatDetails() {
    if (_chatDetails != null) {
      return false;
    }
    if (widget.isGroup) {
      return true;
    }
    final normalizedTitle = widget.title.trim();
    return normalizedTitle.isEmpty ||
        normalizedTitle == 'Чат' ||
        normalizedTitle == 'Пользователь' ||
        widget.otherUserId == null ||
        widget.otherUserId!.trim().isEmpty;
  }

  Future<void> _restoreBootstrapUiState() async {
    // Was a serial chain — pinned → draft → notifications → autodelete.
    // Each one hits SharedPreferences (or its custom store) and does a
    // setState afterwards, so the chat sat with a half-painted header
    // for ~150–300 ms on Samsung mid-range while the chain laddered.
    // All four are independent so we fan them out and await once.
    await Future.wait<void>([
      _runBootstrapTask(
        _restorePinnedMessageIfNeeded,
        label: 'восстановление закрепа',
      ),
      _runBootstrapTask(
        _restoreDraftIfNeeded,
        label: 'восстановление черновика',
      ),
      _runBootstrapTask(
        _restoreNotificationSettingsIfNeeded,
        label: 'восстановление настроек уведомлений',
      ),
      _runBootstrapTask(
        _restoreAutoDeleteSettingsIfNeeded,
        label: 'восстановление автоудаления',
      ),
    ]);
  }

  Future<void> _runBootstrapTask(
    Future<void> Function() task, {
    required String label,
  }) async {
    try {
      await task();
    } catch (error, stackTrace) {
      debugPrint('ChatScreen: сбой during $label: $error\n$stackTrace');
    }
  }

  Future<void> _loadChatDetails() async {
    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }

    setState(() {
      _isLoadingChatDetails = true;
    });

    // Cache-first hydrate: if we have a cached snapshot of this
    // chat's details, paint it immediately so the user sees a
    // properly-populated header (title, member count, online dot)
    // even if the API call below times out / fails on offline.
    final cache = _chatDetailsCache;
    if (cache != null && _chatDetails == null) {
      try {
        final cached = await cache.read(chatId);
        if (cached != null && mounted) {
          setState(() {
            _chatDetails = cached;
            _resolvedTitle = cached.displayTitleFor(_currentUserId);
          });
        }
      } catch (_) {
        // Cache corruption is non-fatal — let the API repopulate.
      }
    }

    try {
      final details = await _chatService.getChatDetails(chatId);
      if (!mounted) {
        return;
      }

      // Persist to cache for future offline opens.
      unawaited(cache?.write(chatId, details));

      setState(() {
        _chatDetails = details;
        _resolvedTitle = details.displayTitleFor(_currentUserId);
        _isLoadingChatDetails = false;
        // Seed presence state from the chat details — gives the
        // subtitle a correct "в сети / был N минут назад" on first
        // paint without waiting for a realtime event.
        for (final participant in details.participants) {
          if (participant.userId == _currentUserId) continue;
          if (participant.isOnline) {
            _onlineUserIds.add(participant.userId);
          }
          if (participant.lastSeenAt != null) {
            _peerLastSeenAt[participant.userId] = participant.lastSeenAt!;
          }
        }
      });

      // GP2: opened from a chats-list «Позвонить» action — candidates are
      // now loaded, so fire the group-call flow exactly once (it runs the
      // same discovery → picker → start path as the header call button).
      if (widget.autoStartCall != null && !_autoStartCallConsumed && mounted) {
        _autoStartCallConsumed = true;
        unawaited(_startCallFromHeader(widget.autoStartCall!));
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isLoadingChatDetails = false;
      });
    }
  }

  Future<void> _markChatAsRead() async {
    final chatId = _chatId;
    final userId = _currentUserId;
    if (_isMarkingRead ||
        chatId == null ||
        chatId.isEmpty ||
        userId == null ||
        userId.isEmpty) {
      return;
    }

    _isMarkingRead = true;
    try {
      await _chatService.markChatAsRead(chatId, userId);
    } catch (error, stackTrace) {
      debugPrint(
        'ChatScreen: не удалось отметить чат как прочитанный: $error\n$stackTrace',
      );
    } finally {
      _isMarkingRead = false;
    }
  }

  Future<void> _pickImageAttachments() async {
    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }
    if (_selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    )) {
      _attachmentsController.clear();
    }
    if (_selectedAttachments.length >= _maxAttachments) {
      showAppSnackBar(
        context,
        'Можно прикрепить не более 6 вложений.',
        isError: true,
      );
      return;
    }

    try {
      final picked = widget.pickImages != null
          ? await widget.pickImages!()
          : await _imagePicker.pickMultiImage(
              imageQuality: 80,
              maxWidth: 1600,
            );
      if (picked.isEmpty || !mounted) {
        return;
      }

      final hadHeavyMedia = _selectedAttachments.any((f) {
        final kind = _attachmentKindFromXFile(f);
        return kind == _ChatAttachmentKind.video ||
            kind == _ChatAttachmentKind.audio;
      });
      if (hadHeavyMedia) {
        _attachmentsController.clear();
      }

      final addedCount = _attachmentsController.addAll(picked);
      if (picked.length > addedCount) {
        showAppSnackBar(
          context,
          'Можно добавить не более 6 фото.',
          isError: true,
        );
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Не удалось выбрать фотографии.',
        isError: true,
      );
    }
  }

  Future<void> _pickVideoAttachment({
    ImageSource source = ImageSource.gallery,
    bool asVideoNote = false,
    Duration maxDuration = const Duration(minutes: 10),
  }) async {
    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }
    if (_selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    )) {
      _attachmentsController.clear();
    }
    try {
      final pickedVideo = widget.pickVideo != null
          ? await widget.pickVideo!()
          : await _imagePicker.pickVideo(
              source: source,
              maxDuration: maxDuration,
            );
      if (pickedVideo == null || !mounted) {
        return;
      }

      final picked = asVideoNote
          ? await _renamePickedVideoAsVideoNote(pickedVideo)
          : pickedVideo;

      final size = await picked.length();
      if (size > 50 * 1024 * 1024) {
        // 50MB limit
        if (mounted) {
          showAppSnackBar(
            context,
            'Видео слишком большое (макс. 50 МБ).',
            isError: true,
          );
        }
        return;
      }

      _attachmentsController.replaceAll(<XFile>[picked]);
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        asVideoNote
            ? 'Не удалось подготовить кружок.'
            : 'Не удалось выбрать видео.',
        isError: true,
      );
    }
  }

  Future<void> _pickVideoNote() async {
    // In-app Telegram-style кружок recorder with a round live preview —
    // user complaint was "почему у нас кружочки пишутся не так, как в
    // телеграм, а через файл отдельный?". This now runs on WEB too:
    // camera_web (≥0.3.5) drives getUserMedia preview + MediaRecorder
    // video recording, so the old «<input type=file> can't preview»
    // fallback (which silently no-op'd on web — the file dialog needs a
    // direct user gesture the long-press loses) is gone. If the camera
    // is missing / permission denied, the recorder shows its own error
    // affordance instead of doing nothing.
    if (_selectedEdit != null) {
      setState(() => _selectedEdit = null);
    }
    if (_selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    )) {
      _attachmentsController.clear();
    }
    // C3d/V2 (FR8): запись кружка инлайн-оверлеем — чат остаётся виден,
    // без fullscreen-роута и его лага; камера стартует сразу. Результат/
    // отмена прилетают в _onInlineKruzhokCaptured/_onInlineKruzhokCancel.
    setState(() => _showInlineKruzhok = true);
  }

  Future<void> _pickGenericFile() async {
    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }
    if (_selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    )) {
      _attachmentsController.clear();
    }
    try {
      // file_picker 11.x replaced `FilePicker.platform.pickFiles(...)`
      // with the static `FilePicker.pickFiles(...)`. Same kwargs.
      final result = await FilePicker.pickFiles(
        allowMultiple: true,
        type: FileType.any,
      );

      if (result == null || result.files.isEmpty || !mounted) {
        return;
      }

      final pickedFiles = result.files
          .where((f) => f.path != null)
          .map((f) => XFile(f.path!, name: f.name, bytes: f.bytes))
          .toList();

      if (pickedFiles.isEmpty) return;

      final addedCount = _attachmentsController.addAll(pickedFiles);
      if (pickedFiles.length > addedCount) {
        showAppSnackBar(context, 'Можно добавить не более 6 файлов.');
      }
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        showAppSnackBar(context, 'Не удалось выбрать файл.', isError: true);
      }
    }
  }

  Future<void> _openAttachmentPicker() async {
    // Telegram-style attachment grid: vivid colored icon-tiles in a 4-up
    // layout. Replaces the previous vertical ListTile menu which the
    // user described as "колхоз".
    final choice = await showAttachmentPickerSheet(
      context,
      title: 'ПРИКРЕПИТЬ',
      actions: const [
        AttachmentPickerAction(
          id: 'images',
          icon: Icons.photo_library_rounded,
          label: 'Галерея',
          color: Color(0xFFE05A8B), // pink — "photos"
        ),
        AttachmentPickerAction(
          id: 'video',
          icon: Icons.videocam_rounded,
          label: 'Видео',
          color: Color(0xFFE85A40), // orange — "video"
        ),
        AttachmentPickerAction(
          id: 'video_note',
          icon: Icons.radio_button_checked_rounded,
          label: 'Кружок',
          color: Color(0xFF7B5BD6), // purple — "video note"
        ),
        AttachmentPickerAction(
          id: 'file',
          icon: Icons.insert_drive_file_rounded,
          label: 'Файл',
          color: Color(0xFF3D8DFF), // blue — "file"
        ),
      ],
    );

    if (!mounted || choice == null) {
      return;
    }

    switch (choice) {
      case 'images':
        await _pickImageAttachments();
        return;
      case 'video':
        await _pickVideoAttachment();
        return;
      case 'video_note':
        await _pickVideoNote();
        return;
      case 'file':
        await _pickGenericFile();
        return;
    }
  }

  /// Global hardware keyboard handler — registered on HardwareKeyboard directly.
  ///
  /// This is more reliable than [Focus.onKeyEvent] on Flutter web (CanvasKit)
  /// where key-event bubbling can be intercepted by the browser text layer.
  ///
  /// Returns true (consumes event) only when the message field has focus and
  /// we actually handle the shortcut.
  bool _handleGlobalKeyEvent(KeyEvent event) {
    if (!mounted || event is! KeyDownEvent) return false;
    // Only fire when the composer text field (or this screen) has focus.
    final bool composerFocused = _messageFocusNode.hasFocus ||
        FocusScope.of(context).focusedChild == _messageFocusNode;

    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    // Ctrl+Enter → send (regardless of composer focus so tooltip users can send)
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.enter) {
      final canSend = _messageController.text.trim().isNotEmpty ||
          _selectedAttachments.isNotEmpty ||
          _selectedForward != null ||
          _selectedForwardBatch != null ||
          _selectedEdit != null;
      if (canSend) {
        if (_selectedEdit != null) {
          _saveEditedMessage();
        } else {
          _sendCurrentMessage();
        }
        return true;
      }
    }

    // The rest only when composer is focused.
    if (!composerFocused) return false;

    // Escape → clear context or exit search/selection
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (_isSelectionMode) {
        _exitSelectionMode();
        return true;
      }
      if (_isSearchMode) {
        _closeSearch();
        return true;
      }
      if (_selectedEdit != null) {
        setState(() => _selectedEdit = null);
        _messageController.clear();
        return true;
      }
      if (_selectedReply != null) {
        setState(() => _selectedReply = null);
        return true;
      }
      if (_selectedForward != null || _selectedForwardBatch != null) {
        setState(() {
          _selectedForward = null;
          _selectedForwardBatch = null;
        });
        return true;
      }
    }

    // ↑ when field is empty → edit last own message (Telegram behaviour)
    if (!isCtrl && event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (_messageController.text.isEmpty && _selectedEdit == null) {
        _startEditingLastOwnMessage();
        return true;
      }
    }

    // Ctrl+F → open search
    if (isCtrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      if (!_isSearchMode) {
        _openSearch();
        return true;
      }
    }

    return false;
  }

  // Legacy Focus.onKeyEvent — kept as secondary handler.
  KeyEventResult _handleMessageKeyEvent(FocusNode node, KeyEvent event) {
    return KeyEventResult.ignored; // Global handler takes precedence.
  }

  /// Edit the most recent message sent by the current user (↑ shortcut).
  void _startEditingLastOwnMessage() {
    final messages = _latestRemoteMessages;
    final myId = _currentUserId;
    if (messages.isEmpty || myId == null) return;

    for (final msg in messages) {
      if (msg.senderId == myId && msg.text.isNotEmpty) {
        _selectEditMessage(msg);
        return;
      }
    }
  }

  Future<void> _startRecording() async {
    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }
    if (_selectedAttachments.isNotEmpty) {
      _attachmentsController.clear();
    }
    try {
      await _recordingController.start();
      // C2: тактильный фидбек, когда запись реально пошла (после выдачи
      // разрешения) — как в Telegram.
      if (_recordingController.state == ChatRecordingState.recording) {
        HapticFeedback.lightImpact();
      }
    } catch (error) {
      debugPrint('Error starting recording: $error');
      if (mounted) {
        showAppSnackBar(context, 'Не удалось начать запись.', isError: true);
      }
    }
  }

  Future<void> _stopAndSendRecording() async {
    await _recordingController.stopToPreview();
    // Auto-send immediately — no preview panel, Telegram-style.
    if (!mounted) return;
    if (_recordingController.state == ChatRecordingState.preview) {
      await _sendCurrentMessage();
    }
  }

  Future<void> _cancelRecording() async {
    await _recordingController.cancelCurrent();
  }

  Future<void> _discardPendingVoiceAttachment() async {
    final voiceAttachment = _selectedAttachments.cast<XFile?>().firstWhere(
          (file) =>
              file != null &&
              _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
          orElse: () => null,
        );
    if (voiceAttachment == null) {
      return;
    }
    _recordingController.discardPreview();
    _attachmentsController.remove(voiceAttachment);
  }

  Future<void> _rerecordVoiceAttachment() async {
    await _discardPendingVoiceAttachment();
    if (!mounted) {
      return;
    }
    await _startRecording();
  }

  Future<void> _sendCurrentMessage() async {
    final currentUserId = _currentUserId;
    final chatId = _chatId;
    if (currentUserId == null ||
        currentUserId.isEmpty ||
        chatId == null ||
        chatId.isEmpty) {
      // Bootstrap still running — give the user visible feedback.
      if (mounted) {
        showAppSnackBar(
          context,
          'Чат ещё загружается, подождите секунду.',
          duration: const Duration(seconds: 2),
        );
      }
      return;
    }

    final text = _messageController.text.trim();
    final forwardBatch = _selectedForwardBatch;
    if (forwardBatch != null) {
      await _sendForwardBatch(forwardBatch, commentText: text);
      return;
    }
    final attachments = List<XFile>.from(_selectedAttachments);
    final forwardedAttachments = List<ChatAttachment>.from(
        _selectedForward?.attachments ?? const <ChatAttachment>[]);
    final messageText = _composeMessageText(
      typedText: text,
      forwardedText: _selectedForward?.text ?? '',
    );
    final replyTo = _selectedReply;
    if (messageText.isEmpty &&
        attachments.isEmpty &&
        forwardedAttachments.isEmpty) {
      return;
    }

    // SPEED-1 замер: от тапа «отправить» до кадра, в котором отрисован
    // оптимистичный пузырь (цель <16мс — один кадр, «эффект Telegram»).
    final tapTrace = PerfTrace('chat.tap-to-bubble');

    if (attachments.any(_isRecordedVoiceAttachment)) {
      _recordingController.markSending();
    }
    _suppressSentDraftEcho(chatId: chatId, text: messageText);
    _messageController.clear();
    unawaited(
      _clearActiveDraft().catchError(
        (e) => debugPrint('[chat] draft-clear error: $e'),
      ),
    );

    setState(() {
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForward = null;
    });
    _attachmentsController.clear();
    await _sendQueue.enqueue(
      chatId: chatId,
      senderId: currentUserId,
      text: messageText,
      attachments: attachments,
      forwardedAttachments: forwardedAttachments,
      replyTo: replyTo,
      expiresInSeconds: _autoDeleteSettings.option.ttl?.inSeconds,
    );
    // enqueue уже дёрнул notify → setState; пузырь отрисуется в ближайшем
    // кадре — фиксируем именно его.
    WidgetsBinding.instance.addPostFrameCallback((_) => tapTrace.finish());

    // Side-effects: fire-and-forget so they can't block or kill the send.
    unawaited(
      _setTypingActive(false, force: true).catchError(
        (e) => debugPrint('[chat] typing-clear error: $e'),
      ),
    );
  }

  Future<void> _sendForwardBatch(
    _ForwardBatchDraft draft, {
    required String commentText,
  }) async {
    final currentUserId = _currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return;
    }

    final batchItems = List<_ForwardDraft>.from(draft.items);
    if (batchItems.isEmpty) {
      return;
    }

    final comment = commentText.trim();
    _suppressSentDraftEcho(chatId: _chatId, text: comment);
    _messageController.clear();
    unawaited(
      _clearActiveDraft().catchError(
        (e) => debugPrint('[chat] draft-clear error: $e'),
      ),
    );
    setState(() {
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
    });
    _attachmentsController.clear();
    unawaited(
      _setTypingActive(false, force: true).catchError(
        (e) => debugPrint('[chat] typing-clear error: $e'),
      ),
    );

    if (comment.isNotEmpty) {
      await _enqueueOutgoingMessageAndSend(
        senderId: currentUserId,
        text: comment,
      );
    }

    for (final item in batchItems) {
      final forwardedText = item.text.trim();
      await _enqueueOutgoingMessageAndSend(
        senderId: currentUserId,
        text: forwardedText,
        forwardedAttachments: item.attachments,
      );
    }
  }

  Future<void> _enqueueOutgoingMessageAndSend({
    required String senderId,
    required String text,
    List<XFile> attachments = const <XFile>[],
    List<ChatAttachment> forwardedAttachments = const <ChatAttachment>[],
    ChatReplyReference? replyTo,
  }) async {
    final chatId = _chatId;
    if (!mounted || chatId == null || chatId.isEmpty) {
      return;
    }
    await _sendQueue.enqueue(
      chatId: chatId,
      senderId: senderId,
      text: text,
      attachments: attachments,
      forwardedAttachments: forwardedAttachments,
      replyTo: replyTo,
      expiresInSeconds: _autoDeleteSettings.option.ttl?.inSeconds,
    );
  }

  Future<void> _saveEditedMessage() async {
    final edit = _selectedEdit;
    final chatId = _chatId;
    if (edit == null || chatId == null || chatId.isEmpty) {
      return;
    }

    final nextText = _messageController.text.trim();
    if (nextText.isEmpty && !edit.hasAttachments) {
      showAppSnackBar(context, 'Сообщение не должно быть пустым.');
      return;
    }

    try {
      unawaited(
        _setTypingActive(false, force: true).catchError(
          (e) => debugPrint('[chat] typing-clear error: $e'),
        ),
      );
      await _chatService.editChatMessage(
        chatId: chatId,
        messageId: edit.messageId,
        text: nextText,
      );
      _suppressSentDraftEcho(chatId: chatId, text: nextText);
      _messageController.clear();
      unawaited(
        _clearActiveDraft().catchError(
          (e) => debugPrint('[chat] draft-clear error: $e'),
        ),
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedEdit = null;
      });
      _attachmentsController.clear();
      _recordingController.discardPreview();
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось сохранить изменения.',
          isError: true);
    }
  }

  List<String> _draftCandidateKeys() {
    final keys = <String>[];
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatDraftStore.chatKey(resolvedChatId));
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatDraftStore.chatKey(widgetChatId));
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      keys.add(SharedPreferencesChatDraftStore.directUserKey(otherUserId));
    }
    return keys.toSet().toList();
  }

  String? _primaryDraftKey() {
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      return SharedPreferencesChatDraftStore.chatKey(resolvedChatId);
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      return SharedPreferencesChatDraftStore.chatKey(widgetChatId);
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      return SharedPreferencesChatDraftStore.directUserKey(otherUserId);
    }
    return null;
  }

  String _composeMessageText({
    required String typedText,
    required String forwardedText,
  }) {
    final cleanTyped = typedText.trim();
    final cleanForwarded = forwardedText.trim();
    if (cleanTyped.isEmpty) {
      return cleanForwarded;
    }
    if (cleanForwarded.isEmpty) {
      return cleanTyped;
    }
    return '$cleanTyped\n\n$cleanForwarded';
  }

  Future<void> _restoreDraftIfNeeded() async {
    final keys = _draftCandidateKeys();
    if (keys.isEmpty) {
      return;
    }

    final restoreVersion = _draftPersistenceVersion;
    ChatDraftSnapshot? bestDraft;
    String? bestDraftKey;
    for (final key in keys) {
      final snapshot = await _draftStore.getDraft(key);
      if (restoreVersion != _draftPersistenceVersion) {
        return;
      }
      if (snapshot == null) {
        continue;
      }
      if (ChatDraftSuppression.instance.shouldSuppressDraftKey(
        key: key,
        text: snapshot.text,
      )) {
        unawaited(_clearDraftKey(key));
        continue;
      }
      if (bestDraft == null ||
          snapshot.updatedAt.isAfter(bestDraft.updatedAt)) {
        bestDraft = snapshot;
        bestDraftKey = key;
      }
    }

    final preferredKey = _primaryDraftKey();
    if (bestDraft == null) {
      _lastPersistedDraftKey = preferredKey;
      return;
    }
    if (restoreVersion != _draftPersistenceVersion ||
        _messageController.text.isNotEmpty) {
      return;
    }

    _isApplyingDraft = true;
    _messageController.value = TextEditingValue(
      text: bestDraft.text,
      selection: TextSelection.collapsed(offset: bestDraft.text.length),
    );
    _isApplyingDraft = false;

    _lastPersistedDraftKey = preferredKey ?? bestDraftKey;
    if (preferredKey != null &&
        bestDraftKey != null &&
        preferredKey != bestDraftKey) {
      await _draftStore.saveDraft(preferredKey, bestDraft.text);
      await _draftStore.clearDraft(bestDraftKey);
    }
  }

  void _handleDraftChanged() {
    if (_isApplyingDraft) {
      return;
    }
    _handleTypingChanged();
    final version = ++_draftPersistenceVersion;
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistCurrentDraft(version));
    });
  }

  Future<void> _persistCurrentDraft(int version) async {
    final draftKey = _primaryDraftKey();
    if (draftKey == null) {
      return;
    }

    final text = _messageController.text;
    if (version != _draftPersistenceVersion) {
      return;
    }
    if (text.trim().isEmpty) {
      await _draftStore.clearDraft(draftKey);
    } else {
      ChatDraftSuppression.instance.recordLocalDraftEdit(
        key: draftKey,
        text: text,
      );
      await _draftStore.saveDraft(draftKey, text);
    }
    if (version != _draftPersistenceVersion) {
      return;
    }

    final previousKey = _lastPersistedDraftKey;
    _lastPersistedDraftKey = draftKey;
    if (previousKey != null && previousKey != draftKey) {
      await _draftStore.clearDraft(previousKey);
    }
  }

  Future<void> _clearActiveDraft() async {
    _draftSaveTimer?.cancel();
    _draftSaveTimer = null;
    _draftPersistenceVersion++;
    final keys = _draftCandidateKeys();
    for (final key in keys) {
      await _draftStore.clearDraft(key);
    }
    _lastPersistedDraftKey = _primaryDraftKey();
  }

  void _suppressSentDraftEcho({required String? chatId, required String text}) {
    final normalizedChatId = chatId?.trim();
    if (normalizedChatId == null || normalizedChatId.isEmpty) {
      return;
    }
    ChatDraftSuppression.instance.suppressSentDraft(
      chatId: normalizedChatId,
      text: text,
    );
  }

  Future<void> _clearDraftKey(String key) async {
    await _draftStore.clearDraft(key);
  }

  List<String> _notificationSettingsCandidateKeys() {
    final keys = <String>[];
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      keys.add(
        SharedPreferencesChatNotificationSettingsStore.chatKey(resolvedChatId),
      );
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      keys.add(
        SharedPreferencesChatNotificationSettingsStore.chatKey(widgetChatId),
      );
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      keys.add(
        SharedPreferencesChatNotificationSettingsStore.directUserKey(
          otherUserId,
        ),
      );
    }
    return keys.toSet().toList();
  }

  String? _primaryNotificationSettingsKey() {
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      return SharedPreferencesChatNotificationSettingsStore.chatKey(
        resolvedChatId,
      );
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      return SharedPreferencesChatNotificationSettingsStore.chatKey(
        widgetChatId,
      );
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      return SharedPreferencesChatNotificationSettingsStore.directUserKey(
        otherUserId,
      );
    }
    return null;
  }

  Future<void> _restoreNotificationSettingsIfNeeded() async {
    final keys = _notificationSettingsCandidateKeys();
    if (keys.isEmpty) {
      return;
    }

    ChatNotificationSettingsSnapshot? bestSnapshot;
    String? bestKey;
    for (final key in keys) {
      final snapshot = await _notificationSettingsStore.getSettings(key);
      if (snapshot == null) {
        continue;
      }
      if (bestSnapshot == null ||
          snapshot.updatedAt.isAfter(bestSnapshot.updatedAt)) {
        bestSnapshot = snapshot;
        bestKey = key;
      }
    }

    final preferredKey = _primaryNotificationSettingsKey();
    final nextSnapshot =
        bestSnapshot ?? ChatNotificationSettingsSnapshot.defaults();
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationSettings = nextSnapshot;
    });

    _lastPersistedNotificationSettingsKey = preferredKey ?? bestKey;
    if (bestSnapshot != null &&
        preferredKey != null &&
        bestKey != null &&
        preferredKey != bestKey) {
      await _notificationSettingsStore.saveSettings(preferredKey, bestSnapshot);
      await _notificationSettingsStore.clearSettings(bestKey);
    }
  }

  List<String> _autoDeleteCandidateKeys() {
    final keys = <String>[];
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatAutoDeleteStore.chatKey(resolvedChatId));
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatAutoDeleteStore.chatKey(widgetChatId));
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      keys.add(SharedPreferencesChatAutoDeleteStore.directUserKey(otherUserId));
    }
    return keys.toSet().toList();
  }

  String? _primaryAutoDeleteKey() {
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      return SharedPreferencesChatAutoDeleteStore.chatKey(resolvedChatId);
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      return SharedPreferencesChatAutoDeleteStore.chatKey(widgetChatId);
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      return SharedPreferencesChatAutoDeleteStore.directUserKey(otherUserId);
    }
    return null;
  }

  Future<void> _restoreAutoDeleteSettingsIfNeeded() async {
    final keys = _autoDeleteCandidateKeys();
    if (keys.isEmpty) {
      return;
    }

    ChatAutoDeleteSnapshot? bestSnapshot;
    String? bestKey;
    for (final key in keys) {
      final snapshot = await _autoDeleteStore.getSettings(key);
      if (snapshot == null) {
        continue;
      }
      if (bestSnapshot == null ||
          snapshot.updatedAt.isAfter(bestSnapshot.updatedAt)) {
        bestSnapshot = snapshot;
        bestKey = key;
      }
    }

    final preferredKey = _primaryAutoDeleteKey();
    final nextSnapshot = bestSnapshot ?? ChatAutoDeleteSnapshot.defaults();
    if (!mounted) {
      return;
    }

    setState(() {
      _autoDeleteSettings = nextSnapshot;
    });

    _lastPersistedAutoDeleteKey = preferredKey ?? bestKey;
    if (bestSnapshot != null &&
        preferredKey != null &&
        bestKey != null &&
        preferredKey != bestKey) {
      await _autoDeleteStore.saveSettings(preferredKey, bestSnapshot);
      await _autoDeleteStore.clearSettings(bestKey);
    }
  }

  Future<void> _updateAutoDeleteOption(ChatAutoDeleteOption option) async {
    final settingsKey = _primaryAutoDeleteKey();
    final nextSnapshot = ChatAutoDeleteSnapshot(
      option: option,
      updatedAt: DateTime.now(),
    );

    if (settingsKey != null) {
      await _autoDeleteStore.saveSettings(settingsKey, nextSnapshot);
      final previousKey = _lastPersistedAutoDeleteKey;
      _lastPersistedAutoDeleteKey = settingsKey;
      if (previousKey != null && previousKey != settingsKey) {
        await _autoDeleteStore.clearSettings(previousKey);
      }
    } else {
      _lastPersistedAutoDeleteKey = null;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _autoDeleteSettings = nextSnapshot;
    });
  }

  Future<void> _persistNotificationSettings(
    ChatNotificationSettingsSnapshot snapshot,
  ) async {
    final settingsKey = _primaryNotificationSettingsKey();
    if (settingsKey == null) {
      return;
    }
    await _notificationSettingsStore.saveSettings(settingsKey, snapshot);
    final previousKey = _lastPersistedNotificationSettingsKey;
    _lastPersistedNotificationSettingsKey = settingsKey;
    if (previousKey != null && previousKey != settingsKey) {
      await _notificationSettingsStore.clearSettings(previousKey);
    }
  }

  Future<void> _updateNotificationLevel(ChatNotificationLevel level) async {
    final nextSnapshot = ChatNotificationSettingsSnapshot(
      level: level,
      updatedAt: DateTime.now(),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _notificationSettings = nextSnapshot;
    });
    await _persistNotificationSettings(nextSnapshot);
    if (!mounted) {
      return;
    }
    String message;
    switch (level) {
      case ChatNotificationLevel.all:
        message = 'Уведомления чата включены';
        break;
      case ChatNotificationLevel.silent:
        message = 'Чат переведен в тихий режим';
        break;
      case ChatNotificationLevel.muted:
        message = 'Уведомления этого чата отключены';
        break;
    }
    showAppSnackBar(context, message);
  }

  bool _hasCurrentUserReaction(ChatMessage message, String emoji) {
    final currentUserId = _currentUserId;
    if (currentUserId == null ||
        currentUserId.isEmpty ||
        emoji.trim().isEmpty) {
      return false;
    }
    return message.reactions.any(
      (reaction) =>
          reaction.emoji == emoji && reaction.userIds.contains(currentUserId),
    );
  }

  List<_ReactionGroup> _reactionGroupsForMessage(ChatMessage message) {
    if (message.reactions.isEmpty) {
      return const <_ReactionGroup>[];
    }

    final currentUserId = _currentUserId;
    final groups = message.reactions
        .map(
          (reaction) => _ReactionGroup(
            emoji: reaction.emoji,
            count: reaction.count,
            isMine: reaction.isMine(currentUserId),
          ),
        )
        .toList()
      ..sort((left, right) => left.emoji.compareTo(right.emoji));
    return groups;
  }

  Future<void> _toggleReactionForMessage(
      ChatMessage message, String emoji) async {
    final currentUserId = _currentUserId;
    if (currentUserId == null ||
        currentUserId.isEmpty ||
        emoji.trim().isEmpty) {
      return;
    }
    final chatId = _chatId ?? widget.chatId;
    if (chatId == null || chatId.trim().isEmpty) {
      return;
    }

    try {
      await _chatService.toggleMessageReaction(
        chatId: chatId,
        messageId: message.id,
        emoji: emoji,
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось обновить реакцию.');
    }
  }

  List<String> _pinCandidateKeys() {
    final keys = <String>[];
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatPinStore.chatKey(resolvedChatId));
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatPinStore.chatKey(widgetChatId));
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      keys.add(SharedPreferencesChatPinStore.directUserKey(otherUserId));
    }
    return keys.toSet().toList();
  }

  String? _primaryPinKey() {
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      return SharedPreferencesChatPinStore.chatKey(resolvedChatId);
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      return SharedPreferencesChatPinStore.chatKey(widgetChatId);
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      return SharedPreferencesChatPinStore.directUserKey(otherUserId);
    }
    return null;
  }

  Future<void> _restorePinnedMessageIfNeeded() async {
    final keys = _pinCandidateKeys();
    if (keys.isEmpty) {
      return;
    }

    ChatPinnedMessageSnapshot? bestSnapshot;
    String? bestKey;
    for (final key in keys) {
      final snapshot = await _pinStore.getPinnedMessage(key);
      if (snapshot == null) {
        continue;
      }
      if (bestSnapshot == null ||
          snapshot.pinnedAt.isAfter(bestSnapshot.pinnedAt)) {
        bestSnapshot = snapshot;
        bestKey = key;
      }
    }

    final preferredKey = _primaryPinKey();
    if (bestSnapshot == null) {
      _lastPersistedPinKey = preferredKey;
      return;
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _pinnedMessage = bestSnapshot;
    });

    _lastPersistedPinKey = preferredKey ?? bestKey;
    if (preferredKey != null && bestKey != null && preferredKey != bestKey) {
      await _pinStore.savePinnedMessage(preferredKey, bestSnapshot);
      await _pinStore.clearPinnedMessage(bestKey);
    }
  }

  Future<void> _persistPinnedMessage(
    ChatPinnedMessageSnapshot snapshot,
  ) async {
    final pinKey = _primaryPinKey();
    if (pinKey == null) {
      return;
    }
    await _pinStore.savePinnedMessage(pinKey, snapshot);
    final previousKey = _lastPersistedPinKey;
    _lastPersistedPinKey = pinKey;
    if (previousKey != null && previousKey != pinKey) {
      await _pinStore.clearPinnedMessage(previousKey);
    }
  }

  Future<void> _clearPinnedMessage() async {
    final keys = _pinCandidateKeys();
    for (final key in keys) {
      await _pinStore.clearPinnedMessage(key);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _pinnedMessage = null;
      _highlightedPinnedMessageId = null;
    });
    _lastPersistedPinKey = _primaryPinKey();
  }

  ChatPinnedMessageSnapshot _snapshotFromMessage(ChatMessage message) {
    return ChatPinnedMessageSnapshot(
      messageId: message.id,
      senderId: message.senderId,
      senderName:
          _groupSenderLabel(message.senderName, message.senderId) ?? 'Участник',
      text: message.text,
      attachmentCount: message.attachments.length,
      pinnedAt: DateTime.now(),
    );
  }

  bool _isSamePinnedMessage(
    ChatPinnedMessageSnapshot first,
    ChatPinnedMessageSnapshot second,
  ) {
    return first.messageId == second.messageId &&
        first.senderId == second.senderId &&
        first.senderName == second.senderName &&
        first.text == second.text &&
        first.attachmentCount == second.attachmentCount;
  }

  Future<void> _pinRemoteMessage(ChatMessage message) async {
    final snapshot = _snapshotFromMessage(message);
    if (!mounted) {
      return;
    }
    setState(() {
      _pinnedMessage = snapshot;
    });
    await _persistPinnedMessage(snapshot);
    if (!mounted) {
      return;
    }
    showAppSnackBar(context, 'Сообщение закреплено');
  }

  void _schedulePinnedSync(List<ChatMessage> remoteMessages) {
    final pinned = _pinnedMessage;
    if (pinned == null) {
      return;
    }
    final match = remoteMessages
        .where((message) => message.id == pinned.messageId)
        .cast<ChatMessage?>()
        .firstWhere((message) => message != null, orElse: () => null);

    if (match == null) {
      return;
    }

    final nextSnapshot = pinned.copyWith(
      senderId: match.senderId,
      senderName: _groupSenderLabel(match.senderName, match.senderId) ??
          pinned.senderName,
      text: match.text,
      attachmentCount: match.attachments.length,
    );
    if (_isSamePinnedMessage(nextSnapshot, pinned)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pinnedMessage?.messageId != pinned.messageId) {
        return;
      }
      setState(() {
        _pinnedMessage = nextSnapshot;
      });
      unawaited(_persistPinnedMessage(nextSnapshot));
    });
  }

  void _bindRealtimeIndicators() {
    if (_realtimeService == null || _realtimeIndicatorsSubscription != null) {
      return;
    }

    unawaited(_realtimeService!.connect());
    _realtimeIndicatorsSubscription =
        _realtimeService!.events.listen(_handleRealtimeIndicatorEvent);
  }

  void _handleRealtimeIndicatorEvent(CustomApiRealtimeEvent event) {
    final currentChatId = _chatId;
    if (!mounted) {
      return;
    }

    if (event.type == 'connection.ready') {
      setState(() {
        _isRealtimeReconnecting = false;
        _onlineUserIds
          ..clear()
          ..addAll(event.onlineUserIds);
      });
      // S5: после реконнекта серверный флажок активности мог протухнуть
      // — переобъявляем сразу, не дожидаясь heartbeat-тика.
      if (currentChatId != null && currentChatId.isNotEmpty) {
        unawaited(_realtimeService?.setActiveChat(currentChatId));
      }
      return;
    }

    // S5: разрыв WS — честный статус «Подключение…» в шапке, как в
    // Telegram, вместо тихо замершего чата.
    if (event.type == 'connection.disconnected') {
      if (!_isRealtimeReconnecting) {
        setState(() => _isRealtimeReconnecting = true);
      }
      return;
    }

    if (event.type == 'presence.updated') {
      final userId = event.userId;
      if (userId == null || userId.isEmpty) {
        return;
      }
      // Backend sends lastSeenAt on the offline transition (== updatedAt
      // for that broadcast). For online events lastSeenAt is null —
      // because the user IS online, the timestamp would be misleading.
      final lastSeenRaw = event.lastSeenAt ?? event.updatedAt;
      final parsedLastSeen =
          lastSeenRaw == null ? null : DateTime.tryParse(lastSeenRaw);
      setState(() {
        if (event.isOnline == true) {
          _onlineUserIds.add(userId);
        } else {
          _onlineUserIds.remove(userId);
          _typingUsers.remove(userId);
          if (parsedLastSeen != null) {
            _peerLastSeenAt[userId] = parsedLastSeen;
          }
        }
      });
      return;
    }

    if (event.type == 'chat.typing.updated' &&
        currentChatId != null &&
        event.chatId == currentChatId) {
      final userId = event.userId;
      if (userId == null ||
          userId.isEmpty ||
          userId == _currentUserId ||
          event.isTyping == null) {
        return;
      }

      setState(() {
        if (event.isTyping == true) {
          _typingUsers[userId] = DateTime.now().add(const Duration(seconds: 4));
          _onlineUserIds.add(userId);
          _ensureTypingDecayTimer();
        } else {
          _typingUsers.remove(userId);
        }
      });
      return;
    }

    if (event.type == 'chat.draft.updated' &&
        currentChatId != null &&
        event.chatId == currentChatId &&
        event.userId == _currentUserId) {
      _handleRemoteDraftUpdate(event);
      return;
    }

    if (event.type == 'chat.pin.updated' &&
        currentChatId != null &&
        event.chatId == currentChatId) {
      _handleRemotePinUpdate(event);
    }
  }

  void _handleRemotePinUpdate(CustomApiRealtimeEvent event) {
    final pinKey = _primaryPinKey();
    if (pinKey == null) {
      return;
    }

    final rawPin = event.pin;
    final snapshot =
        rawPin == null ? null : ChatPinnedMessageSnapshot.fromJson(rawPin);
    final pinStore = _pinStore;

    if (snapshot == null || snapshot.messageId.trim().isEmpty) {
      unawaited(
        pinStore is HybridChatPinStore
            ? pinStore.clearLocalPinnedMessage(pinKey)
            : pinStore.clearPinnedMessage(pinKey),
      );
      setState(() {
        _pinnedMessage = null;
        _highlightedPinnedMessageId = null;
      });
      _lastPersistedPinKey = pinKey;
      return;
    }

    unawaited(
      pinStore is HybridChatPinStore
          ? pinStore.saveLocalPinnedMessage(pinKey, snapshot)
          : pinStore.savePinnedMessage(pinKey, snapshot),
    );
    setState(() {
      _pinnedMessage = snapshot;
    });
    _lastPersistedPinKey = pinKey;
  }

  void _handleRemoteDraftUpdate(CustomApiRealtimeEvent event) {
    final draftKey = _primaryDraftKey();
    if (draftKey == null) {
      return;
    }

    final rawDraft = event.draft;
    final draft =
        rawDraft == null ? null : ChatDraftSnapshot.fromJson(rawDraft);
    final nextText = draft?.text ?? '';
    if (nextText.trim().isNotEmpty &&
        ChatDraftSuppression.instance.shouldSuppressDraft(
          chatId: event.chatId ?? _chatId ?? '',
          text: nextText,
        )) {
      unawaited(_clearDraftKey(draftKey));
      if (_messageController.text.trim() == nextText.trim()) {
        _isApplyingDraft = true;
        _messageController.clear();
        _isApplyingDraft = false;
      }
      return;
    }
    final draftStore = _draftStore;
    if (nextText.trim().isEmpty) {
      unawaited(
        draftStore is HybridChatDraftStore
            ? draftStore.clearLocalDraft(draftKey)
            : draftStore.clearDraft(draftKey),
      );
      final currentText = _messageController.text;
      if (currentText.trim().isEmpty ||
          ChatDraftSuppression.instance.shouldSuppressDraft(
            chatId: event.chatId ?? _chatId ?? '',
            text: currentText,
          )) {
        _isApplyingDraft = true;
        _messageController.clear();
        _isApplyingDraft = false;
      }
      _lastPersistedDraftKey = draftKey;
      return;
    } else {
      unawaited(
        draftStore is HybridChatDraftStore
            ? draftStore.saveLocalDraft(draftKey, nextText)
            : draftStore.saveDraft(draftKey, nextText),
      );
    }

    if (_messageFocusNode.hasFocus ||
        _selectedEdit != null ||
        _selectedForward != null ||
        _selectedForwardBatch != null) {
      return;
    }

    _isApplyingDraft = true;
    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextText.length),
    );
    _isApplyingDraft = false;
    _lastPersistedDraftKey = draftKey;
  }

  void _ensureTypingDecayTimer() {
    _typingDecayTimer ??=
        Timer.periodic(const Duration(seconds: 1), (_) => _pruneTypingUsers());
  }

  void _pruneTypingUsers() {
    if (!mounted) {
      _typingDecayTimer?.cancel();
      _typingDecayTimer = null;
      return;
    }

    final now = DateTime.now();
    final expiredUserIds = _typingUsers.entries
        .where((entry) => !entry.value.isAfter(now))
        .map((entry) => entry.key)
        .toList();
    if (expiredUserIds.isEmpty) {
      return;
    }

    setState(() {
      for (final userId in expiredUserIds) {
        _typingUsers.remove(userId);
      }
      if (_typingUsers.isEmpty) {
        _typingDecayTimer?.cancel();
        _typingDecayTimer = null;
      }
    });
  }

  void _handleTypingChanged() {
    final hasInput = _messageController.text.trim().isNotEmpty;
    if (hasInput) {
      unawaited(_setTypingActive(true));
    } else {
      unawaited(_setTypingActive(false));
    }
  }

  Future<void> _setTypingActive(bool isTyping, {bool force = false}) async {
    final chatId = _chatId;
    if (_realtimeService == null || chatId == null || chatId.isEmpty) {
      return;
    }

    if (!force && _typingHeartbeatActive == isTyping) {
      return;
    }

    _typingHeartbeatActive = isTyping;
    if (isTyping) {
      _typingHeartbeatTimer?.cancel();
      await _realtimeService!.sendTypingState(chatId: chatId, isTyping: true);
      _typingHeartbeatTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) {
          final stillTyping = _messageController.text.trim().isNotEmpty;
          if (!stillTyping) {
            unawaited(_setTypingActive(false));
            return;
          }
          unawaited(
            _realtimeService!.sendTypingState(chatId: chatId, isTyping: true),
          );
        },
      );
      return;
    }

    _typingHeartbeatTimer?.cancel();
    _typingHeartbeatTimer = null;
    await _realtimeService!.sendTypingState(chatId: chatId, isTyping: false);
  }

  String _pinnedPreviewLabel(ChatPinnedMessageSnapshot snapshot) {
    final text = snapshot.text.trim();
    if (text.isNotEmpty) {
      return text;
    }
    if (snapshot.attachmentCount > 0) {
      return _attachmentCountLabel(snapshot.attachmentCount);
    }
    return 'Сообщение без текста';
  }

  void _highlightPinnedMessage(String messageId) {
    _pinnedMessageHighlightTimer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      _highlightedPinnedMessageId = messageId;
    });
    _pinnedMessageHighlightTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _highlightedPinnedMessageId != messageId) {
        return;
      }
      setState(() {
        _highlightedPinnedMessageId = null;
      });
    });
  }

  Future<void> _focusMessageById(String messageId) async {
    final normalizedMessageId = messageId.trim();
    if (normalizedMessageId.isEmpty) {
      return;
    }

    if (_isSearchMode) {
      _closeSearch();
    }

    final visibleContext =
        _remoteMessageKeys[normalizedMessageId]?.currentContext;
    if (visibleContext != null) {
      _highlightPinnedMessage(normalizedMessageId);
      await Scrollable.ensureVisible(
        visibleContext,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.18,
      );
      return;
    }

    if (!_messagesScrollController.hasClients) {
      return;
    }

    final messageIndex = _latestRemoteMessages.indexWhere(
      (message) => message.id == normalizedMessageId,
    );
    if (messageIndex == -1) {
      if (mounted) {
        showAppSnackBar(context, 'Исходное сообщение пока не загружено.');
      }
      return;
    }

    final targetMessage = _latestRemoteMessages[messageIndex];
    final estimatedTextHeight =
        ((targetMessage.text.trim().length / 34).ceil().clamp(1, 7) * 18)
            .toDouble();
    final estimatedAttachmentsHeight =
        targetMessage.attachments.isEmpty ? 0.0 : 160.0;
    final estimatedOffset =
        messageIndex * 112.0 + estimatedTextHeight + estimatedAttachmentsHeight;
    final clampedOffset = estimatedOffset.clamp(
      0.0,
      _messagesScrollController.position.maxScrollExtent,
    );
    await _messagesScrollController.animateTo(
      clampedOffset,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) {
      return;
    }
    _highlightPinnedMessage(normalizedMessageId);
    final resolvedContext =
        _remoteMessageKeys[normalizedMessageId]?.currentContext;
    if (resolvedContext != null && resolvedContext.mounted) {
      await Scrollable.ensureVisible(
        resolvedContext,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: 0.18,
      );
    }
  }

  Future<void> _focusPinnedMessage() async {
    final pinned = _pinnedMessage;
    if (pinned == null) {
      return;
    }
    await _focusMessageById(pinned.messageId);
  }

  void _handleSearchChanged() {
    if (!mounted) {
      return;
    }
    final query = _searchController.query;
    final chatId = _chatId;
    if (query.isEmpty || chatId == null || chatId.isEmpty) {
      _serverSearchDebounce?.cancel();
      setState(_clearServerSearchState);
      return;
    }

    if (_serverSearchAvailable) {
      _scheduleServerSearch(query, chatId);
    }
    setState(() {});
  }

  void _openSearch() {
    _searchController.open();
  }

  void _closeSearch() {
    _searchController.close();
  }

  bool _messageMatchesSearch(String text) {
    return _searchController.matches(text);
  }

  int _searchMatchCount(
    List<ChatMessage> remoteMessages,
    List<_OutgoingMessage> optimisticMessages,
    int? serverResultCount,
  ) {
    if (!_searchController.hasQuery) {
      return 0;
    }
    if (serverResultCount != null) {
      return serverResultCount +
          optimisticMessages
              .where((message) => _messageMatchesSearch(message.text))
              .length;
    }
    return remoteMessages
            .where((message) => _messageMatchesSearch(message.text))
            .length +
        optimisticMessages
            .where((message) => _messageMatchesSearch(message.text))
            .length;
  }

  void _clearServerSearchState() {
    _serverSearchResults = const <ChatMessageSearchResult>[];
    _serverSearchQuery = '';
    _serverSearchError = null;
    _isServerSearchLoading = false;
  }

  void _scheduleServerSearch(String query, String chatId) {
    if (!_serverSearchAvailable) {
      return;
    }
    _serverSearchDebounce?.cancel();
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty || chatId.isEmpty) {
      return;
    }
    if (_serverSearchQuery != normalizedQuery || _serverSearchError != null) {
      _serverSearchQuery = normalizedQuery;
      _serverSearchResults = const <ChatMessageSearchResult>[];
      _serverSearchError = null;
    }
    _isServerSearchLoading = true;
    _serverSearchDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_runServerSearch(query: normalizedQuery, chatId: chatId));
    });
  }

  Future<void> _runServerSearch({
    required String query,
    required String chatId,
  }) async {
    try {
      final results = await _chatService.searchMessages(
        query: query,
        chatId: chatId,
        limit: 100,
      );
      if (!mounted || _searchController.query != query || _chatId != chatId) {
        return;
      }
      setState(() {
        _serverSearchQuery = query;
        _serverSearchResults = results;
        _serverSearchError = null;
        _isServerSearchLoading = false;
      });
    } on UnsupportedError {
      if (!mounted) {
        return;
      }
      setState(() {
        _serverSearchAvailable = false;
        _clearServerSearchState();
      });
    } catch (error) {
      if (!mounted || _searchController.query != query || _chatId != chatId) {
        return;
      }
      setState(() {
        _serverSearchQuery = query;
        _serverSearchError = error;
        _isServerSearchLoading = false;
      });
    }
  }

  bool get _hasCurrentServerSearchResult {
    return _searchController.hasQuery &&
        _serverSearchAvailable &&
        _serverSearchQuery == _searchController.query &&
        !_isServerSearchLoading &&
        _serverSearchError == null;
  }

  String _searchStatusLabel(int matchCount) {
    if (_isServerSearchLoading &&
        _serverSearchQuery == _searchController.query &&
        matchCount == 0) {
      return 'Ищем сообщения...';
    }
    if (_serverSearchError != null &&
        _serverSearchQuery == _searchController.query &&
        matchCount == 0) {
      return 'Поиск временно локальный';
    }
    return matchCount == 1
        ? 'Найдено 1 сообщение'
        : 'Найдено $matchCount сообщений';
  }

  void _handleMessagesScroll() {
    if (!_messagesScrollController.hasClients) {
      return;
    }
    final shouldShow = _messagesScrollController.offset > 120;
    if (shouldShow != _showJumpToLatestButton && mounted) {
      setState(() {
        _showJumpToLatestButton = shouldShow;
        if (!shouldShow) {
          // Дошли до низа — «новые снизу» прочитаны глазами.
          _newBelowViewportCount = 0;
        }
      });
    }
    _updateFloatingDayHeader();
    _updateUnreadChipVisibility();
  }

  /// Чип «N новых» показывается, пока разделитель непрочитанного выше
  /// вьюпорта И юзер отскроллен от низа. Если разделитель построен —
  /// сравниваем его глобальный dy с верхом вьюпорта (reverse-список:
  /// старое сверху); если он за cacheExtent (context == null) — fallback
  /// по времени: самый верхний видимый баббл НОВЕЕ якоря ⇒ разделитель
  /// выше. Гейт offset>120 не даёт чипу висеть, когда мы у низа и всё
  /// увидели (ревью батча: иначе timestamp-fallback вечно true у низа).
  void _updateUnreadChipVisibility() {
    if (!mounted) return;
    final anchorId = _unreadAnchorMessageId;
    bool above = false;
    final scrolledUp = _messagesScrollController.hasClients &&
        _messagesScrollController.offset > 120;
    if (anchorId != null && scrolledUp) {
      final dividerContext = _unreadDividerKey.currentContext;
      final dividerBox = dividerContext?.findRenderObject();
      if (dividerBox is RenderBox && dividerBox.attached) {
        final dy = dividerBox.localToGlobal(Offset.zero).dy;
        final viewportTop = _messagesViewportTopEdge();
        above = dy < viewportTop;
      } else if (dividerContext == null) {
        final anchorMessage = _findMessageById(anchorId);
        // Переиспользуем topmost из _updateFloatingDayHeader (в scroll-
        // пути он свежий и обходит ключи ОДИН раз); в post-frame пути,
        // где day-header не считался, добираем собственным обходом.
        final topmostVisible =
            _topmostVisibleRemoteMessage ?? _topmostVisibleMessage();
        if (anchorMessage != null && topmostVisible != null) {
          above = topmostVisible.timestamp.isAfter(anchorMessage.timestamp);
        }
      }
    }
    if (above != _unreadDividerAboveViewport) {
      setState(() => _unreadDividerAboveViewport = above);
    }
  }

  /// Пересчёт видимости чипа после кадра — нужен, когда состояние
  /// изменилось БЕЗ скролла (открытие чата с большим завалом: initial-
  /// jump молча не сработал за cacheExtent; приход снапшота сдвинул
  /// якорь). Дедуп через флаг, чтобы не копить колбэки на каждый build.
  bool _unreadChipRecomputeScheduled = false;
  void _scheduleUnreadChipRecompute() {
    if (_unreadChipRecomputeScheduled) return;
    _unreadChipRecomputeScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _unreadChipRecomputeScheduled = false;
      _updateUnreadChipVisibility();
    });
  }

  double _messagesViewportTopEdge() {
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached) {
      return box.localToGlobal(Offset.zero).dy;
    }
    return 0;
  }

  ChatMessage? _topmostVisibleMessage() {
    ChatMessage? best;
    double bestDy = double.infinity;
    for (final entry in _remoteMessageKeys.entries) {
      final renderObject = entry.value.currentContext?.findRenderObject();
      if (renderObject is! RenderBox || !renderObject.attached) {
        continue;
      }
      final dy = renderObject.localToGlobal(Offset.zero).dy;
      if (dy >= -8 && dy < bestDy) {
        bestDy = dy;
        best = _findMessageById(entry.key);
      }
    }
    return best;
  }

  /// Walks the live remote-bubble GlobalKeys and finds the one closest
  /// to the top edge of the messages viewport. The day of that message
  /// is the floating-header value. We also bring the header in for ~1.2s
  /// after each scroll event, then fade it back out — same TG / iOS
  /// "show date while scrolling" pattern.
  void _updateFloatingDayHeader() {
    if (!mounted) return;
    // Плавающая плашка дня дублирует разделитель в списке, когда тот и так
    // на экране: история короткая (не скроллится) или проскроллена до
    // самого начала, где первый разделитель стоит прямо под шапкой.
    if (_messagesScrollController.hasClients) {
      final position = _messagesScrollController.position;
      if (position.maxScrollExtent <= 0 ||
          position.pixels >= position.maxScrollExtent - 4) {
        if (_floatingHeaderVisible) {
          setState(() => _floatingHeaderVisible = false);
        }
        return;
      }
    }
    DateTime? bestDay;
    ChatMessage? bestMessage;
    double bestDy = double.infinity;
    for (final entry in _remoteMessageKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.attached) continue;
      final pos = box.localToGlobal(Offset.zero);
      // Items that scrolled above the viewport have negative dy. We
      // pick the highest one that is still within the visible area
      // (smallest non-negative dy) — that's the one whose day pill
      // should anchor at the top.
      if (pos.dy >= -8 && pos.dy < bestDy) {
        bestDy = pos.dy;
        final msg = _findMessageById(entry.key);
        if (msg != null) {
          bestDay = msg.timestamp;
          bestMessage = msg;
        }
      }
    }
    // Стэшим topmost — чип переиспользует его вместо второго обхода.
    _topmostVisibleRemoteMessage = bestMessage;
    if (bestDay != null && bestDay != _floatingDayHeader) {
      setState(() => _floatingDayHeader = bestDay);
    }
    // Visibility timer: header fades in immediately on scroll, fades
    // out 1.2s after the user stops scrolling.
    if (!_floatingHeaderVisible && mounted) {
      setState(() => _floatingHeaderVisible = true);
    }
    _floatingHeaderHideTimer?.cancel();
    _floatingHeaderHideTimer = Timer(
      const Duration(milliseconds: 1200),
      () {
        if (!mounted) return;
        setState(() => _floatingHeaderVisible = false);
      },
    );
  }

  ChatMessage? _findMessageById(String id) {
    for (final m in _latestRemoteMessages) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<void> _jumpToLatestMessages() async {
    if (!_messagesScrollController.hasClients) {
      return;
    }
    await _messagesScrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _showJumpToLatestButton = false;
      _unreadAnchorMessageId = null;
      _newBelowViewportCount = 0;
      _unreadDividerAboveViewport = false;
    });
  }

  /// Тап по чипу «N новых»: к разделителю непрочитанного. Построен —
  /// плавный ensureVisible; за cacheExtent — через _focusMessageById по
  /// id якоря (оценка оффсета по индексу + добор), а не прыжок в самое
  /// начало истории maxScrollExtent, который уводил юзера мимо (ревью).
  Future<void> _scrollToUnreadDivider() async {
    final dividerContext = _unreadDividerKey.currentContext;
    if (dividerContext != null) {
      await Scrollable.ensureVisible(
        dividerContext,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
      return;
    }
    final anchorId = _unreadAnchorMessageId;
    if (anchorId == null) {
      return;
    }
    // Разделитель рендерится прямо перед якорным сообщением — скролл к
    // якорю выводит и разделитель.
    await _focusMessageById(anchorId);
  }

  void _updateUnreadAnchor(List<ChatMessage> remoteMessages) {
    final unreadIncoming = remoteMessages
        .where(
          (message) =>
              message.senderId != _currentUserId && message.isRead == false,
        )
        .toList();
    if (unreadIncoming.isNotEmpty) {
      _unreadAnchorMessageId = unreadIncoming.last.id;
    }
  }

  void _scheduleUnreadJumpIfNeeded() {
    if (_didInitialUnreadJump || _unreadAnchorMessageId == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        return;
      }
      final context = _unreadDividerKey.currentContext;
      if (context == null) {
        return;
      }
      _didInitialUnreadJump = true;
      await Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        alignment: 0.12,
      );
    });
  }

  bool _matchesRemoteMessage(
    _OutgoingMessage localMessage,
    List<ChatMessage> remoteMessages,
  ) {
    return remoteMessages.any((message) {
      return message.clientMessageId != null &&
          message.clientMessageId == localMessage.localId;
    });
  }

  Future<void> _openChatInfo() async {
    final details = _chatDetails;
    final currentUserId = _currentUserId;
    if (details == null || currentUserId == null || currentUserId.isEmpty) {
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ChatInfoSheet(
        initialDetails: details,
        currentUserId: currentUserId,
        // Снапшот присутствия на момент открытия — строки участников
        // показывают «в сети»/«был(а) …» (шит и так работает по
        // снапшоту details, live-обновления внутри шита не нужны).
        onlineUserIds: Set<String>.of(_onlineUserIds),
        lastSeenByUserId: Map<String, DateTime>.of(_peerLastSeenAt),
        hasPinnedMessage: _pinnedMessage != null,
        initialNotificationLevel: _notificationSettings.level,
        initialAutoDeleteOption: _autoDeleteSettings.option,
        onRename: (title) async {
          final updatedDetails = await _chatService.renameGroupChat(
            chatId: details.chatId,
            title: title,
          );
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
            _resolvedTitle = updatedDetails.displayTitleFor(_currentUserId);
          });
          return updatedDetails;
        },
        onUpdatePhoto: (photo) async {
          final updatedDetails = await _chatService.updateGroupChatPhoto(
            chatId: details.chatId,
            photo: photo,
          );
          unawaited(
              _chatDetailsCache?.write(updatedDetails.chatId, updatedDetails));
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
            _resolvedTitle = updatedDetails.displayTitleFor(_currentUserId);
          });
          return updatedDetails;
        },
        onAddParticipants: (participantIds) async {
          final updatedDetails = await _chatService.addGroupParticipants(
            chatId: details.chatId,
            participantIds: participantIds,
          );
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
          });
          return updatedDetails;
        },
        onRemoveParticipant: (participantId) async {
          final updatedDetails = await _chatService.removeGroupParticipant(
            chatId: details.chatId,
            participantId: participantId,
          );
          if (!mounted) {
            return updatedDetails;
          }
          setState(() {
            _chatDetails = updatedDetails;
          });
          return updatedDetails;
        },
        onOpenDirectChat: (participant) {
          Navigator.of(context).pop();
          unawaited(_openDirectChatForParticipant(participant));
        },
        onLeaveGroup: () async {
          // G2: выходим из группы. После выхода чат недоступен — закрываем
          // шит и уходим к списку чатов; realtime-событие уберёт его из
          // списка у нас и обновит состав у остальных. Navigator/роутер
          // захватываем до await (контекст после него использовать нельзя).
          final navigator = Navigator.of(context);
          final router = GoRouter.of(context);
          await _chatService.leaveGroup(details.chatId);
          if (!mounted) {
            return;
          }
          navigator.pop(); // закрыть шит
          router.go('/chats');
        },
        onOpenSearch: () {
          Navigator.of(context).pop();
          _openSearch();
        },
        onOpenPinnedMessage: _pinnedMessage == null
            ? null
            : () {
                Navigator.of(context).pop();
                unawaited(_focusPinnedMessage());
              },
        onOpenTree: details.treeId == null || details.treeId!.trim().isEmpty
            ? null
            : () {
                Navigator.of(context).pop();
                context.push('/tree/view/${details.treeId}');
              },
        onOpenRelatives:
            details.treeId == null || details.treeId!.trim().isEmpty
                ? null
                : () {
                    Navigator.of(context).pop();
                    context.go('/relatives');
                  },
        onOpenMedia: () {
          Navigator.of(context).pop();
          unawaited(_openChatMediaGallery());
        },
        onOpenFiles: () {
          Navigator.of(context).pop();
          unawaited(_openChatFilesGallery());
        },
        onNotificationLevelChanged: _updateNotificationLevel,
        onAutoDeleteChanged: _updateAutoDeleteOption,
      ),
    );
  }

  String? _typingSubtitle() {
    if (_typingUsers.isEmpty) {
      return null;
    }

    final typingUserIds = _typingUsers.keys.toList();
    if (!widget.isGroup && typingUserIds.isNotEmpty) {
      return 'печатает…';
    }
    if (typingUserIds.length == 1) {
      return '${_participantLabelForUserId(typingUserIds.first)} печатает…';
    }
    return 'Печатают: ${typingUserIds.length}';
  }

  String? _presenceSubtitle(ChatDetails? details) {
    // S5: разрыв WS перекрывает presence — пока соединение не вернётся,
    // «в сети» всё равно может врать.
    if (_isRealtimeReconnecting) {
      return 'Подключение…';
    }
    final otherParticipantIds = _otherParticipantIds(details);
    if (otherParticipantIds.isEmpty) {
      return null;
    }

    final onlineCount = otherParticipantIds
        .where((participantId) => _onlineUserIds.contains(participantId))
        .length;

    if (widget.isGroup) {
      if (onlineCount == 0) {
        return null;
      }
      return onlineCount == 1 ? '1 участник в сети' : '$onlineCount в сети';
    }

    // Direct chat — single peer presence drives the subtitle. Either
    // "в сети" (live) or "был(а) N минут назад" derived from the
    // last-seen timestamp populated by chat-details + presence events.
    if (onlineCount > 0) {
      return 'в сети';
    }
    final peerId =
        otherParticipantIds.isNotEmpty ? otherParticipantIds.first : null;
    if (peerId == null) {
      return null;
    }
    final lastSeen = _peerLastSeenAt[peerId];
    if (lastSeen == null) {
      return null;
    }
    return _formatLastSeen(lastSeen, peerId: peerId, details: details);
  }

  /// "был(а) N минут назад" formatter. Prefers gendered Russian forms
  /// when the participant has a known gender hint in the chat details
  /// (currently we don't carry gender on ChatParticipantSummary, so we
  /// default to feminine "была" if the display name ends with a vowel —
  /// a reasonable heuristic for Russian first names).
  String _formatLastSeen(
    DateTime lastSeen, {
    required String peerId,
    required ChatDetails? details,
  }) {
    final delta = DateTime.now().difference(lastSeen);
    final female = _looksFemaleName(_participantLabelForUserId(peerId));
    final byl = female ? 'была' : 'был';

    if (delta.inSeconds < 60) {
      return '$byl только что';
    }
    if (delta.inMinutes < 60) {
      final m = delta.inMinutes;
      return '$byl $m ${_minutesSuffix(m)} назад';
    }
    if (delta.inHours < 24) {
      final h = delta.inHours;
      return '$byl $h ${_hoursSuffix(h)} назад';
    }
    if (delta.inDays < 7) {
      final d = delta.inDays;
      return '$byl $d ${_daysSuffix(d)} назад';
    }
    // Older than a week — fall back to a date string (локальная дата:
    // UTC-компоненты у полуночи давали соседний день).
    final local = toLocalForDisplay(lastSeen);
    final date =
        '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}';
    return '$byl $date';
  }

  bool _looksFemaleName(String displayName) {
    final firstName = displayName.trim().split(RegExp(r'\s+')).first;
    if (firstName.isEmpty) return false;
    final last = firstName[firstName.length - 1].toLowerCase();
    // Russian feminine first names overwhelmingly end in 'а' or 'я'.
    return last == 'а' || last == 'я';
  }

  String _minutesSuffix(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'минуту';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'минуты';
    }
    return 'минут';
  }

  String _hoursSuffix(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'час';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'часа';
    }
    return 'часов';
  }

  String _daysSuffix(int n) {
    final mod10 = n % 10;
    final mod100 = n % 100;
    if (mod10 == 1 && mod100 != 11) return 'день';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) return 'дня';
    return 'дней';
  }

  List<String> _otherParticipantIds(ChatDetails? details) {
    final currentUserId = _currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return const <String>[];
    }

    final participantIds = <String>{
      ...?details?.participantIds,
      ..._latestRemoteMessages.expand((message) => message.participants),
      if (widget.otherUserId != null && widget.otherUserId!.isNotEmpty)
        widget.otherUserId!,
    };

    participantIds.removeWhere(
      (participantId) =>
          participantId.trim().isEmpty || participantId == currentUserId,
    );
    return participantIds.toList();
  }

  ChatParticipantSummary? _participantForUserId(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return null;
    }
    final details = _chatDetails;
    if (details == null) {
      return null;
    }
    for (final participant in details.participants) {
      if (participant.userId == normalizedUserId) {
        return participant;
      }
    }
    return null;
  }

  String _participantLabelForUserId(String userId) {
    final participant = _participantForUserId(userId);
    if (participant != null && participant.displayName.trim().isNotEmpty) {
      return participant.displayName;
    }

    for (final message in _latestRemoteMessages) {
      if (message.senderId == userId &&
          (message.senderName?.trim().isNotEmpty ?? false)) {
        return message.senderName!.trim();
      }
    }

    return 'Участник';
  }

  Future<void> _openDirectChatForParticipant(
    ChatParticipantSummary participant,
  ) {
    return _openDirectChatForUser(
      userId: participant.userId,
      title: participant.displayName,
      photoUrl: participant.photoUrl,
    );
  }

  Future<void> _openDirectChatForMessage(ChatMessage message) {
    final participant = _participantForUserId(message.senderId);
    return _openDirectChatForUser(
      userId: message.senderId,
      title: participant?.displayName ?? message.senderName ?? 'Участник',
      photoUrl: participant?.photoUrl,
    );
  }

  Future<void> _openDirectChatForUser({
    required String userId,
    required String title,
    String? photoUrl,
  }) async {
    final normalizedUserId = userId.trim();
    final currentUserId = _currentUserId?.trim();
    if (normalizedUserId.isEmpty ||
        currentUserId == null ||
        normalizedUserId == currentUserId) {
      return;
    }

    try {
      final chatId = await _chatService.getOrCreateChat(normalizedUserId);
      if (!mounted) {
        return;
      }
      if (chatId == null || chatId.trim().isEmpty) {
        showAppSnackBar(
          context,
          'Не удалось открыть личный чат.',
          isError: true,
        );
        return;
      }

      final resolvedTitle = title.trim().isNotEmpty
          ? title.trim()
          : _participantLabelForUserId(normalizedUserId);
      final resolvedPhoto = photoUrl != null && photoUrl.trim().isNotEmpty
          ? photoUrl.trim()
          : null;
      final openInParent = widget.onOpenDirectChat;
      if (openInParent != null) {
        openInParent(
          chatId: chatId.trim(),
          title: resolvedTitle,
          photoUrl: resolvedPhoto,
          otherUserId: normalizedUserId,
        );
        return;
      }

      final titleParam = Uri.encodeComponent(resolvedTitle);
      final userParam = Uri.encodeComponent(normalizedUserId);
      final photoParam = resolvedPhoto == null
          ? ''
          : '&photo=${Uri.encodeComponent(resolvedPhoto)}';
      await context.push(
        '/chats/view/${Uri.encodeComponent(chatId.trim())}'
        '?type=direct&title=$titleParam&userId=$userParam$photoParam',
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Не удалось открыть личный чат.',
        isError: true,
      );
    }
  }

  String _chatSubtitle() {
    final typingSubtitle = _typingSubtitle();
    if (typingSubtitle != null) {
      return typingSubtitle;
    }

    final details = _chatDetails;
    final presenceSubtitle = _presenceSubtitle(details);
    if (presenceSubtitle != null) {
      return presenceSubtitle;
    }
    if (details != null && details.isBranch) {
      final branchCount = details.branchRoots.length;
      final memberCount = details.memberCount;
      final branchLabel = branchCount == 1 ? '1 ветка' : '$branchCount ветки';
      final memberLabel =
          memberCount == 1 ? '1 участник' : '$memberCount участников';
      return '$branchLabel · $memberLabel';
    }
    if (details != null && details.isGroup) {
      final memberCount = details.memberCount;
      return memberCount == 1 ? '1 участник' : '$memberCount участников';
    }
    return widget.chatType == 'branch'
        ? 'Чат ветки'
        : (widget.isGroup ? 'Групповой чат' : 'Личные сообщения');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _selectionController,
      builder: (context, _) => Scaffold(
        appBar: _buildChatAppBar(context),
        body: Stack(
          children: [
            _buildChatBody(context),
            // C3d/V2 (FR8): инлайн-рекордер кружка поверх чата — чат виден за
            // затемнением, без отдельного экрана и его лага.
            if (_showInlineKruzhok)
              Positioned.fill(
                child: KruzhokRecorderScreen(
                  embedded: true,
                  onCaptured: _onInlineKruzhokCaptured,
                  onCancelled: _onInlineKruzhokCancel,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// C3d/V2 (FR8): кружок записан инлайн-оверлеем — прячем оверлей и кладём
  /// результат во вложения (та же проверка размера, что и у роутового пути).
  Future<void> _onInlineKruzhokCaptured(XFile picked) async {
    if (mounted) {
      setState(() => _showInlineKruzhok = false);
    }
    try {
      final size = await picked.length();
      if (size > 50 * 1024 * 1024) {
        if (mounted) {
          showAppSnackBar(
            context,
            'Видео слишком большое (макс. 50 МБ).',
            isError: true,
          );
        }
        return;
      }
      _attachmentsController.replaceAll(<XFile>[picked]);
    } catch (_) {
      if (mounted) {
        showAppSnackBar(
          context,
          'Не удалось подготовить кружок.',
          isError: true,
        );
      }
    }
  }

  void _onInlineKruzhokCancel() {
    if (mounted) {
      setState(() => _showInlineKruzhok = false);
    }
  }

  /// Compact inline recording bar shown while the user is holding the mic.
  /// Replaces the entire input area — no popups, no panels — pure Telegram style.
  ///
  /// C2: бар перерисовывается через AnimatedBuilder на самом контроллере,
  /// так что живая волна (по амплитуде, ~120мс) и таймер обновляются без
  /// setState всего экрана. Слушатель экрана при этом пропускает
  /// amplitude-only нотификации.
  Widget _buildActiveRecordingInputBar() {
    final scheme = Theme.of(context).colorScheme;
    final recColor = scheme.error;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        8,
        4,
        8,
        MediaQuery.of(context).padding.bottom + 8,
      ),
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        borderRadius: BorderRadius.circular(28),
        child: AnimatedBuilder(
          animation: _recordingController,
          builder: (context, _) {
            final theme = Theme.of(context);
            final minutes = (_recordingController.durationSeconds ~/ 60)
                .toString()
                .padLeft(2, '0');
            final seconds = (_recordingController.durationSeconds % 60)
                .toString()
                .padLeft(2, '0');
            final waveform = _recordingController.liveWaveform;
            // Voice-cancel зона: слушаем dx слайда — подсказка едет за
            // пальцем и гаснет, кнопка отмены «наливается» красным и
            // раскрывает корзину у порога. Существующая подсказка/волна
            // остаются как есть (тест-контракт: '← отмена  ↑ фиксация' и
            // ключ 'recording-live-waveform' взаимоисключающи) — при
            // progress == 0 слои отмены полностью прозрачны.
            return ValueListenableBuilder<double>(
              valueListenable: _recordingDragDx,
              builder: (context, dragDx, _) {
                final progress = (-dragDx / _recordingCancelThreshold)
                    .clamp(0.0, 1.0)
                    .toDouble();
                final trashRevealed = progress > 0.6;
                return Row(
                  children: [
                    // Cancel: кольцо-подсветка растёт с прогрессом слайда,
                    // у порога иконка сменяется корзиной.
                    Transform.scale(
                      scale: 1.0 + 0.25 * progress,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: recColor.withValues(
                            alpha: 0.10 + 0.35 * progress,
                          ),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          onPressed: _cancelRecording,
                          tooltip: 'Отменить',
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 120),
                            child: Icon(
                              trashRevealed
                                  ? Icons.delete_outline_rounded
                                  : Icons.close_rounded,
                              key: ValueKey(trashRevealed),
                              color: recColor,
                            ),
                          ),
                        ),
                      ),
                    ),
                    _PulsingDot(color: recColor),
                    const SizedBox(width: 8),
                    // C2: крупный таймер моноширинными цифрами.
                    Text(
                      '$minutes:$seconds',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        color: recColor,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // C2: живая волна по амплитуде вместо статичной
                    // подсказки; поверх — «← Отмена», едущая за пальцем.
                    Expanded(
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Opacity(
                            opacity: 1.0 - progress,
                            child: waveform.isEmpty
                                ? Text(
                                    '← отмена  ↑ фиксация',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  )
                                : SizedBox(
                                    height: 28,
                                    child: CustomPaint(
                                      key: const Key('recording-live-waveform'),
                                      painter: _VoiceWaveformPainter(
                                        waveform: waveform,
                                        progress: 1.0,
                                        activeColor: recColor,
                                        inactiveColor:
                                            recColor.withValues(alpha: 0.30),
                                      ),
                                      size: Size.infinite,
                                    ),
                                  ),
                          ),
                          if (progress > 0)
                            IgnorePointer(
                              child: Transform.translate(
                                offset: Offset(dragDx * 0.6, 0),
                                child: Opacity(
                                  opacity: (1.0 - progress).clamp(0.25, 1.0),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.chevron_left_rounded,
                                        size: 18,
                                        color: recColor,
                                      ),
                                      Text(
                                        'Отмена',
                                        style:
                                            theme.textTheme.bodySmall?.copyWith(
                                          color: recColor,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    // C3a/V1: чисто визуальная мик-кнопка. Жест press-hold
                    // ведёт персистентный Listener над композером (см.
                    // _buildMessageInputArea) — отдельный recognizer тут не
                    // видел pointer-down и не получал onLongPressEnd на lift.
                    _PulsingMicButton(color: recColor),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Locked-state recording bar (user swiped up to lock).
  /// Compact single row — cancel on left, timer + label in centre, send on right.
  Widget _buildRecordingArea() {
    final theme = Theme.of(context);
    final minutes =
        (_recordingController.durationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds =
        (_recordingController.durationSeconds % 60).toString().padLeft(2, '0');
    final errorColor = theme.colorScheme.error;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        8,
        4,
        8,
        MediaQuery.of(context).padding.bottom + 8,
      ),
      child: GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        borderRadius: BorderRadius.circular(28),
        child: Row(
          children: [
            // Cancel
            IconButton(
              onPressed: _cancelRecording,
              tooltip: 'Отменить запись',
              icon: Icon(Icons.delete_outline_rounded, color: errorColor),
            ),
            // Pulsing dot + timer
            _PulsingDot(color: errorColor),
            const SizedBox(width: 8),
            Text(
              '$minutes:$seconds',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: errorColor,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Зафиксировано',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Send button
            IconButton.filled(
              onPressed: _stopAndSendRecording,
              tooltip: 'Отправить',
              icon: const Icon(Icons.send_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceAttachmentPreview(XFile voiceFile) {
    final theme = Theme.of(context);
    final hasRecordedPreview = _isRecordedVoiceAttachment(voiceFile);
    final durationLabel = hasRecordedPreview
        ? _formatDurationLabel(_recordingController.previewDurationSeconds)
        : 'Аудио';
    final recordingState = _recordingController.state;
    final helperText = recordingState == ChatRecordingState.sending
        ? 'Отправляем голосовое...'
        : recordingState == ChatRecordingState.failed
            ? (_recordingController.errorText ??
                'Не удалось отправить голосовое. Можно попробовать снова.')
            : 'Можно перезаписать или отправить.';
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.55),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Проверьте голосовое',
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  durationLabel,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _VoicePlayerWidget(
            path: voiceFile.path,
            isMe: true,
            waveform: _recordingController.previewWaveform,
          ),
          const SizedBox(height: 4),
          Text(
            helperText,
            style: theme.textTheme.bodySmall?.copyWith(
              color: recordingState == ChatRecordingState.failed
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              children: [
                if (hasRecordedPreview) ...[
                  TextButton.icon(
                    onPressed: recordingState == ChatRecordingState.sending
                        ? null
                        : _rerecordVoiceAttachment,
                    icon: const Icon(Icons.mic_none_rounded),
                    label: const Text('Перезаписать'),
                  ),
                  TextButton.icon(
                    onPressed: recordingState == ChatRecordingState.sending
                        ? null
                        : _discardPendingVoiceAttachment,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Удалить запись'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDurationLabel(int durationSeconds) {
    final minutes = (durationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (durationSeconds % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  Widget _buildMessagesBody() {
    if (_isBootstrapping) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_bootstrapError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: GlassPanel(
              borderRadius: BorderRadius.circular(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 40),
                  const SizedBox(height: 12),
                  Text(
                    _bootstrapError!,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _bootstrapChat,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Повторить'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return Center(
        child: GlassPanel(
          borderRadius: BorderRadius.circular(28),
          child: const Text('Чат недоступен.'),
        ),
      );
    }

    final timelineController = _timelineController;
    if (timelineController == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return StreamBuilder<List<ChatMessage>>(
      stream: timelineController.stream,
      // Hand StreamBuilder the controller's cached snapshot so the screen
      // doesn't flash a spinner on rebuilds (route swap, hot reload, app
      // resume) — the underlying chat service already has the messages
      // hydrated from Hive cache by the time we get here.
      initialData: timelineController.lastValue,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        // S1: первый кадр с сообщениями — конец замера открытия чата.
        final openTrace = _chatOpenTrace;
        if (openTrace != null && snapshot.hasData) {
          _chatOpenTrace = null;
          final count = snapshot.data?.length ?? 0;
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => openTrace.finish('$count messages'),
          );
        }

        // Stream errors fire on every API failure — including a
        // simple offline state where we already have cached messages
        // hydrated. If we have data, prefer to keep showing it and
        // surface the error only via the OfflineIndicator banner +
        // a quiet status snack on retry; full error screen only
        // when we have NOTHING to show.
        final hasCachedData =
            snapshot.hasData && (snapshot.data?.isNotEmpty ?? false);
        if (snapshot.hasError && !hasCachedData) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: GlassPanel(
                  borderRadius: BorderRadius.circular(28),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 40),
                      const SizedBox(height: 12),
                      Text(
                        _appStatusService.isOffline
                            ? 'Нет соединения. Сообщения появятся, когда интернет вернётся.'
                            : 'Не удалось загрузить сообщения.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () {
                          unawaited(timelineController.refresh());
                        },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Обновить'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        final remoteMessages = snapshot.data ?? const <ChatMessage>[];
        _latestRemoteMessages = remoteMessages;
        // First snapshot: hydrate _seenRemoteMessageIds with everything
        // we just got from the server so opening a chat doesn't animate
        // hundreds of messages at once. Subsequent snapshots will only
        // contain *new* ids that aren't in the set yet — those are the
        // ones the bubble enter animation should fire on.
        if (!_remoteHistoryHydrated && remoteMessages.isNotEmpty) {
          _seenRemoteMessageIds.addAll(remoteMessages.map((m) => m.id));
          _arrivalLedgerIds.addAll(remoteMessages.map((m) => m.id));
          // База «самое свежее, что видели» — по ней отличаем ГЕНУИННО
          // новое от старого, доехавшего смёрдженной страницей на
          // реконнекте (иначе бейдж раздувался на старые сообщения).
          for (final message in remoteMessages) {
            final seen = _newestArrivalSeen;
            if (seen == null || message.timestamp.isAfter(seen)) {
              _newestArrivalSeen = message.timestamp;
            }
          }
          _remoteHistoryHydrated = true;
        } else if (_remoteHistoryHydrated) {
          // Sticky unread: считаем НОВЫЕ входящие, пришедшие пока юзер
          // отскроллен вверх — бейдж на jump-FAB. Мутация поля в build —
          // установленный паттерн (_latestRemoteMessages строкой выше);
          // FAB строится ниже в этом же проходе.
          for (final message in remoteMessages) {
            final isFresh = _arrivalLedgerIds.add(message.id);
            final seen = _newestArrivalSeen;
            final isNewerThanBaseline =
                seen == null || message.timestamp.isAfter(seen);
            if (isFresh &&
                isNewerThanBaseline &&
                message.senderId != _currentUserId &&
                _messagesScrollController.hasClients &&
                _messagesScrollController.offset > 120) {
              _newBelowViewportCount += 1;
            }
            if (isNewerThanBaseline) {
              _newestArrivalSeen = message.timestamp;
            }
          }
        }
        _schedulePinnedSync(remoteMessages);
        final currentChatId = _chatId;
        if (currentChatId != null && currentChatId.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            unawaited(
              _sendQueue.confirmRemoteMessages(currentChatId, remoteMessages),
            );
          });
        }
        final optimisticMessages = _optimisticMessages
            .where((message) => !_matchesRemoteMessage(message, remoteMessages))
            .toList();
        final hasActiveSearch = _searchController.hasQuery;
        final hasServerSearchResult = _hasCurrentServerSearchResult;
        final serverSearchResultIds = hasServerSearchResult
            ? _serverSearchResults
                .map((result) => result.messageId)
                .where((messageId) => messageId.isNotEmpty)
                .toSet()
            : const <String>{};
        final filteredRemoteMessages = hasActiveSearch
            ? hasServerSearchResult
                ? remoteMessages
                    .where(
                        (message) => serverSearchResultIds.contains(message.id))
                    .toList()
                : remoteMessages
                    .where((message) => _messageMatchesSearch(message.text))
                    .toList()
            : remoteMessages;
        final filteredOptimisticMessages = hasActiveSearch
            ? optimisticMessages
                .where((message) => _messageMatchesSearch(message.text))
                .toList()
            : optimisticMessages;
        final loadedServerSearchIds = hasServerSearchResult
            ? filteredRemoteMessages.map((message) => message.id).toSet()
            : const <String>{};
        final serverOnlySearchResults = hasServerSearchResult
            ? _serverSearchResults
                .where(
                  (result) => !loadedServerSearchIds.contains(result.messageId),
                )
                .toList(growable: false)
            : const <ChatMessageSearchResult>[];
        final hasUnreadIncoming = !hasActiveSearch &&
            remoteMessages.any(
              (message) =>
                  message.senderId != _currentUserId && message.isRead == false,
            );
        if (!hasActiveSearch) {
          _updateUnreadAnchor(remoteMessages);
        }
        if (hasUnreadIncoming) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _markChatAsRead();
          });
        }

        if (filteredRemoteMessages.isEmpty &&
            filteredOptimisticMessages.isEmpty &&
            serverOnlySearchResults.isEmpty) {
          if (hasActiveSearch) {
            return Center(
              child: GlassPanel(
                borderRadius: BorderRadius.circular(24),
                child: Text(
                  'Ничего не найдено по запросу "${_searchController.query}"',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final isFriendsTree =
              context.read<TreeProvider>().selectedTreeKind == TreeKind.friends;
          return Center(
            child: GlassPanel(
              borderRadius: BorderRadius.circular(24),
              child: Text(
                isFriendsTree
                    ? 'Пока пусто. Начните разговор.'
                    : 'Пока пусто. Начните диалог.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        if (!hasActiveSearch) {
          _scheduleUnreadJumpIfNeeded();
          // Чип «N новых» появляется/обновляется и без скролла — когда
          // снапшот сдвинул якорь или чат открылся с завалом за
          // cacheExtent (там initial-jump молча не срабатывает).
          _scheduleUnreadChipRecompute();
        }
        String? latestOutgoingMessageId;
        if (!widget.isGroup) {
          for (final message in remoteMessages) {
            if (message.senderId == _currentUserId) {
              latestOutgoingMessageId = message.id;
              break;
            }
          }
        }
        final unreadAnchorMessageId = _unreadAnchorMessageId;
        final hasUnreadDivider = !hasActiveSearch &&
            unreadAnchorMessageId != null &&
            remoteMessages
                .any((message) => message.id == unreadAnchorMessageId);
        // «N новых» для плавающего чипа: входящие от якоря (самое старое
        // непрочитанное) до свежайшего. Список newest-first — это
        // индексы 0..anchorIndex.
        var unreadChipCount = 0;
        if (hasUnreadDivider) {
          final anchorIndex = remoteMessages
              .indexWhere((message) => message.id == unreadAnchorMessageId);
          for (var i = 0; i <= anchorIndex; i++) {
            if (remoteMessages[i].senderId != _currentUserId) {
              unreadChipCount += 1;
            }
          }
        }
        final searchMatchCount = _searchMatchCount(
          filteredRemoteMessages,
          filteredOptimisticMessages,
          hasServerSearchResult ? _serverSearchResults.length : null,
        );
        final searchStatusLabel = _searchStatusLabel(searchMatchCount);

        // When the peer starts typing, lift the message column by 20dp
        // so the most-recent bubble visually "anticipates" the
        // incoming message — same TG / iMessage subtle move that
        // tells you "hey, something's coming". Reverse ListView's
        // bottom-padding lives at the literal bottom of the viewport,
        // so growing it pushes the newest bubble up.
        final isPeerTyping = _typingUsers.isNotEmpty;
        return Stack(
          children: [
            AnimatedPadding(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.only(
                bottom: isPeerTyping ? 20 : 0,
              ),
              child: ListView.builder(
                controller: _messagesScrollController,
                reverse: true,
                padding: EdgeInsets.fromLTRB(
                  0,
                  hasActiveSearch ? 52 : 8,
                  0,
                  8,
                ),
                // Pre-render ~1.4 screens of bubbles in each scroll
                // direction (default is 250 px, which on a 1.5-meter
                // chat with photo carousels looked like a fresh build
                // every flick — the user reported jank when scrolling
                // through long histories). 1500 dp is roughly 3 phone
                // viewports of buffer; the trade-off is RAM, but
                // bubbles already cap their text + share an image
                // cache so the cost stays bounded.
                cacheExtent: 1500,
                itemCount: filteredRemoteMessages.length +
                    filteredOptimisticMessages.length +
                    serverOnlySearchResults.length +
                    (hasUnreadDivider ? 1 : 0),
                itemBuilder: (context, index) {
                  if (index < filteredOptimisticMessages.length) {
                    final localMessage = filteredOptimisticMessages[index];
                    return _buildOptimisticBubble(localMessage);
                  }

                  final remoteIndex = index - filteredOptimisticMessages.length;
                  if (hasUnreadDivider && remoteIndex >= 0) {
                    var remoteCursor = 0;
                    for (var msgIdx = 0;
                        msgIdx < filteredRemoteMessages.length;
                        msgIdx++) {
                      final message = filteredRemoteMessages[msgIdx];
                      if (message.id == unreadAnchorMessageId) {
                        if (remoteCursor == remoteIndex) {
                          return _buildUnreadDivider();
                        }
                        remoteCursor++;
                      }

                      if (remoteCursor == remoteIndex) {
                        final isMe = message.senderId == _currentUserId;
                        return _wrapBubbleWithDayHeader(
                          bubble: _buildRemoteBubble(
                            message,
                            isMe,
                            footerLabel: _messageFooterLabel(
                              message,
                              isMe: isMe,
                              isLatestOwnDirectMessage:
                                  message.id == latestOutgoingMessageId,
                            ),
                            isGroupedWithAbove: _isGroupedWithAbove(
                              filteredRemoteMessages,
                              msgIdx,
                            ),
                          ),
                          messages: filteredRemoteMessages,
                          messageIndex: msgIdx,
                        );
                      }
                      remoteCursor++;
                    }
                  }

                  final remoteItemCount = filteredRemoteMessages.length +
                      (hasUnreadDivider ? 1 : 0);
                  if (remoteIndex >= remoteItemCount) {
                    final resultIndex = remoteIndex - remoteItemCount;
                    return _buildServerSearchResultTile(
                      serverOnlySearchResults[resultIndex],
                    );
                  }

                  final messageIdx = remoteIndex - (hasUnreadDivider ? 1 : 0);
                  final remoteMessage = filteredRemoteMessages[messageIdx];
                  final isMe = remoteMessage.senderId == _currentUserId;
                  return _wrapBubbleWithDayHeader(
                    bubble: _buildRemoteBubble(
                      remoteMessage,
                      isMe,
                      footerLabel: _messageFooterLabel(
                        remoteMessage,
                        isMe: isMe,
                        isLatestOwnDirectMessage:
                            remoteMessage.id == latestOutgoingMessageId,
                      ),
                      isGroupedWithAbove: _isGroupedWithAbove(
                        filteredRemoteMessages,
                        messageIdx,
                      ),
                    ),
                    messages: filteredRemoteMessages,
                    messageIndex: messageIdx,
                  );
                },
              ),
            ),
            if (hasActiveSearch)
              Positioned(
                left: 12,
                right: 12,
                top: 8,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(
                      searchStatusLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
              ),
            // Floating date header — pill at the top of the viewport
            // showing the day of the topmost-visible message. Fades in
            // on scroll, fades out 1.2s after scrolling stops.
            if (_floatingDayHeader != null && !hasActiveSearch)
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 220),
                    curve: Curves.easeOutCubic,
                    opacity: _floatingHeaderVisible ? 1.0 : 0.0,
                    child: Center(
                      child: _buildDateDivider(_floatingDayHeader!),
                    ),
                  ),
                ),
              ),
            // Sticky unread: разделитель «Непрочитанные» ускроллен выше
            // вьюпорта (или вовсе за cacheExtent) — плавающий чип
            // «N новых» возвращает к нему одним тапом.
            if (_unreadDividerAboveViewport &&
                hasUnreadDivider &&
                unreadChipCount > 0 &&
                !hasActiveSearch)
              Positioned(
                top: 44,
                left: 0,
                right: 0,
                child: Center(
                  child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                      key: const ValueKey('unread-floating-chip'),
                      borderRadius: BorderRadius.circular(999),
                      onTap: _scrollToUnreadDivider,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer
                              .withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.25),
                            width: 0.6,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.keyboard_arrow_up_rounded,
                              size: 16,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onPrimaryContainer,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$unreadChipCount новых',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelSmall
                                  ?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onPrimaryContainer,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // Telegram-style entry: scale 0 → 1 with elastic overshoot
            // + fade. AnimatedSwitcher (vs AnimatedScale) actually
            // mounts / unmounts the FAB, so the existing test that
            // asserts findsNothing when there's nothing to scroll keeps
            // working — only the visual swap is animated.
            Positioned(
              right: 16,
              bottom: 18,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.elasticOut,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child),
                  );
                },
                child: _showJumpToLatestButton
                    // Бейдж с числом новых снизу (Telegram). Key живёт на
                    // Badge — AnimatedSwitcher диффит прямого ребёнка.
                    ? Badge.count(
                        key: const ValueKey('jump-to-latest-fab'),
                        count: _newBelowViewportCount,
                        isLabelVisible: _newBelowViewportCount > 0,
                        offset: const Offset(-2, 2),
                        child: FloatingActionButton.small(
                          heroTag: 'jump-to-latest',
                          onPressed: _jumpToLatestMessages,
                          tooltip: 'К последним сообщениям',
                          child: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('jump-to-latest-empty')),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildPinnedMessageBanner() {
    final pinned = _pinnedMessage!;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: InkWell(
        onTap: _focusPinnedMessage,
        borderRadius: BorderRadius.circular(24),
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          borderRadius: BorderRadius.circular(24),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 40,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(width: 10),
              const Icon(Icons.push_pin_outlined, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Закрепленное сообщение',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      pinned.senderName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _pinnedPreviewLabel(pinned),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => unawaited(_clearPinnedMessage()),
                tooltip: 'Открепить',
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnreadDivider() {
    final theme = Theme.of(context);
    return Padding(
      key: _unreadDividerKey,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Непрочитанные',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: theme.colorScheme.primary.withValues(alpha: 0.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageInputArea() {
    if (_isDirectChatBlocked) {
      return _buildBlockedComposerNotice();
    }

    final recordingState = _recordingController.state;
    final isLockedRecording = recordingState == ChatRecordingState.locked;
    final canSend = _messageController.text.trim().isNotEmpty ||
        _selectedAttachments.isNotEmpty ||
        _selectedForward != null ||
        _selectedForwardBatch != null ||
        _selectedEdit != null;

    // ── Compact Telegram-style recording UI ──
    // While the user is actively holding the mic, replace the whole input
    // area content with a minimal timer row so no big panel pops up.
    // We swap via AnimatedSwitcher so the recording bar fades + slides
    // in over the composer (220ms easeOutCubic) instead of appearing
    // as a hard cut. Same on the way back when recording stops.
    final isRecording = recordingState == ChatRecordingState.recording;
    // C3a/V1: персистентный Listener над AnimatedSwitcher'ом владеет циклом
    // press-hold (move/release) независимо от ребилда композер↔бар — иначе
    // на старте записи поддерево пересобирается и onLongPressEnd не приходит
    // на отпускание пальца.
    return Listener(
      // FX1/C3a FR1: этот композер-wide Listener ВЛАДЕЕТ только move/up/cancel
      // уже-захваченного recording-pointer (id ставит локальный Listener
      // мик-кнопки), но сам его НЕ назначает — иначе второе касание зоны
      // ввода перебивало бы привязку.
      onPointerMove: _handleRecordingPointerMove,
      onPointerUp: _handleRecordingPointerUp,
      onPointerCancel: _handleRecordingPointerCancel,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          return FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.08),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            ),
          );
        },
        child: isRecording
            ? KeyedSubtree(
                key: const ValueKey('composer-recording'),
                child: _buildActiveRecordingInputBar(),
              )
            : KeyedSubtree(
                key: const ValueKey('composer-idle'),
                child: _buildIdleComposer(canSend, isLockedRecording),
              ),
      ),
    );
  }

  /// Extracted from [_buildMessageInputArea] so the AnimatedSwitcher
  /// has a stable child key for the non-recording state. No behaviour
  /// change — this is the composer that used to be inlined.
  Widget _buildIdleComposer(bool canSend, bool isLockedRecording) {
    final recordingState = _recordingController.state;
    // Одна рамка, а не «овал в овале»: капсула композера и есть поле ввода
    // (как у Telegram), кнопки — плоские иконки внутри неё.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        6,
        2,
        6,
        MediaQuery.of(context).padding.bottom + 6,
      ),
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
        borderRadius: BorderRadius.circular(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Show mic permission / error notices (not the "recording" state —
            // that is now handled by _buildActiveRecordingInputBar above).
            if (recordingState == ChatRecordingState.denied ||
                recordingState == ChatRecordingState.failed)
              _buildRecordingNotice(
                Theme.of(context),
                recordingState: recordingState,
              ),
            if (recordingState == ChatRecordingState.denied ||
                recordingState == ChatRecordingState.failed)
              const SizedBox(height: 8),
            // Composer-bar appearance is animated: AnimatedSize handles
            // the row-height grow / collapse; AnimatedSwitcher inside
            // cross-fades + slide-downs the actual bar so toggling
            // reply / edit / forward feels intentional rather than a
            // jump. Each helper wraps one conditional so the bars
            // never animate against each other when the user flips
            // between modes (e.g. cancel reply → start edit).
            _AnimatedComposerSlot(
              show: _selectedEdit != null,
              child: _selectedEdit == null
                  ? null
                  : _buildEditComposerBar(Theme.of(context), _selectedEdit!),
            ),
            _AnimatedComposerSlot(
              show: _selectedReply != null,
              child: _selectedReply == null
                  ? null
                  : _buildReplyComposerBar(Theme.of(context), _selectedReply!),
            ),
            _AnimatedComposerSlot(
              show: _selectedForward != null,
              child: _selectedForward == null
                  ? null
                  : _buildForwardComposerBar(
                      Theme.of(context), _selectedForward!),
            ),
            _AnimatedComposerSlot(
              show: _selectedForwardBatch != null,
              child: _selectedForwardBatch == null
                  ? null
                  : _buildForwardBatchComposerBar(
                      Theme.of(context),
                      _selectedForwardBatch!,
                    ),
            ),
            if (_autoDeleteSettings.option != ChatAutoDeleteOption.off)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Chip(
                    avatar: const Icon(Icons.timer_outlined, size: 18),
                    label: Text(
                      'Автоудаление: ${_autoDeleteSettings.option.label}',
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
            // Only show the voice preview panel if NOT auto-sending
            // (i.e. it's a non-voice attachment or an edited voice).
            if (_selectedAttachments.isNotEmpty &&
                !_selectedAttachments.any(_isRecordedVoiceAttachment))
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.65),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Icon(
                          _attachmentPanelIcon(_selectedAttachments),
                          size: 18,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _attachmentPanelTitle(_selectedAttachments),
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            if (_selectedAttachments.any(
                              _isRecordedVoiceAttachment,
                            )) {
                              _recordingController.discardPreview();
                            }
                            _attachmentsController.clear();
                          },
                          child: const Text('Очистить'),
                        ),
                      ],
                    ),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _attachmentSummaryLabel(_selectedAttachments),
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _attachmentKindsLabel(_selectedAttachments),
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                    ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        _attachmentHintLabel(_selectedAttachments),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (_selectedAttachments.length == 1 &&
                        _attachmentKindFromXFile(_selectedAttachments.first) ==
                            _ChatAttachmentKind.audio)
                      _buildVoiceAttachmentPreview(
                        _selectedAttachments.first,
                      ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 74,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _selectedAttachments.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (context, index) {
                          final attachment = _selectedAttachments[index];
                          return Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(14),
                                child: SizedBox(
                                  width: 74,
                                  height: 74,
                                  child: _LocalMediaTile(file: attachment),
                                ),
                              ),
                              Positioned(
                                top: -6,
                                right: -6,
                                child: IconButton.filledTonal(
                                  onPressed: () {
                                    final attachmentToRemove =
                                        _selectedAttachments[index];
                                    if (_isRecordedVoiceAttachment(
                                      attachmentToRemove,
                                    )) {
                                      _recordingController.discardPreview();
                                    }
                                    _attachmentsController.removeAt(index);
                                  },
                                  icon: const Icon(Icons.close, size: 16),
                                  visualDensity: VisualDensity.compact,
                                  style: IconButton.styleFrom(
                                    minimumSize: const Size(28, 28),
                                    padding: EdgeInsets.zero,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            if (_selectedAttachments.isNotEmpty &&
                !_selectedAttachments.any(_isRecordedVoiceAttachment))
              const SizedBox(height: 8),
            Row(
              // Center-align so a single-line composer stays visually balanced;
              // multi-line still grows downward via TextField.maxLines.
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Кнопка вложений — плоская иконка без рамки (44dp
                // тач-таргет остаётся): рамок внутри капсулы быть не должно.
                _ComposerIconButton(
                  icon: Icons.attach_file_rounded,
                  tooltip: 'Добавить вложение',
                  onPressed: _selectedAttachments.length >= _maxAttachments
                      ? null
                      : _openAttachmentPicker,
                ),
                const SizedBox(width: 2),
                Expanded(
                  child: Container(
                    // Поле без собственной рамки и фона: раньше внутри
                    // капсулы композера был второй овал («овал в овале»,
                    // жалоба пользователя). Скругление одно — у капсулы.
                    constraints: const BoxConstraints(minHeight: 40),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    // Focus wrapper owns the key event interception;
                    // TextField gets its own internal FocusNode.
                    // We keep _messageFocusNode for programmatic focus only.
                    child: Focus(
                      onKeyEvent: _handleMessageKeyEvent,
                      child: TextField(
                        controller: _messageController,
                        focusNode: _messageFocusNode,
                        onChanged: (_) => setState(() {}),
                        // User-reported: «зачем на овал в овале нарисованный».
                        // `InputDecoration.collapsed` clears `border` but
                        // not `enabledBorder` / `focusedBorder`, so the
                        // global InputDecorationTheme's stadium borders
                        // were drawing INSIDE the composer's outer
                        // border — that's the second oval the user saw.
                        // Explicitly nuke every border + the fill so
                        // the TextField is purely transparent.
                        decoration: InputDecoration(
                          isCollapsed: true,
                          filled: false,
                          fillColor: Colors.transparent,
                          contentPadding: EdgeInsets.zero,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          hintText: 'Сообщение',
                          hintStyle: TextStyle(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant
                                .withValues(alpha: 0.78),
                            // M3 (50+): ≥16 и для подсказки.
                            fontSize: 16,
                          ),
                        ),
                        // M3 (50+): 16/1.4 — крупный ввод; line-height
                        // оставляем, чтобы выносные элементы (д/р/у/щ)
                        // не липли к следующей строке.
                        style: const TextStyle(fontSize: 16, height: 1.4),
                        textCapitalization: TextCapitalization.sentences,
                        keyboardType: TextInputType.multiline,
                        minLines: 1,
                        maxLines: 5,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _buildPrimaryComposerAction(
                  canSend: canSend,
                  isLockedRecording: isLockedRecording,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordingNotice(
    ThemeData theme, {
    required ChatRecordingState recordingState,
  }) {
    final minutes =
        (_recordingController.durationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds =
        (_recordingController.durationSeconds % 60).toString().padLeft(2, '0');

    late final IconData icon;
    late final String title;
    late final String subtitle;
    late final Color foregroundColor;
    late final Color backgroundColor;

    switch (recordingState) {
      case ChatRecordingState.recording:
        icon = Icons.mic_rounded;
        title = '$minutes:$seconds';
        subtitle =
            'Проведите вверх, чтобы зафиксировать. Влево, чтобы отменить.';
        foregroundColor = Colors.red;
        backgroundColor = Colors.red.withValues(alpha: 0.08);
        break;
      case ChatRecordingState.failed:
        icon = Icons.error_outline;
        title = 'Голосовое не отправлено';
        subtitle = _recordingController.errorText ??
            'Проверьте сеть и попробуйте отправить снова.';
        foregroundColor = theme.colorScheme.error;
        backgroundColor =
            theme.colorScheme.errorContainer.withValues(alpha: 0.52);
        break;
      case ChatRecordingState.denied:
        icon = Icons.mic_off_outlined;
        title = 'Микрофон недоступен';
        subtitle =
            'Разрешите доступ к микрофону в настройках браузера или устройства.';
        foregroundColor = theme.colorScheme.error;
        backgroundColor =
            theme.colorScheme.errorContainer.withValues(alpha: 0.52);
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(icon, color: foregroundColor),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: foregroundColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (recordingState == ChatRecordingState.denied)
            TextButton(
              onPressed: () {
                unawaited(openAppSettings());
              },
              child: const Text('Настройки'),
            ),
        ],
      ),
    );
  }

  Widget _buildPrimaryComposerAction({
    required bool canSend,
    required bool isLockedRecording,
  }) {
    if (canSend) {
      // Reference `.composer .send`: 42x42 accent-filled circle with
      // a soft drop shadow, replacing Material's flat IconButton.filled.
      // Icons.send (not send_rounded) keeps the existing widget tests
      // happy — both visually identical at this size.
      return _ComposerSendButton(
        icon: _selectedEdit != null ? Icons.check : Icons.send,
        tooltip: _selectedEdit != null ? 'Сохранить изменения' : 'Отправить',
        onPressed:
            _selectedEdit != null ? _saveEditedMessage : _sendCurrentMessage,
      );
    }

    final recordingState = _recordingController.state;
    if (isLockedRecording) {
      return IconButton.filled(
        onPressed: _stopAndSendRecording,
        tooltip: 'Остановить и прослушать',
        icon: const Icon(Icons.stop_rounded),
      );
    }

    // Mic / Kruzhok composer button — Telegram-style two-state.
    //   tap   → flip mode (voice ↔ kruzhok), no recording starts
    //   hold  → start recording in the current mode (voice loops
    //           through ChatRecordingController; kruzhok opens the
    //           video-note capture UI which is itself press-and-
    //           hold inside)
    //
    // We render the visual via a plain Material+Container instead of
    // IconButton + GestureDetector — the previous combo had IconButton's
    // own onPressed competing with our long-press in the gesture
    // arena, which on some Android devices made long-press never fire
    // ("на телефоне зажимаешь голосовуху — а появляется уведа
    // 'зажмите чтобы записать'"). With a non-interactive child the
    // GestureDetector owns the gesture cleanly.
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isKruzhokMode = _voiceModeIsKruzhok;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Tap toggles the mode (no recording yet).
        HapticFeedback.selectionClick();
        setState(() {
          _voiceModeIsKruzhok = !_voiceModeIsKruzhok;
        });
      },
      onLongPressStart: (details) {
        if (_voiceModeIsKruzhok) {
          // Kruzhok mode: open the video-note recorder. Hold-to-
          // record happens inside the recorder UI itself.
          HapticFeedback.mediumImpact();
          unawaited(_pickVideoNote());
        } else {
          _handleRecordingLongPressStart(details);
        }
      },
      // C3a/V1: move/release голосовой записи ведёт персистентный Listener
      // над композером (см. _buildMessageInputArea), а не этот recognizer —
      // он размонтируется при появлении recording-бара.
      // User-reported on Samsung: «зажатием не записывается, появляется
      // только облачко 'зажмите для голосового' и всё». На ПК
      // мышью работало, на телефоне — нет.
      //
      // Корень: Material `Tooltip` на Android по умолчанию сам
      // открывается на long-press через свой собственный
      // LongPressGestureRecognizer. В gesture arena он конкурирует
      // с нашим GestureDetector — и часто выигрывает на чувствительных
      // экранах Samsung'а, поэтому `onLongPressStart` никогда не
      // вызывался: жест уходил Tooltip'у, наш recorder молчал.
      //
      // Заменили Tooltip на Semantics: TalkBack/screen-reader
      // прочитают тот же текст подсказки, но никаких gesture
      // recognizer-ов на child больше нет — long-press идёт нашему
      // GestureDetector'у напрямую.
      // FX1/C3a FR1: локальный Listener фиксирует id пальца, опущенного
      // именно НА микрофон — запись привяжется к нему, а не к чужому касанию
      // зоны ввода. Move/up уже-захваченного пальца ведёт композер-wide
      // Listener (он переживает ребилд композер→бар).
      child: Listener(
        onPointerDown: (event) => _micPointerId = event.pointer,
        onPointerUp: (event) {
          if (event.pointer == _micPointerId) {
            _micPointerId = null;
          }
        },
        onPointerCancel: (event) {
          if (event.pointer == _micPointerId) {
            _micPointerId = null;
          }
        },
        child: Semantics(
          button: true,
          label: isKruzhokMode ? 'Кружочек' : 'Голосовое сообщение',
          hint: isKruzhokMode
              ? 'Зажмите для кружочка, тап чтобы переключить на голосовое'
              : 'Зажмите для голосового, тап чтобы переключить на кружочек',
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(
              recordingState == ChatRecordingState.recording
                  ? Icons.lock_open_rounded
                  : (isKruzhokMode
                      ? Icons.videocam_outlined
                      : Icons.mic_none_rounded),
              color: scheme.onPrimary,
            ),
          ),
        ),
      ),
    );
  }

  String? _messageFooterLabel(
    ChatMessage message, {
    required bool isMe,
    required bool isLatestOwnDirectMessage,
  }) {
    final segments = <String>[];
    final expiresLabel = _expiresLabel(message.expiresAt);
    if (expiresLabel != null) {
      segments.add('Автоудаление: $expiresLabel');
    }
    // Direct: show receipt only on the latest own message (avoids label
    // spam down the entire bubble column). Group: same restriction —
    // we want the reader to glance at the latest message, not the
    // ten-message-back trail. Group label includes a "X из N прочитали"
    // hint when partial coverage.
    if (isMe && isLatestOwnDirectMessage) {
      final receipt =
          widget.isGroup ? _groupReceiptLabel(message) : _receiptLabel(message);
      if (receipt != null && receipt.isNotEmpty) {
        segments.add(receipt);
      }
    }
    if (segments.isEmpty) {
      return null;
    }
    return segments.join(' · ');
  }

  String _receiptLabel(ChatMessage message) {
    if (_messageReadByAnyRecipient(message)) {
      return 'Прочитано';
    }
    if (_messageDeliveredToAnyRecipient(message)) {
      return 'Доставлено';
    }
    return 'Отправлено';
  }

  /// Group-chat receipt summary: "Прочитали все", "Прочитали X из N",
  /// "Доставлено всем" depending on coverage. Returns null when the
  /// group has no other recipients (single-member group, edge case).
  String? _groupReceiptLabel(ChatMessage message) {
    final recipients = _messageRecipientIds(message);
    final total = recipients.length;
    if (total == 0) {
      return null;
    }
    final readCount = recipients.where(message.readBy.contains).length;
    if (readCount >= total) {
      return 'Прочитали все';
    }
    if (readCount > 0) {
      return 'Прочитали $readCount из $total';
    }
    final deliveredCount =
        recipients.where(message.deliveredTo.contains).length;
    if (deliveredCount >= total) {
      return 'Доставлено всем';
    }
    if (deliveredCount > 0) {
      return 'Доставлено $deliveredCount из $total';
    }
    return 'Отправлено';
  }

  bool _messageDeliveredToAnyRecipient(ChatMessage message) {
    return _messageRecipientIds(message).any(message.deliveredTo.contains);
  }

  bool _messageReadByAnyRecipient(ChatMessage message) {
    return _messageRecipientIds(message).any(message.readBy.contains) ||
        (message.readBy.isEmpty && message.isRead);
  }

  Set<String> _messageRecipientIds(ChatMessage message) {
    final currentUserId = _currentUserId;
    final recipients = message.participants
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty && value != currentUserId)
        .toSet();
    if (recipients.isNotEmpty) {
      return recipients;
    }
    return message.readBy
        .followedBy(message.deliveredTo)
        .where((value) => value.trim().isNotEmpty && value != currentUserId)
        .toSet();
  }

  String? _expiresLabel(DateTime? expiresAt) {
    if (expiresAt == null) {
      return null;
    }

    final remaining = expiresAt.difference(DateTime.now());
    if (remaining.inSeconds <= 0) {
      return 'скоро';
    }
    if (remaining.inHours < 1) {
      final minutes = remaining.inMinutes.clamp(1, 59);
      return '$minutes мин';
    }
    if (remaining.inDays < 1) {
      final hours = remaining.inHours.clamp(1, 23);
      return '$hours ч';
    }
    final days = remaining.inDays.clamp(1, 999);
    return '$days д';
  }

  /// Telegram-style message grouping: a message continues a same-sender run
  /// when the message displayed directly above it (the older neighbour at
  /// index+1, since the list is newest-first + reversed) is from the same
  /// sender within 60s. Continuation messages drop the repeated sender label
  /// and tighten the inter-bubble gap.
  bool _isGroupedWithAbove(List<ChatMessage> messages, int index) {
    final aboveIndex = index + 1;
    if (aboveIndex < 0 || aboveIndex >= messages.length) {
      return false;
    }
    final current = messages[index];
    final above = messages[aboveIndex];
    if (current.senderId != above.senderId) {
      return false;
    }
    return current.timestamp.difference(above.timestamp).abs().inSeconds <= 60;
  }

  Widget _buildRemoteBubble(
    ChatMessage message,
    bool isMe, {
    String? footerLabel,
    bool isGroupedWithAbove = false,
  }) {
    final messageKey = _remoteMessageKeys.putIfAbsent(
      message.id,
      () => GlobalKey(),
    );
    // Mark this id as seen on the next frame so the next time we build
    // we skip the animation. We do it post-frame instead of inline
    // because TweenAnimationBuilder needs the "not in set" signal to
    // be true for the entire first build pass.
    final isFirstAppearance = !_seenRemoteMessageIds.contains(message.id);
    if (isFirstAppearance) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _seenRemoteMessageIds.add(message.id);
      });
    }
    final callMetadata = message.call;
    if (callMetadata != null) {
      return _wrapInEnterAnimation(
        animate: isFirstAppearance,
        child: KeyedSubtree(
          key: messageKey,
          child: _buildCallSummaryBubble(message, callMetadata, isMe),
        ),
      );
    }
    return _wrapInEnterAnimation(
      animate: isFirstAppearance,
      child: SwipeToReply(
        key: messageKey,
        isMe: isMe,
        // Selection mode uses long-press / tap on the bubble for
        // multi-select — the swipe gesture would conflict, so disable
        // it via a no-op callback while in selection mode.
        onReply:
            _isSelectionMode ? () {} : () => _selectReplyFromMessage(message),
        child: GestureDetector(
          onTap: _isSelectionMode
              ? () => _toggleRemoteMessageSelection(message)
              : null,
          onLongPressStart: (details) {
            // Same TG / iOS pattern: medium-impact haptic confirms the
            // long-press fired before the action sheet opens. Without it
            // users hold a beat too long because nothing tells them the
            // gesture took. Mirrors what reaction-picker already does.
            HapticFeedback.mediumImpact();
            if (_isSelectionMode) {
              _toggleRemoteMessageSelection(message);
              return;
            }
            _openRemoteMessageActions(
              message,
              anchorPosition: details.globalPosition,
            );
          },
          onSecondaryTapDown: (details) {
            if (_isSelectionMode) {
              _toggleRemoteMessageSelection(message);
              return;
            }
            _openRemoteMessageActions(
              message,
              anchorPosition: details.globalPosition,
            );
          },
          child: _ChatBubble(
            isMe: isMe,
            groupedWithPrev: isGroupedWithAbove,
            senderLabel: widget.isGroup && !isMe && !isGroupedWithAbove
                ? _groupSenderLabel(message.senderName, message.senderId)
                : null,
            onSenderTap: widget.isGroup && !isMe
                ? () => unawaited(_openDirectChatForMessage(message))
                : null,
            text: message.text,
            highlightQuery: _searchController.query,
            timeLabel: DateFormat.Hm('ru')
                .format(toLocalForDisplay(message.timestamp)),
            isRead: isMe && _messageReadByAnyRecipient(message),
            isDelivered: isMe && _messageDeliveredToAnyRecipient(message),
            remoteAttachments: message.attachments,
            replyTo: message.replyTo,
            onReplyTap: message.replyTo == null
                ? null
                : () =>
                    unawaited(_focusMessageById(message.replyTo!.messageId)),
            isPinned: _pinnedMessage?.messageId == message.id,
            isHighlighted: _highlightedPinnedMessageId == message.id,
            footerLabel: footerLabel,
            reactionGroups: _reactionGroupsForMessage(message),
            onReactionTap: (emoji) => _toggleReactionForMessage(message, emoji),
            showSelectionMarker: _isSelectionMode,
            isSelected: _selectionController.isRemoteSelected(message.id),
            onOpenRemoteAttachment: (attachments, attachment) =>
                _openRemoteAttachmentPreview(message, attachments, attachment),
          ),
        ),
      ),
    );
  }

  /// Telegram-style date header: a small pill above the *oldest*
  /// message of each day. Detected by looking at the next-older
  /// message in the list (since `filteredRemoteMessages[0]` is newest):
  /// if its day differs, this message is the day-anchor and gets a
  /// header. Last message in the list (oldest of all) always gets
  /// one. Optimistic / search-result paths skip the header — they
  /// don't form a continuous timeline.
  Widget _wrapBubbleWithDayHeader({
    required Widget bubble,
    required List<ChatMessage> messages,
    required int messageIndex,
  }) {
    if (messageIndex < 0 || messageIndex >= messages.length) {
      return bubble;
    }
    final current = messages[messageIndex].timestamp;
    final hasOlder = messageIndex < messages.length - 1;
    final isOldestOfDay = !hasOlder ||
        _differentLocalDay(current, messages[messageIndex + 1].timestamp);
    if (!isOldestOfDay) return bubble;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDateDivider(current),
        bubble,
      ],
    );
  }

  bool _differentLocalDay(DateTime a, DateTime b) {
    return a.year != b.year || a.month != b.month || a.day != b.day;
  }

  Widget _buildDateDivider(DateTime timestamp) {
    final theme = Theme.of(context);
    final tokens = theme.extension<RodnyaDesignTokens>() ??
        (theme.brightness == Brightness.dark
            ? RodnyaDesignTokens.dark
            : RodnyaDesignTokens.light);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: tokens.surfaceStrong.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: tokens.surfaceLine.withValues(alpha: 0.45),
              width: 0.6,
            ),
          ),
          child: Text(
            _formatDateDividerLabel(timestamp),
            style: theme.textTheme.labelSmall?.copyWith(
              color: tokens.inkSecondary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ),
    );
  }

  /// "Сегодня" / "Вчера" / "12 марта" / "12 марта 2025" depending on
  /// how recent the message is. Same shape as TG date pills.
  String _formatDateDividerLabel(DateTime timestamp) {
    final now = DateTime.now();
    // Normalize source timestamp to LOCAL once — backend pushes
    // UTC, and `DateTime(timestamp.year, ...)` would otherwise pull
    // year/month/day from the UTC frame which can flip a date by ±1
    // day across midnight in the user's zone.
    final localTimestamp = toLocalForDisplay(timestamp);
    final today = DateTime(now.year, now.month, now.day);
    final messageDay =
        DateTime(localTimestamp.year, localTimestamp.month, localTimestamp.day);
    final diff = today.difference(messageDay).inDays;
    if (diff == 0) return 'Сегодня';
    if (diff == 1) return 'Вчера';
    final pattern = localTimestamp.year == now.year ? 'd MMMM' : 'd MMMM yyyy';
    return DateFormat(pattern, 'ru').format(localTimestamp);
  }

  /// Wraps a bubble in a slide-up + fade-in tween that runs once on
  /// first appearance. Pure VERTICAL entrance — matches the optimistic
  /// outgoing bubble (see _buildOutgoingMessageBubble). The earlier
  /// horizontal nudge (own from the right, peer from the left) made own
  /// messages visibly jump right→left when the server echo reconciled a
  /// just-sent message into a "first appearance" remote bubble — the
  /// «блок улетает справа налево» the user reported. Returns the child
  /// unchanged when [animate] is false (existing messages, history scroll).
  Widget _wrapInEnterAnimation({
    required bool animate,
    required Widget child,
  }) {
    if (!animate) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      builder: (context, t, c) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: c,
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildCallSummaryBubble(
    ChatMessage message,
    ChatMessageCall callMetadata,
    bool isMe,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final timeLabel =
        DateFormat.Hm('ru').format(toLocalForDisplay(message.timestamp));
    final palette = _callSummaryPalette(scheme, callMetadata);
    final mediaIcon =
        callMetadata.isVideo ? Icons.videocam_rounded : Icons.call_rounded;
    final summaryLabel = _callSummaryLabel(callMetadata);
    final secondaryLabel = _callSummarySecondaryLabel(callMetadata);
    final tapMode =
        callMetadata.isVideo ? CallMediaMode.video : CallMediaMode.audio;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => unawaited(_startCall(tapMode)),
              child: Ink(
                decoration: BoxDecoration(
                  color: palette.background,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: palette.border,
                    width: 0.6,
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: palette.iconBackground,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        mediaIcon,
                        size: 18,
                        color: palette.iconColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summaryLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: palette.titleColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (secondaryLabel != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              '$secondaryLabel · $timeLabel',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.subtitleColor,
                              ),
                            ),
                          ] else ...[
                            const SizedBox(height: 2),
                            Text(
                              timeLabel,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: palette.subtitleColor,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      isMe
                          ? Icons.call_made_rounded
                          : Icons.call_received_rounded,
                      size: 16,
                      color: palette.subtitleColor,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _callSummaryLabel(ChatMessageCall callMetadata) {
    final isVideo = callMetadata.isVideo;
    switch (callMetadata.state) {
      case 'ended':
        return isVideo ? 'Видеозвонок' : 'Аудиозвонок';
      case 'missed':
        return isVideo ? 'Пропущенный видеозвонок' : 'Пропущенный звонок';
      case 'rejected':
        return isVideo ? 'Видеозвонок отклонён' : 'Звонок отклонён';
      case 'cancelled':
        return isVideo ? 'Видеозвонок отменён' : 'Звонок отменён';
      case 'failed':
        return 'Не удалось позвонить';
      default:
        return isVideo ? 'Видеозвонок' : 'Аудиозвонок';
    }
  }

  String? _callSummarySecondaryLabel(ChatMessageCall callMetadata) {
    if (callMetadata.state != 'ended') {
      return null;
    }
    final durationMs = callMetadata.durationMs;
    if (durationMs == null || durationMs <= 0) {
      return null;
    }
    final totalSeconds = (durationMs / 1000).floor();
    final seconds = totalSeconds % 60;
    final totalMinutes = totalSeconds ~/ 60;
    final minutes = totalMinutes % 60;
    final hours = totalMinutes ~/ 60;
    String two(int v) => v.toString().padLeft(2, '0');
    if (hours > 0) {
      return '$hours:${two(minutes)}:${two(seconds)}';
    }
    return '$minutes:${two(seconds)}';
  }

  _CallSummaryPalette _callSummaryPalette(
    ColorScheme scheme,
    ChatMessageCall callMetadata,
  ) {
    final isMissedLike = callMetadata.isMissed || callMetadata.isRejected;
    if (isMissedLike) {
      final accent = scheme.error;
      return _CallSummaryPalette(
        background: scheme.errorContainer.withValues(alpha: 0.55),
        border: accent.withValues(alpha: 0.32),
        iconBackground: accent.withValues(alpha: 0.18),
        iconColor: accent,
        titleColor: scheme.onErrorContainer,
        subtitleColor: scheme.onErrorContainer.withValues(alpha: 0.78),
      );
    }
    return _CallSummaryPalette(
      background: scheme.surfaceContainerHigh.withValues(alpha: 0.85),
      border: scheme.outlineVariant.withValues(alpha: 0.55),
      iconBackground: scheme.primary.withValues(alpha: 0.12),
      iconColor: scheme.primary,
      titleColor: scheme.onSurface,
      subtitleColor: scheme.onSurfaceVariant,
    );
  }

  Widget _buildServerSearchResultTile(ChatMessageSearchResult result) {
    final theme = Theme.of(context);
    final isMe = result.senderId == _currentUserId;
    final senderLabel = isMe
        ? 'Вы'
        : result.senderName.trim().isEmpty
            ? 'Участник'
            : result.senderName.trim();
    final snippet = result.snippet.trim().isNotEmpty
        ? result.snippet.trim()
        : result.text.trim();
    final text = snippet.isEmpty ? 'Сообщение без текста' : snippet;
    final hasDate = result.matchedAt.millisecondsSinceEpoch > 0;
    final timeLabel = hasDate
        ? DateFormat('dd.MM HH:mm', 'ru').format(result.matchedAt.toLocal())
        : '';
    final background = isMe
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = isMe
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment:
                    isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          senderLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: foreground.withValues(alpha: 0.82),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (timeLabel.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          timeLabel,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.68),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  _HighlightedMessageText(
                    text: text,
                    query: _searchController.query,
                    color: foreground,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOptimisticBubble(_OutgoingMessage message) {
    final timeLabel =
        DateFormat.Hm('ru').format(toLocalForDisplay(message.timestamp));
    final theme = Theme.of(context);
    final statusMeta = _statusMetaForOutgoingMessage(theme, message);
    final bubbleKey = ValueKey<String>('outgoing-bubble-${message.localId}');

    // Telegram-style send animation: the optimistic bubble slides up
    // 14dp + fades in over 220ms. Keyed by localId so the tween only
    // plays once per message — re-renders during status flips
    // (pending → sent → failed) keep the bubble in its rest state.
    return TweenAnimationBuilder<double>(
      key: ValueKey<String>('outgoing-bubble-anim-${message.localId}'),
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 14),
            child: child,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
        child: Align(
          alignment: Alignment.centerRight,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              SwipeToReply(
                key: bubbleKey,
                isMe: true,
                onReply: _isSelectionMode
                    ? () {}
                    : () => _selectReplyFromOutgoingMessage(message),
                child: GestureDetector(
                  onTap: _isSelectionMode
                      ? () => _toggleOutgoingMessageSelection(message)
                      : null,
                  onLongPressStart: (details) {
                    HapticFeedback.mediumImpact();
                    if (_isSelectionMode) {
                      _toggleOutgoingMessageSelection(message);
                      return;
                    }
                    _openOutgoingMessageActions(
                      message,
                      anchorPosition: details.globalPosition,
                    );
                  },
                  onSecondaryTapDown: (details) {
                    if (_isSelectionMode) {
                      _toggleOutgoingMessageSelection(message);
                      return;
                    }
                    _openOutgoingMessageActions(
                      message,
                      anchorPosition: details.globalPosition,
                    );
                  },
                  child: _ChatBubble(
                    isMe: true,
                    text: message.text,
                    highlightQuery: _searchController.query,
                    timeLabel: timeLabel,
                    isRead: false,
                    isDelivered: false,
                    remoteAttachments: message.forwardedAttachments,
                    localAttachments: message.attachments,
                    localAttachmentStatuses: message.attachmentUploadStatuses,
                    replyTo: message.replyTo,
                    onReplyTap: message.replyTo == null
                        ? null
                        : () => unawaited(
                              _focusMessageById(message.replyTo!.messageId),
                            ),
                    isPinned: false,
                    isHighlighted: false,
                    reactionGroups: const <_ReactionGroup>[],
                    showSelectionMarker: _isSelectionMode,
                    isSelected: _selectionController
                        .isOutgoingSelected(message.localId),
                    onOpenLocalAttachment: (files, file) =>
                        _openLocalAttachmentPreview(files, file),
                    footerLabel: _autoDeleteSettings.option ==
                            ChatAutoDeleteOption.off
                        ? null
                        : 'Автоудаление: ${_autoDeleteSettings.option.label}',
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Status icon cross-fades + scales when the message
                  // walks the ladder (pending → sent → failed). Keyed by
                  // icon code so AnimatedSwitcher actually swaps.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: Tween<double>(begin: 0.6, end: 1.0)
                          .animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: Icon(
                      statusMeta.icon,
                      key: ValueKey<int>(statusMeta.icon.codePoint),
                      size: 14,
                      color: statusMeta.color,
                    ),
                  ),
                  const SizedBox(width: 4),
                  // S4: failed-строка («Не отправлено» + «Повторить»)
                  // переполняла узкий баббл — лейбл сжимаем, кнопка
                  // остаётся целой тап-целью.
                  Flexible(
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      style: theme.textTheme.bodySmall!.copyWith(
                        color: statusMeta.color,
                        fontWeight:
                            message.status == _OutgoingMessageStatus.failed
                                ? FontWeight.w700
                                : FontWeight.w500,
                      ),
                      child: Text(
                        statusMeta.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  if (message.status == _OutgoingMessageStatus.failed) ...[
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: () => unawaited(
                        _sendQueue.retry(message.chatId, message.localId),
                      ),
                      child: const Text('Повторить'),
                    ),
                  ],
                ],
              ),
              // Общий LinearProgressIndicator заменён пофайловыми
              // оверлеями на плитках (_LocalMediaGrid) — текстовый
              // статус «Загрузка вложений N/M» остаётся: он единственный
              // сигнал для файлов за «+N» и для аудио/кружков.
            ],
          ),
        ),
      ),
    );
  }

  _OutgoingStatusMeta _statusMetaForOutgoingMessage(
    ThemeData theme,
    _OutgoingMessage message,
  ) {
    if (message.status == _OutgoingMessageStatus.failed) {
      return _OutgoingStatusMeta(
        label: message.errorText ?? 'Ошибка отправки',
        icon: Icons.error_outline,
        color: theme.colorScheme.error,
      );
    }
    if (message.status == _OutgoingMessageStatus.sent) {
      return _OutgoingStatusMeta(
        label: 'Отправлено',
        icon: Icons.done_all,
        color: theme.colorScheme.primary,
      );
    }

    switch (message.progress?.stage) {
      case ChatSendProgressStage.preparing:
        return _OutgoingStatusMeta(
          label: 'Подготовка вложений...',
          icon: Icons.inventory_2_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        );
      case ChatSendProgressStage.uploading:
        final total = message.progress?.total ?? 0;
        final completed = message.progress?.completed ?? 0;
        if (total > 1) {
          return _OutgoingStatusMeta(
            label: 'Загрузка вложений $completed/$total',
            icon: Icons.cloud_upload_outlined,
            color: theme.colorScheme.onSurfaceVariant,
          );
        }
        return _OutgoingStatusMeta(
          label: 'Загрузка вложения...',
          icon: Icons.cloud_upload_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        );
      case ChatSendProgressStage.sending:
      case null:
        return _OutgoingStatusMeta(
          label: 'Отправляется...',
          icon: Icons.schedule_send_outlined,
          color: theme.colorScheme.onSurfaceVariant,
        );
    }
  }

  String _attachmentSummaryLabel(List<XFile> files) {
    final count = files.length;
    final noun = count == 1
        ? 'вложение'
        : (count >= 2 && count <= 4 ? 'вложения' : 'вложений');
    return '$count $noun';
  }

  String _attachmentKindsLabel(List<XFile> files) {
    if (files.length == 1 && _isVideoNoteFile(files.first)) {
      return '1 кружок';
    }
    final counts = <_ChatAttachmentKind, int>{};
    for (final file in files) {
      final kind = _attachmentKindFromXFile(file);
      counts.update(kind, (value) => value + 1, ifAbsent: () => 1);
    }

    final segments = <String>[];
    void addSegment(_ChatAttachmentKind kind, String singular, String plural) {
      final count = counts[kind];
      if (count == null || count == 0) {
        return;
      }
      segments.add('$count ${count == 1 ? singular : plural}');
    }

    addSegment(_ChatAttachmentKind.image, 'фото', 'фото');
    addSegment(_ChatAttachmentKind.video, 'видео', 'видео');
    addSegment(_ChatAttachmentKind.audio, 'голосовое', 'голосовых');
    addSegment(_ChatAttachmentKind.other, 'файл', 'файла');
    return segments.join(' · ');
  }

  String _attachmentHintLabel(List<XFile> files) {
    if (files.length == 1 && _isVideoNoteFile(files.first)) {
      return 'Кружок уйдет отдельным сообщением и откроется как круглое видео.';
    }
    final kinds = files.map(_attachmentKindFromXFile).toSet();
    if (kinds.length > 1) {
      return 'Пакет уйдет одним сообщением. Проверьте подпись и состав перед отправкой.';
    }

    switch (kinds.first) {
      case _ChatAttachmentKind.image:
        return 'Фото будут ужаты перед отправкой, чтобы чат открывался быстрее.';
      case _ChatAttachmentKind.video:
        return 'Видео отправится как вложение. Можно добавить подпись к отправке.';
      case _ChatAttachmentKind.audio:
        return 'Голосовое отправится отдельным сообщением в текущий чат.';
      case _ChatAttachmentKind.other:
        return 'Файлы отправятся как документы без дополнительной обработки.';
    }
  }

  IconData _attachmentPanelIcon(List<XFile> files) {
    if (files.length == 1 && _isVideoNoteFile(files.first)) {
      return Icons.radio_button_checked_rounded;
    }
    final kinds = files.map(_attachmentKindFromXFile).toSet();
    if (kinds.length > 1) {
      return Icons.collections_outlined;
    }

    switch (kinds.first) {
      case _ChatAttachmentKind.image:
        return Icons.photo_library_outlined;
      case _ChatAttachmentKind.video:
        return Icons.videocam_outlined;
      case _ChatAttachmentKind.audio:
        return Icons.mic_none_outlined;
      case _ChatAttachmentKind.other:
        return Icons.insert_drive_file_outlined;
    }
  }

  String _attachmentPanelTitle(List<XFile> files) {
    if (files.length == 1 && _isVideoNoteFile(files.first)) {
      return 'Кружок перед отправкой';
    }
    final kinds = files.map(_attachmentKindFromXFile).toSet();
    if (kinds.length > 1) {
      return 'Пакет перед отправкой';
    }

    switch (kinds.first) {
      case _ChatAttachmentKind.image:
        return 'Фото перед отправкой';
      case _ChatAttachmentKind.video:
        return 'Видео перед отправкой';
      case _ChatAttachmentKind.audio:
        return 'Голосовое перед отправкой';
      case _ChatAttachmentKind.other:
        return 'Файлы перед отправкой';
    }
  }

  String? _groupSenderLabel(String? senderName, String senderId) {
    final normalizedName = senderName?.trim();
    if (normalizedName != null && normalizedName.isNotEmpty) {
      return normalizedName;
    }
    if (senderId == _currentUserId) {
      return 'Вы';
    }
    return 'Участник';
  }

  bool _isWideLayout(BuildContext context) =>
      MediaQuery.of(context).size.width >= 1180;

  Future<void> _copyMessageText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: trimmed));
    if (!mounted) {
      return;
    }
    showAppSnackBar(context, 'Текст сообщения скопирован');
  }

  bool get _isCurrentDirectChat =>
      _chatDetails?.isDirect ?? widget.chatType == 'direct';

  bool get _canStartCallInChat {
    final details = _chatDetails;
    if (details != null) {
      return (details.isDirect || details.isGroup) &&
          details.participantIds.length >= 2;
    }
    return widget.chatType == 'direct';
  }

  String? get _currentDirectPeerUserId {
    if (!_isCurrentDirectChat) {
      return null;
    }
    final participantIds = _otherParticipantIds(_chatDetails);
    if (participantIds.isEmpty) {
      final otherUserId = widget.otherUserId?.trim();
      return otherUserId == null || otherUserId.isEmpty ? null : otherUserId;
    }
    return participantIds.first;
  }

  String _messageActionErrorText(Object error, String fallback) {
    if (error is CustomApiException && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    if (error is UnsupportedError && error.message?.trim().isNotEmpty == true) {
      return error.message!.trim();
    }
    return fallback;
  }

  Future<_SafetyActionDraft?> _pickSafetyActionDraft({
    required String title,
    required String subtitle,
    required List<_SafetyReasonChoice> choices,
  }) {
    return showModalBottomSheet<_SafetyActionDraft>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        final detailsController = TextEditingController();
        _SafetyReasonChoice? selectedChoice = choices.first;

        return StatefulBuilder(
          builder: (context, setModalState) => SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                left: 20,
                right: 20,
                top: 8,
                bottom: MediaQuery.of(context).viewInsets.bottom + 20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: choices
                        .map(
                          (choice) => ChoiceChip(
                            label: Text(choice.label),
                            selected: selectedChoice == choice,
                            onSelected: (_) {
                              setModalState(() {
                                selectedChoice = choice;
                              });
                            },
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: detailsController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Комментарий для модерации',
                      hintText:
                          'Необязательно, но помогает быстрее разобраться',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Отмена'),
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: selectedChoice == null
                            ? null
                            : () => Navigator.of(context).pop(
                                  _SafetyActionDraft(
                                    reason: selectedChoice!.reason,
                                    details: detailsController.text.trim(),
                                  ),
                                ),
                        child: const Text('Продолжить'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _reportRemoteMessage(ChatMessage message) async {
    final safetyService = _safetyService;
    if (safetyService == null) {
      return;
    }

    final senderLabel = _participantLabelForUserId(message.senderId);
    final draft = await _pickSafetyActionDraft(
      title: 'Пожаловаться на сообщение',
      subtitle:
          'Жалоба уйдёт в модерацию. Мы передадим текст сообщения, автора и контекст чата.',
      choices: const <_SafetyReasonChoice>[
        _SafetyReasonChoice(reason: 'spam', label: 'Спам'),
        _SafetyReasonChoice(reason: 'abuse', label: 'Оскорбление'),
        _SafetyReasonChoice(reason: 'adult', label: 'Нежелательный контент'),
        _SafetyReasonChoice(reason: 'fraud', label: 'Мошенничество'),
        _SafetyReasonChoice(reason: 'other', label: 'Другое'),
      ],
    );
    if (draft == null) {
      return;
    }

    try {
      await safetyService.reportTarget(
        targetType: 'message',
        targetId: message.id,
        reason: draft.reason,
        details: draft.details.isEmpty ? null : draft.details,
        metadata: <String, dynamic>{
          'chatId': message.chatId,
          'senderId': message.senderId,
          'senderName': senderLabel,
          'messagePreview': message.text.trim(),
        },
      );
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Жалоба на сообщение $senderLabel отправлена.');
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        _messageActionErrorText(error, 'Не удалось отправить жалобу.'),
        isError: true,
      );
    }
  }

  Future<void> _blockUserFromMessage(ChatMessage message) async {
    final safetyService = _safetyService;
    final currentUserId = _currentUserId;
    if (safetyService == null ||
        currentUserId == null ||
        currentUserId.isEmpty ||
        message.senderId.trim().isEmpty ||
        message.senderId == currentUserId) {
      return;
    }

    final senderLabel = _participantLabelForUserId(message.senderId);
    final draft = await _pickSafetyActionDraft(
      title: 'Заблокировать пользователя',
      subtitle:
          'После блокировки личный чат станет только для чтения. Управлять списком блокировок можно в настройках.',
      choices: const <_SafetyReasonChoice>[
        _SafetyReasonChoice(reason: 'harassment', label: 'Навязчивость'),
        _SafetyReasonChoice(reason: 'spam', label: 'Спам'),
        _SafetyReasonChoice(reason: 'privacy', label: 'Нарушение границ'),
        _SafetyReasonChoice(reason: 'other', label: 'Другое'),
      ],
    );
    if (draft == null) {
      return;
    }

    try {
      await safetyService.blockUser(
        userId: message.senderId,
        reason: draft.reason,
        metadata: <String, dynamic>{
          'chatId': message.chatId,
          'source': 'chat_message',
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedEdit = null;
        _selectedReply = null;
        _selectedForward = null;
        _selectedForwardBatch = null;
        _isDirectChatBlocked = _isCurrentDirectChat;
        _directChatBlockedLabel = senderLabel;
      });
      _attachmentsController.clear();
      showAppSnackBar(
        context,
        '$senderLabel заблокирован. Отправка в этом личном чате отключена.',
        action: SnackBarAction(
          label: 'Блокировки',
          onPressed: () => context.push('/profile/blocks'),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        _messageActionErrorText(
            error, 'Не удалось заблокировать пользователя.'),
        isError: true,
      );
    }
  }

  Widget _buildBlockedComposerNotice() {
    final theme = Theme.of(context);
    final label = _directChatBlockedLabel?.trim();
    final title = label != null && label.isNotEmpty
        ? '$label в списке блокировок'
        : 'Собеседник в списке блокировок';

    return Padding(
      padding: EdgeInsets.fromLTRB(
        8,
        4,
        8,
        MediaQuery.of(context).padding.bottom + 8,
      ),
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        borderRadius: BorderRadius.circular(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  Icons.block_rounded,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Новые сообщения и медиа сейчас недоступны.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.push('/profile/blocks'),
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Список блокировок'),
                ),
                TextButton.icon(
                  onPressed: () => context.push('/support'),
                  icon: const Icon(Icons.support_agent_outlined),
                  label: const Text('Поддержка'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openRemoteMessageActions(
    ChatMessage message, {
    Offset? anchorPosition,
  }) async {
    final canCopy = message.text.trim().isNotEmpty;
    final isOwnMessage = message.senderId == _currentUserId;
    final isPinned = _pinnedMessage?.messageId == message.id;
    final supportsSafetyActions = _safetyService != null;
    final canOpenDirectChat =
        widget.isGroup && !isOwnMessage && message.senderId.trim().isNotEmpty;
    final canReport = supportsSafetyActions && !isOwnMessage;
    final canBlock = canReport &&
        _isCurrentDirectChat &&
        (_currentDirectPeerUserId == null ||
            _currentDirectPeerUserId == message.senderId);
    final useDesktopMenu =
        _useDesktopMessageContextMenu() && anchorPosition != null;
    _MessageSheetSelection? selection;
    if (useDesktopMenu) {
      selection = await _showDesktopMessagePopover<_MessageSheetSelection>(
        anchorPosition: anchorPosition,
        reactions: _quickReactionEmoji,
        reactionValueBuilder: (emoji) => _MessageSheetSelection(
          action: _MessageAction.react,
          emoji: emoji,
        ),
        actions: <_ContextMenuActionItem<_MessageSheetSelection>>[
          const _ContextMenuActionItem<_MessageSheetSelection>(
            label: 'Ответить',
            icon: Icons.reply_rounded,
            value: _MessageSheetSelection(action: _MessageAction.reply),
          ),
          const _ContextMenuActionItem<_MessageSheetSelection>(
            label: 'Переслать',
            icon: Icons.forward_rounded,
            value: _MessageSheetSelection(action: _MessageAction.forward),
          ),
          const _ContextMenuActionItem<_MessageSheetSelection>(
            label: 'Выбрать',
            icon: Icons.checklist_rounded,
            value: _MessageSheetSelection(action: _MessageAction.select),
          ),
          if (canOpenDirectChat)
            const _ContextMenuActionItem<_MessageSheetSelection>(
              label: 'Написать в личку',
              icon: Icons.chat_bubble_outline_rounded,
              value: _MessageSheetSelection(action: _MessageAction.openDirect),
            ),
          _ContextMenuActionItem<_MessageSheetSelection>(
            label: isPinned ? 'Открепить' : 'Закрепить',
            icon: isPinned ? Icons.push_pin : Icons.push_pin_outlined,
            value: const _MessageSheetSelection(
              action: _MessageAction.pin,
            ),
          ),
          if (isOwnMessage)
            const _ContextMenuActionItem<_MessageSheetSelection>(
              label: 'Редактировать',
              icon: Icons.edit_outlined,
              value: _MessageSheetSelection(action: _MessageAction.edit),
            ),
          if (canCopy)
            const _ContextMenuActionItem<_MessageSheetSelection>(
              label: 'Копировать текст',
              icon: Icons.copy_rounded,
              value: _MessageSheetSelection(action: _MessageAction.copy),
            ),
          if (canReport)
            const _ContextMenuActionItem<_MessageSheetSelection>(
              label: 'Пожаловаться',
              icon: Icons.flag_outlined,
              value: _MessageSheetSelection(action: _MessageAction.report),
              isDestructive: true,
            ),
          if (canBlock)
            const _ContextMenuActionItem<_MessageSheetSelection>(
              label: 'Заблокировать',
              icon: Icons.block_outlined,
              value: _MessageSheetSelection(action: _MessageAction.block),
              isDestructive: true,
            ),
          if (isOwnMessage)
            const _ContextMenuActionItem<_MessageSheetSelection>(
              label: 'Удалить сообщение',
              icon: Icons.delete_outline_rounded,
              value: _MessageSheetSelection(action: _MessageAction.delete),
              isDestructive: true,
            ),
        ],
      );
    } else {
      selection = await showBlurredActionsSheet<_MessageSheetSelection>(
        context: context,
        builder: (context) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Быстрые реакции',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _quickReactionEmoji
                      .map(
                        (emoji) => ChoiceChip(
                          label: Text(emoji),
                          selected: _hasCurrentUserReaction(message, emoji),
                          onSelected: (_) => Navigator.of(context).pop(
                            _MessageSheetSelection(
                              action: _MessageAction.react,
                              emoji: emoji,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.reply_rounded),
                title: const Text('Ответить'),
                onTap: () => Navigator.of(context).pop(
                  const _MessageSheetSelection(
                    action: _MessageAction.reply,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.forward_rounded),
                title: const Text('Переслать'),
                onTap: () => Navigator.of(context).pop(
                  const _MessageSheetSelection(
                    action: _MessageAction.forward,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.checklist_rounded),
                title: const Text('Выбрать'),
                onTap: () => Navigator.of(context).pop(
                  const _MessageSheetSelection(
                    action: _MessageAction.select,
                  ),
                ),
              ),
              if (canOpenDirectChat)
                ListTile(
                  leading: const Icon(Icons.chat_bubble_outline_rounded),
                  title: const Text('Написать в личку'),
                  onTap: () => Navigator.of(context).pop(
                    const _MessageSheetSelection(
                      action: _MessageAction.openDirect,
                    ),
                  ),
                ),
              ListTile(
                leading: Icon(
                  isPinned ? Icons.push_pin : Icons.push_pin_outlined,
                ),
                title: Text(isPinned ? 'Открепить' : 'Закрепить'),
                onTap: () => Navigator.of(context).pop(
                  const _MessageSheetSelection(action: _MessageAction.pin),
                ),
              ),
              if (isOwnMessage)
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Редактировать'),
                  onTap: () => Navigator.of(context).pop(
                    const _MessageSheetSelection(
                      action: _MessageAction.edit,
                    ),
                  ),
                ),
              if (canCopy)
                ListTile(
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Копировать текст'),
                  onTap: () => Navigator.of(context).pop(
                    const _MessageSheetSelection(
                      action: _MessageAction.copy,
                    ),
                  ),
                ),
              if (canReport)
                ListTile(
                  leading: const Icon(Icons.flag_outlined),
                  title: const Text('Пожаловаться'),
                  onTap: () => Navigator.of(context).pop(
                    const _MessageSheetSelection(
                      action: _MessageAction.report,
                    ),
                  ),
                ),
              if (canBlock)
                ListTile(
                  leading: const Icon(Icons.block_outlined),
                  title: const Text('Заблокировать'),
                  onTap: () => Navigator.of(context).pop(
                    const _MessageSheetSelection(
                      action: _MessageAction.block,
                    ),
                  ),
                ),
              if (isOwnMessage)
                ListTile(
                  leading: const Icon(Icons.delete_outline_rounded),
                  title: const Text('Удалить сообщение'),
                  onTap: () => Navigator.of(context).pop(
                    const _MessageSheetSelection(
                      action: _MessageAction.delete,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    if (!mounted || selection == null) {
      return;
    }
    if (selection.action == _MessageAction.react && selection.emoji != null) {
      await _toggleReactionForMessage(message, selection.emoji!);
      return;
    }
    if (selection.action == _MessageAction.reply) {
      _selectReplyFromMessage(message);
      return;
    }
    if (selection.action == _MessageAction.forward) {
      _selectForwardFromMessage(message);
      return;
    }
    if (selection.action == _MessageAction.select) {
      _selectRemoteMessage(message);
      return;
    }
    if (selection.action == _MessageAction.openDirect) {
      await _openDirectChatForMessage(message);
      return;
    }
    if (selection.action == _MessageAction.pin) {
      if (isPinned) {
        await _clearPinnedMessage();
      } else {
        await _pinRemoteMessage(message);
      }
      return;
    }
    if (selection.action == _MessageAction.edit) {
      _selectEditMessage(message);
      return;
    }
    if (selection.action == _MessageAction.copy) {
      await _copyMessageText(message.text);
      return;
    }
    if (selection.action == _MessageAction.report) {
      await _reportRemoteMessage(message);
      return;
    }
    if (selection.action == _MessageAction.block) {
      await _blockUserFromMessage(message);
      return;
    }
    if (selection.action == _MessageAction.delete) {
      await _deleteRemoteMessage(message);
    }
  }

  Future<void> _openOutgoingMessageActions(
    _OutgoingMessage message, {
    Offset? anchorPosition,
  }) async {
    final canCopy = message.text.trim().isNotEmpty;
    final useDesktopMenu =
        _useDesktopMessageContextMenu() && anchorPosition != null;
    _MessageAction? action;
    if (useDesktopMenu) {
      action = await _showDesktopMessagePopover<_MessageAction>(
        anchorPosition: anchorPosition,
        actions: <_ContextMenuActionItem<_MessageAction>>[
          const _ContextMenuActionItem<_MessageAction>(
            label: 'Ответить',
            icon: Icons.reply_rounded,
            value: _MessageAction.reply,
          ),
          const _ContextMenuActionItem<_MessageAction>(
            label: 'Переслать',
            icon: Icons.forward_rounded,
            value: _MessageAction.forward,
          ),
          const _ContextMenuActionItem<_MessageAction>(
            label: 'Выбрать',
            icon: Icons.checklist_rounded,
            value: _MessageAction.select,
          ),
          if (canCopy)
            const _ContextMenuActionItem<_MessageAction>(
              label: 'Копировать текст',
              icon: Icons.copy_rounded,
              value: _MessageAction.copy,
            ),
          if (message.status == _OutgoingMessageStatus.failed)
            const _ContextMenuActionItem<_MessageAction>(
              label: 'Повторить отправку',
              icon: Icons.refresh_rounded,
              value: _MessageAction.retry,
            ),
          if (message.status != _OutgoingMessageStatus.sent)
            const _ContextMenuActionItem<_MessageAction>(
              label: 'Убрать из очереди',
              icon: Icons.delete_outline_rounded,
              value: _MessageAction.delete,
              isDestructive: true,
            ),
        ],
      );
    } else {
      action = await showBlurredActionsSheet<_MessageAction>(
        context: context,
        builder: (context) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.reply_rounded),
              title: const Text('Ответить'),
              onTap: () => Navigator.of(context).pop(_MessageAction.reply),
            ),
            ListTile(
              leading: const Icon(Icons.forward_rounded),
              title: const Text('Переслать'),
              onTap: () => Navigator.of(context).pop(_MessageAction.forward),
            ),
            ListTile(
              leading: const Icon(Icons.checklist_rounded),
              title: const Text('Выбрать'),
              onTap: () => Navigator.of(context).pop(_MessageAction.select),
            ),
            if (canCopy)
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Копировать текст'),
                onTap: () => Navigator.of(context).pop(_MessageAction.copy),
              ),
            if (message.status == _OutgoingMessageStatus.failed)
              ListTile(
                leading: const Icon(Icons.refresh_rounded),
                title: const Text('Повторить отправку'),
                onTap: () => Navigator.of(context).pop(_MessageAction.retry),
              ),
            if (message.status != _OutgoingMessageStatus.sent)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: const Text('Убрать из очереди'),
                onTap: () => Navigator.of(context).pop(_MessageAction.delete),
              ),
            const SizedBox(height: 8),
          ],
        ),
      );
    }
    if (!mounted || action == null) {
      return;
    }

    switch (action) {
      case _MessageAction.react:
        return;
      case _MessageAction.reply:
        _selectReplyFromOutgoingMessage(message);
        return;
      case _MessageAction.forward:
        _selectForwardFromOutgoingMessage(message);
        return;
      case _MessageAction.select:
        _selectOutgoingMessage(message);
        return;
      case _MessageAction.pin:
        return;
      case _MessageAction.edit:
        return;
      case _MessageAction.copy:
        await _copyMessageText(message.text);
        return;
      case _MessageAction.openDirect:
        return;
      case _MessageAction.report:
        return;
      case _MessageAction.block:
        return;
      case _MessageAction.retry:
        await _sendQueue.retry(message.chatId, message.localId);
        return;
      case _MessageAction.delete:
        await _sendQueue.remove(message.chatId, message.localId);
        return;
    }
  }

  void _selectReplyFromMessage(ChatMessage message) {
    final senderName =
        _groupSenderLabel(message.senderName, message.senderId) ??
            (message.senderId == _currentUserId ? 'Вы' : 'Участник');
    setState(() {
      _selectedEdit = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
      _selectedReply = ChatReplyReference(
        messageId: message.id,
        senderId: message.senderId,
        senderName: senderName,
        text: message.text,
      );
    });
  }

  void _selectReplyFromOutgoingMessage(_OutgoingMessage message) {
    final senderName = message.senderId == _currentUserId ? 'Вы' : 'Участник';
    setState(() {
      _selectedEdit = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
      _selectedReply = ChatReplyReference(
        messageId: message.localId,
        senderId: message.senderId,
        senderName: senderName,
        text: message.text,
      );
    });
  }

  void _selectForwardFromMessage(ChatMessage message) {
    final senderName =
        _groupSenderLabel(message.senderName, message.senderId) ??
            (message.senderId == _currentUserId ? 'Вы' : 'Участник');
    setState(() {
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForwardBatch = null;
      _selectedForward = _ForwardDraft(
        senderName: senderName,
        text: message.text,
        attachments: message.attachments,
      );
    });
  }

  void _selectForwardFromOutgoingMessage(_OutgoingMessage message) {
    final senderName = message.senderId == _currentUserId ? 'Вы' : 'Участник';
    final forwardedAttachments = message.forwardedAttachments.isNotEmpty
        ? message.forwardedAttachments
        : message.attachments
            .map(
              (file) => ChatAttachment(
                type: _attachmentTypeForDraft(file),
                url: file.path,
                mimeType: file.mimeType,
                fileName: file.name,
              ),
            )
            .toList();
    setState(() {
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForwardBatch = null;
      _selectedForward = _ForwardDraft(
        senderName: senderName,
        text: message.text,
        attachments: forwardedAttachments,
      );
    });
  }

  void _selectEditMessage(ChatMessage message) {
    _messageController.value = TextEditingValue(
      text: message.text,
      selection: TextSelection.collapsed(offset: message.text.length),
    );
    setState(() {
      _selectedReply = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
      _selectedEdit = _EditDraft(
        messageId: message.id,
        originalText: message.text,
        hasAttachments: message.attachments.isNotEmpty,
      );
    });
    _attachmentsController.clear();
  }

  bool _useDesktopMessageContextMenu() {
    final platform = Theme.of(context).platform;
    final isDesktopPlatform = kIsWeb ||
        platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
    return isDesktopPlatform && MediaQuery.of(context).size.width >= 720;
  }

  Future<T?> _showDesktopMessagePopover<T>({
    required Offset anchorPosition,
    required List<_ContextMenuActionItem<T>> actions,
    List<String> reactions = const <String>[],
    T Function(String emoji)? reactionValueBuilder,
  }) {
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'message-context-menu',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (dialogContext, _, __) {
        final screenSize = MediaQuery.of(dialogContext).size;
        const popupWidth = 320.0;
        final reactionBarHeight = reactions.isEmpty ? 0.0 : 58.0;
        final menuHeight = 16.0 + actions.length * 46.0;
        final totalHeight =
            reactionBarHeight + (reactionBarHeight == 0 ? 0 : 8) + menuHeight;
        final openBelow =
            anchorPosition.dy + totalHeight + 12 <= screenSize.height;
        final resolvedLeft = (anchorPosition.dx - popupWidth / 2)
            .clamp(12.0, screenSize.width - popupWidth - 12.0);
        final resolvedTop = (openBelow
                ? anchorPosition.dy + 10
                : anchorPosition.dy - totalHeight - 10)
            .clamp(12.0, screenSize.height - totalHeight - 12.0);

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => Navigator.of(dialogContext).maybePop(),
              ),
            ),
            Positioned(
              left: resolvedLeft,
              top: resolvedTop,
              child: _DesktopMessageContextMenu<T>(
                reactions: reactions,
                actions: actions,
                onReactionSelected: reactionValueBuilder == null
                    ? null
                    : (emoji) => Navigator.of(dialogContext)
                        .pop(reactionValueBuilder(emoji)),
                onActionSelected: (value) {
                  Navigator.of(dialogContext).pop(value);
                },
              ),
            ),
          ],
        );
      },
      transitionBuilder: (context, animation, _, child) {
        final curvedAnimation = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curvedAnimation,
          child: ScaleTransition(
            scale: Tween<double>(
              begin: 0.96,
              end: 1,
            ).animate(curvedAnimation),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openRemoteAttachmentPreview(
    ChatMessage message,
    List<ChatAttachment> attachments,
    ChatAttachment initialAttachment,
  ) async {
    final currentAttachmentIndex = attachments.indexWhere(
      (attachment) => _attachmentsMatch(attachment, initialAttachment),
    );
    final initialItemId =
        'remote:${message.id}:${currentAttachmentIndex < 0 ? 0 : currentAttachmentIndex}';
    final previewItems = _remoteAttachmentGalleryItems();
    if (previewItems.isEmpty) {
      return;
    }
    final initialIndex = previewItems.indexWhere(
      (item) => item.id == initialItemId,
    );
    await showDialog<void>(
      context: context,
      builder: (context) => _AttachmentViewerDialog(
        items: previewItems,
        initialIndex: initialIndex == -1 ? 0 : initialIndex,
        onOpenExternally: _openAttachmentExternally,
        onDownload: _downloadAttachmentToDevice,
      ),
    );
  }

  Future<void> _openLocalAttachmentPreview(
    List<XFile> files,
    XFile initialFile,
  ) async {
    final kind = _attachmentKindFromXFile(initialFile);
    if (kind == _ChatAttachmentKind.other) {
      await _openLocalAttachmentExternally(initialFile);
      return;
    }

    final previewItems = files
        .where((file) =>
            _attachmentKindFromXFile(file) != _ChatAttachmentKind.audio)
        .toList()
        .asMap()
        .entries
        .map(
          (entry) => _attachmentPreviewItemFromLocal(
            entry.value,
            id: 'local:${entry.key}:${entry.value.name}',
          ),
        )
        .toList();
    if (previewItems.isEmpty) {
      return;
    }
    final initialIndex = previewItems.indexWhere(
      (item) => item.displayName == _displayName(initialFile.name),
    );
    await showDialog<void>(
      context: context,
      builder: (context) => _AttachmentViewerDialog(
        items: previewItems,
        initialIndex: initialIndex == -1 ? 0 : initialIndex,
        onOpenExternally: _openAttachmentExternally,
        onDownload: _downloadAttachmentToDevice,
      ),
    );
  }

  List<_AttachmentPreviewItem> _remoteAttachmentGalleryItems() {
    final messages = List<ChatMessage>.from(_latestRemoteMessages)
      ..sort((left, right) => left.timestamp.compareTo(right.timestamp));
    final previewItems = <_AttachmentPreviewItem>[];
    for (final message in messages) {
      final senderLabel = _senderDisplayNameForMessage(
        senderId: message.senderId,
        senderName: message.senderName,
      );
      for (var index = 0; index < message.attachments.length; index++) {
        final attachment = message.attachments[index];
        final kind = _attachmentKindFromAttachment(attachment);
        if (kind == _ChatAttachmentKind.audio) {
          continue;
        }
        previewItems.add(
          _attachmentPreviewItemFromRemote(
            attachment,
            id: 'remote:${message.id}:$index',
            senderLabel: senderLabel,
            timestamp: message.timestamp,
            caption: message.text.trim(),
          ),
        );
      }
    }
    return previewItems;
  }

  _AttachmentPreviewItem _attachmentPreviewItemFromRemote(
    ChatAttachment attachment, {
    required String id,
    String? senderLabel,
    DateTime? timestamp,
    String? caption,
  }) {
    return _AttachmentPreviewItem.remote(
      id: id,
      kind: _attachmentKindFromAttachment(attachment),
      source: attachment.url,
      displayName: _displayName(attachment.fileName ?? attachment.url),
      thumbnailUrl: attachment.thumbnailUrl,
      senderLabel: senderLabel,
      timestamp: timestamp,
      caption: caption,
      isVideoNote: attachment.isVideoNote,
    );
  }

  _AttachmentPreviewItem _attachmentPreviewItemFromLocal(
    XFile file, {
    required String id,
  }) {
    return _AttachmentPreviewItem.local(
      id: id,
      kind: _attachmentKindFromXFile(file),
      file: file,
      displayName: _displayName(file.name),
      senderLabel: 'Вы',
      timestamp: DateTime.now(),
      caption: '',
      isVideoNote: _isVideoNoteFile(file),
    );
  }

  bool _attachmentsMatch(ChatAttachment left, ChatAttachment right) {
    return left.type == right.type &&
        left.url == right.url &&
        left.fileName == right.fileName &&
        left.thumbnailUrl == right.thumbnailUrl;
  }

  Future<void> _openAttachmentExternally(_AttachmentPreviewItem item) async {
    try {
      if (!item.isRemote && item.file != null) {
        await _openLocalAttachmentExternally(item.file!);
        return;
      }
      final source = item.source;
      if (source == null || source.trim().isEmpty) {
        return;
      }
      final uri = Uri.parse(source);
      await launchUrl(
        uri,
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось открыть вложение.', isError: true);
    }
  }

  Future<void> _openLocalAttachmentExternally(XFile file) async {
    try {
      if (kIsWeb && file.path.trim().isNotEmpty) {
        await launchUrl(
          Uri.parse(file.path),
          webOnlyWindowName: '_blank',
        );
        return;
      }
      await OpenFilex.open(file.path);
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Не удалось открыть локальный файл.',
        isError: true,
      );
    }
  }

  Future<void> _downloadAttachmentToDevice(_AttachmentPreviewItem item) async {
    try {
      if (!item.isRemote ||
          item.source == null ||
          item.source!.trim().isEmpty) {
        await _openAttachmentExternally(item);
        return;
      }
      if (supportsChatAttachmentDownload) {
        await downloadChatAttachment(
          item.source!,
          suggestedFileName: item.displayName,
        );
      } else {
        await _openAttachmentExternally(item);
      }
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        supportsChatAttachmentDownload
            ? 'Скачивание запущено'
            : 'Вложение открыто во внешнем приложении',
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось сохранить вложение.', isError: true);
    }
  }

  Future<void> _deleteRemoteMessage(ChatMessage message) async {
    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить сообщение'),
        content: const Text('Это действие нельзя отменить.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    try {
      await _chatService.deleteChatMessage(
        chatId: chatId,
        messageId: message.id,
      );
      if (!mounted) {
        return;
      }
      if (_selectedEdit?.messageId == message.id) {
        _messageController.clear();
        setState(() {
          _selectedEdit = null;
        });
      }
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось удалить сообщение.', isError: true);
    }
  }

  ChatAttachmentType _attachmentTypeForDraft(XFile file) {
    switch (_attachmentKindFromXFile(file)) {
      case _ChatAttachmentKind.image:
        return ChatAttachmentType.image;
      case _ChatAttachmentKind.video:
        return ChatAttachmentType.video;
      case _ChatAttachmentKind.audio:
        return ChatAttachmentType.audio;
      case _ChatAttachmentKind.other:
        return ChatAttachmentType.file;
    }
  }

  Widget _buildReplyComposerBar(ThemeData theme, ChatReplyReference reply) {
    final hasText = reply.text.trim().isNotEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 36,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Ответ: ${reply.senderName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasText ? reply.text : 'Сообщение без текста',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              setState(() {
                _selectedReply = null;
              });
            },
            tooltip: 'Отменить ответ',
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildEditComposerBar(ThemeData theme, _EditDraft draft) {
    final originalText = draft.originalText.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 40,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Редактируете сообщение',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.secondary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  originalText.isNotEmpty
                      ? originalText
                      : (draft.hasAttachments
                          ? 'Сообщение с вложением'
                          : 'Сообщение без текста'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Отменить редактирование',
            onPressed: () {
              _messageController.clear();
              setState(() {
                _selectedEdit = null;
              });
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildForwardComposerBar(ThemeData theme, _ForwardDraft draft) {
    final hasText = draft.text.trim().isNotEmpty;
    final attachmentCount = draft.attachments.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 42,
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Пересылаете: ${draft.senderName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasText ? draft.text : 'Сообщение без текста',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (attachmentCount > 0)
                  Text(
                    _attachmentCountLabel(attachmentCount),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Отменить пересылку',
            onPressed: () {
              setState(() {
                _selectedForward = null;
              });
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildForwardBatchComposerBar(
    ThemeData theme,
    _ForwardBatchDraft draft,
  ) {
    final messageCount = draft.items.length;
    final attachmentCount = draft.items.fold<int>(
      0,
      (total, item) => total + item.attachments.length,
    );
    final previewText = draft.items.map((item) => item.text.trim()).firstWhere(
          (text) => text.isNotEmpty,
          orElse: () => 'Сообщения без текста',
        );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 42,
            decoration: BoxDecoration(
              color: theme.colorScheme.tertiary,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  messageCount == 1
                      ? 'Пересылаете 1 сообщение'
                      : 'Пересылаете $messageCount сообщений',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.tertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  previewText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (attachmentCount > 0)
                  Text(
                    _attachmentCountLabel(attachmentCount),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Отменить пересылку',
            onPressed: () {
              setState(() {
                _selectedForwardBatch = null;
              });
            },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  String _attachmentCountLabel(int count) {
    final noun = count == 1
        ? 'вложение'
        : (count >= 2 && count <= 4 ? 'вложения' : 'вложений');
    return '$count $noun';
  }
}

class _ChatInfoSheet extends StatefulWidget {
  const _ChatInfoSheet({
    required this.initialDetails,
    required this.currentUserId,
    this.onlineUserIds = const <String>{},
    this.lastSeenByUserId = const <String, DateTime>{},
    required this.hasPinnedMessage,
    required this.initialNotificationLevel,
    required this.initialAutoDeleteOption,
    required this.onRename,
    required this.onUpdatePhoto,
    required this.onAddParticipants,
    required this.onRemoveParticipant,
    required this.onOpenDirectChat,
    required this.onLeaveGroup,
    required this.onOpenSearch,
    required this.onNotificationLevelChanged,
    required this.onAutoDeleteChanged,
    this.onOpenPinnedMessage,
    this.onOpenTree,
    this.onOpenRelatives,
    this.onOpenMedia,
    this.onOpenFiles,
  });

  final ChatDetails initialDetails;
  final String currentUserId;

  /// Снапшот присутствия на момент открытия шита (см. _openChatInfo).
  final Set<String> onlineUserIds;
  final Map<String, DateTime> lastSeenByUserId;
  final bool hasPinnedMessage;
  final ChatNotificationLevel initialNotificationLevel;
  final ChatAutoDeleteOption initialAutoDeleteOption;
  final Future<ChatDetails> Function(String title) onRename;
  final Future<ChatDetails> Function(XFile photo) onUpdatePhoto;
  final Future<ChatDetails> Function(List<String> participantIds)
      onAddParticipants;
  final Future<ChatDetails> Function(String participantId) onRemoveParticipant;
  final void Function(ChatParticipantSummary participant) onOpenDirectChat;
  final Future<void> Function() onLeaveGroup;
  final VoidCallback onOpenSearch;
  final Future<void> Function(ChatNotificationLevel level)
      onNotificationLevelChanged;
  final Future<void> Function(ChatAutoDeleteOption option) onAutoDeleteChanged;
  final VoidCallback? onOpenPinnedMessage;
  final VoidCallback? onOpenTree;
  final VoidCallback? onOpenRelatives;
  final VoidCallback? onOpenMedia;
  final VoidCallback? onOpenFiles;

  @override
  State<_ChatInfoSheet> createState() => _ChatInfoSheetState();
}

/// Компактное «когда был(а) в сети» для строк участников — нейтральная
/// форма без гендерной эвристики (в отличие от заголовка личного чата,
/// где имя одно и _formatLastSeen может позволить себе «была»).
String _relativeLastSeenLabel(DateTime rawLastSeen) {
  final lastSeen = toLocalForDisplay(rawLastSeen);
  final delta = DateTime.now().difference(lastSeen);
  if (delta.inMinutes < 1) {
    return 'был(а) только что';
  }
  if (delta.inMinutes < 60) {
    return 'был(а) ${delta.inMinutes} мин назад';
  }
  if (delta.inHours < 24) {
    return 'был(а) ${delta.inHours} ч назад';
  }
  if (delta.inDays < 7) {
    return 'был(а) ${delta.inDays} дн назад';
  }
  final date =
      '${lastSeen.day.toString().padLeft(2, '0')}.${lastSeen.month.toString().padLeft(2, '0')}';
  return 'был(а) $date';
}

class _ChatInfoSheetState extends State<_ChatInfoSheet> {
  late ChatDetails _details;
  late ChatNotificationLevel _notificationLevel;
  late ChatAutoDeleteOption _autoDeleteOption;
  bool _isSaving = false;
  bool _isUpdatingNotifications = false;
  bool _isUpdatingAutoDelete = false;

  @override
  void initState() {
    super.initState();
    _details = widget.initialDetails;
    _notificationLevel = widget.initialNotificationLevel;
    _autoDeleteOption = widget.initialAutoDeleteOption;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFriendsTree =
        context.read<TreeProvider>().selectedTreeKind == TreeKind.friends;
    final screenHeight = MediaQuery.of(context).size.height;
    final hasTreeContext =
        _details.treeId != null && _details.treeId!.trim().isNotEmpty;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SizedBox(
          height: screenHeight * 0.84,
          child: ListView(
            children: [
              Row(
                children: [
                  Text(
                    'О чате',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                    style: IconButton.styleFrom(
                      backgroundColor: theme.colorScheme.surfaceContainerHighest
                          .withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _buildChatIdentityCard(theme),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _InfoChip(
                    icon: _details.isBranch
                        ? Icons.account_tree_outlined
                        : (_details.isDirect
                            ? Icons.chat_bubble_outline
                            : Icons.groups_2_outlined),
                    label: _details.isBranch
                        ? 'Чат ветки'
                        : _details.isDirect
                            ? 'Личный чат'
                            : (isFriendsTree ? 'Группа круга' : 'Группа'),
                  ),
                  _InfoChip(
                    icon: Icons.people_outline,
                    label: _details.memberCount == 1
                        ? '1 участник'
                        : '${_details.memberCount} участников',
                  ),
                  _InfoChip(
                    icon: isFriendsTree
                        ? Icons.diversity_3_outlined
                        : Icons.account_tree_outlined,
                    label: isFriendsTree ? 'Контекст круга' : 'Контекст дерева',
                  ),
                ],
              ),
              // UX-аудит: в группе участники — самое востребованное в «О
              // чате», а лежали в самом низу за ~5 экранами настроек.
              if (_details.isGroup) ..._buildParticipantsSectionWidgets(theme),
              const SizedBox(height: 16),
              GlassPanel(
                padding: const EdgeInsets.all(14),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _InfoChip(
                      icon: Icons.mark_chat_unread_outlined,
                      label: _details.isEditableGroup
                          ? 'Можно редактировать'
                          : 'Состав фиксируется',
                    ),
                    _InfoChip(
                      icon: Icons.badge_outlined,
                      label: _details.participants.any((participant) =>
                              participant.userId == widget.currentUserId)
                          ? 'Вы в составе'
                          : 'Без вашего профиля',
                    ),
                    if (widget.hasPinnedMessage)
                      const _InfoChip(
                        icon: Icons.push_pin_outlined,
                        label: 'Есть закрепленное',
                      ),
                    _InfoChip(
                      icon: _notificationLevel == ChatNotificationLevel.muted
                          ? Icons.notifications_off_outlined
                          : (_notificationLevel == ChatNotificationLevel.silent
                              ? Icons.notifications_none_outlined
                              : Icons.notifications_active_outlined),
                      label: _notificationLevel.label,
                    ),
                    _InfoChip(
                      icon: _autoDeleteOption == ChatAutoDeleteOption.off
                          ? Icons.timer_off_outlined
                          : Icons.timer_outlined,
                      label: _autoDeleteOption == ChatAutoDeleteOption.off
                          ? 'Без автоудаления'
                          : 'TTL: ${_autoDeleteOption.label}',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Быстрые действия',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _QuickActionCard(
                    icon: Icons.search,
                    title: 'Поиск в чате',
                    subtitle: 'По слову или фразе',
                    onTap: widget.onOpenSearch,
                  ),
                  if (widget.onOpenMedia != null)
                    _QuickActionCard(
                      icon: Icons.perm_media_outlined,
                      title: 'Медиа',
                      subtitle: 'Фото, видео и кружки',
                      onTap: widget.onOpenMedia!,
                    ),
                  if (widget.onOpenFiles != null)
                    _QuickActionCard(
                      icon: Icons.folder_open_outlined,
                      title: 'Файлы',
                      subtitle: 'Документы и голосовые',
                      onTap: widget.onOpenFiles!,
                    ),
                  if (widget.onOpenPinnedMessage != null)
                    _QuickActionCard(
                      icon: Icons.push_pin_outlined,
                      title: 'К закрепленному',
                      subtitle: 'Открыть закрепленное',
                      onTap: widget.onOpenPinnedMessage!,
                    ),
                  if (hasTreeContext && widget.onOpenTree != null)
                    _QuickActionCard(
                      icon: Icons.account_tree_outlined,
                      title: 'Открыть дерево',
                      subtitle: 'Перейти к дереву',
                      onTap: widget.onOpenTree!,
                    ),
                  if (hasTreeContext && widget.onOpenRelatives != null)
                    _QuickActionCard(
                      icon: Icons.people_alt_outlined,
                      title: 'Открыть родных',
                      subtitle: 'Перейти к списку',
                      onTap: widget.onOpenRelatives!,
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'Уведомления',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              GlassPanel(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _notificationLevel.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _notificationLevel.summary,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ChatNotificationLevel.values.map((level) {
                        final isSelected = _notificationLevel == level;
                        return ChoiceChip(
                          label: Text(level.label),
                          selected: isSelected,
                          onSelected: _isUpdatingNotifications || isSelected
                              ? null
                              : (_) => _setNotificationLevel(level),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text(
                'Автоудаление',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              GlassPanel(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _autoDeleteOption.label,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _autoDeleteOption.summary,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: ChatAutoDeleteOption.values.map((option) {
                        final isSelected = _autoDeleteOption == option;
                        return ChoiceChip(
                          label: Text(option.label),
                          selected: isSelected,
                          onSelected: _isUpdatingAutoDelete || isSelected
                              ? null
                              : (_) => _setAutoDeleteOption(option),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),
              if (_details.branchRoots.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  isFriendsTree ? 'Круги' : 'Ветки',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _details.branchRoots
                      .map(
                        (root) => _InfoChip(
                          icon: isFriendsTree
                              ? Icons.diversity_3_outlined
                              : Icons.account_tree_outlined,
                          label: root.name,
                        ),
                      )
                      .toList(),
                ),
              ],
              const SizedBox(height: 18),
              Text(
                'Управление',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              if (_details.isEditableGroup)
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isSaving ? null : _renameChat,
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Переименовать'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _isSaving ? null : _addParticipants,
                        icon: const Icon(Icons.person_add_alt_1_outlined),
                        label: const Text('Добавить'),
                      ),
                    ),
                  ],
                )
              else
                GlassPanel(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    _details.isBranch
                        ? 'Состав идет из дерева.'
                        : _details.isDirect
                            ? 'Состав личного чата фиксирован.'
                            : 'Состав сейчас не меняется.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              // Для групп секция «Участники» уехала наверх (сразу после
              // чипов) — здесь остаётся только для личных/branch чатов.
              if (!_details.isGroup) ..._buildParticipantsSectionWidgets(theme),
              // G2: самовыход из группы. Доступен только в обычном
              // групповом чате (как и кнопка «убрать»); личные/branch не
              // покидают этим путём.
              if (_details.isEditableGroup) ...[
                const SizedBox(height: 18),
                OutlinedButton.icon(
                  key: const Key('chat-info-leave-group'),
                  onPressed: _isSaving ? null : _leaveGroup,
                  icon: const Icon(Icons.logout_rounded),
                  label: const Text('Покинуть чат'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(
                      color: theme.colorScheme.error.withValues(alpha: 0.5),
                    ),
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Секция «Участники»: у групп рендерится сразу после чипов, у
  /// личных/branch — на прежнем месте внизу. Строки кликабельны целиком
  /// (тап → личка, тот же путь, что и иконка) и показывают присутствие
  /// из снапшота на момент открытия шита.
  List<Widget> _buildParticipantsSectionWidgets(ThemeData theme) {
    return [
      const SizedBox(height: 18),
      Text(
        'Участники',
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 8),
      GlassPanel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          children: _details.participants.asMap().entries.map((entry) {
            final index = entry.key;
            final participant = entry.value;
            final isCurrentUser = participant.userId == widget.currentUserId;
            final avatarImage = buildAvatarImageProvider(participant.photoUrl);
            final isOnline = !isCurrentUser &&
                widget.onlineUserIds.contains(participant.userId);
            final lastSeen = widget.lastSeenByUserId[participant.userId] ??
                participant.lastSeenAt;
            final subtitle = isCurrentUser
                ? 'Вы'
                : isOnline
                    ? 'в сети'
                    : (lastSeen != null
                        ? _relativeLastSeenLabel(lastSeen)
                        : 'Участник');
            return Column(
              children: [
                if (index > 0) const Divider(height: 1),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  // Вся строка — таргет для «в личку» (иконки справа
                  // были единственной, слишком мелкой целью). Только в
                  // группе: в личном чате тап по собеседнику открыл бы
                  // дубль того же чата (ревью батча).
                  onTap: isCurrentUser || _isSaving || !_details.isGroup
                      ? null
                      : () => widget.onOpenDirectChat(participant),
                  leading: CircleAvatar(
                    backgroundImage: avatarImage,
                    child: avatarImage == null
                        ? Text(
                            participant.displayName.isNotEmpty
                                ? participant.displayName[0]
                                : '?',
                          )
                        : null,
                  ),
                  title: Text(participant.displayName),
                  subtitle: Text(
                    subtitle,
                    style: isOnline
                        ? const TextStyle(
                            color: Color(0xFF2EBD68),
                            fontWeight: FontWeight.w600,
                          )
                        : null,
                  ),
                  trailing: isCurrentUser || !_details.isGroup
                      ? null
                      : Wrap(
                          spacing: 2,
                          children: [
                            IconButton(
                              onPressed: _isSaving
                                  ? null
                                  : () => widget.onOpenDirectChat(participant),
                              tooltip: 'Написать в личку',
                              icon: const Icon(
                                Icons.chat_bubble_outline_rounded,
                              ),
                            ),
                            if (_details.isEditableGroup)
                              IconButton(
                                onPressed: _isSaving
                                    ? null
                                    : () => _removeParticipant(participant),
                                tooltip: 'Убрать из чата',
                                icon: const Icon(
                                  Icons.person_remove_outlined,
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            );
          }).toList(),
        ),
      ),
    ];
  }

  Widget _buildChatIdentityCard(ThemeData theme) {
    String? avatarUrl;
    final chatPhotoUrl = _details.photoUrl?.trim();
    if (chatPhotoUrl != null && chatPhotoUrl.isNotEmpty) {
      avatarUrl = chatPhotoUrl;
    } else if (_details.isBranch && _details.branchRoots.isNotEmpty) {
      avatarUrl = _details.branchRoots.first.photoUrl;
    } else if (_details.isDirect) {
      for (final participant in _details.participants) {
        if (participant.userId != widget.currentUserId) {
          avatarUrl = participant.photoUrl;
          break;
        }
      }
    }

    final avatarImage = buildAvatarImageProvider(avatarUrl);
    final title = _details.displayTitleFor(widget.currentUserId);
    final subtitle = _details.isDirect
        ? 'Личные сообщения'
        : (_details.memberCount == 1
            ? '1 участник'
            : '${_details.memberCount} участников');

    return GlassPanel(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          CircleAvatar(
            radius: 28,
            backgroundImage: avatarImage,
            child: avatarImage == null
                ? Icon(
                    _details.isDirect
                        ? Icons.person_outline
                        : Icons.groups_2_outlined,
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (_details.isEditableGroup) ...[
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _isSaving ? null : _changeChatPhoto,
              icon: const Icon(Icons.photo_camera_outlined, size: 18),
              label: const Text('Фото'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _changeChatPhoto() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 86,
      maxWidth: 1600,
    );
    if (!mounted || picked == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onUpdatePhoto(picked);
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
      showAppSnackBar(context, 'Фото чата обновлено.');
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Не удалось обновить фото чата.',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Покинуть чат'),
        content: const Text(
          'Вы выйдете из этого группового чата. Чтобы вернуться, кто-то из '
          'участников должен добавить вас снова.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      await widget.onLeaveGroup();
      // Успех: вызывающий закрывает шит и уводит к списку чатов — здесь
      // больше ничего делать не нужно (виджет уже размонтирован).
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _isSaving = false;
      });
      showAppSnackBar(
        context,
        'Не удалось покинуть чат.',
        isError: true,
      );
    }
  }

  Future<void> _setNotificationLevel(ChatNotificationLevel level) async {
    if (_notificationLevel == level) {
      return;
    }
    final previousLevel = _notificationLevel;
    setState(() {
      _isUpdatingNotifications = true;
      _notificationLevel = level;
    });
    try {
      await widget.onNotificationLevelChanged(level);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _notificationLevel = previousLevel;
      });
      showAppSnackBar(
        context,
        'Не удалось обновить настройки уведомлений.',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUpdatingNotifications = false;
        });
      }
    }
  }

  Future<void> _setAutoDeleteOption(ChatAutoDeleteOption option) async {
    if (_autoDeleteOption == option) {
      return;
    }
    final previousOption = _autoDeleteOption;
    setState(() {
      _isUpdatingAutoDelete = true;
      _autoDeleteOption = option;
    });
    try {
      await widget.onAutoDeleteChanged(option);
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _autoDeleteOption = previousOption;
      });
      showAppSnackBar(
        context,
        'Не удалось обновить автоудаление сообщений.',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isUpdatingAutoDelete = false;
        });
      }
    }
  }

  Future<void> _renameChat() async {
    final controller = TextEditingController(
      text: _details.displayTitleFor(widget.currentUserId),
    );
    final nextTitle = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Переименовать чат'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Название',
            hintText: 'Например, Семья Кузнецовых',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (!mounted || nextTitle == null || nextTitle.trim().isEmpty) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onRename(nextTitle.trim());
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось переименовать чат.', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _addParticipants() async {
    final treeId = _details.treeId;
    if (treeId == null || treeId.isEmpty) {
      showAppSnackBar(context, 'Для этого чата не найдено дерево.',
          isError: true);
      return;
    }
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      showAppSnackBar(
        context,
        'Список родных временно недоступен.',
        isError: true,
      );
      return;
    }

    final familyTreeService = GetIt.I<FamilyTreeServiceInterface>();
    final relatives = await familyTreeService.getRelatives(treeId);
    if (!mounted) {
      return;
    }

    final existingParticipantIds = _details.participantIds.toSet();
    final candidates = relatives
        .where((person) {
          final userId = person.userId?.trim();
          return userId != null &&
              userId.isNotEmpty &&
              userId != widget.currentUserId &&
              !existingParticipantIds.contains(userId);
        })
        .map(
          (person) => _GroupChatCandidate(
            userId: person.userId!.trim(),
            displayName:
                person.name.trim().isNotEmpty ? person.name : 'Пользователь',
            photoUrl: person.photoUrl,
            relationLabel: (person.relation ?? '').trim().isNotEmpty
                ? person.relation!.trim()
                : 'Родственник',
          ),
        )
        .toList()
      ..sort((left, right) => left.displayName.compareTo(right.displayName));

    if (candidates.isEmpty) {
      showAppSnackBar(context, 'В этом дереве больше некого добавить.');
      return;
    }

    final selectedIds = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _AddParticipantsSheet(candidates: candidates),
    );

    if (!mounted || selectedIds == null || selectedIds.isEmpty) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onAddParticipants(selectedIds);
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(context, 'Не удалось добавить участников.',
          isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _removeParticipant(
    ChatParticipantSummary participant,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Убрать участника'),
        content: Text(
          'Убрать ${participant.displayName} из этого чата?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Убрать'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) {
      return;
    }

    setState(() {
      _isSaving = true;
    });
    try {
      final details = await widget.onRemoveParticipant(participant.userId);
      if (!mounted) {
        return;
      }
      setState(() {
        _details = details;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      showAppSnackBar(
        context,
        'Не удалось обновить состав чата.',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 220,
      child: GlassPanel(
        padding: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(height: 10),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupChatCandidate {
  const _GroupChatCandidate({
    required this.userId,
    required this.displayName,
    required this.relationLabel,
    this.photoUrl,
  });

  final String userId;
  final String displayName;
  final String relationLabel;
  final String? photoUrl;
}

class _AddParticipantsSheet extends StatefulWidget {
  const _AddParticipantsSheet({required this.candidates});

  final List<_GroupChatCandidate> candidates;

  @override
  State<_AddParticipantsSheet> createState() => _AddParticipantsSheetState();
}

class _AddParticipantsSheetState extends State<_AddParticipantsSheet> {
  final Set<String> _selectedIds = <String>{};
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final search = _searchController.text.trim().toLowerCase();
    final filteredCandidates = widget.candidates.where((candidate) {
      if (search.isEmpty) {
        return true;
      }
      return candidate.displayName.toLowerCase().contains(search) ||
          candidate.relationLabel.toLowerCase().contains(search);
    }).toList();

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: SizedBox(
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    'Добавить участников',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const Spacer(),
                  Text(
                    _selectedIds.isEmpty ? '0' : '${_selectedIds.length}',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GlassPanel(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Найти по имени',
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.separated(
                  itemCount: filteredCandidates.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final candidate = filteredCandidates[index];
                    final isSelected = _selectedIds.contains(candidate.userId);
                    final avatarImage =
                        buildAvatarImageProvider(candidate.photoUrl);
                    return GlassPanel(
                      padding: EdgeInsets.zero,
                      child: CheckboxListTile(
                        value: isSelected,
                        onChanged: (_) {
                          setState(() {
                            if (isSelected) {
                              _selectedIds.remove(candidate.userId);
                            } else {
                              _selectedIds.add(candidate.userId);
                            }
                          });
                        },
                        secondary: CircleAvatar(
                          backgroundImage: avatarImage,
                          child: avatarImage == null
                              ? Text(
                                  candidate.displayName.isNotEmpty
                                      ? candidate.displayName[0]
                                      : '?',
                                )
                              : null,
                        ),
                        title: Text(candidate.displayName),
                        subtitle: Text(candidate.relationLabel),
                        controlAffinity: ListTileControlAffinity.trailing,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _selectedIds.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(_selectedIds.toList()),
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: Text(
                    _selectedIds.isEmpty
                        ? 'Выберите участников'
                        : 'Добавить ${_selectedIds.length}',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// _AttachmentPickerChoice enum removed — the picker now returns the
// AttachmentPickerAction.id string directly, so the call site switches
// on plain `'images'` / `'video'` / `'video_note'` / `'file'`.

bool _isVoiceNoteFileName(String value) {
  final normalizedValue = value.trim().toLowerCase();
  return normalizedValue.startsWith('voice_note_') ||
      normalizedValue.startsWith('voice-note-');
}

bool _isVideoNoteFileName(String value) {
  final normalizedValue = value.trim().toLowerCase();
  return normalizedValue.startsWith('video_note_') ||
      normalizedValue.startsWith('video-note-');
}

Duration? _durationFromAttachmentName(String value) {
  final match = RegExp(r'_(\d+)s_').firstMatch(value.trim().toLowerCase());
  final seconds = int.tryParse(match?.group(1) ?? '');
  if (seconds == null || seconds <= 0) {
    return null;
  }
  return Duration(seconds: seconds);
}

String _formatAttachmentDuration(Duration duration) {
  final minutes = duration.inMinutes;
  final seconds = duration.inSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

// ── Recording animation widgets ─────────────────────────────────────────────

/// A small red dot that pulses (opacity + scale) on a 900 ms loop.
/// Self-contained — no parent TickerProvider needed.
class _PulsingDot extends StatefulWidget {
  const _PulsingDot({required this.color});

  final Color color;

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _scale = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
    _opacity = Tween<double>(begin: 0.45, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Opacity(
        opacity: _opacity.value,
        child: Transform.scale(
          scale: _scale.value,
          child: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

/// Mic icon wrapped in a pulsing red ring glow — shown while recording.
class _PulsingMicButton extends StatefulWidget {
  const _PulsingMicButton({required this.color});

  final Color color;

  @override
  State<_PulsingMicButton> createState() => _PulsingMicButtonState();
}

class _PulsingMicButtonState extends State<_PulsingMicButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _ring;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _ring = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => Stack(
        alignment: Alignment.center,
        children: [
          // Expanding ring
          Container(
            width: 44 + _ring.value * 16,
            height: 44 + _ring.value * 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withValues(
                alpha: (1.0 - _ring.value) * 0.28,
              ),
            ),
          ),
          child!,
        ],
      ),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
        ),
        child: const Icon(Icons.mic_rounded, color: Colors.white, size: 22),
      ),
    );
  }
}

// ── Chat bubbles ─────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.isMe,
    required this.text,
    required this.timeLabel,
    required this.isRead,
    required this.isDelivered,
    required this.isPinned,
    required this.isHighlighted,
    this.highlightQuery = '',
    this.senderLabel,
    this.onSenderTap,
    this.groupedWithPrev = false,
    this.remoteAttachments = const <ChatAttachment>[],
    this.localAttachments = const <XFile>[],
    this.localAttachmentStatuses,
    this.replyTo,
    this.onReplyTap,
    this.reactionGroups = const <_ReactionGroup>[],
    this.onReactionTap,
    this.footerLabel,
    this.showSelectionMarker = false,
    this.isSelected = false,
    this.onOpenRemoteAttachment,
    this.onOpenLocalAttachment,
  });

  final bool isMe;
  final String text;
  final String timeLabel;
  final bool isRead;
  final bool isDelivered;
  final bool isPinned;
  final bool isHighlighted;
  final String highlightQuery;
  final String? senderLabel;
  final VoidCallback? onSenderTap;
  final bool groupedWithPrev;
  final List<ChatAttachment> remoteAttachments;
  final List<XFile> localAttachments;

  /// Пофайловые статусы загрузки (только исходящий optimistic-баббл;
  /// null у remote-сообщений — оверлеев нет). Индексы соответствуют
  /// [localAttachments].
  final List<ChatAttachmentUploadStatus>? localAttachmentStatuses;
  final ChatReplyReference? replyTo;
  final VoidCallback? onReplyTap;
  final List<_ReactionGroup> reactionGroups;
  final ValueChanged<String>? onReactionTap;
  final String? footerLabel;
  final bool showSelectionMarker;
  final bool isSelected;
  final void Function(
          List<ChatAttachment> attachments, ChatAttachment attachment)?
      onOpenRemoteAttachment;
  final void Function(List<XFile> files, XFile file)? onOpenLocalAttachment;

  /// True when the message is a "naked" video note — single circular
  /// kruzhok and nothing else. In TG / WhatsApp such messages render
  /// as a free-floating circle with no bubble background, time stamp,
  /// or border. Detection: empty text + no reply + a single video-note
  /// attachment on either remote or local side.
  bool get _isVideoNoteOnly {
    if (text.trim().isNotEmpty) return false;
    if (replyTo != null) return false;
    if (remoteAttachments.length == 1 &&
        localAttachments.isEmpty &&
        remoteAttachments.first.isVideoNote) {
      return true;
    }
    if (localAttachments.length == 1 && remoteAttachments.isEmpty) {
      // Detect by file name prefix — same heuristic the host state
      // uses for `_isVideoNoteFile` but inlined here so the bubble
      // doesn't depend on the parent state class.
      final raw = localAttachments.first.name.trim().toLowerCase();
      if (raw.startsWith('video_note_') || raw.startsWith('video-note-')) {
        return true;
      }
    }
    return false;
  }

  /// True when the message is "naked" media — only photos / videos,
  /// no text, no reply, no reactions to display via the meta footer.
  /// User-reported: «у картинок нет границ сообщения. Картинка (и
  /// прочее медиа) без рамок как правило отправляется. Рамки нужны
  /// по факту, чтобы текст читать». Same TG / WA behaviour: pure
  /// media floats on the canvas without a bubble around it.
  bool get _isNakedMediaOnly {
    if (text.trim().isNotEmpty) return false;
    if (replyTo != null) return false;
    final hasNonMediaRemote = remoteAttachments.any((a) =>
        a.type != ChatAttachmentType.image &&
        a.type != ChatAttachmentType.video);
    if (hasNonMediaRemote) return false;
    final hasAnyMedia =
        remoteAttachments.isNotEmpty || localAttachments.isNotEmpty;
    return hasAnyMedia;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    // WhatsApp/Telegram-inspired bubble palette tuned to the warm teal brand.
    final Color bubbleColor;
    final Color onBubbleColor;
    final Color metaColor;
    final List<BoxShadow> bubbleShadow;
    final BoxBorder? bubbleBorder;

    if (isMe) {
      // Outgoing: solid accent gradient — confident, on-brand.
      bubbleColor = scheme.primary;
      onBubbleColor = scheme.onPrimary;
      metaColor = scheme.onPrimary.withValues(alpha: 0.78);
      bubbleShadow = [
        BoxShadow(
          color: scheme.primary.withValues(alpha: isDark ? 0.32 : 0.22),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ];
      bubbleBorder = null;
    } else {
      // Incoming: glassy surface tile with hairline border + soft drop shadow.
      bubbleColor = isDark
          ? scheme.surfaceContainerHigh.withValues(alpha: 0.92)
          : scheme.surface.withValues(alpha: 0.94);
      onBubbleColor = scheme.onSurface;
      metaColor = scheme.onSurfaceVariant;
      bubbleShadow = [
        BoxShadow(
          color: scheme.shadow.withValues(alpha: isDark ? 0.32 : 0.06),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
      ];
      bubbleBorder = Border.all(
        color: scheme.outlineVariant.withValues(alpha: isDark ? 0.4 : 0.55),
        width: 0.7,
      );
    }

    // Telegram-style inline timestamp: for short, plain-text messages the meta
    // (time + read tick) sits in a Wrap next to the text, so it tucks onto the
    // last line (wrapping below only when there's no room). The message text
    // stays a clean Text widget (no embedded WidgetSpan) so search / copy /
    // a11y / find.text are unaffected. Long / reaction / media / reply bubbles
    // keep the footer meta.
    final inlineMeta = text.isNotEmpty &&
        text.trim().length <= 64 &&
        replyTo == null &&
        remoteAttachments.isEmpty &&
        localAttachments.isEmpty &&
        reactionGroups.isEmpty &&
        !_isNakedMediaOnly &&
        !_isVideoNoteOnly;
    final metaRow = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          timeLabel,
          style: theme.textTheme.labelSmall?.copyWith(
            color: metaColor,
            // Плотность (чанк 22): было 12.5 — спека держит время ровно
            // на 12sp (labelSmall/11 мелковат, но 12.5 уже не давало
            // экономии против явного значения из тикета).
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (isMe) ...[
          const SizedBox(width: 4),
          _ReadReceiptTick(
            isRead: isRead,
            isDelivered: isDelivered,
            readColor: const Color(0xFF6FC4FF),
            dimColor: scheme.onPrimary.withValues(alpha: 0.72),
          ),
        ],
      ],
    );

    final highlightBorder = isHighlighted
        ? Border.all(color: scheme.tertiary, width: 1.6)
        : isSelected
            ? Border.all(color: scheme.primary, width: 1.4)
            : bubbleBorder;

    final outgoingGradient = isMe
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary,
              Color.alphaBlend(
                Colors.black.withValues(alpha: 0.08),
                scheme.primary,
              ),
            ],
          )
        : null;

    return Padding(
      // Плотность (чанк 22): зазор между пузырями — спека держит его на
      // 2dp внутри одного автора / 8dp при смене автора. Раньше верх и
      // низ были симметричны и оба зависели ТОЛЬКО от [groupedWithPrev]
      // этого же сообщения — а зазор между двумя пузырями фактически
      // равен bottom(верхнего) + top(нижнего), где bottom верхнего
      // сообщения отражает его СОБСТВЕННУЮ группировку (с сообщением
      // ЕЩЁ выше), а не то, продолжает ли его текущее. На стыке рана
      // (последнее сообщение серии само было «grouped» сверху) это
      // тихо давало короткий зазор вместо разделительного. Фикс: низ —
      // константа (1dp), весь зазор кодирует top ТЕКУЩЕГО сообщения,
      // которое как раз знает, продолжает ли оно автора над собой.
      padding: EdgeInsets.fromLTRB(
        10,
        groupedWithPrev ? 1 : 7,
        10,
        1,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Selection marker slides in/out when selection mode toggles
          // — AnimatedSize collapses the slot to 0-width when hidden so
          // bubbles shift back to flush-left without a jump. Inner
          // ScaleTransition + FadeTransition makes the circle "pop"
          // instead of just appearing.
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.centerLeft,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return ScaleTransition(
                  scale: animation,
                  child: FadeTransition(opacity: animation, child: child),
                );
              },
              child: !showSelectionMarker
                  ? const SizedBox(
                      key: ValueKey('selection-marker-hidden'),
                      width: 0,
                      height: 24,
                    )
                  : Padding(
                      key: const ValueKey('selection-marker-shown'),
                      padding: const EdgeInsets.only(right: 8),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color:
                              isSelected ? scheme.primary : Colors.transparent,
                          border: Border.all(
                            color: isSelected
                                ? scheme.primary
                                : scheme.outline.withValues(alpha: 0.72),
                            width: 2,
                          ),
                        ),
                        child: isSelected
                            ? Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: scheme.onPrimary,
                              )
                            : null,
                      ),
                    ),
            ),
          ),
          Expanded(
            child: Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                // AnimatedContainer so the highlight border (when the
                // user taps a reply preview and we focus the original)
                // fades in / out over 360ms instead of jumping. Picks
                // up boxShadow + decoration changes too — pinned /
                // selected transitions look smoother for free.
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 360),
                  curve: Curves.easeOutCubic,
                  // Плотность (чанк 22): паддинг 8/12 (было 6/11) — спека
                  // держит пузырь на «8 верт / 12 гориз» (Telegram `.msg`),
                  // радиус 16 + 6 на «хвостовом» углу без изменений.
                  //
                  // Special case: a "naked" кружочек skips the bubble
                  // entirely (no padding, no background, no border) and
                  // renders just the round video tile — same TG / WA
                  // behaviour where video notes float on the canvas.
                  // Naked media (photos / videos with no text, no
                  // reply, no other content) drops the bubble like
                  // video notes do — TG / WA convention.
                  padding: (_isVideoNoteOnly || _isNakedMediaOnly)
                      ? EdgeInsets.zero
                      : const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: (_isVideoNoteOnly || _isNakedMediaOnly)
                      ? null
                      : BoxDecoration(
                          color: outgoingGradient == null ? bubbleColor : null,
                          gradient: outgoingGradient,
                          border: highlightBorder,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(16),
                            topRight: const Radius.circular(16),
                            bottomLeft: Radius.circular(isMe ? 16 : 6),
                            bottomRight: Radius.circular(isMe ? 6 : 16),
                          ),
                          boxShadow: bubbleShadow,
                        ),
                  child: Column(
                    crossAxisAlignment: isMe
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      if (senderLabel != null && senderLabel!.isNotEmpty) ...[
                        _ChatSenderLabel(
                          label: senderLabel!,
                          color: isMe
                              ? scheme.onPrimary.withValues(alpha: 0.92)
                              : scheme.primary,
                          onTap: onSenderTap,
                        ),
                        const SizedBox(height: 4),
                      ],
                      if (isPinned) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.push_pin,
                              size: 12,
                              color: metaColor,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Закреплено',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: metaColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      ],
                      if (replyTo != null) ...[
                        _ReplyQuoteCard(
                          reply: replyTo!,
                          isMe: isMe,
                          onTap: onReplyTap,
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (remoteAttachments.isNotEmpty) ...[
                        _buildRemoteAttachments(context),
                        if (!_isNakedMediaOnly && !_isVideoNoteOnly)
                          const SizedBox(height: 8),
                      ],
                      if (localAttachments.isNotEmpty) ...[
                        _buildLocalAttachments(context),
                        if (!_isNakedMediaOnly && !_isVideoNoteOnly)
                          const SizedBox(height: 8),
                      ],
                      if (text.isNotEmpty)
                        inlineMeta
                            ? Wrap(
                                crossAxisAlignment: WrapCrossAlignment.end,
                                spacing: 6,
                                runSpacing: 2,
                                children: [
                                  _HighlightedMessageText(
                                    text: text,
                                    query: highlightQuery,
                                    color: onBubbleColor,
                                  ),
                                  metaRow,
                                ],
                              )
                            : _HighlightedMessageText(
                                text: text,
                                query: highlightQuery,
                                color: onBubbleColor,
                              ),
                      if (text.isEmpty &&
                          remoteAttachments.isEmpty &&
                          localAttachments.isEmpty)
                        Text(
                          'Сообщение',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: onBubbleColor,
                          ),
                        ),
                      if (reactionGroups.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: reactionGroups
                              .map(
                                (reaction) => _ReactionPill(
                                  reaction: reaction,
                                  isMe: isMe,
                                  onTap: onReactionTap == null
                                      ? null
                                      : () => onReactionTap!(reaction.emoji),
                                ),
                              )
                              .toList(),
                        ),
                      ],
                      // Footer meta (timestamp + read tick) — only when it was
                      // NOT inlined next to the text above (see inlineMeta).
                      // Naked media skips it entirely (floats as just media);
                      // footerLabel shows below regardless of inline vs footer.
                      if (!inlineMeta &&
                          !_isNakedMediaOnly &&
                          !_isVideoNoteOnly) ...[
                        const SizedBox(height: 2),
                        metaRow,
                      ],
                      if (footerLabel != null &&
                          footerLabel!.isNotEmpty &&
                          !_isNakedMediaOnly &&
                          !_isVideoNoteOnly) ...[
                        const SizedBox(height: 2),
                        Text(
                          footerLabel!,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: metaColor,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRemoteAttachments(BuildContext context) {
    final audio = remoteAttachments
        .where((a) => a.type == ChatAttachmentType.audio)
        .toList();
    final videoNotes = remoteAttachments.where((a) => a.isVideoNote).toList();
    final visuals = remoteAttachments
        .where((a) => a.type != ChatAttachmentType.audio && !a.isVideoNote)
        .toList();

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (audio.isNotEmpty)
          ...audio.map(
            (attachment) => _VoicePlayerWidget(
              url: attachment.url,
              isMe: isMe,
              initialDuration: attachment.durationMs == null
                  ? null
                  : Duration(milliseconds: attachment.durationMs!),
              waveform: attachment.waveform,
              semanticLabel: attachment.isVoiceNote
                  ? 'Голосовое сообщение'
                  : 'Аудиовложение',
            ),
          ),
        if (videoNotes.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: videoNotes
                .map(
                  (attachment) => _VideoNoteTile(
                    previewUrl: attachment.thumbnailUrl,
                    durationLabel: attachment.durationMs == null
                        ? null
                        : _formatAttachmentDuration(
                            Duration(milliseconds: attachment.durationMs!),
                          ),
                    label: 'Кружок',
                    videoSource: attachment.url,
                    isRemoteSource: true,
                    onTap: onOpenRemoteAttachment == null
                        ? null
                        : () => onOpenRemoteAttachment!(
                            remoteAttachments, attachment),
                  ),
                )
                .toList(),
          ),
          if (visuals.isNotEmpty) const SizedBox(height: 8),
        ],
        if (visuals.isNotEmpty)
          _RemoteMediaGrid(
            attachments: visuals,
            onOpenAttachment: onOpenRemoteAttachment,
          ),
      ],
    );
  }

  Widget _buildLocalAttachments(BuildContext context) {
    // Пары (файл, статус) собираем ДО фильтраций — сплиты по типам
    // теряют исходные индексы, а статусы идут по порядку attachments.
    final statuses = localAttachmentStatuses;
    final audio = localAttachments
        .where((f) => _attachmentKindFromXFile(f) == _ChatAttachmentKind.audio)
        .toList();
    final videoNotes = localAttachments
        .where((file) => _isVideoNoteFileName(file.name))
        .toList();
    final visuals = <XFile>[];
    final visualStatuses = <ChatAttachmentUploadStatus>[];
    for (var i = 0; i < localAttachments.length; i++) {
      final file = localAttachments[i];
      if (_attachmentKindFromXFile(file) != _ChatAttachmentKind.audio &&
          !_isVideoNoteFileName(file.name)) {
        visuals.add(file);
        if (statuses != null && i < statuses.length) {
          visualStatuses.add(statuses[i]);
        }
      }
    }

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (audio.isNotEmpty)
          ...audio.map(
            (file) => _VoicePlayerWidget(
              path: file.path,
              isMe: isMe,
              initialDuration: _durationFromAttachmentName(file.name),
              semanticLabel: _isVoiceNoteFileName(file.name)
                  ? 'Голосовое сообщение'
                  : 'Аудиовложение',
            ),
          ),
        if (videoNotes.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: videoNotes
                .map(
                  (file) => _VideoNoteTile(
                    durationLabel:
                        _durationFromAttachmentName(file.name) == null
                            ? null
                            : _formatAttachmentDuration(
                                _durationFromAttachmentName(file.name)!,
                              ),
                    label: 'Кружок',
                    videoSource: file.path,
                    isRemoteSource: false,
                    onTap: onOpenLocalAttachment == null
                        ? null
                        : () => onOpenLocalAttachment!(localAttachments, file),
                  ),
                )
                .toList(),
          ),
          if (visuals.isNotEmpty) const SizedBox(height: 8),
        ],
        if (visuals.isNotEmpty)
          _LocalMediaGrid(
            files: visuals,
            statuses:
                visualStatuses.length == visuals.length ? visualStatuses : null,
            onOpenAttachment: onOpenLocalAttachment,
          ),
      ],
    );
  }
}

class _ChatSenderLabel extends StatelessWidget {
  const _ChatSenderLabel({
    required this.label,
    required this.color,
    this.onTap,
  });

  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelMedium?.copyWith(
        color: color,
        fontWeight: FontWeight.w800,
      ),
    );
    if (onTap == null) {
      return text;
    }

    return Tooltip(
      message: 'Написать в личку',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: text),
                const SizedBox(width: 4),
                Icon(
                  Icons.chat_bubble_outline_rounded,
                  size: 12,
                  color: color.withValues(alpha: 0.86),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReplyQuoteCard extends StatelessWidget {
  const _ReplyQuoteCard({
    required this.reply,
    required this.isMe,
    this.onTap,
  });

  final ChatReplyReference reply;
  final bool isMe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final titleColor = isMe ? scheme.onPrimary : scheme.primary;
    final bodyColor = isMe
        ? scheme.onPrimary.withValues(alpha: 0.84)
        : scheme.onSurfaceVariant;
    final accentColor = isMe ? scheme.onPrimary : scheme.primary;
    final borderRadius = BorderRadius.circular(12);
    final maxPreviewWidth = math.min(
      360.0,
      math.max(220.0, MediaQuery.sizeOf(context).width * 0.58),
    );
    final maxTextWidth = math.max(140.0, maxPreviewWidth - 34);

    final content = Container(
      key: const ValueKey<String>('chat-reply-quote-card'),
      constraints: BoxConstraints(maxWidth: maxPreviewWidth),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.white.withValues(alpha: 0.16)
            : scheme.primary.withValues(alpha: 0.08),
        borderRadius: borderRadius,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxTextWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  reply.senderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reply.text.trim().isNotEmpty
                      ? reply.text
                      : 'Сообщение без текста',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: bodyColor,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (onTap == null) {
      return content;
    }

    return Semantics(
      button: true,
      label: 'Перейти к исходному сообщению',
      child: InkWell(
        onTap: onTap,
        borderRadius: borderRadius,
        child: content,
      ),
    );
  }
}

class _ForwardDraft {
  const _ForwardDraft({
    required this.senderName,
    required this.text,
    required this.attachments,
  });

  final String senderName;
  final String text;
  final List<ChatAttachment> attachments;
}

class _EditDraft {
  const _EditDraft({
    required this.messageId,
    required this.originalText,
    required this.hasAttachments,
  });

  final String messageId;
  final String originalText;
  final bool hasAttachments;
}

enum _ChatAttachmentKind { image, video, audio, other }

_ChatAttachmentKind _chatAttachmentKindFromType(ChatAttachmentType type) {
  switch (type) {
    case ChatAttachmentType.image:
      return _ChatAttachmentKind.image;
    case ChatAttachmentType.video:
      return _ChatAttachmentKind.video;
    case ChatAttachmentType.audio:
      return _ChatAttachmentKind.audio;
    case ChatAttachmentType.file:
      return _ChatAttachmentKind.other;
  }
}

_ChatAttachmentKind _attachmentKindFromAttachment(ChatAttachment attachment) {
  if (attachment.type == ChatAttachmentType.file) {
    return _attachmentKindFromName(attachment.fileName, attachment.url);
  }
  return _chatAttachmentKindFromType(attachment.type);
}

_ChatAttachmentKind _attachmentKindFromXFile(XFile file) {
  final mimeType = file.mimeType?.toLowerCase().trim();
  if (mimeType != null && mimeType.isNotEmpty) {
    if (mimeType.startsWith('image/')) {
      return _ChatAttachmentKind.image;
    }
    if (mimeType.startsWith('video/')) {
      return _ChatAttachmentKind.video;
    }
    if (mimeType.startsWith('audio/')) {
      return _ChatAttachmentKind.audio;
    }
  }

  return _attachmentKindFromName(file.name, file.path);
}

_ChatAttachmentKind _attachmentKindFromName(
  String? preferredName,
  String? fallbackPath,
) {
  final fileName = (preferredName?.trim().isNotEmpty ?? false)
      ? preferredName!.trim()
      : (fallbackPath ?? '');
  final extension = path.extension(fileName).toLowerCase();
  const imageExtensions = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.gif',
    '.bmp',
    '.heic',
    '.heif',
  };
  if (imageExtensions.contains(extension)) {
    return _ChatAttachmentKind.image;
  }

  const videoExtensions = <String>{
    '.mp4',
    '.mov',
    '.webm',
    '.m4v',
    '.avi',
    '.mkv',
    '.3gp',
  };
  if (videoExtensions.contains(extension)) {
    return _ChatAttachmentKind.video;
  }

  const audioExtensions = <String>{
    '.mp3',
    '.m4a',
    '.wav',
    '.ogg',
    '.aac',
  };
  if (audioExtensions.contains(extension)) {
    return _ChatAttachmentKind.audio;
  }

  return _ChatAttachmentKind.other;
}

String _displayName(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Файл';
  }
  final normalized = value.split('/').last.split('?').first;
  return normalized.length > 24
      ? '${normalized.substring(0, 21)}...'
      : normalized;
}

class _GroupCallParticipantPicker extends StatefulWidget {
  const _GroupCallParticipantPicker({
    required this.mediaMode,
    required this.participants,
  });

  final CallMediaMode mediaMode;
  final List<ChatParticipantSummary> participants;

  @override
  State<_GroupCallParticipantPicker> createState() =>
      _GroupCallParticipantPickerState();
}

class _GroupCallParticipantPickerState
    extends State<_GroupCallParticipantPicker> {
  final Set<String> _selectedIds = <String>{};

  bool get _isVideo => widget.mediaMode.isVideo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final selectedCount = _selectedIds.length;
    final canStart = selectedCount > 0;
    final actionLabel = selectedCount == 1
        ? 'Позвонить 1 участнику'
        : 'Позвонить выбранным ($selectedCount)';

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: size.height * 0.86),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            18,
            8,
            18,
            18 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _isVideo ? Icons.videocam_outlined : Icons.call_outlined,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Кого позвать?',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _isVideo
                              ? 'Видеозвонок пойдёт только выбранным.'
                              : 'Аудиозвонок пойдёт только выбранным.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _selectedIds
                          ..clear()
                          ..addAll(widget.participants.map((p) => p.userId));
                      });
                    },
                    icon: const Icon(Icons.done_all_rounded, size: 18),
                    label: const Text('Все'),
                  ),
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: _selectedIds.isEmpty
                        ? null
                        : () => setState(_selectedIds.clear),
                    child: const Text('Сбросить'),
                  ),
                  const Spacer(),
                  Text(
                    selectedCount == 0
                        ? 'Никто не выбран'
                        : 'Выбрано: $selectedCount',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: widget.participants.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final participant = widget.participants[index];
                    final selected = _selectedIds.contains(participant.userId);
                    final avatarImage =
                        buildAvatarImageProvider(participant.photoUrl);
                    final initial = participant.displayName.trim().isNotEmpty
                        ? participant.displayName.trim()[0].toUpperCase()
                        : '?';
                    return CheckboxListTile(
                      value: selected,
                      onChanged: (_) => setState(() {
                        if (selected) {
                          _selectedIds.remove(participant.userId);
                        } else {
                          _selectedIds.add(participant.userId);
                        }
                      }),
                      controlAffinity: ListTileControlAffinity.trailing,
                      secondary: CircleAvatar(
                        backgroundImage: avatarImage,
                        child: avatarImage == null ? Text(initial) : null,
                      ),
                      title: Text(
                        participant.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        participant.isOnline ? 'в сети' : 'участник чата',
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Отмена'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton.icon(
                      onPressed: canStart
                          ? () => Navigator.of(context).pop(
                                _selectedIds.toList(growable: false),
                              )
                          : null,
                      icon: Icon(
                        _isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                      ),
                      label: Text(actionLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallSummaryPalette {
  const _CallSummaryPalette({
    required this.background,
    required this.border,
    required this.iconBackground,
    required this.iconColor,
    required this.titleColor,
    required this.subtitleColor,
  });

  final Color background;
  final Color border;
  final Color iconBackground;
  final Color iconColor;
  final Color titleColor;
  final Color subtitleColor;
}

/// Flat surface-pill icon button used in the composer for attach + secondary
/// actions. Mirrors the reference `.iconbtn` style (38x38, surface bg, hairline
/// border, ink color icon). Lighter visual weight than IconButton.filledTonal.
class _ComposerIconButton extends StatelessWidget {
  const _ComposerIconButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isEnabled = onPressed != null;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Container(
            // M3 (50+): 44dp тач-таргет; без фона и рамки — плоская иконка
            // внутри капсулы композера.
            width: 44,
            height: 44,
            alignment: Alignment.center,
            child: Icon(
              icon,
              size: 22,
              color: isEnabled
                  ? scheme.onSurface.withValues(alpha: 0.78)
                  : scheme.onSurface.withValues(alpha: 0.32),
            ),
          ),
        ),
      ),
    );
  }
}

/// Accent-filled circle for the composer send action. Reference
/// `.composer .send`: 42x42 round, accent gradient, drop shadow that
/// reads as "the primary action lives here".
class _ComposerSendButton extends StatelessWidget {
  const _ComposerSendButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Container(
            // M3 (50+): 48dp вместо 42 — send-кнопка по гайдлайну, как
            // mic-кнопка рядом.
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  scheme.primary,
                  Color.alphaBlend(
                    Colors.black.withValues(alpha: 0.10),
                    scheme.primary,
                  ),
                ],
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.40),
                  blurRadius: 14,
                  spreadRadius: -4,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 21, color: scheme.onPrimary),
          ),
        ),
      ),
    );
  }
}
