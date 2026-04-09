import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/chat_service_interface.dart';
import '../models/chat_preview.dart';

class ChatForwardSelector extends StatefulWidget {
  const ChatForwardSelector({super.key});

  @override
  State<ChatForwardSelector> createState() => _ChatForwardSelectorState();
}

class _ChatForwardSelectorState extends State<ChatForwardSelector> {
  final ChatServiceInterface _chatService = GetIt.I<ChatServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();

  List<ChatPreview> _chats = [];
  bool _isLoading = true;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadChats();
  }

  Future<void> _loadChats() async {
    final userId = _authService.currentUserId;
    if (userId == null) return;

    // We use the stream for one-time fetch or just listen
    final stream = _chatService.getUserChatsStream(userId);
    final firstBatch = await stream.first;
    if (mounted) {
      setState(() {
        _chats = firstBatch;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final filteredChats = _chats
        .where((c) =>
            c.displayName.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Text(
                  'Переслать',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: TextField(
              onChanged: (v) => setState(() => _searchQuery = v),
              decoration: InputDecoration(
                hintText: 'Поиск чатов...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.3,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : filteredChats.isEmpty
                    ? Center(
                        child: Text(_searchQuery.isEmpty
                            ? 'Чатов не найдено'
                            : 'Ничего не найдено'))
                    : ListView.builder(
                        itemCount: filteredChats.length,
                        itemBuilder: (context, index) {
                          final chat = filteredChats[index];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundImage: chat.displayPhotoUrl != null
                                  ? NetworkImage(chat.displayPhotoUrl!)
                                  : null,
                              child: chat.displayPhotoUrl == null
                                  ? Text(chat.displayName.isNotEmpty
                                      ? chat.displayName[0]
                                      : '?')
                                  : null,
                            ),
                            title: Text(chat.displayName),
                            subtitle: Text(
                                chat.isGroup ? 'Групповой чат' : 'Личный чат'),
                            onTap: () => Navigator.pop(context, chat),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
