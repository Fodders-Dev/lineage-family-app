import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import '../backend/backend_runtime_config.dart';
import '../models/family_tree.dart';
import '../models/family_tree_member.dart';
import '../providers/tree_provider.dart';
import 'package:get_it/get_it.dart';
import '../backend/interfaces/auth_service_interface.dart';
import '../backend/interfaces/family_tree_service_interface.dart';
import '../backend/models/tree_invitation.dart';
import '../services/crashlytics_service.dart';
import '../services/public_tree_link_service.dart';

class TreesScreen extends StatefulWidget {
  const TreesScreen({Key? key}) : super(key: key);

  @override
  _TreesScreenState createState() => _TreesScreenState();
}

class _TreesScreenState extends State<TreesScreen>
    with SingleTickerProviderStateMixin {
  final AuthServiceInterface _authService = GetIt.I<AuthServiceInterface>();
  final FamilyTreeServiceInterface _familyTreeService =
      GetIt.I<FamilyTreeServiceInterface>();
  final CrashlyticsService _crashlyticsService = CrashlyticsService();
  late TabController _tabController;

  // Переменные для хранения состояния
  List<FamilyTree> _myTrees = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);

    _tabController.addListener(
      _handleTabSelection,
    ); // Используем метод-обработчик

    // Загружаем деревья для первой вкладки при инициализации
    _loadUserTrees();
  }

  @override
  void dispose() {
    _tabController.removeListener(_handleTabSelection); // Удаляем слушателя
    _tabController.dispose();
    super.dispose();
  }

  // Метод-обработчик для слушателя
  void _handleTabSelection() {
    // Загружаем деревья только когда выбрана первая вкладка (индекс 0)
    // и когда переход между вкладками завершен (!indexIsChanging)
    if (!_tabController.indexIsChanging && _tabController.index == 0) {
      print("[_TreesScreen] Tab changed to 'Мои деревья', reloading trees...");
      _loadUserTrees(); // Вызываем загрузку/обновление
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Семейные деревья'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Мои деревья'),
            Tab(text: 'Приглашения'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildMyTreesTab(), _buildInvitationsTab()],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToCreateTree,
        icon: const Icon(Icons.add),
        label: const Text('Новое дерево'),
        tooltip: 'Создать семейное дерево',
      ),
    );
  }

  Widget _buildMyTreesTab() {
    final userId = _authService.currentUserId;
    if (userId == null) {
      return Center(child: Text('Необходимо войти в систему'));
    }

    if (_isLoading) {
      return Center(child: CircularProgressIndicator());
    }

    if (_myTrees.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.family_restroom, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                'У вас пока нет семейных деревьев',
                style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Создайте своё дерево или примите приглашение. После этого можно будет открыть схему семьи и редактировать её без лишних переходов.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[600]),
              ),
              const SizedBox(height: 20),
              ElevatedButton.icon(
                onPressed: _navigateToCreateTree,
                icon: const Icon(Icons.add),
                label: const Text('Создать новое дерево'),
              ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshTrees,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Быстрый вход в дерево',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Открывайте нужное дерево сразу в интерактивной схеме. Количество веток: ${_myTrees.length}.',
                ),
              ],
            ),
          ),
          ...(() {
            final selectedTreeId = context.select<TreeProvider, String?>(
              (provider) => provider.selectedTreeId,
            );
            return _myTrees.map((tree) {
              final role = tree.creatorId == _authService.currentUserId
                  ? MemberRole.owner
                  : MemberRole.editor;
              return TreeCard(
                tree: tree,
                role: role,
                isSelected: selectedTreeId == tree.id,
                onCopyPublicLink:
                    tree.isPublic ? () => _copyPublicLink(tree) : null,
                onTap: () => _openTree(tree),
              );
            });
          })(),
        ],
      ),
    );
  }

  Widget _buildInvitationsTab() {
    final userId = _authService.currentUserId;
    if (userId == null) {
      return Center(child: Text('Необходимо войти в систему'));
    }

    return RefreshIndicator(
      onRefresh: () async {
        setState(() {});
        return Future.value();
      },
      child: StreamBuilder<List<TreeInvitation>>(
        stream: _familyTreeService.getPendingTreeInvitations(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return Center(child: CircularProgressIndicator());
          }

          if (!snapshot.hasData || snapshot.data!.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mail, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'У вас нет приглашений в семейные деревья',
                    style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                  ),
                ],
              ),
            );
          }

          final invitations = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: invitations
                .map(
                  (invitation) => InvitationCard(
                    tree: invitation.tree,
                    invitedBy: invitation.invitedBy,
                    onAccept: () =>
                        _handleInvitation(invitation.invitationId, true),
                    onDecline: () =>
                        _handleInvitation(invitation.invitationId, false),
                  ),
                )
                .toList(),
          );
        },
      ),
    );
  }

  Future<void> _handleInvitation(String invitationId, bool accept) async {
    try {
      await _familyTreeService.respondToTreeInvitation(invitationId, accept);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept ? 'Приглашение принято' : 'Приглашение отклонено',
          ),
        ),
      );
    } catch (e) {
      print('Ошибка при обработке приглашения: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Произошла ошибка. Попробуйте еще раз.')),
      );
    }
  }

  // --- НОВАЯ РЕАЛИЗАЦИЯ ЗАГРУЗКИ ДЕРЕВЬЕВ ---
  Future<void> _loadUserTrees() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
    });

    final userId = _authService.currentUserId;
    if (userId == null) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
      return;
    }

    try {
      final trees = await _familyTreeService.getUserTrees();

      if (mounted) {
        setState(() {
          _myTrees = trees;
          _isLoading = false;
        });
      }
    } catch (e, stackTrace) {
      _crashlyticsService.logError(e, stackTrace, reason: 'LoadUserTreesError');
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
  // --- КОНЕЦ НОВОЙ РЕАЛИЗАЦИИ ---

  void _navigateToCreateTree() {
    context.push('/trees/create').then((_) {
      _loadUserTrees();
    });
  }

  // --- РЕАЛИЗАЦИЯ REFRESH ---
  Future<void> _refreshTrees() async {
    final userId = _authService.currentUserId;
    if (userId == null) {
      return;
    }

    try {
      await _loadUserTrees();
    } catch (e, stackTrace) {
      _crashlyticsService.logError(e, stackTrace, reason: 'RefreshTreesError');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ошибка обновления списка деревьев')),
        );
      }
    }
  }

  Future<void> _openTree(FamilyTree tree) async {
    await Provider.of<TreeProvider>(context, listen: false).selectTree(
      tree.id,
      tree.name,
    );
    if (!mounted) {
      return;
    }
    final encodedName = Uri.encodeComponent(tree.name);
    context.go('/tree/view/${tree.id}?name=$encodedName');
  }

  Future<void> _copyPublicLink(FamilyTree tree) async {
    final publicUri = PublicTreeLinkService.buildPublicTreeUri(
      tree.publicRouteId,
      publicAppUrl: BackendRuntimeConfig.current.publicAppUrl,
    );
    await Clipboard.setData(ClipboardData(text: publicUri.toString()));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Публичная ссылка скопирована.')),
    );
  }

  // --- КОНЕЦ РЕАЛИЗАЦИИ REFRESH ---
}

class TreeCard extends StatelessWidget {
  final FamilyTree tree;
  final MemberRole role;
  final bool isSelected;
  final VoidCallback? onCopyPublicLink;
  final VoidCallback onTap;

  const TreeCard({
    Key? key,
    required this.tree,
    required this.role,
    this.isSelected = false,
    this.onCopyPublicLink,
    required this.onTap,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    String roleText;
    IconData roleIcon;

    switch (role) {
      case MemberRole.owner:
        roleText = 'Создатель';
        roleIcon = Icons.star;
        break;
      case MemberRole.editor:
        roleText = 'Участник';
        roleIcon = Icons.groups_2_outlined;
        break;
      case MemberRole.viewer:
        roleText = 'Просмотр';
        roleIcon = Icons.visibility;
        break;
      default:
        roleText = 'Неизвестно';
        roleIcon = Icons.question_mark;
    }

    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isSelected
          ? Theme.of(context).colorScheme.primaryContainer.withValues(
                alpha: 0.5,
              )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).primaryColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.family_restroom,
                  size: 32,
                  color: Theme.of(context).primaryColor,
                ),
              ),
              SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tree.name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _MetaChip(
                          icon: tree.isPrivate
                              ? Icons.lock_outline
                              : Icons.public,
                          label: tree.isPrivate ? 'Приватное' : 'Публичное',
                        ),
                        if (tree.isCertified)
                          _MetaChip(
                            icon: Icons.verified_outlined,
                            label: 'Сертифицировано',
                            highlighted: true,
                          ),
                        if (isSelected)
                          _MetaChip(
                            icon: Icons.check_circle_outline,
                            label: 'Открыто сейчас',
                            highlighted: true,
                          ),
                      ],
                    ),
                    SizedBox(height: 4),
                    Text(
                      tree.description.isEmpty
                          ? 'Описание пока не добавлено'
                          : tree.description,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.grey[600]),
                    ),
                    SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          roleIcon,
                          size: 16,
                          color: Theme.of(context).primaryColor,
                        ),
                        SizedBox(width: 4),
                        Text(
                          roleText,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).primaryColor,
                          ),
                        ),
                        SizedBox(width: 12),
                        Icon(Icons.people, size: 16, color: Colors.grey[600]),
                        SizedBox(width: 4),
                        Text(
                          '${tree.memberIds.length} ${_getMembersText(tree.memberIds.length)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                    if (tree.isCertified &&
                        tree.certificationNote != null &&
                        tree.certificationNote!.trim().isNotEmpty) ...[
                      SizedBox(height: 8),
                      Text(
                        tree.certificationNote!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onCopyPublicLink != null)
                IconButton(
                  tooltip: 'Скопировать публичную ссылку',
                  onPressed: onCopyPublicLink,
                  icon: const Icon(Icons.link_outlined),
                ),
              Icon(Icons.arrow_forward_ios, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  String _getMembersText(int count) {
    if (count == 1) return 'участник';
    if (count >= 2 && count <= 4) return 'участника';
    return 'участников';
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({
    required this.icon,
    required this.label,
    this.highlighted = false,
  });

  final IconData icon;
  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.primaryContainer
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: highlighted
                ? colorScheme.primary
                : colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: highlighted
                  ? colorScheme.primary
                  : colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class InvitationCard extends StatelessWidget {
  final FamilyTree tree;
  final String? invitedBy;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const InvitationCard({
    Key? key,
    required this.tree,
    this.invitedBy,
    required this.onAccept,
    required this.onDecline,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).primaryColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.family_restroom,
                    size: 28,
                    color: Theme.of(context).primaryColor,
                  ),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tree.name,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        tree.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            Text(
              invitedBy != null
                  ? 'Вас пригласили присоединиться к семейному дереву'
                  : 'Приглашение в семейное дерево',
              style: TextStyle(fontSize: 14, color: Colors.grey[700]),
            ),
            SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: onDecline,
                  child: Text('Отклонить'),
                  style: TextButton.styleFrom(
                    foregroundColor: Colors.grey[700],
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: onAccept,
                  child: Text('Принять'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).primaryColor,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
