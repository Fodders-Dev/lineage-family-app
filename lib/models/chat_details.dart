class ChatParticipantSummary {
  const ChatParticipantSummary({
    required this.userId,
    required this.displayName,
    this.photoUrl,
  });

  final String userId;
  final String displayName;
  final String? photoUrl;

  factory ChatParticipantSummary.fromMap(Map<String, dynamic> map) {
    return ChatParticipantSummary(
      userId: map['userId']?.toString() ?? '',
      displayName: map['displayName']?.toString() ?? 'Пользователь',
      photoUrl: map['photoUrl']?.toString(),
    );
  }
}

class ChatBranchRootSummary {
  const ChatBranchRootSummary({
    required this.personId,
    required this.name,
    this.photoUrl,
  });

  final String personId;
  final String name;
  final String? photoUrl;

  factory ChatBranchRootSummary.fromMap(Map<String, dynamic> map) {
    return ChatBranchRootSummary(
      personId: map['personId']?.toString() ?? '',
      name: map['name']?.toString() ?? 'Без имени',
      photoUrl: map['photoUrl']?.toString(),
    );
  }
}

class ChatDetails {
  const ChatDetails({
    required this.chatId,
    required this.type,
    required this.participantIds,
    required this.participants,
    required this.branchRoots,
    this.title,
    this.createdBy,
    this.treeId,
    this.createdAt,
    this.updatedAt,
  });

  final String chatId;
  final String type;
  final String? title;
  final List<String> participantIds;
  final String? createdBy;
  final String? treeId;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<ChatParticipantSummary> participants;
  final List<ChatBranchRootSummary> branchRoots;

  bool get isGroup => type == 'group' || type == 'branch';
  bool get isBranch => type == 'branch';
  bool get isEditableGroup => type == 'group';
  int get memberCount => participants.length;

  String get displayTitle {
    final normalizedTitle = title?.trim();
    if (normalizedTitle != null && normalizedTitle.isNotEmpty) {
      return normalizedTitle;
    }
    if (isBranch) {
      return 'Чат ветки';
    }
    if (isGroup) {
      return 'Групповой чат';
    }
    return participants.isNotEmpty ? participants.first.displayName : 'Чат';
  }

  factory ChatDetails.fromMap(Map<String, dynamic> map) {
    DateTime? parseTimestamp(dynamic value) {
      final raw = value?.toString();
      if (raw == null || raw.isEmpty) {
        return null;
      }
      return DateTime.tryParse(raw);
    }

    return ChatDetails(
      chatId: map['id']?.toString() ?? map['chatId']?.toString() ?? '',
      type: map['type']?.toString() ?? 'direct',
      title: map['title']?.toString(),
      participantIds: List<String>.from(map['participantIds'] ?? const []),
      createdBy: map['createdBy']?.toString(),
      treeId: map['treeId']?.toString(),
      createdAt: parseTimestamp(map['createdAt']),
      updatedAt: parseTimestamp(map['updatedAt']),
      participants: (map['participants'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .map(ChatParticipantSummary.fromMap)
          .toList(),
      branchRoots: (map['branchRoots'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .map(ChatBranchRootSummary.fromMap)
          .toList(),
    );
  }
}
