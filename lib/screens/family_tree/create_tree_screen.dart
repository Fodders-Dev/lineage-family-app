// ignore_for_file: use_build_context_synchronously
// ignore_for_file: library_private_types_in_public_api
import 'package:flutter/material.dart';
import 'package:get_it/get_it.dart';
import 'package:go_router/go_router.dart';

import '../../backend/interfaces/family_tree_service_interface.dart';
import '../../models/family_tree.dart';
import '../../providers/tree_provider.dart';

class CreateTreeScreen extends StatefulWidget {
  const CreateTreeScreen({
    super.key,
    this.initialKind = TreeKind.family,
  });

  final TreeKind initialKind;

  @override
  _CreateTreeScreenState createState() => _CreateTreeScreenState();
}

class _CreateTreeScreenState extends State<CreateTreeScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  bool _isLoading = false;
  bool _isPrivate = true; // Значение по умолчанию - приватное дерево
  late TreeKind _treeKind;

  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();

  @override
  void initState() {
    super.initState();
    _treeKind = widget.initialKind;
  }

  Future<void> _createTree() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final treeId = await _familyTreeService.createTree(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        isPrivate: _isPrivate,
        kind: _treeKind,
      );

      if (mounted) {
        final treeName = _nameController.text.trim();
        if (GetIt.I.isRegistered<TreeProvider>()) {
          await GetIt.I<TreeProvider>().selectTree(
            treeId,
            treeName,
            treeKind: _treeKind,
          );
        }
        final successLabel = _treeKind == TreeKind.friends
            ? 'Дерево друзей создано'
            : 'Семейное дерево создано';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(successLabel)));
        final encodedName = Uri.encodeComponent(treeName);
        context.go('/tree/view/$treeId?name=$encodedName');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Ошибка: $e')));
      }
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
      appBar: AppBar(title: const Text('Новое дерево')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'С чего начнём?',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                _treeKind == TreeKind.friends
                    ? 'Введите название и сразу откроете граф друзей для настройки связей и ручной композиции.'
                    : 'Введите название и сразу откроете дерево для добавления родственников.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              SegmentedButton<TreeKind>(
                segments: const [
                  ButtonSegment<TreeKind>(
                    value: TreeKind.family,
                    icon: Icon(Icons.family_restroom),
                    label: Text('Семья'),
                  ),
                  ButtonSegment<TreeKind>(
                    value: TreeKind.friends,
                    icon: Icon(Icons.diversity_3_outlined),
                    label: Text('Друзья'),
                  ),
                ],
                selected: <TreeKind>{_treeKind},
                onSelectionChanged: (selection) {
                  setState(() {
                    _treeKind = selection.first;
                  });
                },
              ),
              const SizedBox(height: 12),
              Text(
                _treeKind == TreeKind.friends
                    ? 'Режим друзей подходит для близкого круга, друзей, коллег и выбранной семьи. Узлы в таком дереве удобнее раскладывать вручную.'
                    : 'Режим семьи лучше подходит для родственных связей, поколений и веток рода.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: _treeKind == TreeKind.friends
                      ? 'Название дерева друзей'
                      : 'Название дерева',
                  hintText: _treeKind == TreeKind.friends
                      ? 'Например: Наш круг'
                      : 'Например: Семья Ивановых',
                  prefixIcon: Icon(
                    _treeKind == TreeKind.friends
                        ? Icons.diversity_3_outlined
                        : Icons.family_restroom,
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return _treeKind == TreeKind.friends
                        ? 'Введите название дерева друзей'
                        : 'Введите название дерева';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _descriptionController,
                decoration: const InputDecoration(
                  labelText: 'Описание, если нужно',
                  hintText:
                      'Например: близкие друзья, университет, рабочий круг',
                  prefixIcon: Icon(Icons.description),
                  alignLabelWithHint: true,
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 20),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _isPrivate,
                onChanged: (value) {
                  setState(() {
                    _isPrivate = value;
                  });
                },
                title:
                    Text(_isPrivate ? 'Приватное дерево' : 'Публичное дерево'),
                subtitle: Text(
                  _isPrivate
                      ? 'Его увидят только приглашённые участники.'
                      : 'Его можно будет открывать по ссылке.',
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _createTree,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: _isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Создать и открыть'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }
}
