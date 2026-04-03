import 'package:flutter/material.dart';
import '../models/user_profile.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';

class SendRelationRequestScreen extends StatefulWidget {
  final String treeId;

  const SendRelationRequestScreen({Key? key, required this.treeId})
      : super(key: key);

  @override
  _SendRelationRequestScreenState createState() =>
      _SendRelationRequestScreenState();
}

class _SendRelationRequestScreenState extends State<SendRelationRequestScreen> {
  final _searchController = TextEditingController();

  List<UserProfile> _searchResults = [];
  UserProfile? _selectedUser;
  bool _isLoading = false;
  bool _isSearching = false;

  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _searchUsers(String query) async {
    if (query.length < 3) return;

    setState(() {
      _isSearching = true;
      _searchResults = [];
    });

    try {
      setState(() {
        _searchResults = [];
      });
      final results = await _profileService.searchUsers(query);
      setState(() {
        _searchResults = results;
      });
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка поиска: $e')));
    } finally {
      setState(() {
        _isSearching = false;
      });
    }
  }

  Future<void> _sendInvitation() async {
    if (_selectedUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Выберите пользователя Родни')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await _familyService.sendTreeInvitation(
        treeId: widget.treeId,
        recipientUserId: _selectedUser!.id,
        relationToTree: 'родственник',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(
        SnackBar(content: Text('Приглашение в дерево отправлено')),
      );

      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка отправки запроса: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Пригласить в дерево')),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Найдите человека, который уже пользуется Родней',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Мы отправим ему именно приглашение в дерево. Принять его можно будет в разделе деревьев.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  SizedBox(height: 16),
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      labelText: 'Имя, email или телефон',
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(Icons.search),
                        onPressed: () => _searchUsers(_searchController.text),
                      ),
                    ),
                    onSubmitted: _searchUsers,
                  ),
                  SizedBox(height: 16),
                  if (!_isSearching &&
                      _searchResults.isEmpty &&
                      _searchController.text.trim().length >= 3)
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Если человека нет в поиске, у него, скорее всего, ещё нет аккаунта. В таком случае лучше отправить ему обычную invite-ссылку из карточки родственника.',
                      ),
                    ),
                  if (_isSearching)
                    Center(child: CircularProgressIndicator())
                  else if (_searchResults.isNotEmpty)
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Результаты поиска',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        SizedBox(height: 8),
                        ListView.builder(
                          shrinkWrap: true,
                          physics: NeverScrollableScrollPhysics(),
                          itemCount: _searchResults.length,
                          itemBuilder: (context, index) {
                            final user = _searchResults[index];
                            final isSelected = _selectedUser?.id == user.id;

                            return ListTile(
                              leading: CircleAvatar(
                                backgroundImage: user.photoURL != null
                                    ? NetworkImage(user.photoURL!)
                                    : null,
                                child: user.photoURL == null
                                    ? Text(user.displayName[0])
                                    : null,
                              ),
                              title: Text(user.displayName),
                              subtitle: Text(user.email ?? 'Email не указан'),
                              trailing: isSelected
                                  ? Icon(
                                      Icons.check_circle,
                                      color: Colors.green,
                                    )
                                  : null,
                              selected: isSelected,
                              onTap: () {
                                setState(() {
                                  _selectedUser = isSelected ? null : user;
                                });
                              },
                            );
                          },
                        ),
                      ],
                    ),
                  if (_selectedUser != null) ...[
                    SizedBox(height: 24),
                    Text(
                      'Выбранный пользователь',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: 8),
                    ListTile(
                      leading: CircleAvatar(
                        backgroundImage: _selectedUser!.photoURL != null
                            ? NetworkImage(_selectedUser!.photoURL!)
                            : null,
                        child: _selectedUser!.photoURL == null
                            ? Text(_selectedUser!.displayName[0])
                            : null,
                      ),
                      title: Text(_selectedUser!.displayName),
                      subtitle: Text(_selectedUser!.email ?? 'Email не указан'),
                      trailing: IconButton(
                        icon: Icon(Icons.close),
                        onPressed: () {
                          setState(() {
                            _selectedUser = null;
                          });
                        },
                      ),
                    ),
                    SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        'Этот сценарий нужен именно для людей с готовым аккаунтом Родни. Если нужно привязать человека к конкретной офлайн-карточке в дереве, это пока делается отдельным запросом из карточки родственника.',
                      ),
                    ),
                    SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _sendInvitation,
                      style: ElevatedButton.styleFrom(
                        minimumSize: Size(double.infinity, 48),
                      ),
                      child: Text('Отправить приглашение'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
