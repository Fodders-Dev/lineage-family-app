import 'package:flutter/material.dart';
import '../models/user_profile.dart';
import '../models/family_relation.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/interfaces/profile_service_interface.dart';

class FindRelativeScreen extends StatefulWidget {
  final String treeId;

  const FindRelativeScreen({super.key, required this.treeId});

  @override
  State<FindRelativeScreen> createState() => _FindRelativeScreenState();
}

class _FindRelativeScreenState extends State<FindRelativeScreen>
    with TickerProviderStateMixin {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final ProfileServiceInterface _profileService =
      GetIt.I<ProfileServiceInterface>();
  List<UserProfile> _searchResults = [];
  bool _isLoading = false;
  RelationType? _selectedRelation;
  late TabController _tabController;
  final _searchEmailController = TextEditingController();
  final _searchPhoneController = TextEditingController();
  final _searchUsernameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchEmailController.dispose();
    _searchPhoneController.dispose();
    _searchUsernameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Найти родственника'),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: 'Email'),
            Tab(text: 'Телефон'),
            Tab(text: 'Никнейм'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildEmailSearchTab(),
          _buildPhoneSearchTab(),
          _buildUsernameSearchTab(),
        ],
      ),
    );
  }

  Future<void> _searchByEmail() async {
    final email = _searchEmailController.text.trim();
    if (email.isEmpty) return;

    setState(() {
      _isLoading = true;
      _searchResults = [];
    });

    try {
      final results = await _profileService.searchUsersByField(
        field: 'email',
        value: email,
        limit: 1,
      );
      final availableResults = await _filterAvailableUsers(results);

      if (!mounted) return;
      if (availableResults.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Подходящий пользователь с таким email не найден'),
          ),
        );
        setState(() {
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _searchResults = availableResults;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Ошибка при поиске пользователя: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Произошла ошибка при поиске: $e')),
      );
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _searchByPhone() async {
    final phone = _searchPhoneController.text.trim();
    if (phone.isEmpty) return;

    _searchUser({'field': 'phoneNumber', 'value': phone});
  }

  Future<void> _searchByUsername() async {
    final username = _searchUsernameController.text.trim();
    if (username.isEmpty) return;

    _searchUser({'field': 'username', 'value': username});
  }

  Future<void> _searchUser(Map<String, String> query) async {
    setState(() {
      _isLoading = true;
      _searchResults = [];
    });

    try {
      final results = await _profileService.searchUsersByField(
        field: query['field']!,
        value: query['value']!,
      );
      final availableResults = await _filterAvailableUsers(results);

      if (!mounted) return;
      setState(() {
        _searchResults = availableResults;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint('Ошибка поиска: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка поиска: $e')));
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _sendRelationRequest(
    UserProfile user,
    RelationType relationType,
  ) async {
    if (user.id.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: информация о пользователе недоступна')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final currentUserId = _authService.currentUserId;
      if (currentUserId == null) throw Exception('Вы не авторизованы');

      // Проверяем, не отправлен ли запрос уже
      final hasPendingRequest =
          await _familyTreeService.hasPendingRelationRequest(
        treeId: widget.treeId,
        senderId: currentUserId,
        recipientId: user.id,
      );

      if (!mounted) return;
      if (hasPendingRequest) {
        setState(() {
          _isLoading = false;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Запрос этому пользователю уже отправлен')),
        );
        return;
      }

      await _familyTreeService.sendRelationRequest(
        treeId: widget.treeId,
        recipientId: user.id,
        relationType: relationType,
        message: 'Запрос на подтверждение родственной связи',
      );

      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Запрос успешно отправлен')));

      context.pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
    }
  }

  Future<List<UserProfile>> _filterAvailableUsers(
    List<UserProfile> users,
  ) async {
    final currentUserId = _authService.currentUserId;
    final relatives = await _familyTreeService.getRelatives(widget.treeId);
    final existingUserIds = relatives
        .map((person) => person.userId)
        .whereType<String>()
        .where((userId) => userId.isNotEmpty)
        .toSet();

    return users.where((user) {
      if (user.id.isEmpty) {
        return false;
      }
      if (user.id == currentUserId) {
        return false;
      }
      return !existingUserIds.contains(user.id);
    }).toList();
  }

  Widget _buildUserCard(UserProfile user) {
    final String displayName = user.displayName.isNotEmpty
        ? user.displayName
        : (user.firstName.isNotEmpty
            ? '${user.firstName} ${user.lastName}'
            : 'Пользователь');

    return Card(
      margin: EdgeInsets.symmetric(vertical: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundImage:
              user.photoURL != null ? NetworkImage(user.photoURL!) : null,
          child: user.photoURL == null
              ? Text(
                  displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
                )
              : null,
        ),
        title: Text(displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (user.email.isNotEmpty) Text(user.email),
            if (user.username.isNotEmpty)
              Text('@${user.username}', style: TextStyle(color: Colors.blue)),
          ],
        ),
        trailing: IconButton(
          icon: Icon(Icons.add_circle_outline, color: Colors.green),
          onPressed: () => _showRelationSelectDialog(user),
        ),
      ),
    );
  }

  Widget _buildEmailSearchTab() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _searchEmailController,
            decoration: InputDecoration(
              labelText: 'Email пользователя',
              hintText: 'example@mail.ru',
              prefixIcon: Icon(Icons.email),
              border: OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(Icons.search),
                onPressed: _searchByEmail,
              ),
            ),
            keyboardType: TextInputType.emailAddress,
            onSubmitted: (_) => _searchByEmail(),
          ),
          SizedBox(height: 16),
          if (_isLoading)
            Center(child: CircularProgressIndicator())
          else if (_searchResults.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _searchResults.length,
                itemBuilder: (context, index) =>
                    _buildUserCard(_searchResults[index]),
              ),
            )
          else if (_searchEmailController.text.isNotEmpty)
            Expanded(child: Center(child: Text('Пользователь не найден'))),
        ],
      ),
    );
  }

  Widget _buildPhoneSearchTab() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _searchPhoneController,
            decoration: InputDecoration(
              labelText: 'Телефон пользователя',
              hintText: '+7XXXXXXXXXX',
              prefixIcon: Icon(Icons.phone),
              border: OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(Icons.search),
                onPressed: _searchByPhone,
              ),
            ),
            keyboardType: TextInputType.phone,
            onSubmitted: (_) => _searchByPhone(),
          ),
          SizedBox(height: 16),
          if (_isLoading)
            Center(child: CircularProgressIndicator())
          else if (_searchResults.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _searchResults.length,
                itemBuilder: (context, index) =>
                    _buildUserCard(_searchResults[index]),
              ),
            )
          else if (_searchPhoneController.text.isNotEmpty)
            Expanded(child: Center(child: Text('Пользователь не найден'))),
        ],
      ),
    );
  }

  Widget _buildUsernameSearchTab() {
    return Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          TextField(
            controller: _searchUsernameController,
            decoration: InputDecoration(
              labelText: 'Никнейм пользователя',
              hintText: '@username',
              prefixIcon: Icon(Icons.person),
              border: OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(Icons.search),
                onPressed: _searchByUsername,
              ),
            ),
            onSubmitted: (_) => _searchByUsername(),
          ),
          SizedBox(height: 16),
          if (_isLoading)
            Center(child: CircularProgressIndicator())
          else if (_searchResults.isNotEmpty)
            Expanded(
              child: ListView.builder(
                itemCount: _searchResults.length,
                itemBuilder: (context, index) =>
                    _buildUserCard(_searchResults[index]),
              ),
            )
          else if (_searchUsernameController.text.isNotEmpty)
            Expanded(child: Center(child: Text('Пользователь не найден'))),
        ],
      ),
    );
  }

  Widget _buildRelationTypeDropdown() {
    return DropdownButtonFormField<RelationType>(
      initialValue: _selectedRelation,
      decoration: InputDecoration(
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      hint: Text('Выберите тип связи'),
      isExpanded: true,
      items: [
        DropdownMenuItem(value: RelationType.parent, child: Text('Родитель')),
        DropdownMenuItem(value: RelationType.child, child: Text('Ребенок')),
        DropdownMenuItem(value: RelationType.spouse, child: Text('Супруг(а)')),
        DropdownMenuItem(
          value: RelationType.sibling,
          child: Text('Брат/сестра'),
        ),
        DropdownMenuItem(
          value: RelationType.cousin,
          child: Text('Двоюродный брат/сестра'),
        ),
        DropdownMenuItem(value: RelationType.uncle, child: Text('Дядя')),
        DropdownMenuItem(value: RelationType.aunt, child: Text('Тётя')),
        DropdownMenuItem(
          value: RelationType.grandparent,
          child: Text('Бабушка/дедушка'),
        ),
        DropdownMenuItem(
          value: RelationType.grandchild,
          child: Text('Внук/внучка'),
        ),
      ],
      onChanged: (value) {
        setState(() {
          _selectedRelation = value;
        });
      },
    );
  }

  void _showRelationSelectDialog(UserProfile user) {
    setState(() {
      _selectedRelation = null;
    });
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Выберите тип родственной связи'),
        content: _buildRelationTypeDropdown(),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Отмена'),
          ),
          TextButton(
            onPressed: () {
              if (_selectedRelation == null) {
                ScaffoldMessenger.of(this.context).showSnackBar(
                  SnackBar(content: Text('Сначала выберите тип родства')),
                );
                return;
              }
              _sendRelationRequest(user, _selectedRelation!);
            },
            child: Text('Добавить'),
          ),
        ],
      ),
    );
  }
}
