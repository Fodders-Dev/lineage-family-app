import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:get_it/get_it.dart';

import '../backend/interfaces/family_tree_service_interface.dart';
import '../providers/tree_provider.dart';
import '../models/family_person.dart';
import '../backend/interfaces/auth_service_interface.dart';

class OfflineProfilesScreen extends StatefulWidget {
  const OfflineProfilesScreen({Key? key}) : super(key: key);

  @override
  _OfflineProfilesScreenState createState() => _OfflineProfilesScreenState();
}

class _OfflineProfilesScreenState extends State<OfflineProfilesScreen> {
  final FamilyTreeServiceInterface _familyService =
      GetIt.I<FamilyTreeServiceInterface>();
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();

  List<FamilyPerson>? _offlineProfiles;
  bool _isLoading = true;
  String _errorMessage = '';
  String? _selectedTreeId;
  String? _selectedTreeName;

  @override
  void initState() {
    super.initState();
    // Получаем данные о дереве из провайдера ПОСЛЕ первого кадра
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final treeProvider = Provider.of<TreeProvider>(context, listen: false);
      _selectedTreeId = treeProvider.selectedTreeId;
      _selectedTreeName = treeProvider.selectedTreeName;
      _loadOfflineProfiles();
    });
  }

  Future<void> _loadOfflineProfiles() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
      _offlineProfiles = null;
    });

    final currentUserId = _authService.currentUserId;
    if (currentUserId == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Ошибка: Пользователь не авторизован.';
      });
      return;
    }

    if (_selectedTreeId == null) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Ошибка: Дерево не выбрано.';
      });
      return;
    }

    try {
      final profiles = await _familyService.getOfflineProfilesByCreator(
        _selectedTreeId!,
        currentUserId,
      );
      if (mounted) {
        setState(() {
          _offlineProfiles = profiles;
          _isLoading = false;
        });
      }
    } catch (e) {
      print('Ошибка загрузки оффлайн профилей: $e');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Не удалось загрузить список созданных профилей.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Созданные профили (${_selectedTreeName ?? "..."})'),
        leading: IconButton(
          icon: Icon(Icons.arrow_back),
          onPressed: () => context.pop(), // Возврат на предыдущий экран
        ),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }
    if (_errorMessage.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(_errorMessage, textAlign: TextAlign.center),
        ),
      );
    }
    if (_offlineProfiles == null || _offlineProfiles!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            'Вы еще не создавали оффлайн-профили в этом дереве.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey[600]),
          ),
        ),
      );
    }

    // Отображаем список
    return ListView.builder(
      itemCount: _offlineProfiles!.length,
      itemBuilder: (context, index) {
        final person = _offlineProfiles![index];
        return ListTile(
          leading: CircleAvatar(
            backgroundImage:
                person.photoUrl != null ? NetworkImage(person.photoUrl!) : null,
            child: person.photoUrl == null
                // Используем инициалы или иконку по полу
                ? Text(person.initials, style: TextStyle(color: Colors.white))
                // ? Icon(person.gender == Gender.male ? Icons.person : Icons.female, color: Colors.white)
                : null,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
          ),
          title: Text(person.displayName),
          subtitle: Text(
            'Оффлайн-профиль' +
                (person.birthDate != null
                    ? ', Род: ${person.birthDate!.year}'
                    : ''),
          ),
          onTap: () {
            context.push('/relative/details/${person.id}');
          },
        );
      },
    );
  }
}
