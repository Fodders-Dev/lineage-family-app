enum ChatSendProgressStage { preparing, uploading, sending }

class ChatSendProgress {
  const ChatSendProgress({
    required this.stage,
    required this.completed,
    required this.total,
  });

  final ChatSendProgressStage stage;
  final int completed;
  final int total;

  double? get value {
    if (total <= 0) {
      return null;
    }
    final normalized = completed.clamp(0, total);
    return normalized / total;
  }
}
