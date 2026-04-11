// ignore_for_file: unused_field
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as path;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../backend/interfaces/chat_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../models/chat_attachment.dart';
import '../models/chat_details.dart';
import '../models/chat_message.dart';
import '../models/chat_send_progress.dart';
import '../models/family_tree.dart';
import '../providers/tree_provider.dart';
import '../services/chat_auto_delete_store.dart';
import '../services/chat_draft_store.dart';
import '../services/chat_notification_settings_store.dart';
import '../services/chat_pin_store.dart';
import '../services/chat_reaction_store.dart';
import '../services/custom_api_realtime_service.dart';
import '../utils/chat_attachment_download.dart';

enum _OutgoingMessageStatus { pending, sent, failed }

class _OutgoingStatusMeta {
  const _OutgoingStatusMeta({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color? color;
}

class _OutgoingMessage {
  const _OutgoingMessage({
    required this.localId,
    required this.senderId,
    required this.text,
    required this.timestamp,
    required this.attachments,
    required this.forwardedAttachments,
    required this.status,
    this.replyTo,
    this.progress,
    this.errorText,
  });

  final String localId;
  final String senderId;
  final String text;
  final DateTime timestamp;
  final List<XFile> attachments;
  final List<ChatAttachment> forwardedAttachments;
  final _OutgoingMessageStatus status;
  final ChatReplyReference? replyTo;
  final ChatSendProgress? progress;
  final String? errorText;

  _OutgoingMessage copyWith({
    _OutgoingMessageStatus? status,
    ChatSendProgress? progress,
    String? errorText,
  }) {
    return _OutgoingMessage(
      localId: localId,
      senderId: senderId,
      text: text,
      timestamp: timestamp,
      attachments: attachments,
      forwardedAttachments: forwardedAttachments,
      status: status ?? this.status,
      replyTo: replyTo,
      progress: progress ?? this.progress,
      errorText: errorText,
    );
  }
}

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
    this.reactionStore,
    this.autoDeleteStore,
    this.initialChatDetails,
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
  final Future<List<XFile>> Function()? pickImages;
  final Future<XFile?> Function()? pickVideo;
  final ChatDraftStore? draftStore;
  final ChatPinStore? pinStore;
  final ChatNotificationSettingsStore? notificationSettingsStore;
  final ChatReactionStore? reactionStore;
  final ChatAutoDeleteStore? autoDeleteStore;
  final ChatDetails? initialChatDetails;

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

  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
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
  int _localMessageCounter = 0;
  late String _resolvedTitle;
  final List<XFile> _selectedAttachments = <XFile>[];
  final List<_OutgoingMessage> _optimisticMessages = <_OutgoingMessage>[];
  Timer? _draftSaveTimer;
  bool _isApplyingDraft = false;
  String? _lastPersistedDraftKey;
  final ScrollController _messagesScrollController = ScrollController();
  final GlobalKey _unreadDividerKey = GlobalKey();
  bool _showJumpToLatestButton = false;
  bool _didInitialUnreadJump = false;
  String? _unreadAnchorMessageId;
  ChatReplyReference? _selectedReply;
  _ForwardDraft? _selectedForward;
  _ForwardBatchDraft? _selectedForwardBatch;
  _EditDraft? _selectedEdit;
  bool _isSearchMode = false;
  final Set<String> _selectedRemoteMessageIds = <String>{};
  final Set<String> _selectedOutgoingMessageIds = <String>{};
  bool _browserContextMenuWasEnabled = false;

  // Voice recording state
  bool _isRecording = false;
  final AudioRecorder _recorder = AudioRecorder();
  Timer? _recordingTimer;
  int _recordingDurationSeconds = 0;
  int _lastRecordedDurationSeconds = 0;
  String? _lastRecordedPath;
  ChatDraftStore get _draftStore =>
      widget.draftStore ?? const SharedPreferencesChatDraftStore();
  ChatNotificationSettingsStore get _notificationSettingsStore =>
      widget.notificationSettingsStore ??
      const SharedPreferencesChatNotificationSettingsStore();
  ChatPinStore get _pinStore =>
      widget.pinStore ?? const SharedPreferencesChatPinStore();
  ChatReactionStore get _reactionStore =>
      widget.reactionStore ?? const SharedPreferencesChatReactionStore();
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
  Map<String, List<ChatMessageReactionEntry>> _messageReactions =
      <String, List<ChatMessageReactionEntry>>{};
  String? _lastPersistedReactionKey;
  List<ChatMessage> _latestRemoteMessages = const <ChatMessage>[];
  final Map<String, GlobalKey> _remoteMessageKeys = <String, GlobalKey>{};
  Timer? _pinnedMessageHighlightTimer;
  String? _highlightedPinnedMessageId;
  StreamSubscription<CustomApiRealtimeEvent>? _realtimeIndicatorsSubscription;
  Timer? _typingHeartbeatTimer;
  Timer? _typingDecayTimer;
  bool _typingHeartbeatActive = false;
  final Map<String, DateTime> _typingUsers = <String, DateTime>{};
  final Set<String> _onlineUserIds = <String>{};

  @override
  void initState() {
    super.initState();
    _chatDetails = widget.initialChatDetails;
    _resolvedTitle = widget.initialChatDetails?.displayTitle ?? widget.title;
    _messageController.addListener(_handleDraftChanged);
    _searchController.addListener(_handleSearchChanged);
    _messagesScrollController.addListener(_handleMessagesScroll);
    _configureBrowserContextMenu();
    _bootstrapChat();
  }

  @override
  void dispose() {
    _draftSaveTimer?.cancel();
    _pinnedMessageHighlightTimer?.cancel();
    _messageController.removeListener(_handleDraftChanged);
    _searchController.removeListener(_handleSearchChanged);
    _messagesScrollController.removeListener(_handleMessagesScroll);
    _messagesScrollController.dispose();
    _messageController.dispose();
    _searchController.dispose();
    _recordingTimer?.cancel();
    _typingHeartbeatTimer?.cancel();
    _typingDecayTimer?.cancel();
    unawaited(_setTypingActive(false, force: true));
    final realtimeSubscription = _realtimeIndicatorsSubscription;
    _realtimeIndicatorsSubscription = null;
    if (realtimeSubscription != null) {
      unawaited(realtimeSubscription.cancel());
    }
    _restoreBrowserContextMenu();
    _recorder.dispose();
    super.dispose();
  }

  bool get _isSelectionMode =>
      _selectedRemoteMessageIds.isNotEmpty ||
      _selectedOutgoingMessageIds.isNotEmpty;

  int get _selectedMessageCount =>
      _selectedRemoteMessageIds.length + _selectedOutgoingMessageIds.length;

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

  void _exitSelectionMode() {
    if (!_isSelectionMode) {
      return;
    }
    setState(() {
      _selectedRemoteMessageIds.clear();
      _selectedOutgoingMessageIds.clear();
    });
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
      _selectedRemoteMessageIds.add(message.id);
    });
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
      _selectedOutgoingMessageIds.add(message.localId);
    });
  }

  void _toggleRemoteMessageSelection(ChatMessage message) {
    setState(() {
      if (_selectedRemoteMessageIds.contains(message.id)) {
        _selectedRemoteMessageIds.remove(message.id);
      } else {
        _selectedRemoteMessageIds.add(message.id);
      }
    });
  }

  void _toggleOutgoingMessageSelection(_OutgoingMessage message) {
    setState(() {
      if (_selectedOutgoingMessageIds.contains(message.localId)) {
        _selectedOutgoingMessageIds.remove(message.localId);
      } else {
        _selectedOutgoingMessageIds.add(message.localId);
      }
    });
  }

  List<_SelectedMessageEntry> _selectedMessagesSnapshot() {
    final selectedMessages = <_SelectedMessageEntry>[
      ..._latestRemoteMessages
          .where((message) => _selectedRemoteMessageIds.contains(message.id))
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
              _selectedOutgoingMessageIds.contains(message.localId))
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
      return '[${formatter.format(message.timestamp)}] ${message.displayName}: $body';
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          selectedMessages.length == 1
              ? 'Сообщение скопировано'
              : 'Скопировано ${selectedMessages.length} сообщений',
        ),
      ),
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
      _selectedRemoteMessageIds.clear();
      _selectedOutgoingMessageIds.clear();
    });
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Пока можно удалять только свои сообщения и локальную очередь.'),
        ),
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
    setState(() {
      if (outgoingIdsToRemove.isNotEmpty) {
        _optimisticMessages.removeWhere(
          (message) => outgoingIdsToRemove.contains(message.localId),
        );
      }
      _selectedRemoteMessageIds.clear();
      _selectedOutgoingMessageIds.clear();
    });
  }

  Future<void> _bootstrapChat() async {
    setState(() {
      _isBootstrapping = true;
      _bootstrapError = null;
      _didInitialUnreadJump = false;
      _unreadAnchorMessageId = null;
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

      await _restoreReactionsIfNeeded();
      await _restorePinnedMessageIfNeeded();
      await _restoreDraftIfNeeded();
      unawaited(_restoreNotificationSettingsIfNeeded());
      unawaited(_restoreAutoDeleteSettingsIfNeeded());
      _bindRealtimeIndicators();
      unawaited(_loadChatDetails());
      await _markChatAsRead();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _bootstrapError =
            'Не удалось открыть чат. Проверьте соединение и попробуйте снова.';
        _isBootstrapping = false;
      });
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

    try {
      final details = await _chatService.getChatDetails(chatId);
      if (!mounted) {
        return;
      }

      setState(() {
        _chatDetails = details;
        _resolvedTitle = widget.isGroup ? details.displayTitle : _resolvedTitle;
        _isLoadingChatDetails = false;
      });
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
    } catch (_) {
      // Не блокируем UI, если mark-as-read временно не сработал.
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
      setState(() {
        _selectedAttachments.clear();
      });
    }
    if (_selectedAttachments.length >= _maxAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Можно прикрепить не более 6 вложений.'),
        ),
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

      setState(() {
        final hadHeavyMedia = _selectedAttachments.any((f) {
          final kind = _attachmentKindFromXFile(f);
          return kind == _ChatAttachmentKind.video ||
              kind == _ChatAttachmentKind.audio;
        });
        if (hadHeavyMedia) {
          _selectedAttachments.clear();
        }

        final remaining = 6 - _selectedAttachments.length;
        if (picked.length > remaining) {
          _selectedAttachments.addAll(picked.take(remaining));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Можно добавить не более 6 фото.')),
          );
        } else {
          _selectedAttachments.addAll(picked);
        }
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать фотографии.')),
      );
    }
  }

  Future<void> _pickVideoAttachment() async {
    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }
    if (_selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    )) {
      setState(() {
        _selectedAttachments.clear();
      });
    }
    try {
      final picked = widget.pickVideo != null
          ? await widget.pickVideo!()
          : await _imagePicker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(minutes: 10),
            );
      if (picked == null || !mounted) {
        return;
      }

      final size = await picked.length();
      if (size > 50 * 1024 * 1024) {
        // 50MB limit
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Видео слишком большое (макс. 50 МБ).')),
          );
        }
        return;
      }

      setState(() {
        _selectedAttachments.clear();
        _selectedAttachments.add(picked);
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать видео.')),
      );
    }
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
      setState(() {
        _selectedAttachments.clear();
      });
    }
    try {
      final result = await FilePicker.platform.pickFiles(
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

      setState(() {
        final remaining = _maxAttachments - _selectedAttachments.length;
        if (pickedFiles.length > remaining) {
          _selectedAttachments.addAll(pickedFiles.take(remaining));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Можно добавить не более 6 файлов.')),
          );
        } else {
          _selectedAttachments.addAll(pickedFiles);
        }
      });
    } catch (e) {
      debugPrint('Error picking file: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось выбрать файл.')),
        );
      }
    }
  }

  Future<void> _openAttachmentPicker() async {
    final choice = await showModalBottomSheet<_AttachmentPickerChoice>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Фото'),
              subtitle:
                  const Text('Сожмём перед отправкой, чтобы быстрее дошло'),
              onTap: () => Navigator.of(context).pop(
                _AttachmentPickerChoice.images,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.videocam_outlined),
              title: const Text('Видео'),
              subtitle: const Text('Добавится как вложение в чат'),
              onTap: () => Navigator.of(context).pop(
                _AttachmentPickerChoice.video,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('Файл'),
              subtitle: const Text('Документы, архивы и другие файлы'),
              onTap: () => Navigator.of(context).pop(
                _AttachmentPickerChoice.file,
              ),
            ),
          ],
        ),
      ),
    );

    if (!mounted || choice == null) {
      return;
    }

    if (choice == _AttachmentPickerChoice.images) {
      await _pickImageAttachments();
      return;
    }

    if (choice == _AttachmentPickerChoice.video) {
      await _pickVideoAttachment();
      return;
    }

    await _pickGenericFile();
  }

  Future<void> _startRecording() async {
    if (_selectedEdit != null) {
      setState(() {
        _selectedEdit = null;
      });
    }
    if (_selectedAttachments.any(
      (file) => _attachmentKindFromXFile(file) == _ChatAttachmentKind.audio,
    )) {
      setState(() {
        _selectedAttachments.clear();
      });
    }
    try {
      if (await _recorder.hasPermission()) {
        final directory = await getTemporaryDirectory();
        final path =
            '${directory.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

        await _recorder.start(const RecordConfig(), path: path);

        setState(() {
          _isRecording = true;
          _recordingDurationSeconds = 0;
          _lastRecordedPath = path;
        });

        _recordingTimer?.cancel();
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() {
            _recordingDurationSeconds++;
          });
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Нужен доступ к микрофону.')),
          );
        }
      }
    } catch (e) {
      debugPrint('Error starting recording: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось начать запись.')),
        );
      }
    }
  }

  Future<void> _stopAndSendRecording() async {
    _recordingTimer?.cancel();
    final path = await _recorder.stop();
    final durationSeconds = _recordingDurationSeconds;
    if (!mounted) {
      return;
    }
    setState(() {
      _isRecording = false;
      _recordingDurationSeconds = 0;
      _lastRecordedDurationSeconds = durationSeconds;
      _lastRecordedPath = path;
    });

    if (path != null && durationSeconds > 0) {
      final voiceFile = XFile(path, mimeType: 'audio/m4a');
      setState(() {
        _selectedAttachments
          ..clear()
          ..add(voiceFile);
      });
    }
  }

  Future<void> _cancelRecording() async {
    _recordingTimer?.cancel();
    await _recorder.stop();
    setState(() {
      _isRecording = false;
      _recordingDurationSeconds = 0;
      _lastRecordedDurationSeconds = 0;
      _lastRecordedPath = null;
    });
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
    setState(() {
      _selectedAttachments.remove(voiceAttachment);
      _lastRecordedDurationSeconds = 0;
      _lastRecordedPath = null;
    });
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
    if (currentUserId == null || currentUserId.isEmpty) {
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
    final localMessageId = 'local-${_localMessageCounter++}';
    if (messageText.isEmpty &&
        attachments.isEmpty &&
        forwardedAttachments.isEmpty) {
      return;
    }

    _messageController.clear();
    await _setTypingActive(false, force: true);
    await _clearActiveDraft();
    setState(() {
      _selectedAttachments.clear();
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForward = null;
      _lastRecordedDurationSeconds = 0;
      _lastRecordedPath = null;
      _optimisticMessages.insert(
        0,
        _OutgoingMessage(
          localId: localMessageId,
          senderId: currentUserId,
          text: messageText,
          timestamp: DateTime.now(),
          attachments: attachments,
          forwardedAttachments: forwardedAttachments,
          status: _OutgoingMessageStatus.pending,
          replyTo: replyTo,
          progress: attachments.isNotEmpty
              ? const ChatSendProgress(
                  stage: ChatSendProgressStage.preparing,
                  completed: 0,
                  total: 1,
                )
              : const ChatSendProgress(
                  stage: ChatSendProgressStage.sending,
                  completed: 1,
                  total: 1,
                ),
        ),
      );
    });

    final pendingMessage = _optimisticMessages.first;
    await _sendOptimisticMessage(pendingMessage);
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
    _messageController.clear();
    await _setTypingActive(false, force: true);
    await _clearActiveDraft();
    setState(() {
      _selectedAttachments.clear();
      _selectedEdit = null;
      _selectedReply = null;
      _selectedForward = null;
      _selectedForwardBatch = null;
      _lastRecordedDurationSeconds = 0;
      _lastRecordedPath = null;
    });

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
    final localMessageId = 'local-${_localMessageCounter++}';
    final pendingMessage = _OutgoingMessage(
      localId: localMessageId,
      senderId: senderId,
      text: text,
      timestamp: DateTime.now(),
      attachments: attachments,
      forwardedAttachments: forwardedAttachments,
      status: _OutgoingMessageStatus.pending,
      replyTo: replyTo,
      progress: attachments.isNotEmpty
          ? ChatSendProgress(
              stage: ChatSendProgressStage.preparing,
              completed: 0,
              total: attachments.length,
            )
          : const ChatSendProgress(
              stage: ChatSendProgressStage.sending,
              completed: 1,
              total: 1,
            ),
    );

    if (!mounted) {
      return;
    }
    setState(() {
      _optimisticMessages.insert(0, pendingMessage);
    });
    await _sendOptimisticMessage(pendingMessage);
  }

  Future<void> _saveEditedMessage() async {
    final edit = _selectedEdit;
    final chatId = _chatId;
    if (edit == null || chatId == null || chatId.isEmpty) {
      return;
    }

    final nextText = _messageController.text.trim();
    if (nextText.isEmpty && !edit.hasAttachments) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сообщение не должно быть пустым.')),
      );
      return;
    }

    try {
      await _setTypingActive(false, force: true);
      await _chatService.editChatMessage(
        chatId: chatId,
        messageId: edit.messageId,
        text: nextText,
      );
      _messageController.clear();
      await _clearActiveDraft();
      if (!mounted) {
        return;
      }
      setState(() {
        _selectedAttachments.clear();
        _selectedEdit = null;
        _lastRecordedDurationSeconds = 0;
        _lastRecordedPath = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить изменения.')),
      );
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

    ChatDraftSnapshot? bestDraft;
    String? bestDraftKey;
    for (final key in keys) {
      final snapshot = await _draftStore.getDraft(key);
      if (snapshot == null) {
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
    _draftSaveTimer?.cancel();
    _draftSaveTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistCurrentDraft());
    });
  }

  Future<void> _persistCurrentDraft() async {
    final draftKey = _primaryDraftKey();
    if (draftKey == null) {
      return;
    }

    final text = _messageController.text;
    if (text.trim().isEmpty) {
      await _draftStore.clearDraft(draftKey);
    } else {
      await _draftStore.saveDraft(draftKey, text);
    }

    final previousKey = _lastPersistedDraftKey;
    _lastPersistedDraftKey = draftKey;
    if (previousKey != null && previousKey != draftKey) {
      await _draftStore.clearDraft(previousKey);
    }
  }

  Future<void> _clearActiveDraft() async {
    final keys = _draftCandidateKeys();
    for (final key in keys) {
      await _draftStore.clearDraft(key);
    }
    _lastPersistedDraftKey = _primaryDraftKey();
  }

  List<String> _reactionCandidateKeys() {
    final keys = <String>[];
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatReactionStore.chatKey(resolvedChatId));
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      keys.add(SharedPreferencesChatReactionStore.chatKey(widgetChatId));
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      keys.add(SharedPreferencesChatReactionStore.directUserKey(otherUserId));
    }
    return keys.toSet().toList();
  }

  String? _primaryReactionKey() {
    final resolvedChatId = _chatId;
    if (resolvedChatId != null && resolvedChatId.isNotEmpty) {
      return SharedPreferencesChatReactionStore.chatKey(resolvedChatId);
    }
    final widgetChatId = widget.chatId;
    if (widgetChatId != null && widgetChatId.isNotEmpty) {
      return SharedPreferencesChatReactionStore.chatKey(widgetChatId);
    }
    final otherUserId = widget.otherUserId;
    if (otherUserId != null && otherUserId.isNotEmpty) {
      return SharedPreferencesChatReactionStore.directUserKey(otherUserId);
    }
    return null;
  }

  Future<void> _restoreReactionsIfNeeded() async {
    final keys = _reactionCandidateKeys();
    if (keys.isEmpty) {
      return;
    }

    ChatReactionCatalogSnapshot? bestSnapshot;
    String? bestKey;
    for (final key in keys) {
      final snapshot = await _reactionStore.getCatalog(key);
      if (snapshot == null) {
        continue;
      }
      if (bestSnapshot == null ||
          snapshot.updatedAt.isAfter(bestSnapshot.updatedAt)) {
        bestSnapshot = snapshot;
        bestKey = key;
      }
    }

    final preferredKey = _primaryReactionKey();
    if (!mounted) {
      return;
    }
    setState(() {
      _messageReactions = bestSnapshot?.reactionsByMessage.map(
            (messageId, entries) => MapEntry(
              messageId,
              List<ChatMessageReactionEntry>.from(entries),
            ),
          ) ??
          <String, List<ChatMessageReactionEntry>>{};
    });

    _lastPersistedReactionKey = preferredKey ?? bestKey;
    if (bestSnapshot != null &&
        preferredKey != null &&
        bestKey != null &&
        preferredKey != bestKey) {
      await _reactionStore.saveCatalog(preferredKey, bestSnapshot);
      await _reactionStore.clearCatalog(bestKey);
    }
  }

  Future<void> _persistReactions() async {
    final reactionKey = _primaryReactionKey();
    if (reactionKey == null) {
      return;
    }

    final cleaned = _messageReactions.map(
      (messageId, entries) => MapEntry(
        messageId,
        entries
            .where(
              (entry) =>
                  entry.messageId.trim().isNotEmpty &&
                  entry.userId.trim().isNotEmpty &&
                  entry.emoji.trim().isNotEmpty,
            )
            .toList(),
      ),
    )..removeWhere((_, entries) => entries.isEmpty);

    final previousKey = _lastPersistedReactionKey;
    _lastPersistedReactionKey = reactionKey;

    if (cleaned.isEmpty) {
      await _reactionStore.clearCatalog(reactionKey);
    } else {
      await _reactionStore.saveCatalog(
        reactionKey,
        ChatReactionCatalogSnapshot(
          updatedAt: DateTime.now(),
          reactionsByMessage: cleaned,
        ),
      );
    }

    if (previousKey != null && previousKey != reactionKey) {
      await _reactionStore.clearCatalog(previousKey);
    }
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _currentReactionEmoji(String messageId) {
    final currentUserId = _currentUserId;
    if (currentUserId == null || currentUserId.isEmpty) {
      return '';
    }
    final entries = _messageReactions[messageId] ?? const [];
    final currentReaction =
        entries.cast<ChatMessageReactionEntry?>().firstWhere(
              (entry) => entry?.userId == currentUserId,
              orElse: () => null,
            );
    return currentReaction?.emoji ?? '';
  }

  List<_ReactionGroup> _reactionGroupsForMessage(String messageId) {
    final entries = _messageReactions[messageId] ?? const [];
    if (entries.isEmpty) {
      return const <_ReactionGroup>[];
    }

    final currentUserId = _currentUserId;
    final grouped = <String, _ReactionGroup>{};
    for (final entry in entries) {
      final existing = grouped[entry.emoji];
      if (existing == null) {
        grouped[entry.emoji] = _ReactionGroup(
          emoji: entry.emoji,
          count: 1,
          isMine: currentUserId != null && entry.userId == currentUserId,
        );
        continue;
      }
      grouped[entry.emoji] = _ReactionGroup(
        emoji: existing.emoji,
        count: existing.count + 1,
        isMine: existing.isMine ||
            (currentUserId != null && entry.userId == currentUserId),
      );
    }

    final groups = grouped.values.toList()
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

    final currentEntries = List<ChatMessageReactionEntry>.from(
        _messageReactions[message.id] ?? const []);
    final currentIndex = currentEntries.indexWhere(
      (entry) => entry.userId == currentUserId,
    );

    if (currentIndex >= 0 && currentEntries[currentIndex].emoji == emoji) {
      currentEntries.removeAt(currentIndex);
    } else {
      final nextEntry = ChatMessageReactionEntry(
        messageId: message.id,
        emoji: emoji,
        userId: currentUserId,
        userName: 'Вы',
        reactedAt: DateTime.now(),
      );
      if (currentIndex >= 0) {
        currentEntries[currentIndex] = nextEntry;
      } else {
        currentEntries.add(nextEntry);
      }
    }

    if (!mounted) {
      return;
    }
    setState(() {
      if (currentEntries.isEmpty) {
        _messageReactions.remove(message.id);
      } else {
        _messageReactions[message.id] = currentEntries;
      }
    });
    await _persistReactions();
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Сообщение закреплено')),
    );
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
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pinnedMessage?.messageId != pinned.messageId) {
          return;
        }
        unawaited(_clearPinnedMessage());
      });
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
        _onlineUserIds
          ..clear()
          ..addAll(event.onlineUserIds);
      });
      return;
    }

    if (event.type == 'presence.updated') {
      final userId = event.userId;
      if (userId == null || userId.isEmpty) {
        return;
      }
      setState(() {
        if (event.isOnline == true) {
          _onlineUserIds.add(userId);
        } else {
          _onlineUserIds.remove(userId);
          _typingUsers.remove(userId);
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
    }
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

  Future<void> _focusPinnedMessage() async {
    final pinned = _pinnedMessage;
    if (pinned == null) {
      return;
    }

    if (_isSearchMode) {
      _closeSearch();
    }

    final visibleContext = _remoteMessageKeys[pinned.messageId]?.currentContext;
    if (visibleContext != null) {
      _highlightPinnedMessage(pinned.messageId);
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
      (message) => message.id == pinned.messageId,
    );
    if (messageIndex == -1) {
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
    _highlightPinnedMessage(pinned.messageId);
    final resolvedContext =
        _remoteMessageKeys[pinned.messageId]?.currentContext;
    if (resolvedContext != null && resolvedContext.mounted) {
      await Scrollable.ensureVisible(
        resolvedContext,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: 0.18,
      );
    }
  }

  void _handleSearchChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _openSearch() {
    setState(() {
      _isSearchMode = true;
    });
  }

  void _closeSearch() {
    _searchController.clear();
    setState(() {
      _isSearchMode = false;
    });
  }

  bool _messageMatchesSearch(String text) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    return text.toLowerCase().contains(query);
  }

  int _searchMatchCount(
    List<ChatMessage> remoteMessages,
    List<_OutgoingMessage> optimisticMessages,
  ) {
    if (_searchController.text.trim().isEmpty) {
      return 0;
    }
    return remoteMessages
            .where((message) => _messageMatchesSearch(message.text))
            .length +
        optimisticMessages
            .where((message) => _messageMatchesSearch(message.text))
            .length;
  }

  void _handleMessagesScroll() {
    if (!_messagesScrollController.hasClients) {
      return;
    }
    final shouldShow = _messagesScrollController.offset > 120;
    if (shouldShow != _showJumpToLatestButton && mounted) {
      setState(() {
        _showJumpToLatestButton = shouldShow;
      });
    }
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
    });
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

  Future<void> _sendOptimisticMessage(_OutgoingMessage message) async {
    try {
      final chatId = _chatId;
      if (chatId == null || chatId.isEmpty) {
        throw StateError('Чат недоступен');
      }
      await _chatService.sendMessageToChat(
        chatId: chatId,
        text: message.text,
        attachments: message.attachments,
        forwardedAttachments: message.forwardedAttachments,
        replyTo: message.replyTo,
        clientMessageId: message.localId,
        expiresInSeconds: _autoDeleteSettings.option.ttl?.inSeconds,
        onProgress: (progress) {
          if (!mounted) {
            return;
          }
          setState(() {
            final currentIndex = _optimisticMessages.indexWhere(
              (item) => item.localId == message.localId,
            );
            if (currentIndex == -1) {
              return;
            }
            _optimisticMessages[currentIndex] =
                _optimisticMessages[currentIndex].copyWith(progress: progress);
          });
        },
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceOptimisticMessage(
          message.localId,
          message.copyWith(status: _OutgoingMessageStatus.sent),
        );
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _replaceOptimisticMessage(
          message.localId,
          message.copyWith(
            status: _OutgoingMessageStatus.failed,
            errorText: 'Не удалось отправить',
          ),
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось отправить сообщение.')),
      );
    }
  }

  void _replaceOptimisticMessage(String localId, _OutgoingMessage nextMessage) {
    final index = _optimisticMessages.indexWhere(
      (message) => message.localId == localId,
    );
    if (index == -1) {
      return;
    }
    _optimisticMessages[index] = nextMessage;
  }

  bool _matchesRemoteMessage(
    _OutgoingMessage localMessage,
    List<ChatMessage> remoteMessages,
  ) {
    return remoteMessages.any((message) {
      if (message.clientMessageId != null &&
          message.clientMessageId == localMessage.localId) {
        return true;
      }
      final sameSender = message.senderId == localMessage.senderId;
      final sameText = message.text.trim() == localMessage.text.trim();
      final sameAttachmentCount =
          (message.mediaUrls?.length ?? (message.imageUrl != null ? 1 : 0)) ==
              localMessage.attachments.length;
      final timeDelta =
          message.timestamp.difference(localMessage.timestamp).inSeconds.abs();
      return sameSender && sameText && sameAttachmentCount && timeDelta <= 30;
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
            _resolvedTitle = updatedDetails.displayTitle;
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
    final otherParticipantIds = _otherParticipantIds(details);
    if (otherParticipantIds.isEmpty) {
      return null;
    }

    final onlineCount = otherParticipantIds
        .where((participantId) => _onlineUserIds.contains(participantId))
        .length;
    if (onlineCount == 0) {
      return null;
    }

    if (!widget.isGroup) {
      return 'в сети';
    }
    return onlineCount == 1 ? '1 участник в сети' : '$onlineCount в сети';
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

  String _participantLabelForUserId(String userId) {
    final details = _chatDetails;
    if (details != null) {
      for (final participant in details.participants) {
        if (participant.userId == userId &&
            participant.displayName.trim().isNotEmpty) {
          return participant.displayName;
        }
      }
    }

    for (final message in _latestRemoteMessages) {
      if (message.senderId == userId &&
          (message.senderName?.trim().isNotEmpty ?? false)) {
        return message.senderName!.trim();
      }
    }

    return 'Участник';
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

  String _chatContextLabel(BuildContext context) {
    final provider = context.watch<TreeProvider>();
    final isFriendsTree = provider.selectedTreeKind == TreeKind.friends;
    final name = provider.selectedTreeName;
    if (name == null || name.isEmpty) {
      return isFriendsTree
          ? 'Контекст круга друзей'
          : 'Контекст семейного дерева';
    }
    return isFriendsTree ? 'Круг: $name' : 'Дерево: $name';
  }

  @override
  Widget build(BuildContext context) {
    final selectionCount = _selectedMessageCount;
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(
            _isSelectionMode
                ? Icons.close
                : (_isSearchMode ? Icons.close : Icons.arrow_back),
          ),
          onPressed: _isSelectionMode
              ? _exitSelectionMode
              : (_isSearchMode ? _closeSearch : () => context.pop()),
        ),
        titleSpacing: 0,
        title: _isSelectionMode
            ? Text(
                'Выбрано: $selectionCount',
                style: const TextStyle(fontWeight: FontWeight.w600),
              )
            : _isSearchMode
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      hintText: 'Поиск по сообщениям',
                      border: InputBorder.none,
                    ),
                  )
                : Row(
                    children: [
                      GestureDetector(
                        onTap: !widget.isGroup &&
                                widget.relativeId != null &&
                                widget.relativeId!.isNotEmpty
                            ? () => context
                                .push('/relative/details/${widget.relativeId}')
                            : null,
                        child: CircleAvatar(
                          radius: 20,
                          backgroundImage: widget.photoUrl != null &&
                                  widget.photoUrl!.isNotEmpty
                              ? NetworkImage(widget.photoUrl!)
                              : null,
                          child: widget.photoUrl == null ||
                                  widget.photoUrl!.isEmpty
                              ? widget.isGroup
                                  ? const Icon(Icons.group_outlined)
                                  : Text(
                                      widget.title.isNotEmpty
                                          ? widget.title[0]
                                          : '?',
                                    )
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _resolvedTitle,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _chatSubtitle(),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            Text(
                              _chatContextLabel(context),
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _openSearch,
                        tooltip: 'Поиск по чату',
                        icon: const Icon(Icons.search),
                      ),
                      IconButton(
                        onPressed: _isLoadingChatDetails || _chatDetails == null
                            ? null
                            : _openChatInfo,
                        tooltip: 'О чате',
                        icon: const Icon(Icons.info_outline),
                      ),
                    ],
                  ),
        actions: _isSelectionMode
            ? [
                IconButton(
                  onPressed: _copySelectedMessages,
                  tooltip: 'Скопировать выбранное',
                  icon: const Icon(Icons.copy_all_rounded),
                ),
                IconButton(
                  onPressed: _forwardSelectedMessages,
                  tooltip: 'Переслать выбранное',
                  icon: const Icon(Icons.forward_rounded),
                ),
                IconButton(
                  onPressed: _deleteSelectedMessages,
                  tooltip: 'Удалить выбранное',
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ]
            : null,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: _isWideLayout(context) ? 1100 : double.infinity,
          ),
          child: Column(
            children: [
              if (_pinnedMessage != null) _buildPinnedMessageBanner(),
              Expanded(child: _buildMessagesBody()),
              if (_isRecording)
                _buildRecordingArea()
              else
                _buildMessageInputArea(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecordingArea() {
    final theme = Theme.of(context);
    final isFriendsTree =
        context.read<TreeProvider>().selectedTreeKind == TreeKind.friends;
    final minutes =
        (_recordingDurationSeconds ~/ 60).toString().padLeft(2, '0');
    final seconds = (_recordingDurationSeconds % 60).toString().padLeft(2, '0');

    return Material(
      elevation: 5,
      color: theme.cardColor,
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).padding.bottom + 12,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.mic, color: Colors.red),
                const SizedBox(width: 12),
                Text(
                  '$minutes:$seconds',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Colors.red,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isFriendsTree
                        ? 'Запись аудио для круга...'
                        : 'Запись аудио...',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: Colors.grey),
                  ),
                ),
                IconButton(
                  onPressed: _cancelRecording,
                  icon: const Icon(Icons.delete_outline, color: Colors.grey),
                  tooltip: 'Отмена',
                ),
                IconButton(
                  onPressed: _stopAndSendRecording,
                  icon: Icon(Icons.stop_rounded,
                      color: theme.colorScheme.primary),
                  tooltip: 'Остановить и прослушать',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Остановите запись, чтобы прослушать, удалить или отправить позже.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceAttachmentPreview(XFile voiceFile) {
    final theme = Theme.of(context);
    final durationLabel = _formatDurationLabel(_lastRecordedDurationSeconds);
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
                  'Прослушайте голосовое перед отправкой',
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
          _VoicePlayerWidget(path: voiceFile.path, isMe: true),
          const SizedBox(height: 4),
          Text(
            'Можно перезаписать голосовое или отправить его как отдельное сообщение.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _rerecordVoiceAttachment,
                  icon: const Icon(Icons.mic_none_rounded),
                  label: const Text('Перезаписать'),
                ),
                TextButton.icon(
                  onPressed: _discardPendingVoiceAttachment,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить запись'),
                ),
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.chat_bubble_outline, size: 48),
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
      );
    }

    final chatId = _chatId;
    if (chatId == null || chatId.isEmpty) {
      return const Center(child: Text('Чат недоступен.'));
    }

    return StreamBuilder<List<ChatMessage>>(
      stream: _chatService.getMessagesStream(chatId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 12),
                  const Text(
                    'Не удалось загрузить сообщения. Попробуйте обновить чат.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _bootstrapChat,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Обновить'),
                  ),
                ],
              ),
            ),
          );
        }

        final remoteMessages = snapshot.data ?? const <ChatMessage>[];
        _latestRemoteMessages = remoteMessages;
        _schedulePinnedSync(remoteMessages);
        final optimisticMessages = _optimisticMessages
            .where((message) => !_matchesRemoteMessage(message, remoteMessages))
            .toList();
        final hasActiveSearch = _searchController.text.trim().isNotEmpty;
        final filteredRemoteMessages = hasActiveSearch
            ? remoteMessages
                .where((message) => _messageMatchesSearch(message.text))
                .toList()
            : remoteMessages;
        final filteredOptimisticMessages = hasActiveSearch
            ? optimisticMessages
                .where((message) => _messageMatchesSearch(message.text))
                .toList()
            : optimisticMessages;
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
            filteredOptimisticMessages.isEmpty) {
          if (hasActiveSearch) {
            return Center(
              child: Text(
                'Ничего не найдено по запросу "${_searchController.text.trim()}"',
                textAlign: TextAlign.center,
              ),
            );
          }
          final isFriendsTree =
              context.read<TreeProvider>().selectedTreeKind == TreeKind.friends;
          return Center(
            child: Text(
              isFriendsTree
                  ? 'Сообщений пока нет. Начните разговор с людьми из круга первым.'
                  : 'Сообщений пока нет. Начните диалог первым.',
            ),
          );
        }

        if (!hasActiveSearch) {
          _scheduleUnreadJumpIfNeeded();
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
        final searchMatchCount = _searchMatchCount(
          filteredRemoteMessages,
          filteredOptimisticMessages,
        );

        return Stack(
          children: [
            ListView.builder(
              controller: _messagesScrollController,
              reverse: true,
              padding: EdgeInsets.fromLTRB(
                0,
                hasActiveSearch ? 52 : 8,
                0,
                8,
              ),
              itemCount: filteredRemoteMessages.length +
                  filteredOptimisticMessages.length +
                  (hasUnreadDivider ? 1 : 0),
              itemBuilder: (context, index) {
                if (index < filteredOptimisticMessages.length) {
                  final localMessage = filteredOptimisticMessages[index];
                  return _buildOptimisticBubble(localMessage);
                }

                final remoteIndex = index - filteredOptimisticMessages.length;
                if (hasUnreadDivider && remoteIndex >= 0) {
                  var remoteCursor = 0;
                  for (final message in filteredRemoteMessages) {
                    if (message.id == unreadAnchorMessageId) {
                      if (remoteCursor == remoteIndex) {
                        return _buildUnreadDivider();
                      }
                      remoteCursor++;
                    }

                    if (remoteCursor == remoteIndex) {
                      final isMe = message.senderId == _currentUserId;
                      return _buildRemoteBubble(
                        message,
                        isMe,
                        footerLabel: _messageFooterLabel(
                          message,
                          isMe: isMe,
                          isLatestOwnDirectMessage:
                              message.id == latestOutgoingMessageId,
                        ),
                      );
                    }
                    remoteCursor++;
                  }
                }

                final remoteMessage = filteredRemoteMessages[
                    remoteIndex - (hasUnreadDivider ? 1 : 0)];
                final isMe = remoteMessage.senderId == _currentUserId;
                return _buildRemoteBubble(
                  remoteMessage,
                  isMe,
                  footerLabel: _messageFooterLabel(
                    remoteMessage,
                    isMe: isMe,
                    isLatestOwnDirectMessage:
                        remoteMessage.id == latestOutgoingMessageId,
                  ),
                );
              },
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
                      searchMatchCount == 1
                          ? 'Найдено 1 сообщение'
                          : 'Найдено $searchMatchCount сообщений',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ),
              ),
            if (_showJumpToLatestButton)
              Positioned(
                right: 16,
                bottom: 18,
                child: FloatingActionButton.small(
                  heroTag: 'jump-to-latest',
                  onPressed: _jumpToLatestMessages,
                  tooltip: 'К последним сообщениям',
                  child: const Icon(Icons.keyboard_arrow_down_rounded),
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
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: InkWell(
        onTap: _focusPinnedMessage,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
          ),
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
    final canSend = _messageController.text.trim().isNotEmpty ||
        _selectedAttachments.isNotEmpty ||
        _selectedForward != null ||
        _selectedForwardBatch != null ||
        _selectedEdit != null;
    final isFriendsTree =
        context.read<TreeProvider>().selectedTreeKind == TreeKind.friends;

    return Material(
      elevation: 5,
      color: Theme.of(context).cardColor,
      child: Container(
        padding: EdgeInsets.only(
          left: 8,
          right: 8,
          top: 8,
          bottom: MediaQuery.of(context).padding.bottom + 8,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).dividerColor,
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selectedEdit != null)
              _buildEditComposerBar(Theme.of(context), _selectedEdit!),
            if (_selectedEdit != null) const SizedBox(height: 8),
            if (_selectedReply != null)
              _buildReplyComposerBar(Theme.of(context), _selectedReply!),
            if (_selectedReply != null) const SizedBox(height: 8),
            if (_selectedForward != null)
              _buildForwardComposerBar(Theme.of(context), _selectedForward!),
            if (_selectedForward != null) const SizedBox(height: 8),
            if (_selectedForwardBatch != null)
              _buildForwardBatchComposerBar(
                Theme.of(context),
                _selectedForwardBatch!,
              ),
            if (_selectedForwardBatch != null) const SizedBox(height: 8),
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
            if (_selectedAttachments.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    isFriendsTree
                        ? 'Сообщения, фото и голосовые останутся в контексте выбранного круга друзей.'
                        : 'Сообщения, фото и голосовые останутся в контексте выбранного семейного дерева.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ),
              ),
            if (_selectedAttachments.isNotEmpty)
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
                            setState(() {
                              _selectedAttachments.clear();
                            });
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
                        isFriendsTree &&
                                _selectedAttachments.every(
                                  (file) =>
                                      _attachmentKindFromXFile(file) ==
                                      _ChatAttachmentKind.video,
                                )
                            ? 'Видео отправится как вложение для выбранного круга друзей.'
                            : _attachmentHintLabel(_selectedAttachments),
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
                                    setState(() {
                                      _selectedAttachments.removeAt(index);
                                    });
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
            if (_selectedAttachments.isNotEmpty) const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  onPressed: _selectedAttachments.length >= _maxAttachments
                      ? null
                      : _openAttachmentPicker,
                  tooltip: 'Добавить вложение',
                  icon: Icon(
                    Icons.attach_file_rounded,
                    color: Theme.of(context).iconTheme.color,
                  ),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: TextField(
                      controller: _messageController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration.collapsed(
                        hintText: 'Сообщение...',
                      ),
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      minLines: 1,
                      maxLines: 5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FloatingActionButton(
                  mini: true,
                  onPressed: canSend
                      ? (_selectedEdit != null
                          ? _saveEditedMessage
                          : _sendCurrentMessage)
                      : _startRecording,
                  elevation: 0,
                  tooltip: canSend
                      ? (_selectedEdit != null
                          ? 'Сохранить изменения'
                          : 'Отправить')
                      : 'Голосовое сообщение',
                  child: Icon(
                    canSend
                        ? (_selectedEdit != null ? Icons.check : Icons.send)
                        : Icons.mic_none_rounded,
                  ),
                ),
              ],
            ),
          ],
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
    if (isMe && !widget.isGroup && isLatestOwnDirectMessage) {
      segments.add(message.isRead ? 'Просмотрено' : 'Доставлено');
    }
    if (segments.isEmpty) {
      return null;
    }
    return segments.join(' · ');
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

  Widget _buildRemoteBubble(
    ChatMessage message,
    bool isMe, {
    String? footerLabel,
  }) {
    final messageKey = _remoteMessageKeys.putIfAbsent(
      message.id,
      () => GlobalKey(),
    );
    return GestureDetector(
      key: messageKey,
      onTap: _isSelectionMode
          ? () => _toggleRemoteMessageSelection(message)
          : null,
      onLongPressStart: (details) {
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
        senderLabel: widget.isGroup && !isMe
            ? _groupSenderLabel(message.senderName, message.senderId)
            : null,
        text: message.text,
        highlightQuery: _searchController.text.trim(),
        timeLabel: DateFormat.Hm('ru').format(message.timestamp),
        isRead: message.isRead,
        remoteAttachments: message.attachments,
        replyTo: message.replyTo,
        isPinned: _pinnedMessage?.messageId == message.id,
        isHighlighted: _highlightedPinnedMessageId == message.id,
        footerLabel: footerLabel,
        reactionGroups: _reactionGroupsForMessage(message.id),
        onReactionTap: (emoji) => _toggleReactionForMessage(message, emoji),
        showSelectionMarker: _isSelectionMode,
        isSelected: _selectedRemoteMessageIds.contains(message.id),
        onOpenRemoteAttachment: (attachments, attachment) =>
            _openRemoteAttachmentPreview(attachments, attachment),
      ),
    );
  }

  Widget _buildOptimisticBubble(_OutgoingMessage message) {
    final timeLabel = DateFormat.Hm('ru').format(message.timestamp);
    final theme = Theme.of(context);
    final statusMeta = _statusMetaForOutgoingMessage(theme, message);
    final progressValue = message.progress?.value;
    final showProgressBar = message.status == _OutgoingMessageStatus.pending &&
        message.attachments.isNotEmpty;
    final bubbleKey = ValueKey<String>('outgoing-bubble-${message.localId}');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            GestureDetector(
              key: bubbleKey,
              onTap: _isSelectionMode
                  ? () => _toggleOutgoingMessageSelection(message)
                  : null,
              onLongPressStart: (details) {
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
                highlightQuery: _searchController.text.trim(),
                timeLabel: timeLabel,
                isRead: false,
                remoteAttachments: message.forwardedAttachments,
                localAttachments: message.attachments,
                replyTo: message.replyTo,
                isPinned: false,
                isHighlighted: false,
                reactionGroups: const <_ReactionGroup>[],
                showSelectionMarker: _isSelectionMode,
                isSelected:
                    _selectedOutgoingMessageIds.contains(message.localId),
                onOpenLocalAttachment: (files, file) =>
                    _openLocalAttachmentPreview(files, file),
                footerLabel:
                    _autoDeleteSettings.option == ChatAutoDeleteOption.off
                        ? null
                        : 'Автоудаление: ${_autoDeleteSettings.option.label}',
              ),
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  statusMeta.icon,
                  size: 14,
                  color: statusMeta.color,
                ),
                const SizedBox(width: 4),
                Text(
                  statusMeta.label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: statusMeta.color,
                    fontWeight: message.status == _OutgoingMessageStatus.failed
                        ? FontWeight.w700
                        : FontWeight.w500,
                  ),
                ),
                if (message.status == _OutgoingMessageStatus.failed) ...[
                  const SizedBox(width: 6),
                  TextButton(
                    onPressed: () => _sendOptimisticMessage(
                      message.copyWith(
                        status: _OutgoingMessageStatus.pending,
                        errorText: null,
                      ),
                    ),
                    child: const Text('Повторить'),
                  ),
                ],
              ],
            ),
            if (showProgressBar) ...[
              const SizedBox(height: 4),
              SizedBox(
                width: 140,
                child: LinearProgressIndicator(value: progressValue),
              ),
            ],
          ],
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
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Текст сообщения скопирован')),
    );
  }

  Future<void> _openRemoteMessageActions(
    ChatMessage message, {
    Offset? anchorPosition,
  }) async {
    final canCopy = message.text.trim().isNotEmpty;
    final isOwnMessage = message.senderId == _currentUserId;
    final isPinned = _pinnedMessage?.messageId == message.id;
    final currentReaction = _currentReactionEmoji(message.id);
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
      selection = await showModalBottomSheet<_MessageSheetSelection>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
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
                            selected: currentReaction == emoji,
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
      action = await showModalBottomSheet<_MessageAction>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
            ],
          ),
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
      case _MessageAction.retry:
        await _sendOptimisticMessage(
          message.copyWith(
            status: _OutgoingMessageStatus.pending,
            errorText: null,
          ),
        );
        return;
      case _MessageAction.delete:
        setState(() {
          _optimisticMessages
              .removeWhere((item) => item.localId == message.localId);
        });
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
      _selectedAttachments.clear();
      _selectedEdit = _EditDraft(
        messageId: message.id,
        originalText: message.text,
        hasAttachments: message.attachments.isNotEmpty,
      );
    });
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
    List<ChatAttachment> attachments,
    ChatAttachment initialAttachment,
  ) async {
    final previewItems = attachments
        .where((attachment) => attachment.type != ChatAttachmentType.audio)
        .map(_attachmentPreviewItemFromRemote)
        .toList();
    if (previewItems.isEmpty) {
      return;
    }
    final initialIndex = previewItems.indexWhere(
      (item) =>
          item.source == initialAttachment.url &&
          item.kind == _chatAttachmentKindFromType(initialAttachment.type),
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
        .map(_attachmentPreviewItemFromLocal)
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

  _AttachmentPreviewItem _attachmentPreviewItemFromRemote(
    ChatAttachment attachment,
  ) {
    return _AttachmentPreviewItem.remote(
      kind: _chatAttachmentKindFromType(attachment.type),
      source: attachment.url,
      displayName: _displayName(attachment.fileName ?? attachment.url),
      thumbnailUrl: attachment.thumbnailUrl,
    );
  }

  _AttachmentPreviewItem _attachmentPreviewItemFromLocal(XFile file) {
    return _AttachmentPreviewItem.local(
      kind: _attachmentKindFromXFile(file),
      file: file,
      displayName: _displayName(file.name),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть вложение.')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть локальный файл.')),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            supportsChatAttachmentDownload
                ? 'Скачивание запущено'
                : 'Вложение открыто во внешнем приложении',
          ),
        ),
      );
    } catch (_) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить вложение.')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось удалить сообщение.')),
      );
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
    required this.hasPinnedMessage,
    required this.initialNotificationLevel,
    required this.initialAutoDeleteOption,
    required this.onRename,
    required this.onAddParticipants,
    required this.onRemoveParticipant,
    required this.onOpenSearch,
    required this.onNotificationLevelChanged,
    required this.onAutoDeleteChanged,
    this.onOpenPinnedMessage,
    this.onOpenTree,
    this.onOpenRelatives,
  });

  final ChatDetails initialDetails;
  final String currentUserId;
  final bool hasPinnedMessage;
  final ChatNotificationLevel initialNotificationLevel;
  final ChatAutoDeleteOption initialAutoDeleteOption;
  final Future<ChatDetails> Function(String title) onRename;
  final Future<ChatDetails> Function(List<String> participantIds)
      onAddParticipants;
  final Future<ChatDetails> Function(String participantId) onRemoveParticipant;
  final VoidCallback onOpenSearch;
  final Future<void> Function(ChatNotificationLevel level)
      onNotificationLevelChanged;
  final Future<void> Function(ChatAutoDeleteOption option) onAutoDeleteChanged;
  final VoidCallback? onOpenPinnedMessage;
  final VoidCallback? onOpenTree;
  final VoidCallback? onOpenRelatives;

  @override
  State<_ChatInfoSheet> createState() => _ChatInfoSheetState();
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
              Text(
                'О чате',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _details.displayTitle,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _details.isBranch
                    ? 'Веточный чат обновляется по составу дерева автоматически.'
                    : _details.isDirect
                        ? 'Личный чат. Здесь можно настроить уведомления, автоудаление и быстрые действия.'
                        : (isFriendsTree
                            ? 'Группа круга друзей. Можно менять название и участников.'
                            : 'Обычная семейная группа. Можно менять название и участников.'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
              ),
              const SizedBox(height: 16),
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
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(18),
                ),
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
                    subtitle: 'Найти сообщение по слову или фразе',
                    onTap: widget.onOpenSearch,
                  ),
                  if (widget.onOpenPinnedMessage != null)
                    _QuickActionCard(
                      icon: Icons.push_pin_outlined,
                      title: 'К закрепленному',
                      subtitle: 'Открыть и подсветить закрепленное сообщение',
                      onTap: widget.onOpenPinnedMessage!,
                    ),
                  if (hasTreeContext && widget.onOpenTree != null)
                    _QuickActionCard(
                      icon: Icons.account_tree_outlined,
                      title: 'Открыть дерево',
                      subtitle: 'Перейти к текущему дереву без поиска по меню',
                      onTap: widget.onOpenTree!,
                    ),
                  if (hasTreeContext && widget.onOpenRelatives != null)
                    _QuickActionCard(
                      icon: Icons.people_alt_outlined,
                      title: 'Открыть родных',
                      subtitle: 'Перейти к списку родственников этого дерева',
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(18),
                ),
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
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(18),
                ),
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
                      .map((root) => Chip(label: Text(root.name)))
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
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    _details.isBranch
                        ? 'Для веточного чата состав меняется через семейное дерево.'
                        : _details.isDirect
                            ? 'Для личного чата состав фиксирован, но уведомления и автоудаление можно настраивать.'
                            : 'Этот чат сейчас не поддерживает изменение состава.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 18),
              Text(
                'Участники',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              ..._details.participants.asMap().entries.map((entry) {
                final index = entry.key;
                final participant = entry.value;
                final isCurrentUser =
                    participant.userId == widget.currentUserId;
                return Column(
                  children: [
                    if (index > 0) const Divider(height: 1),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundImage: participant.photoUrl != null &&
                                participant.photoUrl!.isNotEmpty
                            ? NetworkImage(participant.photoUrl!)
                            : null,
                        child: participant.photoUrl == null ||
                                participant.photoUrl!.isEmpty
                            ? Text(
                                participant.displayName.isNotEmpty
                                    ? participant.displayName[0]
                                    : '?',
                              )
                            : null,
                      ),
                      title: Text(participant.displayName),
                      subtitle: Text(isCurrentUser ? 'Вы' : 'Участник'),
                      trailing: _details.isEditableGroup && !isCurrentUser
                          ? IconButton(
                              onPressed: _isSaving
                                  ? null
                                  : () => _removeParticipant(participant),
                              tooltip: 'Убрать из чата',
                              icon: const Icon(Icons.person_remove_outlined),
                            )
                          : null,
                    ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось обновить настройки уведомлений.'),
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Не удалось обновить автоудаление сообщений.'),
        ),
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
    final controller = TextEditingController(text: _details.displayTitle);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось переименовать чат.')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Для этого чата не найдено дерево.')),
      );
      return;
    }
    if (!GetIt.I.isRegistered<FamilyTreeServiceInterface>()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Список родных временно недоступен.')),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('В этом дереве больше некого добавить.')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось добавить участников.')),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось обновить состав чата.')),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 6),
            Text(label),
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
      child: Material(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
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
              Text(
                'Добавить участников',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Найти по имени',
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
                    return CheckboxListTile(
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
                        backgroundImage: candidate.photoUrl != null &&
                                candidate.photoUrl!.isNotEmpty
                            ? NetworkImage(candidate.photoUrl!)
                            : null,
                        child: candidate.photoUrl == null ||
                                candidate.photoUrl!.isEmpty
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
                      contentPadding: EdgeInsets.zero,
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

enum _AttachmentPickerChoice { images, video, file }

class _ChatBubble extends StatelessWidget {
  const _ChatBubble({
    required this.isMe,
    required this.text,
    required this.timeLabel,
    required this.isRead,
    required this.isPinned,
    required this.isHighlighted,
    this.highlightQuery = '',
    this.senderLabel,
    this.remoteAttachments = const <ChatAttachment>[],
    this.localAttachments = const <XFile>[],
    this.replyTo,
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
  final bool isPinned;
  final bool isHighlighted;
  final String highlightQuery;
  final String? senderLabel;
  final List<ChatAttachment> remoteAttachments;
  final List<XFile> localAttachments;
  final ChatReplyReference? replyTo;
  final List<_ReactionGroup> reactionGroups;
  final ValueChanged<String>? onReactionTap;
  final String? footerLabel;
  final bool showSelectionMarker;
  final bool isSelected;
  final void Function(
          List<ChatAttachment> attachments, ChatAttachment attachment)?
      onOpenRemoteAttachment;
  final void Function(List<XFile> files, XFile file)? onOpenLocalAttachment;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showSelectionMarker) ...[
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                border: Border.all(
                  color: isSelected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context)
                          .colorScheme
                          .outline
                          .withValues(alpha: 0.72),
                  width: 2,
                ),
              ),
              child: isSelected
                  ? Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.onPrimary,
                    )
                  : null,
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Align(
              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? (isMe ? Colors.blue[700] : Colors.blue[50])
                      : (isMe ? Colors.blue[600] : Colors.grey[300]),
                  border: isPinned || isHighlighted || isSelected
                      ? Border.all(
                          color: isHighlighted
                              ? Colors.amber.shade700
                              : (isSelected
                                  ? Theme.of(context).colorScheme.primary
                                  : (isMe
                                      ? Colors.white70
                                      : Colors.blue.shade300)),
                          width: isHighlighted ? 2 : 1.25,
                        )
                      : null,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 0),
                    bottomRight: Radius.circular(isMe ? 0 : 16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment:
                      isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (senderLabel != null && senderLabel!.isNotEmpty) ...[
                      Text(
                        senderLabel!,
                        style: TextStyle(
                          color: isMe
                              ? Colors.white.withValues(alpha: 0.92)
                              : Colors.black54,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 6),
                    ],
                    if (isPinned) ...[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.push_pin,
                            size: 13,
                            color: isMe
                                ? Colors.white.withValues(alpha: 0.9)
                                : Colors.blueGrey[700],
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Закреплено',
                            style: TextStyle(
                              color: isMe
                                  ? Colors.white.withValues(alpha: 0.9)
                                  : Colors.blueGrey[700],
                              fontSize: 11,
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
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (remoteAttachments.isNotEmpty) ...[
                      _buildRemoteAttachments(context),
                      const SizedBox(height: 8),
                    ],
                    if (localAttachments.isNotEmpty) ...[
                      _buildLocalAttachments(context),
                      const SizedBox(height: 8),
                    ],
                    if (text.isNotEmpty)
                      _HighlightedMessageText(
                        text: text,
                        query: highlightQuery,
                        color: isMe ? Colors.white : Colors.black87,
                      ),
                    if (text.isEmpty &&
                        remoteAttachments.isEmpty &&
                        localAttachments.isEmpty)
                      Text(
                        'Сообщение',
                        style: TextStyle(
                          color: isMe ? Colors.white : Colors.black87,
                          fontSize: 16,
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
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          timeLabel,
                          style: TextStyle(
                            color: isMe
                                ? Colors.white.withValues(alpha: 0.7)
                                : Colors.black54,
                            fontSize: 11,
                          ),
                        ),
                        if (isMe) ...[
                          const SizedBox(width: 5),
                          Icon(
                            isRead ? Icons.done_all : Icons.done,
                            size: 14,
                            color: isRead
                                ? Colors.lightBlueAccent[100]
                                : Colors.white.withValues(alpha: 0.7),
                          ),
                        ],
                      ],
                    ),
                    if (footerLabel != null && footerLabel!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        footerLabel!,
                        style: TextStyle(
                          color: isMe
                              ? Colors.white.withValues(alpha: 0.78)
                              : Colors.black54,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
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
    final visuals = remoteAttachments
        .where((a) => a.type != ChatAttachmentType.audio)
        .toList();

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (audio.isNotEmpty)
          ...audio.map((a) => _VoicePlayerWidget(url: a.url, isMe: isMe)),
        if (visuals.isNotEmpty)
          _RemoteMediaGrid(
            attachments: visuals,
            onOpenAttachment: onOpenRemoteAttachment,
          ),
      ],
    );
  }

  Widget _buildLocalAttachments(BuildContext context) {
    final audio = localAttachments
        .where((f) => _attachmentKindFromXFile(f) == _ChatAttachmentKind.audio)
        .toList();
    final visuals = localAttachments
        .where((f) => _attachmentKindFromXFile(f) != _ChatAttachmentKind.audio)
        .toList();

    return Column(
      crossAxisAlignment:
          isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        if (audio.isNotEmpty)
          ...audio.map((f) => _VoicePlayerWidget(path: f.path, isMe: isMe)),
        if (visuals.isNotEmpty)
          _LocalMediaGrid(
            files: visuals,
            onOpenAttachment: onOpenLocalAttachment,
          ),
      ],
    );
  }
}

class _ReplyQuoteCard extends StatelessWidget {
  const _ReplyQuoteCard({
    required this.reply,
    required this.isMe,
  });

  final ChatReplyReference reply;
  final bool isMe;

  @override
  Widget build(BuildContext context) {
    final titleColor = isMe ? Colors.white : Colors.black87;
    final bodyColor =
        isMe ? Colors.white.withValues(alpha: 0.78) : Colors.black54;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.white.withValues(alpha: 0.14)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: isMe ? Colors.white : Colors.blue[600],
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  reply.senderName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  reply.text.trim().isNotEmpty
                      ? reply.text
                      : 'Сообщение без текста',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: bodyColor,
                    fontSize: 12,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VoicePlayerWidget extends StatefulWidget {
  const _VoicePlayerWidget({
    this.url,
    this.path,
    required this.isMe,
  });

  final String? url;
  final String? path;
  final bool isMe;

  @override
  State<_VoicePlayerWidget> createState() => _VoicePlayerWidgetState();
}

class _VoicePlayerWidgetState extends State<_VoicePlayerWidget> {
  late final AudioPlayer _player;
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  StreamSubscription? _stateSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _posSub;
  StreamSubscription? _compSub;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playerState = s);
    });
    _durationSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _compSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playerState = PlayerState.stopped;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _durationSub?.cancel();
    _posSub?.cancel();
    _compSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _play() async {
    try {
      if (widget.url != null) {
        await _player.play(UrlSource(widget.url!));
      } else if (widget.path != null) {
        await _player.play(DeviceFileSource(widget.path!));
      }
    } catch (e) {
      debugPrint('Error playing audio: $e');
    }
  }

  Future<void> _pause() async {
    await _player.pause();
  }

  @override
  Widget build(BuildContext context) {
    final isPlaying = _playerState == PlayerState.playing;
    final color = widget.isMe ? Colors.white : Colors.blue[700];

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: widget.isMe
            ? Colors.white.withValues(alpha: 0.15)
            : Colors.blue.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: isPlaying ? _pause : _play,
            icon: Icon(isPlaying
                ? Icons.pause_circle_filled
                : Icons.play_circle_filled),
            color: color,
            iconSize: 32,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 120,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 2,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 4),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor: color,
                    inactiveTrackColor: color?.withValues(alpha: 0.3),
                    thumbColor: color,
                  ),
                  child: Slider(
                    value: _position.inMilliseconds.toDouble(),
                    max: _duration.inMilliseconds.toDouble() > 0
                        ? _duration.inMilliseconds.toDouble()
                        : 1.0,
                    onChanged: (val) {
                      _player.seek(Duration(milliseconds: val.toInt()));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(
                    _formatDuration(_position),
                    style: TextStyle(color: color, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final min = d.inMinutes;
    final sec = d.inSeconds % 60;
    return '$min:${sec.toString().padLeft(2, '0')}';
  }
}

class _RemoteMediaGrid extends StatelessWidget {
  const _RemoteMediaGrid({
    required this.attachments,
    this.onOpenAttachment,
  });

  final List<ChatAttachment> attachments;
  final void Function(
          List<ChatAttachment> attachments, ChatAttachment attachment)?
      onOpenAttachment;

  @override
  Widget build(BuildContext context) {
    if (attachments.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 220,
          height: 220,
          child: _RemoteMediaTile(
            attachment: attachments.first,
            onTap: onOpenAttachment == null
                ? null
                : () => onOpenAttachment!(attachments, attachments.first),
          ),
        ),
      );
    }

    return SizedBox(
      width: 220,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: attachments
            .take(4)
            .map(
              (attachment) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 106,
                  height: 106,
                  child: _RemoteMediaTile(
                    attachment: attachment,
                    onTap: onOpenAttachment == null
                        ? null
                        : () => onOpenAttachment!(attachments, attachment),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _LocalMediaGrid extends StatelessWidget {
  const _LocalMediaGrid({
    required this.files,
    this.onOpenAttachment,
  });

  final List<XFile> files;
  final void Function(List<XFile> files, XFile file)? onOpenAttachment;

  @override
  Widget build(BuildContext context) {
    if (files.length == 1) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 220,
          height: 220,
          child: _LocalMediaTile(
            file: files.first,
            onTap: onOpenAttachment == null
                ? null
                : () => onOpenAttachment!(files, files.first),
          ),
        ),
      );
    }

    return SizedBox(
      width: 220,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: files
            .take(4)
            .map(
              (file) => ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 106,
                  height: 106,
                  child: _LocalMediaTile(
                    file: file,
                    onTap: onOpenAttachment == null
                        ? null
                        : () => onOpenAttachment!(files, file),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _HighlightedMessageText extends StatelessWidget {
  const _HighlightedMessageText({
    required this.text,
    required this.query,
    required this.color,
  });

  final String text;
  final String query;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 16,
        ),
      );
    }

    final lowerText = text.toLowerCase();
    final lowerQuery = normalizedQuery.toLowerCase();
    final spans = <TextSpan>[];
    var currentIndex = 0;

    while (currentIndex < text.length) {
      final nextMatch = lowerText.indexOf(lowerQuery, currentIndex);
      if (nextMatch == -1) {
        spans.add(
          TextSpan(
            text: text.substring(currentIndex),
            style: TextStyle(color: color),
          ),
        );
        break;
      }
      if (nextMatch > currentIndex) {
        spans.add(
          TextSpan(
            text: text.substring(currentIndex, nextMatch),
            style: TextStyle(color: color),
          ),
        );
      }
      final matchEnd = nextMatch + normalizedQuery.length;
      spans.add(
        TextSpan(
          text: text.substring(nextMatch, matchEnd),
          style: TextStyle(
            color: color,
            backgroundColor: Colors.amber.withValues(alpha: 0.55),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      currentIndex = matchEnd;
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(fontSize: 16),
        children: spans,
      ),
    );
  }
}

class _LocalImagePreview extends StatelessWidget {
  const _LocalImagePreview({required this.file});

  final XFile file;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List>(
      future: file.readAsBytes(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        return Image.memory(
          snapshot.data!,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const ColoredBox(
            color: Color(0x11000000),
            child: Center(child: Icon(Icons.broken_image_outlined)),
          ),
        );
      },
    );
  }
}

class _LocalMediaTile extends StatelessWidget {
  const _LocalMediaTile({
    required this.file,
    this.onTap,
  });

  final XFile file;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final kind = _attachmentKindFromXFile(file);
    if (kind == _ChatAttachmentKind.image) {
      return InkWell(
        onTap: onTap,
        child: _LocalImagePreview(file: file),
      );
    }
    if (kind == _ChatAttachmentKind.audio) {
      return const _AttachmentPlaceholder(
        icon: Icons.mic_none_outlined,
        label: 'Голосовое сообщение',
      );
    }

    return InkWell(
      onTap: onTap,
      child: _AttachmentPlaceholder(
        icon: kind == _ChatAttachmentKind.video
            ? Icons.videocam_outlined
            : Icons.insert_drive_file_outlined,
        label: kind == _ChatAttachmentKind.video
            ? 'Видео'
            : _displayName(file.name),
      ),
    );
  }
}

class _RemoteMediaTile extends StatelessWidget {
  const _RemoteMediaTile({
    required this.attachment,
    this.onTap,
  });

  final ChatAttachment attachment;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final kind = attachment.type == ChatAttachmentType.file
        ? _attachmentKindFromName(attachment.fileName, attachment.url)
        : _chatAttachmentKindFromType(attachment.type);
    if (kind == _ChatAttachmentKind.image) {
      return InkWell(
        onTap: onTap,
        child: Image.network(
          attachment.thumbnailUrl ?? attachment.url,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _AttachmentPlaceholder(
            icon: Icons.broken_image_outlined,
            label: 'Файл',
          ),
        ),
      );
    }
    if (kind == _ChatAttachmentKind.audio) {
      return const _AttachmentPlaceholder(
        icon: Icons.mic_none_outlined,
        label: 'Голосовое сообщение',
      );
    }

    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (kind == _ChatAttachmentKind.video &&
              attachment.thumbnailUrl != null &&
              attachment.thumbnailUrl!.isNotEmpty)
            Image.network(
              attachment.thumbnailUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(
                alpha: kind == _ChatAttachmentKind.video ? 0.28 : 0.08,
              ),
            ),
            child: _AttachmentPlaceholder(
              icon: kind == _ChatAttachmentKind.video
                  ? Icons.play_circle_outline_rounded
                  : Icons.insert_drive_file_outlined,
              label: kind == _ChatAttachmentKind.video
                  ? 'Видео'
                  : _displayName(attachment.fileName ?? attachment.url),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttachmentPlaceholder extends StatelessWidget {
  const _AttachmentPlaceholder({
    required this.icon,
    required this.label,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0x11000000),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReactionGroup {
  const _ReactionGroup({
    required this.emoji,
    required this.count,
    required this.isMine,
  });

  final String emoji;
  final int count;
  final bool isMine;
}

class _ReactionPill extends StatelessWidget {
  const _ReactionPill({
    required this.reaction,
    required this.isMe,
    this.onTap,
  });

  final _ReactionGroup reaction;
  final bool isMe;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final textColor =
        isMe ? Colors.white.withValues(alpha: 0.95) : Colors.black87;
    final selectedColor = isMe
        ? Colors.white.withValues(alpha: 0.18)
        : Colors.blue.withValues(alpha: 0.14);
    final defaultColor = isMe
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.white.withValues(alpha: 0.72);

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: reaction.isMine ? selectedColor : defaultColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: reaction.isMine
                ? (isMe
                    ? Colors.white.withValues(alpha: 0.45)
                    : Colors.blue.withValues(alpha: 0.28))
                : Colors.transparent,
          ),
        ),
        child: Text(
          '${reaction.emoji} ${reaction.count}',
          style: TextStyle(
            color: textColor,
            fontSize: 12,
            fontWeight: reaction.isMine ? FontWeight.w700 : FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

enum _MessageAction {
  react,
  reply,
  forward,
  select,
  pin,
  edit,
  copy,
  retry,
  delete
}

class _ContextMenuActionItem<T> {
  const _ContextMenuActionItem({
    required this.label,
    required this.icon,
    required this.value,
    this.isDestructive = false,
  });

  final String label;
  final IconData icon;
  final T value;
  final bool isDestructive;
}

class _MessageSheetSelection {
  const _MessageSheetSelection({
    required this.action,
    this.emoji,
  });

  final _MessageAction action;
  final String? emoji;
}

class _ForwardBatchDraft {
  const _ForwardBatchDraft({
    required this.items,
  });

  final List<_ForwardDraft> items;
}

class _SelectedMessageEntry {
  _SelectedMessageEntry.remote({
    required ChatMessage message,
    required this.displayName,
  })  : remoteMessageId = message.id,
        outgoingLocalId = null,
        senderId = message.senderId,
        text = message.text,
        timestamp = message.timestamp,
        attachments = message.attachments;

  _SelectedMessageEntry.outgoing({
    required _OutgoingMessage message,
    required this.displayName,
    required List<ChatAttachment> normalizedAttachments,
  })  : remoteMessageId = null,
        outgoingLocalId = message.localId,
        senderId = message.senderId,
        text = message.text,
        timestamp = message.timestamp,
        attachments = normalizedAttachments;

  final String? remoteMessageId;
  final String? outgoingLocalId;
  final String senderId;
  final String displayName;
  final String text;
  final DateTime timestamp;
  final List<ChatAttachment> attachments;

  bool canDelete(String currentUserId) {
    if (remoteMessageId != null) {
      return senderId == currentUserId;
    }
    return true;
  }
}

class _AttachmentPreviewItem {
  const _AttachmentPreviewItem.remote({
    required this.kind,
    required this.source,
    required this.displayName,
    this.thumbnailUrl,
  })  : file = null,
        isRemote = true;

  const _AttachmentPreviewItem.local({
    required this.kind,
    required this.file,
    required this.displayName,
  })  : source = null,
        thumbnailUrl = null,
        isRemote = false;

  final _ChatAttachmentKind kind;
  final String? source;
  final String? thumbnailUrl;
  final XFile? file;
  final String displayName;
  final bool isRemote;

  bool get isVisual =>
      kind == _ChatAttachmentKind.image || kind == _ChatAttachmentKind.video;
}

class _DesktopMessageContextMenu<T> extends StatelessWidget {
  const _DesktopMessageContextMenu({
    required this.actions,
    required this.onActionSelected,
    this.reactions = const <String>[],
    this.onReactionSelected,
  });

  final List<_ContextMenuActionItem<T>> actions;
  final List<String> reactions;
  final ValueChanged<T> onActionSelected;
  final ValueChanged<String>? onReactionSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final backgroundColor = isDark ? const Color(0xFF1F1F22) : Colors.white;
    final reactionBarColor =
        isDark ? const Color(0xFF2A2A2F) : const Color(0xFFF4F5F8);
    final shadowColor = Colors.black.withValues(alpha: isDark ? 0.34 : 0.16);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (reactions.isNotEmpty && onReactionSelected != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: reactionBarColor,
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [
                    BoxShadow(
                      color: shadowColor,
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: reactions
                      .map(
                        (emoji) => InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () => onReactionSelected?.call(emoji),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: Text(
                              emoji,
                              style: const TextStyle(fontSize: 26, height: 1),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            if (reactions.isNotEmpty && onReactionSelected != null)
              const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: backgroundColor,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: shadowColor,
                    blurRadius: 30,
                    offset: const Offset(0, 14),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var index = 0; index < actions.length; index++) ...[
                      _DesktopMessageContextMenuTile<T>(
                        item: actions[index],
                        onTap: () => onActionSelected(actions[index].value),
                      ),
                      if (index != actions.length - 1)
                        Divider(
                          height: 1,
                          indent: 54,
                          endIndent: 16,
                          color: theme.colorScheme.outlineVariant
                              .withValues(alpha: 0.32),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DesktopMessageContextMenuTile<T> extends StatelessWidget {
  const _DesktopMessageContextMenuTile({
    required this.item,
    required this.onTap,
  });

  final _ContextMenuActionItem<T> item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foregroundColor = item.isDestructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 28,
              child: Icon(
                item.icon,
                size: 21,
                color: foregroundColor,
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                item.label,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: foregroundColor,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentViewerDialog extends StatefulWidget {
  const _AttachmentViewerDialog({
    required this.items,
    required this.initialIndex,
    required this.onOpenExternally,
    required this.onDownload,
  });

  final List<_AttachmentPreviewItem> items;
  final int initialIndex;
  final Future<void> Function(_AttachmentPreviewItem item) onOpenExternally;
  final Future<void> Function(_AttachmentPreviewItem item) onDownload;

  @override
  State<_AttachmentViewerDialog> createState() =>
      _AttachmentViewerDialogState();
}

class _AttachmentViewerDialogState extends State<_AttachmentViewerDialog> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.items.length - 1);
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentItem = widget.items[_currentIndex];
    return Dialog.fullscreen(
      backgroundColor: Colors.black.withValues(alpha: 0.92),
      child: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          currentItem.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: currentItem.isRemote
                            ? 'Открыть оригинал'
                            : 'Открыть файл',
                        onPressed: () => widget.onOpenExternally(currentItem),
                        icon:
                            const Icon(Icons.open_in_new, color: Colors.white),
                      ),
                      IconButton(
                        tooltip: supportsChatAttachmentDownload
                            ? 'Скачать'
                            : 'Открыть',
                        onPressed: () => widget.onDownload(currentItem),
                        icon: Icon(
                          supportsChatAttachmentDownload
                              ? Icons.download_rounded
                              : Icons.file_download_outlined,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: widget.items.length,
                    onPageChanged: (index) {
                      setState(() {
                        _currentIndex = index;
                      });
                    },
                    itemBuilder: (context, index) {
                      return _AttachmentViewerPage(item: widget.items[index]);
                    },
                  ),
                ),
                if (widget.items.length > 1)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List<Widget>.generate(
                        widget.items.length,
                        (index) => AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          width: index == _currentIndex ? 18 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: index == _currentIndex
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (widget.items.length > 1 && _currentIndex > 0)
              Positioned(
                left: 20,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filledTonal(
                    onPressed: () => _pageController.previousPage(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                    ),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                ),
              ),
            if (widget.items.length > 1 &&
                _currentIndex < widget.items.length - 1)
              Positioned(
                right: 20,
                top: 0,
                bottom: 0,
                child: Center(
                  child: IconButton.filledTonal(
                    onPressed: () => _pageController.nextPage(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                    ),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentViewerPage extends StatelessWidget {
  const _AttachmentViewerPage({required this.item});

  final _AttachmentPreviewItem item;

  @override
  Widget build(BuildContext context) {
    Widget content;
    switch (item.kind) {
      case _ChatAttachmentKind.image:
        content = item.isRemote
            ? InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Image.network(
                  item.source!,
                  fit: BoxFit.contain,
                ),
              )
            : FutureBuilder<Uint8List>(
                future: item.file!.readAsBytes(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 4,
                    child: Image.memory(
                      snapshot.data!,
                      fit: BoxFit.contain,
                    ),
                  );
                },
              );
        break;
      case _ChatAttachmentKind.video:
        final source = item.isRemote ? item.source! : item.file?.path;
        content = source == null || source.trim().isEmpty
            ? _AttachmentViewerPlaceholder(item: item)
            : _AttachmentVideoPlayer(
                url: source,
                posterUrl: item.thumbnailUrl,
              );
        break;
      case _ChatAttachmentKind.audio:
      case _ChatAttachmentKind.other:
        content = _AttachmentViewerPlaceholder(item: item);
        break;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Center(child: content),
    );
  }
}

class _AttachmentViewerPlaceholder extends StatelessWidget {
  const _AttachmentViewerPlaceholder({required this.item});

  final _AttachmentPreviewItem item;

  @override
  Widget build(BuildContext context) {
    final icon = item.kind == _ChatAttachmentKind.video
        ? Icons.videocam_outlined
        : Icons.insert_drive_file_outlined;
    final label = item.kind == _ChatAttachmentKind.video ? 'Видео' : 'Файл';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: Colors.white),
            const SizedBox(height: 12),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.displayName,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.78),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AttachmentVideoPlayer extends StatefulWidget {
  const _AttachmentVideoPlayer({
    required this.url,
    this.posterUrl,
  });

  final String url;
  final String? posterUrl;

  @override
  State<_AttachmentVideoPlayer> createState() => _AttachmentVideoPlayerState();
}

class _AttachmentVideoPlayerState extends State<_AttachmentVideoPlayer> {
  VideoPlayerController? _controller;
  Future<void>? _initializeFuture;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _initializeFuture = _controller!.initialize();
    _controller!.setLooping(true);
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null) {
      return;
    }
    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<void>(
      future: _initializeFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Stack(
            alignment: Alignment.center,
            children: [
              if (widget.posterUrl != null && widget.posterUrl!.isNotEmpty)
                Image.network(widget.posterUrl!, fit: BoxFit.contain),
              const CircularProgressIndicator(),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 560),
              child: AspectRatio(
                aspectRatio: controller.value.aspectRatio == 0
                    ? 16 / 9
                    : controller.value.aspectRatio,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: Colors.black,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        VideoPlayer(controller),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(
                              alpha: controller.value.isPlaying ? 0.06 : 0.22,
                            ),
                          ),
                          child: const SizedBox.expand(),
                        ),
                        IconButton.filledTonal(
                          onPressed: _togglePlayback,
                          icon: Icon(
                            controller.value.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Slider(
              value: controller.value.position.inMilliseconds
                  .clamp(0, controller.value.duration.inMilliseconds)
                  .toDouble(),
              max: controller.value.duration.inMilliseconds <= 0
                  ? 1
                  : controller.value.duration.inMilliseconds.toDouble(),
              onChanged: (value) {
                controller.seekTo(Duration(milliseconds: value.round()));
              },
            ),
          ],
        );
      },
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
