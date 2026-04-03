import 'package:flutter/material.dart';

class MainNavigationBar extends StatelessWidget {
  const MainNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
    required this.unreadNotificationsStream,
    required this.unreadChatsStream,
    required this.pendingInvitationsCountStream,
  });

  final int currentIndex;
  final ValueChanged<int> onTap;
  final Stream<int> unreadNotificationsStream;
  final Stream<int> unreadChatsStream;
  final Stream<int> pendingInvitationsCountStream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: unreadNotificationsStream,
      initialData: 0,
      builder: (context, notificationsSnapshot) {
        final unreadNotificationsCount = notificationsSnapshot.data ?? 0;
        return StreamBuilder<int>(
          stream: unreadChatsStream,
          initialData: 0,
          builder: (context, unreadSnapshot) {
            final unreadCount = unreadSnapshot.data ?? 0;
            return StreamBuilder<int>(
              stream: pendingInvitationsCountStream,
              initialData: 0,
              builder: (context, invitationsSnapshot) {
                final pendingInvitationsCount = invitationsSnapshot.data ?? 0;

                return BottomNavigationBar(
                  type: BottomNavigationBarType.fixed,
                  currentIndex: currentIndex,
                  selectedItemColor: Theme.of(context).colorScheme.primary,
                  unselectedItemColor: Colors.grey,
                  onTap: onTap,
                  items: [
                    BottomNavigationBarItem(
                      icon: _CountBadgeIcon(
                        count: unreadNotificationsCount,
                        outlinedIcon: Icons.home_outlined,
                        filledIcon: Icons.home,
                        selected: false,
                      ),
                      activeIcon: _CountBadgeIcon(
                        count: unreadNotificationsCount,
                        outlinedIcon: Icons.home_outlined,
                        filledIcon: Icons.home,
                        selected: true,
                      ),
                      label: 'Главная',
                    ),
                    const BottomNavigationBarItem(
                      icon: Icon(Icons.people_outline),
                      activeIcon: Icon(Icons.people),
                      label: 'Родные',
                    ),
                    BottomNavigationBarItem(
                      icon: _buildTreeIcon(context, pendingInvitationsCount),
                      label: 'Моё дерево',
                    ),
                    BottomNavigationBarItem(
                      icon: _CountBadgeIcon(
                        count: unreadCount,
                        outlinedIcon: Icons.chat_bubble_outline,
                        filledIcon: Icons.chat_bubble,
                        selected: false,
                      ),
                      activeIcon: _CountBadgeIcon(
                        count: unreadCount,
                        outlinedIcon: Icons.chat_bubble_outline,
                        filledIcon: Icons.chat_bubble,
                        selected: true,
                      ),
                      label: 'Чаты',
                    ),
                    const BottomNavigationBarItem(
                      icon: Icon(Icons.person_outline),
                      activeIcon: Icon(Icons.person),
                      label: 'Профиль',
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildTreeIcon(BuildContext context, int pendingInvitationsCount) {
    final icon = Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.account_tree,
        color: Theme.of(context).colorScheme.onPrimary,
        size: 20,
      ),
    );

    if (pendingInvitationsCount <= 0) {
      return icon;
    }

    return Badge(
      label: Text(
        pendingInvitationsCount > 99
            ? '99+'
            : pendingInvitationsCount.toString(),
      ),
      child: icon,
    );
  }
}

class _CountBadgeIcon extends StatelessWidget {
  const _CountBadgeIcon({
    required this.count,
    required this.outlinedIcon,
    required this.filledIcon,
    required this.selected,
  });

  final int count;
  final IconData outlinedIcon;
  final IconData filledIcon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final child = Icon(selected ? filledIcon : outlinedIcon);
    if (count <= 0) {
      return child;
    }

    return Badge(
      label: Text(count > 99 ? '99+' : count.toString()),
      child: child,
    );
  }
}
