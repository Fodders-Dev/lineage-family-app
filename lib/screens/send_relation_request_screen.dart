import 'package:flutter/material.dart';
import '../models/family_relation.dart';
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
  final _messageController = TextEditingController();

  List<UserProfile> _searchResults = [];
  UserProfile? _selectedUser;
  RelationType? _selectedRelation;
  bool _isLoading = false;
  bool _isSearching = false;

  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();

  @override
  void dispose() {
    _searchController.dispose();
    _messageController.dispose();
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

  Future<void> _sendRequest() async {
    if (_selectedUser == null || _selectedRelation == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Выберите пользователя и тип родства')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      await _familyService.sendRelationRequest(
        treeId: widget.treeId,
        recipientId: _selectedUser!.id,
        relationType: _selectedRelation!,
        message: _messageController.text,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Запрос на родство отправлен')));

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
      appBar: AppBar(title: Text('Добавить родственника')),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Поиск пользователей',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  SizedBox(height: 8),
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
                    Text(
                      'Тип родства',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    SizedBox(height: 8),
                    DropdownButtonFormField<RelationType>(
                      decoration: InputDecoration(
                        labelText: 'Кем приходится вам этот человек',
                        border: OutlineInputBorder(),
                      ),
                      value: _selectedRelation,
                      items: [
                        DropdownMenuItem(
                          value: RelationType.parent,
                          child: Text('Родитель (отец/мать)'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.child,
                          child: Text('Ребенок (сын/дочь)'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.spouse,
                          child: Text('Супруг(а)'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.sibling,
                          child: Text('Брат/сестра'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.cousin,
                          child: Text('Двоюродный брат/сестра'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.uncle,
                          child: Text('Дядя/тетя'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.nephew,
                          child: Text('Племянник/племянница'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.grandparent,
                          child: Text('Дедушка/бабушка'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.grandchild,
                          child: Text('Внук/внучка'),
                        ),
                        DropdownMenuItem(
                          value: RelationType.other,
                          child: Text('Другое родство'),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedRelation = value;
                        });
                      },
                    ),
                    SizedBox(height: 16),
                    TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        labelText: 'Сообщение (необязательно)',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    SizedBox(height: 24),
                    ElevatedButton(
                      onPressed: _sendRequest,
                      style: ElevatedButton.styleFrom(
                        minimumSize: Size(double.infinity, 48),
                      ),
                      child: Text('Отправить запрос на родство'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
