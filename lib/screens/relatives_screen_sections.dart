part of 'relatives_screen.dart';

extension _RelativesScreenSections on _RelativesScreenState {
  List<Widget> _buildRelativesAppBarActions({
    required TreeProvider treeProvider,
    required String? selectedTreeId,
    required bool isFriendsTree,
  }) {
    return [
      if (!_isWideLayout(context))
        IconButton(
          key: const ValueKey<String>('relatives-search-toggle'),
          icon: const Icon(Icons.search),
          tooltip: 'Поиск',
          onPressed: _openSearch,
        ),
      IconButton(
        icon: const Icon(Icons.account_tree_outlined),
        // Ведёт на вкладку с уже выбранным деревом — «выбрать другое»
        // тут не обещаем: за выбором ходят в /trees.
        tooltip: 'Открыть дерево',
        onPressed: () {
          // Дерево — соседняя вкладка (центр бара/рейла).
          context.go('/tree');
        },
      ),
      if (_pendingRequestsCount > 0)
        Badge(
          label: Text(_pendingRequestsCount.toString()),
          child: IconButton(
            icon: const Icon(Icons.notifications_none),
            tooltip: isFriendsTree
                ? 'Запросы на связи ($_pendingRequestsCount)'
                : 'Запросы на родство ($_pendingRequestsCount)',
            onPressed: selectedTreeId == null
                ? null
                : () {
                    context.push('/relatives/requests/$selectedTreeId');
                  },
          ),
        ),
      PopupMenuButton<String>(
        onSelected: (value) => _handleRelativesMenuSelection(
          value,
          selectedTreeId: selectedTreeId,
        ),
        itemBuilder: (context) => _buildRelativesMenuItems(
          treeProvider: treeProvider,
          selectedTreeId: selectedTreeId,
          isFriendsTree: isFriendsTree,
        ),
      ),
    ];
  }

  void _handleRelativesMenuSelection(
    String value, {
    required String? selectedTreeId,
  }) {
    if (selectedTreeId == null) {
      showAppSnackBar(context, 'Сначала выберите дерево');
      return;
    }

    if (value == 'add') {
      // Audit Screen 4.2 (2026-05-28): explicit «Кем приходится?»
      // step ПЕРЕД name form. Через _startAddRelativeFlow — список
      // перезагружается после сохранения (stale-list смоук 2026-07-04).
      unawaited(_startAddRelativeFlow(selectedTreeId));
    } else if (value == 'find') {
      context.push('/relatives/find/$selectedTreeId');
    } else if (value == 'create_tree') {
      context.push('/trees/create').then((result) {
        // Можно опционально перейти на новый экран дерева после создания.
      });
    } else if (value == 'requests_menu') {
      context.push('/relatives/requests/$selectedTreeId');
    }
  }

  List<PopupMenuEntry<String>> _buildRelativesMenuItems({
    required TreeProvider treeProvider,
    required String? selectedTreeId,
    required bool isFriendsTree,
  }) {
    return [
      PopupMenuItem<String>(
        value: 'add',
        enabled: selectedTreeId != null,
        child: ListTile(
          leading: const Icon(Icons.person_add),
          title: Text(_graphAddLabel(treeProvider)),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      PopupMenuItem<String>(
        value: 'create_tree',
        child: ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: Text(
            isFriendsTree ? 'Создать новый круг' : 'Создать новое дерево',
          ),
          contentPadding: EdgeInsets.zero,
        ),
      ),
      if (_pendingRequestsCount > 0)
        PopupMenuItem<String>(
          value: 'requests_menu',
          enabled: selectedTreeId != null,
          child: ListTile(
            leading: const Icon(Icons.notifications),
            title: Text(
              isFriendsTree
                  ? 'Запросы на связи ($_pendingRequestsCount)'
                  : 'Запросы на родство ($_pendingRequestsCount)',
            ),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      PopupMenuItem<String>(
        value: 'find',
        enabled: selectedTreeId != null,
        child: ListTile(
          leading: const Icon(Icons.search),
          title: Text(_graphFindLabel(treeProvider)),
          contentPadding: EdgeInsets.zero,
        ),
      ),
    ];
  }
}
